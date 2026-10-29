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
	-- [v2.16] Distance 13 -> 18 y Duration 0.28 -> 0.32 (velocidad pico ~112 studs/s). RecoveryTime 0.06 -> 0.03: tras el dash
	-- se puede atacar casi enseguida (dash + M1).
	Duration = 0.32,
	Distance = 18,
	Cooldown = 2, -- Desde el INICIO del dash [v2.4: antes 0.65]
	RecoveryTime = 0.03,
	-- [v2.9] Ventanas más generosas: el dodge normal ocupa casi todo el dash (antes 0.12 s) y el Perfect Dodge pasa de
	-- 0.08 a 0.11 s. El dodge normal efectivo es InvulnerabilityDuration + Server.InvulnerabilityPadding (tope: Duration).
	InvulnerabilityDuration = 0.22, -- Desde el inicio del dash
	PerfectDodgeWindow = 0.11, -- Golpe que se resuelve dentro de esta ventana desde el inicio del dash = Perfect Dodge
	-- (debe ser <= InvulnerabilityDuration)

	-- [v2.3] Lo ÚNICO que distingue un Perfect Dodge de un dodge normal en el juego: un poco de velocidad de
	-- movimiento. WalkSpeed (caminar y sprint) se multiplica por Multiplier durante Duration segundos.
	-- (Los textos y destellos de HitFeedback solo sirven para ver cuál fue; no cambian nada del combate.)
	PerfectDodgeSpeedBoost = {
		Multiplier = 1.2,
		Duration = 2.0,
	},

	MaxCharges = 1,

	-- v(t) = base * (p + 1) * (1 - t/T)^p. La distancia total siempre es "Distance".
	SpeedDecayPower = 1,

	Direction = {
		Mode = "FourWay", -- "FourWay" o "Free"
		NoInput = "Backward", -- Sin teclas: "Backward" o "Forward"
		AlignCharacterToCamera = true,
		-- [v2.9] Dash lateral (A / D) CIRCULAR: la dirección sigue al yaw de la cámara durante todo el dash. Con lock-on
		-- (la cámara apunta al objetivo) el dash lateral rodea al rival hasta quedar detrás de él.
		CircularSideDash = true,
	},

	AllowInAir = true, -- [v2.3] el dash también se puede hacer en el aire (el eje Y queda libre)
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