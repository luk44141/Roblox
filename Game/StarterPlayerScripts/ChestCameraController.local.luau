
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local cameraEvent = ReplicatedStorage:WaitForChild("PlayChestCamera")
local data = ReplicatedStorage:WaitForChild("ChestCameraAnimation")

local framesFolder = data:WaitForChild("Frames")
local fovFolder = data:WaitForChild("FOV")

local camera = workspace.CurrentCamera
local playing = false

local function playCamera()
	if playing then
		return
	end

	playing = true

	local frames = framesFolder:GetChildren()
	local fovs = fovFolder:GetChildren()

	local function sortNumeric(a, b)
		return tonumber(a.Name) < tonumber(b.Name)
	end

	table.sort(frames, sortNumeric)
	table.sort(fovs, sortNumeric)

	local previousType = camera.CameraType
	local previousSubject = camera.CameraSubject
	local previousFOV = camera.FieldOfView
	local previousCFrame = camera.CFrame

	camera.CameraType = Enum.CameraType.Scriptable

	local elapsed = 0
	local fps = 60
	local connection

	connection = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt * fps

		local index = math.floor(elapsed) + 1

		if index > #frames then
			connection:Disconnect()

			camera.CameraType = previousType
			camera.CameraSubject = previousSubject
			camera.FieldOfView = previousFOV
			camera.CFrame = previousCFrame

			playing = false
			return
		end

		local frame = frames[index]

		if frame:IsA("CFrameValue") then
			camera.CFrame = frame.Value
		end

		local fov = fovs[index]

		if fov then
			if fov:IsA("NumberValue") then
				camera.FieldOfView = fov.Value
			elseif fov:IsA("IntValue") then
				camera.FieldOfView = fov.Value
			end
		end
	end)
end

cameraEvent.OnClientEvent:Connect(playCamera)
