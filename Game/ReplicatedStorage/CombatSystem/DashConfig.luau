--[[
	DashConfig  (ModuleScript)
	Ubicación: ReplicatedStorage > CombatSystem > DashConfig
	(antes estaba en ReplicatedStorage > Combat; esa carpeta se elimina)

	Compartido entre cliente (DashController) y servidor (DodgeService).
	Tiempos en SEGUNDOS, distancias en studs.
	Las restricciones de movimiento durante el dash NO están acá: viven en CombatConfig.Movement.Dash.
]]

local DashConfig = {
	Key = Enum.KeyCode.Q,

	-- Tiempos
	-- [CAMBIO] Distance 8 -> 13 (más alcance) y Duration 0.25 -> 0.28 (la velocidad pico sube poco: ~93 studs/s).
	-- [CAMBIO] RecoveryTime 0.15 -> 0.06: es el tiempo tras el dash en que no se puede atacar ni bloquear
	-- (el servidor lo usa en DodgeService.IsBusy). La invulnerabilidad y el Perfect Dodge NO cambian.
	Duration = 0.28,
	Distance = 13,
	Cooldown = 0.65, -- Desde el INICIO del dash
	RecoveryTime = 0.06,
	InvulnerabilityDuration = 0.12, -- Desde el inicio del dash
	PerfectDodgeWindow = 0.08, -- Golpe que se resuelve dentro de esta ventana desde el inicio del dash = Perfect Dodge
	-- (debe ser <= InvulnerabilityDuration)

	MaxCharges = 1,

	-- v(t) = base * (p + 1) * (1 - t/T)^p. La distancia total siempre es "Distance".
	SpeedDecayPower = 1,

	Direction = {
		Mode = "FourWay", -- "FourWay" o "Free"
		NoInput = "Backward", -- Sin teclas: "Backward" o "Forward"
		AlignCharacterToCamera = true,
	},

	AllowInAir = false,
	BlockInUIMode = true,

	Physics = {
		ForceMultiplier = 20000, -- Fuerza máxima = masa * esto
	},

	Collision = {
		Width = 1.9,
		StepHeight = 0.8,
		HeadRoom = 1.0,
		SkinWidth = 0.1,
		MinDistance = 2,
		MinDuration = 0.08,
	},

	-- Validación en el servidor (el cliente solo envía un ID de secuencia)
	Server = {
		MinRequestInterval = 0.1, -- Anti-spam
		MaxIdJump = 8, -- Un ID nuevo debe ser mayor que el último y como máximo este salto más grande
		LatencyTolerance = 0.15,
		InvulnerabilityPadding = 0.05,

		-- Auditoría de desplazamiento: al terminar la fase activa se compara la distancia horizontal
		-- recorrida con la máxima plausible. Si se excede: señal DashViolation y sanción temporal.
		AuditDisplacement = true,
		MaxPlanarSpeed = 30, -- Velocidad horizontal máxima plausible (sprint 24 + margen)
		DisplacementSlack = 4,
		ViolationPenalty = 1.0, -- Segundos sin poder hacer dash
	},
}

return DashConfig