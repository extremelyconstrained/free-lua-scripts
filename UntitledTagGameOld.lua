
if _G.UTG then
	pcall(_G.UTG.Unload)
	_G.UTG = nil
end

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
	AutoVault = true,     -- regular vaults: ledges under HighVaultMinHeight
	AutoHighVault = true, -- high vaults: ledges HighVaultMinHeight and above

	HardLandingSpeed = 40, -- the game rolls at FallingSpeed < -40

	HighVaultMinHeight = 2.0, -- "2+ studs" high-vault threshold
	VaultMinSpeed = 10,       -- grounded: must be moving forward this fast
	VaultForwardDot = 0.3,    -- grounded: velocity must follow the look vector
	VaultCooldown = 0.35,     -- debounce between jump presses
	VaultWhileFalling = true,
	FallingVaultMinDownSpeed = 8, -- airborne: must be falling this fast
	JumpHoldTime = 0.05,

	ToggleRollKey = Enum.KeyCode.T,
	ToggleVaultKey = Enum.KeyCode.Y,
	ToggleHighVaultKey = Enum.KeyCode.H,
	UnloadKey = Enum.KeyCode.Delete,
}


local State = {
	Loaded = true,
	RollStamps = 0,
	VaultPresses = 0,
	LastVaultHeight = 0,
	LastVaultPress = 0,
	LastRollMs = nil,
	RollInput = nil,       -- live QueueInput closure of Parkour.Roll
	RollInputIndex = nil,  -- upvalue index holding the queued timestamp
	Controller = nil,      -- live parkour state (FallingSpeed / RollMs)
	Char = nil,
	CharRayParams = nil,
	CharOverlapParams = nil,
	LastBindRetry = 0,
	Connections = {},
}


local function Track(conn)
	if conn ~= nil then
		table.insert(State.Connections, conn)
	end
end

local function GetHumanoid()
	local char = LocalPlayer.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	return char, humanoid
end


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
	State.RollInput = nil
	State.RollInputIndex = nil
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
					State.RollInput, State.RollInputIndex = fn, index
					return true
				end
			end
		end
	end
	return false
end


local function ControllerScore(ctrl, char)
	if type(ctrl) ~= "table" or type(ctrl.RollMs) ~= "number" then
		return 0
	end
	local rig = ctrl.Rig
	local instance = type(rig) == "table" and rig.Instance or nil
	if typeof(instance) ~= "Instance" or not instance:IsDescendantOf(Workspace) then
		return 0
	end
	if not char or not instance:IsDescendantOf(char) then
		return 0
	end
	local score = 1
	if type(ctrl.EmoteRestricted) == "function" then
		score += 1
	end
	if type(ctrl.IsSlideHeld) == "function" then
		score += 1
	end
	if type(ctrl.AddMomentum) == "function" then
		score += 1
	end
	if ctrl.Params ~= nil then
		score += 1
	end
	return score
end

local function IsLiveController(ctrl, char)
	return ControllerScore(ctrl, char) > 0
end

local function BindController()
	State.Controller = nil
	local ok, matches = pcall(filtergc, "table", { Keys = { "RollMs", "VaultDebounce" } }, false)
	if not ok or type(matches) ~= "table" then
		return false
	end
	if matches.RollMs ~= nil then
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
	State.Controller = best
	return best ~= nil
end

local function StampRollInput()
	if not State.RollInput or not State.RollInputIndex then
		return false
	end
	local ok = pcall(setupvalue, State.RollInput, State.RollInputIndex, time())
	if ok then
		State.RollStamps += 1
	end
	return ok
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

	State.CharRayParams = ray
	State.CharOverlapParams = overlap
	State.Char = char
end

local function ProbeLedge()
	local char, humanoid = GetHumanoid()
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not humanoid then
		return nil
	end
	if State.Char ~= char or not State.CharRayParams then
		BuildProbeParams(char)
	end
	local rayParams = State.CharRayParams
	local overlapParams = State.CharOverlapParams

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
		return nil -- blocked at body height
	end

	local instance = hit.Instance
	if instance:GetAttribute("SwingBar") or instance:GetAttribute("NoClimb") then
		return nil -- the game would swing or climb instead of vaulting
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
	local char = State.Char
	if not char or char ~= LocalPlayer.Character then
		return
	end
	local staleController = not IsLiveController(State.Controller, char)
	if not (staleController or State.RollInput == nil) then
		return
	end
	if os.clock() - State.LastBindRetry < 1 then
		return
	end
	State.LastBindRetry = os.clock()

	if staleController then
		BindController()
		BuildProbeParams(char)
	end
	if State.RollInput == nil then
		BindRollInput()
	end
end

local function BindCharacter()
	local char = LocalPlayer.Character
	if not char then
		return
	end
	State.Char = char
	BuildProbeParams(char)
	BindRollInput()
	BindController()
end

local function Unload()
	State.Loaded = false
	for _, conn in ipairs(State.Connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(State.Connections)
end


Track(RunService.RenderStepped:Connect(function()
	if not State.Loaded then
		return
	end
	EnsureBindings()
	if not CONFIG.AutoRoll then
		return
	end

	local char, humanoid = GetHumanoid()
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		local ctrl = State.Controller
		if ctrl and type(ctrl.RollMs) == "number" and ctrl.RollMs ~= State.LastRollMs then
			State.LastRollMs = ctrl.RollMs
		end
		return
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
		return
	end

	local ctrl = State.Controller
	if not IsLiveController(ctrl, char) then
		return
	end
	local fallingSpeed = ctrl.FallingSpeed
	if type(fallingSpeed) ~= "number" or fallingSpeed > -CONFIG.HardLandingSpeed then
		return -- the game would not roll this landing; leave input untouched
	end

	StampRollInput()
end))


Track(RunService.Heartbeat:Connect(function()
	if not State.Loaded then
		return
	end
	if not (CONFIG.AutoVault or CONFIG.AutoHighVault) then
		return
	end
	if os.clock() - State.LastVaultPress < CONFIG.VaultCooldown then
		return
	end

	local char, humanoid = GetHumanoid()
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
		State.LastVaultHeight = height
		State.LastVaultPress = os.clock()
		State.VaultPresses += 1
	end
end))

Track(LocalPlayer.CharacterAdded:Connect(function(char)
	task.delay(0.3, function()
		if not State.Loaded then
			return
		end
		State.Char = char or LocalPlayer.Character
		BuildProbeParams(State.Char)
		BindRollInput()
		BindController()
		State.LastRollMs = nil
	end)
end))

BindCharacter()


State.Unload = function()
	Unload()
	_G.UTG = nil
end

State.Probe = function()
	return ProbeLedge()
end

State.Status = function()
	local char, humanoid = GetHumanoid()
	return {
		AutoRoll = CONFIG.AutoRoll,
		AutoVault = CONFIG.AutoVault,
		AutoHighVault = CONFIG.AutoHighVault,
		HighVaultMinHeight = CONFIG.HighVaultMinHeight,
		RollBound = State.RollInput ~= nil,
		RollStamps = State.RollStamps,
		LastRollMs = State.LastRollMs,
		ControllerLive = IsLiveController(State.Controller, char),
		FallingSpeed = State.Controller and State.Controller.FallingSpeed,
		VaultPresses = State.VaultPresses,
		LastVaultHeight = State.LastVaultHeight,
		LastProbe = ProbeLedge(),
		Grounded = humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air,
	}
end

State.ToggleAutoRoll = function()
	CONFIG.AutoRoll = not CONFIG.AutoRoll
	return CONFIG.AutoRoll
end

State.ToggleAutoVault = function()
	CONFIG.AutoVault = not CONFIG.AutoVault
	return CONFIG.AutoVault
end

State.ToggleAutoHighVault = function()
	CONFIG.AutoHighVault = not CONFIG.AutoHighVault
	return CONFIG.AutoHighVault
end

_G.UTG = State


Track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == CONFIG.ToggleRollKey then
		State.ToggleAutoRoll()
	elseif input.KeyCode == CONFIG.ToggleVaultKey then
		State.ToggleAutoVault()
	elseif input.KeyCode == CONFIG.ToggleHighVaultKey then
		State.ToggleAutoHighVault()
	elseif input.KeyCode == CONFIG.UnloadKey then
		State.Unload()
	end
end))

