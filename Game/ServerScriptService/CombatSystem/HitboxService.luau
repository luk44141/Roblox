-- HitboxService
-- Ubicación: ServerScriptService > CombatSystem
-- Hurtboxes visibles, cajas de ataque y consultas espaciales.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("CombatConfig"))

local HURTBOX_NAME = "Hurtbox"
local HURTBOX_TAG = CombatConfig.Tags.Hurtbox
local DEFAULT_ATTACK_FORWARD = 0.5

export type AttackBoxSpec = {
	Size: Vector3,
	Forward: number?,
	VerticalOffset: number?,
}

local HitboxService = {}

local debugFolder: Folder? = nil

local function getDebugFolder(): Folder
	if debugFolder and debugFolder.Parent then
		return debugFolder
	end
	local existing = workspace:FindFirstChild(CombatConfig.Debug.FolderName)
	if existing and existing:IsA("Folder") then
		debugFolder = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = CombatConfig.Debug.FolderName
		folder.Parent = workspace
		debugFolder = folder
	end
	return debugFolder :: Folder
end

local function applyDebugPartSettings(part: BasePart, color: Color3, transparency: number)
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = if CombatConfig.Debug.Enabled then transparency else 1
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Locked = true
end

local function getOwnerColor(ownerKind: string?): Color3
	if ownerKind == "Player" then
		return CombatConfig.Colors.PlayerHurtbox
	end
	return CombatConfig.Colors.DummyHurtbox
end

-- Crea (una sola vez por personaje) la zona vulnerable visible, soldada al HumanoidRootPart.
-- La propia pieza ES el volumen que consulta la detección. Puede ceder.
function HitboxService.AttachHurtbox(character: Model, ownerKind: string): BasePart?
	local existing = character:FindFirstChild(HURTBOX_NAME)
	if existing then
		return existing :: BasePart
	end

	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not root or not root:IsA("BasePart") or not character.Parent then
		warn(`[HitboxService] No se pudo crear la hurtbox: {character.Name} no tiene HumanoidRootPart.`)
		return nil
	end

	local createdMeanwhile = character:FindFirstChild(HURTBOX_NAME)
	if createdMeanwhile then
		return createdMeanwhile :: BasePart
	end

	local hurtbox = Instance.new("Part")
	hurtbox.Name = HURTBOX_NAME
	hurtbox.Size = CombatConfig.Hurtbox.Size
	hurtbox.CFrame = root.CFrame * CFrame.new(CombatConfig.Hurtbox.Offset)
	applyDebugPartSettings(hurtbox, getOwnerColor(ownerKind), CombatConfig.Debug.HurtboxTransparency)
	hurtbox.CanQuery = true -- necesario para que GetPartBoundsInBox la encuentre
	hurtbox:SetAttribute("OwnerKind", ownerKind)
	hurtbox.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = hurtbox
	weld.Parent = hurtbox

	CollectionService:AddTag(hurtbox, HURTBOX_TAG)

	return hurtbox
end

-- Cambia el aspecto de la hurtbox según el estado defensivo: "Normal", "Blocking" o "Parry".
-- Solo afecta a la visualización; la detección usa siempre el mismo tamaño.
function HitboxService.SetHurtboxState(character: Model, stateName: string)
	local hurtbox = character:FindFirstChild(HURTBOX_NAME)
	if not hurtbox or not hurtbox:IsA("BasePart") then
		return
	end

	local color = getOwnerColor(hurtbox:GetAttribute("OwnerKind") :: string?)
	local transparency = CombatConfig.Debug.HurtboxTransparency

	if stateName == "Blocking" then
		color = CombatConfig.Colors.SpecialZone
	elseif stateName == "Parry" then
		color = CombatConfig.Colors.SpecialZone
		transparency = CombatConfig.Debug.ParryTransparency
	end

	hurtbox.Color = color
	hurtbox.Transparency = if CombatConfig.Debug.Enabled then transparency else 1
end

-- Posición y tamaño de una caja de ataque delante del personaje, orientada según hacia dónde mira.
-- Fuente única de datos para mostrar la caja y para detectar impactos.
function HitboxService.GetAttackBoxData(character: Model, spec: AttackBoxSpec): (CFrame?, Vector3?)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil, nil
	end

	local forward = spec.Forward or DEFAULT_ATTACK_FORWARD
	local vertical = spec.VerticalOffset or 0
	local cframe = root.CFrame * CFrame.new(0, vertical, -(forward + spec.Size.Z / 2))

	return cframe, spec.Size
end

-- Caja de ataque visible (solo visual; sin colisión ni daño).
function HitboxService.ShowAttackBox(cframe: CFrame, size: Vector3, duration: number?): BasePart?
	if not CombatConfig.Debug.Enabled then
		return nil
	end

	local box = Instance.new("Part")
	box.Name = "AttackBoxDebug"
	box.Anchored = true
	box.Size = size
	box.CFrame = cframe
	applyDebugPartSettings(box, CombatConfig.Colors.ActiveAttack, CombatConfig.Debug.AttackBoxTransparency)
	box.CanQuery = false
	box.Parent = getDebugFolder()

	Debris:AddItem(box, duration or CombatConfig.Debug.AttackBoxDuration)
	return box
end

-- Consulta espacial: devuelve los personajes (sin repetir) cuya hurtbox toca la caja, excluyendo al atacante.
-- No muestra nada ni aplica daño.
function HitboxService.QueryBox(attacker: Model, cframe: CFrame, size: Vector3): { Model }
	local targets = {}
	for _, hurtbox in ipairs(CollectionService:GetTagged(HURTBOX_TAG)) do
		if hurtbox.Parent ~= attacker then
			table.insert(targets, hurtbox)
		end
	end
	if #targets == 0 then
		return {}
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = targets

	local hitCharacters = {}
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(cframe, size, params)) do
		local character = part.Parent
		if character and not seen[character] then
			seen[character] = true
			table.insert(hitCharacters, character :: Model)
		end
	end

	return hitCharacters
end

-- Disparo único (mostrar + consultar). Se conserva por compatibilidad con la etapa 1.
function HitboxService.Cast(attacker: Model, spec: AttackBoxSpec, visualDuration: number?): { Model }
	local cframe, size = HitboxService.GetAttackBoxData(attacker, spec)
	if not cframe or not size then
		return {}
	end

	HitboxService.ShowAttackBox(cframe, size, visualDuration)
	return HitboxService.QueryBox(attacker, cframe, size)
end

return HitboxService