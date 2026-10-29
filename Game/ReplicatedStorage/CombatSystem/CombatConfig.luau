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
local ANIMATION_DEFAULTS = {
	M1_1 = "rbxassetid://123838620024691",
	M1_2 = "rbxassetid://71856574775605",
	M1_3 = "",   -- PENDIENTE
	M1_4 = "",   -- PENDIENTE
	-- [v2.3] El combo ahora es de 4 golpes: M1_4 es el golpe final (el que empuja lejos).
	Uppercut = "",  -- PENDIENTE
	AirSlam = "",   -- PENDIENTE (4º básico en el aire: estampa al rival)
	CounterM1 = "", -- PENDIENTE (M1 de contraataque tras bloquear el AirSlam)
	RunAttack = "", -- PENDIENTE (ataque corriendo)
	AirGrab = "",   -- PENDIENTE (agarre en el aire de 2 s)
	DummyM1 = "rbxassetid://123838620024691", -- repite el de M1_1
	Heavy = "",  -- PENDIENTE
	Stun = "",   -- PENDIENTE
}

-- [v2.12] Los IDs de animación viven en el ModuleScript "CombatAnimations" (mismo folder que este módulo). Así, al
-- reemplazar CombatConfig por una versión nueva NO se pisan tus IDs. Un ID vacío en CombatAnimations no pisa el default.
CombatConfig.Animations = ANIMATION_DEFAULTS
do
	local overridesModule = script.Parent:FindFirstChild("CombatAnimations")
	if overridesModule and overridesModule:IsA("ModuleScript") then
		local ok, overrides = pcall(require, overridesModule)
		if ok and typeof(overrides) == "table" then
			for name, id in overrides do
				if typeof(id) == "string" and id ~= "" then
					CombatConfig.Animations[name] = id
				end
			end
		else
			warn("[CombatConfig] CombatAnimations no se pudo cargar: " .. tostring(overrides))
		end
	end
end

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
	-- [v2.3] Golpe final del combo (antes M1_5): empuja LEJOS y aturde un poco (HitReaction).
	M1_4 = {
		Label = "M1", Damage = 18, Windup = 0.28, Active = 0.16, Recovery = 0.35, -- [v2.10] Recovery 0.5 -> 0.35
		Box = { Size = Vector3.new(7, 5.5, 7), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
		Finisher = true,
		HitReaction = { Stun = 0.7, Knockback = 16, KnockbackTime = 0.35, ParryChance = false },
	},
	-- [v2.3] Uppercut: es el 4º golpe si se mantiene Espacio (CombatConfig.Uppercut.Key). Si conecta, atacante y rival
	-- suben juntos; el 4º básico aéreo es AirSlam. Ver CombatConfig.Uppercut.
	Uppercut = {
		-- [v2.8] Recovery 0.12 -> 0.45: el primer golpe aéreo no sale pegado a la subida (más tiempo para acomodarse).
		Label = "UPPERCUT", Damage = 6, Windup = 0.22, Active = 0.12, Recovery = 0.45,
		Box = { Size = Vector3.new(6, 6, 6), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
		Launcher = true,
	},
	-- [v2.4] 4º golpe del combo AÉREO (reemplaza a M1_4 mientras dura el Uppercut). Si conecta, estampa al rival contra el
	-- suelo y lo deja aturdido (pero con dash). Caja alta: los dos están en el aire a alturas parecidas.
	AirSlam = {
		Label = "SLAM", Damage = 18, Windup = 0.28, Active = 0.16, Recovery = 0.45,
		Box = { Size = Vector3.new(8, 12, 8), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
		AirSlam = true,
		Finisher = true,
	},
	-- Contraataque: el M1 que pega el que bloqueó el AirSlam (misma consecuencia: estampa y aturde con dash).
	CounterM1 = {
		Label = "COUNTER", Damage = 12, Windup = 0.1, Active = 0.16, Recovery = 0.3,
		Box = { Size = Vector3.new(8, 12, 8), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Light",
		CounterSlam = true,
		Finisher = true,
	},
	-- [v2.5] R en el aire (durante el combo aéreo): AGARRE. No se bloquea ni se parrea. Conecta con la caja y el rival queda
	-- sujeto GrabDuration segundos delante tuyo; luego lo tirás lejos (CombatConfig.Uppercut). Comparte el cooldown de la R.
	AirGrab = {
		Label = "GRAB", Damage = 15, Windup = 0.15, Active = 0.12, Recovery = 0.25,
		PlayerCooldown = 20, CooldownKey = "Heavy",
		Box = { Size = Vector3.new(8, 12, 8), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = false, CanBeParried = false, BreaksGuard = false,
		MovementProfile = "Grab", -- [v2.8] el atacante no se mueve durante el agarre
		Grab = true,
	},
	-- Ataque corriendo (W + Shift + M1). Perfil de movimiento "Run": no pierde velocidad. Cooldown solo contra spam.
	RunAttack = {
		Label = "RUN", Damage = 12, Windup = 0.1, Active = 0.16, Recovery = 0.3, Cooldown = 1,
		Box = { Size = Vector3.new(6, 5.5, 9), Forward = 1, VerticalOffset = 0 },
		CanBeBlocked = true, CanBeParried = true, BreaksGuard = false,
		MovementProfile = "Run",
		HitReaction = { Stun = 0.5, Knockback = 8, KnockbackTime = 0.25, ParryChance = false },
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
		-- [v2.5] La R dura 1 s en total: Windup 0.55 (el casteo original) + Active 0.15 + Recovery 0.3 (antes 1.45 s).
		-- Sigue sin poder bloquearse (rompe la guardia), pero SÍ se puede parrear (CanBeParried) y esquivar con el dash.
		-- En el aire, durante un combo aéreo, la R es el agarre AirGrab (ver CombatConfig.Uppercut).
		Label = "GUARD BREAK", Damage = 25, Windup = 0.55, Active = 0.15, Recovery = 0.3, Cooldown = 3,
		PlayerCooldown = 20,
		ContinuesCombo = true,
		Box = { Size = Vector3.new(6, 5.5, 7), Forward = 0.5, VerticalOffset = 0 },
		CanBeBlocked = false, CanBeParried = true, BreaksGuard = true,
		MovementProfile = "Heavy",
	},
}

-- Combo M1 (jugadores)
--   Window: tiempo tras terminar la recuperación de un golpe para encadenar el siguiente.
--   BufferTime: un clic hecho durante Active/Recovery se recuerda este tiempo.
--   EndCooldown: pausa tras el golpe final antes de poder iniciar otro combo.
CombatConfig.Combo = {
	Sequence = { "M1_1", "M1_2", "M1_3", "M1_4" }, -- [v2.3] antes 5 golpes
	Window = 0.55,
	BufferTime = 0.35,
	EndCooldown = 0.25, -- [v2.10] antes 0.6: tras el 4º golpe se puede seguir casi enseguida (p. ej. dash + M1)
	-- [v2.10] Dash durante el combo (en la ventana o en la recuperación de un M1): NO lo rompe, y la ventana se extiende
	-- DashWindow segundos para poder seguir con el siguiente M1 después del dash.
	DashWindow = 1.0,
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
		-- [v2.5] Ataque corriendo: penalización MUY pequeña (sprint 24 -> 23 / 21 / 22 studs/s).
		Run = {
			Windup = { MaxSpeed = 23, Forward = 1, Lateral = 1, Backward = 1 },
			Active = { MaxSpeed = 21, Forward = 1, Lateral = 1, Backward = 1 },
			Recovery = { MaxSpeed = 22, Forward = 1, Lateral = 1, Backward = 1 },
			ComboWindow = { MaxSpeed = 22, Forward = 1, Lateral = 1, Backward = 1 },
		},
		-- [v2.8] Agarre: el atacante queda totalmente quieto (el agarrado ya está en Stunned).
		Grab = {
			Windup = { MaxSpeed = 0, Forward = 0, Lateral = 0, Backward = 0 },
			Active = { MaxSpeed = 0, Forward = 0, Lateral = 0, Backward = 0 },
			Recovery = { MaxSpeed = 0, Forward = 0, Lateral = 0, Backward = 0 },
			ComboWindow = { MaxSpeed = 0, Forward = 0, Lateral = 0, Backward = 0 },
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
	-- [v2.7] Combo aéreo (el atacante; servidor: atributo CombatAirCombo): movimiento muy penalizado para que el rival
	-- siempre quede delante tuyo.
	-- [v2.10] MaxSpeed 5 -> 18: se avanza con W detrás del rival (cada M1 lo empuja un poco hacia atrás).
	AirCombo = { MaxSpeed = 18, Forward = 1, Lateral = 1, Backward = 1, AllowJump = true },

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

	-- [v2.10] Bloquear y parrear solo funciona contra ataques que vienen de FRENTE: si el atacante está a más de
	-- FrontHalfAngle grados de hacia donde mira el defensor (es decir, de espaldas), el golpe conecta (y arranca el combo).
	FrontHalfAngle = 100,

	-- [v2.4] Barra de bloqueo: se puede mantener F SIN LÍMITE de tiempo (DrainPerSecond = 0); la barra baja de a poco
	-- SOLO al bloquear golpes: cada golpe bloqueado le quita HitCost ([v2.5] 10 = aguanta 10 golpes).
	-- Al llegar a 0 la guardia se ROMPE: el jugador queda aturdido igual que el atacante al que le hacen parry
	-- (CombatConfig.Stun.OnParried), no se puede volver a bloquear durante DepletedCooldown (2 s) y después la barra vuelve llena. Si no se está bloqueando se recarga (tras RegenDelay). El parry NO usa la barra. Solo jugadores.
	Meter = {
		Max = 100,
		DrainPerSecond = 0, -- >0 haría que también baje con el tiempo
		HitCost = 10, -- por golpe bloqueado (10 golpes la vacían)
		RegenPerSecond = 35,
		RegenDelay = 1.0,
		DepletedCooldown = 2,
	},
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
--   [v2.3] Un ataque puede traer su propia HitReaction = { Stun, Knockback, KnockbackTime, ParryChance } (M1_4, RunAttack):
--   entonces se usa esa en vez de la del combo.
--   Knockback: el objetivo es empujado en la dirección a la que mira el atacante (para el atacante es "hacia adelante";
--   para quien recibe es hacia atrás). Lo aplica el cliente del objetivo (ver MovementController.ApplyKnockback).
CombatConfig.HitReaction = {
	Enabled = true,
	StunSlack = 0.1,
	Knockback = {
		Distance = 2.5,
		Duration = 0.18,
	},
}

-- [v2.4] Uppercut y combo aéreo (solo contra jugadores).
--   1) Se mantiene Key (Espacio) durante un combo de M1. Al llegar al 4º golpe, ese golpe es el UPPERCUT en vez de M1_4.
--   2) Si el Uppercut conecta (no bloqueado / parryado / esquivado), los DOS suben (LaunchSpeed, durante RiseTime) y se
--      quedan FLOTANDO. El rival solo puede bloquear o parrear (no atacar, no dash, no moverse). El atacante lanza un
--      combo NUEVO de 4 golpes: M1_1, M1_2, M1_3 normales y el 4º es el AirSlam.
--   3) AirSlam sin bloqueo ni parry: estampa al rival contra el suelo y lo aturde SlamStun, pero puede hacer dash.
--   4) Si el rival bloqueó los golpes (la barra de bloqueo es la que lo limita), al recibir el AirSlam bloqueado tiene
--      CounterWindow segundos para pegar UN M1 (CounterM1): estampa al atacante igual que el AirSlam (stun con dash).
--   5) Parry en cualquier golpe aéreo: caen los dos y el atacante queda aturdido ParriedStun (el otro empieza combo).
--   AirWindow: duración máxima; AirIdle: si el atacante deja de pegar ese tiempo, caen los dos.
CombatConfig.Uppercut = {
	Enabled = true,
	Key = Enum.KeyCode.Space,
	LaunchSpeed = 70,
	RiseTime = 0.3,
	AirWindow = 6,
	-- [v2.8] El combo aéreo NO obliga a pegar: AirIdle = 0 desactiva la caída por inactividad. En cambio, si el atacante
	-- lleva BreakIdle segundos sin atacar, el rival lanzado puede apretar M1 y caen los dos.
	AirIdle = 0,
	-- [v2.10] En el combo aéreo no se queda uno quieto: el atacante avanza con W (Movement.AirCombo) y cada M1 que conecta
	-- empuja al rival AirPush studs hacia atrás (AirPushTime segundos).
	AirPush = 5,
	AirPushTime = 0.2,
	BreakIdle = 1.6, -- [v2.11] antes 0.9: el atacante necesitaba más tiempo para el primer golpe aéreo
	-- [v2.8] Los M1 del combo aéreo (y el AirSlam) tienen la anticipación multiplicada: menos veloces, más fáciles de leer.
	AirWindupScale = 1.4,
	SlamSpeed = 110,
	-- [v2.5] El 4º golpe aéreo (AirSlam y su contraataque) manda LEJOS al rival, lo estampa y lo aturde SlamStun segundos,
	-- salvo que haga dash (el dash corta el stun).
	-- [v2.10] SlamStun = stun EN EL PISO tras caer (se cuenta desde que aterriza); SlamAirMax = tope mientras vuela.
	-- Aplica al 4º golpe aéreo, al contraataque y al lanzamiento del agarre. El dash corta el stun.
	SlamStun = 1.5,
	SlamAirMax = 3,
	SlamKnockback = 22,
	SlamKnockbackTime = 0.5,
	CounterWindow = 1.0,
	ParriedStun = 1.8,
	-- [v2.5] R en el aire = agarre: el rival queda sujeto GrabDuration s delante tuyo y luego sale despedido GrabThrowDistance.
	GrabDuration = 2,
	GrabOffset = Vector3.new(0, 0, -3.6),
	GrabThrowDistance = 36,
	GrabThrowTime = 0.6,
	GrabThrowStun = 1.0,
}

-- [v2.3] Ataque corriendo: W + sprint + M1. El cliente pide "RunAttack"; el servidor comprueba que de verdad vayas
-- rápido hacia adelante (velocidad horizontal real >= MinSpeed y dirección alineada con hacia donde mirás) y, si no, lo
-- trata como un M1 normal.
-- [v2.5] Se habilita apenas ganás un poco de velocidad con Shift (MinSpeed > WalkSpeed 16). Casi no frena (ver perfil Run);
-- se puede repetir cada Attacks.RunAttack.Cooldown segundos mientras sigas corriendo. ServerMinSpeed es la tolerancia del
-- servidor por la latencia de la velocidad replicada.
CombatConfig.RunAttack = {
	Enabled = true,
	MinSpeed = 16.5,
	ServerMinSpeed = 15.5,
	MinForwardDot = 0.6,
}


-- [v2.9] Finta: durante la anticipación (Windup) de un M1 del combo, el clic derecho cancela el golpe. El rival vio la
-- animación y quizá gastó su parry (que queda en cooldown); tu combo conserva su progreso, así que el siguiente M1 sigue
-- donde ibas. Cooldown contra el abuso.
CombatConfig.Feint = {
	Enabled = true,
	Cooldown = 2.0,
}

-- [v2.3] Salto: cooldown (cliente, igual que el resto del movimiento).
CombatConfig.Jump = {
	Cooldown = 1.5,
	-- [v2.4] Tras cualquier fase de combate (M1, R, ataque corriendo...) no se puede saltar durante este tiempo: así
	-- mantener Espacio para el Uppercut no hace saltar al atacante al empezar / terminar la ventana del combo.
	LockAfterCombat = 0.5,
}

-- [v2.7] Ayuda del combo AÉREO (en el suelo no hay): el servidor avisa al atacante del rival atrapado, y su personaje
-- gira hacia él durante todo el combo y da un paso corto hacia él en cada golpe (hasta MaxStep studs, quedando a
-- StopDistance). Además el movimiento del atacante queda muy penalizado (Movement.AirCombo).
CombatConfig.Assist = {
	Enabled = true,
	StopDistance = 4.6, -- [v2.8] antes 3.4: un poco más de distancia al rival
	MaxStep = 0, -- [v2.10] sin paso automático: el atacante avanza solo con W
	StepTime = 0.15,
	TurnSharpness = 24,
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
	-- [v2.7] Dummy para probar combos: vida infinita, no ataca ni bloquea y es MÓVIL (Movable): no está anclado y el
	-- servidor le aplica el empuje del 4º golpe, el Uppercut con combo aéreo, el estampado y el agarre (DummyPhysics).
	-- Vuelve solo a su lugar 3 s después del último efecto. Crear el modelo "ComboDummy" en Workspace.CombatDummies
	-- (duplicando InfiniteHealthDummy, rig R6).
	ComboDummy = { Role = "Training", InfiniteHealth = true, Movable = true },
	-- [v2.12] BasicAttackerDummy hace el COMBO de 4 M1 (M1_1..M1_4, con tus animaciones y tiempos) y descansa Interval
	-- segundos: sirve para aprender a parrear el combo (con un parry exitoso cortás la cadena). Para volver al golpe
	-- suelto de siempre: AutoAttack = { Attack = "DummyM1", Interval = 2.5 }.
	BasicAttackerDummy = {
		Role = "BasicAttacker",
		AutoAttack = { Combo = { "M1_1", "M1_2", "M1_3", "M1_4" }, Interval = 3 },
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
		{ Id = "Jump", Name = "SALTO" }, -- [v2.3]
	},
	-- [v2.8] Contador de golpes: un círculo por M1 del combo en el borde derecho; el último (el 4º básico / Uppercut /
	-- AirSlam) es más grande. En el combo aéreo usa AirColor. Lo alimenta el servidor (ComboCount / ComboAir /
	-- ComboCountUntil en el Player).
	ComboCounter = {
		CircleSize = 16,
		LastCircleSize = 28,
		Gap = 10,
		EdgeOffset = 22,
		LitColor = Color3.fromRGB(255, 225, 90),
		AirColor = Color3.fromRGB(110, 220, 255),
		UnlitColor = Color3.fromRGB(40, 44, 54),
	},
	-- [v2.3] Barra de bloqueo (se ve cuando no está llena o está en cooldown)
	BlockBar = {
		Width = 230,
		Height = 12,
		Gap = 8,
		FullColor = Color3.fromRGB(110, 200, 255),
		LowColor = Color3.fromRGB(255, 120, 90),
	},
}

return CombatConfig