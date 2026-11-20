local BASE_URL = "https://raw.githubusercontent.com/extremelyconstrained/free-lua-scripts/main/"

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local function loadScript(path)
	local url = BASE_URL .. path
	local ok, source = pcall(game.HttpGet, game, url)
	if not ok or type(source) ~= "string" or #source == 0 then
		warn("[loader] Failed to fetch " .. path)
		return
	end
	local chunk, compileError = loadstring(source)
	if not chunk then
		warn("[loader] Failed to compile " .. path .. ": " .. tostring(compileError))
		return
	end
	local runOk, runtimeError = pcall(chunk)
	if not runOk then
		warn("[loader] Error running " .. path .. ": " .. tostring(runtimeError))
	end
end

local scriptsByPlace = {
	[14044547200] = { "scripts/UntitledTagGame.lua" },
	[18667984660] = { "scripts/FlexFPS%26Ping.lua" },
	[134728380684025] = { "scripts/AislesOfTheLocust.lua" },
	[119925538689885] = { "scripts/StealOrDie.lua" },
	[698448212] = { "scripts/Robeats.lua" },
	[138014591158268] = { "scripts/ZHD.lua" },
	[72897745776800] = { "scripts/ZHD.lua" },
	[12355337193] = { "scripts/MVSD.lua" },
	[18687417158] = { "scripts/Forsaken.lua" },
	[106560117662077] = { "scripts/Forsaken.lua" },
	[83645629621104] = { "scripts/Forsaken.lua" },
	[94626476208514] = { "scripts/Forsaken.lua" },
	[86454545238517] = { "scripts/Forsaken.lua" },
}

local function getGuiParent()
	local gethuiOk, hui = pcall(function()
		return gethui()
	end)
	if gethuiOk and hui then
		return hui
	end
	local coreGuiOk, coreGui = pcall(function()
		return game:GetService("CoreGui")
	end)
	if coreGuiOk and coreGui then
		return coreGui
	end
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function promptGraceMode()
	local parent = getGuiParent()

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GraceLoaderPrompt"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "Prompt"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(320, 150)
	frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 40)
	title.Position = UDim2.fromOffset(0, 8)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.Text = "Grace — select mode"
	title.Parent = frame

	local function makeButton(text, position, color)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0.5, -16, 0, 44)
		button.Position = position
		button.BackgroundColor3 = color
		button.BorderSizePixel = 0
		button.Font = Enum.Font.GothamBold
		button.TextSize = 16
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.Text = text
		button.Parent = frame

		local buttonCorner = Instance.new("UICorner")
		buttonCorner.CornerRadius = UDim.new(0, 6)
		buttonCorner.Parent = button

		return button
	end

	local normalButton = makeButton("Normal", UDim2.new(0, 12, 1, -56), Color3.fromRGB(60, 120, 220))
	local zenButton = makeButton("Zen", UDim2.new(0.5, 4, 1, -56), Color3.fromRGB(140, 70, 220))

	local function select(path)
		screenGui:Destroy()
		loadScript(path)
	end

	normalButton.Activated:Connect(function()
		select("scripts/Grace/GraceNormal.lua")
	end)
	zenButton.Activated:Connect(function()
		select("scripts/Grace/GraceZen.lua")
	end)

	screenGui.Parent = parent
end

local placeId = game.PlaceId

if placeId == 110333320616502 then
	promptGraceMode()
elseif scriptsByPlace[placeId] then
	for _, path in ipairs(scriptsByPlace[placeId]) do
		loadScript(path)
	end
else
	warn("[loader] Unsupported place id: " .. tostring(placeId))
end
