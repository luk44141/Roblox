--[[
	RibbonPhysics (ModuleScript)  -  v3
	UBICACIÓN: ReplicatedStorage > RibbonPhysics

	Cinta con huesos (Bone) para Roblox. Método: cadena "spring bone" (partículas
	en mundo, con restricciones LOCALES por segmento). Es el método típico de
	colas/pelo/cintas en juegos porque es estable y acotado:

	  * Huesos hasta StartBone (por defecto "Bone.005"): NO se simulan; siguen a
	    la espada exactamente y conservan su pose base. Viento, inercia y demás
	    solo actúan a partir del hueso SIGUIENTE a StartBone.
	  * Cada partícula libre es atraída hacia su posición de reposo RELATIVA A SU
	    PADRE (la dirección de reposo del segmento, girada con la espada). Eso da
	    inercia lineal y angular (si la espada gira, las posiciones de reposo
	    giran y la cinta las sigue con retraso).
	  * Cada segmento tiene un límite DURO de desvío angular respecto a su
	    dirección de reposo (Stiffness): la cinta no puede "volverse loca"
	    aunque la espada dé un salto brusco.
	  * Longitud de cada segmento exacta, procesada de padre a hijo en una sola
	    pasada (sin iteraciones ni error residual).
	  * Follow: fracción del movimiento de la espada que cada hueso sigue sin
	    retraso (alto cerca de la empuñadura, bajo en la punta).
	  * Conversión a huesos: arco mínimo que alinea el eje de cadena de cada
	    hueso (hacia su hijo) con el segmento simulado; no hace falta conocer el
	    eje X/Y/Z de Blender y no se acumula torsión.
	  * Colisión (opcional): cajas orientadas + punto medio de cada segmento.
	    Corrección VISUAL de la cadena simulada, no física real.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local RibbonPhysics = {}
RibbonPhysics.__index = RibbonPhysics

--------------------------------------------------------------------------------
-- CONFIGURACIÓN POR DEFECTO
-- Los parámetros con { Near, Tip } van del primer hueso libre (Near) a la punta (Tip).
--------------------------------------------------------------------------------
RibbonPhysics.DefaultConfig = {
	Debug = true,
	DebugDraw = false, -- esferas cian = partículas; cajas rojas = colisionadores
	DebugStats = false, -- imprime cada segundo el desvío máximo respecto al reposo

	Names = {
		Ribbon = "Ribbon",
		RootPart = "RootPart",
		Colliders = { "Shape", "Base" },
	},

	Simulation = {
		FixedStep = 1 / 120,
		MaxSubSteps = 8,
		MaxFrameDelta = 1 / 15,
		TeleportDistance = 30, -- si la espada salta más que esto en un frame, se reinicia
		MaxSpeed = 80, -- velocidad máxima de una partícula (studs/s)
		InputSmoothing = 0.04, -- segundos; filtra el movimiento/giro de la espada que ve la cinta (quita escalones). 0 = off
	},

	Chain = {
		StartBone = "Bone.005", -- este hueso y los anteriores NO se simulan
	},

	Physics = {
		Curve = 1.5, -- 1 = lineal de Near a Tip; >1 = los huesos cercanos se parecen más a Near
		Elasticity = { Near = 100, Tip = 14 }, -- fuerza de recuperación (1/s^2). Alto = más rígida
		Damping = { Near = 12, Tip = 6 }, -- pérdida de energía (1/s). Alto = se asienta antes
		AirDrag = { Near = 0.3, Tip = 1.5 }, -- resistencia del aire (1/s): retraso mientras hay velocidad
		Stiffness = { Near = 0.95, Tip = 0.3 }, -- 0..1: límite angular por segmento. 1 = rígido
		Follow = { Near = 1, Tip = 0.1 }, -- 1 = sigue a la espada sin retraso; 0 = inercia total
		Gravity = Vector3.zero,
	},

	Wind = {
		Enabled = true,
		Strength = 6, -- velocidad del aire (studs/s)
		Speed = 0.5,
		SpatialPhase = 0.06, -- bajo = ondula coherente; alto = irregular
		Space = "World", -- "World" o "Local" (relativo a la espada)
		AxisMask = Vector3.new(1, 0, 1), -- Y = 0 => nunca levanta (en Space "World")
		Steady = Vector3.zero,
	},

	Collision = {
		Enabled = false, -- actívalo cuando la cinta ya se vea bien; revisa las cajas con DebugDraw
		Radius = 0.12,
		IgnoreFirstParticles = 3,
		MidpointSamples = 1,
		Softness = 0.75,
		ContactDamping = 0.5,
		RestMargin = 0.15,
	},

	-- Suelo: raycast hacia abajo desde cada partícula libre (corrección visual)
	Ground = {
		Enabled = true,
		Radius = 0.15, -- semigrosor de la cinta sobre el suelo; sube si el borde de la malla aún se hunde
		Lift = 1.5, -- altura sobre la partícula desde la que se lanza el rayo
		SearchDepth = 40, -- distancia máxima al suelo bajo la espada (si no hay suelo, no se comprueba)
		CheckHeight = 8, -- solo se comprueban partículas a menos de esta altura sobre el suelo
		Friction = 8, -- rozamiento al arrastrarse por el suelo (1/s)
	},

	Bones = {
		MaxBendAngle = 70, -- grados máx. por articulación (respecto al padre)
		ResponseGain = 1, -- NEGATIVO invierte la respuesta; >1 exagera
		SmoothingRate = 30, -- suavizado temporal de la salida (1/s); 0 = off
		SpatialSmoothing = 1, -- pasadas de suavizado a lo largo de la cadena; 0 = off
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

local function boxPush(cf, half, point)
	local l = cf:PointToObjectSpace(point)
	local ax, ay, az = math.abs(l.X), math.abs(l.Y), math.abs(l.Z)
	if ax >= half.X or ay >= half.Y or az >= half.Z then
		return nil
	end
	local px, py, pz = half.X - ax, half.Y - ay, half.Z - az
	local nl
	if px <= py and px <= pz then
		nl = Vector3.new(l.X >= 0 and half.X or -half.X, l.Y, l.Z)
	elseif py <= pz then
		nl = Vector3.new(l.X, l.Y >= 0 and half.Y or -half.Y, l.Z)
	else
		nl = Vector3.new(l.X, l.Y, l.Z >= 0 and half.Z or -half.Z)
	end
	return cf:PointToWorldSpace(nl) - point
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
		self:_warn("El objeto 'zanpakuto' no existe o no es un Model.")
		return false
	end

	local ribbon = sword:FindFirstChild(cfg.Names.Ribbon, true)
	if not ribbon then
		self:_warn("No se encontró '" .. cfg.Names.Ribbon .. "' dentro del modelo (se continúa buscando huesos).")
	elseif not ribbon:IsA("MeshPart") then
		self:_warn("'" .. ribbon:GetFullName() .. "' no es un MeshPart; la malla con huesos debe ser un MeshPart.")
	else
		local okProp, skinned = pcall(function()
			return ribbon.HasSkinnedMesh
		end)
		if okProp and skinned == false then
			self:_warn("El MeshPart Ribbon indica HasSkinnedMesh = false: la malla no tiene skinning, los huesos no la deformarán.")
		end
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
			self:_log("Simulación desde '" .. startName .. "' (hueso " .. self.startIdx .. " de " .. n .. "): los anteriores quedan fijos, los " .. (n - self.startIdx) .. " siguientes son libres.")
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

	local mismatch = 0
	for i = 2, n do
		local worldLen = (chain[i].WorldCFrame.Position - chain[i - 1].WorldCFrame.Position).Magnitude
		if math.abs(worldLen - self.plen[i]) > 0.02 * math.max(self.plen[i], 0.01) then
			mismatch += 1
		end
	end
	if mismatch > 0 then
		self:_warn(mismatch .. " segmentos tienen longitud local distinta a la del mundo: ¿el MeshPart está escalado?")
	end

	-- Parámetros por hueso libre
	local ph = cfg.Physics
	local s0 = self.startIdx
	local free = n - s0
	self.k, self.damp, self.drag, self.stf, self.fol = {}, {}, {}, {}, {}
	for i = s0 + 1, n do
		local u = (free > 1) and ((i - s0 - 1) / (free - 1)) or 0
		local w = u ^ ph.Curve
		self.k[i] = lerpParam(ph.Elasticity, w)
		self.damp[i] = lerpParam(ph.Damping, w)
		self.drag[i] = lerpParam(ph.AirDrag, w)
		self.stf[i] = math.clamp(lerpParam(ph.Stiffness, w), 0, 1)
		self.fol[i] = math.clamp(lerpParam(ph.Follow, w), 0, 1)
	end

	-- Estado
	self.pos, self.prv, self.goal, self.windVel = {}, {}, {}, {}
	self.out = {}
	self:_reset(self.rootBone.WorldCFrame)
	for i = 1, n do
		self.windVel[i] = Vector3.zero
	end

	-- Colisionadores
	self.boxes = {}
	local colCfg = cfg.Collision
	if colCfg.Enabled then
		for _, name in ipairs(cfg.Names.Colliders) do
			local part = sword:FindFirstChild(name, true)
			if part and part:IsA("BasePart") then
				local half = part.Size / 2 + Vector3.one * colCfg.Radius
				local cf = part.CFrame
				table.insert(self.boxes, { name = name, part = part, half = half, cf = cf, prev = cf, cur = cf })
			else
				self:_warn("Colisionador '" .. name .. "' no encontrado o no es BasePart; se ignora.")
			end
		end
		if #self.boxes == 0 then
			self:_warn("No hay colisionadores válidos: la cinta puede atravesar la espada.")
		end
	end

	-- Parámetros del raycast de suelo (excluye la espada y el personaje local; solo piezas con CanCollide)
	if cfg.Ground.Enabled then
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.RespectCanCollide = true
		rp.FilterDescendantsInstances = { sword }
		self.groundParams = rp
	end

	-- Partículas que en reposo ya están dentro/pegadas a una caja: no colisionan con ella
	self.ignore = {}
	local rootCF = self.rootBone.WorldCFrame
	local margin = Vector3.one * colCfg.RestMargin
	for i = 1, n do
		self.ignore[i] = {}
		local g = rootCF:PointToWorldSpace(self.restLocal[i])
		for bi, b in ipairs(self.boxes) do
			if boxPush(b.cf, b.half + margin, g) then
				self.ignore[i][bi] = true
			end
		end
	end

	-- Diagnóstico de movimiento
	self.diag = { parts = {}, reported = {}, rootReported = false, anyMoved = false, anyMovedAt = 0, time = 0, noMoveNoted = false }
	for _, d in ipairs(sword:GetDescendants()) do
		if d:IsA("BasePart") then
			self.diag.parts[d] = d.CFrame
		end
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
		self.goal[i] = g
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
	if not w.Enabled or (w.Strength == 0 and w.Steady == Vector3.zero) then
		for i = 1, self.n do
			W[i] = Vector3.zero
		end
		return
	end
	local t = self.time * w.Speed
	local mask = w.AxisMask
	local useLocal = w.Space == "Local"
	local gust = 1 + math.noise(t * 0.4, 3.3, self.seed) * 1.2
	local amp = w.Strength * 2 * math.max(gust, 0.2)
	for i = self.startIdx + 1, self.n do
		local ph = (i - 1) * w.SpatialPhase
		local nx = math.noise(t + ph, 0.31, self.seed)
		local ny = math.noise(t * 0.8 + ph, 7.7, self.seed)
		local nz = math.noise(t + ph, 15.2, self.seed)
		local v = Vector3.new(nx * mask.X, ny * mask.Y, nz * mask.Z) * amp + w.Steady
		if useLocal then
			v = cur:VectorToWorldSpace(v)
		end
		W[i] = v
	end
end

--------------------------------------------------------------------------------
-- SUBPASO: una sola pasada de padre a hijo
--------------------------------------------------------------------------------
function RibbonPhysics:_step(h, frame, sframe, lastS)
	local cfg = self.cfg
	local ph, col = cfg.Physics, cfg.Collision
	local n, s0 = self.n, self.startIdx
	local P, Q, W = self.pos, self.prv, self.windVel
	local restLocal, restOff, plen = self.restLocal, self.restOff, self.plen
	local k, damp, drag, stf, fol = self.k, self.damp, self.drag, self.stf, self.fol
	local gravity = ph.Gravity
	local maxSpd = cfg.Simulation.MaxSpeed
	local hh = h * h
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

	local boxes = self.boxes
	local collide = col.Enabled and #boxes > 0
	local skipCol = math.max(col.IgnoreFirstParticles, s0)
	local soft, midN = col.Softness, col.MidpointSamples
	local cd = col.ContactDamping
	local ignore = self.ignore

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

		-- Fuerzas: recuperación elástica + resistencia del aire respecto al viento + gravedad
		local accel = (restW - p) * k[i] + (W[i] - disp / h) * drag[i] + gravity

		local mv = move * fol[i]
		local np = p + disp + accel * hh + mv
		Q[i] = p + mv

		-- Límite de desvío respecto a la dirección de reposo del segmento.
		-- La corrección también se aplica a la posición previa: el segmento se desliza
		-- por el límite en lugar de rebotar (sin golpes bruscos).
		local d = restW - np
		local dl = d.Magnitude
		local maxl = plen[i] * (1 - stf[i]) * 2
		if dl > maxl and dl > 1e-6 then
			local corr = d * ((dl - maxl) / dl)
			np = np + corr
			Q[i] = Q[i] + corr
		end

		-- Colisión (opcional)
		local touched = false
		if collide and i > skipCol then
			local ign = ignore[i]
			for bi, b in ipairs(boxes) do
				if not ign[bi] then
					local c = boxPush(b.cur, b.half, np)
					if c then
						np = np + c * soft
						touched = true
					end
					for s = 1, midN do
						local f = s / (midN + 1)
						local pt = par:Lerp(np, f)
						local c2 = boxPush(b.cur, b.half, pt)
						if c2 then
							np = np + (c2 * soft) / f
							touched = true
						end
					end
				end
			end
		end

		-- Longitud exacta del segmento
		local dd = par - np
		local L = dd.Magnitude
		if L > 1e-6 then
			np = np + dd * ((L - plen[i]) / L)
		end

		P[i] = np
		if touched then
			Q[i] = Q[i]:Lerp(np, cd)
		end
	end
end

--------------------------------------------------------------------------------
-- PARTÍCULAS -> Bone.Transform
--------------------------------------------------------------------------------
-- Suelo: empuja las partículas libres por encima de la superficie (corrección visual)
function RibbonPhysics:_groundPass(dt)
	local g = self.cfg.Ground
	local P, Q = self.pos, self.prv
	local s0, n, plen = self.startIdx, self.n, self.plen
	local rp = self.groundParams

	-- El filtro excluye la espada y el personaje local (se actualiza al reaparecer)
	local char = Players.LocalPlayer and Players.LocalPlayer.Character or nil
	if char ~= self.groundChar then
		self.groundChar = char
		local list = { self.sword }
		if char then
			table.insert(list, char)
		end
		rp.FilterDescendantsInstances = list
	end

	-- Comprobación barata: ¿hay suelo bajo la espada? Si no, no se hace nada
	local rr = Workspace:Raycast(P[s0], Vector3.new(0, -g.SearchDepth, 0), rp)
	if not rr then
		return
	end
	local limitY = rr.Position.Y + g.CheckHeight

	local fr = 1 - math.exp(-g.Friction * dt)
	local lift, radius = g.Lift, g.Radius
	for i = s0 + 1, n do
		local p = P[i]
		if p.Y < limitY then
			local res = Workspace:Raycast(p + Vector3.new(0, lift, 0), Vector3.new(0, -(lift + radius + 0.5), 0), rp)
			if res then
				local nrm = res.Normal
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
					-- conserva la velocidad (sin rebote) y añade rozamiento
					Q[i] = (Q[i] + (np - p)):Lerp(np, fr)
					P[i] = np
				end
			end
		end
	end
end

function RibbonPhysics:_apply(frame, dt)
	local bcfg = self.cfg.Bones
	local chain, base, axis = self.chain, self.base, self.axis
	local n, s0 = self.n, self.startIdx
	local maxRad = math.rad(bcfg.MaxBendAngle)
	local gain = bcfg.ResponseGain
	local alpha = 1
	if bcfg.SmoothingRate > 0 then
		alpha = 1 - math.exp(-bcfg.SmoothingRate * dt)
	end

	local Q = self.out
	for i = 1, n do
		local p = self.pos[i]
		if gain == 1 or i <= s0 then
			Q[i] = p
		else
			local g = self.goal[i]
			Q[i] = g + (p - g) * gain
		end
	end

	-- Suavizado espacial (solo partículas libres): evita ángulos ruidosos con segmentos cortos
	for _ = 1, bcfg.SpatialSmoothing do
		local prevQ = Q[s0 + 1]
		for i = s0 + 2, n - 1 do
			local c = Q[i]
			Q[i] = (prevQ + c * 2 + Q[i + 1]) * 0.25
			prevQ = c
		end
	end

	local posedParent = frame * base[1]

	for i = 2, n do
		local bone = chain[i]
		local parentFrame = posedParent * bone.CFrame
		local F0 = parentFrame * base[i]
		local posed = F0

		if i > s0 and i < n then
			local d = Q[i + 1] - Q[i]
			if d.Magnitude > 1e-5 then
				local axisW = F0:VectorToWorldSpace(axis[i])
				local R = arc(axisW, d.Unit, maxRad)
				posed = CFrame.new(F0.Position) * R * F0.Rotation
			end
		end

		local newT = parentFrame:Inverse() * posed
		if alpha < 1 then
			newT = self.lastT[i]:Lerp(newT, alpha)
			posed = parentFrame * newT
		end
		self.lastT[i] = newT
		bone.Transform = newT
		posedParent = posed
	end
end

--------------------------------------------------------------------------------
-- DIAGNÓSTICO
--------------------------------------------------------------------------------
function RibbonPhysics:_diagnose(dt, cur)
	local d = self.diag
	if not d or d.rootReported then
		return
	end
	d.time += dt

	local rootMoved = (cur.Position - self.frame.Position).Magnitude > 1e-3
		or (cur.LookVector - self.frame.LookVector).Magnitude > 1e-3

	for part, last in pairs(d.parts) do
		if part.Parent then
			local cf = part.CFrame
			if (cf.Position - last.Position).Magnitude > 1e-3 or (cf.LookVector - last.LookVector).Magnitude > 1e-3 then
				d.parts[part] = cf
				if not d.reported[part] then
					d.reported[part] = true
					if not d.anyMoved then
						d.anyMoved = true
						d.anyMovedAt = d.time
					end
					self:_log("Se movió la pieza:", part:GetFullName())
				end
			end
		end
	end

	if rootMoved then
		d.rootReported = true
		self:_log("El hueso raíz '" .. self.rootBone.Name .. "' sigue el movimiento: la cinta reaccionará.")
	elseif d.anyMoved and d.time - d.anyMovedAt > 1 and not d.noMoveNoted then
		d.noMoveNoted = true
		self:_warn("Se mueven piezas del modelo pero el hueso raíz NO. Mueve el MODELO COMPLETO o la pieza que contiene los huesos (" .. (self.rootBone.Parent and self.rootBone.Parent:GetFullName() or "?") .. ").")
	end
end

function RibbonPhysics:_checkConflicts()
	for i = 2, self.n do
		local a, b = self.chain[i].Transform, self.lastT[i]
		if (a.Position - b.Position).Magnitude > 1e-3 or (a.LookVector - b.LookVector).Magnitude > 1e-3 then
			if not self.conflictWarned then
				self.conflictWarned = true
				self:_warn("Otro script/animación está modificando Bone.Transform de '" .. self.chain[i].Name .. "'. Desactiva el script antiguo para evitar temblores.")
			end
			return
		end
	end
end

function RibbonPhysics:_debugDraw()
	if not self.cfg.DebugDraw then
		return
	end
	if not self.dbg then
		local folder = Instance.new("Folder")
		folder.Name = "RibbonPhysicsDebug"
		folder.Parent = Workspace
		local parts = {}
		for i = 1, self.n do
			local p = Instance.new("Part")
			p.Shape = Enum.PartType.Ball
			p.Size = Vector3.one * 0.15
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Material = Enum.Material.Neon
			p.Color = (i <= self.startIdx) and Color3.new(1, 0, 0) or Color3.new(0, 1, 1)
			p.Parent = folder
			parts[i] = p
		end
		local boxParts = {}
		for bi, b in ipairs(self.boxes) do
			local bp = Instance.new("Part")
			bp.Name = "Box_" .. b.name
			bp.Anchored = true
			bp.CanCollide = false
			bp.CanQuery = false
			bp.CanTouch = false
			bp.Size = b.half * 2
			bp.Transparency = 0.75
			bp.Color = Color3.new(1, 0.3, 0.3)
			bp.Material = Enum.Material.SmoothPlastic
			bp.Parent = folder
			boxParts[bi] = bp
		end
		self.dbg = { folder = folder, parts = parts, boxes = boxParts }
	end
	for i = 1, self.n do
		self.dbg.parts[i].Position = self.pos[i]
	end
	for bi, bp in ipairs(self.dbg.boxes) do
		bp.CFrame = self.boxes[bi].cf
	end
end

--------------------------------------------------------------------------------
-- BUCLE PRINCIPAL
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

	if (cur.Position - self.frame.Position).Magnitude < 1e-5 then
		self.stalls = (self.stalls or 0) + 1
	end

	if (cur.Position - self.frame.Position).Magnitude > sim.TeleportDistance then
		self:_reset(cur)
		for _, b in ipairs(self.boxes) do
			b.cf = b.part.CFrame
		end
	end

	if self.cfg.Debug then
		self:_diagnose(dt, cur)
	end
	if self.frameCount % 30 == 0 and not self.conflictWarned then
		self:_checkConflicts()
	end

	for _, b in ipairs(self.boxes) do
		b.prev = b.cf
		b.cf = b.part.CFrame
	end

	self:_updateWind(cur)

	local prev = self.frame
	local steps = math.clamp(math.ceil(dt / sim.FixedStep), 1, sim.MaxSubSteps)
	local h = dt / steps
	local tau = sim.InputSmoothing
	local lastS = self.sframe
	for s = 1, steps do
		local a = s / steps
		for _, b in ipairs(self.boxes) do
			b.cur = b.prev:Lerp(b.cf, a)
		end
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

	-- Posición de reposo actual (para estadísticas y ResponseGain)
	local needGoal = self.cfg.DebugStats or self.cfg.Bones.ResponseGain ~= 1
	if needGoal then
		for i = 1, self.n do
			self.goal[i] = cur:PointToWorldSpace(self.restLocal[i])
		end
	end

	if self.cfg.DebugStats and self.frameCount % 60 == 0 then
		local maxDev, maxI = 0, self.startIdx + 1
		for i = self.startIdx + 1, self.n do
			local dev = (self.pos[i] - self.goal[i]).Magnitude
			if dev > maxDev then
				maxDev, maxI = dev, i
			end
		end
		print(string.format("[RibbonPhysics] desvío máx. %.2f studs (partícula %d) | frame %.1f ms | raíz sin moverse en %d de 60 frames", maxDev, maxI, dt * 1000, self.stalls or 0))
		self.stalls = 0
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
	self:_debugDraw()
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
	if self.dbg then
		self.dbg.folder:Destroy()
		self.dbg = nil
	end
end

return RibbonPhysics