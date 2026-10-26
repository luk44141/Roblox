print("[RibbonPhysicsClient] script iniciado")

--[[
	RibbonPhysicsClient (LocalScript)  -  multi-espada
	UBICACIÓN: StarterPlayer > StarterPlayerScripts > RibbonPhysicsClient
	Requiere el ModuleScript "RibbonPhysics" (v3.x) en ReplicatedStorage.

	Aplica la simulación a TODOS los modelos de Workspace cuyo nombre coincida
	con SWORD_PATTERN (también a los que se añadan después). Cada espada tiene su
	propia simulación independiente.

	Todas las espadas deben tener la misma estructura que la original:
	RootPart, Ribbon (con huesos), Shape, Base...
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
-- CONFIGURACIÓN DE LA FÍSICA (compartida por todas las espadas)
--------------------------------------------------------------------------------
local CONFIG = {
	Debug = true,
	DebugDraw = false, -- true: esferas rojas (huesos fijos) y cian (libres) + cajas de colisión
	DebugStats = true, -- desvío máximo respecto al reposo (solo de la espada equipada)

	Names = {
		Ribbon = "Ribbon",
		RootPart = "RootPart",
		Colliders = { "Shape", "Base" },
	},

	Simulation = {
		TeleportDistance = 30,
		MaxSpeed = 80,
		InputSmoothing = 0.04,
	},

	Chain = {
		StartBone = "Bone.005", -- este hueso y los anteriores NO se simulan
	},

	-- { Near, Tip }: del primer hueso libre a la punta
	Physics = {
		Curve = 1.5,
		Elasticity = { Near = 100, Tip = 14 },
		Damping = { Near = 12, Tip = 6 },
		AirDrag = { Near = 0.3, Tip = 1.5 },
		Stiffness = { Near = 0.95, Tip = 0.3 },
		Follow = { Near = 1, Tip = 0.1 },
		Gravity = Vector3.zero,
	},

	Wind = {
		Enabled = true,
		Strength = 6,
		Speed = 0.5,
		SpatialPhase = 0.06,
		Space = "World",
		AxisMask = Vector3.new(1, 0, 1),
		Steady = Vector3.zero,
	},

	Collision = {
		Enabled = false,
		Radius = 0.12,
		IgnoreFirstParticles = 3,
		MidpointSamples = 1,
		Softness = 0.75,
		ContactDamping = 0.5,
		RestMargin = 0.15,
	},

	Ground = {
		Enabled = true,
		Radius = 0.15,
		Lift = 1.5,
		SearchDepth = 40,
		CheckHeight = 8,
		Friction = 8,
	},

	Bones = {
		MaxBendAngle = 70,
		ResponseGain = 1,
		SmoothingRate = 25,
		SpatialSmoothing = 1,
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
local sims = {} -- [modelo] = simulación

local function isEquipped(sword)
	return EQUIP_TEST and sword.Name == EQUIP_SWORD
end

local function setupSword(sword)
	if started[sword] then
		return
	end
	started[sword] = true

	task.spawn(function()
		-- Espera a que lleguen las piezas (importante si hay StreamingEnabled)
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

		-- Copia superficial de la config: solo la espada equipada imprime estadísticas
		local cfg = table.clone(CONFIG)
		cfg.DebugStats = CONFIG.DebugStats and (isEquipped(sword) or not EQUIP_TEST)

		local sim = RibbonPhysics.new(sword, cfg)
		if sim.ok then
			sims[sword] = sim
			print("[RibbonPhysicsClient] Simulación activa en '" .. sword.Name .. "'")
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