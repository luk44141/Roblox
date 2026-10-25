--[[
	MovementConfig  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > MovementConfig

	Parámetros del cursor y de la orientación del personaje.
	"Sharpness" = qué tan rápido converge un valor (más alto = más rápido/seco).
]]

local MovementConfig = {
	Cursor = {
		ToggleKey = Enum.KeyCode.T,
		ResetToGameOnRespawn = true, -- Al reaparecer vuelve al modo de juego
	},

	Orientation = {
		-- Política en modo NORMAL, sin lock-on, sin ShiftLock y sin acción de combate:
		--   "FaceCameraWhenMoving": mira al frente de la cámara solo mientras te movés (A/D no lo giran)
		--   "FaceCameraAlways":     siempre mira al frente de la cámara
		--   "Free":                 comportamiento estándar de Roblox (gira hacia donde caminás)
		NormalPolicy = "FaceCameraWhenMoving",
		NormalTurnSharpness = 18,
		ShiftLockTurnSharpness = 30,

		-- Durante Windup / Active / Recovery / ComboWindow el personaje apunta al frente de la cámara,
		-- porque la hitbox del ataque sale del HumanoidRootPart.
		CombatTurnSharpness = 30,

		MovingThreshold = 0.05, -- Magnitud mínima de MoveDirection para considerar "en movimiento"
		OverrideDriftTolerance = 0.02, -- Radianes: durante el dash solo se corrige el yaw si se desvía más que esto
	},
}

return MovementConfig