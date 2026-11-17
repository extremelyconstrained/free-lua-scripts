local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local VirtualInputManager
pcall(function()
	VirtualInputManager = game:GetService("VirtualInputManager")
end)

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
	AutoRoll = true,
	AutoVault = true,
	AutoHighVault = true,

	HardLandingSpeed = 40,
	HighVaultMinHeight = 2.0,
	VaultMinSpeed = 10,
	VaultForwardDot = 0.3,
	VaultCooldown = 0.35,
	VaultWhileFalling = true,
	FallingVaultMinDownSpeed = 8,
	JumpHoldTime = 0.05,

	ToggleRollKey = Enum.KeyCode.T,
	ToggleVaultKey = Enum.KeyCode.Y,
	ToggleHighVaultKey = Enum.KeyCode.H,
	UnloadKey = Enum.KeyCode.Delete,
}

local function getCharacterParts()
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart then
		return nil
	end
	return character, humanoid, rootPart
end

local RollState = {
	RollInput = nil,
	RollInputIndex = nil,
	Controller = nil,
	Char = nil,
	CharRayParams = nil,
	CharOverlapParams = nil,
	LastBindRetry = 0,
	LastVaultPress = 0,
	VaultPresses = 0,
}

local function UsesNumericUpvalue(fn)
	local ok, ups = pcall(getupvalues, fn)
	if not ok or type(ups) ~= "table" then
		return nil
	end
	for index, value in pairs(ups) do
		if type(value) == "number" then
			return index
		end
	end
	return nil
end

local function BindRollInput()
	RollState.RollInput = nil
	RollState.RollInputIndex = nil
	local filters = {
		{ Name = "QueueInput", Constants = { "Queue" } },
		{ Name = "QueueInput" },
	}
	for _, filter in ipairs(filters) do
		local ok, matches = pcall(filtergc, "function", filter, false)
		if ok and type(matches) == "table" then
			if type(matches) == "function" then
				matches = { matches }
			end
			for _, fn in ipairs(matches) do
				local index = UsesNumericUpvalue(fn)
				if index then
					RollState.RollInput, RollState.RollInputIndex = fn, index
					return true
				end
			end
		end
	end
	return false
end

local function ControllerScore(ctrl, char)
	if type(ctrl) ~= "table" or type(rawget(ctrl, "RollMs")) ~= "number" then
		return 0
	end
	local rig = rawget(ctrl, "Rig")
	local instance = type(rig) == "table" and rawget(rig, "Instance") or nil
	if typeof(instance) ~= "Instance" or not instance:IsDescendantOf(Workspace) then
		return 0
	end
	if not char or not instance:IsDescendantOf(char) then
		return 0
	end
	local score = 1
	if type(rawget(ctrl, "EmoteRestricted")) == "function" then
		score += 1
	end
	if type(rawget(ctrl, "IsSlideHeld")) == "function" then
		score += 1
	end
	if type(rawget(ctrl, "AddMomentum")) == "function" then
		score += 1
	end
	if rawget(ctrl, "Params") ~= nil then
		score += 1
	end
	return score
end

local function IsLiveController(ctrl, char)
	return ControllerScore(ctrl, char) > 0
end

local function BindController()
	RollState.Controller = nil
	local ok, matches = pcall(filtergc, "table", { Keys = { "RollMs", "VaultDebounce" } }, false)
	if not ok or type(matches) ~= "table" then
		return false
	end
	if rawget(matches, "RollMs") ~= nil then
		matches = { matches }
	end
	local char = LocalPlayer.Character
	local best, bestScore = nil, 0
	for _, ctrl in ipairs(matches) do
		local score = ControllerScore(ctrl, char)
		if score > bestScore then
			best, bestScore = ctrl, score
		end
	end
	RollState.Controller = best
	return best ~= nil
end

local function StampRollInput()
	if not RollState.RollInput or not RollState.RollInputIndex then
		return false
	end
	return (pcall(setupvalue, RollState.RollInput, RollState.RollInputIndex, time()))
end

local function BuildProbeParams(char)
	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	ray.FilterDescendantsInstances = { char, Workspace.CurrentCamera }
	ray.CollisionGroup = "Player"

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { char, Workspace.CurrentCamera }
	overlap.CollisionGroup = "Player"
	overlap.MaxParts = 1

	RollState.CharRayParams = ray
	RollState.CharOverlapParams = overlap
	RollState.Char = char
end

local function ProbeLedge()
	local char, humanoid = getCharacterParts()
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not humanoid then
		return nil
	end
	if RollState.Char ~= char or not RollState.CharRayParams then
		BuildProbeParams(char)
	end
	local rayParams = RollState.CharRayParams
	local overlapParams = RollState.CharOverlapParams

	local cf = root.CFrame
	local look, up = cf.LookVector, cf.UpVector
	local position = root.Position

	if #Workspace:GetPartBoundsInBox(cf * CFrame.new(0, 1.125, -1.25), Vector3.new(1, 3.5, 1.7), overlapParams) == 0 then
		return nil
	end

	local hit
	for i = 0.5, 2, 0.25 do
		hit = Workspace:Raycast(position + look * i + up * 2.75, -up * 3.25, rayParams)
		if hit then
			break
		end
	end
	if not hit then
		return nil
	end

	if Workspace:Raycast(position + Vector3.new(0, 1.25, 0) - look * 2.5, look * 3, rayParams) then
		return nil
	end

	local instance = hit.Instance
	if instance:GetAttribute("SwingBar") or instance:GetAttribute("NoClimb") then
		return nil
	end

	return math.abs(hit.Position.Y - position.Y)
end

local function PressJump()
	if not VirtualInputManager then
		return false
	end
	local pressed = pcall(function()
		VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
	end)
	if not pressed then
		return false
	end
	task.delay(CONFIG.JumpHoldTime, function()
		pcall(function()
			VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
		end)
	end)
	return true
end

local function EnsureBindings()
	local char = RollState.Char
	if not char or char ~= LocalPlayer.Character then
		return
	end
	local staleController = not IsLiveController(RollState.Controller, char)
	if not (staleController or RollState.RollInput == nil) then
		return
	end
	if os.clock() - RollState.LastBindRetry < 1 then
		return
	end
	RollState.LastBindRetry = os.clock()

	if staleController then
		BindController()
		BuildProbeParams(char)
	end
	if RollState.RollInput == nil then
		BindRollInput()
	end
end

local function BindCharacter()
	local char = LocalPlayer.Character
	if not char then
		return
	end
	RollState.Char = char
	BuildProbeParams(char)
	BindRollInput()
	BindController()
end

local function tryAutoRoll()
	if not CONFIG.AutoRoll then
		return
	end

	EnsureBindings()

	local char, humanoid = getCharacterParts()
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		return
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
		return
	end

	local ctrl = RollState.Controller
	if not IsLiveController(ctrl, char) then
		return
	end
	local fallingSpeed = rawget(ctrl, "FallingSpeed")
	if type(fallingSpeed) ~= "number" or fallingSpeed > -CONFIG.HardLandingSpeed then
		return
	end

	StampRollInput()
end

local function tryAutoVault()
	if not CONFIG.AutoVault and not CONFIG.AutoHighVault then
		return
	end
	if os.clock() - RollState.LastVaultPress < CONFIG.VaultCooldown then
		return
	end

	local char, humanoid = getCharacterParts()
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if char:GetAttribute("Sliding") then
		return
	end

	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local velocity = root.AssemblyLinearVelocity
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
		local look = root.CFrame.LookVector
		local lookFlat = Vector3.new(look.X, 0, look.Z)
		if horizontal.Magnitude < CONFIG.VaultMinSpeed then
			return
		end
		if lookFlat.Magnitude < 0.01 then
			return
		end
		if horizontal.Unit:Dot(lookFlat.Unit) < CONFIG.VaultForwardDot then
			return
		end
	else
		if not CONFIG.VaultWhileFalling or velocity.Y > -CONFIG.FallingVaultMinDownSpeed then
			return
		end
	end

	local height = ProbeLedge()
	if not height then
		return
	end

	local high = height >= CONFIG.HighVaultMinHeight
	if high then
		if not CONFIG.AutoHighVault then
			return
		end
	elseif not CONFIG.AutoVault then
		return
	end

	if PressJump() then
		RollState.LastVaultPress = os.clock()
		RollState.VaultPresses += 1
	end
end

if type(_G.UntitledTagGameUnload) == "function" then
	pcall(_G.UntitledTagGameUnload)
end

local Connections = {}
local unloaded = false

local function Unload()
	if unloaded then
		return
	end
	unloaded = true
	for _, conn in ipairs(Connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(Connections)
	if _G.UntitledTagGameUnload == Unload then
		_G.UntitledTagGameUnload = nil
	end
end

_G.UntitledTagGameUnload = Unload

local function Track(conn)
	if conn then
		table.insert(Connections, conn)
	end
end

BindCharacter()

Track(LocalPlayer.CharacterAdded:Connect(function(char)
	task.delay(0.3, function()
		if unloaded then
			return
		end
		RollState.Char = char or LocalPlayer.Character
		BuildProbeParams(RollState.Char)
		BindRollInput()
		BindController()
	end)
end))

local vaultAccumulator = 0
Track(RunService.RenderStepped:Connect(function()
	if unloaded then
		return
	end
	tryAutoRoll()
end))

Track(RunService.Heartbeat:Connect(function(deltaTime)
	if unloaded then
		return
	end
	vaultAccumulator = vaultAccumulator + deltaTime
	if vaultAccumulator >= 0.05 then
		vaultAccumulator = 0
		tryAutoVault()
	end
end))

Track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == CONFIG.ToggleRollKey then
		CONFIG.AutoRoll = not CONFIG.AutoRoll
	elseif input.KeyCode == CONFIG.ToggleVaultKey then
		CONFIG.AutoVault = not CONFIG.AutoVault
	elseif input.KeyCode == CONFIG.ToggleHighVaultKey then
		CONFIG.AutoHighVault = not CONFIG.AutoHighVault
	elseif input.KeyCode == CONFIG.UnloadKey then
		Unload()
	end
end))
