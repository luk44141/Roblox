--[[
	DummyPhysics  (ModuleScript)
	Ubicación: ServerScriptService > CombatSystem > DummyPhysics

	Física de los dummies MÓVILES (CombatConfig.Dummies.<Nombre>.Movable = true, p. ej. ComboDummy).

	Los jugadores reciben empuje / lanzamiento / estampado / agarre en su propio cliente (MovementController, vía el
	remote de feedback). Un dummy no tiene cliente, así que esos mismos efectos se aplican aquí, en el servidor, con
	las mismas reglas: LinearVelocity para empuje y flotar, velocidad directa para el estampado y un AlignPosition
	para el agarre.

	API:
	  DummyPhysics.Setup(model, humanoid, root)   Desancla el rig, deja el dueño de física en el servidor y guarda la posición base.
	  DummyPhysics.Apply(model, payload)          payload = el mismo que recibiría un cliente: Kind = Knockback | Launch |
	                                              LaunchEnd | Slam | Grab | GrabEnd (ver CombatService).

	Para que el dummy no termine lejos tras los empujes, vuelve solo a su posición base cuando pasan RETURN_DELAY
	segundos sin recibir efectos.
]]

local RunService = game:GetService("RunService")

local FORCE_MULTIPLIER = 20000
local RETURN_DELAY = 3 -- s sin efectos antes de volver a la posición base
local RETURN_DISTANCE = 2.5 -- studs de distancia a la base para considerarlo "desplazado"

local DummyPhysics = {}

type DummyData = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	home: CFrame,
	lastEffectAt: number,
	knockback: any,
	hover: any,
	grab: any,
}

local dummies: { [Model]: DummyData } = {}
local loopConnection: RBXScriptConnection? = nil

---------------------------------------------------------------------
-- Limpieza de cada efecto
---------------------------------------------------------------------

local function destroyKnockback(data: DummyData)
	if data.knockback then
		data.knockback.velocity:Destroy()
		data.knockback.attachment:Destroy()
		data.knockback = nil
	end
end

local function destroyHover(data: DummyData)
	if data.hover then
		data.hover.velocity:Destroy()
		data.hover.attachment:Destroy()
		data.hover = nil
	end
end

local function destroyGrab(data: DummyData)
	if data.grab then
		data.grab.align:Destroy()
		data.grab.attachment0:Destroy()
		data.grab = nil
	end
end

---------------------------------------------------------------------
-- Efectos
---------------------------------------------------------------------

local function startKnockback(data: DummyData, direction: Vector3, distance: number, duration: number)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	distance = math.clamp(distance, 0, 40)
	duration = math.clamp(duration, 0.05, 0.8)
	if distance <= 0 then
		return
	end

	destroyKnockback(data)

	local attachment = Instance.new("Attachment")
	attachment.Name = "KnockbackAttachment"
	attachment.Parent = data.root

	local force = data.root.AssemblyMass * FORCE_MULTIPLIER
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "KnockbackVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.MaxAxesForce = Vector3.new(force, 0, force)
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = data.root

	data.knockback = {
		attachment = attachment,
		velocity = velocity,
		direction = flat.Unit,
		startSpeed = 2 * distance / duration,
		startTime = os.clock(),
		duration = duration,
	}
end

local function startHover(data: DummyData, riseSpeed: number, riseTime: number, maxTime: number)
	destroyKnockback(data)
	destroyHover(data)
	data.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

	local attachment = Instance.new("Attachment")
	attachment.Name = "AirHangAttachment"
	attachment.Parent = data.root

	local force = data.root.AssemblyMass * FORCE_MULTIPLIER
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "AirHangVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.MaxAxesForce = Vector3.new(0, force, 0)
	velocity.VectorVelocity = Vector3.new(0, math.clamp(riseSpeed, 0, 120), 0)
	velocity.Parent = data.root

	data.hover = {
		attachment = attachment,
		velocity = velocity,
		riseSpeed = math.clamp(riseSpeed, 0, 120),
		riseTime = math.max(riseTime, 0.05),
		startTime = os.clock(),
		maxTime = math.clamp(maxTime, 1, 15),
	}
end

local function startGrab(data: DummyData, holder: Model, duration: number, offset: Vector3)
	local holderRoot = holder:FindFirstChild("HumanoidRootPart")
	if not holderRoot or not holderRoot:IsA("BasePart") then
		return
	end

	destroyHover(data)
	destroyKnockback(data)
	destroyGrab(data)

	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "GrabAttachment0"
	attachment0.Parent = data.root

	-- OneAttachment: el objetivo es un punto del mundo (se actualiza en step). Con dos attachments la reacción del
	-- AlignPosition empujaba también al que agarra y los dos salían volando.
	local align = Instance.new("AlignPosition")
	align.Name = "GrabAlign"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment0
	align.Position = (holderRoot.CFrame * CFrame.new(offset)).Position
	align.RigidityEnabled = false
	align.ApplyAtCenterOfMass = true
	align.MaxForce = data.root.AssemblyMass * 20000
	align.MaxVelocity = 100
	align.Responsiveness = 60
	align.Parent = data.root

	data.root.AssemblyLinearVelocity = Vector3.zero
	data.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

	data.grab = {
		align = align,
		attachment0 = attachment0,
		holderRoot = holderRoot,
		offset = offset,
		endTime = os.clock() + math.clamp(duration, 0.1, 6) + 1,
	}
end

function DummyPhysics.Apply(model: Model, payload: any)
	local data = dummies[model]
	if not data or not data.root.Parent then
		return
	end
	data.lastEffectAt = os.clock()

	local kind = payload.Kind
	if kind == "Knockback" then
		if typeof(payload.Direction) == "Vector3" then
			startKnockback(data, payload.Direction, payload.Distance, payload.Duration)
		end
	elseif kind == "Launch" then
		startHover(data, payload.VelocityY, payload.RiseTime, payload.MaxTime or 8)
	elseif kind == "LaunchEnd" then
		destroyHover(data)
	elseif kind == "Slam" then
		destroyHover(data)
		destroyKnockback(data)
		data.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		data.root.AssemblyLinearVelocity = Vector3.new(0, -math.clamp(payload.Speed, 0, 200), 0)
	elseif kind == "Grab" then
		if typeof(payload.Holder) == "Instance" and payload.Holder:IsA("Model") then
			startGrab(data, payload.Holder, payload.Duration, payload.Offset)
		end
	elseif kind == "GrabEnd" then
		destroyGrab(data)
	end
end

---------------------------------------------------------------------
-- Actualización (decaimiento de los efectos y regreso a la base)
---------------------------------------------------------------------

local function step()
	local now = os.clock()
	for model, data in dummies do
		if not model.Parent then
			dummies[model] = nil
			continue
		end

		local knock = data.knockback
		if knock then
			local t = (now - knock.startTime) / knock.duration
			if t >= 1 then
				destroyKnockback(data)
			else
				knock.velocity.VectorVelocity = knock.direction * (knock.startSpeed * (1 - t))
			end
		end

		local hover = data.hover
		if hover then
			local t = now - hover.startTime
			if t >= hover.maxTime then
				destroyHover(data)
			else
				local vy = hover.riseSpeed * (1 - math.min(t / hover.riseTime, 1))
				hover.velocity.VectorVelocity = Vector3.new(0, vy, 0)
			end
		end

		local grab = data.grab
		if grab and (now > grab.endTime or not grab.holderRoot.Parent) then
			destroyGrab(data)
		elseif grab then
			grab.align.Position = (grab.holderRoot.CFrame * CFrame.new(grab.offset)).Position
		end

		-- Volver a la posición base cuando pasa un rato sin efectos.
		if not data.knockback and not data.hover and not data.grab and now - data.lastEffectAt > RETURN_DELAY then
			local offset = data.root.Position - data.home.Position
			local fallen = data.root.Position.Y < workspace.FallenPartsDestroyHeight + 50
			if offset.Magnitude > RETURN_DISTANCE or fallen then
				data.model:PivotTo(data.home)
				data.root.AssemblyLinearVelocity = Vector3.zero
				data.root.AssemblyAngularVelocity = Vector3.zero
				data.lastEffectAt = now
			end
		end
	end
end

function DummyPhysics.Setup(model: Model, humanoid: Humanoid, root: BasePart)
	-- Desanclar todo el rig (los Motor6D lo mantienen unido) y dejar la física en el servidor.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end
	root.Anchored = false
	pcall(function()
		root:SetNetworkOwner(nil) -- sin esto, un jugador cercano se haría dueño de la física del dummy
	end)

	-- Que no se caiga / se ragdollee con los golpes: se queda de pie.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.AutoRotate = false

	dummies[model] = {
		model = model,
		humanoid = humanoid,
		root = root,
		home = model:GetPivot(),
		lastEffectAt = os.clock(),
		knockback = nil,
		hover = nil,
		grab = nil,
	}

	if not loopConnection then
		loopConnection = RunService.Heartbeat:Connect(step)
	end
end

return DummyPhysics
