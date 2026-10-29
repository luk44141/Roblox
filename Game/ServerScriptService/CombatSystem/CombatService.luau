-- CombatService
-- Ubicación: ServerScriptService > CombatSystem
-- Estados de combate, combo, defensa, stun y daño. Toda la lógica es del servidor.
--
-- Prioridad de estados (de mayor a menor):
--   1. Stun: cancela el ataque en curso (y el dash) y bloquea ataque, bloqueo, parry y movimiento.
--   2. Guard break recibido: solo impide bloquear durante GuardBreakStun.
--   3. Ataque en curso (Windup / Active / Recovery): impide iniciar otro ataque, empezar a bloquear o hacer dash.
--   4. Dash (Active / Recovery): impide atacar y empezar a bloquear.
--   5. Bloqueo / parry: impide atacar y hacer dash.
--
-- Orden de resolución de un impacto (resolveHit):
--   canDamage -> Dodge (invulnerabilidad del dash / Perfect Dodge) -> Parry -> Guard break -> Block -> Hit
-- [NUEVO en esta versión]: DodgeService, acción "Dash" del remote, y los puntos marcados con [DASH].
-- [v2] Puntos marcados con [R] (habilidad R = ataque "Heavy": cooldown real de 20 s, combos), [CD] (cooldowns que
-- sobreviven al respawn y se publican como atributos del Player) y [DEF] (atributo CombatDefense para la velocidad).

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("CombatSystem")
local CombatConfig = require(CombatFolder:WaitForChild("CombatConfig"))
local HitboxService = require(script.Parent:WaitForChild("HitboxService"))
local DodgeService = require(script.Parent:WaitForChild("DodgeService")) -- [DASH]
local DummyPhysics = require(script.Parent:WaitForChild("DummyPhysics")) -- [v2.7] física de dummies móviles

local CombatService = {}

type CombatState = {
	character: Model,
	humanoid: Humanoid,
	player: Player?,                -- [CD] nil en dummies
	movable: boolean,               -- [v2.7] dummy móvil (Movable): recibe los efectos de movimiento desde el servidor
	ownerKind: string,
	action: string,                 -- "Idle" | "Windup" | "Active" | "Recovery"
	currentAttack: string?,
	attackToken: number,
	cooldowns: { [string]: number },
	blockHeld: boolean,
	permanentBlock: boolean,
	autoParry: boolean,
	parryUntil: number,
	parryReadyAt: number,
	guardBrokenUntil: number,
	stunUntil: number,
	stunImmuneUntil: number,
	stunToken: number,
	stunPhaseToken: number,
	hitStunUntil: number,           -- [HIT] hitstun por M1 recibido
	hitStunToken: number,
	hitStunPhaseToken: number,
	parryChance: boolean,           -- [HIT] queda 1 intento de parry para el próximo golpe
	slamStunUntil: number,          -- [AIR] estampado: stun en el que SOLO se puede hacer dash
	slamStunToken: number,
	slamStunPhaseToken: number,
	airLockUntil: number,           -- [AIR] rival lanzado por el Uppercut: solo puede bloquear / parrear
	airLockToken: number,
	airLockPhaseToken: number,
	airComboUntil: number,          -- [AIR] atacante tras un Uppercut conectado: su M1 es el AirSlam
	airComboToken: number,
	counterUntil: number,           -- [AIR] tras bloquear un AirSlam: ventana para pegar CounterM1
	counterToken: number,
	airPartner: CombatState?,       -- [AIR] el otro participante del combo aéreo (en ambos lados)
	hovering: boolean,              -- [AIR] el cliente está flotando por orden del servidor
	airLastActionAt: number,
	upHeld: boolean,                -- [AIR] el cliente mantiene la tecla del Uppercut (Espacio)
	runArmed: boolean,              -- (sin uso desde v2.5: el ataque corriendo solo depende de su cooldown)
	grabUntil: number,              -- [AIR] agarre en curso (R en el aire): hasta cuándo sostiene al rival
	grabToken: number,
	m1Held: boolean,                -- [COMBO] el cliente mantiene el clic: el combo de 4 M1 se encadena solo
	feintReadyAt: number,           -- [FINTA] cooldown de la finta
	activeStartedAt: number,        -- [FINTA] cuándo empezó la fase de impacto del ataque actual
	blockMeter: number,             -- [BLOQUEO] barra de bloqueo (solo jugadores)
	blockRegenAt: number,
	blockExhaustedUntil: number,
	blockMeterRate: number,
	blockWasExhausted: boolean,
	comboIndex: number,
	comboWindowUntil: number,
	comboEndCooldownUntil: number,
	bufferedM1At: number?,
	bufferedHeavyAt: number?,       -- [R] R pulsada durante Active/Recovery de un M1
	phaseToken: number,
	telegraphing: boolean,
	tracks: { [string]: AnimationTrack },
	currentTrack: AnimationTrack?,
	dead: boolean,
}

type RegisterOptions = {
	PermanentBlock: boolean?,
	AutoParry: boolean?,
	Movable: boolean?,
}

local states: { [Model]: CombatState } = {}

-- [CD] Cooldowns de ataques de los JUGADORES, por UserId: sobreviven al respawn (morir ya no resetea la R).
-- Cada valor es un os.clock() de "listo desde".
local playerCooldowns: { [number]: { [string]: number } } = {}

local COMBO_SEQUENCE = CombatConfig.Combo.Sequence
local COMBO_INDEX_OF: { [string]: number } = {}
for index, attackName in ipairs(COMBO_SEQUENCE) do
	COMBO_INDEX_OF[attackName] = index
end

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------

local remotesFolder = CombatFolder:FindFirstChild(CombatConfig.Remotes.FolderName)
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = CombatConfig.Remotes.FolderName
	remotesFolder.Parent = CombatFolder
end

local function getOrCreateRemote(name: string): RemoteEvent
	local remote = remotesFolder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = remotesFolder
	end
	return remote :: RemoteEvent
end

local requestRemote = getOrCreateRemote(CombatConfig.Remotes.Request)
local feedbackRemote = getOrCreateRemote(CombatConfig.Remotes.Feedback)

local function fireFeedback(payload)
	feedbackRemote:FireAllClients(payload)
end

-- [v2.11] Durante el combo aéreo los dos personajes NO chocan entre sí (grupo "AirCombo"): sin eso, al subir juntos se
-- empujaban, el atacante retrocedía y el agarre arrastraba a los dos. Siguen chocando con el mapa.
local AIR_COLLISION_GROUP = "AirCombo"
pcall(function()
	PhysicsService:RegisterCollisionGroup(AIR_COLLISION_GROUP)
end)
pcall(function()
	PhysicsService:CollisionGroupSetCollidable(AIR_COLLISION_GROUP, AIR_COLLISION_GROUP, false)
end)

local function setAirCollision(character: Model, enabled: boolean)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = if enabled then AIR_COLLISION_GROUP else "Default"
		end
	end
end

-- [v2.7] Efectos de movimiento sobre el OBJETIVO (Knockback / Launch / LaunchEnd / Slam / Grab / GrabEnd): un jugador los
-- aplica en su propio cliente; un dummy móvil, aquí en el servidor (DummyPhysics). Un dummy anclado los ignora.
local function sendEffect(state: CombatState, payload)
	if state.player then
		feedbackRemote:FireClient(state.player, payload)
	elseif state.movable then
		DummyPhysics.Apply(state.character, payload)
	end
end

-- [CD] Publica cuándo termina un cooldown como atributo del Player ("CooldownEnd_<clave>", tiempo del SERVIDOR
-- según Workspace:GetServerTimeNow; 0 = listo). Es la única fuente que lee el HUD del cliente.
local function publishCooldown(player: Player, key: string, readyAtClock: number)
	local remaining = readyAtClock - os.clock()
	player:SetAttribute("CooldownEnd_" .. key, if remaining > 0 then workspace:GetServerTimeNow() + remaining else 0)
end

---------------------------------------------------------------------
-- Consultas de estado
---------------------------------------------------------------------

local function isAlive(state: CombatState): boolean
	return not state.dead and state.humanoid.Health > 0 and state.character.Parent ~= nil
end

local function isStunned(state: CombatState, now: number): boolean
	return now < state.stunUntil
end

-- [HIT] Hitstun de combo: no se puede actuar, pero el parry sigue permitido (ver SetBlockHeld).
local function isHitStunned(state: CombatState, now: number): boolean
	return now < state.hitStunUntil
end

-- Bloqueos "duros": stun real, hitstun de combo o rival lanzado por el Uppercut. Impiden también el dash.
local function isHardLocked(state: CombatState, now: number): boolean
	return now < state.stunUntil or now < state.hitStunUntil or now < state.airLockUntil
end

-- Además del anterior, el stun de estampado (SlamStun): impide atacar, bloquear y R, pero NO el dash.
local function isActionLocked(state: CombatState, now: number): boolean
	return isHardLocked(state, now) or now < state.slamStunUntil
end

local function isBlocking(state: CombatState, now: number): boolean
	return (state.blockHeld or state.permanentBlock)
		and now >= state.guardBrokenUntil
		and now >= state.blockExhaustedUntil -- [BLOQUEO] barra agotada: 2 s sin poder bloquear
		and not isStunned(state, now)
		and not isHitStunned(state, now)
		and now >= state.slamStunUntil
end

local function isParryActive(state: CombatState, now: number): boolean
	return (state.autoParry or now < state.parryUntil) and not isStunned(state, now)
end

---------------------------------------------------------------------
-- Visuales de hurtbox
---------------------------------------------------------------------

local function refreshDefenseVisual(state: CombatState)
	local now = os.clock()
	local visual = "Normal"
	if isParryActive(state, now) then
		visual = "Parry"
	elseif isBlocking(state, now) then
		visual = "Blocking"
	end
	HitboxService.SetHurtboxState(state.character, visual)

	-- [DEF] El cliente (init.local) lo traduce en la fase de movimiento "Block" / "Parry".
	if state.ownerKind == "Player" then
		state.character:SetAttribute("CombatDefense", if visual == "Normal" then "None" else visual)
	end
end

local function scheduleVisualRefresh(state: CombatState, delaySeconds: number)
	task.delay(delaySeconds + 0.02, function()
		if states[state.character] == state then
			refreshDefenseVisual(state)
		end
	end)
end

---------------------------------------------------------------------
-- Fase de movimiento (la lee el cliente para limitar la movilidad)
---------------------------------------------------------------------

-- Devuelve un token: sirve para saber si la fase sigue siendo la misma al ejecutar un temporizador.
local function setMovePhase(state: CombatState, phase: string, profile: string?): number
	state.phaseToken += 1
	if state.ownerKind == "Player" then
		state.character:SetAttribute("CombatMoveProfile", profile or "Light")
		state.character:SetAttribute("CombatMovePhase", phase)
		state.character:SetAttribute("CombatDashCancel", false) -- [v2.10] runAttack lo activa en la recuperación de un M1
	end
	return state.phaseToken
end

---------------------------------------------------------------------
-- Animaciones (solo si hay un ID configurado)
---------------------------------------------------------------------

local function stopTrack(state: CombatState)
	if state.currentTrack then
		state.currentTrack:Stop(0.1)
		state.currentTrack = nil
	end
end

local function playAnimation(state: CombatState, animName: string)
	local id = CombatConfig.Animations[animName]
	if typeof(id) ~= "string" or id == "" then
		return
	end

	local track = state.tracks[animName]
	if not track then
		local animator = state.humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = state.humanoid
		end

		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, loaded = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if not ok then
			warn(`[CombatService] No se pudo cargar la animación "{animName}": {loaded}`)
			return
		end
		loaded.Priority = Enum.AnimationPriority.Action
		-- [v2.12] Si la animación se publicó con "Looped", se repetía en bucle al apretar M1: se fuerza a reproducirse una vez.
		loaded.Looped = false
		state.tracks[animName] = loaded
		track = loaded
	end

	stopTrack(state)
	track:Play(0.05)
	state.currentTrack = track
end

---------------------------------------------------------------------
-- [BLOQUEO] Barra de bloqueo (solo jugadores)
---------------------------------------------------------------------

local applyStun -- se define más abajo (necesaria al romperse la guardia)

-- Publica la barra como atributos del Player para el HUD: valor, ritmo (por segundo, + recarga / - gasto), instante del
-- servidor y fin del cooldown. El cliente extrapola con ellos, así que solo se publica cuando cambia el ritmo.
local function publishBlockMeter(state: CombatState, rate: number)
	local player = state.player
	if not player then
		return
	end
	local serverNow = workspace:GetServerTimeNow()
	local locked = state.blockExhaustedUntil - os.clock()
	player:SetAttribute("BlockMeter", state.blockMeter)
	player:SetAttribute("BlockMeterRate", rate)
	player:SetAttribute("BlockMeterTime", serverNow)
	player:SetAttribute("BlockLockedUntil", if locked > 0 then serverNow + locked else 0)
end

local function exhaustBlock(state: CombatState, now: number)
	state.blockMeter = 0
	state.blockExhaustedUntil = now + CombatConfig.Block.Meter.DepletedCooldown
	state.blockWasExhausted = true
	state.blockMeterRate = math.huge -- fuerza a republicar en el próximo ciclo
	refreshDefenseVisual(state) -- CombatDefense vuelve a "None": el cliente deja de ir lento
	-- [v2.5] Guardia rota = mismo estado que le deja el parry al atacante (CombatConfig.Stun.OnParried).
	applyStun(state, CombatConfig.Stun.OnParried.Player)
end

-- Cada golpe bloqueado cuesta HitCost de barra.
local function drainBlockMeter(state: CombatState, cost: number, now: number)
	if not state.player or now < state.blockExhaustedUntil then
		return
	end
	state.blockMeter = math.max(0, state.blockMeter - cost)
	state.blockRegenAt = now + CombatConfig.Block.Meter.RegenDelay
	state.blockMeterRate = math.huge
	if state.blockMeter <= 0 then
		exhaustBlock(state, now)
	end
end

local function updateBlockMeter(state: CombatState, now: number, dt: number)
	local meter = CombatConfig.Block.Meter
	local rate = 0

	if now >= state.blockExhaustedUntil then
		if state.blockWasExhausted then
			-- Terminó el cooldown de 2 s: la barra vuelve llena y, si F sigue apretada, vuelve el bloqueo.
			state.blockWasExhausted = false
			state.blockMeter = meter.Max
			state.blockMeterRate = math.huge
			refreshDefenseVisual(state)
		end

		if isBlocking(state, now) then
			state.blockMeter = math.max(0, state.blockMeter - meter.DrainPerSecond * dt)
			state.blockRegenAt = now + meter.RegenDelay
			rate = -meter.DrainPerSecond
			if state.blockMeter <= 0 then
				exhaustBlock(state, now)
				rate = 0
			end
		elseif now >= state.blockRegenAt and state.blockMeter < meter.Max then
			state.blockMeter = math.min(meter.Max, state.blockMeter + meter.RegenPerSecond * dt)
			rate = if state.blockMeter < meter.Max then meter.RegenPerSecond else 0
		end
	end

	if rate ~= state.blockMeterRate then
		state.blockMeterRate = rate
		publishBlockMeter(state, rate)
	end
end

---------------------------------------------------------------------
-- Cancelación y stun
---------------------------------------------------------------------

-- Cancela el ataque en curso y limpia el combo. No toca el stun.
local function cancelAttack(state: CombatState)
	state.attackToken += 1
	state.action = "Idle"
	state.currentAttack = nil
	state.bufferedM1At = nil
	state.bufferedHeavyAt = nil
	state.comboIndex = 0
	state.comboWindowUntil = 0
	if state.player then
		state.player:SetAttribute("ComboCountUntil", 0) -- [v2.8] el combo se cortó: se apaga el contador
	end
	stopTrack(state)

	if state.telegraphing then
		state.telegraphing = false
		fireFeedback({ Kind = "TelegraphCancel", Attacker = state.character })
	end
end

local function endStun(state: CombatState, token: number)
	if state.stunToken ~= token then
		return
	end
	state.character:SetAttribute("CombatStunned", false)
	stopTrack(state)
	if state.phaseToken == state.stunPhaseToken then
		setMovePhase(state, "None")
	end
	refreshDefenseVisual(state)
end

-- Un stun en curso nunca se reinicia, y tras terminar hay un periodo de inmunidad.
function applyStun(state: CombatState, duration: number): boolean
	local now = os.clock()
	if not isAlive(state) or now < state.stunUntil or now < state.stunImmuneUntil then
		return false
	end

	state.stunUntil = now + duration
	state.stunImmuneUntil = state.stunUntil + CombatConfig.Stun.ImmunityAfter
	state.parryUntil = 0
	state.stunToken += 1
	local token = state.stunToken

	DodgeService.Cancel(state.character, "Stunned") -- [DASH] El stun cancela el dash en curso
	cancelAttack(state)
	state.stunPhaseToken = setMovePhase(state, "Stunned")
	state.character:SetAttribute("CombatStunned", true)
	playAnimation(state, "Stun")
	refreshDefenseVisual(state)

	fireFeedback({
		Kind = "Stun",
		Target = state.character,
		Duration = duration,
		EndTime = workspace:GetServerTimeNow() + duration,
	})

	task.delay(duration, function()
		if states[state.character] == state then
			endStun(state, token)
		end
	end)

	return true
end

---------------------------------------------------------------------
-- [HIT] Hitstun y empuje por M1 recibido
---------------------------------------------------------------------

-- Termina el hitstun (por tiempo o por parry exitoso). Es idempotente.
local function clearHitStun(state: CombatState)
	local wasHitStunned = state.hitStunUntil > 0
	state.hitStunToken += 1
	state.hitStunUntil = 0
	state.parryChance = false
	if wasHitStunned and state.phaseToken == state.hitStunPhaseToken and not isStunned(state, os.clock()) then
		setMovePhase(state, "None")
	end
	refreshDefenseVisual(state)
end

local function applyHitReaction(attackerState: CombatState, targetState: CombatState, attackName: string, attackDef, now: number)
	local cfg = CombatConfig.HitReaction
	if not cfg.Enabled or not (targetState.ownerKind == "Player" or targetState.movable) or not isAlive(targetState) then
		return
	end

	-- [AIR] El rival lanzado por el Uppercut solo puede bloquear / parrear: sin hitstun, pero cada M1 del combo que
	-- conecta lo EMPUJA un poco hacia atrás (el atacante tiene que avanzar con W para seguir pegando).
	if now < targetState.airLockUntil then
		local cfgAir = CombatConfig.Uppercut
		local airRoot = attackerState.character:FindFirstChild("HumanoidRootPart")
		if COMBO_INDEX_OF[attackName] and cfgAir.AirPush > 0 and airRoot and airRoot:IsA("BasePart") then
			local airLook = airRoot.CFrame.LookVector
			local airFlat = Vector3.new(airLook.X, 0, airLook.Z)
			if airFlat.Magnitude > 1e-3 then
				sendEffect(targetState, {
					Kind = "Knockback",
					Direction = airFlat.Unit,
					Distance = cfgAir.AirPush,
					Duration = cfgAir.AirPushTime,
				})
			end
		end
		return
	end

	-- Reacción propia del ataque (M1_4, RunAttack) o la genérica de los M1 del combo.
	local comboIndex = COMBO_INDEX_OF[attackName]
	local reaction = attackDef.HitReaction
	local duration: number
	local parryChance: boolean
	local distance: number
	local knockTime: number = cfg.Knockback.Duration

	if reaction then
		duration = reaction.Stun
		parryChance = reaction.ParryChance == true
		distance = reaction.Knockback or 0
		knockTime = reaction.KnockbackTime or knockTime
	elseif comboIndex and comboIndex < #COMBO_SEQUENCE then
		local nextDef = CombatConfig.Attacks[COMBO_SEQUENCE[comboIndex + 1]]
		-- [v2.15] El siguiente golpe llega, encadenado, Active + Windup siguiente después de este impacto.
		duration = attackDef.Active + nextDef.Windup + cfg.StunSlack
		parryChance = true
		distance = cfg.Knockback.Distance
	else
		return -- R, golpes de dummies, etc.: sin hitstun
	end

	-- Lo que estaba haciendo el objetivo se cancela.
	DodgeService.Cancel(targetState.character, "Hit")
	cancelAttack(targetState)

	targetState.hitStunUntil = math.max(targetState.hitStunUntil, now + duration)
	targetState.parryChance = parryChance
	targetState.hitStunToken += 1
	local token = targetState.hitStunToken
	targetState.hitStunPhaseToken = setMovePhase(targetState, "Stunned")
	refreshDefenseVisual(targetState)

	task.delay(targetState.hitStunUntil - now, function()
		if states[targetState.character] == targetState and targetState.hitStunToken == token then
			clearHitStun(targetState)
		end
	end)

	-- Empuje: en la dirección a la que mira el atacante (plano horizontal). Lo ejecuta el cliente del objetivo.
	local attackerRoot = attackerState.character:FindFirstChild("HumanoidRootPart")
	if distance > 0 and attackerRoot and attackerRoot:IsA("BasePart") then
		local look = attackerRoot.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 1e-3 then
			sendEffect(targetState, {
				Kind = "Knockback",
				Direction = flat.Unit,
				Distance = distance,
				Duration = knockTime,
			})
		end
	end
end

---------------------------------------------------------------------
-- [AIR] Uppercut: combo aéreo de 4 golpes
---------------------------------------------------------------------

local function clearAirLock(state: CombatState)
	if state.airLockUntil == 0 then
		return
	end
	local now = os.clock()
	state.airLockUntil = 0
	state.airLockToken += 1
	if state.phaseToken == state.airLockPhaseToken and not isStunned(state, now) and now >= state.hitStunUntil then
		setMovePhase(state, "None")
	end
	refreshDefenseVisual(state)
end

local function endAirCombo(state: CombatState)
	state.airComboUntil = 0
	state.airComboToken += 1
	state.character:SetAttribute("CombatAirCombo", false) -- el cliente deja de penalizar el movimiento
end

-- Hace que el cliente del jugador flote (Launch) o vuelva a la gravedad normal (LaunchEnd).
local function setHover(state: CombatState, on: boolean)
	if state.hovering == on then
		return
	end
	state.hovering = on
	if on then
		local cfg = CombatConfig.Uppercut
		sendEffect(state, {
			Kind = "Launch",
			VelocityY = cfg.LaunchSpeed,
			RiseTime = cfg.RiseTime,
			MaxTime = cfg.AirWindow + 1, -- tope de seguridad del cliente
		})
	else
		sendEffect(state, { Kind = "LaunchEnd" })
	end
end

-- Termina TODA la secuencia aérea de ambos participantes (caen los dos, el rival vuelve a la normalidad).
local function releaseAir(state: CombatState)
	local partner = state.airPartner
	for _, participant in { state, partner } do
		participant.airPartner = nil
		endAirCombo(participant)
		clearAirLock(participant)
		setHover(participant, false)
		setAirCollision(participant.character, false)
	end
end

local function clearSlamStun(state: CombatState)
	if state.slamStunUntil == 0 then
		return
	end
	local now = os.clock()
	state.slamStunUntil = 0
	state.slamStunToken += 1
	state.character:SetAttribute("CombatDashable", false)
	if state.phaseToken == state.slamStunPhaseToken and not isStunned(state, now) and now >= state.hitStunUntil then
		setMovePhase(state, "None")
	end
	refreshDefenseVisual(state)
end

-- Estampado: stun en el que solo se puede hacer dash (el dash lo corta: ver onDashStarted).
-- ¿Está apoyado en el suelo? (rayo corto hacia abajo desde el HumanoidRootPart)
local function isGrounded(character: Model): boolean
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return true
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	return workspace:Raycast(root.Position, Vector3.new(0, -4.5, 0), params) ~= nil
end

-- Estampado / lanzamiento: stun en el que SOLO se puede hacer dash (el dash lo corta: ver onDashStarted). Mientras vuela
-- vale SlamAirMax como tope; al aterrizar pasa a durar SlamStun segundos EN EL PISO.
local function applySlamStun(state: CombatState, now: number)
	local cfg = CombatConfig.Uppercut
	DodgeService.Cancel(state.character, "Slam")
	cancelAttack(state)

	state.slamStunUntil = now + cfg.SlamAirMax
	state.slamStunToken += 1
	local token = state.slamStunToken
	state.character:SetAttribute("CombatDashable", true)
	state.slamStunPhaseToken = setMovePhase(state, "Stunned")
	refreshDefenseVisual(state)

	task.spawn(function()
		local landed = false
		while states[state.character] == state and state.slamStunToken == token do
			task.wait(0.05)
			local t = os.clock()
			if not landed and t - now > 0.12 and isGrounded(state.character) then
				landed = true
				state.slamStunUntil = t + cfg.SlamStun
				-- [v2.11] Indicador de STUN visible sobre el que aterrizó (también en dummies)
				fireFeedback({
					Kind = "Stun",
					Target = state.character,
					Duration = cfg.SlamStun,
					EndTime = workspace:GetServerTimeNow() + cfg.SlamStun,
				})
				if CombatConfig.Debug.PrintResults then
					print(string.format("[Combat] SLAM STUN: %s aterrizó, aturdido %.1fs (dash lo corta)", state.character.Name, cfg.SlamStun))
				end
			end
			if t >= state.slamStunUntil then
				clearSlamStun(state)
				return
			end
		end
	end)
end

local function sendSlam(state: CombatState)
	sendEffect(state, { Kind = "Slam", Speed = CombatConfig.Uppercut.SlamSpeed })
end

-- Empuje horizontal en la dirección a la que mira el atacante (lo aplica el cliente del objetivo).
local function sendKnockbackFrom(attackerState: CombatState, targetState: CombatState, distance: number, duration: number)
	local root = attackerState.character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 1e-3 then
		sendEffect(targetState, {
			Kind = "Knockback",
			Direction = flat.Unit,
			Distance = distance,
			Duration = duration,
		})
	end
end

-- El Uppercut conectó: los dos suben y flotan. El rival solo puede bloquear / parrear; el atacante empieza un combo NUEVO.
local function startAirCombo(attackerState: CombatState, targetState: CombatState, now: number)
	local cfg = CombatConfig.Uppercut

	DodgeService.Cancel(targetState.character, "Launched")
	cancelAttack(targetState)
	targetState.airLockUntil = now + cfg.AirWindow
	targetState.airLockToken += 1
	targetState.airLockPhaseToken = setMovePhase(targetState, "Stunned")
	targetState.counterUntil = 0
	targetState.counterToken += 1
	refreshDefenseVisual(targetState)

	attackerState.airComboUntil = now + cfg.AirWindow
	attackerState.airComboToken += 1
	local token = attackerState.airComboToken
	attackerState.airLastActionAt = now
	attackerState.comboIndex = 0 -- combo nuevo: M1_1, M1_2, M1_3 y el 4º es el AirSlam
	attackerState.comboWindowUntil = 0
	attackerState.comboEndCooldownUntil = 0
	attackerState.airPartner = targetState
	targetState.airPartner = attackerState
	attackerState.character:SetAttribute("CombatAirCombo", true) -- movimiento penalizado: el rival queda delante

	-- Ayuda de apuntado continua durante todo el combo aéreo
	if attackerState.player and CombatConfig.Assist.Enabled then
		feedbackRemote:FireClient(attackerState.player, {
			Kind = "Assist",
			Target = targetState.character,
			Duration = cfg.AirWindow,
			Gap = 0,
		})
	end

	setAirCollision(attackerState.character, true)
	setAirCollision(targetState.character, true)
	setHover(attackerState, true)
	setHover(targetState, true)

	if CombatConfig.Debug.PrintResults then
		print(string.format("[Combat] UPPERCUT %s -> %s: combo aéreo iniciado", attackerState.character.Name, targetState.character.Name))
	end

	-- Vigilante: si el atacante deja de pegar, se aturde, muere, o se agota el tiempo, caen los dos.
	task.spawn(function()
		while attackerState.airComboToken == token do
			task.wait(0.1)
			if attackerState.airComboToken ~= token then
				return
			end
			local t = os.clock()
			local idle = cfg.AirIdle > 0 and attackerState.action == "Idle" and t - attackerState.airLastActionAt > cfg.AirIdle
			if t >= attackerState.airComboUntil
				or idle
				or not isAlive(attackerState)
				or not isAlive(targetState)
				or isStunned(attackerState, t)
			then
				releaseAir(attackerState)
				return
			end
		end
	end)
end

-- [v2.5] R en el aire: el rival queda sujeto GrabDuration segundos delante del atacante y después sale despedido lejos.
local function startGrab(attackerState: CombatState, victimState: CombatState, now: number)
	local cfg = CombatConfig.Uppercut

	endAirCombo(attackerState) -- no hay más M1 aéreos; los dos siguen flotando mientras dura el agarre
	victimState.counterUntil = 0
	victimState.airLockUntil = math.max(victimState.airLockUntil, now + cfg.GrabDuration + 1)
	attackerState.grabUntil = now + cfg.GrabDuration
	attackerState.grabToken += 1
	local token = attackerState.grabToken

	sendEffect(attackerState, { Kind = "Freeze" }) -- [v2.11] el atacante queda totalmente quieto (también en horizontal)
	sendEffect(victimState, {
		Kind = "Grab",
		Holder = attackerState.character,
		Duration = cfg.GrabDuration,
		Offset = cfg.GrabOffset,
	})

	task.spawn(function()
		while attackerState.grabToken == token do
			task.wait(0.05)
			if attackerState.grabToken ~= token then
				return
			end
			local t = os.clock()
			local broken = not isAlive(attackerState) or not isAlive(victimState) or isStunned(attackerState, t)
			if t >= attackerState.grabUntil or broken then
				attackerState.grabUntil = 0
				attackerState.grabToken += 1
				sendEffect(victimState, { Kind = "GrabEnd" })
				releaseAir(attackerState) -- caen los dos
				if not broken and isAlive(victimState) then
					sendKnockbackFrom(attackerState, victimState, cfg.GrabThrowDistance, cfg.GrabThrowTime)
					applySlamStun(victimState, os.clock()) -- [v2.10] stun en el piso con dash, igual que el 4º golpe aéreo
				end
				return
			end
		end
	end)
end

-- Consecuencias del resultado de los golpes del combo aéreo (solo jugadores).
local function applyAirEffects(attackerState: CombatState, targetState: CombatState, attackDef, outcome: string, now: number)
	local cfg = CombatConfig.Uppercut
	if not cfg.Enabled then
		return
	end

	if attackDef.Launcher then
		if outcome == "Hit"
			and attackerState.ownerKind == "Player"
			and (targetState.ownerKind == "Player" or targetState.movable)
			and isAlive(targetState)
		then
			startAirCombo(attackerState, targetState, now)
		end
		return
	end

	if attackerState.airPartner == nil then
		return -- no hay combo aéreo en curso
	end

	-- Parry en cualquier golpe aéreo: caen los dos (resolveHit aturde al atacante ParriedStun).
	if outcome == "Parried" then
		releaseAir(attackerState)
		return
	end

	if attackDef.Grab then
		if outcome == "Hit" and isAlive(targetState) then
			startGrab(attackerState, targetState, now)
		else
			releaseAir(attackerState)
		end
	elseif attackDef.AirSlam then
		if outcome == "Blocked" then
			-- El que bloqueó el 4º golpe puede contraatacar con UN M1 mientras siguen flotando.
			endAirCombo(attackerState)
			clearAirLock(targetState)
			targetState.counterUntil = now + cfg.CounterWindow
			targetState.counterToken += 1
			local token = targetState.counterToken
			task.delay(cfg.CounterWindow + 0.05, function()
				if states[targetState.character] == targetState and targetState.counterToken == token then
					targetState.counterUntil = 0
					releaseAir(attackerState) -- no contraatacó (o ya terminó): caen los dos
				end
			end)
		else
			releaseAir(attackerState)
			if outcome == "Hit" and isAlive(targetState) then
				-- [v2.5] Lo estampa, lo manda LEJOS y lo aturde SlamStun (2 s) salvo que haga dash.
				sendSlam(targetState)
				sendKnockbackFrom(attackerState, targetState, cfg.SlamKnockback, cfg.SlamKnockbackTime)
				applySlamStun(targetState, now)
			end
		end
	elseif attackDef.CounterSlam then
		attackerState.counterUntil = 0
		releaseAir(attackerState)
		if outcome == "Hit" and isAlive(targetState) then
			sendSlam(targetState)
			sendKnockbackFrom(attackerState, targetState, cfg.SlamKnockback, cfg.SlamKnockbackTime)
			applySlamStun(targetState, now) -- el atacante original cae lejos y aturdido, pero puede recuperarse con dash
		end
	end
end

---------------------------------------------------------------------
-- Resolución de impactos
---------------------------------------------------------------------

-- [v2.10] ¿El atacante está delante del defensor? Bloquear y parrear no funcionan contra golpes por la espalda.
local function isAttackFromFront(attackerState: CombatState, targetState: CombatState): boolean
	local targetRoot = targetState.character:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attackerState.character:FindFirstChild("HumanoidRootPart")
	if not targetRoot or not attackerRoot or not targetRoot:IsA("BasePart") or not attackerRoot:IsA("BasePart") then
		return true
	end
	local look = targetRoot.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local offset = attackerRoot.Position - targetRoot.Position
	local flatOffset = Vector3.new(offset.X, 0, offset.Z)
	if flatLook.Magnitude < 0.01 or flatOffset.Magnitude < 0.01 then
		return true
	end
	return flatLook.Unit:Dot(flatOffset.Unit) >= math.cos(math.rad(CombatConfig.Block.FrontHalfAngle))
end

local function resolveOutcome(attackDef, targetState: CombatState, now: number, attackerState: CombatState): (string, number)
	-- [v2.10] Por la espalda no hay parry ni bloqueo: conecta normal (y arranca el combo).
	if not isAttackFromFront(attackerState, targetState) then
		return "Hit", attackDef.Damage
	end

	if attackDef.CanBeParried and isParryActive(targetState, now) then
		return "Parried", 0
	end

	if isBlocking(targetState, now) then
		if attackDef.BreaksGuard then
			return "GuardBroken", attackDef.Damage
		end
		if attackDef.CanBeBlocked then
			return "Blocked", attackDef.Damage * CombatConfig.Block.DamageMultiplier
		end
	end

	return "Hit", attackDef.Damage
end

local function canDamage(attackerState: CombatState, targetState: CombatState): boolean
	if attackerState == targetState or attackerState.character == targetState.character then
		return false
	end
	if not isAlive(targetState) then
		return false
	end
	if targetState.character:FindFirstChildOfClass("ForceField") then
		return false
	end

	local rules = CombatConfig.Rules
	if attackerState.ownerKind == "Dummy" and targetState.ownerKind == "Dummy" and not rules.DummiesCanDamageDummies then
		return false
	end
	if attackerState.ownerKind == "Player" and targetState.ownerKind == "Player" and not rules.PlayersCanDamagePlayers then
		return false
	end

	return true
end

local function resolveHit(attackerState: CombatState, targetState: CombatState, attackName: string, attackDef)
	if not canDamage(attackerState, targetState) then
		return
	end

	local now = os.clock()

	-- [DASH] 1) Dodge: un golpe que YA habría impactado (hitbox + canDamage) y cae dentro de la
	-- invulnerabilidad del dash. Va antes de parry/block: un personaje en dash nunca está bloqueando
	-- ni con ventana de parry (iniciar el dash las cancela), así que no hay solapamiento con esas reglas.
	-- Devuelve "PerfectDodge" solo si el golpe llega dentro de PerfectDodgeWindow desde el inicio del dash.
	local outcome: string
	local damage: number
	local dodgeResult = DodgeService.ResolveIncomingHit(targetState.character, {
		Attacker = attackerState.character,
		Attack = attackName,
	})
	if attackDef.Grab then
		outcome, damage = "Hit", attackDef.Damage -- [v2.5] el agarre no se bloquea, no se parrea ni se esquiva
	elseif dodgeResult then
		outcome, damage = dodgeResult, 0
	else
		outcome, damage = resolveOutcome(attackDef, targetState, now, attackerState)
	end

	if outcome == "GuardBroken" then
		local stun = CombatConfig.Block.GuardBreakStun
		targetState.guardBrokenUntil = now + stun
		targetState.parryUntil = 0
		refreshDefenseVisual(targetState)
		scheduleVisualRefresh(targetState, stun)
	end

	-- Daño real confirmado: lo que se resta y lo que se muestra es la misma cifra.
	local dealt = 0
	if damage > 0 then
		dealt = math.min(damage, targetState.humanoid.Health)
		targetState.humanoid:TakeDamage(dealt) -- [v2] antes TakeDamage(damage): ahora se aplica lo mismo que se registra
	end

	-- [BLOQUEO] Cada golpe bloqueado le cuesta barra al que bloquea.
	if outcome == "Blocked" then
		drainBlockMeter(targetState, CombatConfig.Block.Meter.HitCost, now)
	end

	-- [HIT] M1 que conecta = hitstun + empuje; un parry exitoso libera al objetivo.
	if outcome == "Hit" and targetState.humanoid.Health > 0 then
		applyHitReaction(attackerState, targetState, attackName, attackDef, now)
	elseif outcome == "Parried" then
		clearHitStun(targetState)
	end

	-- [AIR] Uppercut / combo aéreo / contraataque
	local attackerInAir = attackerState.airPartner ~= nil
	applyAirEffects(attackerState, targetState, attackDef, outcome, now)

	-- Un parry exitoso aturde al atacante (una sola vez por impacto).
	if outcome == "Parried" then
		local durations = CombatConfig.Stun.OnParried
		local duration = if attackerState.ownerKind == "Player" then durations.Player else durations.Dummy
		if attackerInAir and attackerState.ownerKind == "Player" then
			duration = CombatConfig.Uppercut.ParriedStun -- el rival tiene tiempo de empezar combo
		end
		applyStun(attackerState, duration)
	end

	local target = targetState.character
	target:SetAttribute("LastHitResult", outcome)
	target:SetAttribute("LastHitAttack", attackName)
	target:SetAttribute("LastHitDamage", dealt)
	target:SetAttribute("LastHitBy", attackerState.character.Name)
	target:SetAttribute("LastHitSerial", (target:GetAttribute("LastHitSerial") or 0) + 1)

	if CombatConfig.Debug.PrintResults then
		print(string.format(
			"[Combat] %s -> %s | %s | %s | daño %.1f",
			attackerState.character.Name,
			target.Name,
			attackName,
			outcome,
			dealt
			))
	end

	if CombatConfig.Feedback.Enabled then
		local variant = "Normal"
		if attackDef.Finisher then
			variant = "Finisher"
		elseif attackDef.BreaksGuard then
			variant = "GuardBreak"
		end

		fireFeedback({
			Kind = "Damage",
			Target = target,
			Result = outcome,
			Amount = dealt,
			Attack = attackName,
			Variant = variant,
		})
	end
end

---------------------------------------------------------------------
-- Ataques y combo
---------------------------------------------------------------------

local startComboHit
local startM1Action
local runAttack

local function stillValid(state: CombatState, token: number): boolean
	return states[state.character] == state and state.attackToken == token and isAlive(state)
end

-- [v2.7] Ayuda del combo AÉREO (en el suelo no hay ayuda): al empezar cada golpe se avisa al cliente del atacante del rival
-- atrapado, para que gire hacia él y se acerque un poco. Además el atacante tiene el movimiento muy penalizado
-- (atributo CombatAirCombo) para que el rival siempre quede delante.
-- [v2.8] Anticipación efectiva: los golpes del combo aéreo son más lentos (CombatConfig.Uppercut.AirWindupScale).
local function effectiveWindup(state: CombatState, attackName: string, def): number
	if state.airPartner ~= nil and (COMBO_INDEX_OF[attackName] or def.AirSlam) then
		return def.Windup * CombatConfig.Uppercut.AirWindupScale
	end
	return def.Windup
end

-- [v2.8] Contador de golpes del HUD (círculos): ComboCount 1..4, ComboAir, ComboCountUntil (tiempo del servidor).
local function publishComboCount(state: CombatState, attackName: string, def)
	local player = state.player
	if not player then
		return
	end
	local count = COMBO_INDEX_OF[attackName]
	if not count then
		if def.Launcher or def.AirSlam then
			count = #COMBO_SEQUENCE -- el Uppercut y el AirSlam son el 4º golpe
		else
			return -- R, ataque corriendo, contraataque: no tocan el contador
		end
	end
	local duration = effectiveWindup(state, attackName, def) + def.Active + def.Recovery + CombatConfig.Combo.Window
	player:SetAttribute("ComboCount", count)
	player:SetAttribute("ComboAir", state.airPartner ~= nil)
	player:SetAttribute("ComboCountUntil", workspace:GetServerTimeNow() + duration)
end

local function sendAirAssist(state: CombatState, def)
	local cfg = CombatConfig.Assist
	local targetState = state.airPartner
	if not cfg.Enabled or not state.player or not targetState or not isAlive(targetState) then
		return
	end
	local root = state.character:FindFirstChild("HumanoidRootPart")
	local targetRoot = targetState.character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or not targetRoot or not targetRoot:IsA("BasePart") then
		return
	end
	local offset = targetRoot.Position - root.Position
	feedbackRemote:FireClient(state.player, {
		Kind = "Assist",
		Target = targetState.character,
		Duration = def.Windup * CombatConfig.Uppercut.AirWindupScale + def.Active + 0.05,
		Gap = Vector3.new(offset.X, 0, offset.Z).Magnitude,
	})
end

local function beginAttack(state: CombatState, attackName: string, def)
	state.action = "Windup"
	state.currentAttack = attackName
	state.attackToken += 1
	state.bufferedM1At = nil
	state.bufferedHeavyAt = nil
	state.airLastActionAt = os.clock()
	local token = state.attackToken

	-- Un ataque fuera del combo reinicia el combo, SALVO que sea una habilidad que lo continúa (R: ContinuesCombo)
	-- y se use con el combo vivo (dentro de su ventana). Así R no interrumpe el combo: lo "puentea".
	if not COMBO_INDEX_OF[attackName] then
		local continues = def.ContinuesCombo == true
			and state.comboIndex > 0
			and os.clock() <= state.comboWindowUntil
		if not continues then
			state.comboIndex = 0
			state.comboWindowUntil = 0
		end
	end

	setMovePhase(state, "Windup", def.MovementProfile)
	playAnimation(state, attackName)
	sendAirAssist(state, def) -- [v2.7]
	publishComboCount(state, attackName, def) -- [v2.8]

	-- Indicador de timing: se calcula con el tiempo real de anticipación del servidor.
	local role = state.character:GetAttribute("CombatRole")
	if CombatConfig.Telegraph.Enabled and role ~= nil and CombatConfig.Telegraph.Roles[role] then
		state.telegraphing = true
		local now = workspace:GetServerTimeNow()
		fireFeedback({
			Kind = "Telegraph",
			Attacker = state.character,
			Attack = attackName,
			Label = def.Label or attackName,
			StartTime = now,
			ImpactTime = now + def.Windup,
			CanBeParried = def.CanBeParried,
			BreaksGuard = def.BreaksGuard,
			TrainDodge = def.TrainDodge, -- [v2] solo informativo para el telegraph del PerfectDodgeDummy
		})
	end

	task.spawn(runAttack, state, attackName, def, token)
end

-- [R] Consume las entradas recordadas durante Active/Recovery (M1 y/o R). Gana la más reciente; si no se puede
-- ejecutar (cooldown, stun...), se prueba la otra. Devuelve true si empezó un ataque. Las entradas se descartan siempre.
local function consumeBufferedInput(state: CombatState, now: number): boolean
	local bufferTime = CombatConfig.Combo.BufferTime
	local m1At = state.bufferedM1At
	local heavyAt = state.bufferedHeavyAt
	state.bufferedM1At = nil
	state.bufferedHeavyAt = nil

	local wantsM1 = m1At ~= nil and now - m1At <= bufferTime
	local wantsHeavy = heavyAt ~= nil and now - heavyAt <= bufferTime

	local heavyName = if state.airPartner ~= nil and now < state.airComboUntil then "AirGrab" else "Heavy"
	local heavyFirst = wantsHeavy and (not wantsM1 or (heavyAt :: number) >= (m1At :: number))
	if heavyFirst then
		if CombatService.StartAttack(state.character, heavyName) then
			return true
		end
		return wantsM1 and startM1Action(state, now, false)
	end

	if wantsM1 and startM1Action(state, now, false) then
		return true
	end
	if wantsHeavy and CombatService.StartAttack(state.character, heavyName) then
		return true
	end
	return false
end

-- Reabre la ventana de combo tras un golpe M1, o tras R cuando R puenteó un combo en curso.
local function openComboWindow(state: CombatState, def, now: number)
	state.comboWindowUntil = now + CombatConfig.Combo.Window

	-- [v2.5] Clic mantenido: el siguiente golpe del combo se encadena solo (como un clic recordado).
	if state.m1Held and state.bufferedM1At == nil then
		state.bufferedM1At = now
	end

	-- Entrada recordada durante Active/Recovery: encadena de inmediato.
	if consumeBufferedInput(state, now) then
		return
	end

	local phaseToken = setMovePhase(state, "ComboWindow", def.MovementProfile)
	task.delay(CombatConfig.Combo.Window, function()
		if states[state.character] == state and state.phaseToken == phaseToken then
			setMovePhase(state, "None")
		end
	end)
end

-- Termina la recuperación: abre la ventana de combo o cierra el combo.
local function finishAttack(state: CombatState, attackName: string, def)
	local now = os.clock()
	local comboIndex = COMBO_INDEX_OF[attackName]

	if not comboIndex then
		-- [R] R usada con un combo vivo (ver beginAttack): el combo sigue, con su mismo índice, y se reabre la ventana.
		if def.ContinuesCombo and state.comboIndex > 0 then
			openComboWindow(state, def, now)
		elseif def.Launcher then
			-- [AIR] Tras el Uppercut conectado empieza el combo aéreo: con el clic mantenido arranca solo; un clic
			-- recordado también. (Si el Uppercut no conectó, no se encadena nada.)
			if state.m1Held and state.airPartner ~= nil and state.bufferedM1At == nil then
				state.bufferedM1At = now
			end
			if not consumeBufferedInput(state, now) then
				setMovePhase(state, "None")
			end
		else
			state.bufferedM1At = nil
			state.bufferedHeavyAt = nil
			setMovePhase(state, "None")
		end
		return
	end

	if comboIndex >= #COMBO_SEQUENCE then
		state.comboIndex = 0
		state.comboWindowUntil = 0
		state.comboEndCooldownUntil = now + CombatConfig.Combo.EndCooldown
		-- [R] Una R recordada durante el golpe final sí se ejecuta (un M1 recordado no: lo frena EndCooldown).
		if not consumeBufferedInput(state, now) then
			setMovePhase(state, "None")
		end
		return
	end

	openComboWindow(state, def, now)
end

function runAttack(state: CombatState, attackName: string, def, token: number)
	-- Anticipación (más lenta en el combo aéreo)
	task.wait(effectiveWindup(state, attackName, def))
	if not stillValid(state, token) then
		return
	end

	-- Impacto: la caja se calcula UNA vez; se muestra y se consulta con los mismos datos.
	state.telegraphing = false
	state.action = "Active"
	setMovePhase(state, "Active", def.MovementProfile)
	state.activeStartedAt = os.clock()

	-- [v2.15] El golpe de un M1 de jugador se compromete CommitDelay segundos después de empezar el impacto: hasta entonces
	-- se puede fintar (clic derecho). La caja se calcula recién al comprometerse.
	local commitDelay = 0
	if COMBO_INDEX_OF[attackName] and state.ownerKind == "Player" then
		commitDelay = math.min(CombatConfig.Feint.CommitDelay, def.Active)
	end
	if commitDelay > 0 then
		task.wait(commitDelay)
		if not stillValid(state, token) then
			return
		end
	end

	local cframe, size = HitboxService.GetAttackBoxData(state.character, def.Box)
	if not cframe or not size then
		cancelAttack(state)
		setMovePhase(state, "None")
		return
	end

	HitboxService.ShowAttackBox(cframe, size, def.Active - commitDelay)

	local alreadyHit: { [Model]: boolean } = {}
	local startTime = os.clock()
	repeat
		for _, targetCharacter in ipairs(HitboxService.QueryBox(state.character, cframe, size)) do
			if not alreadyHit[targetCharacter] then
				alreadyHit[targetCharacter] = true -- un objetivo recibe un único impacto por golpe
				local targetState = states[targetCharacter]
				if targetState then
					resolveHit(state, targetState, attackName, def)
				end
			end
		end
		RunService.Heartbeat:Wait()
	until os.clock() - startTime >= def.Active - commitDelay or not stillValid(state, token)

	if not stillValid(state, token) then
		return
	end

	-- [v2.5] Agarre en curso: el atacante queda sujetando al rival hasta que termina (o se rompe) el agarre.
	while state.grabUntil > os.clock() and stillValid(state, token) do
		task.wait(0.05)
	end
	if not stillValid(state, token) then
		return
	end

	-- Recuperación
	state.action = "Recovery"
	setMovePhase(state, "Recovery", def.MovementProfile)
	-- [v2.10] En la recuperación de un M1 del combo se puede hacer dash (corta la recuperación y conserva el combo).
	if COMBO_INDEX_OF[attackName] and state.ownerKind == "Player" then
		state.character:SetAttribute("CombatDashCancel", true)
	end

	-- [v2.15] Si ya apretaste M1 de nuevo (o lo mantenés), el siguiente golpe arranca YA: la animación siguiente entra en el
	-- frame 30 de la anterior (fin del impacto), sin esperar la recuperación. No aplica al golpe final. Los dummies lo
	-- usan igual (CombatService.SetChainHeld) para hacer el combo seguido.
	local comboIndex = COMBO_INDEX_OF[attackName]
	local chained = comboIndex ~= nil
		and comboIndex < #COMBO_SEQUENCE
		and (
			state.m1Held
			or (state.bufferedM1At ~= nil and os.clock() - state.bufferedM1At <= CombatConfig.Combo.BufferTime)
		)
	if not chained then
		task.wait(def.Recovery)
	end
	if not stillValid(state, token) then
		return
	end

	state.action = "Idle"
	state.currentAttack = nil
	finishAttack(state, attackName, def)
end

function startComboHit(state: CombatState, now: number, upHeld: boolean?): boolean
	if now < state.comboEndCooldownUntil then
		return false
	end

	-- Si la ventana venció (o el combo terminó), vuelve al primer golpe.
	local index = state.comboIndex + 1
	if now > state.comboWindowUntil or index > #COMBO_SEQUENCE then
		index = 1
	end

	if index == #COMBO_SEQUENCE and state.ownerKind == "Player" and CombatConfig.Uppercut.Enabled then
		-- [AIR] En el combo aéreo, el 4º golpe es el AirSlam.
		if now < state.airComboUntil then
			beginAttack(state, "AirSlam", CombatConfig.Attacks.AirSlam)
			return true
		end
		-- [AIR] Con Espacio mantenido (aviso del cliente por UpHold, o en el propio clic), el 4º golpe es el Uppercut.
		if upHeld == true or state.upHeld then
			beginAttack(state, "Uppercut", CombatConfig.Attacks.Uppercut)
			return true
		end
	end

	state.comboIndex = index
	local attackName = COMBO_SEQUENCE[index]
	beginAttack(state, attackName, CombatConfig.Attacks[attackName])
	return true
end

-- [AIR] Qué hace un M1 cuando se puede actuar: AirSlam si estás en el combo aéreo, si no, el siguiente golpe del combo.
function startM1Action(state: CombatState, now: number, upHeld: boolean?): boolean
	return startComboHit(state, now, upHeld)
end

-- M1 del jugador: inicia o encadena el combo. Un clic durante Active/Recovery se recuerda.
-- upHeld: el cliente informa si mantiene Espacio (solo cambia el 4º golpe a Uppercut; el servidor valida el resto).
function CombatService.RequestM1(character: Model, upHeld: boolean?): boolean
	local state = states[character]
	if not state or not isAlive(state) then
		return false
	end

	local now = os.clock()

	-- [AIR] [v2.8] El rival lanzado NO tiene ataques, pero si el atacante deja de pegar puede apretar M1 y caen los dos.
	if now < state.airLockUntil and state.airPartner then
		local partner = state.airPartner
		if partner.grabUntil < now
			and partner.action == "Idle"
			and now > partner.comboWindowUntil
			and now - partner.airLastActionAt > CombatConfig.Uppercut.BreakIdle
		then
			releaseAir(state)
			return true
		end
		return false
	end

	-- [AIR] Contraataque tras bloquear un AirSlam: se permite aunque se siga sosteniendo F (se suelta la intención).
	if now < state.counterUntil and state.action == "Idle" and not isActionLocked(state, now) then
		if not DodgeService.IsBusy(character) then
			state.counterUntil = 0
			state.blockHeld = false
			refreshDefenseVisual(state)
			return CombatService.StartAttack(character, "CounterM1")
		end
	end

	if isActionLocked(state, now) or state.blockHeld or state.permanentBlock then
		return false
	end
	if DodgeService.IsBusy(character) then -- [DASH] No se ataca durante el dash ni su recuperación
		return false
	end

	if state.action == "Idle" then
		return startM1Action(state, now, upHeld)
	end

	local current = state.currentAttack
	if (state.action == "Active" or state.action == "Recovery") and current then
		local currentDef = CombatConfig.Attacks[current]
		-- [R] También se recuerda el clic durante una R que puentea un combo en curso.
		-- [AIR] ...y durante el Uppercut (el clic recordado pasa a ser el AirSlam).
		if COMBO_INDEX_OF[current]
			or (currentDef ~= nil and currentDef.ContinuesCombo and state.comboIndex > 0)
			or (currentDef ~= nil and currentDef.Launcher)
		then
			state.bufferedM1At = now
		end
	end
	return false
end

-- [FINTA] Cancela un M1 del combo durante su anticipación (clic derecho). Conserva el progreso del combo.
function CombatService.RequestFeint(character: Model): boolean
	local state = states[character]
	local cfg = CombatConfig.Feint
	if not cfg.Enabled or not state or state.ownerKind ~= "Player" or not isAlive(state) then
		return false
	end

	local now = os.clock()
	local current = state.currentAttack
	local index = if current then COMBO_INDEX_OF[current] else nil
	if not index or now < state.feintReadyAt then
		return false
	end
	-- [v2.15] Durante la preparación, o en el primer tramo del impacto (mientras el golpe todavía no se comprometió).
	local inWindup = state.action == "Windup"
	local inCommitDelay = state.action == "Active" and now - state.activeStartedAt < cfg.CommitDelay
	if not inWindup and not inCommitDelay then
		return false
	end

	state.feintReadyAt = now + cfg.Cooldown
	if state.player then
		publishCooldown(state.player, "Feint", state.feintReadyAt) -- [CD] el HUD muestra el cooldown de la finta
	end
	cancelAttack(state) -- corta la animación y el golpe (el token invalida runAttack)
	setMovePhase(state, "None")

	-- El combo no se pierde: el siguiente M1 repite el golpe que se fintó.
	state.comboIndex = index - 1
	state.comboWindowUntil = now + CombatConfig.Combo.Window
	return true
end

-- [RUN] Ataque corriendo. El cliente lo pide con W + sprint; el servidor lo comprueba con la velocidad REAL del
-- personaje y, si no se cumple (o está en cooldown, o hay un combo vivo), lo trata como un M1 normal.
function CombatService.RequestRunAttack(character: Model): boolean
	local state = states[character]
	local cfg = CombatConfig.RunAttack
	if not state or not isAlive(state) then
		return false
	end

	local now = os.clock()
	local comboAlive = state.comboIndex > 0 and now <= state.comboWindowUntil
	local root = character:FindFirstChild("HumanoidRootPart")
	if cfg.Enabled and state.ownerKind == "Player" and state.action == "Idle" and not comboAlive
		and now >= state.airComboUntil and root and root:IsA("BasePart")
	then
		local velocity = root.AssemblyLinearVelocity
		local planar = Vector3.new(velocity.X, 0, velocity.Z)
		local look = root.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		if planar.Magnitude >= cfg.ServerMinSpeed
			and flatLook.Magnitude > 0.01
			and planar.Unit:Dot(flatLook.Unit) >= cfg.MinForwardDot
		then
			if CombatService.StartAttack(character, "RunAttack") then
				return true
			end
		end
	end

	return CombatService.RequestM1(character)
end

-- Ataques fuera del combo (R, ataques automáticos de dummies), con cooldown propio.
function CombatService.StartAttack(character: Model, attackName: string): boolean
	local state = states[character]
	local def = CombatConfig.Attacks[attackName]
	if not state or not def or not isAlive(state) then
		return false
	end

	local now = os.clock()
	if isActionLocked(state, now) or state.action ~= "Idle" then
		return false
	end
	if state.blockHeld or state.permanentBlock then
		return false
	end
	if DodgeService.IsBusy(character) then -- [DASH] (los dummies nunca están en dash: devuelve false)
		return false
	end
	-- [v2.5] CooldownKey: ataques que comparten cooldown (R en el suelo = Heavy, R en el aire = AirGrab).
	local cooldownKey = def.CooldownKey or attackName
	if now < (state.cooldowns[cooldownKey] or 0) then
		return false
	end

	-- [R] Los jugadores usan PlayerCooldown (R = 20 s); los dummies siguen con Cooldown.
	local cooldown = def.Cooldown or 0
	if state.ownerKind == "Player" and def.PlayerCooldown then
		cooldown = def.PlayerCooldown
	end
	local readyAt = now + cooldown
	state.cooldowns[cooldownKey] = readyAt
	if state.player and cooldown > 0 then
		publishCooldown(state.player, cooldownKey, readyAt) -- [CD] el HUD se sincroniza con esto
	end

	beginAttack(state, attackName, def)
	return true
end

-- [R] Habilidad R del jugador (remote "Heavy"). Reglas:
--   * Con cooldown activo se rechaza SIN recordar nada (no se puede "pre-cargar" por encima del cooldown).
--   * En reposo o en la ventana de combo se ejecuta al instante (y no reinicia el combo: ver beginAttack).
--   * Durante Active/Recovery de un M1 se recuerda BufferTime y se ejecuta al terminar la recuperación.
--   * El cooldown de 20 s empieza cuando R realmente arranca, y lo valida siempre StartAttack.
-- [v2.12] ¿Terminó de atacar? (lo usa el combo automático de los dummies)
-- [v2.15] Combo automático de los dummies: mantiene "apretado" el M1 mientras dura la cadena.
function CombatService.SetChainHeld(character: Model, held: boolean)
	local state = states[character]
	if state then
		state.m1Held = held
	end
end

-- ¿Sigue en curso un ataque o un combo (dentro de su ventana)?
function CombatService.IsComboActive(character: Model): boolean
	local state = states[character]
	if not state then
		return false
	end
	return state.action ~= "Idle" or (state.comboIndex > 0 and os.clock() <= state.comboWindowUntil)
end

function CombatService.IsIdle(character: Model): boolean
	local state = states[character]
	return state == nil or state.action == "Idle"
end

function CombatService.RequestHeavy(character: Model): boolean
	local state = states[character]
	if not state or state.ownerKind ~= "Player" or not isAlive(state) then
		return false
	end

	local now = os.clock()
	if isActionLocked(state, now) or state.blockHeld or state.permanentBlock then
		return false
	end
	if DodgeService.IsBusy(character) then
		return false
	end
	if now < (state.cooldowns.Heavy or 0) then
		return false
	end

	-- [AIR] En el combo aéreo, la R es el agarre de 2 s (comparte el cooldown de 20 s).
	local heavyName = if state.airPartner ~= nil and now < state.airComboUntil then "AirGrab" else "Heavy"

	if state.action == "Idle" then
		return CombatService.StartAttack(character, heavyName)
	end

	local current = state.currentAttack
	if (state.action == "Active" or state.action == "Recovery") and current and COMBO_INDEX_OF[current] then
		state.bufferedHeavyAt = now
	end
	return false
end

-- Utilidad de depuración: aturde a un personaje registrado (respeta duración e inmunidad).
function CombatService.ApplyStun(character: Model, duration: number?): boolean
	local state = states[character]
	if not state then
		return false
	end
	return applyStun(state, duration or CombatConfig.Stun.OnParried.Dummy)
end

---------------------------------------------------------------------
-- Bloqueo y parry
---------------------------------------------------------------------

function CombatService.SetBlockHeld(character: Model, held: boolean): boolean
	local state = states[character]
	if not state or not isAlive(state) then
		return false
	end

	if held then
		if state.blockHeld then
			return true
		end
		if state.action ~= "Idle" then
			return false
		end
		if DodgeService.IsBusy(character) then -- [DASH] El cliente reenvía BlockStart al terminar el dash
			return false
		end

		local now = os.clock()
		state.blockHeld = true
		state.bufferedHeavyAt = nil

		-- Empezar a bloquear cierra la ventana de combo.
		if state.comboIndex > 0 then
			state.comboIndex = 0
			state.comboWindowUntil = 0
			state.bufferedM1At = nil
			setMovePhase(state, "None")
		end

		-- [HIT] En hitstun de combo solo se permite el parry: 1 intento por golpe recibido, sin usar el cooldown del parry.
		-- (blockHeld queda como intención: al terminar el hitstun, si F sigue apretada, vuelve el bloqueo normal.)
		if now < state.hitStunUntil then
			if state.parryChance and now >= state.guardBrokenUntil and now >= state.stunUntil then
				state.parryChance = false
				state.parryUntil = now + CombatConfig.Block.ParryWindow
				scheduleVisualRefresh(state, CombatConfig.Block.ParryWindow)
			end
		-- Durante un stun se recuerda la intención, pero no se abre ventana de parry.
		elseif now >= state.guardBrokenUntil and now >= state.stunUntil and now >= state.slamStunUntil and now >= state.parryReadyAt then
			state.parryUntil = now + CombatConfig.Block.ParryWindow
			state.parryReadyAt = now + CombatConfig.Block.ParryCooldown
			if state.player then
				publishCooldown(state.player, "Parry", state.parryReadyAt) -- [CD]
			end
			scheduleVisualRefresh(state, CombatConfig.Block.ParryWindow)
		end
	else
		state.blockHeld = false
	end

	refreshDefenseVisual(state)
	return true
end

---------------------------------------------------------------------
-- Registro de combatientes
---------------------------------------------------------------------

function CombatService.Register(character: Model, ownerKind: string, options: RegisterOptions?): CombatState?
	if states[character] then
		return states[character]
	end

	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid or not humanoid:IsA("Humanoid") or not character.Parent then
		warn(`[CombatService] {character.Name} no tiene Humanoid; no se registra.`)
		return nil
	end

	if states[character] then
		return states[character]
	end

	-- [CD] Los jugadores comparten su tabla de cooldowns entre personajes (respawn) y se republica el estado.
	local player: Player? = if ownerKind == "Player" then Players:GetPlayerFromCharacter(character) else nil
	local cooldowns: { [string]: number } = {}
	if player then
		cooldowns = playerCooldowns[player.UserId] or {}
		playerCooldowns[player.UserId] = cooldowns
		for key, readyAt in cooldowns do
			publishCooldown(player, key, readyAt)
		end
		player:SetAttribute("CooldownEnd_Parry", 0) -- el parry sí empieza limpio con cada personaje
		player:SetAttribute("CooldownEnd_Feint", 0)
	end

	local state: CombatState = {
		character = character,
		humanoid = humanoid :: Humanoid,
		player = player,
		ownerKind = ownerKind,
		action = "Idle",
		currentAttack = nil,
		attackToken = 0,
		cooldowns = cooldowns,
		blockHeld = false,
		movable = options ~= nil and options.Movable == true,
		permanentBlock = options ~= nil and options.PermanentBlock == true,
		autoParry = options ~= nil and options.AutoParry == true,
		parryUntil = 0,
		parryReadyAt = 0,
		guardBrokenUntil = 0,
		stunUntil = 0,
		stunImmuneUntil = 0,
		stunToken = 0,
		stunPhaseToken = 0,
		hitStunUntil = 0,
		hitStunToken = 0,
		hitStunPhaseToken = 0,
		parryChance = false,
		slamStunUntil = 0,
		slamStunToken = 0,
		slamStunPhaseToken = 0,
		airLockUntil = 0,
		airLockToken = 0,
		airLockPhaseToken = 0,
		airComboUntil = 0,
		airComboToken = 0,
		counterUntil = 0,
		counterToken = 0,
		airPartner = nil,
		hovering = false,
		airLastActionAt = 0,
		upHeld = false,
		runArmed = true,
		grabUntil = 0,
		grabToken = 0,
		m1Held = false,
		feintReadyAt = 0,
		activeStartedAt = 0,
		blockMeter = CombatConfig.Block.Meter.Max,
		blockRegenAt = 0,
		blockExhaustedUntil = 0,
		blockMeterRate = math.huge, -- fuerza a publicar el estado inicial en el próximo ciclo
		blockWasExhausted = false,
		comboIndex = 0,
		comboWindowUntil = 0,
		comboEndCooldownUntil = 0,
		bufferedM1At = nil,
		bufferedHeavyAt = nil,
		phaseToken = 0,
		telegraphing = false,
		tracks = {},
		currentTrack = nil,
		dead = false,
	}
	states[character] = state

	humanoid.Died:Connect(function()
		state.dead = true
		state.blockHeld = false
		state.hitStunToken += 1
		state.hitStunUntil = 0
		state.parryChance = false
		state.slamStunToken += 1
		state.slamStunUntil = 0
		state.airLockToken += 1
		state.airLockUntil = 0
		state.upHeld = false
		state.m1Held = false
		state.grabToken += 1
		state.grabUntil = 0
		if state.airPartner then
			releaseAir(state) -- el rival (o el atacante) deja de flotar
		end
		state.airComboToken += 1
		state.airComboUntil = 0
		state.counterUntil = 0
		state.stunToken += 1
		cancelAttack(state)
		setMovePhase(state, "None")
		character:SetAttribute("CombatStunned", false)
		if ownerKind == "Player" then
			character:SetAttribute("CombatDefense", "None") -- [DEF]
		end
	end)

	character.Destroying:Connect(function()
		state.attackToken += 1
		state.stunToken += 1
		if states[character] == state then
			states[character] = nil
		end
	end)

	refreshDefenseVisual(state)
	return state
end

---------------------------------------------------------------------
-- [DASH] Reglas de combate para el dash (las consulta DodgeService)
---------------------------------------------------------------------

-- Devuelve (true) o (false, motivo). Solo jugadores registrados, vivos, sin stun, sin ataque en curso y sin bloqueo.
-- La ventana de combo (action == "Idle") SÍ permite dash.
local function canDashFor(character: Model): (boolean, string?)
	local state = states[character]
	if not state or state.ownerKind ~= "Player" or not isAlive(state) then
		return false, "NotRegistered"
	end

	local now = os.clock()
	-- [AIR] Estampado (SlamStun): el dash SÍ está permitido (y corta el stun). Stun real, hitstun, aire bloqueado del
	-- rival lanzado y combo aéreo del atacante, no.
	if isHardLocked(state, now) or now < state.airComboUntil then
		return false, "Stunned"
	end
	if state.action ~= "Idle" then
		-- [v2.10] Excepción: la recuperación de un M1 del combo se puede cancelar con dash.
		local current = state.currentAttack
		if not (state.action == "Recovery" and current and COMBO_INDEX_OF[current]) then
			return false, "Attacking"
		end
	end
	if (state.blockHeld or state.permanentBlock) and now >= state.slamStunUntil then
		return false, "Blocking"
	end
	return true, nil
end

-- Al comenzar un dash aceptado: cierra combo, buffer y parry, y limpia la fase "ComboWindow".
local function onDashStarted(character: Model)
	local state = states[character]
	if not state then
		return
	end

	local now = os.clock()
	state.parryUntil = 0
	state.bufferedM1At = nil
	state.counterUntil = 0
	clearSlamStun(state) -- [AIR] el dash corta el stun de estampado

	-- [v2.10] El dash NO rompe el combo: si cancela la recuperación de un M1, el progreso se conserva; en cualquier caso
	-- la ventana se extiende Combo.DashWindow para poder seguir con el siguiente M1 tras el dash. (Después del 4º golpe
	-- el siguiente M1 empieza un combo nuevo.)
	local keptIndex = state.comboIndex
	if state.action == "Recovery" then
		cancelAttack(state)
		state.comboIndex = keptIndex
		state.comboEndCooldownUntil = 0
	end
	if state.comboIndex > 0 then
		state.comboWindowUntil = now + CombatConfig.Combo.DashWindow
	end
	setMovePhase(state, "None")
	refreshDefenseVisual(state)
end

DodgeService.Init({
	sendToPlayer = function(player: Player, payload)
		feedbackRemote:FireClient(player, payload)
	end,
	broadcast = fireFeedback,
	canDash = canDashFor,
	onDashStarted = onDashStarted,
})

-- [BLOQUEO] Actualiza la barra de bloqueo de cada jugador (barato: solo recorre los estados con jugador).
RunService.Heartbeat:Connect(function(dt: number)
	local now = os.clock()
	for _, state in states do
		if state.player and not state.dead then
			updateBlockMeter(state, now, dt)
		end
	end
end)

-- [CD] Al salir, los cooldowns se conservan unos segundos (más que el mayor) para que salir y volver a entrar al
-- mismo servidor no los resetee; después se liberan.
Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId
	task.delay(30, function()
		if not Players:GetPlayerByUserId(userId) then
			playerCooldowns[userId] = nil
		end
	end)
end)

---------------------------------------------------------------------
-- Entrada del cliente: el servidor valida todo
---------------------------------------------------------------------

requestRemote.OnServerEvent:Connect(function(player: Player, action: any, argument: any)
	if typeof(action) ~= "string" then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	if action == "M1" then
		local upHeld = typeof(argument) == "table" and argument.Up == true
		CombatService.RequestM1(character, upHeld)
	elseif action == "RunAttack" then
		CombatService.RequestRunAttack(character)
	elseif action == "Feint" then
		CombatService.RequestFeint(character) -- [v2.9]
	elseif action == "M1Hold" then
		-- [v2.5] Clic mantenido: el combo de 4 M1 se encadena solo hasta el golpe final.
		local state = states[character]
		if state then
			state.m1Held = argument == true
		end
	elseif action == "UpHold" then
		-- [AIR] El cliente avisa si mantiene Espacio: así el Uppercut funciona aunque el 4º clic se haya recordado (buffer).
		local state = states[character]
		if state then
			state.upHeld = argument == true
		end
	elseif action == "Heavy" then
		CombatService.RequestHeavy(character) -- [R] antes StartAttack: ahora admite combo, buffer y cooldown de 20 s
	elseif action == "BlockStart" then
		CombatService.SetBlockHeld(character, true)
	elseif action == "BlockEnd" then
		CombatService.SetBlockHeld(character, false)
	elseif action == "Dash" then -- [DASH] argument = ID de secuencia; el servidor decide todo lo demás
		DodgeService.RequestDash(player, argument)
	end
end)

return CombatService