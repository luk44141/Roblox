-- CombatClient  (LocalScript)
-- Ubicación: StarterPlayer > StarterPlayerScripts > CombatClient
-- ÚNICO punto de arranque del cliente (reemplaza a ClientBootstrap) y ÚNICO que escucha CharacterAdded/Removing.
-- Entrada del jugador y enrutado de eventos del servidor. No decide daño ni impactos.
--
-- Módulos hijos (combate):       MovementController, LockOn, HitFeedback, CombatIndicators, CooldownHUD [v2]
-- Módulos en StarterPlayerScripts > Client:  CameraController, SprintController, CursorController,
--                                CharacterOrientation, DashController
--
-- Quién escribe qué (un solo dueño por propiedad):
--   CurrentCamera ............ CameraController
--   Humanoid.AutoRotate / yaw  CharacterOrientation
--   Humanoid.WalkSpeed ....... SprintController
--   Humanoid:Move (limites) .. MovementController
--   MouseBehavior / icono .... CursorController

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local StarterPlayer = game:GetService("StarterPlayer")

local player = Players.LocalPlayer

local combatFolder = ReplicatedStorage:WaitForChild("CombatSystem")
local CombatConfig = require(combatFolder:WaitForChild("CombatConfig"))
local remotesFolder = combatFolder:WaitForChild(CombatConfig.Remotes.FolderName)
local requestRemote = remotesFolder:WaitForChild(CombatConfig.Remotes.Request) :: RemoteEvent
local feedbackRemote = remotesFolder:WaitForChild(CombatConfig.Remotes.Feedback) :: RemoteEvent

local MovementController = require(script:WaitForChild("MovementController"))
local LockOn = require(script:WaitForChild("LockOn"))
local HitFeedback = require(script:WaitForChild("HitFeedback"))
local CombatIndicators = require(script:WaitForChild("CombatIndicators"))
local CooldownHUD = require(script:WaitForChild("CooldownHUD")) -- [v2]
local DashConfig = require(combatFolder:WaitForChild("DashConfig")) -- [v2] solo para el nombre de la tecla del dash en el HUD

local Client = script.Parent:WaitForChild("Client")
local CameraController = require(Client:WaitForChild("CameraController"))
local SprintController = require(Client:WaitForChild("SprintController"))
local CursorController = require(Client:WaitForChild("CursorController"))
local CharacterOrientation = require(Client:WaitForChild("CharacterOrientation"))
local DashController = require(Client:WaitForChild("DashController"))

local KEY_HEAVY = Enum.KeyCode.R
local KEY_BLOCK = Enum.KeyCode.F

if StarterPlayer.EnableMouseLockOption then
	warn("[CombatClient] StarterPlayer.EnableMouseLockOption está activo: desactivalo para que LeftShift no active el Shift Lock nativo de Roblox.")
end

---------------------------------------------------------------------
-- Estado compartido
---------------------------------------------------------------------

local isBlockHeld = false

-- Los controles de combate solo funcionan con el cursor bloqueado (modo de juego) y sin el menú de Roblox abierto.
local function canAct(): boolean
	return CursorController.IsGameMode() and not GuiService.MenuIsOpen
end

-- Fase efectiva de movimiento. Prioridad: stun del servidor > fase del dash local > ataque (servidor) > Parry > Block.
-- [v2] Block / Parry salen del atributo CombatDefense que publica CombatService (refleja lo que el SERVIDOR considera
-- bloqueo o parry activo: se ignora F mantenida si el servidor la rechazó, p. ej. durante un ataque o guard break).
-- Al soltar F o terminar la ventana de parry el atributo vuelve a "None" y MovementController deja de limitar:
-- la velocidad (caminar / sprint) la sigue decidiendo solo SprintController.
local function getCombatPhase(): string
	local character = player.Character
	if not character then
		return "None"
	end
	local serverPhase = character:GetAttribute("CombatMovePhase") or "None"
	if serverPhase == "Stunned" then
		return serverPhase
	end

	local dashPhase = DashController.GetMovePhase()
	if dashPhase then
		return dashPhase
	end

	-- [v2.7] Combo aéreo (el atacante): movimiento muy penalizado para que el rival siempre quede delante.
	if character:GetAttribute("CombatAirCombo") == true then
		return "AirCombo"
	end

	if serverPhase == "None" then
		local defense = character:GetAttribute("CombatDefense")
		if defense == "Parry" then
			return "Parry"
		elseif defense == "Blocking" then
			return "Block"
		end
	end
	return serverPhase
end

-- Reglas locales para el dash (el servidor las vuelve a validar con CombatService).
local function canStartDash(): (boolean, string?)
	local character = player.Character
	if not character then
		return false, "NoCharacter"
	end
	-- [v2.3] Estampado (SlamStun): stun en el que solo se permite el dash (lo marca el servidor).
	if character:GetAttribute("CombatDashable") == true then
		return true, nil
	end
	if isBlockHeld then
		return false, "Blocking"
	end
	if character:GetAttribute("CombatStunned") then
		return false, "Stunned"
	end
	local phase = character:GetAttribute("CombatMovePhase") or "None"
	-- [v2.10] La recuperación de un M1 del combo se puede cancelar con dash (el servidor marca CombatDashCancel).
	if phase == "Recovery" and character:GetAttribute("CombatDashCancel") == true then
		return true, nil
	end
	if phase ~= "None" and phase ~= "ComboWindow" then
		return false, "Busy"
	end
	return true, nil
end

---------------------------------------------------------------------
-- Arranque de módulos
---------------------------------------------------------------------

CursorController.Start()
SprintController.Start()

CameraController.Start({
	isRotationActive = CursorController.IsRotationActive,
	isSprinting = SprintController.IsSprinting,
	isDashing = DashController.IsDashing,
	getLockTarget = LockOn.GetCameraTarget,
})

-- [v2.7] Ayuda del combo aéreo (CombatConfig.Assist): el servidor manda el rival atrapado; se usa a través del mismo
-- provider del lock-on (el lock-on real siempre manda).
local assistRoot: BasePart? = nil
local assistUntil = 0

local function getFacingTarget(): (BasePart?, number?)
	local lockRoot, lockSharpness = LockOn.GetFacingTarget()
	if lockRoot then
		return lockRoot, lockSharpness
	end
	if assistRoot and assistRoot.Parent and os.clock() < assistUntil then
		return assistRoot, CombatConfig.Assist.TurnSharpness
	end
	return nil, nil
end

CharacterOrientation.Start({
	getCameraYaw = CameraController.GetYaw,
	isShiftLockActive = CameraController.IsShiftLockActive,
	getLockTarget = getFacingTarget,
	getCombatPhase = getCombatPhase,
})

DashController.Start({
	getCameraYaw = CameraController.GetYaw,
	isGameMode = canAct,
	canStart = canStartDash,
	requestDash = function(dashId: number)
		requestRemote:FireServer("Dash", dashId)
	end,
	orientation = CharacterOrientation,
})

MovementController.Start({ getPhase = getCombatPhase })

-- [v2] HUD de cooldowns: lee el estado real publicado por el servidor (atributos del Player). Para el dash también usa
-- la predicción local (DashController) y muestra el valor más restrictivo: lo que de verdad te dejaría hacer el cliente.
CooldownHUD.Start({
	keys = { Dash = DashConfig.Key, Heavy = KEY_HEAVY, Parry = KEY_BLOCK, Jump = Enum.KeyCode.Space, Feint = "M2" },
	getDashCooldownRemaining = DashController.GetCooldownRemaining,
	getJumpCooldownRemaining = MovementController.GetJumpCooldownRemaining,
})

-- Solo valida el objetivo (ya no escribe la cámara). Antes del paso de cámara (Camera + 1).
RunService:BindToRenderStep("CombatLockOnValidate", Enum.RenderPriority.Camera.Value - 1, LockOn.Step)

---------------------------------------------------------------------
-- Entrada
---------------------------------------------------------------------

local function releaseBlock()
	if isBlockHeld then
		isBlockHeld = false
		requestRemote:FireServer("BlockEnd")
	end
end

-- Si F sigue presionada al terminar o cancelarse el dash, se vuelve a pedir el bloqueo
-- (el servidor lo rechaza mientras dura el dash).
local function resyncBlock()
	if isBlockHeld and not DashController.IsBusy() then
		requestRemote:FireServer("BlockStart")
	end
end

local connections = {}

table.insert(
	connections,
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not canAct() then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- [v2.16] El clic también se envía durante el dash: el servidor lo recuerda y lo ejecuta apenas termina el dash.
			do
				-- [v2.3] Corriendo hacia adelante (W + sprint, sin acción en curso) = ataque corriendo; el servidor lo
				-- valida con la velocidad real y, si no cumple, lo trata como M1. Con Espacio mantenido, el 4º golpe es Uppercut.
				local character = player.Character
				local phase = if character then (character:GetAttribute("CombatMovePhase") or "None") else "None"
				-- [v2.4] Basta con Shift + W y haber ganado un poco de velocidad (RunAttack.MinSpeed, apenas sobre caminar).
				local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
				local planarSpeed = 0
				if root and root:IsA("BasePart") then
					local v = root.AssemblyLinearVelocity
					planarSpeed = math.sqrt(v.X * v.X + v.Z * v.Z)
				end
				local running = CombatConfig.RunAttack.Enabled
					and phase == "None"
					and not isBlockHeld
					and SprintController.IsSprintKeyHeld()
					and UserInputService:IsKeyDown(Enum.KeyCode.W)
					and planarSpeed >= CombatConfig.RunAttack.MinSpeed
				if running then
					requestRemote:FireServer("RunAttack")
				else
					requestRemote:FireServer("M1", { Up = UserInputService:IsKeyDown(CombatConfig.Uppercut.Key) })
				end
				-- [v2.5] Clic mantenido: el servidor encadena solo los 4 golpes (y el Uppercut si mantenés Espacio)
				requestRemote:FireServer("M1Hold", true)
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
			if CombatConfig.LockOn.Enabled then
				LockOn.Toggle()
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- [v2.9] Finta: clic derecho durante la anticipación de un M1 lo cancela (el servidor valida todo)
			requestRemote:FireServer("Feint")
		elseif input.KeyCode == KEY_HEAVY then
			if not DashController.IsBusy() then
				CooldownHUD.NotifyPress("Heavy") -- [v2] solo feedback visual si está en cooldown; el servidor decide siempre
				requestRemote:FireServer("Heavy")
			end
		elseif input.KeyCode == KEY_BLOCK and not isBlockHeld then
			isBlockHeld = true
			if not DashController.IsBusy() then
				requestRemote:FireServer("BlockStart")
			end
		end
	end)
)

table.insert(
	connections,
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == KEY_BLOCK then
			releaseBlock()
		end
	end)
)

-- [v2.4] Espacio mantenido (Uppercut): el servidor lo necesita aunque el 4º clic se recuerde (buffer) o se apriete antes.
local upHeldSent = false
local function setUpHeld(held: boolean)
	if upHeldSent ~= held then
		upHeldSent = held
		requestRemote:FireServer("UpHold", held)
	end
end

table.insert(
	connections,
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.KeyCode == CombatConfig.Uppercut.Key and UserInputService:GetFocusedTextBox() == nil then
			setUpHeld(true)
		end
	end)
)
table.insert(
	connections,
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == CombatConfig.Uppercut.Key then
			setUpHeld(false)
		end
	end)
)
table.insert(connections, UserInputService.WindowFocusReleased:Connect(function()
	setUpHeld(false)
end))

table.insert(
	connections,
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			requestRemote:FireServer("M1Hold", false)
		end
	end)
)
table.insert(connections, UserInputService.WindowFocusReleased:Connect(function()
	requestRemote:FireServer("M1Hold", false)
end))

table.insert(connections, UserInputService.WindowFocusReleased:Connect(releaseBlock))
table.insert(connections, DashController.Events.RecoveryEnded:Connect(resyncBlock))
table.insert(connections, DashController.Events.DashCancelled:Connect(resyncBlock))

---------------------------------------------------------------------
-- Eventos del servidor
---------------------------------------------------------------------

table.insert(
	connections,
	feedbackRemote.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		local kind = payload.Kind
		if kind == "Damage" then
			HitFeedback.OnDamage(payload)
		elseif kind == "Telegraph" then
			CombatIndicators.OnTelegraph(payload)
		elseif kind == "TelegraphCancel" then
			CombatIndicators.OnTelegraphCancel(payload)
		elseif kind == "Stun" then
			CombatIndicators.OnStun(payload)
		elseif kind == "DashResponse" then
			DashController.OnServerResponse(payload)
		elseif kind == "DodgeEvent" then
			DashController.OnServerEvent(payload)
		elseif kind == "Launch" then
			-- [v2.4] Uppercut: los dos suben y quedan flotando hasta LaunchEnd
			MovementController.StartAirHang(payload.VelocityY, payload.RiseTime, payload.MaxTime)
		elseif kind == "Freeze" then
			MovementController.FreezeAirHang() -- [v2.11] el agarre deja quieto al que agarra
		elseif kind == "LaunchEnd" then
			MovementController.StopAirHang()
			assistUntil = 0 -- termina la ayuda continua del combo aéreo
		elseif kind == "Grab" then
			-- [v2.5] R en el aire: este jugador queda sujeto delante de quien lo agarra
			MovementController.StartGrab(payload.Holder, payload.Duration, payload.Offset)
		elseif kind == "GrabEnd" then
			MovementController.StopGrab()
		elseif kind == "Assist" then
			-- [v2.7] Girar hacia el rival y, si está algo lejos, un paso corto hacia él
			local targetModel = payload.Target
			local targetRoot = if typeof(targetModel) == "Instance" then targetModel:FindFirstChild("HumanoidRootPart") else nil
			local character = player.Character
			local myRoot = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if targetRoot and targetRoot:IsA("BasePart") and myRoot and myRoot:IsA("BasePart") then
				assistRoot = targetRoot
				assistUntil = math.max(assistUntil, os.clock() + (if typeof(payload.Duration) == "number" then payload.Duration else 0.3))

				local assistCfg = CombatConfig.Assist
				local gap = if typeof(payload.Gap) == "number" then payload.Gap else 0
				if gap > assistCfg.StopDistance then
					local offset = targetRoot.Position - myRoot.Position
					local flat = Vector3.new(offset.X, 0, offset.Z)
					if flat.Magnitude > 0.01 then
						MovementController.ApplyKnockback(
							flat.Unit,
							math.min(gap - assistCfg.StopDistance, assistCfg.MaxStep),
							assistCfg.StepTime
						)
					end
				end
			end
		elseif kind == "Knockback" then
			-- [v2.2] Empuje por M1 recibido: lo aplica el cliente dueño del personaje
			MovementController.ApplyKnockback(payload.Direction, payload.Distance, payload.Duration)
		end
	end)
)

---------------------------------------------------------------------
-- Ciclo de vida del personaje (único punto)
---------------------------------------------------------------------

local generation = 0

local function clearCharacter()
	isBlockHeld = false
	LockOn.Release()
	DashController.SetCharacter(nil, nil, nil)
	CharacterOrientation.SetCharacter(nil, nil)
	SprintController.SetCharacter(nil)
	CameraController.SetCharacter(nil, nil, nil)
end

local function onCharacterAdded(character: Model)
	generation += 1
	local thisGeneration = generation
	clearCharacter()

	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	-- Si el personaje cambió o desapareció mientras esperábamos, abortar
	if thisGeneration ~= generation or player.Character ~= character or not humanoid or not root then
		return
	end

	CursorController.OnCharacterAdded()
	CameraController.SetCharacter(humanoid :: Humanoid, root :: BasePart, character)
	CharacterOrientation.SetCharacter(humanoid :: Humanoid, root :: BasePart)
	SprintController.SetCharacter(humanoid :: Humanoid)
	DashController.SetCharacter(humanoid :: Humanoid, root :: BasePart, character)
end

local function onCharacterRemoving()
	generation += 1
	clearCharacter()
end

table.insert(connections, player.CharacterAdded:Connect(onCharacterAdded))
table.insert(connections, player.CharacterRemoving:Connect(onCharacterRemoving))

if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end

---------------------------------------------------------------------
-- Limpieza
---------------------------------------------------------------------

script.Destroying:Connect(function()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	RunService:UnbindFromRenderStep("CombatLockOnValidate")
	clearCharacter()
	MovementController.Stop()
	CooldownHUD.Destroy()
	DashController.Destroy()
	CharacterOrientation.Destroy()
	CameraController.Destroy()
	SprintController.Destroy()
	CursorController.Destroy()
end)