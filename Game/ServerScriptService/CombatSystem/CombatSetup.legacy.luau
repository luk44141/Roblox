-- CombatSetup
-- Ubicación: ServerScriptService > CombatSystem
-- Prepara jugadores y dummies: hurtboxes, registro de combate, vida y comportamientos.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("CombatConfig"))
local HitboxService = require(script.Parent:WaitForChild("HitboxService"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local DummyPhysics = require(script.Parent:WaitForChild("DummyPhysics")) -- [v2.7]

---------------------------------------------------------------------
-- Jugadores
---------------------------------------------------------------------

local setupPlayers: { [Player]: boolean } = {}

local function onCharacterAdded(character: Model)
	-- Ambas funciones son idempotentes: no duplican hurtbox ni registro.
	HitboxService.AttachHurtbox(character, "Player")
	CombatService.Register(character, "Player")
end

local function onPlayerAdded(player: Player)
	if setupPlayers[player] then
		return
	end
	setupPlayers[player] = true

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	setupPlayers[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

---------------------------------------------------------------------
-- Vida de los dummies
---------------------------------------------------------------------

-- Vida infinita en la práctica: vida enorme, sin estado de muerte y restauración inmediata.
local function makeInfiniteHealth(humanoid: Humanoid)
	local maxHealth = CombatConfig.TrainingDummy.MaxHealth
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	humanoid.BreakJointsOnDeath = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

	humanoid.HealthChanged:Connect(function(health)
		if health < humanoid.MaxHealth then
			humanoid.Health = humanoid.MaxHealth
		end
	end)
end

-- Vida finita que no mata al dummy: se restaura tras `regenDelay` segundos sin recibir daño.
local function makeRegenerating(humanoid: Humanoid, maxHealth: number, regenDelay: number)
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	humanoid.BreakJointsOnDeath = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

	local token = 0
	humanoid.HealthChanged:Connect(function(health)
		if health >= humanoid.MaxHealth then
			return
		end
		token += 1
		local myToken = token
		task.delay(regenDelay, function()
			if myToken == token and humanoid.Parent then
				humanoid.Health = humanoid.MaxHealth
			end
		end)
	end)
end

---------------------------------------------------------------------
-- Dummies
---------------------------------------------------------------------

-- Ataque automático: temporizado y con cooldown (lo valida CombatService). Se detiene si el dummy se elimina.
local function startAutoAttack(dummy: Model, autoAttack)
	task.spawn(function()
		task.wait(autoAttack.Interval)
		while dummy.Parent do
			if autoAttack.Combo then
				-- [v2.12] Combo: cada golpe empieza apenas termina el anterior. Si algo lo corta (parry, stun), se
				-- interrumpe la cadena y espera el próximo ciclo.
				for _, attackName in ipairs(autoAttack.Combo) do
					if not CombatService.StartAttack(dummy, attackName) then
						break
					end
					local waited = 0
					repeat
						task.wait(0.03)
						waited += 0.03
					until CombatService.IsIdle(dummy) or waited > 3 or not dummy.Parent
				end
			else
				CombatService.StartAttack(dummy, autoAttack.Attack)
			end
			task.wait(autoAttack.Interval)
		end
	end)
end

local function setupDummy(dummy: Model, settings)
	local humanoid = dummy:WaitForChild("Humanoid", 5)
	local root = dummy:WaitForChild("HumanoidRootPart", 5)
	if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
		warn(`[CombatSetup] {dummy.Name} no tiene Humanoid y HumanoidRootPart; se omite.`)
		return
	end

	if humanoid.RigType ~= Enum.HumanoidRigType.R6 then
		warn(`[CombatSetup] {dummy.Name} no es R6. Recrealo con Rig Builder en R6.`)
	end

	if settings.Movable then
		-- [v2.7] Dummy móvil: se desancla y el servidor le aplica empuje / Uppercut / estampado / agarre (DummyPhysics).
		DummyPhysics.Setup(dummy, humanoid, root)
	else
		-- Estático: anclar el HumanoidRootPart ancla todo el rig.
		root.Anchored = true
	end

	dummy:SetAttribute("IsCombatDummy", true)
	dummy:SetAttribute("CombatRole", settings.Role)

	if settings.InfiniteHealth then
		dummy:SetAttribute("InfiniteHealth", true)
		makeInfiniteHealth(humanoid)
	else
		local defaults = CombatConfig.DummyDefaults
		makeRegenerating(humanoid, settings.MaxHealth or defaults.MaxHealth, defaults.RegenDelay)
	end

	HitboxService.AttachHurtbox(dummy, "Dummy")
	CombatService.Register(dummy, "Dummy", {
		PermanentBlock = settings.PermanentBlock,
		AutoParry = settings.AutoParry,
		Movable = settings.Movable,
	})

	if settings.AutoAttack then
		startAutoAttack(dummy, settings.AutoAttack)
	end
end

local dummiesFolder = workspace:WaitForChild(CombatConfig.DummyFolderName, 10)
if dummiesFolder then
	for dummyName, settings in pairs(CombatConfig.Dummies) do
		local dummy = dummiesFolder:FindFirstChild(dummyName)
		if dummy and dummy:IsA("Model") then
			task.spawn(setupDummy, dummy, settings)
		else
			warn(`[CombatSetup] No se encontró el modelo "{dummyName}" en Workspace.{CombatConfig.DummyFolderName}.`)
		end
	end
else
	warn(`[CombatSetup] No se encontró la carpeta Workspace.{CombatConfig.DummyFolderName}.`)
end