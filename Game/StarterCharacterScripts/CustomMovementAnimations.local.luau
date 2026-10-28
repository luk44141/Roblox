
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local ANIMATION_IDS = {
	Forward = "83572833970924",
	Run = "94980362862867",
	Left = "133275686749257",
	Right = "93362505905321",
	Back = "96561322957785",
}

local character
local humanoid
local animator
local tracks = {}
local connections = {}
local currentTrack
local currentName

local shiftHeld = false

local function disconnectAll()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function stopCurrent(fadeTime)
	if currentTrack then
		currentTrack:Stop(fadeTime or 0.12)
		currentTrack = nil
		currentName = nil
	end
end

local function setupCharacter(newCharacter)
	disconnectAll()
	stopCurrent(0)

	character = newCharacter
	humanoid = character:WaitForChild("Humanoid")
	animator = humanoid:WaitForChild("Animator")
	tracks = {}
	shiftHeld = false

	for name, id in pairs(ANIMATION_IDS) do
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = "rbxassetid://" .. id

		local success, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)

		if success then
			track.Looped = true
			track.Priority = Enum.AnimationPriority.Action
			tracks[name] = track
		else
			warn("No se pudo cargar la animación:", name, id)
		end
	end

	table.insert(connections,
		UserInputService.InputBegan:Connect(function(input, processed)
			if input.KeyCode == Enum.KeyCode.LeftShift
				or input.KeyCode == Enum.KeyCode.RightShift then
				shiftHeld = true
			end
		end)
	)

	table.insert(connections,
		UserInputService.InputEnded:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.LeftShift
				or input.KeyCode == Enum.KeyCode.RightShift then
				shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			end
		end)
	)

	table.insert(connections,
		RunService.RenderStepped:Connect(function()
			if not humanoid or humanoid.Health <= 0 then
				stopCurrent()
				return
			end

			if humanoid.MoveDirection.Magnitude < 0.05 then
				stopCurrent()
				return
			end

			local desiredName

			if shiftHeld then
				desiredName = "Run"
			elseif UserInputService:IsKeyDown(Enum.KeyCode.D) then
				desiredName = "Right"
			elseif UserInputService:IsKeyDown(Enum.KeyCode.A) then
				desiredName = "Left"
			elseif UserInputService:IsKeyDown(Enum.KeyCode.S) then
				desiredName = "Back"
			elseif UserInputService:IsKeyDown(Enum.KeyCode.W) then
				desiredName = "Forward"
			end

			if not desiredName then
				stopCurrent()
				return
			end

			local desiredTrack = tracks[desiredName]

			if desiredTrack and currentName ~= desiredName then
				stopCurrent(0.1)

				currentTrack = desiredTrack
				currentName = desiredName
				currentTrack:Play(0.1)
			end
		end)
	)
end

player.CharacterAdded:Connect(setupCharacter)

if player.Character then
	setupCharacter(player.Character)
end
