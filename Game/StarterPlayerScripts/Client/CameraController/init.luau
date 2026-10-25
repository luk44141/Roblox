--[[
	CameraController  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > CameraController
	Hijos: CameraConfig, ShiftLock

	ÚNICO escritor de CurrentCamera (CFrame, Focus, FieldOfView, CameraType).
	LockOn YA NO escribe la cámara: solo expone el objetivo por el provider getLockTarget.

	Rotación: el mouse rota yaw/pitch solo con el cursor bloqueado (CursorController), igual en modo
	normal y en ShiftLock. Con el cursor libre la orientación queda fija y la cámara solo sigue la posición.

	[v2] Encuadre: la cámara normal usa CameraConfig.NormalFraming (hombro + elevación + distancia, parecido al
	ShiftLock). Se mezcla con el del ShiftLock según su transición y se anula con lock-on, así que hay UN solo
	cálculo de cámara y la orientación del personaje (CharacterOrientation) sigue leyendo solo yaw / lock-on.
	La mira (punto central) la dibuja ShiftLock en ambos modos.

	Con lock-on activo:
	  - yaw/pitch convergen suavemente hacia el objetivo (el mouse no rota); al soltarlo no hay salto.
	  - el zoom (rueda) sigue funcionando.
	  - ShiftLock queda suprimido (sin hombro ni punto) pero conserva su estado: reaparece al soltar el lock-on.
	  - la orientación del personaje la decide CharacterOrientation (mira al objetivo).

	providers = {
		isRotationActive() -> boolean
		isSprinting()      -> boolean
		isDashing()        -> boolean
		getLockTarget()    -> (BasePart?, pitchDegrees?, smoothing?)
	}
	Sistema de ángulos: pitch positivo = cámara POR ENCIMA del foco. Sin roll: horizonte siempre recto.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local cfg = require(script:WaitForChild("CameraConfig"))
local ShiftLock = require(script:WaitForChild("ShiftLock"))

local RENDER_STEP_NAME = "CustomCameraUpdate"
local MAX_DELTA_TIME = 1 / 15
local MAX_CAST_STEPS = 4
local TWO_PI = math.pi * 2

local MIN_PITCH = math.rad(cfg.MinPitch)
local MAX_PITCH = math.rad(cfg.MaxPitch)

local CameraController = {}

----------------------------------------------------------------------
-- Estado
----------------------------------------------------------------------

local providers = nil
local shiftLock = nil
local started = false

local character, humanoid, root = nil, nil, nil
local characterConnections = {}
local connections = {}

local yaw = 0
local pitch = math.rad(cfg.DefaultPitch)
local zoomTarget = cfg.DefaultDistance
local zoom = cfg.DefaultDistance
local focus = Vector3.zero
local followSharpnessY = cfg.FollowSharpnessY

local collisionFactor = 1
local bobPhase, bobStrength = 0, 0
local strafe = 0
local landOffset, landVelocity = 0, 0
local wasAirborne, peakDownSpeed = false, 0
local sprintFovBlend, dashBlend = 0, 0
local lockBlend = 0 -- [v2] 0..1: cuánto del encuadre normal se anula por el lock-on

local wasRotating = false

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.RespectCanCollide = true
raycastParams.IgnoreWater = true

local offsetBuffer = { Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero } -- Reutilizado: sin tablas por frame

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------

local function smoothAlpha(sharpness, dt)
	return 1 - math.exp(-sharpness * dt)
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

----------------------------------------------------------------------
-- Colisión con paredes (5 rayos paralelos: centro + 4 laterales)
----------------------------------------------------------------------

local function shouldIgnore(part)
	if part:IsA("Terrain") then
		return false
	end
	if part.Transparency >= cfg.Collision.IgnoreTransparency then
		return true
	end
	-- Otros personajes/NPCs (incluidos dummies) no deben empujar la cámara
	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- Devuelve la distancia al primer obstáculo válido, o nil si el camino está libre.
local function castAlong(origin, direction, length)
	local traveled = 0
	for _ = 1, MAX_CAST_STEPS do
		local start = origin + direction * traveled
		local result = workspace:Raycast(start, direction * (length - traveled), raycastParams)
		if not result then
			return nil
		end

		local hitDistance = traveled + (result.Position - start).Magnitude
		if not shouldIgnore(result.Instance) then
			return hitDistance
		end

		traveled = hitDistance + 0.05
		if traveled >= length then
			return nil
		end
	end
	return nil
end

local function getObstacleDistance(origin, direction, length, rotation)
	local closest = castAlong(origin, direction, length)

	local radius = cfg.Collision.Radius
	local rightOffset = rotation.RightVector * radius
	local upOffset = rotation.UpVector * radius
	offsetBuffer[1] = rightOffset
	offsetBuffer[2] = -rightOffset
	offsetBuffer[3] = upOffset
	offsetBuffer[4] = -upOffset

	for i = 1, 4 do
		local distance = castAlong(origin + offsetBuffer[i], direction, length)
		if distance and (closest == nil or distance < closest) then
			closest = distance
		end
	end

	return closest
end

----------------------------------------------------------------------
-- Personaje
----------------------------------------------------------------------

local function resetCamera()
	local look = root.CFrame.LookVector
	yaw = math.atan2(-look.X, -look.Z) -- Cámara detrás del personaje
	pitch = math.rad(cfg.DefaultPitch)
	focus = root.Position + Vector3.new(0, cfg.FocusHeight, 0)
	followSharpnessY = cfg.FollowSharpnessY

	collisionFactor = 1
	bobPhase, bobStrength = 0, 0
	strafe = 0
	landOffset, landVelocity = 0, 0
	wasAirborne, peakDownSpeed = false, 0
	sprintFovBlend, dashBlend = 0, 0
	lockBlend = 0
	wasRotating = false
end

local function clearCharacter()
	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)

	character, humanoid, root = nil, nil, nil
	wasRotating = false
	if shiftLock then
		shiftLock:SetCharacter(nil)
	end
end

-- Llamar con (humanoid, root, character) al aparecer y con nil al removerlo.
function CameraController.SetCharacter(newHumanoid, newRoot, newCharacter)
	clearCharacter()
	if not newHumanoid or not newRoot or not newCharacter or not shiftLock then
		return
	end

	character, humanoid, root = newCharacter, newHumanoid, newRoot
	raycastParams.FilterDescendantsInstances = { newCharacter }
	shiftLock:SetCharacter(newHumanoid)

	table.insert(
		characterConnections,
		newHumanoid.Died:Connect(function()
			shiftLock:SetEnabled(false)
		end)
	)

	resetCamera()
end

----------------------------------------------------------------------
-- API para otros sistemas
----------------------------------------------------------------------

function CameraController.GetYaw()
	return yaw
end

function CameraController.SetYaw(newYaw)
	yaw = newYaw
end

-- true si el ShiftLock está activado Y no suprimido por lock-on (lo usa CharacterOrientation).
function CameraController.IsShiftLockActive()
	if shiftLock == nil or not shiftLock.Enabled then
		return false
	end
	local lockRoot = nil
	if providers and providers.getLockTarget then
		lockRoot = providers.getLockTarget()
	end
	return lockRoot == nil
end

function CameraController.GetShiftLock()
	return shiftLock
end

----------------------------------------------------------------------
-- Entrada (solo zoom: la rotación viene del delta del mouse bloqueado)
----------------------------------------------------------------------

local function onInputChanged(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		zoomTarget = math.clamp(zoomTarget - input.Position.Z * cfg.ZoomStep, cfg.MinZoom, cfg.MaxZoom)
	end
end

----------------------------------------------------------------------
-- Actualización por frame
----------------------------------------------------------------------

local function onRenderStep(deltaTime)
	local dt = math.min(deltaTime, MAX_DELTA_TIME)

	local camera = workspace.CurrentCamera
	if not camera or not humanoid or not root or not root.Parent then
		wasRotating = false
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local rotationActive = providers.isRotationActive()
	local dashing = providers.isDashing()
	local sprinting = providers.isSprinting()

	local lockRoot, lockPitchDegrees, lockSmoothing = nil, nil, nil
	if providers.getLockTarget then
		lockRoot, lockPitchDegrees, lockSmoothing = providers.getLockTarget()
	end
	local lockActive = lockRoot ~= nil and lockRoot.Parent ~= nil

	-- 1) Rotación: lock-on (hacia el objetivo) o mouse (idéntica en modo normal y ShiftLock).
	-- GetMouseDelta() ya viene escalado por la sensibilidad del jugador: solo píxeles -> radianes.
	if lockActive then
		local toTarget = lockRoot.Position - focus
		if toTarget.X * toTarget.X + toTarget.Z * toTarget.Z > 0.01 then
			local alpha = smoothAlpha(lockSmoothing or 7, dt)
			local targetYaw = math.atan2(-toTarget.X, -toTarget.Z)
			local delta = (targetYaw - yaw + math.pi) % TWO_PI - math.pi
			yaw += delta * alpha

			-- CameraPitch del lock-on usa "negativo = mira hacia abajo"; aquí pitch positivo = cámara arriba
			local targetPitch = math.rad(-(lockPitchDegrees or -12))
			pitch += (targetPitch - pitch) * alpha
			pitch = math.clamp(pitch, MIN_PITCH, MAX_PITCH)
		end
	elseif rotationActive then
		local delta = UserInputService:GetMouseDelta()
		if wasRotating then -- Se ignora el primer frame: el cursor pega un salto al bloquearse
			local sens = cfg.Sensitivity
			yaw -= delta.X * sens.X
			pitch += delta.Y * sens.Y * (if cfg.InvertY then -1 else 1)
			pitch = math.clamp(pitch, MIN_PITCH, MAX_PITCH)
		end
	end
	wasRotating = rotationActive and not lockActive

	-- 2) Zoom suavizado
	zoom += (zoomTarget - zoom) * smoothAlpha(cfg.ZoomSharpness, dt)

	-- 3) Shift Lock: transición y hombro (suprimido con lock-on). La mira también se muestra en cámara normal.
	local alive = humanoid.Health > 0
	local blend, shoulder = shiftLock:Update(dt, rotationActive and alive, lockActive)
	local effectScale = lerp(1, cfg.ShiftLock.EffectScale, blend)

	-- [v2] Peso del encuadre de la cámara normal: se apaga con ShiftLock (lo reemplaza su propio encuadre) y con lock-on
	-- (el lock-on centra la cámara entre el personaje y el objetivo). Ambas mezclas son suaves: sin saltos.
	local nf = cfg.NormalFraming
	lockBlend += ((if lockActive then 1 else 0) - lockBlend) * smoothAlpha(nf.LockOnSharpness, dt)
	local normalWeight = if nf.Enabled then (1 - blend) * (1 - lockBlend) else 0

	-- 4) Movimiento del personaje (se lee ANTES del seguimiento: este usa la velocidad vertical)
	local velocity = root.AssemblyLinearVelocity
	local grounded = alive and humanoid.FloorMaterial ~= Enum.Material.Air
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local speedFraction = math.clamp(horizontalSpeed / math.max(humanoid.WalkSpeed, 1), 0, 1)
	local moveDirection = humanoid.MoveDirection
	local moveStrength = if alive then math.min(speedFraction, moveDirection.Magnitude) else 0

	-- 5) Seguimiento suave: XZ con sharpness fijo, Y con sharpness adaptativo a la velocidad vertical
	local targetFocus = root.Position + Vector3.new(0, cfg.FocusHeight, 0)
	if (targetFocus - focus).Magnitude > cfg.TeleportSnapDistance then
		focus = targetFocus
		followSharpnessY = cfg.FollowSharpnessY
	else
		local vf = cfg.VerticalFollow

		local excessSpeed = math.max(math.abs(velocity.Y) - vf.StartSpeed, 0)
		local sharpnessTarget = math.min(cfg.FollowSharpnessY + excessSpeed * vf.Gain, vf.MaxSharpness)
		local rate = if sharpnessTarget > followSharpnessY then vf.Attack else vf.Release
		followSharpnessY += (sharpnessTarget - followSharpnessY) * smoothAlpha(rate, dt)

		local alphaXZ = smoothAlpha(lerp(cfg.FollowSharpnessXZ, cfg.ShiftLock.FollowSharpnessXZ, blend), dt)
		local alphaY = smoothAlpha(followSharpnessY, dt)

		local newY = focus.Y + (targetFocus.Y - focus.Y) * alphaY
		newY = math.clamp(newY, targetFocus.Y - vf.MaxLag, targetFocus.Y + vf.MaxLag)

		focus = Vector3.new(
			focus.X + (targetFocus.X - focus.X) * alphaXZ,
			newY,
			focus.Z + (targetFocus.Z - focus.Z) * alphaXZ
		)
	end

	-- Solo yaw + pitch: sin componente de roll, el horizonte siempre queda recto
	local rotation = CFrame.Angles(0, yaw, 0) * CFrame.Angles(-pitch, 0, 0)

	-- 6) Efectos de FOV / distancia (sprint y dash)
	local sprintTarget = if cfg.SprintFov.Enabled and sprinting and not dashing then 1 else 0
	sprintFovBlend += (sprintTarget - sprintFovBlend) * smoothAlpha(cfg.SprintFov.Sharpness, dt)

	local dashTarget = if dashing then 1 else 0
	local dashRate = if dashTarget > dashBlend then cfg.DashFov.Attack else cfg.DashFov.Release
	dashBlend += (dashTarget - dashBlend) * smoothAlpha(dashRate, dt)

	-- Balanceo al caminar
	local bobTarget = if cfg.Bob.Enabled and grounded and not dashing then moveStrength else 0
	bobStrength += (bobTarget - bobStrength) * smoothAlpha(cfg.Bob.Sharpness, dt)
	bobPhase = (bobPhase + dt * cfg.Bob.Frequency * bobStrength) % TWO_PI
	local bobX = math.sin(bobPhase) * cfg.Bob.HorizontalAmplitude * bobStrength
	local bobY = math.sin(bobPhase * 2) * cfg.Bob.VerticalAmplitude * bobStrength

	-- Impacto al aterrizar (se suprime durante el dash: FloorMaterial puede parpadear)
	if cfg.Landing.Enabled then
		if dashing then
			wasAirborne, peakDownSpeed = false, 0
		elseif grounded then
			if wasAirborne and peakDownSpeed > cfg.Landing.MinFallSpeed then
				local excess = math.min(peakDownSpeed, cfg.Landing.MaxFallSpeed) - cfg.Landing.MinFallSpeed
				landVelocity = -excess * cfg.Landing.Strength
			end
			peakDownSpeed = 0
			wasAirborne = false
		else
			peakDownSpeed = math.max(peakDownSpeed, -velocity.Y)
			wasAirborne = true
		end

		local acceleration = -cfg.Landing.Stiffness * landOffset - cfg.Landing.Damping * landVelocity
		landVelocity += acceleration * dt
		landOffset = math.clamp(landOffset + landVelocity * dt, -cfg.Landing.MaxOffset, cfg.Landing.MaxOffset)
	else
		landOffset, landVelocity = 0, 0
		wasAirborne, peakDownSpeed = false, 0
	end

	-- Desplazamiento lateral respecto de la cámara (+ = derecha)
	local strafeTarget = 0
	if cfg.Strafe.Enabled and not dashing then
		strafeTarget = moveDirection:Dot(rotation.RightVector) * moveStrength * cfg.Strafe.MaxOffset
	end
	strafe += (strafeTarget - strafe) * smoothAlpha(cfg.Strafe.Sharpness, dt)

	-- 7) Posición deseada de la cámara
	local origin = focus + rotation.RightVector * strafe

	local sl = cfg.ShiftLock
	local pullback = if cfg.DashPullback.Enabled then cfg.DashPullback.Distance * dashBlend else 0
	local distanceScale = lerp(lerp(1, nf.DistanceScale, normalWeight), sl.DistanceScale, blend)
	local distance = zoom * distanceScale + pullback
	local shoulderOffset = nf.ShoulderOffset * normalWeight + sl.ShoulderOffset * blend
	local verticalOffset = nf.VerticalOffset * normalWeight + sl.VerticalOffset * blend
	local localOffset = Vector3.new(shoulder * shoulderOffset, verticalOffset, distance)
	local desiredPosition = (CFrame.new(origin) * rotation) * localOffset

	local toCamera = desiredPosition - origin
	local desiredLength = toCamera.Magnitude
	local direction = toCamera / desiredLength

	-- 8) Colisión: se acerca al instante, se aleja de forma suave
	local padding = cfg.Collision.Padding
	local hitDistance = getObstacleDistance(origin, direction, desiredLength + padding, rotation)
	local targetFactor = 1
	if hitDistance then
		targetFactor = math.clamp((hitDistance - padding) / desiredLength, cfg.Collision.MinDistance / desiredLength, 1)
	end

	if targetFactor < collisionFactor then
		collisionFactor = targetFactor
	else
		collisionFactor += (targetFactor - collisionFactor) * smoothAlpha(cfg.Collision.RecoverSharpness, dt)
	end

	local safePosition = origin + direction * (desiredLength * collisionFactor)

	-- 9) CFrame final: orientación + balanceo/impacto (solo traslaciones, sin roll)
	camera.CFrame = CFrame.new(safePosition) * rotation * CFrame.new(bobX * effectScale, (bobY + landOffset) * effectScale, 0)
	camera.Focus = CFrame.new(focus)

	local fov = lerp(cfg.FieldOfView, sl.FieldOfView, blend)
	if cfg.SprintFov.Enabled then
		fov += cfg.SprintFov.Amount * sprintFovBlend
	end
	if cfg.DashFov.Enabled then
		fov += cfg.DashFov.Amount * dashBlend
	end
	camera.FieldOfView = math.clamp(fov, 20, 110)
end

----------------------------------------------------------------------
-- Inicio y limpieza
----------------------------------------------------------------------

function CameraController.Start(newProviders)
	if started then
		return
	end
	started = true
	providers = newProviders
	shiftLock = ShiftLock.new(cfg.ShiftLock)

	table.insert(connections, UserInputService.InputChanged:Connect(onInputChanged))

	-- Un frame después del paso de cámara por defecto, para que nuestro CFrame sea el último
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

function CameraController.Destroy()
	if not started then
		return
	end
	started = false

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	clearCharacter()
	if shiftLock then
		shiftLock:Destroy()
		shiftLock = nil
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
end

return CameraController