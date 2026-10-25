-- CombatClient  (LocalScript)
-- Ubicación: StarterPlayer > StarterPlayerScripts > CombatClient
-- ÚNICO punto de arranque del cliente (reemplaza a ClientBootstrap) y ÚNICO que escucha CharacterAdded/Removing.
-- Entrada del jugador y enrutado de eventos del servidor. No decide daño ni impactos.
--
-- Módulos hijos (combate):       MovementController, LockOn, HitFeedback, CombatIndicators
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

-- Fase efectiva de movimiento: el stun del servidor manda; luego la fase del dash local; luego la del combate.
local function getCombatPhase(): string
	local character = player.Character
	if not character then
		return "None"
	end
	local serverPhase = character:GetAttribute("CombatMovePhase") or "None"
	if serverPhase == "Stunned" then
		return serverPhase
	end
	return DashController.GetMovePhase() or serverPhase
end

-- Reglas locales para el dash (el servidor las vuelve a validar con CombatService).
local function canStartDash(): (boolean, string?)
	local character = player.Character
	if not character then
		return false, "NoCharacter"
	end
	if isBlockHeld then
		return false, "Blocking"
	end
	if character:GetAttribute("CombatStunned") then
		return false, "Stunned"
	end
	local phase = character:GetAttribute("CombatMovePhase") or "None"
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

CharacterOrientation.Start({
	getCameraYaw = CameraController.GetYaw,
	isShiftLockActive = CameraController.IsShiftLockActive,
	getLockTarget = LockOn.GetFacingTarget,
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
			if not DashController.IsBusy() then
				requestRemote:FireServer("M1")
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
			if CombatConfig.LockOn.Enabled then
				LockOn.Toggle()
			end
		elseif input.KeyCode == KEY_HEAVY then
			if not DashController.IsBusy() then
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
	DashController.Destroy()
	CharacterOrientation.Destroy()
	CameraController.Destroy()
	SprintController.Destroy()
	CursorController.Destroy()
end)