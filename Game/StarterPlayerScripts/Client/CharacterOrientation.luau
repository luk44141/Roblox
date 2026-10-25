--[[
	CharacterOrientation  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > CharacterOrientation

	ÚNICO dueño de Humanoid.AutoRotate y del yaw del HumanoidRootPart.
	MovementController (combate) y LockOn YA NO los tocan: solo le informan estado por providers.

	Prioridad de política (la primera que aplique):
	  1. Override (dash)           -> yaw fijo; solo se corrige si el yaw se desvía de verdad.
	  2. Stun o DashActive         -> "Hold": no gira (AutoRotate desactivado).
	  3. Lock-on con objetivo      -> mira al objetivo (solo yaw, sin inclinarse).
	  4. ShiftLock activo          -> mira al yaw de la cámara.
	  5. Acción de combate         -> mira al yaw de la cámara (la hitbox sale del root).
	  6. Modo normal               -> MovementConfig.Orientation.NormalPolicy.

	providers = {
		getCameraYaw()      -> number
		isShiftLockActive() -> boolean
		getLockTarget()     -> (BasePart?, turnSharpness?)
		getCombatPhase()    -> "None" | "Windup" | "Active" | "Recovery" | "ComboWindow" | "Stunned" | "DashActive" | "DashRecovery"
	}
]]

local RunService = game:GetService("RunService")

local cfg = require(script.Parent:WaitForChild("MovementConfig")).Orientation

local RENDER_STEP_NAME = "CharacterOrientationUpdate"
local TWO_PI = math.pi * 2

local COMBAT_ACTION_PHASES = {
	Windup = true,
	Active = true,
	Recovery = true,
	ComboWindow = true,
}

local CharacterOrientation = {}

local providers = nil
local humanoid, root = nil, nil
local characterYaw = nil
local overrideYaw = nil
local autoRotateDisabled = false
local previousAutoRotate = true
local started = false

local function smoothAlpha(sharpness, dt)
	return 1 - math.exp(-sharpness * dt)
end

local function angleDelta(target, current)
	return (target - current + math.pi) % TWO_PI - math.pi
end

local function setAutoRotateDisabled(disabled)
	if not humanoid then
		return
	end
	if disabled and not autoRotateDisabled then
		previousAutoRotate = humanoid.AutoRotate
		humanoid.AutoRotate = false
		autoRotateDisabled = true
	elseif not disabled and autoRotateDisabled then
		humanoid.AutoRotate = previousAutoRotate
		autoRotateDisabled = false
	end
end

local function currentYaw()
	local look = root.CFrame.LookVector
	return math.atan2(-look.X, -look.Z)
end

local function writeYaw(yaw)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
end

-- Llamar con (humanoid, root) al aparecer un personaje y con (nil, nil) al removerlo.
function CharacterOrientation.SetCharacter(newHumanoid, newRoot)
	if humanoid and autoRotateDisabled and humanoid.Parent then
		humanoid.AutoRotate = previousAutoRotate
	end
	autoRotateDisabled = false
	characterYaw = nil
	overrideYaw = nil
	humanoid, root = newHumanoid, newRoot
end

-- Fija el yaw del personaje (dash) y lo mantiene hasta EndOverride.
function CharacterOrientation.BeginOverride(yaw)
	if not humanoid or not root or not root.Parent then
		return
	end
	overrideYaw = yaw
	characterYaw = yaw
	setAutoRotateDisabled(true)
	writeYaw(yaw)
end

-- Libera el yaw fijo: el control vuelve a la política normal en el siguiente frame.
function CharacterOrientation.EndOverride()
	overrideYaw = nil
	characterYaw = nil
end

-- Dirección de movimiento en el espacio del personaje: X = derecha, Z = adelante (para blends de animación).
function CharacterOrientation.GetLocalMoveDirection()
	if not humanoid or not root then
		return Vector3.zero
	end
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.01 then
		return Vector3.zero
	end
	local localDir = root.CFrame:VectorToObjectSpace(moveDirection)
	return Vector3.new(localDir.X, 0, -localDir.Z)
end

local function onRenderStep(deltaTime)
	local dt = math.min(deltaTime, 1 / 15)

	if not humanoid or not root or not root.Parent then
		characterYaw = nil
		return
	end
	if humanoid.Health <= 0 or humanoid.Sit then
		characterYaw = nil
		return
	end

	-- 1) Override (dash): sin escrituras por frame salvo que el yaw se desvíe
	if overrideYaw then
		setAutoRotateDisabled(true)
		if math.abs(angleDelta(overrideYaw, currentYaw())) > cfg.OverrideDriftTolerance then
			writeYaw(overrideYaw)
		end
		characterYaw = overrideYaw
		return
	end

	local phase = providers.getCombatPhase() or "None"

	-- 2) Stun o dash sin alineación: no gira
	if phase == "Stunned" or phase == "DashActive" then
		setAutoRotateDisabled(true)
		characterYaw = nil
		return
	end

	local targetYaw = nil
	local sharpness = cfg.NormalTurnSharpness

	local lockRoot, lockSharpness = providers.getLockTarget()
	if lockRoot and lockRoot.Parent then
		-- 3) Lock-on
		local offset = lockRoot.Position - root.Position
		if offset.X * offset.X + offset.Z * offset.Z > 0.0025 then
			targetYaw = math.atan2(-offset.X, -offset.Z)
		end
		sharpness = lockSharpness or cfg.NormalTurnSharpness
	elseif providers.isShiftLockActive() then
		-- 4) ShiftLock
		targetYaw = providers.getCameraYaw()
		sharpness = cfg.ShiftLockTurnSharpness
	elseif COMBAT_ACTION_PHASES[phase] then
		-- 5) Acción de combate
		targetYaw = providers.getCameraYaw()
		sharpness = cfg.CombatTurnSharpness
	else
		-- 6) Modo normal
		local policy = cfg.NormalPolicy
		if policy == "Free" then
			setAutoRotateDisabled(false)
			characterYaw = nil
			return
		end

		if policy == "FaceCameraWhenMoving" and humanoid.MoveDirection.Magnitude < cfg.MovingThreshold then
			setAutoRotateDisabled(true) -- Quieto: conserva la orientación actual
			characterYaw = nil
			return
		end

		targetYaw = providers.getCameraYaw()
		sharpness = cfg.NormalTurnSharpness
	end

	setAutoRotateDisabled(true)

	if targetYaw == nil then
		characterYaw = nil
		return
	end

	if characterYaw == nil then
		characterYaw = currentYaw()
	end

	-- Giro por el camino más corto; no se escribe si el error es despreciable
	local delta = angleDelta(targetYaw, characterYaw)
	if math.abs(delta) < 0.0005 then
		return
	end
	characterYaw += delta * smoothAlpha(sharpness, dt)
	writeYaw(characterYaw)
end

function CharacterOrientation.Start(newProviders)
	if started then
		return
	end
	started = true
	providers = newProviders
	-- Después de la cámara (Camera + 1)
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 2, onRenderStep)
end

function CharacterOrientation.Destroy()
	if not started then
		return
	end
	started = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	CharacterOrientation.SetCharacter(nil, nil)
end

return CharacterOrientation