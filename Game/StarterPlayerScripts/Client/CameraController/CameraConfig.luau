--[[
	CameraConfig  (ModuleScript)
	Ubicación: StarterPlayer > StarterPlayerScripts > Client > CameraController > CameraConfig
	REEMPLAZA tu CameraConfig actual.

	Todos los parámetros ajustables del sistema de cámara.
	Ángulos en GRADOS, distancias en studs.
	"Sharpness" = qué tan rápido converge un valor (más alto = más rápido/seco).

	Cambios respecto a tu versión:
	  - Se eliminó la rotación con botón derecho (el mouse rota solo con el cursor bloqueado).
	  - Efectos con "Enabled" individual; bobbing y strafe más sutiles (precisión de combate).
	  - FollowSharpnessXZ 18 -> 22 (menos retraso del personaje en pantalla al correr).
	  - Nuevos: SprintFov, DashFov, DashPullback, ShiftLock.EffectScale.
	  - ShiftLock.CharacterTurnSharpness se movió a MovementConfig.Orientation (lo usa CharacterOrientation).

	Cambios de esta actualización [v2]:
	  - NormalFraming: la cámara normal usa un encuadre parecido al del Shift Lock (hombro + algo más de altura).
	  - DefaultPitch 20 -> 24 (vista algo más elevada).
	  - ShiftLock.SwapInNormalMode: la tecla de cambio de hombro también funciona en cámara normal.
	  - ShiftLock.Dot.ShowInNormalMode / HideDuringLockOn ahora SÍ se leen (antes la config existía pero ShiftLock no la usaba).
]]

local CameraConfig = {
	-- Cámara normal
	FieldOfView = 70,

	-- Zoom
	DefaultDistance = 16,
	MinZoom = 6,
	MaxZoom = 40,
	ZoomStep = 3, -- Studs por "click" de rueda
	ZoomSharpness = 12,

	-- Encuadre
	FocusHeight = 2, -- Altura del punto que mira la cámara, sobre el HumanoidRootPart
	DefaultPitch = 24, -- Cámara elevada respecto al personaje [v2: antes 20]
	MinPitch = -25, -- Negativo = cámara por debajo del foco, mirando hacia arriba
	MaxPitch = 80,

	-- Rotación con el mouse (solo con el cursor bloqueado, en ambos modos).
	-- Radianes por píxel (X, Y). GetMouseDelta() ya incluye la sensibilidad del jugador.
	Sensitivity = Vector2.new(0.002 * math.pi, 0.0015 * math.pi),
	InvertY = false,

	-- Seguimiento del personaje
	FollowSharpnessXZ = 22,
	FollowSharpnessY = 8,
	TeleportSnapDistance = 30,

	-- Seguimiento vertical adaptativo (igual que antes)
	VerticalFollow = {
		StartSpeed = 50,
		Gain = 0.35,
		MaxSharpness = 45,
		Attack = 20,
		Release = 5,
		MaxLag = 6,
	},

	-- Balanceo al caminar
	Bob = {
		Enabled = true,
		VerticalAmplitude = 0.04,
		HorizontalAmplitude = 0.02,
		Frequency = 7.5,
		Sharpness = 8,
	},

	-- Desplazamiento horizontal al moverse hacia los lados (sin rotación)
	Strafe = {
		Enabled = true,
		MaxOffset = 0.5, -- Antes 1.5: más centrado para combatir
		Sharpness = 6,
	},

	-- Impacto al aterrizar (resorte vertical)
	Landing = {
		Enabled = true,
		MinFallSpeed = 20,
		MaxFallSpeed = 120,
		Strength = 0.05,
		Stiffness = 170,
		Damping = 22,
		MaxOffset = 0.5,
	},

	-- FOV extra al correr (solo con movimiento real)
	SprintFov = {
		Enabled = true,
		Amount = 4, -- Grados extra
		Sharpness = 6,
	},

	-- FOV extra durante el dash
	DashFov = {
		Enabled = true,
		Amount = 6,
		Attack = 22, -- Qué tan rápido sube
		Release = 7, -- Qué tan rápido vuelve
	},

	-- La cámara se aleja un poco durante el dash
	DashPullback = {
		Enabled = true,
		Distance = 1.0, -- Studs
	},

	-- [v2] Encuadre de la cámara NORMAL (mismos ejes que el ShiftLock: hombro / elevación / distancia).
	--   [v2.1] SIN hombro: ShoulderOffset = 0, el personaje queda centrado horizontalmente. El hombro y su cambio
	--   (X) son solo del ShiftLock. VerticalOffset sube el punto que apunta la cámara: el personaje queda más abajo
	--   en pantalla y la mira (centro de la pantalla) queda JUSTO ENCIMA de él, distinto del ShiftLock (mira al costado).
	--   Al activar el ShiftLock se mezcla con ShiftLock.* y con lock-on activo se anula (el lock-on encuadra solo).
	NormalFraming = {
		Enabled = true,
		ShoulderOffset = 0,
		VerticalOffset = 1.8,
		DistanceScale = 0.85, -- Multiplica el zoom actual (el zoom con la rueda sigue funcionando)
		LockOnSharpness = 6, -- Velocidad con la que el encuadre se centra al fijar un objetivo (y vuelve al soltarlo)
	},

	-- Colisión con paredes
	Collision = {
		Radius = 0.4,
		Padding = 0.2,
		MinDistance = 0.8,
		RecoverSharpness = 6,
		IgnoreTransparency = 0.95,
	},

	-- Shift Lock
	ShiftLock = {
		ToggleKey = Enum.KeyCode.LeftAlt,
		SwapShoulderKey = Enum.KeyCode.X,
		SwapInNormalMode = false, -- [v2.1] false: X solo cambia el hombro con el ShiftLock activo
		StartShoulder = "Right", -- "Right" o "Left"

		ShoulderOffset = 2.2,
		VerticalOffset = 0.4,
		DistanceScale = 0.7,
		FieldOfView = 66,
		FollowSharpnessXZ = 32,
		EffectScale = 0.5, -- Multiplica bobbing y aterrizaje en ShiftLock (más precisión al apuntar)

		TransitionTime = 0.3,
		ShoulderSwapSharpness = 12,
		AltTabGuardTime = 0.35, -- Si la ventana pierde el foco hasta este tiempo después del toggle, se evalúa revertirlo
		AltTabConfirmTime = 0.6, -- [v2.3] ...pero solo si tras este tiempo sigue sin foco ni entrada (Alt+Tab real; no el falso de Alt)

		Dot = {
			ShowInNormalMode = true, -- true: la mira también se ve en cámara normal (cursor bloqueado). false: solo en ShiftLock
			HideDuringLockOn = true, -- Con lock-on activo se oculta (ya hay un marcador sobre el objetivo)
			FadeSharpness = 14, -- Velocidad de aparición/desaparición
			Size = 6,
			Color = Color3.fromRGB(255, 255, 255),
			OutlineColor = Color3.fromRGB(0, 0, 0),
			OutlineThickness = 1.5,
		},
	},
}

return CameraConfig