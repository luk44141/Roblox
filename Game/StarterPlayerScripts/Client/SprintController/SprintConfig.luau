--[[
	SprintConfig  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > SprintController > SprintConfig
]]

local SprintConfig = {
	WalkSpeed = 16,
	SprintSpeed = 24,
	SprintKey = Enum.KeyCode.LeftShift,

	-- IsSprinting() solo es true si la velocidad horizontal REAL supera WalkSpeed + este margen.
	-- Así, durante ataques/stun/recuperación (movimiento limitado por CombatConfig) no cuenta como sprint.
	SprintDetectionMargin = 1,
}

return SprintConfig