-- Forsaken — ESP (survivors & killers, 2D boxes) + Infinite Stamina
-- F2 toggles everything; _G.ForsakenScriptCleanup restores pristine state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

if _G.ForsakenScriptCleanup then
	pcall(_G.ForsakenScriptCleanup)
	_G.ForsakenScriptCleanup = nil
end

local localPlayer = Players.LocalPlayer
local enabled = true

-- Stamina
local function applyStamina()
	local ok, module = pcall(require, ReplicatedStorage.Systems.Character.Game.Sprinting)
	if not ok or not module then return end
	module.StaminaLossDisabled = true
	module.StaminaLoss = 0
	module.StaminaGain = 100
	module.MaxStamina = 1000000
	module.Stamina = module.MaxStamina
	module.CanSprint = true
	pcall(function()
		if module.__staminaChangedEvent then
			module.__staminaChangedEvent:Fire(module.Stamina, 0)
		end
	end)
end
applyStamina()

-- ESP

local BOX_COLOR_KILLER = Color3.fromRGB(255, 70, 70)
local BOX_COLOR_SURVIVOR = Color3.fromRGB(80, 255, 90)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local BOX_THICKNESS = 1.5
local TEXT_SIZE = 13
local HEALTH_SIZE = 12

local VISUAL_PARTS = {
	Head = true, Torso = true, UpperTorso = true, LowerTorso = true,
	["Left Arm"] = true, ["Right Arm"] = true,
	["Left Leg"] = true, ["Right Leg"] = true,
	LeftUpperArm = true, RightUpperArm = true,
	LeftLowerArm = true, RightLowerArm = true,
	LeftUpperLeg = true, RightUpperLeg = true,
	LeftLowerLeg = true, RightLowerLeg = true,
	LeftHand = true, RightHand = true, LeftFoot = true, RightFoot = true,
}

local espDrawings = {}

local function destroyEsp(model)
	local bundle = espDrawings[model]
	if not bundle then return end
	for _, drawing in ipairs(bundle) do
		pcall(function() drawing:Remove() end)
	end
	espDrawings[model] = nil
end

local function destroyAllEsp()
	for model in pairs(espDrawings) do
		destroyEsp(model)
	end
end

local function getEspBundle(model)
	local bundle = espDrawings[model]
	if bundle then return bundle end

	local box = Drawing.new("Square")
	box.Thickness = BOX_THICKNESS
	box.Filled = false
	box.Visible = false

	local nametag = Drawing.new("Text")
	nametag.Size = TEXT_SIZE
	nametag.Center = true
	nametag.Outline = true
	nametag.Color = TEXT_COLOR
	nametag.Visible = false

	local healthTag = Drawing.new("Text")
	healthTag.Size = HEALTH_SIZE
	healthTag.Center = true
	healthTag.Outline = true
	healthTag.Color = Color3.fromRGB(120, 220, 120)
	healthTag.Visible = false

	bundle = { box = box, nametag = nametag, healthTag = healthTag }
	espDrawings[model] = bundle
	return bundle
end

local function setEspVisible(bundle, visible)
	bundle.box.Visible = visible
	bundle.nametag.Visible = visible
	bundle.healthTag.Visible = visible
end

local function getRole(model)
	if model.Parent and model.Parent.Name == "Killers" then
		return "Killer"
	elseif model.Parent and model.Parent.Name == "Survivors" then
		return "Survivor"
	end
	return nil
end

local function projectBounds(parts, camera)
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local found = false
	for _, part in ipairs(parts) do
		local cf = part.CFrame
		local half = part.Size * 0.5
		for _, xSign in ipairs({ -1, 1 }) do
			for _, ySign in ipairs({ -1, 1 }) do
				for _, zSign in ipairs({ -1, 1 }) do
					local corner = cf * Vector3.new(xSign * half.X, ySign * half.Y, zSign * half.Z)
					local sp, onScreen = camera:WorldToViewportPoint(corner)
					if onScreen and sp.Z > 0 then
						found = true
						if sp.X < minX then minX = sp.X end
						if sp.Y < minY then minY = sp.Y end
						if sp.X > maxX then maxX = sp.X end
						if sp.Y > maxY then maxY = sp.Y end
					end
				end
			end
		end
	end
	return found, minX, minY, maxX, maxY
end

local function getVisibleBodyParts(model)
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and VISUAL_PARTS[descendant.Name] then
			parts[#parts + 1] = descendant
		end
	end
	return parts
end

local function updateEsp(model)
	if model == localPlayer.Character then
		local bundle = espDrawings[model]
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local role = getRole(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")

	if not role or not humanoid or humanoid.Health <= 0 or not rootPart then
		local bundle = espDrawings[model]
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local camera = Workspace.CurrentCamera
	local rootPosition, rootOnScreen = camera:WorldToViewportPoint(rootPart.Position)
	if not rootOnScreen or rootPosition.Z <= 0 then
		local bundle = espDrawings[model]
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local bodyParts = getVisibleBodyParts(model)
	if #bodyParts == 0 then
		local bundle = espDrawings[model]
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local found, minX, minY, maxX, maxY = projectBounds(bodyParts, camera)
	if not found then
		local bundle = espDrawings[model]
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local padding = 4
	minX -= padding
	minY -= padding
	maxX += padding
	maxY += padding
	local width, height = maxX - minX, maxY - minY
	if width < 4 or height < 4 then
		local bundle = espDrawings[model]
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local bundle = getEspBundle(model)
	local color = role == "Killer" and BOX_COLOR_KILLER or BOX_COLOR_SURVIVOR
	bundle.box.Color = color
	bundle.box.Position = Vector2.new(minX, minY)
	bundle.box.Size = Vector2.new(width, height)
	bundle.box.Visible = true

	local distance = (camera.CFrame.Position - rootPart.Position).Magnitude
	local displayName = model:GetAttribute("ActorDisplayName") or model.Name
	bundle.nametag.Text = string.format("%s | %d studs", displayName, math.floor(distance + 0.5))
	bundle.nametag.Position = Vector2.new((minX + maxX) / 2, minY - TEXT_SIZE - 2)
	bundle.nametag.Visible = true

	local healthText = string.format("HP %d/%d", math.floor(humanoid.Health + 0.5), math.floor(humanoid.MaxHealth + 0.5))
	local fraction = math.clamp(humanoid.Health / math.max(1, humanoid.MaxHealth), 0, 1)
	bundle.healthTag.Text = healthText
	bundle.healthTag.Color = Color3.new(1 - fraction, fraction, 0.2)
	bundle.healthTag.Position = Vector2.new((minX + maxX) / 2, maxY + 2)
	bundle.healthTag.Visible = true
end

-- Watchdog + ESP sweep + round re-hook
local espSweepAccumulator = 0
local connection
connection = RunService.Heartbeat:Connect(function(deltaTime)
	espSweepAccumulator += deltaTime
	if espSweepAccumulator >= 1 then
		espSweepAccumulator = 0
		for model in pairs(espDrawings) do
			local ok, alive = pcall(function()
				return model and model:IsDescendantOf(Workspace)
			end)
			if not ok or not alive then
				destroyEsp(model)
			end
		end
	end

	if not enabled then return end

	pcall(function()
		local playersFolder = Workspace:FindFirstChild("Players")
		if not playersFolder then return end
		for _, roleFolder in ipairs(playersFolder:GetChildren()) do
			if roleFolder.Name == "Killers" or roleFolder.Name == "Survivors" then
				for _, model in ipairs(roleFolder:GetChildren()) do
					if model:IsA("Model") then
						updateEsp(model)
					end
				end
			end
		end
	end)
end)

local toggleConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F2 then
		enabled = not enabled
		if not enabled then
			destroyAllEsp()
		end
	end
end)

local matchStateConnection = localPlayer:GetAttributeChangedSignal("MatchState"):Connect(function()
	enabled = true
	destroyAllEsp()
	applyStamina()
end)

local function onCharacterAdded(character)
	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			applyStamina()
		end
	end)
end

local characterAddedConnection = localPlayer.CharacterAdded:Connect(onCharacterAdded)
if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end

local cleanup = function()
	enabled = false
	if connection then connection:Disconnect() end
	if toggleConnection then toggleConnection:Disconnect() end
	if matchStateConnection then matchStateConnection:Disconnect() end
	if characterAddedConnection then characterAddedConnection:Disconnect() end
	destroyAllEsp()
end

_G.ForsakenScriptCleanup = cleanup

return "ESP + infinite stamina loaded"
