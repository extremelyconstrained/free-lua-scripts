local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local mainModule = require(ReplicatedStorage:WaitForChild("MainModule"))

local tracer = Instance.new("Part")
tracer.Name = "LocalAimviewerTracer"
tracer.Anchored = true
tracer.CanCollide = false
tracer.CanQuery = false
tracer.CanTouch = false
tracer.Shape = Enum.PartType.Cylinder
tracer.Material = Enum.Material.Neon
tracer.Color = Color3.fromRGB(255, 0, 0)
tracer.Transparency = 1
tracer.Size = Vector3.new(0.1, 0.1, 0.1)
tracer.Parent = workspace

local running = true
local updateConnection
local inputConnection

local function stop()
	if not running then
		return
	end

	running = false
	if updateConnection then
		updateConnection:Disconnect()
	end
	if inputConnection then
		inputConnection:Disconnect()
	end
	tracer:Destroy()
end

local function updateTracer()
	local character = localPlayer.Character
	if not character then
		tracer.Transparency = 1
		return
	end

	local ok, heldGun = pcall(mainModule.GunHold, character)
	local gun = ok and heldGun and heldGun[1]
	local handle = gun and gun:FindFirstChild("Handle")
	local bodyEffects = character:FindFirstChild("BodyEffects")
	local mousePosition = bodyEffects and bodyEffects:FindFirstChild("MousePos")

	if not handle or not mousePosition or not mousePosition:IsA("Vector3Value") then
		tracer.Transparency = 1
		return
	end

	local origin = handle.Position
	local offset = mousePosition.Value - origin
	local distance = math.clamp(offset.Magnitude, 5, 200)
	if distance == 0 then
		tracer.Transparency = 1
		return
	end

	tracer.Transparency = 0.25
	tracer.Size = Vector3.new(distance, 0.1, 0.1)
	tracer.CFrame = CFrame.lookAt(origin, origin + offset.Unit)
		* CFrame.new(0, 0, -distance / 2)
		* CFrame.Angles(0, math.pi / 2, 0)
end

updateConnection = RunService.Heartbeat:Connect(updateTracer)
inputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not gameProcessed and input.KeyCode == Enum.KeyCode.Home then
		stop()
	end
end)
