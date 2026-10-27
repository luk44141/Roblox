--[[
	RibbonPhysics (ModuleScript)  -  v4 (versión limpia)
	UBICACIÓN: ReplicatedStorage > RibbonPhysics

	Cinta con huesos (Bone) para Roblox. Método "spring bone": una cadena de
	partículas en el mundo con restricciones por segmento.

	  * Los huesos hasta StartBone NO se simulan: siguen a la espada exactamente.
	    El viento y el movimiento solo actúan a partir de StartBone.
	  * Cada partícula libre es atraída hacia su posición de reposo (relativa a su
	    padre, girada con la espada). Si mueves la espada (por ejemplo con la D)
	    la cinta se queda atrás y luego la alcanza: inercia lineal y angular.
	  * El viento es ruido suave (Perlin) que empuja solo hacia los lados.
	  * Longitud de cada segmento exacta; límite angular por segmento (Stiffness).
	  * Suelo: la cinta no atraviesa el piso, no rebota y se arrastra un poco.
	  * Los huesos se orientan con el arco mínimo hacia el segmento simulado, así
	    que no hace falta conocer los ejes X/Y/Z de Blender.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local RibbonPhysics = {}
RibbonPhysics.__index = RibbonPhysics

--------------------------------------------------------------------------------
-- CONFIGURACIÓN POR DEFECTO
-- Los parámetros { Near, Tip } van del primer hueso libre (Near) a la punta (Tip).
--------------------------------------------------------------------------------
RibbonPhysics.DefaultConfig = {
	Debug = false, -- true = imprime en Output qué detecta (huesos, suelo...)

	Names = {
		Ribbon = "Ribbon",
		RootPart = "RootPart",
	},

	Simulation = {
		FixedStep = 1 / 120,
		MaxSubSteps = 8,
		MaxFrameDelta = 1 / 15,
		TeleportDistance = 30, -- si la espada salta más que esto en un frame, se reinicia
		MaxSpeed = 45, -- velocidad máxima de una partícula (studs/s)
		InputSmoothing = 0.04, -- segundos; quita escalones del movimiento de la espada. 0 = off
	},

	Chain = {
		StartBone = "Bone.004", -- PRIMER hueso que gira; los anteriores quedan fijos
	},

	Physics = {
		Elasticity = { Near = 80, Tip = 8 }, -- fuerza que devuelve la cinta a su forma. Alto = más rígida
		Damping = { Near = 12, Tip = 6 }, -- pérdida de energía (1/s). Alto = se asienta antes
		AirDrag = { Near = 0.4, Tip = 1.5 }, -- resistencia del aire (1/s): retraso y empuje del viento
		Stiffness = { Near = 0.85, Tip = 0.1 }, -- 0..1: límite angular por segmento. 1 = rígido
		Follow = { Near = 1, Tip = 0.05 }, -- 1 = sigue a la espada sin retraso; 0 = inercia total
		ConstraintDamping = 0.5, -- 0..1: evita latigazos cuando la cadena se tensa de golpe
		MaxRise = 0.5, -- la cinta no puede subir más que esto por encima de StartBone (studs). nil = sin límite
	},

	Wind = {
		Enabled = true,
		Strength = 4.5, -- velocidad del aire (studs/s): más = más movimiento
		Speed = 0.35, -- rapidez de las ráfagas
		SpatialPhase = 0.06, -- bajo = ondula coherente; alto = irregular
		AxisMask = Vector3.new(1, 0, 1), -- Y = 0 => nunca levanta
	},

	-- Suelo: un raycast hacia abajo desde cada partícula libre
	Ground = {
		Enabled = true,
		Radius = 0.2, -- distancia mínima de la cinta al suelo
		Lift = 1.5, -- altura sobre la partícula desde la que sale el rayo
		SearchDepth = 40, -- distancia máxima al suelo bajo la espada
		CheckHeight = 8, -- solo se comprueban partículas a menos de esto sobre el suelo
		Friction = 5, -- rozamiento al arrastrarse (1/s). Alto = se frena enseguida
		StaticSpeed = 0.5, -- por debajo de esta velocidad (studs/s) sobre el suelo se queda quieta
		Ignore = {}, -- objetos que NO cuentan como suelo (el LocalScript añade aquí las espadas)
	},

	Bones = {
		MaxBendAngle = 90, -- grados máx. por articulación
		TipMaxBendAngle = 40, -- ídem en la punta (baja gradualmente)
		SmoothingRate = 18, -- suavizado temporal de la salida (1/s); 0 = off
		TipSmoothingRate = 12, -- ídem en la punta
		TipSmoothCount = 6, -- cuántas partículas finales reciben una pasada extra de suavizado
		SpatialSmoothing = 2, -- pasadas de suavizado a lo largo de la cadena
		MaxAngularSpeed = 400, -- grados/s máx. por hueso (corta tirones); 0 = sin límite
	},
}

--------------------------------------------------------------------------------
-- UTILIDADES
--------------------------------------------------------------------------------
local function isDictionary(t)
	return next(t) ~= nil and #t == 0
end

local function deepMerge(base, override)
	local out = {}
	for k, v in pairs(base) do
		if type(v) == "table" and isDictionary(v) then
			out[k] = deepMerge(v, nil)
		else
			out[k] = v
		end
	end
	if override then
		for k, v in pairs(override) do
			if type(v) == "table" and isDictionary(v) and type(out[k]) == "table" and isDictionary(out[k]) then
				out[k] = deepMerge(out[k], v)
			else
				out[k] = v
			end
		end
	end
	return out
end

local function boneOrder(bone)
	if bone.Name == "Bone" then
		return 0
	end
	local n = bone.Name:match("%.(%d+)$")
	return n and tonumber(n) or math.huge
end

local function sortBones(list)
	table.sort(list, function(a, b)
		local oa, ob = boneOrder(a), boneOrder(b)
		if oa ~= ob then
			return oa < ob
		end
		return a.Name < b.Name
	end)
end

-- Rotación mínima que lleva el vector "from" hacia "to" (limitada a maxAngle)
local function arc(from, to, maxAngle)
	local angle = math.acos(math.clamp(from:Dot(to), -1, 1))
	if angle < 1e-5 then
		return CFrame.identity
	end
	local axis = from:Cross(to)
	if axis.Magnitude < 1e-6 then
		axis = from:Cross(Vector3.yAxis)
		if axis.Magnitude < 1e-6 then
			axis = from:Cross(Vector3.xAxis)
		end
	end
	return CFrame.fromAxisAngle(axis.Unit, math.min(angle, maxAngle))
end

-- Contacto con el suelo sin rebote: se anula la velocidad que entra en el suelo,
-- la que va a lo largo del suelo decae con mu (1/s) y por debajo de "stat" se queda quieta
local function groundVel(np, q, gn, h, mu, stat)
	local v = np - q
	local vn = v:Dot(gn)
	-- sin rebote: toda la velocidad perpendicular al suelo se anula (entrando o saliendo)
	v = v - gn * vn
	vn = 0
	local vt = v - gn * vn
	if mu > 0 then
		vt = vt * math.exp(-mu * h)
	end
	if stat > 0 and vt.Magnitude / h < stat then
		vt = Vector3.zero
	end
	return np - (gn * vn + vt)
end

local function collectBones(container)
	local list = {}
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("Bone") then
			table.insert(list, d)
		end
	end
	return list
end

local function lerpParam(range, w)
	return range.Near + (range.Tip - range.Near) * w
end

--------------------------------------------------------------------------------
-- CONSTRUCCIÓN
--------------------------------------------------------------------------------
function RibbonPhysics.new(sword, userConfig)
	local self = setmetatable({}, RibbonPhysics)
	self.cfg = deepMerge(RibbonPhysics.DefaultConfig, userConfig)
	self.sword = sword
	self.ok = false
	self.destroyed = false
	self.time = 0
	self.frameCount = 0
	self.seed = math.random() * 100 + 0.5

	if self:_setup() then
		self.ok = true
		self:_start()
	end
	return self
end

function RibbonPhysics:_warn(...)
	warn("[RibbonPhysics]", ...)
end

function RibbonPhysics:_log(...)
	if self.cfg.Debug then
		print("[RibbonPhysics]", ...)
	end
end

function RibbonPhysics:_setup()
	local cfg = self.cfg
	local sword = self.sword

	if not sword or not sword:IsA("Model") then
		self:_warn("El objeto de la espada no existe o no es un Model.")
		return false
	end

	local ribbon = sword:FindFirstChild(cfg.Names.Ribbon, true)
	if not ribbon then
		self:_warn("No se encontró '" .. cfg.Names.Ribbon .. "' dentro del modelo (se continúa buscando huesos).")
	elseif not ribbon:IsA("MeshPart") then
		self:_warn("'" .. ribbon:GetFullName() .. "' no es un MeshPart; la malla con huesos debe ser un MeshPart.")
	end

	local rootPart = sword:FindFirstChild(cfg.Names.RootPart, true)
	local container = rootPart or ribbon or sword
	local found = collectBones(container)
	if #found == 0 and container ~= sword then
		found = collectBones(sword)
	end
	if #found < 2 then
		self:_warn("Se necesitan al menos 2 huesos (Bone); encontrados:", #found)
		return false
	end
	self:_log("Huesos encontrados:", #found, "dentro de", found[1]:GetFullName())

	-- Cadena de huesos: raíz -> primer hijo -> ...
	local roots = {}
	for _, b in ipairs(found) do
		if not (b.Parent and b.Parent:IsA("Bone")) then
			table.insert(roots, b)
		end
	end
	sortBones(roots)
	if #roots ~= 1 then
		self:_warn("Se esperaba 1 hueso raíz y hay " .. #roots .. ". Se usa:", roots[1].Name)
	end

	local chain, inChain = {}, {}
	local cur = roots[1]
	while cur do
		table.insert(chain, cur)
		inChain[cur] = true
		local kids = {}
		for _, c in ipairs(cur:GetChildren()) do
			if c:IsA("Bone") then
				table.insert(kids, c)
			end
		end
		sortBones(kids)
		if #kids > 1 then
			self:_warn("El hueso '" .. cur.Name .. "' tiene " .. #kids .. " hijos; solo se simula la rama '" .. kids[1].Name .. "'.")
		end
		cur = kids[1]
	end

	local missing = {}
	for _, b in ipairs(found) do
		if not inChain[b] then
			table.insert(missing, b.Name)
		end
	end
	if #missing > 0 then
		self:_warn("Huesos NO incluidos en la cadena (no se animarán):", table.concat(missing, ", "))
	end

	local n = #chain
	if n < 3 then
		self:_warn("La cadena tiene menos de 3 huesos.")
		return false
	end
	self.chain = chain
	self.n = n
	self.rootBone = chain[1]

	-- Hueso donde empieza la simulación
	self.startIdx = 1
	local startName = cfg.Chain.StartBone
	if startName and startName ~= "" then
		local hit = false
		for i, b in ipairs(chain) do
			if b.Name == startName then
				self.startIdx = i
				hit = true
				break
			end
		end
		if not hit then
			self:_warn("StartBone '" .. startName .. "' no está en la cadena; se simula desde el principio. Nombres: " .. chain[1].Name .. " ... " .. chain[n].Name)
		elseif self.startIdx >= n - 1 then
			self:_warn("StartBone '" .. startName .. "' está demasiado cerca de la punta; se ignora.")
			self.startIdx = 1
		else
			self:_log("'" .. startName .. "' (hueso " .. self.startIdx .. " de " .. n .. ") es el PRIMER hueso que gira; los anteriores quedan fijos y los " .. (n - self.startIdx) .. " siguientes son libres.")
		end
	end

	-- Poses base (se conservan; nunca se acumulan)
	self.base, self.lastT = {}, {}
	for i, b in ipairs(chain) do
		self.base[i] = b.Transform
		self.lastT[i] = b.Transform
	end

	-- Geometría de reposo en el espacio del hueso raíz
	self.restLocal, self.restOff, self.plen, self.axis = {}, {}, {}, {}
	local restCF = {}
	restCF[1] = self.base[1]
	self.restLocal[1] = restCF[1].Position
	for i = 2, n do
		restCF[i] = restCF[i - 1] * chain[i].CFrame * self.base[i]
		self.restLocal[i] = restCF[i].Position
		local off = self.restLocal[i] - self.restLocal[i - 1]
		if off.Magnitude < 1e-4 then
			self:_warn("Segmento degenerado (longitud ~0) entre '" .. chain[i - 1].Name .. "' y '" .. chain[i].Name .. "'.")
			off = Vector3.new(0, -1e-4, 0)
		end
		self.restOff[i] = off
		self.plen[i] = off.Magnitude
	end
	for i = 1, n - 1 do
		local o = chain[i + 1].CFrame.Position
		self.axis[i] = o.Magnitude > 1e-6 and o.Unit or Vector3.yAxis
	end

	-- Parámetros por hueso libre
	local ph = cfg.Physics
	local s0 = self.startIdx
	local free = n - s0
	self.k, self.damp, self.drag, self.stf, self.fol = {}, {}, {}, {}, {}
	for i = s0 + 1, n do
		local u = (free > 1) and ((i - s0 - 1) / (free - 1)) or 0
		local w = u
		self.k[i] = lerpParam(ph.Elasticity, w)
		self.damp[i] = lerpParam(ph.Damping, w)
		self.drag[i] = lerpParam(ph.AirDrag, w)
		self.stf[i] = math.clamp(lerpParam(ph.Stiffness, w), 0, 1)
		self.fol[i] = math.clamp(lerpParam(ph.Follow, w), 0, 1)
	end

	local freeLen = 0
	for i = s0 + 1, n do
		freeLen += self.plen[i]
	end
	self:_log(string.format("Cinta libre: %d huesos, %.2f studs de largo, segmento medio %.3f studs", free, freeLen, freeLen / math.max(free, 1)))

	-- Estado
	self.pos, self.prv, self.windVel = {}, {}, {}
	self.out = {}
	self.gPos, self.gNrm = {}, {} -- plano de suelo bajo cada partícula (del último frame)
	for i = 1, n do
		self.windVel[i] = Vector3.zero
	end
	self:_reset(self.rootBone.WorldCFrame)

	-- Raycast de suelo (excluye la espada y el personaje local)
	if cfg.Ground.Enabled then
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.RespectCanCollide = true
		rp.FilterDescendantsInstances = { sword }
		self.groundParams = rp
	end

	return true
end

function RibbonPhysics:_start()
	local signal = RunService:IsClient() and RunService.PreRender or RunService.Heartbeat
	self.conn = signal:Connect(function(dt)
		self:_update(dt)
	end)
	self:_log("Simulación iniciada con", self.n, "huesos. Mueve la espada para ver la reacción.")
end

function RibbonPhysics:_reset(frame)
	for i = 1, self.n do
		local g = frame:PointToWorldSpace(self.restLocal[i])
		self.pos[i] = g
		self.prv[i] = g
	end
	self.frame = frame
	self.sframe = frame
	self.lastH = nil
end

function RibbonPhysics:Reset()
	if self.ok and self.rootBone then
		self:_reset(self.rootBone.WorldCFrame)
	end
end

--------------------------------------------------------------------------------
-- VIENTO (solo afecta a las partículas libres)
--------------------------------------------------------------------------------
function RibbonPhysics:_updateWind(cur)
	local w = self.cfg.Wind
	local W = self.windVel
	if not w.Enabled or w.Strength == 0 then
		for i = 1, self.n do
			W[i] = Vector3.zero
		end
		return
	end
	local t = self.time * w.Speed
	local mask = w.AxisMask
	local gust = 1 + math.noise(t * 0.4, 3.3, self.seed) * 1.2
	local amp = w.Strength * 2 * math.max(gust, 0.2)
	for i = self.startIdx + 1, self.n do
		local ph = (i - 1) * w.SpatialPhase
		local nx = math.noise(t + ph, 0.31, self.seed)
		local ny = math.noise(t * 0.8 + ph, 7.7, self.seed)
		local nz = math.noise(t + ph, 15.2, self.seed)
		local v = Vector3.new(nx * mask.X, ny * mask.Y, nz * mask.Z) * amp
		W[i] = v
	end
end

--------------------------------------------------------------------------------
-- SUBPASO: una sola pasada de padre a hijo
--------------------------------------------------------------------------------
function RibbonPhysics:_step(h, frame, sframe, lastS)
	local cfg = self.cfg
	local n, s0 = self.n, self.startIdx
	local P, Q, W = self.pos, self.prv, self.windVel
	local restLocal, restOff, plen = self.restLocal, self.restOff, self.plen
	local k, damp, drag, stf, fol = self.k, self.damp, self.drag, self.stf, self.fol
	local maxSpd = cfg.Simulation.MaxSpeed
	local cdamp = math.clamp(cfg.Physics.ConstraintDamping, 0, 1)
	local hh = h * h
	local maxRise = cfg.Physics.MaxRise
	-- La cinta libre "ve" la espada filtrada (sframe): sin escalones ni saltos. Los huesos fijos usan la exacta.
	local move = sframe.Position - lastS.Position

	-- Corrige el desplazamiento de Verlet si el paso de tiempo cambió respecto al anterior
	local tscale = 1
	if self.lastH then
		tscale = math.clamp(h / self.lastH, 0.5, 2)
	end
	self.lastH = h

	-- Huesos fijos: siguen a la espada exactamente
	for i = 1, s0 do
		local g = frame:PointToWorldSpace(restLocal[i])
		P[i] = g
		Q[i] = g
	end

	local gcfg = cfg.Ground
	local gOn = gcfg.Enabled and self.groundParams ~= nil
	local gr, gfric, gstat = gcfg.Radius, gcfg.Friction, gcfg.StaticSpeed
	local gPos, gNrm = self.gPos, self.gNrm

	for i = s0 + 1, n do
		local par = P[i - 1] -- el padre ya está en su posición final de este subpaso
		local p, q = P[i], Q[i]

		-- Inercia (Verlet) con amortiguación
		local disp = (p - q) * (tscale * math.exp(-damp[i] * h))
		local sp = disp.Magnitude / h
		if sp > maxSpd then
			disp = disp * (maxSpd / sp)
		end

		-- Posición de reposo: relativa al padre simulado, girada con la espada
		local restW = par + sframe:VectorToWorldSpace(restOff[i])
		-- La posición de reposo nunca queda bajo el suelo: así el muelle no empuja contra él (evita el rebote)
		local gp0 = gOn and gPos[i] or nil
		if gp0 then
			local sd0 = (restW - gp0):Dot(gNrm[i])
			if sd0 < gr then
				restW = restW + gNrm[i] * (gr - sd0)
			end
		end

		-- Fuerzas: recuperación elástica + resistencia del aire respecto al viento
		local accel = (restW - p) * k[i] + (W[i] - disp / h) * drag[i]

		local mv = move * fol[i]
		local np = p + disp + accel * hh + mv
		Q[i] = p + mv

		-- Límite de desvío respecto a la dirección de reposo del segmento.
		-- La corrección también se aplica a la posición previa: el segmento se desliza
		-- por el límite en lugar de rebotar.
		local d = restW - np
		local dl = d.Magnitude
		local maxl = plen[i] * (1 - stf[i]) * 2
		if dl > maxl and dl > 1e-6 then
			local corr = d * ((dl - maxl) / dl)
			np = np + corr
			Q[i] = Q[i] + corr
		end

		-- Longitud exacta del segmento. Una parte de la corrección no se convierte en velocidad
		-- (evita latigazos cuando la cadena se tensa de golpe).
		local dd = par - np
		local L = dd.Magnitude
		if L > 1e-6 then
			local lc = dd * ((L - plen[i]) / L)
			np = np + lc
			Q[i] = Q[i] + lc * cdamp
		end

		-- Techo: la cinta cuelga, no sube por encima de su hueso de inicio (evita que "vuele" al caminar)
		if maxRise then
			local over = np.Y - (P[s0].Y + maxRise)
			if over > 0 then
				np = np - Vector3.yAxis * over
				Q[i] = Q[i] - Vector3.yAxis * math.max(over, 0)
			end
		end

		-- Suelo (plano del frame anterior): se empuja por encima, sin rebote y con rozamiento
		local gp = gOn and gPos[i] or nil
		if gp then
			local gn = gNrm[i]
			local sd = (np - gp):Dot(gn)
			if sd < gr then
				local push = gn * (gr - sd)
				np = np + push
				Q[i] = groundVel(np, Q[i] + push, gn, h, gfric, gstat)
			end
		end

		P[i] = np
	end
end

--------------------------------------------------------------------------------
-- SUELO: busca la superficie bajo cada partícula y corrige las que quedaron por debajo
--------------------------------------------------------------------------------
function RibbonPhysics:_groundPass(dt)
	local g = self.cfg.Ground
	local P, Q = self.pos, self.prv
	local s0, n, plen = self.startIdx, self.n, self.plen
	local rp = self.groundParams

	-- El filtro excluye la espada, el personaje local y las demás espadas
	local char = Players.LocalPlayer and Players.LocalPlayer.Character or nil
	local extra = g.Ignore
	local extraN = extra and #extra or 0
	if char ~= self.groundChar or extraN ~= self.groundIgnoreN then
		self.groundChar = char
		self.groundIgnoreN = extraN
		local list = { self.sword }
		if char then
			table.insert(list, char)
		end
		for i = 1, extraN do
			if extra[i] and extra[i].Parent then
				table.insert(list, extra[i])
			end
		end
		rp.FilterDescendantsInstances = list
	end

	-- Comprobación barata: ¿hay suelo bajo la espada? Si no, no se hace nada
	local rr = Workspace:Raycast(P[s0], Vector3.new(0, -g.SearchDepth, 0), rp)
	if self.cfg.Debug then
		if rr and not self.groundLogged then
			self.groundLogged = true
			self:_log("Suelo detectado: " .. rr.Instance:GetFullName() .. " (CanCollide=" .. tostring(rr.Instance.CanCollide) .. ")")
		elseif not rr and self.frameCount % 120 == 0 then
			self:_warn("No se detecta suelo bajo la espada (rayo de " .. g.SearchDepth .. " studs). Revisa CanCollide/CanQuery de la baseplate.")
		end
	end
	if not rr then
		for i = 1, n do
			self.gPos[i] = nil
		end
		return
	end
	local limitY = rr.Position.Y + g.CheckHeight

	local lift, radius = g.Lift, g.Radius
	for i = s0 + 1, n do
		local p = P[i]
		self.gPos[i] = nil
		if p.Y < limitY then
			-- El rayo sale desde encima de la mano (o de la partícula, si está más alta): así detecta
			-- el suelo aunque la partícula ya esté hundida por debajo de él
			local top = math.max(p.Y, P[s0].Y) + lift
			local res = Workspace:Raycast(Vector3.new(p.X, top, p.Z), Vector3.new(0, -(top - p.Y + radius + 2), 0), rp)
			if res then
				local nrm = res.Normal
				self.gPos[i] = res.Position -- se guarda el plano para el siguiente frame
				self.gNrm[i] = nrm
				local sd = (p - res.Position):Dot(nrm)
				if sd < radius then
					local np = p + nrm * (radius - sd)
					-- mantiene la longitud del segmento respecto al padre
					local dd = P[i - 1] - np
					local L = dd.Magnitude
					if L > 1e-6 then
						np = np + dd * ((L - plen[i]) / L)
					end
					local sd2 = (np - res.Position):Dot(nrm)
					if sd2 < radius then
						np = np + nrm * (radius - sd2)
					end
					Q[i] = groundVel(np, Q[i] + (np - p), nrm, dt, 0, 0)
					P[i] = np
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- PARTÍCULAS -> Bone.Transform
--------------------------------------------------------------------------------
function RibbonPhysics:_apply(frame, dt)
	local bcfg = self.cfg.Bones
	local chain, base, axis = self.chain, self.base, self.axis
	local n, s0 = self.n, self.startIdx
	local gcfg = self.cfg.Ground
	local gOn = gcfg.Enabled and self.groundParams ~= nil
	local gr = gcfg.Radius
	local gPos, gNrm = self.gPos, self.gNrm
	local maxRad = math.rad(bcfg.MaxBendAngle)
	local tipMaxRad = math.rad(bcfg.TipMaxBendAngle or bcfg.MaxBendAngle)
	local rate0 = bcfg.SmoothingRate
	local rate1 = bcfg.TipSmoothingRate or rate0

	local Q = self.out
	for i = 1, n do
		Q[i] = self.pos[i]
	end

	-- Suavizado espacial (solo partículas libres): evita ángulos ruidosos con segmentos cortos
	for _ = 1, bcfg.SpatialSmoothing do
		local prevQ = Q[s0 + 1]
		for i = s0 + 2, n - 1 do
			local c = Q[i]
			Q[i] = (prevQ + c * 2 + Q[i + 1]) * 0.25
			prevQ = c
		end
		-- La última partícula se mezcla con la prolongación del segmento anterior
		if n - 2 >= s0 then
			Q[n] = Q[n] * 0.7 + (Q[n - 1] * 2 - Q[n - 2]) * 0.3
		end
	end

	-- Pasada extra de suavizado solo en las últimas partículas
	local tc = bcfg.TipSmoothCount or 0
	if tc > 0 then
		local from = math.max(s0 + 2, n - tc)
		local prevQ = Q[from - 1]
		for i = from, n - 1 do
			local c = Q[i]
			Q[i] = (prevQ + c * 2 + Q[i + 1]) * 0.25
			prevQ = c
		end
	end

	local posedParent = frame * base[1]

	for i = 2, n do
		local bone = chain[i]
		local tu = math.clamp((i - s0) / math.max(n - s0, 1), 0, 1)
		local mrad = maxRad + (tipMaxRad - maxRad) * tu
		local rate = rate0 + (rate1 - rate0) * tu
		local alpha = 1
		if rate > 0 then
			alpha = 1 - math.exp(-rate * dt)
		end
		local parentFrame = posedParent * bone.CFrame
		local F0 = parentFrame * base[i]
		local posed = F0

		-- i >= s0: el hueso StartBone ya gira (apunta hacia la primera partícula libre)
		if i >= s0 and i < n then
			local d = Q[i + 1] - Q[i]
			if d.Magnitude > 1e-5 then
				local axisW = F0:VectorToWorldSpace(axis[i])
				posed = CFrame.new(F0.Position) * arc(axisW, d.Unit, mrad) * F0.Rotation
			end
		end

		local newT = parentFrame:Inverse() * posed

		-- Límite de velocidad angular: ningún hueso puede girar de golpe entre dos frames
		local maxAS = bcfg.MaxAngularSpeed
		if maxAS and maxAS > 0 and i > s0 then
			local _, ang = self.lastT[i]:ToObjectSpace(newT):ToAxisAngle()
			local lim = math.rad(maxAS) * dt
			if ang > lim and ang > 1e-6 then
				newT = self.lastT[i]:Lerp(newT, lim / ang)
				posed = parentFrame * newT
			end
		end

		if alpha < 1 then
			newT = self.lastT[i]:Lerp(newT, alpha)
			posed = parentFrame * newT
		end

		-- Suelo, comprobación final sobre la pose real: si el hueso hijo quedaría bajo la
		-- superficie, este hueso gira lo necesario para levantarlo
		if gOn and i >= s0 and i < n then
			local gp = gPos[i + 1]
			if gp then
				local gn = gNrm[i + 1]
				local childRel = chain[i + 1].CFrame * base[i + 1]
				local fixed = false
				for _ = 1, 4 do
					local cpos = (posed * childRel).Position
					local sd = (cpos - gp):Dot(gn)
					local need = gr * 0.85
					if sd >= need then
						break
					end
					local from = cpos - posed.Position
					local to = from + gn * (need - sd)
					if from.Magnitude < 1e-5 or to.Magnitude < 1e-5 then
						break
					end
					posed = CFrame.new(posed.Position) * arc(from.Unit, to.Unit, math.pi) * posed.Rotation
					fixed = true
				end
				if fixed then
					newT = parentFrame:Inverse() * posed
				end
			end
		end

		self.lastT[i] = newT
		bone.Transform = newT
		posedParent = posed
	end
end

--------------------------------------------------------------------------------
-- ACTUALIZACIÓN POR FRAME
--------------------------------------------------------------------------------
function RibbonPhysics:_update(frameDt)
	if self.destroyed then
		return
	end
	if not self.rootBone.Parent or not self.sword.Parent then
		self:Destroy()
		return
	end

	local sim = self.cfg.Simulation
	local dt = math.clamp(frameDt, 1 / 240, sim.MaxFrameDelta)
	local cur = self.rootBone.WorldCFrame
	self.time += dt
	self.frameCount += 1

	if (cur.Position - self.frame.Position).Magnitude > sim.TeleportDistance then
		self:_reset(cur)
	end

	self:_updateWind(cur)

	local prev = self.frame
	local steps = math.clamp(math.ceil(dt / sim.FixedStep), 1, sim.MaxSubSteps)
	local h = dt / steps
	local tau = sim.InputSmoothing
	local lastS = self.sframe
	for s = 1, steps do
		local a = s / steps
		local real = prev:Lerp(cur, a)
		local sf = real
		if tau > 0 then
			sf = lastS:Lerp(real, 1 - math.exp(-h / tau))
		end
		self:_step(h, real, sf, lastS)
		lastS = sf
	end
	self.sframe = lastS

	if self.groundParams then
		self:_groundPass(dt)
	end

	for i = 1, self.n do
		local p = self.pos[i]
		if p ~= p then
			self:_warn("Valor NaN detectado; reiniciando simulación.")
			self:_reset(cur)
			break
		end
	end

	self.frame = cur
	self:_apply(cur, dt)
end

function RibbonPhysics:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	if self.chain then
		for i, bone in ipairs(self.chain) do
			if bone.Parent then
				bone.Transform = self.base[i]
			end
		end
	end
end

return RibbonPhysics