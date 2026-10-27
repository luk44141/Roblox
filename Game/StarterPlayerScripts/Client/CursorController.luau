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
local lastFocusReleasedAt = 0 -- [v2.2]
local FOCUS_HEAL_DELAY = 0.15 -- [v2.2] s: ignora la entrada del mismo instante en que se perdió el foco
local lastAltAt = -math.huge -- [v2.6] última vez que se apretó o soltó Alt
local ALT_FOCUS_IGNORE = 1 -- [v2.6] s
local FOCUS_GRACE = 0.3 -- [v2.3] s: tras perder el foco se sigue tratando como enfocada (evita el parpadeo del mouse con Alt)
local mouseOwned = false
local iconHidden = false
local savedIconEnabled = true
local started = false
local connections = {}

-- true = el cursor está bloqueado y el mouse debe rotar la cámara
function CursorController.IsRotationActive()
	return mode == "Game"
		and (windowFocused or os.clock() - lastFocusReleasedAt < FOCUS_GRACE)
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
-- [v2.5] Pulsar Alt (en Windows) puede soltar el bloqueo del mouse por debajo sin que la propiedad MouseBehavior cambie,
-- y como ya vale LockCenter nunca se reaplicaba: el mouse quedaba libre al activar / sacar el ShiftLock. Con ForceRelock
-- se pasa por Default un fotograma y se vuelve a LockCenter para obligar al motor a bloquear de nuevo.
local relockFrames = 0
local lastRelockAt = -math.huge
local FREE_CURSOR_THRESHOLD = 0.18 -- fracción del lado menor de la pantalla; más lejos del centro = cursor libre
local FREE_CURSOR_COOLDOWN = 0.12 -- s entre re-bloqueos forzados
function CursorController.ForceRelock()
	relockFrames = 2
end

local function apply()
	local lock = CursorController.IsRotationActive()

	if lock then
		if relockFrames == 2 then
			relockFrames = 1
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			return
		elseif relockFrames == 1 then
			relockFrames = 0
		end
		-- [v2.6] Se reasigna SIEMPRE (no solo si cambió): si el sistema soltó el bloqueo por debajo, vuelve en el acto.
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		mouseOwned = true

		-- [v2.7] Detector de cursor libre: con el bloqueo activo el cursor siempre está en el centro de la pantalla. Si se
		-- aleja (p. ej. tras apretar Alt solo y mover el mouse, que en Windows lo libera hasta apretar otra tecla), se
		-- fuerza el re-bloqueo pasando por Default un fotograma, con un mínimo de FREE_CURSOR_COOLDOWN entre intentos.
		local camera = workspace.CurrentCamera
		if camera and relockFrames == 0 and os.clock() - lastRelockAt > FREE_CURSOR_COOLDOWN then
			local size = camera.ViewportSize
			local offset = UserInputService:GetMouseLocation() - size / 2
			if offset.Magnitude > math.min(size.X, size.Y) * FREE_CURSOR_THRESHOLD then
				lastRelockAt = os.clock()
				CursorController.ForceRelock()
			end
		end
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
			-- [v2.6] El mouse NUNCA se libera por pulsar Alt (tecla del ShiftLock): si Alt está apretada o se soltó hace
			-- un instante y no es un Alt+Tab (Tab apretada), el "foco perdido" es falso y se ignora.
			local altActive = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
				or os.clock() - lastAltAt < ALT_FOCUS_IGNORE
			if altActive and not UserInputService:IsKeyDown(Enum.KeyCode.Tab) then
				CursorController.ForceRelock()
				return
			end
			windowFocused = false
			lastFocusReleasedAt = os.clock()
		end)
	)
	table.insert(
		connections,
		UserInputService.WindowFocused:Connect(function()
			windowFocused = true
		end)
	)

	-- [v2.2] Auto-corrección: a veces (p. ej. al pulsar Alt en Windows) llega WindowFocusReleased y NUNCA WindowFocused,
	-- y el cursor se queda desbloqueado. Si el juego vuelve a recibir entrada del mouse/teclado, la ventana está
	-- enfocada: se recupera el foco y el cursor se vuelve a bloquear solo.
	local function healFocus()
		if not windowFocused and os.clock() - lastFocusReleasedAt > FOCUS_HEAL_DELAY then
			windowFocused = true
		end
	end
	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				healFocus()
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
				lastAltAt = os.clock()
				CursorController.ForceRelock()
			end
			healFocus()
		end)
	)

	-- [v2.5] Al soltar Alt (tecla del ShiftLock) y al recuperar el foco, se fuerza el re-bloqueo del mouse.
	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
				lastAltAt = os.clock()
				CursorController.ForceRelock()
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.WindowFocused:Connect(function()
			CursorController.ForceRelock()
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