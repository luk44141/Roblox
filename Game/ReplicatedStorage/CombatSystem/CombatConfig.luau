-- CombatConfig
-- Ubicación: ReplicatedStorage > CombatSystem
-- Configuración central del sistema de combate.
-- CAMBIOS respecto a tu versión (marcados con [NUEVO]):
--   * Movement.Dash: restricciones de movimiento durante el dash y su recuperación.
--   * Feedback.Numbers.Styles: estilos "Dodged" y "PerfectDodge".
-- CAMBIOS de esta actualización (marcados con [v2]):
--   * Movement: perfil Light más ágil, fases Block y Parry, recuperación del dash más ligera.
--   * Attacks.Heavy (tecla R): PlayerCooldown = 20 y ContinuesCombo. Attacks.DodgeDummyM1 (dummy de Perfect Dodge).
--   * Telegraph: rol DodgeTrainer, zonas de Dodge / Perfect Dodge.
--   * Feedback.Impact: efectos para Dodged y PerfectDodge.
--   * Dummies.PerfectDodgeDummy y CooldownHUD.

local CombatConfig = {}

-- Depuración visual
CombatConfig.Debug = {
	Enabled = true,
	HurtboxTransparency = 0.65,
	ParryTransparency = 0.25,
	AttackBoxTransparency = 0.45,
	AttackBoxDuration = 0.25,
	FolderName = "CombatDebug",
	PrintResults = true,
}

CombatConfig.Colors = {
	PlayerHurtbox = Color3.fromRGB(0, 162, 255),
	DummyHurtbox = Color3.fromRGB(0, 200, 90),
	ActiveAttack = Color3.fromRGB(255, 50, 50),
	SpecialZone = Color3.fromRGB(170, 85, 255),
}

CombatConfig.Tags = {
	Hurtbox = "CombatHurtbox",
}

CombatConfig.Hurtbox = {
	Size = Vector3.new(4, 5.5, 2),
	Offset = Vector3.new(0, -0.25, 0),
}

-- IDs de animación. Dejalos vacíos hasta tenerlos: si un ID está vacío, no se reproduce nada.
-- Formato: "rbxassetid://123456789". Deben ser animaciones R6 publicadas por vos o tu grupo.
CombatConfig.Animations = {
	M1_1 = "",   -- PENDIENTE
	M1_2 = "",   -- PENDIENTE
	M1_3 = "",   -- PENDIENTE
	M1_4 = "",   -- PENDIENTE
	M1_5 = "",   -- PENDIENTE (golpe final, más pesado)
	DummyM1 = "",-- PENDIENTE (puede repetir el de M1_1)
	Heavy = "",  -- PENDIENTE
	Stun = "",   -- PENDIENTE
}

-- Ataques. Tiempos en segundos.
--   Windup: anticipación | Active: ventana de impacto (caja fija) | Recovery: recuperación
--   Cooldown: solo para ataques que no son parte del combo
--   Label: texto del indicador de timing
--   MovementProfile: perfil de CombatConfig.Movement.Profiles
--   Finisher: marca el golpe final del combo (número y efecto distintos)
CombatConfig.Attacks = {
	M1_1 = {
		Label = "M1", Damage = 8, Windup = 0.18, Active = 0.12, Recovery = 0.22,
		Box = { Size = Vector3.new(5, 5, 5), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
	},
	M1_2 = {
		Label = "M1", Damage = 9, Windup = 0.16, Active = 0.12, Recovery = 0.22,
		Box = { Size = Vector3.new(5.5, 5, 5), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
	},
	M1_3 = {
		Label = "M1", Damage = 10, Windup = 0.16, Active = 0.12, Recovery = 0.24,
		Box = { Size = Vector3.new(5.5, 5, 5.5), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
	},
	M1_4 = {
		Label = "M1", Damage = 11, Windup = 0.18, Active = 0.12, Recovery = 0.26,
		Box = { Size = Vector3.new(6, 5, 5.5), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
	},
	M1_5 = {
		Label = "M1", Damage = 20, Windup = 0.32, Active = 0.18, Recovery = 0.55,
		Box = { Size = Vector3.new(7, 5.5, 7), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
		Finisher = true,
	},
	-- Ataque básico de BasicAttackerDummy: anticipación larga para aprender el timing.
	DummyM1 = {
		Label = "M1", Damage = 10, Windup = 0.7, Active = 0.15, Recovery = 0.4, Cooldown = 1,
		Box = { Size = Vector3.new(5, 5, 5), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
	},
	-- [v2] Ataque del PerfectDodgeDummy. Anticipación larga (1 s) para aprender el timing del dash.
	--   [v2.1] Box reducida (antes 24x8x24). Ahora es una caja chica delante del dummy: si te alejás con el dash antes
	--   del impacto el golpe puede fallar (sin daño y sin mensaje de dodge); para practicar, quedate cerca del dummy.
	--   TrainDodge: el telegraph dibuja las zonas de Dodge y Perfect Dodge (ver CombatIndicators).
	DodgeDummyM1 = {
		Label = "DODGE", Damage = 10, Windup = 1.0, Active = 0.15, Recovery = 0.4, Cooldown = 1,
		Box = { Size = Vector3.new(8, 6, 8), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = false, BreaksGuard = false,
		MovementProfile = "Light",
		TrainDodge = true,
	},
	-- Habilidad R del jugador.
	--   Cooldown: lo usan los dummies (GuardBreakDummy).
	--   [v2] PlayerCooldown: cooldown REAL para jugadores (20 s). Lo aplica y lo sincroniza el servidor.
	--   [v2] ContinuesCombo: usada dentro de un combo no lo reinicia; reabre la ventana para seguir con M1.
	Heavy = {
		Label = "GUARD BREAK", Damage = 25, Windup = 0.55, Active = 0.2, Recovery = 0.7, Cooldown = 3,
		PlayerCooldown = 20,
		ContinuesCombo = true,
		Box = { Size = Vector3.new(6, 5.5, 7), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = false, CanBeParried = false, BreaksGuard = true,
		MovementProfile = "Heavy",
	},
}

-- Combo M1 (jugadores)
--   Window: tiempo tras terminar la recuperación de un golpe para encadenar el siguiente.
--   BufferTime: un clic hecho durante Active/Recovery se recuerda este tiempo.
--   EndCooldown: pausa tras el golpe final antes de poder iniciar otro combo.
CombatConfig.Combo = {
	Sequence = { "M1_1", "M1_2", "M1_3", "M1_4", "M1_5" },
	Window = 0.55,
	BufferTime = 0.35,
	EndCooldown = 0.6,
}

-- Movilidad durante acciones (solo se aplica al jugador local, desde MovementController).
--   MaxSpeed: tope ABSOLUTO en studs/s (anula la ventaja del sprint).
--   Forward / Lateral / Backward: fracción de movimiento conservada en cada dirección,
--   relativa a hacia dónde mira el personaje (0 = nada, 1 = todo).
-- Fases: Windup, Active, Recovery, ComboWindow (espera entre golpes del combo).
CombatConfig.Movement = {
	AllowJump = false,
	Profiles = {
		-- [v2.1] M1 aún más ágil (original 8 / 5 / 6 / 10; v2: 12 / 9 / 11 / 14 studs/s). Heavy (R) no cambia.
		-- Con WalkSpeed 16 casi no hay penalización caminando; el sprint (24) sí queda topado.
		Light = {
			Windup = { MaxSpeed = 15, Forward = 1, Lateral = 1, Backward = 0.85 },
			Active = { MaxSpeed = 13, Forward = 1, Lateral = 0.9, Backward = 0.7 },
			Recovery = { MaxSpeed = 15, Forward = 1, Lateral = 1, Backward = 0.85 },
			ComboWindow = { MaxSpeed = 18, Forward = 1, Lateral = 1, Backward = 1 },
		},
		Heavy = {
			Windup = { MaxSpeed = 5, Forward = 0.8, Lateral = 0.4, Backward = 0.3 },
			Active = { MaxSpeed = 2, Forward = 0.5, Lateral = 0.2, Backward = 0.1 },
			Recovery = { MaxSpeed = 3, Forward = 0.6, Lateral = 0.3, Backward = 0.2 },
			ComboWindow = { MaxSpeed = 10, Forward = 1, Lateral = 0.8, Backward = 0.6 },
		},
	},
	Stunned = { MaxSpeed = 0, Forward = 0, Lateral = 0, Backward = 0 },

	-- [NUEVO] Restricciones del dash (las aplica MovementController con las mismas reglas que las demás fases).
	--   Active: el impulso lo da la física del dash; el control del Humanoid se anula para no pelear con él.
	--   Recovery: tras el dash, movilidad reducida (el sprint no da ventaja: MaxSpeed es absoluto).
	Dash = {
		Active = { MaxSpeed = 0, Forward = 0, Lateral = 0, Backward = 0 },
		-- [v2] Recuperación más ligera (antes MaxSpeed 6 / 0.8 / 0.6 / 0.4).
		Recovery = { MaxSpeed = 14, Forward = 1, Lateral = 1, Backward = 0.85 },
	},

	-- [v2] Defensa. Las aplica MovementController con las mismas reglas que las demás fases.
	--   Block: mientras se mantiene F y el servidor confirma el bloqueo (atributo CombatDefense = "Blocking").
	--   Parry: durante la ventana de parry (CombatDefense = "Parry"); algo más lento que Block.
	--   MaxSpeed es un tope ABSOLUTO: el sprint no lo anula. AllowJump = true conserva el salto
	--   (antes de este cambio se podía saltar bloqueando).
	-- [v2.1] Menos penalización (v2: Block 9 / Parry 6). Block ~75% de caminar, Parry ~62%.
	-- [v2.2] Frenada progresiva: al entrar en una fase con tope MÁS BAJO que tu velocidad (p. ej. sprint 24 -> M1 15),
	-- el tope baja a este ritmo (studs/s por segundo) en vez de cortar de golpe. Stun y dash siguen siendo inmediatos.
	SlowdownRate = 45,

	Block = { MaxSpeed = 12, Forward = 1, Lateral = 0.95, Backward = 0.85, AllowJump = true },
	Parry = { MaxSpeed = 10, Forward = 1, Lateral = 0.85, Backward = 0.75, AllowJump = true },
}

-- Defensa
CombatConfig.Block = {
	DamageMultiplier = 0.2,
	ParryWindow = 0.25,
	ParryCooldown = 0.8,
	GuardBreakStun = 1.5, -- tiempo sin poder bloquear tras un guard break (no es el stun por parry)
}

-- Stun por parry.
--   OnParried: segundos que queda aturdido el ATACANTE cuyo golpe fue desviado.
--   ImmunityAfter: tras terminar un stun, no se puede volver a aturdir durante este tiempo
--   (evita encadenar stuns infinitos). Un stun en curso nunca se reinicia.
CombatConfig.Stun = {
	OnParried = { Player = 1.0, Dummy = 1.5 },
	ImmunityAfter = 1.0,
	Indicator = {
		Color = Color3.fromRGB(255, 205, 40),
		Offset = Vector3.new(0, 3.3, 0),
	},
}

-- [v2.2] Reacción al recibir un M1 del combo (solo jugadores como objetivo).
--   Un M1 que CONECTA (no bloqueado, ni parryado, ni esquivado) deja al objetivo en hitstun: cancela lo que hacía y no
--   puede moverse, atacar, bloquear ni hacer dash. Lo ÚNICO que puede hacer es intentar un parry, UNA vez por golpe
--   recibido (esa chance no depende del cooldown del parry). Si falla, el siguiente M1 vuelve a conectar.
--   La duración cubre hasta que llega el siguiente golpe del combo: Active + Recovery + Windup siguiente + StunSlack.
--   Un parry exitoso libera al objetivo al instante (y aturde al atacante, como siempre).
--   Con el M1 final (M1_5) no hay chance de parry: solo FinisherStun segundos de hitstun.
--   Knockback: el objetivo es empujado en la dirección a la que mira el atacante (para el atacante es "hacia adelante";
--   para quien recibe es hacia atrás). Lo aplica el cliente del objetivo (ver MovementController.ApplyKnockback).
CombatConfig.HitReaction = {
	Enabled = true,
	StunSlack = 0.1,
	FinisherStun = 0.5,
	Knockback = {
		Distance = 2.5,
		FinisherDistance = 6,
		Duration = 0.18,
	},
}

CombatConfig.Rules = {
	DummiesCanDamageDummies = false,
	PlayersCanDamagePlayers = true,
}

-- Números de daño y efectos de impacto (cliente)
CombatConfig.Feedback = {
	Enabled = true,
	Numbers = {
		Duration = 1.3,                          -- segundos totales
		RiseStuds = 3,                           -- cuánto suben
		StartOffset = Vector3.new(0, 2.6, 0),    -- posición inicial sobre la cabeza
		Spread = 1.3,                            -- desplazamiento lateral alternado
		StackWindow = 0.8,                       -- golpes dentro de este tiempo se apilan
		StackRise = 0.7,                         -- altura extra por golpe apilado
		PopScale = 1.35,                         -- escala máxima del efecto de aparición
		PopTime = 0.12,
		SettleTime = 0.1,
		FadeStart = 0.5,                         -- fracción de Duration en que empieza a desvanecerse
		Font = Enum.Font.GothamBlack,
		StrokeColor = Color3.fromRGB(15, 15, 15),
		StrokeThickness = 3,
		Styles = {
			Normal = { Color = Color3.fromRGB(255, 255, 255), Size = 26, Suffix = "" },
			Finisher = { Color = Color3.fromRGB(255, 205, 40), Size = 42, Suffix = "!" },
			GuardBreak = { Color = Color3.fromRGB(255, 120, 40), Size = 34, Suffix = "" },
			Blocked = { Color = Color3.fromRGB(90, 170, 255), Size = 22, Suffix = "" },
			Parried = { Color = Color3.fromRGB(190, 120, 255), Size = 30, Suffix = "" },
			-- [NUEVO]
			Dodged = { Color = Color3.fromRGB(170, 235, 255), Size = 24, Suffix = "" },
			PerfectDodge = { Color = Color3.fromRGB(110, 255, 220), Size = 38, Suffix = "" }, -- [v2] 32 -> 38
		},
	},
	Impact = {
		Normal = { Color = Color3.fromRGB(255, 255, 255), StartSize = 1, EndSize = 3, Time = 0.18, Highlight = false },
		Finisher = { Color = Color3.fromRGB(255, 205, 40), StartSize = 2, EndSize = 9, Time = 0.3, Highlight = true },
		GuardBreak = { Color = Color3.fromRGB(255, 120, 40), StartSize = 2, EndSize = 7, Time = 0.28, Highlight = true },
		-- [v2] Se ven sobre el jugador que esquiva: el Perfect Dodge es claramente más grande y brillante.
		Dodged = { Color = Color3.fromRGB(170, 235, 255), StartSize = 1, EndSize = 4, Time = 0.2, Highlight = false },
		PerfectDodge = { Color = Color3.fromRGB(110, 255, 220), StartSize = 2, EndSize = 10, Time = 0.35, Highlight = true },
	},
}

-- Indicadores de timing sobre dummies (se sincronizan con el tiempo real del servidor).
--   Roles: valores de CombatRole de los dummies que muestran indicador.
--   ParryCueLead: margen (s) antes del impacto en que ya no conviene pulsar F (latencia).
CombatConfig.Telegraph = {
	Enabled = true,
	Roles = { BasicAttacker = true, GuardBreak = true, DodgeTrainer = true },
	Offset = Vector3.new(0, 4.3, 0),
	ParryCueLead = 0.05,
	-- [v2] Igual que ParryCueLead pero para la tecla del dash: margen (s) por latencia. La pulsación tarda en llegar
	-- al servidor, así que las zonas se adelantan este tiempo. Subilo si tu ping es alto.
	DodgeCueLead = 0.05,
	LingerAfterImpact = 0.2,
	Styles = {
		Normal = { Color = Color3.fromRGB(255, 225, 90) },
		GuardBreak = { Color = Color3.fromRGB(255, 110, 40) },
		-- [v2] Dummy de Perfect Dodge
		Dodge = { Color = Color3.fromRGB(120, 200, 255) },
		DodgeZone = { Color = Color3.fromRGB(120, 200, 255) },     -- Dodge normal
		PerfectZone = { Color = Color3.fromRGB(110, 255, 220) },   -- Perfect Dodge
	},
}

-- Lock-on (rueda del mouse = clic central)
-- Con el controlador de cámara nuevo, CameraPitch y CameraSmoothing los LEE la cámara (LockOn ya no la escribe).
CombatConfig.LockOn = {
	Enabled = true,
	AcquireDistance = 45,
	AcquireAngle = 70,        -- semiángulo (grados) respecto a la dirección de la cámara
	BreakDistance = 70,       -- se suelta si el objetivo se aleja más
	TargetPlayers = true,
	TurnSpeed = 14,           -- suavizado del giro del personaje
	CameraSmoothing = 7,      -- suavizado de la cámara
	CameraPitch = -12,        -- grados; negativo mira hacia abajo
	MarkerColor = Color3.fromRGB(255, 255, 255),
	MarkerSize = 26,
	MarkerOffset = Vector3.new(0, 0.5, 0),
}

CombatConfig.Remotes = {
	FolderName = "Remotes",
	Request = "CombatRequest",
	Feedback = "CombatFeedback",
}

-- Dummies
CombatConfig.DummyFolderName = "CombatDummies"

CombatConfig.TrainingDummy = {
	MaxHealth = 1e9,
}

CombatConfig.DummyDefaults = {
	MaxHealth = 1000,
	RegenDelay = 4,
}

CombatConfig.Dummies = {
	InfiniteHealthDummy = { Role = "Training", InfiniteHealth = true },
	BasicAttackerDummy = {
		Role = "BasicAttacker",
		AutoAttack = { Attack = "DummyM1", Interval = 2.5 },
	},
	GuardBreakDummy = {
		Role = "GuardBreak",
		AutoAttack = { Attack = "Heavy", Interval = 4 },
	},
	BlockingDummy = { Role = "Blocking", PermanentBlock = true },
	ParryDummy = { Role = "Parry", PermanentBlock = true, AutoParry = true },
	-- [v2] Hay que crear el modelo "PerfectDodgeDummy" en Workspace.CombatDummies (ver instrucciones).
	PerfectDodgeDummy = {
		Role = "DodgeTrainer",
		AutoAttack = { Attack = "DodgeDummyM1", Interval = 3 },
	},
}

-- [v2] HUD de cooldowns (cliente). Las duraciones salen de DashConfig.Cooldown, Attacks.Heavy.PlayerCooldown y
-- Block.ParryCooldown; los tiempos restantes los publica el servidor en atributos del Player.
CombatConfig.CooldownHUD = {
	Enabled = true,
	SlotSize = 62,
	Spacing = 10,
	BottomOffset = 26,
	DisplayOrder = 40,
	ReadyColor = Color3.fromRGB(110, 255, 170),
	CooldownColor = Color3.fromRGB(255, 120, 90),
	BackgroundColor = Color3.fromRGB(18, 20, 26),
	Slots = {
		{ Id = "Dash", Name = "DASH" },
		{ Id = "Heavy", Name = "GUARD BREAK" },
		{ Id = "Parry", Name = "PARRY" },
	},
}

return CombatConfig