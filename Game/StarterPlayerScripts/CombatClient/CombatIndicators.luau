-- CombatIndicators
-- Ubicación: StarterPlayerScripts > CombatClient > CombatIndicators
-- Indicador de timing de los ataques de los dummies y señal visual de stun.
-- Todo se calcula con tiempos del servidor (Workspace:GetServerTimeNow): no hay cuentas regresivas propias.
-- Es solo una ayuda de entrenamiento; el resultado real del parry lo decide el servidor.
-- [v2] PerfectDodgeDummy: el telegraph (payload.TrainDodge) dibuja además la zona de Dodge normal y la de Perfect Dodge,
-- derivadas de DashConfig (InvulnerabilityDuration, InvulnerabilityPadding, PerfectDodgeWindow). El resultado real
-- (Hit / Dodged / PerfectDodge) lo decide el servidor en DodgeService y lo muestra HitFeedback.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatConfig = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("CombatConfig"))
local DashConfig = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("DashConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local telegraphCfg = CombatConfig.Telegraph
local stunCfg = CombatConfig.Stun

local CombatIndicators = {}

local telegraphs: { [Model]: any } = {}
local stuns: { [Model]: any } = {}

local function getAnchor(model: Model): BasePart?
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function makeText(parent: Instance, size: UDim2, position: UDim2, textSize: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = textSize
	label.TextColor3 = color
	label.Text = ""
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(15, 15, 15)
	stroke.Thickness = 2
	stroke.Parent = label
	return label
end

local function makeBar(parent: Instance, position: UDim2, color: Color3, transparency: number, zIndex: number): Frame
	local frame = Instance.new("Frame")
	frame.Position = position
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.ZIndex = zIndex
	frame.Parent = parent
	return frame
end

---------------------------------------------------------------------
-- Telegraph (aviso de ataque)
---------------------------------------------------------------------

local function destroyTelegraph(attacker: Model)
	local telegraph = telegraphs[attacker]
	if telegraph then
		telegraph.gui:Destroy()
		telegraphs[attacker] = nil
	end
end

function CombatIndicators.OnTelegraph(payload)
	local attacker = payload.Attacker
	local startTime = payload.StartTime
	local impactTime = payload.ImpactTime
	if typeof(attacker) ~= "Instance" or not attacker:IsA("Model") then
		return
	end
	if typeof(startTime) ~= "number" or typeof(impactTime) ~= "number" then
		return
	end

	local anchor = getAnchor(attacker)
	if not anchor then
		return
	end

	destroyTelegraph(attacker)

	local trainDodge = payload.TrainDodge == true
	local style = if trainDodge
		then telegraphCfg.Styles.Dodge
		elseif payload.BreaksGuard then telegraphCfg.Styles.GuardBreak
		else telegraphCfg.Styles.Normal
	local windup = math.max(impactTime - startTime, 0.05)

	-- [v2] Duración real de la invulnerabilidad del dash en el servidor y ventana de Perfect Dodge (ambas desde el INICIO del dash).
	local perfectWindow = DashConfig.PerfectDodgeWindow
	local dodgeWindow = math.min(
		DashConfig.InvulnerabilityDuration + DashConfig.Server.InvulnerabilityPadding,
		DashConfig.Duration
	)

	local gui = Instance.new("BillboardGui")
	gui.Name = "CombatTelegraph"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(180, 64)
	gui.StudsOffset = telegraphCfg.Offset
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false

	local title = makeText(gui, UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 0), 16, style.Color)

	local barBack = Instance.new("Frame")
	barBack.Position = UDim2.fromOffset(0, 26)
	barBack.Size = UDim2.new(1, 0, 0, 12)
	barBack.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	barBack.BackgroundTransparency = 0.15
	barBack.BorderSizePixel = 0
	barBack.Parent = gui

	local backStroke = Instance.new("UIStroke")
	backStroke.Color = Color3.fromRGB(10, 10, 10)
	backStroke.Thickness = 1.5
	backStroke.Parent = barBack

	local fill = makeBar(barBack, UDim2.fromScale(0, 0), style.Color, 0, 1)
	fill.Size = UDim2.fromScale(0, 1)

	-- Zona de parry: cualquier pulsación de F dentro de esta franja cubre el impacto.
	-- Se deriva de Block.ParryWindow, así que cambia sola si ajustás la ventana.
	if payload.CanBeParried then
		local startRemaining = CombatConfig.Block.ParryWindow + telegraphCfg.ParryCueLead
		local endRemaining = telegraphCfg.ParryCueLead
		local zoneStart = 1 - math.min(1, startRemaining / windup)
		local zoneEnd = 1 - math.min(1, endRemaining / windup)
		local zone = makeBar(barBack, UDim2.fromScale(zoneStart, 0), CombatConfig.Colors.SpecialZone, 0.35, 2)
		zone.Size = UDim2.fromScale(math.max(zoneEnd - zoneStart, 0.02), 1)
	end

	-- [v2] Zonas del dash. La barra termina en el impacto: la franja de Perfect Dodge son los últimos PerfectDodgeWindow
	-- segundos y la de Dodge normal el tramo anterior, hasta que acaba la invulnerabilidad. Se adelantan DodgeCueLead
	-- (la pulsación de Q tarda en llegar al servidor).
	if trainDodge then
		local lead = telegraphCfg.DodgeCueLead
		local dodgeStart = 1 - math.min(1, (dodgeWindow + lead) / windup)
		local perfectStart = 1 - math.min(1, (perfectWindow + lead) / windup)
		local perfectEnd = 1 - math.min(1, lead / windup)

		local dodgeZone = makeBar(barBack, UDim2.fromScale(dodgeStart, 0), telegraphCfg.Styles.DodgeZone.Color, 0.4, 2)
		dodgeZone.Size = UDim2.fromScale(math.max(perfectStart - dodgeStart, 0.02), 1)

		local perfectZone = makeBar(barBack, UDim2.fromScale(perfectStart, 0), telegraphCfg.Styles.PerfectZone.Color, 0.1, 3)
		perfectZone.Size = UDim2.fromScale(math.max(perfectEnd - perfectStart, 0.02), 1)
	end

	local cue = makeText(gui, UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 40), 18, CombatConfig.Colors.SpecialZone)

	gui.Parent = playerGui

	telegraphs[attacker] = {
		gui = gui,
		title = title,
		fill = fill,
		cue = cue,
		label = payload.Label or payload.Attack or "ATTACK",
		windup = windup,
		impactTime = impactTime,
		canBeParried = payload.CanBeParried == true,
		color = style.Color,
		trainDodge = trainDodge,
		perfectWindow = perfectWindow,
		dodgeWindow = dodgeWindow,
	}
end

function CombatIndicators.OnTelegraphCancel(payload)
	local attacker = payload.Attacker
	if typeof(attacker) == "Instance" and attacker:IsA("Model") then
		destroyTelegraph(attacker)
	end
end

local function updateTelegraph(attacker: Model, telegraph, now: number)
	if not attacker.Parent then
		destroyTelegraph(attacker)
		return
	end

	local remaining = telegraph.impactTime - now
	if remaining < -telegraphCfg.LingerAfterImpact then
		destroyTelegraph(attacker)
		return
	end

	telegraph.fill.Size = UDim2.fromScale(math.clamp(1 - remaining / telegraph.windup, 0, 1), 1)

	if remaining <= 0 then
		telegraph.title.Text = telegraph.label .. "  !"
		telegraph.cue.Text = ""
		return
	end

	telegraph.title.Text = string.format("%s  %.2f", telegraph.label, remaining)

	-- [v2] Dummy de Perfect Dodge: indica con texto y color en qué zona estaría una pulsación de Q en este instante.
	if telegraph.trainDodge then
		local lead = telegraphCfg.DodgeCueLead
		local perfectLimit = telegraph.perfectWindow + lead
		local dodgeLimit = telegraph.dodgeWindow + lead
		if remaining <= perfectLimit and remaining >= lead then
			telegraph.cue.Text = "PERFECT"
			telegraph.cue.TextColor3 = telegraphCfg.Styles.PerfectZone.Color
		elseif remaining <= dodgeLimit and remaining > perfectLimit then
			telegraph.cue.Text = "DODGE"
			telegraph.cue.TextColor3 = telegraphCfg.Styles.DodgeZone.Color
		else
			telegraph.cue.Text = ""
		end
		return
	end

	if telegraph.canBeParried then
		local lead = telegraphCfg.ParryCueLead
		if remaining <= CombatConfig.Block.ParryWindow + lead and remaining >= lead then
			telegraph.cue.Text = "F"
			telegraph.cue.TextTransparency = 0.05 + 0.3 * (math.sin(now * 40) * 0.5 + 0.5)
		else
			telegraph.cue.Text = ""
		end
	else
		telegraph.cue.Text = "SIN PARRY"
		telegraph.cue.TextColor3 = telegraph.color
	end
end

---------------------------------------------------------------------
-- Stun
---------------------------------------------------------------------

local function destroyStun(model: Model)
	local stun = stuns[model]
	if stun then
		stun.gui:Destroy()
		stuns[model] = nil
	end
end

function CombatIndicators.OnStun(payload)
	local target = payload.Target
	local duration = payload.Duration
	local endTime = payload.EndTime
	if typeof(target) ~= "Instance" or not target:IsA("Model") then
		return
	end
	if typeof(duration) ~= "number" or typeof(endTime) ~= "number" then
		return
	end

	local anchor = getAnchor(target)
	if not anchor then
		return
	end

	destroyStun(target)

	local color = stunCfg.Indicator.Color

	local gui = Instance.new("BillboardGui")
	gui.Name = "CombatStunIndicator"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(120, 40)
	gui.StudsOffset = stunCfg.Indicator.Offset
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false

	makeText(gui, UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 0), 18, color).Text = "STUN"

	local barBack = Instance.new("Frame")
	barBack.Position = UDim2.fromOffset(0, 26)
	barBack.Size = UDim2.new(1, 0, 0, 8)
	barBack.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	barBack.BackgroundTransparency = 0.15
	barBack.BorderSizePixel = 0
	barBack.Parent = gui

	local fill = makeBar(barBack, UDim2.fromScale(0, 0), color, 0, 1)

	gui.Parent = playerGui

	stuns[target] = {
		gui = gui,
		fill = fill,
		duration = math.max(duration, 0.05),
		endTime = endTime,
	}
end

local function updateStun(model: Model, stun, now: number)
	if not model.Parent then
		destroyStun(model)
		return
	end

	local remaining = stun.endTime - now
	if remaining <= 0 then
		destroyStun(model)
		return
	end

	stun.fill.Size = UDim2.fromScale(math.clamp(remaining / stun.duration, 0, 1), 1)
end

---------------------------------------------------------------------
-- Bucle único de actualización
---------------------------------------------------------------------

RunService.RenderStepped:Connect(function()
	local now = workspace:GetServerTimeNow()
	for attacker, telegraph in pairs(telegraphs) do
		updateTelegraph(attacker, telegraph, now)
	end
	for model, stun in pairs(stuns) do
		updateStun(model, stun, now)
	end
end)

return CombatIndicators