--[[
	ShiftLock  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > CameraController > ShiftLock

	Estado del modo Shift Lock: alternancia, hombro, transición y punto central.
	NO toca el mouse, la cámara, Humanoid.AutoRotate ni el CFrame del personaje:
	  - el mouse y la cámara los maneja CameraController / CursorController
	  - la orientación del personaje la maneja CharacterOrientation (lee ShiftLock.Enabled)

	Con lock-on activo, CameraController lo "suprime" (suppressed = true): la transición vuelve a 0 y el punto
	se oculta, pero Enabled se conserva, así que al soltar el lock-on el ShiftLock reaparece solo.

	[v2] La mira (punto central) es la misma en ambos modos: se ve con ShiftLock activo y, si
	Dot.ShowInNormalMode es true, también en cámara normal. Dot.HideDuringLockOn la oculta durante el lock-on.
	Su visibilidad ya no depende de la transición del hombro sino de su propio fundido (Dot.FadeSharpness).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local ShiftLock = {}
ShiftLock.__index = ShiftLock

local function smoothAlpha(sharpness, dt)
	return 1 - math.exp(-sharpness * dt)
end

local function createDot(dotConfig)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "ShiftLockDot"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.None -- (0.5, 0.5) = centro real de la pantalla
	gui.DisplayOrder = 100
	gui.Enabled = false

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(dotConfig.Size, dotConfig.Size)
	dot.BackgroundColor3 = dotConfig.Color
	dot.BorderSizePixel = 0
	dot.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	local stroke = Instance.new("UIStroke")
	stroke.Color = dotConfig.OutlineColor
	stroke.Thickness = dotConfig.OutlineThickness
	stroke.Parent = dot

	gui.Parent = playerGui
	return gui, dot, stroke
end

function ShiftLock.new(config)
	local self = setmetatable({}, ShiftLock)

	self.config = config
	self.Enabled = false -- Lo leen CameraController y (vía CameraController) CharacterOrientation
	self.shoulder = if config.StartShoulder == "Left" then -1 else 1
	self.shoulderSmooth = self.shoulder
	self.blend = 0 -- 0..1 lineal; se suaviza con smoothstep al devolverlo
	self.dotAlpha = 0 -- [v2] 0..1: visibilidad de la mira
	self.humanoid = nil

	-- Guarda anti Alt+Tab (LeftAlt también se dispara al cambiar de ventana)
	self.lastToggleTime = -math.huge
	self.stateBeforeToggle = false

	self.dotGui, self.dot, self.dotStroke = createDot(config.Dot)

	self.connections = {
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			self:_onInputBegan(input, gameProcessed)
		end),
		UserInputService.WindowFocusReleased:Connect(function()
			if os.clock() - self.lastToggleTime < self.config.AltTabGuardTime then
				self:SetEnabled(self.stateBeforeToggle)
			end
		end),
	}

	return self
end

function ShiftLock:_onInputBegan(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == self.config.ToggleKey then
		self.stateBeforeToggle = self.Enabled
		self.lastToggleTime = os.clock()
		self:SetEnabled(not self.Enabled)
	elseif input.KeyCode == self.config.SwapShoulderKey and (self.Enabled or self.config.SwapInNormalMode) then
		self.shoulder = -self.shoulder
	end
end

-- Llamar con el humanoid al aparecer un personaje y con nil al removerlo. Reinicia el estado.
function ShiftLock:SetCharacter(humanoid)
	self.Enabled = false
	self.blend = 0
	self.dotAlpha = 0
	self.humanoid = humanoid
	self.dotGui.Enabled = false -- Sin personaje no hay Update: el punto no debe quedar visible
end

function ShiftLock:SetEnabled(enabled)
	if enabled == self.Enabled then
		return
	end

	if enabled then
		if not self.humanoid or self.humanoid.Health <= 0 then
			return
		end
		self.Enabled = true
	else
		self.Enabled = false
	end
end

-- dotAllowed: false cuando el cursor está libre (modo interfaz) o el personaje está muerto: no se muestra la mira.
-- suppressed: true mientras hay lock-on (la transición vuelve a 0 sin perder Enabled).
--   [v2] Con Dot.HideDuringLockOn = true, suppressed también oculta la mira.
-- Devuelve: transición suavizada (0..1) y hombro suavizado (-1 izquierdo .. 1 derecho)
function ShiftLock:Update(dt, dotAllowed, suppressed)
	local config = self.config

	local target = if self.Enabled and not suppressed then 1 else 0
	local step = dt / config.TransitionTime
	if self.blend < target then
		self.blend = math.min(self.blend + step, target)
	elseif self.blend > target then
		self.blend = math.max(self.blend - step, target)
	end
	local t = self.blend
	local eased = t * t * (3 - 2 * t) -- smoothstep: entra y sale suave

	self.shoulderSmooth += (self.shoulder - self.shoulderSmooth) * smoothAlpha(config.ShoulderSwapSharpness, dt)

	-- Punto central (la mira): visible con ShiftLock y, si ShowInNormalMode, también en cámara normal.
	local dotConfig = config.Dot
	local dotTarget = 0
	if dotAllowed and (self.Enabled or dotConfig.ShowInNormalMode) then
		if not (suppressed and dotConfig.HideDuringLockOn) then
			dotTarget = 1
		end
	end
	self.dotAlpha += (dotTarget - self.dotAlpha) * smoothAlpha(dotConfig.FadeSharpness, dt)
	if math.abs(dotTarget - self.dotAlpha) < 0.01 then
		self.dotAlpha = dotTarget
	end
	self.dotGui.Enabled = self.dotAlpha > 0.01
	self.dot.BackgroundTransparency = 1 - self.dotAlpha
	self.dotStroke.Transparency = 1 - self.dotAlpha

	return eased, self.shoulderSmooth
end

function ShiftLock:Destroy()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	self.Enabled = false
	self.dotGui:Destroy()
end

return ShiftLock