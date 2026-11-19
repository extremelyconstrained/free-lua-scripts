-- Forsaken — ESP (survivors & killers, 2D boxes) + Infinite Stamina + Generator ESP
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
	module.MaxStamina = 100
	module.Stamina = module.MaxStamina
	module.CanSprint = true
	pcall(function()
		if module.__staminaChangedEvent then
			module.__staminaChangedEvent:Fire(module.Stamina, 0)
		end
	end)
end
applyStamina()

-- ESP Colors & Settings
local BOX_COLOR_KILLER = Color3.fromRGB(255, 70, 70)
local BOX_COLOR_SURVIVOR = Color3.fromRGB(80, 255, 90)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local BOX_THICKNESS = 1.5
local TEXT_SIZE = 13
local HEALTH_SIZE = 12

local GENERATOR_COLOR = Color3.fromRGB(255, 215, 0)
local GENERATOR_TEXT_SIZE = 12

-- Drawing tables (weak-keyed to prevent leaks)
local espDrawings = {}
local generatorEspDrawings = {}

-- ===== ESP Cleanup Functions =====

local function destroyEsp(model)
	-- rawget to safely read without metamethod interference
	local bundle = rawget(espDrawings, model)
	if not bundle then return end
	for _, drawing in ipairs(bundle) do
		pcall(function() drawing:Remove() end)
	end
	rawset(espDrawings, model, nil)
end

local function destroyGeneratorEsp(model)
	local bundle = rawget(generatorEspDrawings, model)
	if not bundle then return end
	for _, drawing in ipairs(bundle) do
		pcall(function() drawing:Remove() end)
	end
	rawset(generatorEspDrawings, model, nil)
end

local function destroyAllEsp()
	for model in pairs(espDrawings) do
		destroyEsp(model)
	end
end

local function destroyAllGeneratorEsp()
	for model in pairs(generatorEspDrawings) do
		destroyGeneratorEsp(model)
	end
end

-- ===== ESP Bundle Creation =====

local function getEspBundle(model)
	-- rawget to safely check
	local bundle = rawget(espDrawings, model)
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
	rawset(espDrawings, model, bundle)
	return bundle
end

local function getGeneratorEspBundle(model)
	local bundle = rawget(generatorEspDrawings, model)
	if bundle then return bundle end

	local box = Drawing.new("Square")
	box.Thickness = 2.0
	box.Filled = false
	box.Color = GENERATOR_COLOR
	box.Visible = false

	local nametag = Drawing.new("Text")
	nametag.Size = GENERATOR_TEXT_SIZE
	nametag.Center = true
	nametag.Outline = true
	nametag.Color = GENERATOR_COLOR
	nametag.Visible = false

	bundle = { box = box, nametag = nametag }
	rawset(generatorEspDrawings, model, bundle)
	return bundle
end

-- ===== ESP Visibility =====

local function setEspVisible(bundle, visible)
	if not bundle then return end
	bundle.box.Visible = visible
	bundle.nametag.Visible = visible
	bundle.healthTag.Visible = visible
end

local function setGeneratorEspVisible(bundle, visible)
	if not bundle then return end
	bundle.box.Visible = visible
	bundle.nametag.Visible = visible
end

-- ===== Role Detection =====

local function getRole(model)
	if model.Parent and model.Parent.Name == "Killers" then
		return "Killer"
	elseif model.Parent and model.Parent.Name == "Survivors" then
		return "Survivor"
	end
	return nil
end

-- ===== Generator Model Detection =====

local function isGeneratorModel(model)
	-- Check if model itself is a part named "Generator"
	if model:IsA("BasePart") and model.Name == "Generator" then
		return true
	end
	-- Check descendants for Generator part or "gen" in name
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant.Name == "Generator" then
				return true
			end
			if descendant.Name:lower():find("gen") then
				return true
			end
		end
	end
	return false
end

-- ===== Body Part Detection =====

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

local function getVisibleBodyParts(model)
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and VISUAL_PARTS[descendant.Name] then
			parts[#parts + 1] = descendant
		end
	end
	return parts
end

-- ===== ESP Update =====

local function updateEsp(model)
	if model == localPlayer.Character then
		local bundle = rawget(espDrawings, model)
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local role = getRole(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")

	if not role or not humanoid or humanoid.Health <= 0 or not rootPart then
		local bundle = rawget(espDrawings, model)
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local camera = Workspace.CurrentCamera
	local rootPosition, rootOnScreen = camera:WorldToViewportPoint(rootPart.Position)
	if not rootOnScreen or rootPosition.Z <= 0 then
		local bundle = rawget(espDrawings, model)
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local bodyParts = getVisibleBodyParts(model)
	if #bodyParts == 0 then
		local bundle = rawget(espDrawings, model)
		if bundle then setEspVisible(bundle, false) end
		return
	end

	local found, minX, minY, maxX, maxY = projectBounds(bodyParts, camera)
	if not found then
		local bundle = rawget(espDrawings, model)
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
		local bundle = rawget(espDrawings, model)
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

-- ===== Generator ESP Update =====

local function updateGeneratorEsp(model)
	local bundle = rawget(generatorEspDrawings, model)
	if not bundle then return end

	local camera = Workspace.CurrentCamera
	local primaryPart = model:GetPrimaryPart()
	if not primaryPart then
		destroyGeneratorEsp(model)
		return
	end

	local cameraPos = camera.CFrame.Position
	local genPos = primaryPart.Position
	local distance = (cameraPos - genPos).Magnitude

	setGeneratorEspVisible(bundle, true)
	bundle.box.Color = GENERATOR_COLOR
	bundle.box.Position = Vector2.new(0, 0)
	bundle.box.Size = Vector2.new(120, 36)

	bundle.nametag.Text = string.format("Gen: %.1f%%", math.clamp(100 - distance / 50, 0, 100))
	bundle.nametag.Position = Vector2.new(0, 18)
	bundle.nametag.Visible = true
end

-- ===== Heartbeat Connection =====

local espSweepAccumulator = 0
local connection
connection = RunService.Heartbeat:Connect(function(deltaTime)
	espSweepAccumulator += deltaTime
	if espSweepAccumulator >= 1 then
		espSweepAccumulator = 0

		-- Clean up stale player ESP
		for model in pairs(espDrawings) do
			local ok, alive = pcall(function()
				return model and model:IsDescendantOf(Workspace)
			end)
			if not ok or not alive then
				destroyEsp(model)
			else
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local rootPart = model:FindFirstChild("HumanoidRootPart")
				if not humanoid or humanoid.Health <= 0 or not rootPart then
					destroyEsp(model)
				end
			end
		end

		-- Clean up stale generator ESP
		for model in pairs(generatorEspDrawings) do
			local ok, alive = pcall(function()
				return model and model:IsDescendantOf(Workspace)
			end)
			if not ok or not alive then
				destroyGeneratorEsp(model)
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
		-- Update generator ESP for models in Workspace
		for _, model in ipairs(Workspace:GetChildren()) do
			if isGeneratorModel(model) and model:IsDescendantOf(Workspace) then
				updateGeneratorEsp(model)
			end
		end
	end)
end)

-- ===== Input Toggle =====

local toggleConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F2 then
		enabled = not enabled
		if not enabled then
			destroyAllEsp()
			destroyAllGeneratorEsp()
		end
	end
end)

-- ===== Match State =====

local matchStateConnection = localPlayer:GetAttributeChangedSignal("MatchState"):Connect(function()
	enabled = true
	destroyAllEsp()
	applyStamina()
end)

-- ===== Character Respawn =====

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

-- ===== Full Cleanup =====

local cleanup = function()
	enabled = false
	if connection then connection:Disconnect() end
	if toggleConnection then toggleConnection:Disconnect() end
	if matchStateConnection then matchStateConnection:Disconnect() end
	if characterAddedConnection then characterAddedConnection:Disconnect() end
	destroyAllEsp()
	destroyAllGeneratorEsp()
end

_G.ForsakenScriptCleanup = cleanup

return "ESP + infinite stamina + generator ESP loaded"