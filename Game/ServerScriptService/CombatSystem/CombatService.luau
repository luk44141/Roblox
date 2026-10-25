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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("CombatSystem")
local CombatConfig = require(CombatFolder:WaitForChild("CombatConfig"))
local HitboxService = require(script.Parent:WaitForChild("HitboxService"))
local DodgeService = require(script.Parent:WaitForChild("DodgeService")) -- [DASH]

local CombatService = {}

type CombatState = {
	character: Model,
	humanoid: Humanoid,
	player: Player?,                -- [CD] nil en dummies
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

local function isBlocking(state: CombatState, now: number): boolean
	return (state.blockHeld or state.permanentBlock)
		and now >= state.guardBrokenUntil
		and not isStunned(state, now)
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
		state.tracks[animName] = loaded
		track = loaded
	end

	stopTrack(state)
	track:Play(0.05)
	state.currentTrack = track
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
local function applyStun(state: CombatState, duration: number): boolean
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
-- Resolución de impactos
---------------------------------------------------------------------

local function resolveOutcome(attackDef, targetState: CombatState, now: number): (string, number)
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
	if dodgeResult then
		outcome, damage = dodgeResult, 0
	else
		outcome, damage = resolveOutcome(attackDef, targetState, now)
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

	-- Un parry exitoso aturde al atacante (una sola vez por impacto).
	if outcome == "Parried" then
		local durations = CombatConfig.Stun.OnParried
		local duration = if attackerState.ownerKind == "Player" then durations.Player else durations.Dummy
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
local runAttack

local function stillValid(state: CombatState, token: number): boolean
	return states[state.character] == state and state.attackToken == token and isAlive(state)
end

local function beginAttack(state: CombatState, attackName: string, def)
	state.action = "Windup"
	state.currentAttack = attackName
	state.attackToken += 1
	state.bufferedM1At = nil
	state.bufferedHeavyAt = nil
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

	local heavyFirst = wantsHeavy and (not wantsM1 or (heavyAt :: number) >= (m1At :: number))
	if heavyFirst then
		if CombatService.StartAttack(state.character, "Heavy") then
			return true
		end
		return wantsM1 and startComboHit(state, now)
	end

	if wantsM1 and startComboHit(state, now) then
		return true
	end
	if wantsHeavy and CombatService.StartAttack(state.character, "Heavy") then
		return true
	end
	return false
end

-- Reabre la ventana de combo tras un golpe M1, o tras R cuando R puenteó un combo en curso.
local function openComboWindow(state: CombatState, def, now: number)
	state.comboWindowUntil = now + CombatConfig.Combo.Window

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
	-- Anticipación
	task.wait(def.Windup)
	if not stillValid(state, token) then
		return
	end

	-- Impacto: la caja se calcula UNA vez; se muestra y se consulta con los mismos datos.
	state.telegraphing = false
	state.action = "Active"
	setMovePhase(state, "Active", def.MovementProfile)

	local cframe, size = HitboxService.GetAttackBoxData(state.character, def.Box)
	if not cframe or not size then
		cancelAttack(state)
		setMovePhase(state, "None")
		return
	end

	HitboxService.ShowAttackBox(cframe, size, def.Active)

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
	until os.clock() - startTime >= def.Active or not stillValid(state, token)

	if not stillValid(state, token) then
		return
	end

	-- Recuperación
	state.action = "Recovery"
	setMovePhase(state, "Recovery", def.MovementProfile)
	task.wait(def.Recovery)
	if not stillValid(state, token) then
		return
	end

	state.action = "Idle"
	state.currentAttack = nil
	finishAttack(state, attackName, def)
end

function startComboHit(state: CombatState, now: number): boolean
	if now < state.comboEndCooldownUntil then
		return false
	end

	-- Si la ventana venció (o el combo terminó), vuelve al primer golpe.
	local index = state.comboIndex + 1
	if now > state.comboWindowUntil or index > #COMBO_SEQUENCE then
		index = 1
	end

	state.comboIndex = index
	local attackName = COMBO_SEQUENCE[index]
	beginAttack(state, attackName, CombatConfig.Attacks[attackName])
	return true
end

-- M1 del jugador: inicia o encadena el combo. Un clic durante Active/Recovery se recuerda.
function CombatService.RequestM1(character: Model): boolean
	local state = states[character]
	if not state or not isAlive(state) then
		return false
	end

	local now = os.clock()
	if isStunned(state, now) or state.blockHeld or state.permanentBlock then
		return false
	end
	if DodgeService.IsBusy(character) then -- [DASH] No se ataca durante el dash ni su recuperación
		return false
	end

	if state.action == "Idle" then
		return startComboHit(state, now)
	end

	local current = state.currentAttack
	if (state.action == "Active" or state.action == "Recovery") and current then
		local currentDef = CombatConfig.Attacks[current]
		-- [R] También se recuerda el clic durante una R que puentea un combo en curso.
		if COMBO_INDEX_OF[current] or (currentDef ~= nil and currentDef.ContinuesCombo and state.comboIndex > 0) then
			state.bufferedM1At = now
		end
	end
	return false
end

-- Ataques fuera del combo (R, ataques automáticos de dummies), con cooldown propio.
function CombatService.StartAttack(character: Model, attackName: string): boolean
	local state = states[character]
	local def = CombatConfig.Attacks[attackName]
	if not state or not def or not isAlive(state) then
		return false
	end

	local now = os.clock()
	if isStunned(state, now) or state.action ~= "Idle" then
		return false
	end
	if state.blockHeld or state.permanentBlock then
		return false
	end
	if DodgeService.IsBusy(character) then -- [DASH] (los dummies nunca están en dash: devuelve false)
		return false
	end
	if now < (state.cooldowns[attackName] or 0) then
		return false
	end

	-- [R] Los jugadores usan PlayerCooldown (R = 20 s); los dummies siguen con Cooldown.
	local cooldown = def.Cooldown or 0
	if state.ownerKind == "Player" and def.PlayerCooldown then
		cooldown = def.PlayerCooldown
	end
	local readyAt = now + cooldown
	state.cooldowns[attackName] = readyAt
	if state.player and cooldown > 0 then
		publishCooldown(state.player, attackName, readyAt) -- [CD] el HUD se sincroniza con esto
	end

	beginAttack(state, attackName, def)
	return true
end

-- [R] Habilidad R del jugador (remote "Heavy"). Reglas:
--   * Con cooldown activo se rechaza SIN recordar nada (no se puede "pre-cargar" por encima del cooldown).
--   * En reposo o en la ventana de combo se ejecuta al instante (y no reinicia el combo: ver beginAttack).
--   * Durante Active/Recovery de un M1 se recuerda BufferTime y se ejecuta al terminar la recuperación.
--   * El cooldown de 20 s empieza cuando R realmente arranca, y lo valida siempre StartAttack.
function CombatService.RequestHeavy(character: Model): boolean
	local state = states[character]
	if not state or state.ownerKind ~= "Player" or not isAlive(state) then
		return false
	end

	local now = os.clock()
	if isStunned(state, now) or state.blockHeld or state.permanentBlock then
		return false
	end
	if DodgeService.IsBusy(character) then
		return false
	end
	if now < (state.cooldowns.Heavy or 0) then
		return false
	end

	if state.action == "Idle" then
		return CombatService.StartAttack(character, "Heavy")
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

		-- Durante un stun se recuerda la intención, pero no se abre ventana de parry.
		if now >= state.guardBrokenUntil and now >= state.stunUntil and now >= state.parryReadyAt then
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
		permanentBlock = options ~= nil and options.PermanentBlock == true,
		autoParry = options ~= nil and options.AutoParry == true,
		parryUntil = 0,
		parryReadyAt = 0,
		guardBrokenUntil = 0,
		stunUntil = 0,
		stunImmuneUntil = 0,
		stunToken = 0,
		stunPhaseToken = 0,
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
	if isStunned(state, now) then
		return false, "Stunned"
	end
	if state.action ~= "Idle" then
		return false, "Attacking"
	end
	if state.blockHeld or state.permanentBlock then
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

	state.parryUntil = 0
	state.bufferedM1At = nil
	if state.comboIndex > 0 then
		state.comboIndex = 0
		state.comboWindowUntil = 0
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
		CombatService.RequestM1(character)
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