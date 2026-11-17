local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local GAME_SENSITIVITY = 0.22
local SAMPLE_RATE = 60
local RECORD_KEY = Enum.KeyCode.F5
local PLAY_KEY = Enum.KeyCode.F6
local PATH_KEY = Enum.KeyCode.F4
local ABORT_KEY = Enum.KeyCode.F8
local PANEL_KEY = Enum.KeyCode.F9
local SAVE_FOLDER = "bhop_tas"
local LATEST_FILE = SAVE_FOLDER .. "/latest.json"
local MAX_PATH_SEGMENTS = 300

local KEY_BITS = {
    [Enum.KeyCode.W] = 1,
    [Enum.KeyCode.A] = 2,
    [Enum.KeyCode.S] = 4,
    [Enum.KeyCode.D] = 8,
    [Enum.KeyCode.Space] = 16,
}
local SINGLE_KEYS = {
    { bit = 1, keyCode = Enum.KeyCode.W, virtualKey = 0x57 },
    { bit = 2, keyCode = Enum.KeyCode.A, virtualKey = 0x41 },
    { bit = 4, keyCode = Enum.KeyCode.S, virtualKey = 0x53 },
    { bit = 8, keyCode = Enum.KeyCode.D, virtualKey = 0x44 },
    { bit = 16, keyCode = Enum.KeyCode.Space, virtualKey = 0x20 },
}

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local state = "idle"
local samples = {}
local recordClock = 0
local sampleAccumulator = 0
local playbackClock = 0
local playbackSamples = nil
local playbackDuration = 0
local appliedKeyBits = 0
local pathVisible = false
local editorState = {
    gui = nil,
    open = false,
    samples = nil,
    cursorTime = 0,
    duration = 0,
    dragging = nil,
    graphFrames = { yaw = {}, pitch = {}, lanes = {} },
    cursorBar = nil,
    infoLabel = nil,
    yMin = -1, yMax = 1, pMin = -1, pMax = 1,
}

local pathSegments = {}
local pathPositions = nil

local hasMouseMoveRel = type(mousemoverel) == "function"
local hasVirtualKeys = type(keypress) == "function" and type(keyrelease) == "function"
local hasFiles = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

local function getViewAngles()
    local look = camera.CFrame.LookVector
    local yaw = math.atan2(look.Z, look.X)
    local pitch = math.asin(math.clamp(look.Y, -1, 1))
    return yaw, pitch
end

local function wrapAngle(angle)
    while angle > math.pi do
        angle -= 2 * math.pi
    end
    while angle < -math.pi do
        angle += 2 * math.pi
    end
    return angle
end

local function getKeyBitmask()
    local bits = 0
    for keyCode, bit in pairs(KEY_BITS) do
        if UserInputService:IsKeyDown(keyCode) then
            bits += bit
        end
    end
    return bits
end

local function sampleMovement()
    local character = localPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local yaw, pitch = getViewAngles()
    local position = rootPart and rootPart.Position or Vector3.zero
    return {
        t = recordClock,
        yaw = yaw,
        pitch = pitch,
        keys = getKeyBitmask(),
        pos = { position.X, position.Y, position.Z },
    }
end

local function applyKeyBits(bits)
    if not hasVirtualKeys then
        appliedKeyBits = bits
        return
    end
    for _, entry in ipairs(SINGLE_KEYS) do
        local shouldHold = bit32.band(bits, entry.bit) ~= 0
        local wasHeld = bit32.band(appliedKeyBits, entry.bit) ~= 0
        if shouldHold and not wasHeld then
            pcall(keypress, entry.virtualKey)
        elseif not shouldHold and wasHeld then
            pcall(keyrelease, entry.virtualKey)
        end
    end
    appliedKeyBits = bits
end

local function releaseAllKeys()
    applyKeyBits(0)
end

local function pixelsPerRadian()
    local fovRadians = math.rad(camera.FieldOfView)
    local zoomFactor = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) and 5 or 1
    return 128 / (GAME_SENSITIVITY * math.tan(fovRadians * 0.5)) * zoomFactor
end

local function clearPath()
    for _, segment in ipairs(pathSegments) do
        segment.drawing:Remove()
    end
    table.clear(pathSegments)
end

local function rebuildPath(positions)
    clearPath()
    pathPositions = positions
    if not positions or #positions < 2 then
        return
    end
    local stride = math.max(1, math.floor(#positions / MAX_PATH_SEGMENTS))
    for index = 1, #positions - stride, stride do
        local fromPosition = positions[index]
        local toPosition = positions[index + stride]
        local line = Drawing.new("Line")
        line.Color = Color3.fromRGB(80, 255, 255)
        line.Thickness = 2
        line.Transparency = 0.9
        line.Visible = true
        line.From = Vector2.new()
        line.To = Vector2.new()
        table.insert(pathSegments, { drawing = line, from = fromPosition, to = toPosition })
    end
end

local function updatePathProjection()
    if not pathVisible then
        for _, segment in ipairs(pathSegments) do
            segment.drawing.Visible = false
        end
        return
    end
    for _, segment in ipairs(pathSegments) do
        local fromScreen, fromVisible = camera:WorldToViewportPoint(segment.from)
        local toScreen, toVisible = camera:WorldToViewportPoint(segment.to)
        local onScreen = fromVisible and toVisible and fromScreen.Z > 0 and toScreen.Z > 0
        segment.drawing.Visible = onScreen
        if onScreen then
            segment.drawing.From = Vector2.new(fromScreen.X, fromScreen.Y)
            segment.drawing.To = Vector2.new(toScreen.X, toScreen.Y)
        end
    end
end

local function saveRecording()
    if not hasFiles then
        warn("[tas] file functions unavailable, cannot save")
        return nil
    end
    local payload = {
        name = "run_" .. os.time(),
        created = os.time(),
        sampleRate = SAMPLE_RATE,
        samples = samples,
    }
    local encoded = HttpService:JSONEncode(payload)
    local fileName = SAVE_FOLDER .. "/" .. payload.name .. ".json"
    local ok, err = pcall(writefile, fileName, encoded)
    if not ok then
        warn("[tas] save failed: " .. tostring(err))
        return nil
    end
    pcall(writefile, LATEST_FILE, encoded)
    return fileName, payload.name
end

local function loadLatestRecording()
    if not hasFiles or not isfile(LATEST_FILE) then
        return nil
    end
    local ok, raw = pcall(readfile, LATEST_FILE)
    if not ok then
        return nil
    end
    local decoded
    ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
    if not ok or type(decoded) ~= "table" or type(decoded.samples) ~= "table" then
        return nil
    end
    return decoded
end

local function interpolateSample(track, time)
    if time <= track[1].t then
        return track[1]
    end
    local last = track[#track]
    if time >= last.t then
        return last
    end
    local low, high = 1, #track
    while high - low > 1 do
        local mid = math.floor((low + high) / 2)
        if track[mid].t <= time then
            low = mid
        else
            high = mid
        end
    end
    local a, b = track[low], track[high]
    local span = b.t - a.t
    local alpha = span > 0 and (time - a.t) / span or 0
    return {
        t = time,
        yaw = a.yaw + wrapAngle(b.yaw - a.yaw) * alpha,
        pitch = a.pitch + (b.pitch - a.pitch) * alpha,
        keys = alpha < 0.5 and a.keys or b.keys,
        pos = {
            a.pos[1] + (b.pos[1] - a.pos[1]) * alpha,
            a.pos[2] + (b.pos[2] - a.pos[2]) * alpha,
            a.pos[3] + (b.pos[3] - a.pos[3]) * alpha,
        },
    }
end

local function stopPlayback(clearDrawing)
    state = "idle"
    playbackSamples = nil
    playbackClock = 0
    releaseAllKeys()
    if clearDrawing then
        clearPath()
        pathPositions = nil
        pathVisible = false
    end
end

local function startRecording()
    if state ~= "idle" then
        return
    end
    samples = {}
    recordClock = 0
    sampleAccumulator = 0
    state = "recording"
    print("[tas] recording started — press F5 to stop and save")
end

local function finishRecording()
    if state ~= "recording" then
        return
    end
    state = "idle"
    if #samples < 2 then
        warn("[tas] recording too short, discarded")
        return
    end
    local fileName, name = saveRecording()
    if fileName then
        print(("[tas] saved %d samples as %q (%s)"):format(#samples, name, fileName))
    end
end

local function startPlayback(sourceSamples, startTime)
    if state ~= "idle" then
        return
    end
    local track = sourceSamples
    if not track then
        local recording = loadLatestRecording()
        if not recording then
            warn("[tas] no latest.json found in " .. SAVE_FOLDER .. " — record first with F5")
            return
        end
        track = recording.samples
    end
    playbackSamples = track
    playbackDuration = playbackSamples[#playbackSamples].t
    playbackClock = startTime or 0
    appliedKeyBits = 0
    state = "playing"

    local positions = {}
    for _, sample in ipairs(playbackSamples) do
        positions[#positions + 1] = Vector3.new(sample.pos[1], sample.pos[2], sample.pos[3])
    end
    rebuildPath(positions)
    pathVisible = true
    print(("[tas] playback started — %d samples, %.2fs — F4 toggles path, F8 aborts"):format(#playbackSamples, playbackDuration))
end

RunService.RenderStepped:Connect(function(deltaTime)
    if state == "recording" then
        recordClock += deltaTime
        sampleAccumulator += deltaTime
        local interval = 1 / SAMPLE_RATE
        while sampleAccumulator >= interval do
            sampleAccumulator -= interval
            local sample = sampleMovement()
            sample.t = recordClock - sampleAccumulator
            samples[#samples + 1] = sample
        end
    elseif state == "playing" and playbackSamples then
        playbackClock += deltaTime
        if playbackClock >= playbackDuration then
            print("[tas] playback finished")
            stopPlayback(false)
        else
            local target = interpolateSample(playbackSamples, playbackClock)
            local currentYaw, currentPitch = getViewAngles()
            local yawDelta = wrapAngle(target.yaw - currentYaw)
            local pitchDelta = target.pitch - currentPitch
            local scale = pixelsPerRadian()
            if hasMouseMoveRel then
                local dx = yawDelta * scale
                local dy = -pitchDelta * scale
                if math.abs(dx) >= 0.5 or math.abs(dy) >= 0.5 then
                    pcall(mousemoverel, math.floor(dx + (dx >= 0 and 0.5 or -0.5)), math.floor(dy + (dy >= 0 and 0.5 or -0.5)))
                end
            end
            applyKeyBits(target.keys)
        end
    end

    updatePathProjection()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end
    if input.KeyCode == RECORD_KEY then
        if state == "recording" then
            finishRecording()
        elseif state == "idle" then
            startRecording()
        end
    elseif input.KeyCode == PLAY_KEY then
        if state == "idle" then
            local source = editorState.open and editorState.samples or nil
            startPlayback(source, editorState.open and editorState.cursorTime or 0)
        elseif state == "playing" then
            stopPlayback(false)
        end
    elseif input.KeyCode == PATH_KEY then
        pathVisible = not pathVisible
        print("[tas] path " .. (pathVisible and "shown" or "hidden"))
    elseif input.KeyCode == ABORT_KEY then
        if state == "recording" then
            state = "idle"
            samples = {}
            print("[tas] recording discarded")
        elseif state == "playing" then
            stopPlayback(true)
            print("[tas] playback aborted")
        end
    end
end)

local EDITOR_KEY = Enum.KeyCode.J
local EDITOR_WIDTH = 780
local EDITOR_CONTENT_WIDTH = 680
local GRAPH_HEIGHT = 76
local PITCH_HEIGHT = 44
local LANE_HEIGHT = 18
local MAX_GRAPH_POINTS = 110
local BRUSH_RADIUS = 5

local LANE_DEFS = {
    { label = "W", bit = 1, color = Color3.fromRGB(120, 200, 255) },
    { label = "A", bit = 2, color = Color3.fromRGB(255, 170, 120) },
    { label = "S", bit = 4, color = Color3.fromRGB(140, 255, 170) },
    { label = "D", bit = 8, color = Color3.fromRGB(255, 140, 140) },
    { label = "JUMP", bit = 16, color = Color3.fromRGB(235, 225, 120) },
}

local function clearFrames(list)
    for _, frame in ipairs(list) do
        frame:Destroy()
    end
    table.clear(list)
end

local function makeButton(parent, text, x, y, width, height)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(0, width, 0, height or 20)
    button.Position = UDim2.new(0, x, 0, y)
    button.BackgroundColor3 = Color3.fromRGB(38, 44, 60)
    button.TextColor3 = Color3.fromRGB(220, 235, 255)
    button.Font = Enum.Font.Gotham
    button.TextSize = 12
    button.Text = text
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Parent = parent
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = button
    return button
end

local function timeToX(t)
    if editorState.duration <= 0 then
        return 0
    end
    return math.clamp(t / editorState.duration, 0, 1) * EDITOR_CONTENT_WIDTH
end

local function xToTime(x)
    if editorState.duration <= 0 then
        return 0
    end
    return math.clamp(x / EDITOR_CONTENT_WIDTH, 0, 1) * editorState.duration
end

local function computeRanges()
    local samples = editorState.samples
    if not samples or #samples == 0 then
        return
    end
    local yMin, yMax = math.huge, -math.huge
    local pMin, pMax = math.huge, -math.huge
    for _, sample in ipairs(samples) do
        if sample.yaw < yMin then yMin = sample.yaw end
        if sample.yaw > yMax then yMax = sample.yaw end
        if sample.pitch < pMin then pMin = sample.pitch end
        if sample.pitch > pMax then pMax = sample.pitch end
    end
    if yMax - yMin < 0.05 then yMax = yMin + 0.05 end
    if pMax - pMin < 0.05 then pMax = pMin + 0.05 end
    editorState.yMin, editorState.yMax = yMin, yMax
    editorState.pMin, editorState.pMax = pMin, pMax
end

local function valueToY(value, min, max, height)
    return (1 - (value - min) / (max - min)) * height
end

local function rebuildGraph(kind, height, minValue, maxValue)
    local samples = editorState.samples
    local container = editorState.graphContainers and editorState.graphContainers[kind]
    if not samples or not container then
        return
    end
    local frames = editorState.graphFrames[kind]
    clearFrames(frames)
    local stride = math.max(1, math.floor(#samples / MAX_GRAPH_POINTS))
    local previous = nil
    for index = 1, #samples, stride do
        local current = samples[index]
        if previous then
            local x1 = timeToX(previous.t)
            local x2 = timeToX(current.t)
            local valueKey = kind == "yaw" and "yaw" or "pitch"
            local y1 = valueToY(previous[valueKey], minValue, maxValue, height)
            local y2 = valueToY(current[valueKey], minValue, maxValue, height)
            local dx = x2 - x1
            local dy = y2 - y1
            local length = math.sqrt(dx * dx + dy * dy)
            if length >= 1 then
                local segment = Instance.new("Frame")
                segment.AnchorPoint = Vector2.new(0.5, 0.5)
                segment.Size = UDim2.new(0, length, 0, 2)
                segment.Position = UDim2.new(0, (x1 + x2) / 2, 0, (y1 + y2) / 2)
                segment.Rotation = math.deg(math.atan2(dy, dx))
                segment.BackgroundColor3 = kind == "yaw" and Color3.fromRGB(120, 255, 160) or Color3.fromRGB(255, 220, 140)
                segment.BorderSizePixel = 0
                segment.Parent = container
                frames[#frames + 1] = segment
            end
        end
        previous = current
    end
end

local function bitIsSet(bits, bit)
    return bit32.band(bits, bit) ~= 0
end

local function rebuildLanes(width)
    local samples = editorState.samples
    for laneIndex, laneDef in ipairs(LANE_DEFS) do
        for _, bar in ipairs(editorState.graphFrames.lanes[laneIndex] or {}) do
            bar:Destroy()
        end
        editorState.graphFrames.lanes[laneIndex] = {}
        local container = editorState.laneStrips[laneIndex]
        if samples and container then
            local stride = math.max(1, math.floor(#samples / 2000))
            local runStart = nil
            for index = 1, #samples + stride, stride do
                local sample = samples[index]
                local isSet = sample ~= nil and bitIsSet(sample.keys, laneDef.bit)
                if isSet and not runStart then
                    runStart = sample.t
                elseif not isSet and runStart then
                    local bar = Instance.new("Frame")
                    bar.Size = UDim2.new(0, math.max(2, timeToX(sample.t) - timeToX(runStart)), 1, -4)
                    bar.Position = UDim2.new(0, timeToX(runStart), 0, 2)
                    bar.BackgroundColor3 = laneDef.color
                    bar.BackgroundTransparency = 0.15
                    bar.BorderSizePixel = 0
                    bar.Parent = container
                    local corner = Instance.new("UICorner")
                    corner.CornerRadius = UDim.new(0, 3)
                    corner.Parent = bar
                    editorState.graphFrames.lanes[laneIndex][#editorState.graphFrames.lanes[laneIndex] + 1] = bar
                    runStart = nil
                end
            end
        end
    end
end

local function sampleIndexAtTime(t)
    local samples = editorState.samples
    local closest = 1
    local closestDistance = math.huge
    for index, sample in ipairs(samples) do
        local distance = math.abs(sample.t - t)
        if distance < closestDistance then
            closestDistance = distance
            closest = index
        else
            break
        end
    end
    return closest
end

local function setBitRange(laneDef, fromTime, toTime, value)
    local samples = editorState.samples
    local low, high = math.min(fromTime, toTime), math.max(fromTime, toTime)
    for _, sample in ipairs(samples) do
        if sample.t >= low and sample.t <= high then
            if value then
                sample.keys = bit32.bor(sample.keys, laneDef.bit)
            else
                sample.keys = bit32.band(sample.keys, bit32.bnot(laneDef.bit))
            end
        elseif sample.t > high then
            break
        end
    end
end

local function applyValueBrush(kind, centerTime, radiansDelta)
    local samples = editorState.samples
    local centerIndex = sampleIndexAtTime(centerTime)
    for index = math.max(1, centerIndex - BRUSH_RADIUS), math.min(#samples, centerIndex + BRUSH_RADIUS) do
        local offset = math.abs(index - centerIndex)
        local weight = 0.5 + 0.5 * math.cos((offset / (BRUSH_RADIUS + 1)) * math.pi)
        local sample = samples[index]
        if kind == "yaw" then
            sample.yaw = sample.yaw + radiansDelta * weight
        else
            sample.pitch = sample.pitch + radiansDelta * weight
        end
    end
end

local function updateInfoLabel(text)
    if editorState.infoLabel then
        editorState.infoLabel.Text = text
    end
end

local function updateInfo()
    local samples = editorState.samples
    if not samples then
        updateInfoLabel("No recording loaded — press F5 to record, or open after recording something.")
        return
    end
    updateInfoLabel(string.format("%d samples · %.2fs · cursor %.2fs · yaw %.2f..%.2f · pitch %.2f..%.2f",
        #samples, editorState.duration, editorState.cursorTime,
        editorState.yMin, editorState.yMax, editorState.pMin, editorState.pMax))
end

local function updateCursor()
    if editorState.cursorBar then
        editorState.cursorBar.Position = UDim2.new(0, timeToX(editorState.cursorTime) - 1, 0, 0)
    end
end

local function rebuildAll()
    computeRanges()
    rebuildGraph("yaw", GRAPH_HEIGHT, editorState.yMin, editorState.yMax)
    rebuildGraph("pitch", PITCH_HEIGHT, editorState.pMin, editorState.pMax)
    rebuildLanes()
    updateCursor()
    updateInfo()
end

local function loadEditorRecording()
    local recording = loadLatestRecording()
    if not recording then
        editorState.samples = nil
        editorState.duration = 0
        updateInfo()
        return false
    end
    editorState.samples = recording.samples
    editorState.duration = recording.samples[#recording.samples].t
    editorState.cursorTime = 0
    rebuildAll()
    return true
end

local function saveEditorEdit()
    local samples = editorState.samples
    if not samples then
        return
    end
    if not hasFiles then
        warn("[tas] cannot save — file functions unavailable")
        return
    end
    local payload = {
        name = "run_" .. os.time() .. "_edit",
        created = os.time(),
        sampleRate = SAMPLE_RATE,
        samples = samples,
    }
    local encoded = HttpService:JSONEncode(payload)
    local fileName = SAVE_FOLDER .. "/" .. payload.name .. ".json"
    local ok, err = pcall(writefile, fileName, encoded)
    if not ok then
        warn("[tas] edit save failed: " .. tostring(err))
        return
    end
    pcall(writefile, LATEST_FILE, encoded)
    print(("[tas] edit saved as %s (also written to latest.json)"):format(payload.name))
end

local function buildEditorGui()
    local gui = Instance.new("ScreenGui")
    gui.Name = "TasTimelineEditor"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.Size = UDim2.new(0, EDITOR_WIDTH, 0, 348)
    panel.Position = UDim2.new(0.5, 0, 0, 10)
    panel.AnchorPoint = Vector2.new(0.5, 0)
    panel.BackgroundColor3 = Color3.fromRGB(16, 17, 24)
    panel.BackgroundTransparency = 0.12
    panel.BorderSizePixel = 0
    panel.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(0, EDITOR_WIDTH, 0, 26)
    title.Position = UDim2.new(0, 0, 0, 4)
    title.BackgroundTransparency = 1
    title.Text = "TAS TIMELINE EDITOR"
    title.TextColor3 = Color3.fromRGB(120, 255, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.Parent = panel

    local info = Instance.new("TextLabel")
    info.Size = UDim2.new(0, EDITOR_WIDTH - 20, 0, 14)
    info.Position = UDim2.new(0, 10, 1, -16)
    info.BackgroundTransparency = 1
    info.Text = ""
    info.TextColor3 = Color3.fromRGB(160, 170, 185)
    info.Font = Enum.Font.Gotham
    info.TextSize = 11
    info.TextXAlignment = Enum.TextXAlignment.Left
    info.Parent = panel
    editorState.infoLabel = info

    local function actionButton(text, x, width, callback)
        local button = makeButton(panel, text, x, 4, width, 22)
        button.MouseButton1Click:Connect(callback)
        return button
    end

    actionButton("Preview", 470, 60, function()
        if state == "playing" then
            stopPlayback(false)
        elseif editorState.samples then
            startPlayback(editorState.samples, editorState.cursorTime)
        end
    end)
    actionButton("From Start", 536, 68, function()
        if state == "idle" and editorState.samples then
            startPlayback(editorState.samples, 0)
        end
    end)
    actionButton("Save Edit", 610, 66, saveEditorEdit)
    actionButton("Close", 682, 44, function()
        gui.Enabled = false
        editorState.open = false
    end)

    local contentX = (EDITOR_WIDTH - EDITOR_CONTENT_WIDTH) / 2
    local cursorStrip = Instance.new("Frame")
    cursorStrip.Name = "CursorStrip"
    cursorStrip.Size = UDim2.new(0, EDITOR_CONTENT_WIDTH, 0, 10)
    cursorStrip.Position = UDim2.new(0, contentX, 0, 32)
    cursorStrip.BackgroundColor3 = Color3.fromRGB(28, 30, 40)
    cursorStrip.BorderSizePixel = 0
    cursorStrip.Parent = panel
    local cursorBar = Instance.new("Frame")
    cursorBar.Size = UDim2.new(0, 3, 1, 0)
    cursorBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    cursorBar.BorderSizePixel = 0
    cursorBar.ZIndex = 5
    cursorBar.Parent = cursorStrip
    editorState.cursorBar = cursorBar

    local function makeGraphContainer(name, labelText, y, height)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0, contentX - 8, 0, 14)
        label.Position = UDim2.new(0, 6, 0, y)
        label.BackgroundTransparency = 1
        label.Text = labelText
        label.TextColor3 = Color3.fromRGB(180, 190, 205)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 11
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = panel
        local container = Instance.new("Frame")
        container.Name = name
        container.Size = UDim2.new(0, EDITOR_CONTENT_WIDTH, 0, height)
        container.Position = UDim2.new(0, contentX, 0, y)
        container.BackgroundColor3 = Color3.fromRGB(22, 23, 32)
        container.BorderSizePixel = 0
        container.ClipsDescendants = true
        container.Parent = panel
        return container
    end

    editorState.graphContainers = {
        yaw = makeGraphContainer("YawGraph", "YAW", 46, GRAPH_HEIGHT),
        pitch = makeGraphContainer("PitchGraph", "PITCH", 46 + GRAPH_HEIGHT + 8, PITCH_HEIGHT),
    }

    local laneTop = 46 + GRAPH_HEIGHT + 8 + PITCH_HEIGHT + 8
    local laneStrips = {}
    for laneIndex, laneDef in ipairs(LANE_DEFS) do
        local laneY = laneTop + (laneIndex - 1) * (LANE_HEIGHT + 2)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0, contentX - 8, 0, LANE_HEIGHT)
        label.Position = UDim2.new(0, 6, 0, laneY)
        label.BackgroundTransparency = 1
        label.Text = laneDef.label
        label.TextColor3 = laneDef.color
        label.Font = Enum.Font.GothamBold
        label.TextSize = 12
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = panel
        local strip = Instance.new("Frame")
        strip.Name = "Lane_" .. laneDef.label
        strip.Size = UDim2.new(0, EDITOR_CONTENT_WIDTH, 0, LANE_HEIGHT)
        strip.Position = UDim2.new(0, contentX, 0, laneY)
        strip.BackgroundColor3 = Color3.fromRGB(24, 25, 34)
        strip.BorderSizePixel = 0
        strip.ClipsDescendants = true
        strip.Parent = panel
        laneStrips[laneIndex] = strip
    end
    editorState.laneStrips = laneStrips

    local help = Instance.new("TextLabel")
    help.Size = UDim2.new(0, EDITOR_WIDTH - 20, 0, 12)
    help.Position = UDim2.new(0, 10, 1, -32)
    help.BackgroundTransparency = 1
    help.Text = "Drag on YAW/PITCH: bend curve (5-sample brush) · Drag on a key lane: paint / erase, drag segment edges to extend · Click anywhere: set scrub cursor"
    help.TextColor3 = Color3.fromRGB(130, 140, 155)
    help.Font = Enum.Font.Gotham
    help.TextSize = 10
    help.Parent = panel

    local function localX(frame, input)
        local position = frame.AbsolutePosition
        return input.Position.X - position.X, input.Position.Y - position.Y
    end

    local function beginYawDrag(frame, input)
        editorState.dragging = { kind = "yaw", lastY = input.Position.Y, moved = false, downX = input.Position.X, downY = input.Position.Y }
    end
    local function beginPitchDrag(frame, input)
        editorState.dragging = { kind = "pitch", lastY = input.Position.Y, moved = false, downX = input.Position.X, downY = input.Position.Y }
    end
    local function beginLaneDrag(frame, laneIndex, input)
        local laneDef = LANE_DEFS[laneIndex]
        local x = localX(frame, input)
        local t = xToTime(x)
        local drag = { kind = "lane", lane = laneIndex, bit = laneDef.bit, startTime = t, lastTime = t, mode = "paint", moved = false }
        local segments = {}
        local samples = editorState.samples
        if samples then
            local stride = math.max(1, math.floor(#samples / 2000))
            local runStart = nil
            for index = 1, #samples + stride, stride do
                local sample = samples[index]
                local isSet = sample ~= nil and bitIsSet(sample.keys, laneDef.bit)
                if isSet and not runStart then
                    runStart = sample.t
                elseif not isSet and runStart then
                    segments[#segments + 1] = { t0 = runStart, t1 = sample.t }
                    runStart = nil
                end
            end
        end
        local edgeTolerance = 6 / EDITOR_CONTENT_WIDTH * editorState.duration
        for _, segment in ipairs(segments) do
            if math.abs(t - segment.t0) <= edgeTolerance then
                drag.mode = "edge"
                drag.edge = "left"
                drag.segment = segment
                editorState.dragging = drag
                return
            elseif math.abs(t - segment.t1) <= edgeTolerance then
                drag.mode = "edge"
                drag.edge = "right"
                drag.segment = segment
                editorState.dragging = drag
                return
            elseif t > segment.t0 and t < segment.t1 then
                drag.mode = "erase"
                editorState.dragging = drag
                return
            end
        end
        editorState.dragging = drag
    end
    local function beginCursorDrag(frame, input)
        editorState.dragging = { kind = "cursor" }
        local x = localX(frame, input)
        editorState.cursorTime = xToTime(x)
        updateCursor()
        updateInfo()
    end

    editorState.graphContainers.yaw.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            beginYawDrag(editorState.graphContainers.yaw, input)
        end
    end)
    editorState.graphContainers.pitch.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            beginPitchDrag(editorState.graphContainers.pitch, input)
        end
    end)
    cursorStrip.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            beginCursorDrag(cursorStrip, input)
        end
    end)
    for laneIndex in ipairs(laneStrips) do
        laneStrips[laneIndex].InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                beginLaneDrag(laneStrips[laneIndex], laneIndex, input)
            end
        end)
    end

    UserInputService.InputChanged:Connect(function(input)
        local drag = editorState.dragging
        if not drag or input.UserInputType ~= Enum.UserInputType.MouseMovement then
            return
        end
        if drag.kind == "yaw" or drag.kind == "pitch" then
            local deltaY = drag.lastY - input.Position.Y
            drag.lastY = input.Position.Y
            if math.abs(input.Position.X - (drag.downX or input.Position.X)) > 2 or deltaY ~= 0 then
                drag.moved = true
            end
            local samples = editorState.samples
            if not samples then
                return
            end
            local range = (drag.kind == "yaw" and (editorState.yMax - editorState.yMin) or (editorState.pMax - editorState.pMin))
            local height = drag.kind == "yaw" and GRAPH_HEIGHT or PITCH_HEIGHT
            local radiansDelta = (deltaY / height) * math.max(range, 0.05)
            local x = localX(editorState.graphContainers[drag.kind], input)
            applyValueBrush(drag.kind, xToTime(x), radiansDelta)
            rebuildGraph(drag.kind, height,
                drag.kind == "yaw" and editorState.yMin or editorState.pMin,
                drag.kind == "yaw" and editorState.yMax or editorState.pMax)
            updateInfo()
        elseif drag.kind == "lane" then
            local strip = laneStrips[drag.lane]
            local x = localX(strip, input)
            local t = xToTime(x)
            local laneDef = LANE_DEFS[drag.lane]
            if drag.mode == "edge" then
                local edgeT = drag.edge == "left" and drag.segment.t0 or drag.segment.t1
                local low, high = math.min(edgeT, t), math.max(edgeT, t)
                local expanding = t > edgeT
                if drag.edge == "left" then
                    expanding = t < edgeT
                end
                setBitRange(laneDef, low, high, expanding)
                if drag.edge == "left" then
                    drag.segment.t0 = t
                else
                    drag.segment.t1 = t
                end
            else
                setBitRange(laneDef, drag.startTime, t, drag.mode ~= "erase")
            end
            drag.lastTime = t
            drag.moved = true
            rebuildLanes()
            updateInfo()
        elseif drag.kind == "cursor" then
            local x = localX(cursorStrip, input)
            editorState.cursorTime = xToTime(x)
            updateCursor()
            updateInfo()
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        local drag = editorState.dragging
        if not drag or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
            return
        end
        if (drag.kind == "yaw" or drag.kind == "pitch") and not drag.moved then
            local container = editorState.graphContainers[drag.kind]
            local x = localX(container, input)
            editorState.cursorTime = xToTime(x)
            updateCursor()
            updateInfo()
        end
        editorState.dragging = nil
    end)

    local parent = pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui") or localPlayer:WaitForChild("PlayerGui")
    gui.Parent = parent
    return gui
end

local function toggleEditor()
    if not editorState.gui then
        editorState.gui = buildEditorGui()
    end
    editorState.open = not editorState.open
    editorState.gui.Enabled = editorState.open
    if editorState.open then
        if not editorState.samples then
            loadEditorRecording()
        else
            rebuildAll()
        end
        print("[tas] editor opened — J closes · drag YAW/PITCH to bend · drag lanes to paint/erase · drag segment edges to extend holds")
    else
        print("[tas] editor closed")
    end
end

local function createKeybindPanel()
    local panelGui = Instance.new("ScreenGui")
    panelGui.Name = "TasKeybindPanel"
    panelGui.ResetOnSpawn = false
    panelGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.Size = UDim2.new(0, 260, 0, 150)
    container.Position = UDim2.new(0, 16, 1, -166)
    container.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    container.BackgroundTransparency = 0.25
    container.BorderSizePixel = 0
    container.Parent = panelGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = container

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 10)
    padding.PaddingTop = UDim.new(0, 8)
    padding.Parent = container

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -10, 0, 18)
    title.BackgroundTransparency = 1
    title.Text = "TAS Recorder"
    title.TextColor3 = Color3.fromRGB(120, 255, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = container

    local bindings = {
        { "F5", "Record / Stop + Save" },
        { "F6", "Play / Stop Playback" },
        { "F4", "Toggle Path Line" },
        { "F8", "Abort (discard / stop)" },
        { "F9", "Toggle This Panel" },
        { "J", "Toggle Timeline Editor" },
    }
    for index, binding in ipairs(bindings) do
        local row = Instance.new("TextLabel")
        row.Size = UDim2.new(1, -10, 0, 17)
        row.Position = UDim2.new(0, 0, 0, 20 + (index - 1) * 18)
        row.BackgroundTransparency = 1
        row.Text = binding[1] .. "  —  " .. binding[2]
        row.TextColor3 = Color3.fromRGB(225, 225, 225)
        row.Font = Enum.Font.Gotham
        row.TextSize = 12
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.Parent = container
    end

    local parent = pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui") or localPlayer:WaitForChild("PlayerGui")
    panelGui.Parent = parent
    return panelGui, container
end

local keybindPanel, keybindContainer = createKeybindPanel()

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end
    if input.KeyCode == PANEL_KEY then
        keybindContainer.Visible = not keybindContainer.Visible
    elseif input.KeyCode == EDITOR_KEY then
        toggleEditor()
    end
end)

localPlayer.CharacterRemoving:Connect(function()
    if state == "playing" then
        stopPlayback(false)
        warn("[tas] playback stopped — character removed")
    elseif state == "recording" then
        state = "idle"
        samples = {}
        warn("[tas] recording discarded — character removed")
    end
end)

print("[tas] recorder loaded — F5 record/stop+save · F6 play/stop · F4 path · F8 abort · F9 panel · J timeline editor")