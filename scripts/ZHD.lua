--- keybinds: 
-- F2: Master Toggle, F3: Decrease FOV, F4: Increase FOV, F5: Change Aiming Part

local FOV_STEP = 10
local FOV_MIN = 10
local FOV_MAX = 1000
local LOS_CHECK = true
local AIM_ONLY_OWN_SHOTS = true

local TARGET_MODES = {
    { id = "Head", label = "Head", parts = { "Head" } },
    { id = "Torso", label = "Torso", parts = { "UpperTorso", "Torso" } },
    { id = "LowerTorso", label = "LowerTorso", parts = { "LowerTorso" } },
    { id = "HumanoidRootPart", label = "HumanoidRootPart", parts = { "HumanoidRootPart" } },
    { id = "LeftArm", label = "Left Arm", parts = { "LeftUpperArm", "LeftArm", "Left Arm" } },
    { id = "RightArm", label = "Right Arm", parts = { "RightUpperArm", "RightArm", "Right Arm" } },
    { id = "LeftLeg", label = "Left Leg", parts = { "LeftUpperLeg", "LeftLeg", "Left Leg" } },
    { id = "RightLeg", label = "Right Leg", parts = { "RightUpperLeg", "RightLeg", "Right Leg" } },
    { id = "ClosestPart", label = "Closest Part" },
    { id = "ClosestPoint", label = "Closest Point" },
}

local COLOR_ENEMY = Color3.fromRGB(255, 70, 70)
local COLOR_TRACER = Color3.fromRGB(255, 255, 255)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

if _G.ZHD and _G.ZHD.unload then
    pcall(_G.ZHD.unload)
end

local state = {
    unloaded = false,
    connections = {},
    drawings = {},
    tracer = nil,
    settings = {
        enabled = true,
        fov = 500,
        showBoxes = true,
        showNames = true,
        showHealth = true,
        showTracer = true,
        targetIndex = 1,
    },
    currentTarget = nil,
    tracerLabel = nil,
    announcement = nil,
    announcementUntil = 0,
}

local MainModule = require(ReplicatedStorage:WaitForChild("MainModule"))

local function track(connection)
    state.connections[#state.connections + 1] = connection
    return connection
end

-- Enemy detection

local function isFriendly(otherPlayer)
    local ok, result = pcall(MainModule.CheckTeam, localPlayer, otherPlayer)
    return ok and result == true
end

local function isEnemy(otherPlayer)
    if otherPlayer == localPlayer then
        return false
    end
    local character = otherPlayer.Character
    if not character then
        return false
    end
    if isFriendly(otherPlayer) then
        return false
    end
    local bodyEffects = character:FindFirstChild("BodyEffects")
    if bodyEffects then
        local k = bodyEffects:FindFirstChild("K.O")
        local d = bodyEffects:FindFirstChild("Dead")
        if (k and k.Value) or (d and d.Value) then
            return false
        end
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

local function getAimableParts(character)
    local parts = {}
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart")
            and not descendant:FindFirstAncestorOfClass("Accessory")
            and not descendant:FindFirstAncestorOfClass("Tool") then
            parts[#parts + 1] = descendant
        end
    end
    return parts
end

local function getMouseRay()
    local mouse = localPlayer:GetMouse()
    local unitRay = camera:ScreenPointToRay(mouse.X, mouse.Y)
    return unitRay.Origin, unitRay.Direction.Unit
end

local function closestPointOnPartToRay(part, rayOrigin, rayDir)
    local half = part.Size * 0.5
    local localOrigin = part.CFrame:PointToObjectSpace(rayOrigin)
    local localDir = part.CFrame:VectorToObjectSpace(rayDir).Unit

    local t = math.max(0, -localOrigin:Dot(localDir))
    local point = localOrigin + localDir * t
    for _ = 1, 20 do
        local clamped = Vector3.new(
            math.clamp(point.X, -half.X, half.X),
            math.clamp(point.Y, -half.Y, half.Y),
            math.clamp(point.Z, -half.Z, half.Z)
        )
        local nextT = math.max(0, (clamped - localOrigin):Dot(localDir))
        local nextPoint = localOrigin + localDir * nextT
        if (nextPoint - point).Magnitude < 1e-5 then
            point = nextPoint
            break
        end
        point = nextPoint
    end

    local clamped = Vector3.new(
        math.clamp(point.X, -half.X, half.X),
        math.clamp(point.Y, -half.Y, half.Y),
        math.clamp(point.Z, -half.Z, half.Z)
    )
    return part.CFrame:PointToWorldSpace(clamped)
end

local function resolveByPartNames(character, partNames)
    for _, name in ipairs(partNames) do
        local part = character:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            return part.Position, part.Name
        end
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    if root then
        return root.Position, "HumanoidRootPart"
    end
    return nil, nil
end

local function getClosestPartAim(character, mousePos)
    local bestPart, bestDistance
    for _, part in ipairs(getAimableParts(character)) do
        local viewportPoint, onScreen = camera:WorldToViewportPoint(part.Position)
        if onScreen then
            local distance = (Vector2.new(viewportPoint.X, viewportPoint.Y) - mousePos).Magnitude
            if not bestDistance or distance < bestDistance then
                bestDistance = distance
                bestPart = part
            end
        end
    end
    if bestPart then
        return bestPart.Position, bestPart.Name, bestDistance
    end
    return nil, nil, nil
end

local function getClosestPointAim(character, rayOrigin, rayDir, mousePos)
    local bestPoint, bestPartName, bestDistance
    for _, part in ipairs(getAimableParts(character)) do
        local point = closestPointOnPartToRay(part, rayOrigin, rayDir)
        local viewportPoint, onScreen = camera:WorldToViewportPoint(point)
        if onScreen then
            local distance = (Vector2.new(viewportPoint.X, viewportPoint.Y) - mousePos).Magnitude
            if not bestDistance or distance < bestDistance then
                bestDistance = distance
                bestPoint = point
                bestPartName = part.Name
            end
        end
    end
    return bestPoint, bestPartName, bestDistance
end

local function getEnemyEntries()
    local entries = {}
    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if isEnemy(otherPlayer) then
            local character = otherPlayer.Character
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            local rootPart = character:FindFirstChild("HumanoidRootPart")
            if humanoid and rootPart then
                entries[#entries + 1] = {
                    player = otherPlayer,
                    character = character,
                    humanoid = humanoid,
                    rootPart = rootPart,
                }
            end
        end
    end
    return entries
end

local function getCurrentMode()
    return TARGET_MODES[state.settings.targetIndex] or TARGET_MODES[1]
end

local function getBestTarget()
    local mouse = localPlayer:GetMouse()
    local mousePos = Vector2.new(mouse.X, mouse.Y)
    local mode = getCurrentMode()

    local rayOrigin, rayDir
    if mode.id == "ClosestPoint" then
        rayOrigin, rayDir = getMouseRay()
    end

    local best = nil
    local bestScreenDistance = state.settings.fov

    for _, entry in ipairs(getEnemyEntries()) do
        local aimPoint, aimPartName, screenDistance

        if mode.id == "ClosestPart" then
            aimPoint, aimPartName, screenDistance = getClosestPartAim(entry.character, mousePos)
        elseif mode.id == "ClosestPoint" then
            aimPoint, aimPartName, screenDistance = getClosestPointAim(entry.character, rayOrigin, rayDir, mousePos)
        else
            aimPoint, aimPartName = resolveByPartNames(entry.character, mode.parts)
            if aimPoint then
                local viewportPoint, onScreen = camera:WorldToViewportPoint(aimPoint)
                if onScreen then
                    screenDistance = (Vector2.new(viewportPoint.X, viewportPoint.Y) - mousePos).Magnitude
                end
            end
        end

        if aimPoint and screenDistance and screenDistance <= bestScreenDistance then
            best = {
                player = entry.player,
                character = entry.character,
                humanoid = entry.humanoid,
                rootPart = entry.rootPart,
                aimPoint = aimPoint,
                aimPartName = aimPartName,
                modeLabel = mode.label,
                modeId = mode.id,
            }
            bestScreenDistance = screenDistance
        end
    end

    return best
end

local function hasClearLineOfFire(origin, targetPosition, targetCharacter, range)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true

    local exclude = {}
    local lpCharacter = localPlayer.Character
    if lpCharacter then
        for _, descendant in ipairs(lpCharacter:GetDescendants()) do
            if descendant:IsA("BasePart") then
                exclude[#exclude + 1] = descendant
            end
        end
    end
    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if otherPlayer ~= localPlayer and not isEnemy(otherPlayer) and otherPlayer.Character then
            for _, descendant in ipairs(otherPlayer.Character:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    exclude[#exclude + 1] = descendant
                end
            end
        end
    end

    params.FilterDescendantsInstances = exclude
    local direction = targetPosition - origin
    local result = Workspace:Raycast(origin, direction.Unit * math.min(range or 500, direction.Magnitude), params)
    if not result then
        return true
    end
    return result.Instance:IsDescendantOf(targetCharacter)
end

-- ESP

local function newBundle()
    local bundle = {
        box = Drawing.new("Square"),
        name = Drawing.new("Text"),
        health = Drawing.new("Text"),
    }
    bundle.box.Filled = false
    bundle.box.Thickness = 1.5
    bundle.box.Color = COLOR_ENEMY
    bundle.box.Transparency = 1
    bundle.box.Visible = false

    bundle.name.Size = 13
    bundle.name.Center = true
    bundle.name.Outline = true
    bundle.name.Color = Color3.fromRGB(255, 255, 255)
    bundle.name.Font = 2
    bundle.name.Visible = false

    bundle.health.Size = 12
    bundle.health.Center = true
    bundle.health.Outline = true
    bundle.health.Color = Color3.fromRGB(120, 220, 120)
    bundle.health.Font = 2
    bundle.health.Visible = false

    return bundle
end

local function getBundle(player)
    if not state.drawings[player] then
        state.drawings[player] = newBundle()
    end
    return state.drawings[player]
end

local function removeBundle(player)
    local bundle = state.drawings[player]
    if not bundle then
        return
    end
    for _, drawing in pairs(bundle) do
        pcall(function()
            drawing:Remove()
        end)
    end
    state.drawings[player] = nil
end

local function measureCharacter(character)
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    local head = character:FindFirstChild("Head")
    if not rootPart or not head then
        return nil
    end

    local topY = head.Position.Y + head.Size.Y * 0.5

    local function footBottomY()
        local lowest
        for _, name in ipairs({ "LeftFoot", "RightFoot", "Left Leg", "Right Leg" }) do
            local leg = character:FindFirstChild(name)
            if leg then
                local bottom = leg.Position.Y - leg.Size.Y * 0.5
                lowest = lowest and math.min(lowest, bottom) or bottom
            end
        end
        return lowest or (rootPart.Position.Y - 3)
    end

    local bottomY = footBottomY()
    local center = Vector3.new(rootPart.Position.X, (topY + bottomY) * 0.5, rootPart.Position.Z)
    local topPoint = Vector3.new(rootPart.Position.X, topY, rootPart.Position.Z)
    local bottomPoint = Vector3.new(rootPart.Position.X, bottomY, rootPart.Position.Z)

    local topScreen = camera:WorldToViewportPoint(topPoint)
    local bottomScreen = camera:WorldToViewportPoint(bottomPoint)
    local centerScreen = camera:WorldToViewportPoint(center)

    if centerScreen.Z <= 0 then
        return nil
    end

    local heightPixels = bottomScreen.Y - topScreen.Y
    if heightPixels < 2 then
        return nil
    end

    local worldHeight = math.max(0.5, topY - bottomY)
    local upperTorso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    local worldWidth = (upperTorso and upperTorso.Size.X or 2) * 1.6
    local widthPixels = heightPixels * (worldWidth / worldHeight)

    return centerScreen.X - widthPixels * 0.5, topScreen.Y, widthPixels, heightPixels, rootPart
end

local function updateEsp()
    for _, entry in ipairs(getEnemyEntries()) do
        local player = entry.player
        local bundle = state.drawings[player]

        if not state.settings.enabled then
            removeBundle(player)
            continue
        end

        local minX, minY, width, height, rootPart = measureCharacter(entry.character)
        if not minX or not rootPart then
            removeBundle(player)
            continue
        end

        bundle = getBundle(player)
        local show = state.settings.enabled

        if state.settings.showBoxes then
            bundle.box.Position = Vector2.new(minX, minY)
            bundle.box.Size = Vector2.new(width, height)
            bundle.box.Color = COLOR_ENEMY
            bundle.box.Visible = show
        else
            bundle.box.Visible = false
        end

        local distance = (rootPart.Position - camera.CFrame.Position).Magnitude

        if state.settings.showNames then
            bundle.name.Text = ("%s [%dm]"):format(player.Name, math.floor(distance))
            bundle.name.Position = Vector2.new(minX + width * 0.5, minY - 15)
            bundle.name.Visible = show
        else
            bundle.name.Visible = false
        end

        if state.settings.showHealth then
            bundle.health.Text = ("HP %d/%d"):format(math.floor(entry.humanoid.Health), math.floor(entry.humanoid.MaxHealth))
            bundle.health.Position = Vector2.new(minX + width * 0.5, minY + height + 2)
            bundle.health.Color = Color3.fromRGB(120 + math.floor(135 * (1 - entry.humanoid.Health / math.max(1, entry.humanoid.MaxHealth))), 220, 120)
            bundle.health.Visible = show
        else
            bundle.health.Visible = false
        end
    end

    -- knocked/dead/friendly/left players must not keep their boxes: if a drawn player is no longer a valid enemy, purge it
    for player in pairs(state.drawings) do
        if player.Parent ~= Players or not isEnemy(player) then
            removeBundle(player)
        end
    end
end

-- Target tracer

local function getTracerLabel()
    if not state.tracerLabel then
        local text = Drawing.new("Text")
        text.Size = 13
        text.Center = true
        text.Outline = true
        text.Color = COLOR_TRACER
        text.Font = 2
        text.Visible = false
        state.tracerLabel = text
    end
    return state.tracerLabel
end

local function getAnnouncement()
    if not state.announcement then
        local text = Drawing.new("Text")
        text.Size = 17
        text.Center = true
        text.Outline = true
        text.Color = Color3.fromRGB(255, 230, 120)
        text.Font = 2
        text.Visible = false
        state.announcement = text
    end
    return state.announcement
end

local function getTracer()
    if not state.tracer then
        local line = Drawing.new("Line")
        line.Color = COLOR_TRACER
        line.Thickness = 1.5
        line.Transparency = 1
        line.Visible = false
        state.tracer = line
    end
    return state.tracer
end

local function hideTracer()
    if state.tracer then
        state.tracer.Visible = false
    end
    if state.tracerLabel then
        state.tracerLabel.Visible = false
    end
end

local function updateTracer()
    local target = state.currentTarget
    local shouldShow = state.settings.enabled and state.settings.showTracer and target ~= nil and localPlayer.Character

    if not shouldShow then
        hideTracer()
        return
    end

    local localRoot = localPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not localRoot then
        hideTracer()
        return
    end

    local targetPosition = target.aimPoint
    local p1, on1 = camera:WorldToViewportPoint(localRoot.Position)
    local p2, on2 = camera:WorldToViewportPoint(targetPosition)
    local tracer = getTracer()
    local label = getTracerLabel()

    if on1 and on2 then
        tracer.From = Vector2.new(p1.X, p1.Y)
        tracer.To = Vector2.new(p2.X, p2.Y)
        tracer.Visible = true

        if target.modeId == "ClosestPart" or target.modeId == "ClosestPoint" then
            label.Text = ("%s · %s"):format(target.modeLabel, target.aimPartName)
        else
            label.Text = target.aimPartName
        end
        label.Position = Vector2.new(p2.X, p2.Y - 18)
        label.Visible = true
    else
        hideTracer()
    end
end

-- Silent aim hook

local SPREAD_KEEP = 0.5

local GunHandler = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("GunHandler"))
local originalTrace = rawget(GunHandler, "Trace")
assert(originalTrace, "GunHandler.Trace not found")

local function getSilentAimPoint(config, origin, targetPosition)
    if typeof(origin) ~= "Vector3" then
        return targetPosition
    end

    local aimLockPart = config.AimLockPart
    if typeof(aimLockPart) == "Instance" and aimLockPart:IsA("BasePart") and aimLockPart.Parent then
        return targetPosition
    end

    local originalAim = config.AimPosition
    local range = tonumber(config.Range) or 200
    if typeof(originalAim) ~= "Vector3" or range <= 0 then
        return targetPosition
    end

    local getAim = rawget(GunHandler, "GetAim")
    if type(getAim) ~= "function" then
        return targetPosition
    end

    local ok, baseDir = pcall(getAim, origin)
    if not ok or typeof(baseDir) ~= "Vector3" then
        return targetPosition
    end

    -- recovers the shotgun pellet's original spread offset (v41 in GunClientShotgun)
    local spread = (originalAim - origin) / range - baseDir
    if spread.Magnitude > 0.5 then
        return targetPosition
    end

    local toTarget = targetPosition - origin
    if toTarget.Magnitude < 0.001 then
        return targetPosition
    end

    return origin + (toTarget.Unit + spread * SPREAD_KEEP) * range
end

local wrappedTrace
wrappedTrace = newcclosure(function(config)
    if not state.unloaded and type(config) == "table" and state.settings.enabled then
        local shooter = config.Shooter
        local isOwnShot = not AIM_ONLY_OWN_SHOTS or shooter == localPlayer.Character

        if isOwnShot then
            local best = getBestTarget()
            if best then
                local origin = config.ForcedOrigin
                if typeof(origin) ~= "Vector3" then
                    local handle = config.Handle
                    if handle and handle:FindFirstChild("Muzzle") then
                        origin = handle.Muzzle.WorldPosition
                    end
                end

                local clear = true
                if LOS_CHECK and typeof(origin) == "Vector3" then
                    clear = hasClearLineOfFire(origin, best.aimPoint, best.character, config.Range)
                end

                if clear then
                    config.AimPosition = getSilentAimPoint(config, origin, best.aimPoint)
                end
            end
        end
    end

    return originalTrace(config)
end)
setstackhidden(wrappedTrace, true)
rawset(GunHandler, "Trace", wrappedTrace)

-- No jump cooldown

local JUMP_RESCAN_INTERVAL = 30
local jumpAntiSpamFn = nil
local jumpRescanCountdown = 0

local function isJumpAntiSpamHandler(fn)
    if type(fn) ~= "function" then
        return false
    end
    local okConstants, constants = pcall(debug.getconstants, fn)
    if not okConstants or type(constants) ~= "table" then
        return false
    end

    local stringCount = 0
    local sawTick = false
    for _, value in ipairs(constants) do
        if type(value) == "string" then
            stringCount += 1
            if value == "tick" then
                sawTick = true
            end
        end
    end
    if not sawTick or stringCount ~= 1 then
        return false
    end

    local okUpvalues, upvalues = pcall(debug.getupvalues, fn)
    if not okUpvalues or type(upvalues) ~= "table" then
        return false
    end

    local counter = upvalues[1]
    if type(counter) ~= "table" then
        return false
    end

    return rawget(counter, "Time") ~= nil
        and rawget(counter, "Timer") ~= nil
        and type(upvalues[2]) == "boolean"
end

local function findJumpAntiSpamHandler()
    local humanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil
    end
    local okConnections, connections = pcall(getconnections, humanoid.Jumping)
    if not okConnections or type(connections) ~= "table" then
        return nil
    end
    for _, connection in ipairs(connections) do
        local fn = connection.Function
        if type(fn) == "function" and isJumpAntiSpamHandler(fn) then
            return fn
        end
    end
    return nil
end

local function resetJumpAntiSpam()
    if not jumpAntiSpamFn then
        jumpAntiSpamFn = findJumpAntiSpamHandler()
    end
    local fn = jumpAntiSpamFn
    if not fn then
        return
    end
    pcall(debug.setupvalue, fn, 2, false)
    local okUpvalues, upvalues = pcall(debug.getupvalues, fn)
    if okUpvalues and type(upvalues) == "table" and type(upvalues[1]) == "table" then
        rawset(upvalues[1], "Time", 0)
    end
end

local function maintenanceJumpAntiSpam()
    jumpRescanCountdown -= 1
    if jumpRescanCountdown <= 0 then
        jumpRescanCountdown = JUMP_RESCAN_INTERVAL
        jumpAntiSpamFn = nil
    end
    resetJumpAntiSpam()
end

local function disableJumpCooldownForCharacter(character)
    jumpAntiSpamFn = nil
    jumpRescanCountdown = 0
    resetJumpAntiSpam()

    local bodyEffects = character:FindFirstChild("BodyEffects")
    local movement = bodyEffects and bodyEffects:FindFirstChild("Movement")
    if movement then
        local noJumping = movement:FindFirstChild("NoJumping")
        if noJumping then
            pcall(function()
                noJumping:Destroy()
            end)
        end
        track(movement.ChildAdded:Connect(function(child)
            if child.Name == "NoJumping" then
                pcall(function()
                    child:Destroy()
                end)
            end
        end))
    end
end

if localPlayer.Character then
    disableJumpCooldownForCharacter(localPlayer.Character)
end
track(localPlayer.CharacterAdded:Connect(function(character)
    character:WaitForChild("Humanoid", 5)
    disableJumpCooldownForCharacter(character)
end))

-- Unload / main loop

local function removeAllDrawings()
    for player in pairs(state.drawings) do
        removeBundle(player)
    end
    for _, drawingName in ipairs({ "tracer", "tracerLabel", "announcement" }) do
        if state[drawingName] then
            pcall(function()
                state[drawingName]:Remove()
            end)
            state[drawingName] = nil
        end
    end
end

local function onUnload()
    if state.unloaded then
        return
    end
    state.unloaded = true
    for _, connection in ipairs(state.connections) do
        pcall(connection.Disconnect, connection)
    end
    state.connections = {}
    removeAllDrawings()
    pcall(rawset, GunHandler, "Trace", originalTrace)
    jumpAntiSpamFn = nil
    _G.ZHD = nil
end

_G.ZHD = { unload = onUnload }

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end

    if input.KeyCode == Enum.KeyCode.F2 then
        state.settings.enabled = not state.settings.enabled
        if not state.settings.enabled then
            removeAllDrawings()
        end
    elseif input.KeyCode == Enum.KeyCode.F3 then
        state.settings.fov = math.clamp(state.settings.fov - FOV_STEP, FOV_MIN, FOV_MAX)
    elseif input.KeyCode == Enum.KeyCode.F4 then
        state.settings.fov = math.clamp(state.settings.fov + FOV_STEP, FOV_MIN, FOV_MAX)
    elseif input.KeyCode == Enum.KeyCode.F5 then
        state.settings.targetIndex = (state.settings.targetIndex % #TARGET_MODES) + 1
        local mode = getCurrentMode()
        local announcement = getAnnouncement()
        announcement.Text = "Target: " .. mode.label
        state.announcementUntil = tick() + 1.6
    end
end))

track(RunService.RenderStepped:Connect(function()
    if state.unloaded then
        return
    end
    camera = Workspace.CurrentCamera

    pcall(maintenanceJumpAntiSpam)
    state.currentTarget = getBestTarget()
    pcall(updateEsp)
    pcall(updateTracer)

    if state.announcement then
        local show = tick() < state.announcementUntil
        if show then
            local announcement = state.announcement
            announcement.Position = Vector2.new(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.78)
            announcement.Visible = true
        else
            state.announcement.Visible = false
        end
    end
end))
