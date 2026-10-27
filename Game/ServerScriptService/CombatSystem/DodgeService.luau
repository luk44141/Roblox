--[[
	DodgeService  (ModuleScript)
	Ubicación: ServerScriptService > CombatSystem > DodgeService

	Autoridad del servidor sobre el dash: cargas, cooldown, duración, invulnerabilidad y Perfect Dodge.
	NO crea remotes: CombatService le inyecta las funciones de envío (Init) y reutiliza
	CombatRequest ("Dash", dashId) y CombatFeedback (Kind = "DashResponse" / "DodgeEvent").
	El cliente solo envía un ID de secuencia; dirección, distancia y tiempos NUNCA se leen del cliente.

	Lo llama CombatService:
		DodgeService.Init(env)                       env = { sendToPlayer, broadcast, canDash, onDashStarted }
		DodgeService.RequestDash(player, dashId)
		DodgeService.ResolveIncomingHit(character, hitInfo) -> nil | "Dodged" | "PerfectDodge"
		DodgeService.IsBusy(character) / IsInvulnerable(character) / GetPhase(character) / Cancel(character, reason)

	Señales para recompensas, contraataques y VFX (DodgeService.Events.X:Connect(...)):
		DashStarted(player, info)   InvulnerabilityStarted(player, info)   InvulnerabilityEnded(player)
		Dodged(player, hitInfo)     PerfectDodge(player, hitInfo)          DashEnded(player, info)
		RecoveryStarted(player, info)   RecoveryEnded(player)
		DashCancelled(player, reason)   DashRejected(player, reason)       DashViolation(player, data)

	Atributos en el personaje: "Invulnerable" (bool) y "DashPhase" (string).
	[v2] Atributos en el JUGADOR (los lee el HUD de cooldowns): "DashCharges" (cargas disponibles) y
	"CooldownEnd_Dash" (tiempo del servidor, Workspace:GetServerTimeNow, en que vuelve la próxima carga; 0 = cargas llenas).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("CombatSystem")
local cfg = require(CombatFolder:WaitForChild("DashConfig"))
local SignalSet = require(CombatFolder:WaitForChild("SignalSet"))
local srv = cfg.Server

local DodgeService = {}
DodgeService.Signals = SignalSet.new({
	"DashStarted",
	"InvulnerabilityStarted",
	"InvulnerabilityEnded",
	"Dodged",
	"PerfectDodge",
	"DashEnded",
	"RecoveryStarted",
	"RecoveryEnded",
	"DashCancelled",
	"DashRejected",
	"DashViolation",
})
DodgeService.Events = DodgeService.Signals.Events

local env = nil
local started = false

local states = {} -- [Player] = state
local activeSet = {} -- [Player] = true mientras la fase no sea Idle
local characterConnections = {} -- [Player] = { conexiones del personaje actual (Died) }
local playerConnections = {} -- [Player] = { CharacterAdded / CharacterRemoving }
local globalConnections = {}

----------------------------------------------------------------------
-- Estado
----------------------------------------------------------------------

local function newState()
	return {
		character = nil,
		humanoid = nil,
		root = nil,

		charges = cfg.MaxCharges,
		rechargeAt = 0,

		phase = "Idle", -- Idle | Active | Recovery
		lastDashId = 0,
		dashStart = 0,
		activeEnd = 0,
		recoveryEnd = 0,
		startPosition = nil,

		invulnerable = false,
		invulnEnd = 0,
		perfect = false,

		lastRequest = 0,
		penaltyUntil = 0,
	}
end

local function fire(name, ...)
	DodgeService.Signals:Fire(name, ...)
end

local function broadcast(eventName, state, reason)
	if env and state.character then
		env.broadcast({
			Kind = "DodgeEvent",
			Event = eventName,
			Target = state.character,
			Reason = reason,
		})
	end
end

local function setAttributes(state)
	local character = state.character
	if character and character.Parent then
		character:SetAttribute("Invulnerable", state.invulnerable)
		character:SetAttribute("DashPhase", state.phase)
	end
end

-- [v2] Publica el estado REAL de las cargas del dash para el HUD. Se llama al aceptar un dash y al (re)crear el personaje.
local function publishCooldown(player, state)
	local nextCharge = 0
	if state.charges < cfg.MaxCharges then
		nextCharge = workspace:GetServerTimeNow() + math.max(state.rechargeAt - os.clock(), 0)
	end
	player:SetAttribute("DashCharges", state.charges)
	player:SetAttribute("CooldownEnd_Dash", nextCharge)
end

local function makeInfo(state)
	return {
		DashId = state.lastDashId,
		StartTime = state.dashStart,
		Duration = cfg.Duration,
	}
end

local function refreshCharges(state, now)
	local cooldown = math.max(cfg.Cooldown, 0.01)
	while state.charges < cfg.MaxCharges and now >= state.rechargeAt do
		state.charges += 1
		state.rechargeAt += cooldown
	end
end

local function endInvulnerability(player, state)
	if not state.invulnerable then
		return
	end
	state.invulnerable = false
	setAttributes(state)
	fire("InvulnerabilityEnded", player)
	broadcast("InvulnerabilityEnded", state)
end

----------------------------------------------------------------------
-- Auditoría de desplazamiento (el cliente tiene la autoridad física; el servidor lo audita)
----------------------------------------------------------------------

local function auditDisplacement(player, state, now)
	if not srv.AuditDisplacement or not state.startPosition then
		return
	end
	local root = state.root
	if not root or not root.Parent then
		return
	end

	local delta = root.Position - state.startPosition
	local planar = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)
	local allowed = cfg.Distance + srv.MaxPlanarSpeed * (cfg.Duration + srv.LatencyTolerance) + srv.DisplacementSlack

	if planar > allowed then
		state.penaltyUntil = now + srv.ViolationPenalty
		warn(string.format("[DodgeService] %s recorrió %.1f studs en un dash (máximo plausible %.1f).", player.Name, planar, allowed))
		fire("DashViolation", player, { Distance = planar, Allowed = allowed })
	end
end

----------------------------------------------------------------------
-- Fases
----------------------------------------------------------------------

-- Avanza las fases según el reloj. Se llama desde Heartbeat y antes de validar/resolver.
local function advance(player, state, now)
	if state.phase == "Idle" then
		return
	end

	if state.invulnerable and now >= state.invulnEnd then
		endInvulnerability(player, state)
	end

	if state.phase == "Active" and now >= state.activeEnd then
		state.phase = "Recovery"
		setAttributes(state)
		auditDisplacement(player, state, now)
		local info = makeInfo(state)
		fire("DashEnded", player, info)
		fire("RecoveryStarted", player, info)
		broadcast("DashEnded", state)
	end

	if state.phase == "Recovery" and now >= state.recoveryEnd then
		state.phase = "Idle"
		activeSet[player] = nil
		setAttributes(state)
		fire("RecoveryEnded", player)
		broadcast("RecoveryEnded", state)
	end
end

local function cancelDash(player, state, reason)
	if state.phase == "Idle" then
		return
	end

	local wasActive = state.phase == "Active"
	if state.invulnerable then
		state.invulnerable = false
		fire("InvulnerabilityEnded", player)
	end

	state.phase = "Idle"
	activeSet[player] = nil
	setAttributes(state)

	if wasActive then
		fire("DashCancelled", player, reason)
	end
	-- También se avisa si estaba en Recovery: el cliente debe volver a Idle
	broadcast("DashCancelled", state, reason)
end

----------------------------------------------------------------------
-- Pedido de dash
----------------------------------------------------------------------

local function respond(player, dashId, accepted, reason)
	if env then
		env.sendToPlayer(player, {
			Kind = "DashResponse",
			DashId = dashId,
			Accepted = accepted,
			Reason = reason,
		})
	end
end

local function validate(player, state, dashId, now)
	local humanoid, root = state.humanoid, state.root
	if not humanoid or not root or player.Character ~= state.character then
		return "NoCharacter"
	end
	if humanoid.Health <= 0 or not root.Parent then
		return "Dead"
	end
	if humanoid.Sit then
		return "Seated"
	end
	if now < state.penaltyUntil then
		return "Penalized"
	end

	-- Secuencia: el ID debe ser estrictamente mayor que el último y no saltar demasiado
	if dashId <= state.lastDashId or dashId > state.lastDashId + srv.MaxIdJump then
		return "OutOfSequence"
	end
	state.lastDashId = dashId

	-- Reglas del combate (stun, ataque en curso, bloqueo): las decide CombatService
	local ok, reason = env.canDash(state.character)
	if not ok then
		return reason or "CombatState"
	end

	local lenient = now + srv.LatencyTolerance
	advance(player, state, lenient)
	if state.phase ~= "Idle" then
		return "Busy"
	end

	refreshCharges(state, lenient)
	if state.charges <= 0 then
		return "Cooldown"
	end

	return nil
end

function DodgeService.RequestDash(player, dashId)
	if not started then
		return
	end
	if typeof(dashId) ~= "number" or dashId ~= dashId or dashId % 1 ~= 0 then
		return
	end

	local state = states[player]
	if not state then
		return
	end

	local now = os.clock()
	local reason = nil
	if now - state.lastRequest < srv.MinRequestInterval then
		reason = "RateLimited"
	else
		reason = validate(player, state, dashId, now)
	end
	state.lastRequest = now

	if reason then
		fire("DashRejected", player, reason)
		respond(player, dashId, false, reason)
		return
	end

	-- Aceptado
	local wasFull = state.charges >= cfg.MaxCharges
	state.charges -= 1
	if wasFull then
		state.rechargeAt = now + cfg.Cooldown
	end

	state.phase = "Active"
	state.dashStart = now
	state.activeEnd = now + cfg.Duration
	state.recoveryEnd = state.activeEnd + cfg.RecoveryTime
	state.startPosition = state.root.Position
	state.perfect = false
	state.invulnerable = cfg.InvulnerabilityDuration > 0
	state.invulnEnd = math.min(now + cfg.InvulnerabilityDuration + srv.InvulnerabilityPadding, state.activeEnd)
	activeSet[player] = true
	setAttributes(state)
	publishCooldown(player, state) -- [v2]

	env.onDashStarted(state.character)

	local info = makeInfo(state)
	fire("DashStarted", player, info)
	broadcast("DashStarted", state)
	if state.invulnerable then
		fire("InvulnerabilityStarted", player, info)
		broadcast("InvulnerabilityStarted", state)
	end

	respond(player, dashId, true, nil)
end

----------------------------------------------------------------------
-- Consultas por personaje (las usa CombatService)
----------------------------------------------------------------------

local function getState(character)
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return nil, nil
	end
	local state = states[player]
	if not state or state.character ~= character then
		return nil, nil
	end
	return player, state
end

function DodgeService.IsBusy(character)
	local _, state = getState(character)
	return state ~= nil and state.phase ~= "Idle"
end

function DodgeService.IsInvulnerable(character)
	local _, state = getState(character)
	if not state then
		return false
	end
	local now = os.clock()
	return state.invulnerable and now >= state.dashStart and now < state.invulnEnd
end

function DodgeService.GetPhase(character)
	local _, state = getState(character)
	return state and state.phase or "Idle"
end

function DodgeService.Cancel(character, reason)
	local player, state = getState(character)
	if state then
		cancelDash(player, state, reason or "Cancelled")
	end
end

-- Se llama desde CombatService.resolveHit para un golpe que YA habría impactado
-- (hitbox válida y canDamage). Devuelve nil si no hay invulnerabilidad.
function DodgeService.ResolveIncomingHit(character, hitInfo)
	local player, state = getState(character)
	if not state then
		return nil
	end

	local now = os.clock()
	advance(player, state, now)

	if not (state.invulnerable and now >= state.dashStart and now < state.invulnEnd) then
		return nil
	end

	if not state.perfect and now - state.dashStart <= cfg.PerfectDodgeWindow then
		state.perfect = true
		-- [v2.3] Bonus de velocidad: atributo con el tiempo del SERVIDOR en que termina; SprintController lo aplica.
		local boost = cfg.PerfectDodgeSpeedBoost
		if boost and state.character then
			state.character:SetAttribute("PerfectDodgeBoostUntil", workspace:GetServerTimeNow() + boost.Duration)
		end
		fire("PerfectDodge", player, hitInfo)
		broadcast("PerfectDodge", state)
		return "PerfectDodge"
	end

	fire("Dodged", player, hitInfo)
	broadcast("Dodged", state)
	return "Dodged"
end

----------------------------------------------------------------------
-- Personajes y jugadores
----------------------------------------------------------------------

local function clearCharacterConnections(player)
	local list = characterConnections[player]
	if list then
		for _, connection in list do
			connection:Disconnect()
		end
		characterConnections[player] = nil
	end
end

local function unbindCharacter(player, reason)
	local state = states[player]
	clearCharacterConnections(player)
	if state then
		cancelDash(player, state, reason)
		state.character, state.humanoid, state.root = nil, nil, nil
	end
end

local function bindCharacter(player, character)
	local state = states[player]
	if not state then
		return
	end

	unbindCharacter(player, "Respawn")

	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not states[player] or player.Character ~= character or not humanoid or not root then
		return
	end

	state.character, state.humanoid, state.root = character, humanoid, root
	state.charges = cfg.MaxCharges
	state.rechargeAt = 0
	state.phase = "Idle"
	state.lastDashId = 0
	state.invulnerable = false
	state.startPosition = nil
	activeSet[player] = nil
	setAttributes(state)
	publishCooldown(player, state) -- [v2] personaje nuevo = cargas llenas

	characterConnections[player] = {
		humanoid.Died:Connect(function()
			cancelDash(player, state, "Died")
		end),
	}
end

local function onPlayerAdded(player)
	if states[player] then
		return
	end
	states[player] = newState()

	playerConnections[player] = {
		player.CharacterAdded:Connect(function(character)
			bindCharacter(player, character)
		end),
		player.CharacterRemoving:Connect(function()
			unbindCharacter(player, "CharacterRemoving")
		end),
	}

	if player.Character then
		task.spawn(bindCharacter, player, player.Character)
	end
end

local function onPlayerRemoving(player)
	unbindCharacter(player, "PlayerLeft")
	local list = playerConnections[player]
	if list then
		for _, connection in list do
			connection:Disconnect()
		end
		playerConnections[player] = nil
	end
	states[player] = nil
	activeSet[player] = nil
end

----------------------------------------------------------------------
-- Inicio / fin
----------------------------------------------------------------------

function DodgeService.Init(newEnv)
	if started then
		return
	end
	started = true
	env = newEnv

	table.insert(globalConnections, Players.PlayerAdded:Connect(onPlayerAdded))
	table.insert(globalConnections, Players.PlayerRemoving:Connect(onPlayerRemoving))
	table.insert(
		globalConnections,
		RunService.Heartbeat:Connect(function()
			local now = os.clock()
			for player in activeSet do
				local state = states[player]
				if state then
					advance(player, state, now)
				else
					activeSet[player] = nil
				end
			end
		end)
	)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return DodgeService