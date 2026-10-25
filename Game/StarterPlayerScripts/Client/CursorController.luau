--[[
	CursorController  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > CursorController

	ÚNICO dueño de MouseBehavior y MouseIconEnabled.

	Modo "Game": cursor oculto y bloqueado al centro; el mouse rota la cámara.
	Modo "UI":   cursor visible y libre; el mouse NO rota la cámara.
	La tecla T alterna entre ambos (ignorada si se escribe en un TextBox).

	El bloqueo se suspende (sin cambiar de modo) si: se pierde el foco de la ventana,
	el menú de Roblox está abierto o hay un TextBox enfocado.
	Es independiente del estado de ShiftLock.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SignalSet = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("SignalSet"))
local cfg = require(script.Parent:WaitForChild("MovementConfig")).Cursor

local RENDER_STEP_NAME = "CursorControllerUpdate"

local CursorController = {}
CursorController.Signals = SignalSet.new({ "ModeChanged" })
CursorController.Events = CursorController.Signals.Events

local mode = "Game"
local windowFocused = true
local mouseOwned = false
local iconHidden = false
local savedIconEnabled = true
local started = false
local connections = {}

-- true = el cursor está bloqueado y el mouse debe rotar la cámara
function CursorController.IsRotationActive()
	return mode == "Game"
		and windowFocused
		and not GuiService.MenuIsOpen
		and UserInputService:GetFocusedTextBox() == nil
end

function CursorController.GetMode()
	return mode
end

function CursorController.IsGameMode()
	return mode == "Game"
end

function CursorController.SetMode(newMode)
	if newMode ~= "Game" and newMode ~= "UI" then
		return
	end
	if newMode == mode then
		return
	end
	mode = newMode
	CursorController.Signals:Fire("ModeChanged", mode)
end

function CursorController.Toggle()
	CursorController.SetMode(if mode == "Game" then "UI" else "Game")
end

function CursorController.OnCharacterAdded()
	if cfg.ResetToGameOnRespawn then
		CursorController.SetMode("Game")
	end
end

-- Solo toca MouseBehavior/MouseIcon cuando hace falta y restaura lo que cambió.
local function apply()
	local lock = CursorController.IsRotationActive()

	if lock then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		mouseOwned = true
	elseif mouseOwned then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		mouseOwned = false
	end

	if lock and not iconHidden then
		savedIconEnabled = UserInputService.MouseIconEnabled
		UserInputService.MouseIconEnabled = false
		iconHidden = true
	elseif not lock and iconHidden then
		UserInputService.MouseIconEnabled = savedIconEnabled
		iconHidden = false
	end
end

function CursorController.Start()
	if started then
		return
	end
	started = true

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed or input.KeyCode ~= cfg.ToggleKey then
				return
			end
			if UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			CursorController.Toggle()
		end)
	)
	table.insert(
		connections,
		UserInputService.WindowFocusReleased:Connect(function()
			windowFocused = false
		end)
	)
	table.insert(
		connections,
		UserInputService.WindowFocused:Connect(function()
			windowFocused = true
		end)
	)

	-- Antes que la cámara (Camera + 1) para que ya vea el estado del cursor de este frame
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value, apply)
end

function CursorController.Destroy()
	if not started then
		return
	end
	started = false

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	-- Restaura MouseBehavior y MouseIcon
	local previousMode = mode
	mode = "UI"
	apply()
	mode = previousMode
end

return CursorController