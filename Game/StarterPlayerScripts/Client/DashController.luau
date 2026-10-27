--[[
	DashController  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > DashController

	Cliente del dash. Responsabilidades del CLIENTE:
	  - Input, dirección (MoveDirection + yaw de la cámara) y estados (Idle / Active / Recovery).
	  - Impulso físico con LinearVelocity (solo plano XZ: la gravedad y el salto siguen funcionando).
	  - Detección de paredes con Blockcast del tamaño del personaje, antes y durante el dash.
	  - Predicción inmediata (el dash arranca sin esperar al servidor).
	El SERVIDOR (DodgeService vía CombatService) valida el pedido, concede la invulnerabilidad y decide el Perfect Dodge.

	Red (sin remotes propios): CombatClient envía "Dash" por CombatRequest (deps.requestDash) y
	reenvía a este módulo los payloads de CombatFeedback Kind = "DashResponse" / "DodgeEvent"
	(OnServerResponse / OnServerEvent).

	Reconciliación: si el servidor rechaza el dash (o lo cancela por stun, muerte, etc.), el cliente destruye el
	LinearVelocity, anula la velocidad horizontal residual, libera la orientación y vuelve a Idle. No hay
	teletransporte de corrección: el personaje se detiene donde está. Mientras el dash está activo, MovementController
	pone el movimiento del Humanoid a 0 (CombatConfig.Movement.Dash.Active), así que nada compite con el LinearVelocity.

	Señales (DashController.Events.X:Connect(...)) -- puntos de enganche para animaciones, VFX y sonidos:
		DashStarted(info)            InvulnerabilityStarted(info)   InvulnerabilityEnded(info)
		Dodged()                     PerfectDodge()  (confirmado por el servidor)
		DashEnded(info, reason)      RecoveryStarted(info)          RecoveryEnded()
		DashCancelled(reason)        DashBlocked(reason, directionName)
		RemotePlayerEvent(eventName, character)   (eventos de OTROS jugadores, para VFX)
	info = { Id, Direction (Vector3), DirectionName ("Forward"/"Backward"/"Left"/"Right"), Distance, Duration }

	Consultas: GetState(), GetMovePhase(), IsDashing(), IsBusy(), GetCharges(), GetCooldownRemaining().

	deps = {
		getCameraYaw() -> number
		isGameMode()   -> boolean
		canStart()     -> (boolean, string?)   reglas locales del combate (stun, ataque, bloqueo)
		requestDash(id)
		orientation    -> CharacterOrientation
	}
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CombatFolder = ReplicatedStorage:WaitForChild("CombatSystem")
local cfg = require(CombatFolder:WaitForChild("DashConfig"))
local SignalSet = require(CombatFolder:WaitForChild("SignalSet"))

local player = Players.LocalPlayer
local collisionCfg = cfg.Collision

local DashController = {}
DashController.Signals = SignalSet.new({
	"DashStarted",
	"InvulnerabilityStarted",
	"InvulnerabilityEnded",
	"Dodged",
	"PerfectDodge",
	"DashEnded",
	"RecoveryStarted",
	"RecoveryEnded",
	"DashCancelled",
	"DashBlocked",
	"RemotePlayerEvent",
})
DashController.Events = DashController.Signals.Events

local INVALID_STATES = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Seated] = true,
}

----------------------------------------------------------------------
-- Estado
----------------------------------------------------------------------

local deps = nil
local started = false
local connections = {}
local characterConnections = {}

local character, humanoid, root = nil, nil, nil

local state = "Idle" -- Idle | Active | Recovery
local recoveryEnd = 0
local charges = cfg.MaxCharges
local rechargeAt = 0
local nextDashId = 0
local dash = nil -- Dash activo

local attachment, linearVelocity = nil, nil

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.RespectCanCollide = true
raycastParams.IgnoreWater = true

local function fire(name, ...)
	DashController.Signals:Fire(name, ...)
end

----------------------------------------------------------------------
-- Cargas
----------------------------------------------------------------------

local function refreshCharges(now)
	local cooldown = math.max(cfg.Cooldown, 0.01)
	while charges < cfg.MaxCharges and now >= rechargeAt do
		charges += 1
		rechargeAt += cooldown
	end
end

----------------------------------------------------------------------
-- Dirección
----------------------------------------------------------------------

-- Devuelve (derecha, adelante) del movimiento pedido, relativo al yaw de la cámara.
local function getLocalInput(yaw)
	local moveDir = humanoid.MoveDirection
	local sinY, cosY = math.sin(yaw), math.cos(yaw)
	local forward = moveDir.X * -sinY + moveDir.Z * -cosY
	local right = moveDir.X * cosY + moveDir.Z * -sinY
	return right, forward
end

local function cardinalName(right, forward)
	if math.abs(right) > math.abs(forward) + 0.01 then
		return if right > 0 then "Right" else "Left"
	end
	return if forward >= 0 then "Forward" else "Backward"
end

-- Devuelve la dirección en el mundo (horizontal, unitaria) y su nombre cardinal.
-- Con lock-on el yaw de la cámara apunta al objetivo: W = hacia él, A/D = circular, S = alejarse.
local function resolveDirection(yaw)
	local right, forward = getLocalInput(yaw)
	local magnitude = math.sqrt(right * right + forward * forward)
	local dirCfg = cfg.Direction

	-- MoveDirection puede venir escalado por las restricciones del combate; se compara con un umbral bajo
	if magnitude < 0.05 then
		right, forward = 0, if dirCfg.NoInput == "Forward" then 1 else -1
	elseif dirCfg.Mode == "FourWay" then
		-- En diagonales gana adelante/atrás sobre el lateral
		if math.abs(right) > math.abs(forward) + 0.01 then
			right, forward = math.sign(right), 0
		else
			right, forward = 0, math.sign(forward)
		end
	else
		right, forward = right / magnitude, forward / magnitude
	end

	local sinY, cosY = math.sin(yaw), math.cos(yaw)
	local worldDir = Vector3.new(-sinY * forward + cosY * right, 0, -cosY * forward - sinY * right)
	return worldDir.Unit, cardinalName(right, forward)
end

----------------------------------------------------------------------
-- Colisión: Blockcast con el tamaño real del personaje (no un raycast central)
----------------------------------------------------------------------

local function getCastBox(direction)
	local hipHeight = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else humanoid.HipHeight
	local rootPos = root.Position
	local bottom = rootPos.Y - (hipHeight + root.Size.Y / 2) + collisionCfg.StepHeight
	local top = rootPos.Y + root.Size.Y / 2 + collisionCfg.HeadRoom
	local height = math.max(top - bottom, 0.5)
	local center = Vector3.new(rootPos.X, bottom + height / 2, rootPos.Z)
	return CFrame.lookAt(center, center + direction), Vector3.new(collisionCfg.Width, height, collisionCfg.Width)
end

-- Devuelve la distancia libre hasta el primer obstáculo, o nil si el camino está libre.
local function castDistance(direction, distance)
	local cframe, size = getCastBox(direction)
	local result = workspace:Blockcast(cframe, size, direction * distance, raycastParams)
	if result then
		return result.Distance
	end
	return nil
end

----------------------------------------------------------------------
-- Física
----------------------------------------------------------------------

local function destroyConstraint()
	if linearVelocity then
		linearVelocity:Destroy()
		linearVelocity = nil
	end
	if attachment then
		attachment:Destroy()
		attachment = nil
	end
end

local function createConstraint(initialVelocity)
	attachment = Instance.new("Attachment")
	attachment.Name = "DashAttachment"
	attachment.Parent = root

	local lv = Instance.new("LinearVelocity")
	lv.Name = "DashVelocity"
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	local force = root.AssemblyMass * cfg.Physics.ForceMultiplier
	lv.MaxAxesForce = Vector3.new(force, 0, force) -- Eje Y libre: gravedad y salto intactos
	lv.VectorVelocity = initialVelocity
	lv.Parent = root
	linearVelocity = lv
end

-- Anula la velocidad horizontal (conserva la vertical): sin deslizamiento residual.
local function zeroPlanarVelocity()
	if root and root.Parent then
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
	end
end

local function releaseOrientation()
	if deps and deps.orientation then
		deps.orientation.EndOverride()
	end
end

----------------------------------------------------------------------
-- Fin del dash
----------------------------------------------------------------------

local function isCharacterValid()
	if not humanoid or not root or not root.Parent or humanoid.Parent == nil then
		return false
	end
	if humanoid.Health <= 0 or humanoid.Sit then
		return false
	end
	return not INVALID_STATES[humanoid:GetState()]
end

-- Fin normal (completado o por obstáculo): pasa a Recovery.
local function finishDash(reason)
	if state ~= "Active" or not dash then
		return
	end
	local info = dash.info

	if reason == "Obstacle" then
		zeroPlanarVelocity()
	end

	destroyConstraint()
	releaseOrientation()

	if dash.invulnerable then
		dash.invulnerable = false
		fire("InvulnerabilityEnded", info)
	end

	dash = nil
	state = "Recovery"
	recoveryEnd = os.clock() + cfg.RecoveryTime

	fire("DashEnded", info, reason)
	fire("RecoveryStarted", info)
end

-- Cancelación (muerte, respawn, rechazo del servidor, stun, estado inválido): vuelve a Idle sin residuos.
local function cancelDash(reason)
	if state == "Idle" then
		return
	end

	local wasActive = state == "Active"
	local info = dash and dash.info
	local wasInvulnerable = dash ~= nil and dash.invulnerable

	destroyConstraint()
	releaseOrientation()
	if wasActive then
		zeroPlanarVelocity()
	end

	dash = nil
	state = "Idle"

	if wasInvulnerable then
		fire("InvulnerabilityEnded", info)
	end
	if wasActive then
		fire("DashCancelled", reason)
	end
end

----------------------------------------------------------------------
-- Inicio del dash
----------------------------------------------------------------------

local function tryStart()
	if state ~= "Idle" or not humanoid or not root then
		return
	end
	if not isCharacterValid() then
		return
	end
	if cfg.BlockInUIMode and deps.isGameMode and not deps.isGameMode() then
		return
	end

	-- Reglas locales del combate (el servidor las vuelve a validar y manda)
	if deps.canStart then
		local ok, reason = deps.canStart()
		if not ok then
			fire("DashBlocked", reason or "CombatState", "")
			return
		end
	end

	local now = os.clock()
	refreshCharges(now)
	if charges <= 0 then
		fire("DashBlocked", "Cooldown", "")
		return
	end
	if not cfg.AllowInAir and humanoid.FloorMaterial == Enum.Material.Air then
		fire("DashBlocked", "Airborne", "")
		return
	end

	local yaw = deps.getCameraYaw()
	local direction, directionName = resolveDirection(yaw)

	-- Acorta el dash si hay una pared; si no hay espacio suficiente, ni empieza (no gasta carga)
	local distance = cfg.Distance
	local free = castDistance(direction, distance + collisionCfg.SkinWidth)
	if free then
		distance = math.min(distance, free - collisionCfg.SkinWidth)
	end
	if distance < collisionCfg.MinDistance then
		fire("DashBlocked", "Obstacle", directionName)
		return
	end

	local duration = math.max(cfg.Duration * (distance / cfg.Distance), collisionCfg.MinDuration)

	-- Gasta la carga
	local wasFull = charges >= cfg.MaxCharges
	charges -= 1
	if wasFull then
		rechargeAt = now + cfg.Cooldown
	end

	nextDashId += 1
	local info = {
		Id = nextDashId,
		Direction = direction,
		DirectionName = directionName,
		Distance = distance,
		Duration = duration,
	}
	dash = {
		id = nextDashId,
		info = info,
		direction = direction,
		distance = distance,
		duration = duration,
		baseSpeed = distance / duration,
		startTime = now,
		invulnerable = cfg.InvulnerabilityDuration > 0, -- Predicción local; el servidor decide
	}
	state = "Active"

	if cfg.Direction.AlignCharacterToCamera and deps.orientation then
		deps.orientation.BeginOverride(yaw)
	end

	local power = cfg.SpeedDecayPower
	createConstraint(direction * dash.baseSpeed * (power + 1))

	-- Solo se envía el ID de secuencia: el servidor no lee dirección, distancia ni tiempos del cliente
	if deps.requestDash then
		deps.requestDash(nextDashId)
	end

	fire("DashStarted", info)
	if dash.invulnerable then
		fire("InvulnerabilityStarted", info)
	end
end

----------------------------------------------------------------------
-- Actualización por frame (Heartbeat: fase de física)
----------------------------------------------------------------------

local function onHeartbeat(dt)
	local now = os.clock()

	if charges < cfg.MaxCharges then
		refreshCharges(now)
	end

	if state == "Recovery" then
		if now >= recoveryEnd then
			state = "Idle"
			fire("RecoveryEnded")
		end
		return
	end
	if state ~= "Active" or not dash then
		return
	end

	if not isCharacterValid() then
		cancelDash("InvalidState")
		return
	end

	local t = now - dash.startTime

	if dash.invulnerable and t >= cfg.InvulnerabilityDuration then
		dash.invulnerable = false
		fire("InvulnerabilityEnded", dash.info)
	end

	if t >= dash.duration then
		finishDash("Completed")
		return
	end

	-- [v2.9] Dash lateral circular: la dirección se recalcula cada fotograma con el yaw ACTUAL de la cámara.
	if cfg.Direction.CircularSideDash and deps.getCameraYaw then
		local side = if dash.info.DirectionName == "Right" then 1 elseif dash.info.DirectionName == "Left" then -1 else 0
		if side ~= 0 then
			local yaw = deps.getCameraYaw()
			local sinY, cosY = math.sin(yaw), math.cos(yaw)
			dash.direction = Vector3.new(cosY * side, 0, -sinY * side).Unit
			if cfg.Direction.AlignCharacterToCamera and deps.orientation then
				deps.orientation.BeginOverride(yaw) -- el personaje sigue mirando hacia donde mira la cámara
			end
		end
	end

	local tau = t / dash.duration
	local power = cfg.SpeedDecayPower
	local speed = dash.baseSpeed * (power + 1) * (1 - tau) ^ power

	-- Obstáculo por delante (también cubre objetos que aparecen a mitad del dash)
	local lookAhead = speed * dt + collisionCfg.SkinWidth
	if castDistance(dash.direction, lookAhead) then
		finishDash("Obstacle")
		return
	end

	if linearVelocity then
		linearVelocity.VectorVelocity = dash.direction * speed
	end
end

----------------------------------------------------------------------
-- Personaje
----------------------------------------------------------------------

local function clearCharacter()
	cancelDash("CharacterChanged")
	state = "Idle"
	dash = nil

	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)

	character, humanoid, root = nil, nil, nil
end

-- Llamar con (humanoid, root, character) al aparecer y con nil al removerlo.
function DashController.SetCharacter(newHumanoid, newRoot, newCharacter)
	clearCharacter()
	charges = cfg.MaxCharges
	rechargeAt = 0

	if not newHumanoid or not newRoot or not newCharacter then
		return
	end

	character, humanoid, root = newCharacter, newHumanoid, newRoot
	raycastParams.FilterDescendantsInstances = { newCharacter }
	raycastParams.CollisionGroup = newRoot.CollisionGroup

	table.insert(
		characterConnections,
		newHumanoid.Died:Connect(function()
			cancelDash("Died")
		end)
	)
end

----------------------------------------------------------------------
-- Consultas
----------------------------------------------------------------------

function DashController.GetState()
	return state
end

-- Fase de movimiento para MovementController / CharacterOrientation (nil si no hay dash).
function DashController.GetMovePhase()
	if state == "Active" then
		return "DashActive"
	elseif state == "Recovery" then
		return "DashRecovery"
	end
	return nil
end

function DashController.IsDashing()
	return state == "Active"
end

-- Activo o en recuperación: bloquea ataques y bloqueo hasta que termine.
function DashController.IsBusy()
	return state ~= "Idle"
end

function DashController.GetCharges()
	refreshCharges(os.clock())
	return charges
end

function DashController.GetCooldownRemaining()
	if charges > 0 then
		return 0
	end
	return math.max(rechargeAt - os.clock(), 0)
end

----------------------------------------------------------------------
-- Red (los llama CombatClient al recibir CombatFeedback)
----------------------------------------------------------------------

function DashController.OnServerResponse(payload)
	if typeof(payload) ~= "table" or payload.Accepted ~= false then
		return
	end
	-- Solo cancela si sigue siendo ESE dash
	if dash and dash.id == payload.DashId and state == "Active" then
		cancelDash("Rejected:" .. tostring(payload.Reason))
	end
end

function DashController.OnServerEvent(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local eventName, target = payload.Event, payload.Target
	if typeof(eventName) ~= "string" or typeof(target) ~= "Instance" then
		return
	end

	if target == player.Character then
		-- Los eventos propios de inicio/fin ya se predicen localmente
		if eventName == "PerfectDodge" then
			fire("PerfectDodge")
		elseif eventName == "Dodged" then
			fire("Dodged")
		elseif eventName == "DashCancelled" then
			-- Cancelación autoritativa del servidor (stun, muerte...). Si ya estaba en Idle no hace nada.
			cancelDash("Server:" .. tostring(payload.Reason))
		end
	else
		fire("RemotePlayerEvent", eventName, target)
	end
end

----------------------------------------------------------------------
-- Inicio y limpieza
----------------------------------------------------------------------

function DashController.Start(newDeps)
	if started then
		return
	end
	started = true
	deps = newDeps

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return -- Escribiendo en un TextBox o sobre un botón de la interfaz
			end
			if input.KeyCode == cfg.Key then
				tryStart()
			end
		end)
	)
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))
end

function DashController.Destroy()
	if not started then
		return
	end
	started = false

	clearCharacter()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	DashController.Signals:Destroy()
end

return DashController