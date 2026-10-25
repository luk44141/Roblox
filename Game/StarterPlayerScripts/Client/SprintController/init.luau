--[[
	SprintController  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > SprintController
	Hijo: SprintConfig

	ÚNICO escritor de Humanoid.WalkSpeed (16 caminando, 24 con LeftShift), siempre por eventos, nunca por frame.

	Estrategia de velocidad efectiva (sin pelear por WalkSpeed):
	  - WalkSpeed expresa la INTENCIÓN del jugador (caminar o sprintear).
	  - Las restricciones del combate (ataque, stun, recuperación del dash) las aplica MovementController
	    limitando el vector de movimiento con un tope ABSOLUTO en studs/s (CombatConfig.Movement),
	    dividido por el WalkSpeed actual. Por eso el sprint nunca anula esas restricciones.
	  - IsSprinting() mide la velocidad real, así la cámara no muestra sprint cuando el combate te limita.
]]

local UserInputService = game:GetService("UserInputService")

local cfg = require(script:WaitForChild("SprintConfig"))

local SprintController = {}

local humanoid: Humanoid? = nil
local isSprintKeyHeld = false
local started = false
local connections = {}

-- Aplica la velocidad correspondiente según el estado actual.
-- Solo se llama ante eventos (tecla, respawn, foco), nunca por fotograma.
local function updateSpeed()
	if humanoid and humanoid.Parent then
		humanoid.WalkSpeed = if isSprintKeyHeld then cfg.SprintSpeed else cfg.WalkSpeed
	end
end

-- Detecta si el jugador está escribiendo en un TextBox (por ejemplo, el chat).
local function isTyping(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

-- true solo si la tecla está presionada Y el personaje realmente se mueve más rápido que caminando.
function SprintController.IsSprinting(): boolean
	if not isSprintKeyHeld or not humanoid or humanoid.Health <= 0 then
		return false
	end
	local root = humanoid.RootPart
	if not root then
		return false
	end
	local velocity = root.AssemblyLinearVelocity
	local planarSpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	return planarSpeed > cfg.WalkSpeed + cfg.SprintDetectionMargin
end

-- Llamar con el Humanoid de un personaje nuevo, y con nil al removerlo.
function SprintController.SetCharacter(newHumanoid: Humanoid?)
	humanoid = newHumanoid
	if humanoid then
		-- Sincroniza con el estado real del teclado (por si Shift ya estaba presionado al reaparecer).
		isSprintKeyHeld = UserInputService:IsKeyDown(cfg.SprintKey) and not isTyping()
		updateSpeed()
	end
end

function SprintController.Start()
	if started then
		return
	end
	started = true

	-- Entrada: se conecta UNA sola vez, no por personaje.
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.KeyCode ~= cfg.SprintKey then
				return
			end
			if isTyping() then
				return
			end
			isSprintKeyHeld = true
			updateSpeed()
		end)
	)

	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.KeyCode ~= cfg.SprintKey then
				return
			end
			-- Siempre se procesa la liberación, incluso si se está escribiendo,
			-- para que el sprint nunca quede "pegado".
			isSprintKeyHeld = false
			updateSpeed()
		end)
	)

	-- Si la ventana pierde el foco con Shift presionado (Alt+Tab, etc.),
	-- Roblox puede no enviar InputEnded: se corta el sprint por seguridad.
	table.insert(
		connections,
		UserInputService.WindowFocusReleased:Connect(function()
			isSprintKeyHeld = false
			updateSpeed()
		end)
	)
end

function SprintController.Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	isSprintKeyHeld = false
	updateSpeed()
	humanoid = nil
	started = false
end

return SprintController