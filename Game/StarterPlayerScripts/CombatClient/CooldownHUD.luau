--[[
	CooldownHUD  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > CombatClient > CooldownHUD   (hijo del LocalScript CombatClient)

	Indicadores de cooldown de las habilidades: Dash (Q), R (Guard Break) y Parry (F).
	Solo MUESTRA información; nunca decide si una habilidad se puede usar (eso lo decide siempre el servidor).

	Fuente de datos = estado REAL del servidor, publicado como atributos del Player (con tiempo del servidor):
	  CooldownEnd_Heavy  -> CombatService.StartAttack (R, 20 s, sobrevive al respawn)
	  CooldownEnd_Parry  -> CombatService.SetBlockHeld
	  DashCharges / CooldownEnd_Dash -> DodgeService (cargas y recarga del dash)
	El tiempo restante se calcula con Workspace:GetServerTimeNow(), el mismo reloj que usan los telegraphs, así que
	no hay cuentas regresivas propias que se desincronicen.

	[v2.3] Salto: cooldown local (MovementController.GetJumpCooldownRemaining) y barra de bloqueo (atributos del Player
	BlockMeter / BlockMeterRate / BlockMeterTime / BlockLockedUntil publicados por CombatService).

	Dash: además del servidor se usa la predicción local de DashController (deps.getDashCooldownRemaining) y se muestra
	el MAYOR de los dos. Así el HUD reacciona en el mismo fotograma de la pulsación (sin esperar al ping) y nunca
	muestra "listo" cuando el cliente todavía no te dejaría hacer dash.

	deps = {
		keys = { Dash = Enum.KeyCode, Heavy = Enum.KeyCode, Parry = Enum.KeyCode },
		getDashCooldownRemaining = function() -> number,   (opcional)
		getJumpCooldownRemaining = function() -> number,   (opcional)
	}

	API: Start(deps), NotifyPress(id), IsReady(id), Destroy()
	Configuración: CombatConfig.CooldownHUD
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CombatFolder = ReplicatedStorage:WaitForChild("CombatSystem")
local CombatConfig = require(CombatFolder:WaitForChild("CombatConfig"))
local DashConfig = require(CombatFolder:WaitForChild("DashConfig"))

local player = Players.LocalPlayer
local cfg = CombatConfig.CooldownHUD

local READY_EPSILON = 0.05 -- por debajo de esto se considera listo

local CooldownHUD = {}

local started = false
local gui: ScreenGui? = nil
local updateConnection: RBXScriptConnection? = nil
local slots: { [string]: any } = {}
local slotList: { any } = {}
local deps: any = nil
local blockBar: any = nil -- [v2.3]
local comboWidget: any = nil -- [v2.8]

---------------------------------------------------------------------
-- Lectura del estado (atributos del Player publicados por el servidor)
---------------------------------------------------------------------

-- Segundos que faltan para el tiempo de servidor guardado en el atributo (0 si no existe o ya pasó).
local function remainingFromAttribute(name: string, now: number): number
	local value = player:GetAttribute(name)
	if typeof(value) ~= "number" then
		return 0
	end
	return math.max(value - now, 0)
end

-- Cada proveedor devuelve (segundos restantes, duración total del cooldown, cargas o nil).
local providers = {
	Dash = function(now: number): (number, number, number?)
		local maxCharges = DashConfig.MaxCharges
		local cooldown = math.max(DashConfig.Cooldown, 0.01)

		local charges = player:GetAttribute("DashCharges")
		if typeof(charges) ~= "number" then
			charges = maxCharges
		end
		local nextCharge = player:GetAttribute("CooldownEnd_Dash")
		if typeof(nextCharge) ~= "number" then
			nextCharge = 0
		end

		-- El servidor solo recalcula las cargas al recibir un pedido: aquí se avanzan las recargas ya cumplidas.
		while charges < maxCharges and nextCharge > 0 and now >= nextCharge do
			charges += 1
			nextCharge += cooldown
		end

		local remaining = 0
		if charges <= 0 then
			remaining = math.max(nextCharge - now, 0)
		end

		-- Predicción local: el mayor de ambos (ver cabecera).
		if deps and deps.getDashCooldownRemaining then
			remaining = math.max(remaining, deps.getDashCooldownRemaining())
		end

		return remaining, cooldown, if maxCharges > 1 then charges else nil
	end,

	Heavy = function(now: number): (number, number, number?)
		local def = CombatConfig.Attacks.Heavy
		return remainingFromAttribute("CooldownEnd_Heavy", now), def.PlayerCooldown or def.Cooldown or 1, nil
	end,

	Parry = function(now: number): (number, number, number?)
		return remainingFromAttribute("CooldownEnd_Parry", now), CombatConfig.Block.ParryCooldown, nil
	end,

	-- [v2.15] Finta: cooldown del servidor (CombatService.RequestFeint)
	Feint = function(now: number): (number, number, number?)
		return remainingFromAttribute("CooldownEnd_Feint", now), CombatConfig.Feint.Cooldown, nil
	end,

	-- [v2.3] El cooldown del salto es local (cliente), no hay atributo del servidor.
	Jump = function(_now: number): (number, number, number?)
		local remaining = if deps and deps.getJumpCooldownRemaining then deps.getJumpCooldownRemaining() else 0
		return remaining, CombatConfig.Jump.Cooldown, nil
	end,
}

---------------------------------------------------------------------
-- Construcción de la interfaz
---------------------------------------------------------------------

local function addCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function makeLabel(parent: Instance, name: string, size: UDim2, position: UDim2, textSize: number, zIndex: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = textSize
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Text = ""
	label.ZIndex = zIndex
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(10, 10, 10)
	stroke.Thickness = 1.5
	stroke.Parent = label
	return label
end

local function createSlot(index: number, def: any, keyName: string, parent: Instance)
	local size = cfg.SlotSize

	local frame = Instance.new("Frame")
	frame.Name = "Slot_" .. def.Id
	frame.LayoutOrder = index
	frame.Size = UDim2.fromOffset(size, size)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = cfg.BackgroundColor
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = parent
	addCorner(frame, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = cfg.ReadyColor
	stroke.Thickness = 2.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = frame

	local keyLabel = makeLabel(frame, "Key", UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 6), 26, 1)
	keyLabel.Text = keyName

	local nameLabel = makeLabel(frame, "Name", UDim2.new(1, 0, 0, 14), UDim2.new(0, 0, 1, -18), 9, 1)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.Text = def.Name

	-- Barrido de cooldown: cubre la casilla y se encoge hacia abajo a medida que pasa el tiempo.
	local overlay = Instance.new("Frame")
	overlay.Name = "Cooldown"
	overlay.AnchorPoint = Vector2.new(0, 1)
	overlay.Position = UDim2.fromScale(0, 1)
	overlay.Size = UDim2.fromScale(1, 0)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.Visible = false
	overlay.ZIndex = 2
	overlay.Parent = frame

	local timeLabel = makeLabel(frame, "Time", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 20, 3)
	timeLabel.TextColor3 = cfg.CooldownColor

	local chargeLabel = makeLabel(frame, "Charges", UDim2.fromOffset(22, 16), UDim2.new(1, -24, 0, 2), 13, 3)
	chargeLabel.TextXAlignment = Enum.TextXAlignment.Right
	chargeLabel.Visible = false

	-- Destello al volver a estar disponible
	local flash = Instance.new("Frame")
	flash.Name = "ReadyFlash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = cfg.ReadyColor
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 4
	flash.Parent = frame

	return {
		id = def.Id,
		frame = frame,
		stroke = stroke,
		scale = scale,
		keyLabel = keyLabel,
		overlay = overlay,
		timeLabel = timeLabel,
		chargeLabel = chargeLabel,
		flash = flash,
		provider = providers[def.Id],
		onCooldown = false,
		lastText = "",
		lastCharges = -1,
		shakeToken = 0,
		visualReady = nil, -- nil fuerza el primer pintado
	}
end

---------------------------------------------------------------------
-- Animaciones
---------------------------------------------------------------------

local function playReady(slot)
	slot.flash.BackgroundTransparency = 0.35
	TweenService:Create(slot.flash, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()

	slot.scale.Scale = 1.18
	TweenService:Create(slot.scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Sacudida breve: se intentó usar la habilidad con cooldown activo.
local function shake(slot)
	slot.shakeToken += 1
	local token = slot.shakeToken
	task.spawn(function()
		for _, angle in { 7, -7, 4, 0 } do
			if slot.shakeToken ~= token or not slot.frame.Parent then
				return
			end
			local tween = TweenService:Create(slot.frame, TweenInfo.new(0.05, Enum.EasingStyle.Quad), { Rotation = angle })
			tween:Play()
			tween.Completed:Wait()
		end
	end)
end

---------------------------------------------------------------------
-- Actualización
---------------------------------------------------------------------

local function formatTime(remaining: number): string
	if remaining >= 10 then
		return tostring(math.ceil(remaining))
	end
	return string.format("%.1f", remaining)
end

local function paintReady(slot, ready: boolean)
	if slot.visualReady == ready then
		return
	end
	slot.visualReady = ready
	slot.stroke.Color = if ready then cfg.ReadyColor else cfg.CooldownColor
	slot.stroke.Transparency = if ready then 0 else 0.35
	slot.keyLabel.TextTransparency = if ready then 0 else 0.45
end

local function updateSlot(slot, now: number)
	local remaining, duration, charges = slot.provider(now)
	local onCooldown = remaining > READY_EPSILON

	if slot.onCooldown and not onCooldown then
		playReady(slot)
	end
	slot.onCooldown = onCooldown

	paintReady(slot, not onCooldown)

	if onCooldown then
		slot.overlay.Visible = true
		slot.overlay.Size = UDim2.fromScale(1, math.clamp(remaining / math.max(duration, 0.01), 0, 1))
		local text = formatTime(remaining)
		if text ~= slot.lastText then
			slot.timeLabel.Text = text
			slot.lastText = text
		end
	elseif slot.overlay.Visible then
		slot.overlay.Visible = false
		slot.timeLabel.Text = ""
		slot.lastText = ""
	end

	-- Cargas (solo si DashConfig.MaxCharges > 1)
	local chargeValue = charges or -1
	if chargeValue ~= slot.lastCharges then
		slot.lastCharges = chargeValue
		slot.chargeLabel.Visible = charges ~= nil
		slot.chargeLabel.Text = if charges ~= nil then "x" .. tostring(charges) else ""
	end
end

-- [v2.3] Barra de bloqueo: se extrapola con el ritmo (+recarga / -gasto) que publica el servidor.
local function updateBlockBar(now: number)
	if not blockBar then
		return
	end
	local meter = CombatConfig.Block.Meter
	local barCfg = cfg.BlockBar

	local value = player:GetAttribute("BlockMeter")
	local rate = player:GetAttribute("BlockMeterRate")
	local t0 = player:GetAttribute("BlockMeterTime")
	local lockedUntil = player:GetAttribute("BlockLockedUntil")
	value = if typeof(value) == "number" then value else meter.Max
	rate = if typeof(rate) == "number" then rate else 0
	t0 = if typeof(t0) == "number" then t0 else now
	lockedUntil = if typeof(lockedUntil) == "number" then lockedUntil else 0

	local current = math.clamp(value + rate * (now - t0), 0, meter.Max)
	local lockedRemaining = math.max(lockedUntil - now, 0)

	local show = lockedRemaining > 0 or current < meter.Max - 0.5
	blockBar.frame.Visible = show
	if not show then
		return
	end

	if lockedRemaining > 0 then
		-- Bloqueo agotado: la barra se "llena" con el tiempo que falta para poder bloquear de nuevo.
		local progress = 1 - math.clamp(lockedRemaining / math.max(meter.DepletedCooldown, 0.01), 0, 1)
		blockBar.fill.Size = UDim2.fromScale(progress, 1)
		blockBar.fill.BackgroundColor3 = barCfg.LowColor
		blockBar.label.Text = string.format("BLOQUEO %.1f", lockedRemaining)
	else
		local fraction = current / meter.Max
		blockBar.fill.Size = UDim2.fromScale(fraction, 1)
		blockBar.fill.BackgroundColor3 = barCfg.LowColor:Lerp(barCfg.FullColor, fraction)
		blockBar.label.Text = "BLOQUEO"
	end
end

-- [v2.8] Contador de golpes: círculos en el borde derecho; el último (4º básico / Uppercut / AirSlam) es más grande.
local function updateComboCounter(now: number)
	if not comboWidget then
		return
	end
	local counterCfg = cfg.ComboCounter

	local count = player:GetAttribute("ComboCount")
	local untilTime = player:GetAttribute("ComboCountUntil")
	local isAir = player:GetAttribute("ComboAir") == true
	count = if typeof(count) == "number" then count else 0
	untilTime = if typeof(untilTime) == "number" then untilTime else 0

	local visible = count > 0 and now < untilTime
	comboWidget.frame.Visible = visible
	if not visible then
		comboWidget.lastCount = 0
		return
	end

	local litColor = if isAir then counterCfg.AirColor else counterCfg.LitColor
	for index, circle in ipairs(comboWidget.circles) do
		local lit = index <= count
		circle.frame.BackgroundColor3 = if lit then litColor else counterCfg.UnlitColor
		circle.frame.BackgroundTransparency = if lit then 0 else 0.35
		circle.stroke.Color = litColor
		circle.stroke.Transparency = if lit then 0 else 0.5
	end

	-- Pequeño "pop" en el círculo que se acaba de encender
	if count ~= comboWidget.lastCount then
		local circle = comboWidget.circles[count]
		if circle then
			circle.scale.Scale = 1.5
			TweenService:Create(circle.scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		comboWidget.lastCount = count
	end
end

local function onRenderStepped()
	local now = workspace:GetServerTimeNow()
	for _, slot in slotList do
		updateSlot(slot, now)
	end
	updateBlockBar(now)
	updateComboCounter(now)
end

---------------------------------------------------------------------
-- API
---------------------------------------------------------------------

-- ¿Está disponible según lo último que vio el cliente? (informativo: el servidor siempre decide)
function CooldownHUD.IsReady(id: string): boolean
	local slot = slots[id]
	return slot == nil or not slot.onCooldown
end

-- Se llama al pulsar la tecla de una habilidad: si está en cooldown, la casilla se sacude.
function CooldownHUD.NotifyPress(id: string)
	local slot = slots[id]
	if slot and slot.onCooldown then
		shake(slot)
	end
end

function CooldownHUD.Start(newDeps: any)
	if started or not cfg.Enabled then
		return
	end
	started = true
	deps = newDeps

	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CombatCooldownHUD"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = cfg.DisplayOrder
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local container = Instance.new("Frame")
	container.Name = "Slots"
	container.AnchorPoint = Vector2.new(0.5, 1)
	container.Position = UDim2.new(0.5, 0, 1, -cfg.BottomOffset)
	container.Size = UDim2.fromOffset(0, cfg.SlotSize)
	container.AutomaticSize = Enum.AutomaticSize.X
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, cfg.Spacing)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	for index, def in ipairs(cfg.Slots) do
		if providers[def.Id] then
			local keyCode = deps and deps.keys and deps.keys[def.Id]
			local keyName = if typeof(keyCode) == "EnumItem" then keyCode.Name elseif typeof(keyCode) == "string" then keyCode else "?"
			local slot = createSlot(index, def, keyName, container)
			slots[def.Id] = slot
			table.insert(slotList, slot)
		else
			warn(`[CooldownHUD] Casilla desconocida en CombatConfig.CooldownHUD.Slots: {tostring(def.Id)}`)
		end
	end

	-- [v2.3] Barra de bloqueo, encima de las casillas
	local barCfg = cfg.BlockBar
	local barFrame = Instance.new("Frame")
	barFrame.Name = "BlockBar"
	barFrame.AnchorPoint = Vector2.new(0.5, 1)
	barFrame.Position = UDim2.new(0.5, 0, 1, -(cfg.BottomOffset + cfg.SlotSize + barCfg.Gap))
	barFrame.Size = UDim2.fromOffset(barCfg.Width, barCfg.Height)
	barFrame.BackgroundColor3 = cfg.BackgroundColor
	barFrame.BackgroundTransparency = 0.25
	barFrame.BorderSizePixel = 0
	barFrame.Visible = false
	barFrame.ClipsDescendants = true
	barFrame.Parent = screenGui
	addCorner(barFrame, 6)

	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = barCfg.FullColor
	barFill.BorderSizePixel = 0
	barFill.Parent = barFrame

	local barLabel = makeLabel(barFrame, "Label", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 10, 2)
	barLabel.Font = Enum.Font.GothamBold
	barLabel.Text = "BLOQUEO"
	blockBar = { frame = barFrame, fill = barFill, label = barLabel }

	-- [v2.8] Contador de golpes (borde derecho, centrado en vertical)
	local counterCfg = cfg.ComboCounter
	local comboCount = #CombatConfig.Combo.Sequence
	local comboFrame = Instance.new("Frame")
	comboFrame.Name = "ComboCounter"
	comboFrame.AnchorPoint = Vector2.new(1, 0.5)
	comboFrame.Position = UDim2.new(1, -counterCfg.EdgeOffset, 0.5, 0)
	comboFrame.Size = UDim2.fromOffset(counterCfg.LastCircleSize, 0)
	comboFrame.AutomaticSize = Enum.AutomaticSize.Y
	comboFrame.BackgroundTransparency = 1
	comboFrame.Visible = false
	comboFrame.Parent = screenGui

	local comboLayout = Instance.new("UIListLayout")
	comboLayout.FillDirection = Enum.FillDirection.Vertical
	comboLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	comboLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	comboLayout.Padding = UDim.new(0, counterCfg.Gap)
	comboLayout.SortOrder = Enum.SortOrder.LayoutOrder
	comboLayout.Parent = comboFrame

	local circles = {}
	for index = 1, comboCount do
		local size = if index == comboCount then counterCfg.LastCircleSize else counterCfg.CircleSize
		local circle = Instance.new("Frame")
		circle.Name = "Circle" .. index
		circle.LayoutOrder = index
		circle.Size = UDim2.fromOffset(size, size)
		circle.AnchorPoint = Vector2.new(0.5, 0.5)
		circle.BackgroundColor3 = counterCfg.UnlitColor
		circle.BorderSizePixel = 0
		circle.Parent = comboFrame
		addCorner(circle, size) -- radio >= mitad = círculo

		local circleStroke = Instance.new("UIStroke")
		circleStroke.Thickness = 2
		circleStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		circleStroke.Color = counterCfg.LitColor
		circleStroke.Parent = circle

		local circleScale = Instance.new("UIScale")
		circleScale.Scale = 1
		circleScale.Parent = circle

		circles[index] = { frame = circle, stroke = circleStroke, scale = circleScale }
	end
	comboWidget = { frame = comboFrame, circles = circles, lastCount = 0 }

	screenGui.Parent = playerGui
	gui = screenGui

	updateConnection = RunService.RenderStepped:Connect(onRenderStepped)
end

function CooldownHUD.Destroy()
	if not started then
		return
	end
	started = false

	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	table.clear(slots)
	table.clear(slotList)
	blockBar = nil
	comboWidget = nil
	deps = nil
end

return CooldownHUD
