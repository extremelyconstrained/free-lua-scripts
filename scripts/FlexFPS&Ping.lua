local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer

local SPOOF = {
	Enabled = true,

	FPS = {
		Mode = "range", -- "off" | "constant" | "range"
		Constant = 9999,
		Min = 10440,
		Max = 11608,
		Drift = 24, -- linear step per second; triangle-wave between Min/Max
		SpoofBillboard = true,
	},

	Platform = {
		Mode = "preset", -- "off" | "preset"
		-- Windows/Linux/Mobile/Console/VR fingerprints (see PLATFORM_PRESETS)
		Preset = "Linux",
		VersionOverride = nil, -- keep the real version() string; mismatches may flag
	},

	Ping = {
		-- The game samples the client's Data Ping, not Network Ping
		Value = 12,
		HookStats = true,
		LocalDisplay = true, -- HUD IntValues only
		HighestPing = 12,
		LowestPing = 12,
	},
}

local BIT = bit32

local SEEDS = { 2166136261, 3735928559, 2654435769, 1374496523 }

local MIXERS = {
	function(a, b)
		local x = BIT.bxor(a, b)
		x = BIT.bxor(x, BIT.lshift(x, 13))
		x = BIT.bxor(x, BIT.rshift(x, 17))
		x = BIT.bxor(x, BIT.lshift(x, 5))
		return BIT.bxor(x, 2654435769)
	end,
	function(a, b)
		local x = BIT.bxor(a + b, 2246822507)
		x = BIT.bxor(x, BIT.rshift(x, 15))
		x = BIT.bxor(x, BIT.lshift(x, 7))
		return BIT.bxor(x, BIT.rshift(x, 11))
	end,
	function(a, b)
		local x = a + BIT.bxor(b, 3266489909)
		x = BIT.band(x, 4294967295)
		x = BIT.bxor(x, BIT.lshift(x, 9))
		x = BIT.bxor(x, BIT.rshift(x, 21))
		return BIT.bxor(x, 668265263)
	end,
	function(a, b)
		local t = BIT.band(b * 3, 4294967295)
		local x = BIT.bxor(a, t)
		x = BIT.bxor(x, BIT.rshift(x, 7))
		x = BIT.bxor(x, BIT.lshift(x, 11))
		x = BIT.bxor(x, BIT.rshift(x, 19))
		return BIT.bxor(x, 374761393)
	end,
}

local function norm(x)
	return math.floor((tonumber(x) or 0) * 100) % 4294967296
end

local function sign(variant, ...)
	local mixer = MIXERS[variant] or MIXERS[1]
	local seed = SEEDS[variant] or SEEDS[1]
	for i = 1, select("#", ...) do
		seed = mixer(seed, norm(select(i, ...)))
	end
	return seed
end

local function veil(value, mask)
	local rot = mask % 31 + 1
	local x = BIT.bxor(value % 4294967296, mask) % 4294967296
	local hi = BIT.lshift(x, rot)
	local lo = BIT.rshift(x, 32 - rot)
	return (BIT.bor(hi, lo) % 4294967296 + mask) % 4294967296
end

local function unveil(value, mask)
	local rot = mask % 31 + 1
	local tmp = (value - mask) % 4294967296
	local lo = BIT.rshift(tmp, rot)
	local hi = BIT.lshift(tmp, 32 - rot)
	local x = BIT.bor(lo, hi) % 4294967296
	return BIT.bxor(x, mask)
end

local function strNum(s)
	local acc = 0
	s = tostring(s)
	for i = 1, #s do
		acc = (acc + s:byte(i) * i) % 4294967296
	end
	return acc
end

local function boolBit(v)
	return v and 1 or 0
end

local REAL_KEYS = { "bq", "dm", "hs", "kp", "nx", "rv", "tw", "zc" }
-- rawMetrics = { seq, frameDelta, fps, mem*100, resX, resY, quality, probe|integrity }

local function hideStack(fn)
	pcall(setstackhidden, fn, true)
	return fn
end

local meow = ReplicatedStorage:FindFirstChild("meow")
local nya = ReplicatedStorage:FindFirstChild("nya")

local session = { secret = nil, variant = nil, ok = false }

local function tryCaptureUpvalues(fn)
	local ok, upvalues = pcall(debug.getupvalues, fn)
	if not ok then return end
	for _, upvalue in ipairs(upvalues) do
		if type(upvalue) == "table"
			and type(rawget(upvalue, "secret")) == "number"
			and type(rawget(upvalue, "variant")) == "number"
			and type(rawget(upvalue, "seq")) == "number"
		then
			session.secret = upvalue.secret
			session.variant = upvalue.variant
			session.ok = true
			return true
		end
	end
end

if meow then
	local okConns, conns = pcall(getconnections, meow.OnClientEvent)
	if okConns and conns then
		for _, connection in ipairs(conns) do
			if tryCaptureUpvalues(connection.Function) then break end
		end
	end
	if not session.ok then
		local okGc, found = pcall(filtergc, "table", { keys = { "secret", "variant", "seq", "ca", "cb" } }, true)
		if okGc and type(found) == "table" then
			session.secret = found.secret
			session.variant = found.variant
			session.ok = true
		end
	end
end

local function refreshSession()
	if not meow then return end
	local okConns, conns = pcall(getconnections, meow.OnClientEvent)
	if not okConns or not conns then return end
	for _, connection in ipairs(conns) do
		local ok, upvalues = pcall(debug.getupvalues, connection.Function)
		if ok then
			for _, upvalue in ipairs(upvalues) do
				if type(upvalue) == "table" and type(rawget(upvalue, "secret")) == "number" then
					session.secret, session.variant = upvalue.secret, upvalue.variant
					return
				end
			end
		end
	end
end

local fpsWalk = { value = nil, direction = -1, lastStep = 0 }

local function spoofFps()
	local f = SPOOF.FPS
	if f.Mode == "constant" then return f.Constant end
	if f.Mode ~= "range" then return nil end
	if not fpsWalk.value then fpsWalk.value = f.Max end
	local now = os.clock()
	if now - fpsWalk.lastStep >= 1 then
		fpsWalk.lastStep = now
		fpsWalk.value = fpsWalk.value + fpsWalk.direction * f.Drift
		if fpsWalk.value >= f.Max then
			fpsWalk.value = f.Max
			fpsWalk.direction = -1
		elseif fpsWalk.value <= f.Min then
			fpsWalk.value = f.Min
			fpsWalk.direction = 1
		end
	end
	return fpsWalk.value
end

local PLATFORM_PRESETS = {
	Windows = { A = false, B = false, C = true,  E = false, F = false, G = true,  H = true,  I = true },
	Linux   = { A = false, B = false, C = false, E = false, F = false, G = true,  H = true,  I = true },
	Mobile  = { A = false, B = false, C = false, E = true,  F = true,  G = false, H = false, I = true },
	Console = { A = false, B = true,  C = false, E = false, F = false, G = false, H = false, I = true },
	VR      = { A = true,  B = false, C = true,  E = false, F = false, G = true,  H = true,  I = true },
}

local function forgeMetrics(packet)
	if not session.ok then refreshSession() end
	if not session.ok then return false end
	local secret, variant, token = session.secret, session.variant, packet.token
	if type(token) ~= "number" then return false end

	local rawMetrics = {}
	for i = 1, 8 do
		rawMetrics[i] = unveil(packet[REAL_KEYS[i]] or 0, sign(variant, secret, token, i))
	end

	local fps = spoofFps()
	if fps then rawMetrics[3] = math.clamp(fps, 0, 1000000) end

	for i = 1, 8 do
		packet[REAL_KEYS[i]] = veil(rawMetrics[i], sign(variant, secret, token, i))
	end

	packet.fps = rawMetrics[3]
	packet.mem = rawMetrics[4] / 100
	packet.res = Vector2.new(rawMetrics[5], rawMetrics[6])

	local metricsMixer = variant % #MIXERS + 1
	packet.sig = sign(metricsMixer, secret, rawMetrics[1], token, rawMetrics[3], rawMetrics[4] / 100, rawMetrics[5], rawMetrics[6], rawMetrics[7])
	packet.ck = sign(variant, secret, token, unpack(rawMetrics))

	return true
end

local function forgeDevice(packet)
	if SPOOF.Platform.Mode ~= "preset" then return false end
	local preset = PLATFORM_PRESETS[SPOOF.Platform.Preset]
	if not preset then return false end
	if not session.ok then refreshSession() end
	if not session.ok then return false end

	local secret, variant, token = session.secret, session.variant, packet.token
	if type(token) ~= "number" then return false end

	local device = packet.tbl
	if type(device) ~= "table" then return false end

	device.A, device.B, device.C, device.E, device.F, device.G, device.H, device.I =
		preset.A, preset.B, preset.C, preset.E, preset.F, preset.G, preset.H, preset.I
	if SPOOF.Platform.VersionOverride then device.D = SPOOF.Platform.VersionOverride end

	packet.sig = sign(variant, secret, token,
		boolBit(device.A), boolBit(device.B), boolBit(device.C), strNum(device.D),
		boolBit(device.E), boolBit(device.F), boolBit(device.G), boolBit(device.H), boolBit(device.I))
	return true
end

-- hookfunction swaps the C closure body in place (identity preserved), which
-- is what the anti-cheat captured at load. Do NOT hook __namecall — that trips
-- the namecallInstance detector and gets you kicked.
if nya then
	local oldFireServer
	local fireServerHook
	fireServerHook = hideStack(function(self, packet, ...)
		if SPOOF.Enabled and type(packet) == "table" then
			if packet.t == "metrics" then
				pcall(forgeMetrics, packet)
			elseif packet.t == "device" then
				pcall(forgeDevice, packet)
			end
		end
		return oldFireServer(self, packet, ...)
	end)
	local okHook, err = pcall(function()
		oldFireServer = hookfunction(nya.FireServer, fireServerHook)
	end)
	if not okHook or not oldFireServer then
		warn("[spoof] hookfunction on nya.FireServer failed:", err, "— spoof disabled")
		oldFireServer = nil
	end
else
	warn("[spoof] nya remote not found — packet spoof disabled")
end

-- Data Ping only. Instance-method hooks (Stats:GetNetworkPing etc.) are the
-- same call shape the namecallInstance detector watches — leave them off.
if SPOOF.Ping.HookStats then
	pcall(function()
		local okDataPing, dataPing = pcall(function()
			return Stats.Network.ServerStatsItem["Data Ping"].GetValue
		end)
		if okDataPing and dataPing and hookfunction then
			local okHook, err = pcall(function()
				hookfunction(dataPing, hideStack(newcclosure(function()
					return SPOOF.Ping.Value
				end)))
			end)
			if okHook then
				print("[spoof] Data Ping hooked ->", SPOOF.Ping.Value, "ms")
			else
				warn("[spoof] Data Ping hook failed:", err)
			end
		end
	end)
end

if SPOOF.Ping.LocalDisplay then
	local data = LocalPlayer:FindFirstChild("Data")
	if data then
		local highest = data:FindFirstChild("HighestPing")
		local lowest = data:FindFirstChild("LowestPing")
		local function apply()
			if highest then highest.Value = SPOOF.Ping.HighestPing end
			if lowest then lowest.Value = SPOOF.Ping.LowestPing end
		end
		apply()
		if highest then highest.Changed:Connect(apply) end
		if lowest then lowest.Changed:Connect(apply) end
	else
		warn("[spoof] Data folder not found yet — ping HUD override skipped")
	end
end

if SPOOF.FPS.SpoofBillboard then
	task.spawn(hideStack(function()
		while true do
			task.wait(0.25)
			local fps = spoofFps()
			local character = LocalPlayer.Character
			local head = character and character:FindFirstChild("Head")
			local fpsGui = head and head:FindFirstChild("fpsGui")
			local fpsLabel = fpsGui and fpsGui:FindFirstChild("FPS")
			if fpsLabel and fps then
				fpsLabel.Text = tostring(fps)
			end
		end
	end))
end

print("[spoof] loaded — FPS mode:", SPOOF.FPS.Mode,
	"| platform:", SPOOF.Platform.Mode == "preset" and SPOOF.Platform.Preset or "off",
	"| ping:", SPOOF.Ping.HookStats and ("Data Ping -> " .. SPOOF.Ping.Value .. "ms") or "hook off",
	SPOOF.Ping.LocalDisplay and "(+HUD)" or "")