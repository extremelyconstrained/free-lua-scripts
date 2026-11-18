local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

if _G.MurderersRagebotCleanup then
	pcall(_G.MurderersRagebotCleanup)
	_G.MurderersRagebotCleanup = nil
end

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local ShootGun = ReplicatedStorage.Remotes.ShootGun
local Tags = require(ReplicatedStorage.Modules.Tags)
local CollisionGroups = require(ReplicatedStorage.Modules.CollisionGroups)
local WeaponRaycast = require(ReplicatedStorage.Modules.WeaponRaycast)
local CharacterRayOrigin = require(ReplicatedStorage.Modules.CharacterRayOrigin)
local BulletRenderer = require(ReplicatedStorage.Modules.BulletRenderer)

local FFA_Team = Teams:FindFirstChild("FFA_Team")
local MAX_RANGE = 400
local MIN_COOLDOWN = 0.08


local lastShot = 0
local ragebotEnabled = true

local function isEnemy(player)
	local localTeam = localPlayer.Team
	if localTeam == FFA_Team then localTeam = nil end
	local team = player.Team
	if team == FFA_Team then team = nil end
	return localTeam ~= team
end

local function getEquippedGun()
	local character = localPlayer.Character
	if not character then return nil end
	for _, tool in ipairs(character:GetChildren()) do
		if tool:IsA("Tool") and CollectionService:HasTag(tool, Tags.GUN_TOOL) then
			return tool
		end
	end
	return nil
end

local PART_PRIORITY = {
	"Head",
	"UpperTorso",
	"Torso",
	"LowerTorso",
	"HumanoidRootPart",
	"LeftUpperArm",
	"RightUpperArm",
	"LeftArm",
	"RightArm",
	"LeftLowerArm",
	"RightLowerArm",
	"LeftHand",
	"RightHand",
	"LeftUpperLeg",
	"RightUpperLeg",
	"LeftLeg",
	"RightLeg",
	"LeftLowerLeg",
	"RightLowerLeg",
	"LeftFoot",
	"RightFoot",
}

local function getVisibilityOrder(character)
	local ordered, seen = {}, {}
	for _, name in ipairs(PART_PRIORITY) do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			seen[part] = true
			table.insert(ordered, part)
		end
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") and not seen[descendant] then
			seen[descendant] = true
			table.insert(ordered, descendant)
		end
	end
	return ordered
end

local function findFirstVisiblePart(character, origin)
	for _, part in ipairs(getVisibilityOrder(character)) do
		local position = part.Position

		local cameraHit = WeaponRaycast(camera.CFrame.Position, position, nil, CollisionGroups.SCREEN_RAYCAST)
		local cameraSees = cameraHit == nil or (cameraHit.Instance and cameraHit.Instance:IsDescendantOf(character))
		if cameraSees then
			local originHit = WeaponRaycast(origin, position)
			local originSees = originHit == nil or (originHit.Instance and originHit.Instance:IsDescendantOf(character))
			if originSees then
				return part, position
			end
		end
	end
	return nil, nil
end

local function findClosestVisibleEnemy()
	local character = localPlayer.Character
	local localRoot = character and character:FindFirstChild("HumanoidRootPart")
	local origin = character and CharacterRayOrigin(character)
	if not localRoot or not origin then return nil end

	local closest, closestDistance
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer and isEnemy(player) then
			local enemyCharacter = player.Character
			if enemyCharacter and enemyCharacter:IsDescendantOf(Workspace) then
				local humanoid = enemyCharacter:FindFirstChildOfClass("Humanoid")
				local rootPart = enemyCharacter:FindFirstChild("HumanoidRootPart")
				if humanoid and rootPart and humanoid.Health > 0
					and humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
					local distance = (localRoot.Position - rootPart.Position).Magnitude
					if distance <= MAX_RANGE and (not closestDistance or distance < closestDistance) then
						local visiblePart, visiblePosition = findFirstVisiblePart(enemyCharacter, origin)
						if visiblePart then
							closest = {player = player, position = visiblePosition, part = visiblePart, distance = distance}
							closestDistance = distance
						end
					end
				end
			end
			end
	end
	return closest
end

local function fireAt(tool, targetPosition)
	local character = localPlayer.Character
	local Muzzle = tool:FindFirstChild("Muzzle", true)
	if not Muzzle then return end

	local origin = CharacterRayOrigin(character)
	if not origin then return end

	local direction = (targetPosition - camera.CFrame.Position)
	if direction.Magnitude < 0.001 then return end
	local targetPoint = targetPosition + direction.Unit * 50

	local screenHit = WeaponRaycast(camera.CFrame.Position, targetPoint, nil, CollisionGroups.SCREEN_RAYCAST)
	local v8 = (screenHit and screenHit.Position) or targetPoint

	local v9 = WeaponRaycast(origin, v8)
	local hitPosition = v9 and v9.Position or targetPoint
	local hitInstance = v9 and v9.Instance or nil

	local Fire = tool:FindFirstChild("Fire")
	if Fire then Fire:Play() end

	pcall(BulletRenderer, Muzzle.WorldPosition, hitPosition, tool:GetAttribute("BulletType"))
	pcall(function() tool:Activate() end)

	ShootGun:FireServer(origin, targetPoint, hitInstance, v9 and v9.Position or nil)
	lastShot = tick()
end

local connection
connection = RunService.Heartbeat:Connect(function()
	if not ragebotEnabled then return end

	local tool = getEquippedGun()
	if not tool or tool.Enabled == false then return end

	local cooldown = tool:GetAttribute("Cooldown") or MIN_COOLDOWN
	if tick() - lastShot < math.max(cooldown, MIN_COOLDOWN) then return end

	local target = findClosestVisibleEnemy()
	if not target then return end

	pcall(fireAt, tool, target.position)
end)

local cleanup = function()
	ragebotEnabled = false
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

_G.MurderersRagebotCleanup = cleanup

return "Ragebot loaded"
