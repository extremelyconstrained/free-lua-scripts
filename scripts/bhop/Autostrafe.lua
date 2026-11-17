local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GAME_SENSITIVITY = 1
local TOGGLE_KEY = Enum.KeyCode.F
local MAX_TURN_RATE = 4.5
local MIN_TURN_RATE = 2.2
local SNAP_TURN_THRESHOLD = 75
local ACCEPT_THETA = 82
local OVERSHOOT_THETA = 110
local ACCEL_ESTIMATE_FALLBACK = 25

local executorGlobals = getgenv and getgenv() or _G
if executorGlobals.__Autostrafe and executorGlobals.__Autostrafe.dispose then
    pcall(executorGlobals.__Autostrafe.dispose)
end
local scriptHandle = {}
executorGlobals.__Autostrafe = scriptHandle
local connections = {}
local function track(connection)
    connections[#connections + 1] = connection
    return connection
end
scriptHandle.dispose = function()
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
end

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local enabled = true
local jumpActive = false
local previousSpeed = 0
local perpendicularAccelEstimate = ACCEL_ESTIMATE_FALLBACK
local pixelRemainder = 0

local hasMouseMoveRel = type(mousemoverel) == "function"

local function getHorizontalVelocity(character)
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not rootPart then
        return nil, 0
    end
    local velocity = rootPart.AssemblyLinearVelocity
    local flat = Vector3.new(velocity.X, 0, velocity.Z)
    return flat, flat.Magnitude
end

local function getFlattenedCameraVectors()
    local look = camera.CFrame.LookVector
    local forward = Vector3.new(look.X, 0, look.Z)
    if forward.Magnitude < 0.01 then
        return nil, nil
    end
    forward = forward.Unit
    local right = Vector3.new(-forward.Z, 0, forward.X)
    return forward, right
end

local function getWishDirection(forward, right)
    local moveForward = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
    local strafeAxis = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
    local wish = right * strafeAxis + forward * moveForward
    if wish.Magnitude < 0.01 then
        return nil, strafeAxis
    end
    return wish.Unit, strafeAxis
end

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function isAirborne(humanoid, rootPart)
    if humanoid and (humanoid:GetState() == Enum.HumanoidStateType.Freefall or humanoid:GetState() == Enum.HumanoidStateType.Jumping) then
        return true
    end
    if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
        return true
    end
    if not rootPart then
        return false
    end
    raycastParams.FilterDescendantsInstances = rootPart.Parent and { rootPart.Parent } or {}
    local hit = Workspace:Raycast(rootPart.Position, Vector3.new(0, -3.25, 0), raycastParams)
    return hit == nil
end

local function pixelsPerRadian()
    local fovRadians = math.rad(camera.FieldOfView)
    local zoomFactor = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) and 5 or 1
    return 128 / (GAME_SENSITIVITY * math.tan(fovRadians * 0.5)) * zoomFactor
end

local function getSteerDirection()
    local left = UserInputService:IsKeyDown(Enum.KeyCode.A)
    local right = UserInputService:IsKeyDown(Enum.KeyCode.D)
    if left == right then
        return 0
    end
    return right and 1 or -1
end

local function computeTurnRate(speed, cosTheta)
    if speed < 1 then
        return 2.2
    end
    local theta = math.deg(math.acos(math.clamp(cosTheta, -1, 1)))
    local sustainRate = math.clamp(perpendicularAccelEstimate * 2 / speed + 0.6, MIN_TURN_RATE, MAX_TURN_RATE)
    if theta < SNAP_TURN_THRESHOLD then
        return MAX_TURN_RATE
    elseif theta < ACCEPT_THETA then
        return math.clamp(sustainRate * 1.7, MIN_TURN_RATE, MAX_TURN_RATE)
    elseif theta <= OVERSHOOT_THETA then
        return sustainRate
    end
    return 0
end

track(RunService.RenderStepped:Connect(function(deltaTime)
    local character = localPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local velocityFlat, speed = getHorizontalVelocity(character)

    local airborne = isAirborne(humanoid, rootPart)

    if airborne and UserInputService:IsKeyDown(Enum.KeyCode.Space) then
        jumpActive = true
    end
    if not airborne then
        jumpActive = false
    end

    if not enabled or not hasMouseMoveRel or not airborne or not jumpActive then
        previousSpeed = speed
        return
    end
    if UserInputService:GetFocusedTextBox() then
        previousSpeed = speed
        return
    end

    local steer = getSteerDirection()
    if steer == 0 or not velocityFlat then
        previousSpeed = speed
        return
    end

    local forward, right = getFlattenedCameraVectors()
    if not forward then
        previousSpeed = speed
        return
    end

    local wishDir = getWishDirection(forward, right)
    if not wishDir then
        previousSpeed = speed
        return
    end

    local cosTheta = speed > 0.5 and math.clamp(velocityFlat.Unit:Dot(wishDir), -1, 1) or 1

    local instantAccel = deltaTime > 0 and math.max((speed - previousSpeed) / deltaTime, 0) or 0
    if instantAccel > 0 then
        perpendicularAccelEstimate = perpendicularAccelEstimate * 0.92 + math.min(instantAccel, 120) * 0.08
    end
    previousSpeed = speed

    local turnRate = computeTurnRate(speed, cosTheta)
    if turnRate <= 0 then
        return
    end

    local pixelDelta = steer * turnRate * deltaTime * pixelsPerRadian() + pixelRemainder
    local wholePixels = math.floor(pixelDelta)
    pixelRemainder = pixelDelta - wholePixels
    if wholePixels ~= 0 then
        pcall(mousemoverel, wholePixels, 0)
    end
end))

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end
    if input.KeyCode == TOGGLE_KEY then
        enabled = not enabled
        print("[strafe_optimizer] " .. (enabled and "enabled" or "disabled"))
    end
end))

track(localPlayer.CharacterRemoving:Connect(function()
    jumpActive = false
    previousSpeed = 0
    pixelRemainder = 0
end))

print("[strafe_optimizer] loaded — auto-strafe ON (F to toggle)")