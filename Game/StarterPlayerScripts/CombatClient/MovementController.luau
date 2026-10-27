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

-- [v2.3] Cooldown del salto (CombatConfig.Jump.Cooldown). Se detecta al entrar en el estado Jumping y se aplica
-- deshabilitando ese estado hasta que pase el tiempo (igual que el bloqueo de salto de las fases de combate).
local jumpCooldownUntil = 0
local stateConnection: RBXScriptConnection? = nil

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
	elseif phase == "AirCombo" then
		return CombatConfig.Movement.AirCombo -- [v2.7]
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

-- [v2.5] Agarre (R en el aire): el rival queda sujeto delante del que lo agarra con un AlignPosition local.
local grab: any = nil

local function destroyGrab()
	if grab then
		grab.align:Destroy()
		grab.attachment0:Destroy()
		grab = nil
	end
end

-- [v2.4] Flotar del combo aéreo (ver StartAirHang)
local hover: any = nil
local comboJumpLockUntil = 0

local function destroyHover()
	if hover then
		hover.velocity:Destroy()
		hover.attachment:Destroy()
		hover = nil
	end
end

local function updateHover()
	if not hover then
		return
	end
	local t = os.clock() - hover.startTime
	if t >= hover.maxTime or not hover.root.Parent then
		destroyHover()
		return
	end
	local vy = hover.riseSpeed * (1 - math.min(t / hover.riseTime, 1))
	hover.velocity.VectorVelocity = Vector3.new(0, vy, 0)
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
-- [v2.3] Segundos que faltan para poder volver a saltar (0 = listo). Lo usa el HUD.
function MovementController.GetJumpCooldownRemaining(): number
	return math.max(jumpCooldownUntil - os.clock(), 0)
end

-- [v2.4] Uppercut: sube RiseSpeed (decae a 0 en RiseTime) y se queda FLOTANDO hasta StopAirHang (o MaxTime, por seguridad).
-- Se hace con un LinearVelocity solo en el eje Y, que sostiene la altura mientras dura el combo aéreo.
function MovementController.StartAirHang(riseSpeed: any, riseTime: any, maxTime: any)
	if typeof(riseSpeed) ~= "number" or typeof(riseTime) ~= "number" then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return
	end

	destroyKnockback()
	destroyHover()
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

	local attachment = Instance.new("Attachment")
	attachment.Name = "AirHangAttachment"
	attachment.Parent = root

	local force = root.AssemblyMass * 20000
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "AirHangVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.MaxAxesForce = Vector3.new(0, force, 0)
	velocity.VectorVelocity = Vector3.new(0, math.clamp(riseSpeed, 0, 120), 0)
	velocity.Parent = root

	hover = {
		root = root,
		attachment = attachment,
		velocity = velocity,
		riseSpeed = math.clamp(riseSpeed, 0, 120),
		riseTime = math.max(riseTime, 0.05),
		startTime = os.clock(),
		maxTime = if typeof(maxTime) == "number" then math.clamp(maxTime, 1, 15) else 8,
	}
end

function MovementController.StopAirHang()
	destroyHover()
end

-- [v2.5] holder: el personaje que agarra; offset: posición del agarrado en el espacio local de holder (adelante = -Z).
function MovementController.StartGrab(holder: any, duration: any, offset: any)
	if typeof(holder) ~= "Instance" or typeof(duration) ~= "number" or typeof(offset) ~= "Vector3" then
		return
	end
	local holderRoot = holder:FindFirstChild("HumanoidRootPart")
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not holderRoot or not holderRoot:IsA("BasePart") then
		return
	end
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return
	end

	destroyHover()
	destroyKnockback()
	destroyGrab()

	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "GrabAttachment0"
	attachment0.Parent = root

	-- [v2.9] OneAttachment: el objetivo es un PUNTO del mundo que se actualiza cada fotograma. Con TwoAttachment el
	-- AlignPosition empujaba también al que agarra (reacción) y los dos salían volando.
	local align = Instance.new("AlignPosition")
	align.Name = "GrabAlign"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment0
	align.Position = (holderRoot.CFrame * CFrame.new(offset)).Position
	align.RigidityEnabled = false
	align.ApplyAtCenterOfMass = true
	align.MaxForce = root.AssemblyMass * 20000
	align.MaxVelocity = 100
	align.Responsiveness = 60
	align.Parent = root

	root.AssemblyLinearVelocity = Vector3.zero
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

	grab = {
		align = align,
		attachment0 = attachment0,
		holderRoot = holderRoot,
		offset = offset,
		endTime = os.clock() + math.clamp(duration, 0.1, 6) + 1,
	}
end

function MovementController.StopGrab()
	destroyGrab()
end

-- [v2.3] Estampado: velocidad hacia abajo (anula el movimiento horizontal).
function MovementController.ApplySlam(speed: any)
	if typeof(speed) ~= "number" then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return
	end
	destroyKnockback()
	destroyHover() -- el estampado corta el flotar
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	root.AssemblyLinearVelocity = Vector3.new(0, -math.clamp(speed, 0, 200), 0)
end

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
		destroyHover()
		destroyGrab()
		currentCap = nil
		return
	end
	updateKnockback()
	updateHover()
	if grab and (os.clock() > grab.endTime or not grab.holderRoot.Parent) then
		destroyGrab() -- seguridad: si se pierde el aviso GrabEnd, el agarre no queda para siempre
	elseif grab then
		grab.align.Position = (grab.holderRoot.CFrame * CFrame.new(grab.offset)).Position -- sigue a quien agarra
	end

	-- Personaje nuevo (respawn): descartar el estado del anterior.
	if humanoid ~= lastHumanoid then
		lastHumanoid = humanoid
		jumpOverridden = false
		jumpCooldownUntil = 0
		if stateConnection then
			stateConnection:Disconnect()
		end
		stateConnection = humanoid.StateChanged:Connect(function(_, newState)
			if newState == Enum.HumanoidStateType.Jumping then
				jumpCooldownUntil = os.clock() + CombatConfig.Jump.Cooldown
			end
		end)
	end

	local phase = getPhase() or "None"
	local phaseConfig = if phase ~= "None" then getPhaseConfig(character, phase) else nil
	if phaseConfig == nil then
		currentCap = nil -- sin fase activa: no se limita nada y la velocidad (caminar / sprint) vuelve sola
	end

	-- Salto: bloqueado durante fases restringidas (salvo AllowJump global o de la propia fase: Block / Parry).
	local jumpAllowed = CombatConfig.Movement.AllowJump or (phaseConfig ~= nil and phaseConfig.AllowJump == true)
	-- [v2.4] Durante y justo después de cualquier fase de combate no se puede saltar (Espacio mantenido para el Uppercut).
	if phase == "Windup" or phase == "Active" or phase == "Recovery" or phase == "ComboWindow" then
		comboJumpLockUntil = os.clock() + CombatConfig.Jump.LockAfterCombat
	end
	local jumpOnCooldown = os.clock() < jumpCooldownUntil or os.clock() < comboJumpLockUntil -- [v2.3]
	if (phaseConfig ~= nil and not jumpAllowed) or jumpOnCooldown then
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
	destroyHover()
	destroyGrab()
	currentCap = nil
	if stateConnection then
		stateConnection:Disconnect()
		stateConnection = nil
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		restoreJump(humanoid)
	end
	jumpOverridden = false
	lastHumanoid = nil
end

return MovementController