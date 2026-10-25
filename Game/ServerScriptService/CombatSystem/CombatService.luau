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
		targetState.humanoid:TakeDamage(damage)
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
	local token = state.attackToken

	-- Un ataque fuera del combo (R, dummies) reinicia el combo.
	if not COMBO_INDEX_OF[attackName] then
		state.comboIndex = 0
		state.comboWindowUntil = 0
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
		})
	end

	task.spawn(runAttack, state, attackName, def, token)
end

-- Termina la recuperación: abre la ventana de combo o cierra el combo.
local function finishAttack(state: CombatState, attackName: string, def)
	local now = os.clock()
	local comboIndex = COMBO_INDEX_OF[attackName]

	if not comboIndex then
		setMovePhase(state, "None")
		return
	end

	if comboIndex >= #COMBO_SEQUENCE then
		state.comboIndex = 0
		state.comboWindowUntil = 0
		state.comboEndCooldownUntil = now + CombatConfig.Combo.EndCooldown
		state.bufferedM1At = nil
		setMovePhase(state, "None")
		return
	end

	state.comboWindowUntil = now + CombatConfig.Combo.Window

	-- Clic recordado durante Active/Recovery: encadena el siguiente golpe de inmediato.
	local buffered = state.bufferedM1At
	state.bufferedM1At = nil
	if buffered and now - buffered <= CombatConfig.Combo.BufferTime then
		if startComboHit(state, now) then
			return
		end
	end

	local phaseToken = setMovePhase(state, "ComboWindow", def.MovementProfile)
	task.delay(CombatConfig.Combo.Window, function()
		if states[state.character] == state and state.phaseToken == phaseToken then
			setMovePhase(state, "None")
		end
	end)
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
	if (state.action == "Active" or state.action == "Recovery") and current and COMBO_INDEX_OF[current] then
		state.bufferedM1At = now
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

	state.cooldowns[attackName] = now + (def.Cooldown or 0)
	beginAttack(state, attackName, def)
	return true
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

	local state: CombatState = {
		character = character,
		humanoid = humanoid :: Humanoid,
		ownerKind = ownerKind,
		action = "Idle",
		currentAttack = nil,
		attackToken = 0,
		cooldowns = {},
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
		CombatService.StartAttack(character, "Heavy")
	elseif action == "BlockStart" then
		CombatService.SetBlockHeld(character, true)
	elseif action == "BlockEnd" then
		CombatService.SetBlockHeld(character, false)
	elseif action == "Dash" then -- [DASH] argument = ID de secuencia; el servidor decide todo lo demás
		DodgeService.RequestDash(player, argument)
	end
end)

return CombatService