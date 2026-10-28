--[[
	RibbonPhysicsClient (LocalScript)  -  versión limpia
	UBICACIÓN: StarterPlayer > StarterPlayerScripts > RibbonPhysicsClient
	Requiere el ModuleScript "RibbonPhysics" (v4) en ReplicatedStorage.

	Aplica la simulación a TODOS los modelos de Workspace cuyo nombre coincida
	con SWORD_PATTERN (también a los que se añadan después). Cada espada tiene su
	propia simulación independiente.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local RibbonPhysics = require(ReplicatedStorage:WaitForChild("RibbonPhysics"))

--------------------------------------------------------------------------------
-- QUÉ ESPADAS SE SIMULAN Y CUÁL SE EQUIPA
--------------------------------------------------------------------------------
local SWORD_PATTERN = "^zanpakuto" -- cualquier Model en Workspace cuyo nombre empiece así
local EQUIP_TEST = true -- true: suelda UNA espada a tu mano derecha (solo visual/local)
local EQUIP_SWORD = "zanpakuto" -- nombre EXACTO de la espada que se equipa. Las demás quedan libres para moverlas con Move
local HANDLE_NAME = "Base"
local GRIP_OFFSET = CFrame.new(0, -0.2, 0) * CFrame.Angles(90, 90, 0)

local player = Players.LocalPlayer

--------------------------------------------------------------------------------
-- CONFIGURACIÓN (compartida por todas las espadas)
-- Los parámetros { Near, Tip } van del primer hueso libre a la punta.
--------------------------------------------------------------------------------
local CONFIG = {
	Debug = false, -- true = imprime en Output qué detecta (huesos, suelo...)

	Simulation = {
		TeleportDistance = 30,
		MaxSpeed = 45, -- velocidad máx. de las partículas (studs/s)
		InputSmoothing = 0.04,
	},

	Chain = {
		StartBone = "Bone.004", -- PRIMER hueso que gira; los anteriores quedan fijos
	},

	Physics = {
		Elasticity = { Near = 70, Tip = 5 }, -- fuerza que devuelve la cinta a su forma
		Damping = { Near = 12, Tip = 6 }, -- pérdida de energía
		AirDrag = { Near = 1, Tip = 3 }, -- retraso al moverte (D, A, W, S...) y empuje del viento
		Stiffness = { Near = 0.85, Tip = 0.1 }, -- límite angular por segmento
		Follow = { Near = 1, Tip = 0.05 }, -- 1 = sigue a la espada; 0 = se queda atrás por inercia
		ConstraintDamping = 0.5,
		MaxRise = 0.5, -- máx. que sube la cinta sobre StartBone (studs)
	},

	Wind = {
		Enabled = true,
		Strength = 9, -- más = más viento
		Speed = 0.35, -- rapidez de las ráfagas
		SpatialPhase = 0.06,
		AxisMask = Vector3.new(1, 0, 1),
	},

	Ground = {
		Enabled = true,
		Radius = 0.2, -- distancia mínima de la cinta al suelo
		Lift = 1.5,
		SearchDepth = 40,
		CheckHeight = 8,
		Friction = 5, -- más = se arrastra menos
		StaticSpeed = 0.5,
	},

	Bones = {
		MaxBendAngle = 90,
		TipMaxBendAngle = 40,
		SmoothingRate = 18,
		TipSmoothingRate = 12,
		TipSmoothCount = 6,
		SpatialSmoothing = 2,
		MaxAngularSpeed = 400,
	},
}

--------------------------------------------------------------------------------
-- EQUIPAR (prueba local): suelda la espada a la mano derecha
--------------------------------------------------------------------------------
local function equipSword(sword, character)
	local hand = character:WaitForChild("RightHand", 5) or character:WaitForChild("Right Arm", 5)
	local handle = sword:FindFirstChild(HANDLE_NAME, true)
	if not hand or not handle then
		warn("[RibbonPhysicsClient] No se pudo equipar '" .. sword.Name .. "': falta la mano o la pieza '" .. HANDLE_NAME .. "'")
		return false
	end

	for _, d in ipairs(sword:GetDescendants()) do
		if d:IsA("WeldConstraint") and d.Name == "EquipWeld" then
			d:Destroy()
		end
	end

	local pivotRel = handle.CFrame:ToObjectSpace(sword:GetPivot())
	sword:PivotTo(hand.CFrame * GRIP_OFFSET * pivotRel)

	for _, d in ipairs(sword:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			if d ~= handle then
				local w = Instance.new("WeldConstraint")
				w.Name = "EquipWeld"
				w.Part0 = handle
				w.Part1 = d
				w.Parent = handle
			end
		end
	end

	local hw = Instance.new("WeldConstraint")
	hw.Name = "EquipWeld"
	hw.Part0 = hand
	hw.Part1 = handle
	hw.Parent = handle
	return true
end

--------------------------------------------------------------------------------
-- UNA SIMULACIÓN POR ESPADA
--------------------------------------------------------------------------------
local started = {} -- [modelo] = true
local swordModels = {} -- todas las espadas: no cuentan como suelo para la cinta de las demás
local sims = {} -- [modelo] = simulación

local function isEquipped(sword)
	return EQUIP_TEST and sword.Name == EQUIP_SWORD
end

local function setupSword(sword)
	if started[sword] then
		return
	end
	started[sword] = true
	table.insert(swordModels, sword)

	task.spawn(function()
		local rootPart = sword:WaitForChild("RootPart", 30)
		local ribbonPart = sword:WaitForChild("Ribbon", 30)
		if not rootPart or not ribbonPart then
			warn("[RibbonPhysicsClient] '" .. sword.Name .. "': RootPart/Ribbon no llegaron al cliente en 30 s")
			started[sword] = nil
			return
		end

		if isEquipped(sword) then
			equipSword(sword, player.Character or player.CharacterAdded:Wait())
		end

		local cfg = table.clone(CONFIG)
		cfg.Ground = table.clone(CONFIG.Ground)
		cfg.Ground.Ignore = swordModels

		local sim = RibbonPhysics.new(sword, cfg)
		if sim.ok then
			sims[sword] = sim
			if CONFIG.Debug then
				print("[RibbonPhysicsClient] Simulación activa en '" .. sword.Name .. "'")
			end
		else
			warn("[RibbonPhysicsClient] '" .. sword.Name .. "': la simulación no pudo iniciarse. Revisa los avisos anteriores.")
		end

		sword.Destroying:Connect(function()
			if sims[sword] then
				sims[sword]:Destroy()
				sims[sword] = nil
			end
			started[sword] = nil
		end)
	end)
end

local function consider(obj)
	if obj:IsA("Model") and obj.Name:match(SWORD_PATTERN) then
		setupSword(obj)
	end
end

for _, child in ipairs(Workspace:GetChildren()) do
	consider(child)
end
Workspace.ChildAdded:Connect(consider)

task.delay(10, function()
	if next(started) == nil then
		warn("[RibbonPhysicsClient] No se encontró ningún Model en Workspace cuyo nombre empiece por el patrón '" .. SWORD_PATTERN .. "'")
	end
end)

-- Al reaparecer: se vuelve a equipar y se reinicia solo esa simulación
player.CharacterAdded:Connect(function(character)
	if not EQUIP_TEST then
		return
	end
	for sword, sim in pairs(sims) do
		if sword.Name == EQUIP_SWORD then
			equipSword(sword, character)
			sim:Reset()
		end
	end
end)