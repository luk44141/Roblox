-- LockOn
-- Ubicación: StarterPlayerScripts > CombatClient > LockOn
-- Fijación de objetivo con la rueda del mouse (clic central). Solo cliente.
-- YA NO escribe la cámara ni orienta al personaje: elige y valida el objetivo, dibuja el marcador y
-- lo expone por GetCameraTarget (lo lee CameraController) y GetFacingTarget (lo lee CharacterOrientation).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage:WaitForChild("CombatSystem"):WaitForChild("CombatConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local cfg = CombatConfig.LockOn

local LockOn = {}

local target: Model? = nil
local marker: BillboardGui? = nil

local function flatten(vector: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return Vector3.zero
	end
	return flat.Unit
end

local function isValidTarget(model: Model): boolean
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	return humanoid ~= nil and humanoid.Health > 0 and root ~= nil and model:IsDescendantOf(workspace)
end

-- Objetivo válido más cercano que esté razonablemente delante de la cámara.
local function findBestTarget(): Model?
	local character = player.Character
	local myRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not myRoot then
		return nil
	end

	local cameraLook = flatten(workspace.CurrentCamera.CFrame.LookVector)
	local best: Model? = nil
	local bestDistance = math.huge

	for _, hurtbox in ipairs(CollectionService:GetTagged(CombatConfig.Tags.Hurtbox)) do
		local model = hurtbox.Parent
		if model and model ~= character and model:IsA("Model") and isValidTarget(model) then
			local isPlayerCharacter = Players:GetPlayerFromCharacter(model) ~= nil
			if cfg.TargetPlayers or not isPlayerCharacter then
				local targetRoot = model:FindFirstChild("HumanoidRootPart") :: BasePart
				local offset = targetRoot.Position - (myRoot :: BasePart).Position
				local distance = offset.Magnitude

				if distance <= cfg.AcquireDistance then
					local direction = flatten(offset)
					local angle = 0
					if direction ~= Vector3.zero and cameraLook ~= Vector3.zero then
						angle = math.deg(math.acos(math.clamp(cameraLook:Dot(direction), -1, 1)))
					end
					if angle <= cfg.AcquireAngle and distance < bestDistance then
						best = model
						bestDistance = distance
					end
				end
			end
		end
	end

	return best
end

local function createMarker(model: Model): BillboardGui?
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "CombatLockOnMarker"
	gui.Adornee = root
	gui.Size = UDim2.fromOffset(cfg.MarkerSize, cfg.MarkerSize)
	gui.StudsOffset = cfg.MarkerOffset
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false

	local ring = Instance.new("Frame")
	ring.Size = UDim2.fromScale(1, 1)
	ring.BackgroundTransparency = 1
	ring.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring

	local stroke = Instance.new("UIStroke")
	stroke.Color = cfg.MarkerColor
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = ring

	gui.Parent = playerGui
	return gui
end

function LockOn.Release()
	if marker then
		marker:Destroy()
		marker = nil
	end
	target = nil
end

local function acquire()
	local best = findBestTarget()
	if not best then
		return -- sin objetivo válido: no se activa
	end

	target = best
	marker = createMarker(best)
end

function LockOn.Toggle()
	if target then
		LockOn.Release()
	else
		acquire()
	end
end

-- Raíz del objetivo actual (o nil). Siempre comprueba que siga siendo válido.
local function getTargetRoot(): BasePart?
	if not target or not isValidTarget(target) then
		return nil
	end
	local root = target:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Para CameraController: (raíz del objetivo, CameraPitch en grados, CameraSmoothing) o nil.
function LockOn.GetCameraTarget(): (BasePart?, number?, number?)
	local root = getTargetRoot()
	if not root then
		return nil, nil, nil
	end
	return root, cfg.CameraPitch, cfg.CameraSmoothing
end

-- Para CharacterOrientation: (raíz del objetivo, TurnSpeed) o nil.
function LockOn.GetFacingTarget(): (BasePart?, number?)
	local root = getTargetRoot()
	if not root then
		return nil, nil
	end
	return root, cfg.TurnSpeed
end

-- Solo validación (ya no toca la cámara). Se ejecuta antes del paso de cámara.
function LockOn.Step(_dt: number)
	if not target then
		return
	end

	local character = player.Character
	local myRoot = character and character:FindFirstChild("HumanoidRootPart")
	local myHumanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not myRoot or not myHumanoid or myHumanoid.Health <= 0 or not isValidTarget(target) then
		LockOn.Release()
		return
	end

	local targetRoot = target:FindFirstChild("HumanoidRootPart") :: BasePart
	if (targetRoot.Position - (myRoot :: BasePart).Position).Magnitude > cfg.BreakDistance then
		LockOn.Release()
	end
end

return LockOn