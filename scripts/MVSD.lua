local Config = {
	Mode = "rage", -- "rage" | "legit"
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Teams = game:GetService("Teams")

if _G.MVSD then
	pcall(_G.MVSD)
	_G.MVSD = nil
end

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local FFA_Team = Teams:FindFirstChild("FFA_Team")

local function isTeammate(player)
	if not localPlayer.Team or not player.Team then
		return false
	end
	if localPlayer.Team == FFA_Team or player.Team == FFA_Team then
		return false
	end
	return localPlayer.Team == player.Team
end

-- ESP

local drawingsByPlayer = {}
local espEnabled = true

local BOX_COLOR = Color3.fromRGB(255, 80, 80)
local TEAMMATE_COLOR = Color3.fromRGB(80, 255, 80)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local BOX_THICKNESS = 1.5
local TEXT_SIZE = 13

local function destroyDrawings(player)
	local drawings = drawingsByPlayer[player]
	if not drawings then return end
	for _, drawing in ipairs(drawings) do
		pcall(function() drawing:Remove() end)
	end
	drawingsByPlayer[player] = nil
end

local function destroyAllDrawings()
	for player in pairs(drawingsByPlayer) do
		destroyDrawings(player)
	end
end

local function getDrawings(player)
	local drawings = drawingsByPlayer[player]
	if drawings then return drawings end

	local box = Drawing.new("Square")
	box.Thickness = BOX_THICKNESS
	box.Filled = false
	box.Visible = false

	local nameTag = Drawing.new("Text")
	nameTag.Size = TEXT_SIZE
	nameTag.Center = true
	nameTag.Outline = true
	nameTag.Color = TEXT_COLOR
	nameTag.Visible = false

	local distanceTag = Drawing.new("Text")
	distanceTag.Size = TEXT_SIZE - 2
	distanceTag.Center = true
	distanceTag.Outline = true
	distanceTag.Color = TEXT_COLOR
	distanceTag.Visible = false

	drawings = {box, nameTag, distanceTag}
	drawingsByPlayer[player] = drawings
	return drawings
end

local function setDrawingsVisible(player, visible)
	local drawings = drawingsByPlayer[player]
	if not drawings then return end
	for _, drawing in ipairs(drawings) do
		drawing.Visible = visible
	end
end

local function getBoxColor(player)
	if isTeammate(player) then
		return TEAMMATE_COLOR
	end
	return BOX_COLOR
end

local function getCharacterBounds(character)
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	local found = false

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			local offset = part.Position - camera.CFrame.Position
			local inFront = camera.CFrame.LookVector:Dot(offset) > 1
			if inFront then
				local position, onScreen = camera:WorldToViewportPoint(part.Position)
				if onScreen then
					found = true
					minX = math.min(minX, position.X)
					minY = math.min(minY, position.Y)
					maxX = math.max(maxX, position.X)
					maxY = math.max(maxY, position.Y)
				end
			end
		end
	end

	return found, minX, minY, maxX, maxY
end

local function isPlayerStale(player)
	local ok, stale = pcall(function()
		if not player or not player:IsDescendantOf(Players) then
			return true
		end

		local character = player.Character
		if character and not character:IsDescendantOf(Workspace) then
			return true
		end

		return false
	end)

	return ok and stale or false
end

local function sweepStaleInstances()
	local currentPlayers = {}
	for _, player in ipairs(Players:GetPlayers()) do
		currentPlayers[player] = true
	end

	for player in pairs(drawingsByPlayer) do
		if not currentPlayers[player] or isPlayerStale(player) then
			destroyDrawings(player)
		end
	end
end

local function updatePlayerEsp(player)
	if player == localPlayer or isTeammate(player) then
		destroyDrawings(player)
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	if not character or not character:IsDescendantOf(Workspace)
		or not humanoid or not rootPart or humanoid.Health <= 0
		or humanoid:GetState() == Enum.HumanoidStateType.Dead then
		destroyDrawings(player)
		return
	end

	local rootPosition, rootOnScreen = camera:WorldToViewportPoint(rootPart.Position)
	if not rootOnScreen then
		setDrawingsVisible(player, false)
		return
	end

	local found, minX, minY, maxX, maxY = getCharacterBounds(character)
	if not found then
		setDrawingsVisible(player, false)
		return
	end

	local padding = 4
	minX -= padding
	minY -= padding
	maxX += padding
	maxY += padding

	local width = maxX - minX
	local height = maxY - minY
	if width < 4 or height < 4 then
		setDrawingsVisible(player, false)
		return
	end

	local drawings = getDrawings(player)
	local box, nameTag, distanceTag = drawings[1], drawings[2], drawings[3]
	local color = getBoxColor(player)

	box.Color = color
	box.Position = Vector2.new(minX, minY)
	box.Size = Vector2.new(width, height)
	box.Visible = true

	local distance = (camera.CFrame.Position - rootPart.Position).Magnitude

	nameTag.Text = player.Name
	nameTag.Position = Vector2.new((minX + maxX) / 2, minY - TEXT_SIZE - 2)
	nameTag.Visible = true

	distanceTag.Text = string.format("%d studs", math.floor(distance + 0.5))
	distanceTag.Position = Vector2.new((minX + maxX) / 2, maxY + 2)
	distanceTag.Visible = true
end

local sweepAccumulator = 0
local renderConnection
renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
	if not espEnabled then return end

	sweepAccumulator += deltaTime
	if sweepAccumulator >= 1 then
		sweepAccumulator = 0
		sweepStaleInstances()
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local ok = pcall(updatePlayerEsp, player)
		if not ok then
			setDrawingsVisible(player, false)
		end
	end
end)

local playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
	destroyDrawings(player)
end)

local characterAddedConnections = {}
local function watchCharacter(player)
	characterAddedConnections[player] = player.CharacterAdded:Connect(function()
		setDrawingsVisible(player, false)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	watchCharacter(player)
end

local playerAddedConnection = Players.PlayerAdded:Connect(watchCharacter)

-- Ragebot

local ShootGun = ReplicatedStorage.Remotes.ShootGun
local Tags = require(ReplicatedStorage.Modules.Tags)
local CollisionGroups = require(ReplicatedStorage.Modules.CollisionGroups)
local WeaponRaycast = require(ReplicatedStorage.Modules.WeaponRaycast)
local CharacterRayOrigin = require(ReplicatedStorage.Modules.CharacterRayOrigin)
local BulletRenderer = require(ReplicatedStorage.Modules.BulletRenderer)

local MAX_RANGE = 400
local MIN_COOLDOWN = 0.08

local lastShot = 0
local ragebotEnabled = true

local function isRage()
	return string.lower(Config.Mode) == "rage"
end

local function getEquippedGun()
	local character = localPlayer.Character
	if character then
		for _, tool in ipairs(character:GetChildren()) do
			if tool:IsA("Tool") and CollectionService:HasTag(tool, Tags.GUN_TOOL) then
				return tool
			end
		end
	end
	return nil
end

-- legit mode: shot must reach the target with a clear line of fire
local function hasLineOfFire(targetCharacter, targetPosition)
	local character = localPlayer.Character
	local origin = character and CharacterRayOrigin(character)
	if not origin then return false end

	local direction = targetPosition - origin
	if direction.Magnitude < 0.001 then return true end
	local targetPoint = targetPosition + direction.Unit * 50

	local screenHit = WeaponRaycast(camera.CFrame.Position, targetPoint, nil, CollisionGroups.SCREEN_RAYCAST)
	local midPoint = (screenHit and screenHit.Position) or targetPoint

	local originHit = WeaponRaycast(origin, midPoint)
	if originHit == nil then return true end
	return originHit.Instance ~= nil and originHit.Instance:IsDescendantOf(targetCharacter)
end

-- closest part of the character to the shooter (no wall/LoS rejection in rage mode)
local function findClosestPart(character, origin)
	local closestPart, closestPosition, closestDistance
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local distance = (origin - descendant.Position).Magnitude
			if not closestDistance or distance < closestDistance then
				closestPart = descendant
				closestPosition = descendant.Position
				closestDistance = distance
			end
		end
	end
	return closestPart, closestPosition
end

local function findClosestEnemy()
	local character = localPlayer.Character
	local localRoot = character and character:FindFirstChild("HumanoidRootPart")
	local origin = character and CharacterRayOrigin(character)
	if not localRoot or not origin then return nil end

	local closest, closestDistance
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer and not isTeammate(player) then
			local enemyCharacter = player.Character
			if enemyCharacter and enemyCharacter:IsDescendantOf(Workspace) then
				local humanoid = enemyCharacter:FindFirstChildOfClass("Humanoid")
				local rootPart = enemyCharacter:FindFirstChild("HumanoidRootPart")
				if humanoid and rootPart and humanoid.Health > 0
					and humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
					local distance = (localRoot.Position - rootPart.Position).Magnitude
					if distance <= MAX_RANGE and (not closestDistance or distance < closestDistance) then
						local closestPart, closestPartPosition = findClosestPart(enemyCharacter, origin)
						if closestPart then
							if not isRage() and not hasLineOfFire(enemyCharacter, closestPartPosition) then
								continue
							end
							closest = {player = player, position = closestPartPosition, part = closestPart, distance = distance}
							closestDistance = distance
						end
					end
				end
			end
		end
	end
	return closest
end

local function fireAt(tool, targetPart, targetPosition)
	local character = localPlayer.Character
	local Muzzle = tool:FindFirstChild("Muzzle", true)
	if not Muzzle then return end

	local origin = CharacterRayOrigin(character)
	if not origin then return end

	local direction = targetPosition - origin
	if direction.Magnitude < 0.001 then return end
	local targetPoint = targetPosition + direction.Unit * 50

	local Fire = tool:FindFirstChild("Fire")
	if Fire then Fire:Play() end

	pcall(BulletRenderer, Muzzle.WorldPosition, targetPosition, tool:GetAttribute("BulletType"))
	pcall(function() tool:Activate() end)

	ShootGun:FireServer(origin, targetPoint, targetPart, targetPosition)
	lastShot = tick()
end

local heartbeatConnection
heartbeatConnection = RunService.Heartbeat:Connect(function()
	if not ragebotEnabled then return end

	local tool = getEquippedGun()
	if not tool or tool.Enabled == false then return end

	local cooldown = tool:GetAttribute("Cooldown") or MIN_COOLDOWN
	if tick() - lastShot < math.max(cooldown, MIN_COOLDOWN) then return end

	local target = findClosestEnemy()
	if not target then return end

	pcall(fireAt, tool, target.part, target.position)
end)

-- Cleanup

local cleanup
cleanup = function()
	espEnabled = false
	ragebotEnabled = false
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	if playerRemovingConnection then
		playerRemovingConnection:Disconnect()
		playerRemovingConnection = nil
	end
	if playerAddedConnection then
		playerAddedConnection:Disconnect()
		playerAddedConnection = nil
	end
	for player, connection in pairs(characterAddedConnections) do
		pcall(function() connection:Disconnect() end)
		characterAddedConnections[player] = nil
	end
	destroyAllDrawings()
end

_G.MVSD = cleanup

return "MVSD loaded"
