-- HitFeedback
-- Ubicación: StarterPlayerScripts > CombatClient > HitFeedback
-- Números de daño animados y efectos de impacto. Muestra la cifra confirmada por el servidor.
-- [NUEVO]: resultados "Dodged" y "PerfectDodge" (texto y estilos en CombatConfig.Feedback.Numbers.Styles).

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CombatConfig = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("CombatConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local numbersCfg = CombatConfig.Feedback.Numbers
local impactCfg = CombatConfig.Feedback.Impact

local HitFeedback = {}

-- Golpes recientes por objetivo, para que los números consecutivos no se superpongan.
local recent = setmetatable({}, { __mode = "k" })

local function formatAmount(amount: number): string
	return tostring(math.round(amount * 10) / 10)
end

local function buildText(styleKey: string, result: string, amount: number, style): string
	if result == "Parried" then
		return "PARRY"
	elseif result == "Dodged" then
		return "DODGE"
	elseif result == "PerfectDodge" then
		return "PERFECT DODGE"
	elseif result == "Blocked" then
		return if amount > 0 then "BLOCK -" .. formatAmount(amount) else "BLOCK"
	elseif result == "GuardBroken" then
		return "GUARD BREAK -" .. formatAmount(amount)
	end
	return "-" .. formatAmount(amount) .. (style.Suffix or "")
end

local function spawnNumber(character: Model, text: string, style)
	local anchor = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not anchor or not anchor:IsA("BasePart") then
		return
	end

	-- Apilado: cada golpe dentro de StackWindow se desplaza a un lado y un poco más arriba.
	local now = os.clock()
	local info = recent[character]
	if info and now - info.time <= numbersCfg.StackWindow then
		info.count += 1
	else
		info = { count = 0, time = now }
		recent[character] = info
	end
	info.time = now

	local side = if info.count % 2 == 0 then 1 else -1
	local lateral = side * numbersCfg.Spread * (0.5 + (info.count % 3) * 0.35) + (math.random() - 0.5) * 0.3
	local startOffset = numbersCfg.StartOffset + Vector3.new(lateral, math.min(info.count, 4) * numbersCfg.StackRise, 0)

	local gui = Instance.new("BillboardGui")
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(320, 80)
	gui.StudsOffset = startOffset
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = style.Color
	label.TextSize = style.Size
	label.Font = numbersCfg.Font
	label.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = numbersCfg.StrokeColor
	stroke.Thickness = numbersCfg.StrokeThickness
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 0.4
	scale.Parent = label

	-- Aparición: pequeño efecto de escala y luego asentamiento.
	TweenService:Create(
		scale,
		TweenInfo.new(numbersCfg.PopTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = numbersCfg.PopScale }
	):Play()
	task.delay(numbersCfg.PopTime, function()
		if scale.Parent then
			TweenService:Create(
				scale,
				TweenInfo.new(numbersCfg.SettleTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1 }
			):Play()
		end
	end)

	-- Ascenso continuo y suave durante toda la duración.
	TweenService:Create(
		gui,
		TweenInfo.new(numbersCfg.Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ StudsOffset = startOffset + Vector3.new(0, numbersCfg.RiseStuds, 0) }
	):Play()

	-- Desvanecimiento gradual en la segunda parte.
	local fadeDelay = numbersCfg.Duration * numbersCfg.FadeStart
	task.delay(fadeDelay, function()
		if label.Parent then
			local fadeInfo = TweenInfo.new(numbersCfg.Duration - fadeDelay, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(label, fadeInfo, { TextTransparency = 1 }):Play()
			TweenService:Create(stroke, fadeInfo, { Transparency = 1 }):Play()
		end
	end)

	Debris:AddItem(gui, numbersCfg.Duration + 0.1)
end

local function spawnImpact(character: Model, variant: string)
	local fx = impactCfg[variant] or impactCfg.Normal
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanTouch = false
	ball.CanQuery = false
	ball.CastShadow = false
	ball.Material = Enum.Material.Neon
	ball.Color = fx.Color
	ball.Transparency = 0.2
	ball.Size = Vector3.one * fx.StartSize
	ball.CFrame = CFrame.new(root.Position + Vector3.new(0, 0.5, 0))
	ball.Parent = workspace

	TweenService:Create(
		ball,
		TweenInfo.new(fx.Time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * fx.EndSize, Transparency = 1 }
	):Play()
	Debris:AddItem(ball, fx.Time + 0.1)

	if fx.Highlight then
		local highlight = Instance.new("Highlight")
		highlight.FillColor = fx.Color
		highlight.FillTransparency = 0.3
		highlight.OutlineTransparency = 1
		highlight.Adornee = character
		highlight.Parent = character
		TweenService:Create(highlight, TweenInfo.new(fx.Time), { FillTransparency = 1 }):Play()
		Debris:AddItem(highlight, fx.Time + 0.1)
	end
end

function HitFeedback.OnDamage(payload)
	local target = payload.Target
	local result = payload.Result
	local amount = payload.Amount
	local variant = payload.Variant or "Normal"

	if typeof(target) ~= "Instance" or not target:IsA("Model") then
		return
	end
	if typeof(result) ~= "string" or typeof(amount) ~= "number" or typeof(variant) ~= "string" then
		return
	end

	local styleKey = variant
	if result == "Parried" then
		styleKey = "Parried"
	elseif result == "Blocked" then
		styleKey = "Blocked"
	elseif result == "Dodged" then
		styleKey = "Dodged"
	elseif result == "PerfectDodge" then
		styleKey = "PerfectDodge"
	end

	local style = numbersCfg.Styles[styleKey] or numbersCfg.Styles.Normal
	spawnNumber(target, buildText(styleKey, result, amount, style), style)

	if result == "Hit" or result == "GuardBroken" then
		spawnImpact(target, variant)
	end
end

return HitFeedback