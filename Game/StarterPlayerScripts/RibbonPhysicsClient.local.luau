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
-- NOTA: CFrame.Angles usa RADIANES (90 rad = ~117° efectivos). Se deja tal cual para no cambiar la orientación que ya
-- tenías; si quisieras 90° reales sería math.rad(90).

-- [v2.12] AJUSTADOR DE LA POSICIÓN DEL ARMA EN LA MANO (para que coincida con tu animación)
--   Con GRIP_TUNER = true, mientras jugás:  Flechas arriba/abajo = eje Y de la mano, izquierda/derecha = eje X,
--   RePág/AvPág = eje Z (paso 0.05; con Shift apretado 0.25).  Suprimir = volver al valor original.
--   Cada cambio imprime en Output la línea `local gripTune = Vector3.new(...)`: copiala aquí abajo (reemplaza la de arriba) y poné GRIP_TUNER = false.
local GRIP_TUNER = true
local gripTune = Vector3.new(0, 0, 0)

-- [v2.14] ARMA UNIDA CON MOTOR6D (como tus animaciones)
--   Tus animaciones mueven el arma a través de una unión Motor6D (brazo -> arma). En el juego la espada se pegaba con una
--   soldadura fija, por eso no coincidía con la animación (se veía más arriba) y no seguía sus keyframes.
--   Ahora se busca esa Motor6D en tus rigs de animación (Workspace.Animaciones.*) y se COPIA al personaje: mismo nombre de
--   parte, mismo C0 / C1 y misma parte del cuerpo. Las animaciones se enlazan por el NOMBRE de la parte, así que se crea una
--   parte invisible con el nombre exacto que usa la animación y la espada se suelda a ella.
local ANIMATION_RIGS_FOLDER = "Animaciones"
-- Si la detección automática no sirve, rellená esto a mano (o dejalo en nil):
--   { Part0 = "Right Arm", Part1 = "NombreDeLaPartePosesAnimada", C0 = CFrame.new(...), C1 = CFrame.new(...) }
local WEAPON_JOINT_OVERRIDE = nil
-- Desplazamiento de la espada respecto de esa parte (normalmente nada: la espada y la parte del rig coinciden).
local SWORD_FROM_PROXY = CFrame.new()

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
-- Busca en los rigs de animación la unión que sostiene el arma: cualquier Motor6D / Weld / WeldConstraint que una una parte
-- del cuerpo (Torso, brazos, mano...) con una parte que NO es del cuerpo (el arma). Se prioriza el rig "m1Rig" y las Motor6D.
local weaponJointTemplate = nil
local templateSearched = false

local BODY_PARTS = {
	["Head"] = true, ["Torso"] = true, ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true,
	["HumanoidRootPart"] = true, -- R6
	["UpperTorso"] = true, ["LowerTorso"] = true, ["LeftUpperArm"] = true, ["LeftLowerArm"] = true, ["LeftHand"] = true,
	["RightUpperArm"] = true, ["RightLowerArm"] = true, ["RightHand"] = true, ["LeftUpperLeg"] = true, ["LeftLowerLeg"] = true,
	["LeftFoot"] = true, ["RightUpperLeg"] = true, ["RightLowerLeg"] = true, ["RightFoot"] = true, -- R15
}
local PREFERRED_RIG = "m1Rig"

local function findWeaponJointTemplate()
	if templateSearched then
		return weaponJointTemplate
	end
	templateSearched = true

	if WEAPON_JOINT_OVERRIDE then
		weaponJointTemplate = {
			Name = "WeaponJoint",
			Part0Name = WEAPON_JOINT_OVERRIDE.Part0,
			Part1Name = WEAPON_JOINT_OVERRIDE.Part1,
			C0 = WEAPON_JOINT_OVERRIDE.C0 or CFrame.new(),
			C1 = WEAPON_JOINT_OVERRIDE.C1 or CFrame.new(),
			SwordFromProxy = CFrame.new(),
		}
		return weaponJointTemplate
	end

	local folder = Workspace:WaitForChild(ANIMATION_RIGS_FOLDER, 5)
	if not folder then
		warn("[RibbonPhysicsClient] No hay Workspace." .. ANIMATION_RIGS_FOLDER .. ": se usa la soldadura simple del arma")
		return nil
	end

	-- Rigs en orden de prioridad
	local rigs = {}
	local preferred = folder:FindFirstChild(PREFERRED_RIG)
	if preferred then
		table.insert(rigs, preferred)
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child ~= preferred then
			table.insert(rigs, child)
		end
	end

	local report = {}
	local function isExtra(part: BasePart?): boolean
		return part ~= nil and not BODY_PARTS[part.Name]
	end

	for _, rig in ipairs(rigs) do
		local extraParts = {}
		for _, descendant in ipairs(rig:GetDescendants()) do
			if descendant:IsA("BasePart") and isExtra(descendant) then
				table.insert(extraParts, descendant.Name)
			end
		end
		table.insert(report, string.format("%s: partes extra = {%s}", rig.Name, table.concat(extraParts, ", ")))

		for _, descendant in ipairs(rig:GetDescendants()) do
			local part0, part1, c0, c1, kind
			if descendant:IsA("Motor6D") or descendant:IsA("Weld") then
				part0, part1, c0, c1 = descendant.Part0, descendant.Part1, descendant.C0, descendant.C1
				kind = descendant.ClassName
			elseif descendant:IsA("WeldConstraint") then
				part0, part1 = descendant.Part0, descendant.Part1
				if part0 and part1 then
					c0, c1 = part0.CFrame:ToObjectSpace(part1.CFrame), CFrame.new()
				end
				kind = "WeldConstraint"
			end

			if part0 and part1 and c0 and c1 then
				-- Se normaliza para que Part0 sea la parte del cuerpo y Part1 el arma
				if isExtra(part0) and not isExtra(part1) then
					part0, part1 = part1, part0
					c0, c1 = c1, c0
				end
				if not isExtra(part0) and isExtra(part1) then
					table.insert(report, string.format("   %s '%s' (%s -> %s)", kind, descendant.Name, part0.Name, part1.Name))
					local better = weaponJointTemplate == nil
						or (weaponJointTemplate.Kind ~= "Motor6D" and kind == "Motor6D")
					if better then
						-- Si el rig trae una copia de la espada, se alinea nuestra pieza Base con la suya
						local swordFromProxy = CFrame.new()
						local rigBase = rig:FindFirstChild(HANDLE_NAME, true)
						if rigBase and rigBase:IsA("BasePart") and rigBase ~= part1 then
							swordFromProxy = part1.CFrame:ToObjectSpace(rigBase.CFrame)
						end
						weaponJointTemplate = {
							Name = if kind == "Motor6D" then descendant.Name else "WeaponJoint",
							Part0Name = part0.Name,
							Part1Name = part1.Name,
							C0 = c0,
							C1 = c1,
							Kind = kind,
							SwordFromProxy = swordFromProxy,
							RigName = rig.Name,
						}
					end
				end
			end
		end
	end

	if weaponJointTemplate then
		print(string.format(
			"[RibbonPhysicsClient] Unión del arma copiada del rig '%s': %s '%s' (%s -> %s)\n%s",
			weaponJointTemplate.RigName, weaponJointTemplate.Kind, weaponJointTemplate.Name,
			weaponJointTemplate.Part0Name, weaponJointTemplate.Part1Name, table.concat(report, "\n")
		))
	else
		warn("[RibbonPhysicsClient] No encontré ninguna unión de arma en Workspace." .. ANIMATION_RIGS_FOLDER
			.. ": se usa la soldadura simple (el arma NO coincidirá con la animación). Esto es lo que hay en los rigs:\n"
			.. table.concat(report, "\n"))
	end
	return weaponJointTemplate
end

-- Crea (o actualiza) la parte invisible con el nombre que usa la animación y su Motor6D al brazo. Devuelve la parte.
local function ensureWeaponProxy(character)
	local template = findWeaponJointTemplate()
	if not template then
		return nil
	end

	local part0 = character:FindFirstChild(template.Part0Name)
		or character:FindFirstChild("Right Arm")
		or character:FindFirstChild("RightHand")
	if not part0 then
		return nil
	end

	local proxy = character:FindFirstChild(template.Part1Name)
	if not proxy then
		proxy = Instance.new("Part")
		proxy.Name = template.Part1Name
		proxy.Size = Vector3.new(0.2, 0.2, 0.2)
		proxy.Transparency = 1
		proxy.CanCollide = false
		proxy.CanQuery = false
		proxy.CanTouch = false
		proxy.Massless = true
		proxy.CFrame = part0.CFrame * template.C0 * template.C1:Inverse()
		proxy.Parent = character
	end

	local joint = part0:FindFirstChild(template.Name)
	if not joint or not joint:IsA("Motor6D") then
		joint = Instance.new("Motor6D")
		joint.Name = template.Name
		joint.Part0 = part0
		joint.Part1 = proxy
		joint.Parent = part0
	end
	joint.C0 = template.C0 * CFrame.new(gripTune) -- el ajustador mueve el arma en el espacio de la unión
	joint.C1 = template.C1

	return proxy, part0, joint
end

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

	-- Con la Motor6D del rig: la espada se suelda a la parte que anima la animación; si no, a la mano (modo anterior).
	local anchorPart = hand
	local anchorCFrame = hand.CFrame * CFrame.new(gripTune) * GRIP_OFFSET
	local proxy, part0, joint = ensureWeaponProxy(character)
	if proxy and part0 and joint then
		anchorPart = proxy
		local fromProxy = if weaponJointTemplate then weaponJointTemplate.SwordFromProxy else CFrame.new()
		anchorCFrame = part0.CFrame * joint.C0 * joint.C1:Inverse() * fromProxy * SWORD_FROM_PROXY
	end

	local pivotRel = handle.CFrame:ToObjectSpace(sword:GetPivot())
	sword:PivotTo(anchorCFrame * pivotRel)

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
	hw.Part0 = anchorPart
	hw.Part1 = handle
	hw.Parent = handle
	return true
end

--------------------------------------------------------------------------------
-- UNA SIMULACIÓN POR ESPADA
--------------------------------------------------------------------------------
local equippedSword: Model? = nil -- espada equipada (para el ajustador)
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
			equippedSword = sword
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

-- [v2.12] Ajustador del agarre (ver GRIP_TUNER arriba)
if GRIP_TUNER then
	local UserInputService = game:GetService("UserInputService")
	local nudges = {
		[Enum.KeyCode.Up] = Vector3.new(0, 1, 0),
		[Enum.KeyCode.Down] = Vector3.new(0, -1, 0),
		[Enum.KeyCode.Right] = Vector3.new(1, 0, 0),
		[Enum.KeyCode.Left] = Vector3.new(-1, 0, 0),
		[Enum.KeyCode.PageUp] = Vector3.new(0, 0, 1),
		[Enum.KeyCode.PageDown] = Vector3.new(0, 0, -1),
	}
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not equippedSword then
			return
		end
		local nudge = nudges[input.KeyCode]
		if input.KeyCode == Enum.KeyCode.Delete then
			gripTune = Vector3.zero
		elseif nudge then
			local step = if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then 0.25 else 0.05
			gripTune += nudge * step
		else
			return
		end
		local character = player.Character
		if character then
			equipSword(equippedSword, character)
		end
		print(string.format(
			"[RibbonPhysicsClient] AJUSTE del arma (espacio de la unión Motor6D): local gripTune = Vector3.new(%.2f, %.2f, %.2f)",
			gripTune.X, gripTune.Y, gripTune.Z
		))
	end)
end
