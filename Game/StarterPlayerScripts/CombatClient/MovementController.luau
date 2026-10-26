-- MovementController
-- Ubicación: StarterPlayerScripts > CombatClient > MovementController
-- Limita la movilidad según la fase de combate (o del dash) que le informa el provider.
-- NUNCA escribe WalkSpeed (SprintController es su único dueño) NI Humanoid.AutoRotate NI HumanoidRootPart.CFrame
-- (CharacterOrientation es el único dueño de la orientación; antes este módulo también orientaba hacia el lock-on).
--
-- Fases que entiende: Windup, Active, Recovery, ComboWindow, Stunned (servidor, atributo CombatMovePhase),
-- DashActive, DashRecovery (dash local, vía provider; ver CombatConfig.Movement.Dash)
-- y [v2] Block, Parry (las decide init.local con el atributo CombatDefense del servidor; ver CombatConfig.Movement.Block/Parry).
--
-- Restaurar la velocidad: este módulo solo LIMITA el vector de movimiento mientras hay una fase activa. Al volver a
-- "None" simplemente deja de escribir, así que la velocidad del jugador (caminar / sprint, que decide SprintController)
-- vuelve sola y nunca queda un valor viejo. Prioridad de fases (la resuelve init.local): Stunned > dash > ataque > Parry > Block.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatConfig = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("CombatConfig"))

local player = Players.LocalPlayer

local RENDER_STEP_NAME = "CombatMovementController"

local MovementController = {}

-- Vector de movimiento del jugador desde los controles predeterminados.
local controls = nil
do
	local ok, result = pcall(function()
		local playerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
		return require(playerModule):GetControls()
	end)
	if ok then
		controls = result
	else
		warn("[MovementController] No se pudo acceder a los controles; se usará Humanoid.MoveDirection.")
	end
end

-- Provider de fase. Por defecto lee el atributo del servidor.
local getPhase = function(): string
	local character = player.Character
	return character and character:GetAttribute("CombatMovePhase") or "None"
end

-- Estado de lo que este módulo modifica temporalmente, para restaurarlo siempre.
local lastHumanoid: Humanoid? = nil
local jumpOverridden = false

-- [v2.2] Tope de velocidad suavizado: baja gradualmente (CombatConfig.Movement.SlowdownRate) en vez de cortar de golpe.
local currentCap: number? = nil

-- [v2.2] Empuje recibido (knockback). Lo pide el servidor al cliente dueño del personaje (init.local, Kind = "Knockback").
local knockback: any = nil
local savedJumpEnabled = true
local started = false

local function flatten(vector: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return Vector3.zero
	end
	return flat.Unit
end

-- Dirección de movimiento en el mundo (magnitud <= 1), según la cámara.
local function getWorldMoveDirection(humanoid: Humanoid): Vector3
	if controls then
		local moveVector: Vector3 = controls:GetMoveVector()
		if moveVector.Magnitude < 1e-3 then
			return Vector3.zero
		end
		local cameraCFrame = workspace.CurrentCamera.CFrame
		local right = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)
		right = if right.Magnitude > 1e-3 then right.Unit else Vector3.xAxis
		local look = Vector3.yAxis:Cross(right)
		return right * moveVector.X + look * -moveVector.Z
	end
	return humanoid.MoveDirection
end

local function getPhaseConfig(character: Model, phase: string)
	if phase == "Stunned" then
		return CombatConfig.Movement.Stunned
	elseif phase == "DashActive" then
		return CombatConfig.Movement.Dash.Active
	elseif phase == "DashRecovery" then
		return CombatConfig.Movement.Dash.Recovery
	elseif phase == "Block" then
		return CombatConfig.Movement.Block
	elseif phase == "Parry" then
		return CombatConfig.Movement.Parry
	end
	local profileName = character:GetAttribute("CombatMoveProfile") or "Light"
	local profile = CombatConfig.Movement.Profiles[profileName] or CombatConfig.Movement.Profiles.Light
	return profile[phase]
end

local function restoreJump(humanoid: Humanoid)
	if jumpOverridden then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, savedJumpEnabled)
		jumpOverridden = false
	end
end

local function destroyKnockback()
	if knockback then
		knockback.velocity:Destroy()
		knockback.attachment:Destroy()
		knockback = nil
	end
end

-- direction: dirección horizontal del empuje; distance: studs totales aproximados; duration: segundos.
-- La velocidad parte alta y decae linealmente a 0 (recorre ~distance). Las colisiones las resuelve la física.
function MovementController.ApplyKnockback(direction: any, distance: any, duration: any)
	if typeof(direction) ~= "Vector3" or typeof(distance) ~= "number" or typeof(duration) ~= "number" then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return
	end

	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	distance = math.clamp(distance, 0, 20)
	duration = math.clamp(duration, 0.05, 0.6)
	if distance <= 0 then
		return
	end

	destroyKnockback()

	local attachment = Instance.new("Attachment")
	attachment.Name = "KnockbackAttachment"
	attachment.Parent = root

	local force = root.AssemblyMass * 20000
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "KnockbackVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.MaxAxesForce = Vector3.new(force, 0, force)
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = root

	knockback = {
		root = root,
		attachment = attachment,
		velocity = velocity,
		direction = flat.Unit,
		startSpeed = 2 * distance / duration,
		startTime = os.clock(),
		duration = duration,
	}
end

local function updateKnockback()
	if not knockback then
		return
	end
	local t = (os.clock() - knockback.startTime) / knockback.duration
	if t >= 1 or not knockback.root.Parent then
		destroyKnockback()
	else
		knockback.velocity.VectorVelocity = knockback.direction * (knockback.startSpeed * (1 - t))
	end
end

local function step(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		destroyKnockback()
		currentCap = nil
		return
	end
	updateKnockback()

	-- Personaje nuevo (respawn): descartar el estado del anterior.
	if humanoid ~= lastHumanoid then
		lastHumanoid = humanoid
		jumpOverridden = false
	end

	local phase = getPhase() or "None"
	local phaseConfig = if phase ~= "None" then getPhaseConfig(character, phase) else nil
	if phaseConfig == nil then
		currentCap = nil -- sin fase activa: no se limita nada y la velocidad (caminar / sprint) vuelve sola
	end

	-- Salto: bloqueado durante fases restringidas (salvo AllowJump global o de la propia fase: Block / Parry).
	local jumpAllowed = CombatConfig.Movement.AllowJump or (phaseConfig ~= nil and phaseConfig.AllowJump == true)
	if phaseConfig ~= nil and not jumpAllowed then
		if not jumpOverridden then
			savedJumpEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
			jumpOverridden = true
		end
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	elseif jumpOverridden then
		restoreJump(humanoid)
	end

	-- Movimiento limitado: se aplica después de los controles predeterminados cada fotograma.
	if phaseConfig ~= nil then
		local facing = flatten(root.CFrame.LookVector)
		if facing == Vector3.zero then
			return
		end
		local right = facing:Cross(Vector3.yAxis)

		local worldDirection = getWorldMoveDirection(humanoid)
		local forwardAmount = worldDirection:Dot(facing)
		local lateralAmount = worldDirection:Dot(right)

		forwardAmount *= if forwardAmount >= 0 then phaseConfig.Forward else phaseConfig.Backward
		lateralAmount *= phaseConfig.Lateral

		local move = facing * forwardAmount + right * lateralAmount

		-- Tope absoluto en studs/s: el sprint no da ventaja durante la acción.
		-- [v2.2] Frenada progresiva: si el tope nuevo es menor que la velocidad actual (WalkSpeed, p. ej. sprint 24)
		-- baja a SlowdownRate studs/s por segundo. Los topes 0 (stun, dash activo) y las subidas son inmediatos.
		local targetCap = phaseConfig.MaxSpeed
		local cap = currentCap or math.max(humanoid.WalkSpeed, targetCap)
		if targetCap <= 0 or cap <= targetCap then
			cap = targetCap
		else
			cap = math.max(targetCap, cap - CombatConfig.Movement.SlowdownRate * dt)
		end
		currentCap = cap
		local maxMagnitude = cap / math.max(humanoid.WalkSpeed, 0.01)
		if move.Magnitude > maxMagnitude then
			move = if maxMagnitude <= 0 then Vector3.zero else move.Unit * maxMagnitude
		end

		humanoid:Move(move, false)
	end
end

-- providers = { getPhase = function() -> string }  (opcional; por defecto lee CombatMovePhase)
function MovementController.Start(providers)
	if started then
		return
	end
	started = true

	if providers and providers.getPhase then
		getPhase = providers.getPhase
	end

	-- Después de los controles predeterminados (Input), para que esta limitación prevalezca.
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Input.Value + 1, step)
end

function MovementController.Stop()
	if not started then
		return
	end
	started = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	destroyKnockback()
	currentCap = nil

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		restoreJump(humanoid)
	end
	jumpOverridden = false
	lastHumanoid = nil
end

return MovementController