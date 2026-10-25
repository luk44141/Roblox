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

	Dash: además del servidor se usa la predicción local de DashController (deps.getDashCooldownRemaining) y se muestra
	el MAYOR de los dos. Así el HUD reacciona en el mismo fotograma de la pulsación (sin esperar al ping) y nunca
	muestra "listo" cuando el cliente todavía no te dejaría hacer dash.

	deps = {
		keys = { Dash = Enum.KeyCode, Heavy = Enum.KeyCode, Parry = Enum.KeyCode },
		getDashCooldownRemaining = function() -> number,   (opcional)
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

local function onRenderStepped()
	local now = workspace:GetServerTimeNow()
	for _, slot in slotList do
		updateSlot(slot, now)
	end
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
			local keyName = if typeof(keyCode) == "EnumItem" then keyCode.Name else "?"
			local slot = createSlot(index, def, keyName, container)
			slots[def.Id] = slot
			table.insert(slotList, slot)
		else
			warn(`[CooldownHUD] Casilla desconocida en CombatConfig.CooldownHUD.Slots: {tostring(def.Id)}`)
		end
	end

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
	deps = nil
end

return CooldownHUD
