local folder = workspace:WaitForChild("Animaciones")

local animations = {
	{
		rigName = "RunRig",
		animationId = "94980362862867",
	},
	{
		rigName = "LeftRig",
		animationId = "133275686749257",
	},
	{
		rigName = "RightRig",
		animationId = "93362505905321",
	},
	{
		rigName = "BackRig",
		animationId = "96561322957785",
	},
	{
		rigName = "ForwardRig",
		animationId = "83572833970924",
	},
}

for _, data in ipairs(animations) do
	local rig = folder:WaitForChild(data.rigName)

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local controller = rig:FindFirstChildOfClass("AnimationController")

	local animator

	if humanoid then
		animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
	elseif controller then
		animator = controller:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = controller
		end
	else
		warn(rig.Name .. ": no tiene Humanoid ni AnimationController")
		continue
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://" .. data.animationId

	local success, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if success then
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Action
		track:Play(0.15)

		print("Animación reproduciéndose en:", rig.Name)
	else
		warn("Error al cargar la animación de " .. rig.Name .. ": " .. tostring(track))
	end
end