-- Leon-finder  |  LeonFinder.lua  |  Roblox executor
-- UI: hitam + biru | 480x380 | loading instan | resize di kanan bawah

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
if not player then
	player = Players.PlayerAdded:Wait()
end
local playerGui = player:WaitForChild("PlayerGui", 8)
if not playerGui then
	warn("[Leon-finder] PlayerGui not found - aborting")
	return
end

-- hapus UI lama kalau script dijalankan ulang
do
	local old = playerGui:FindFirstChild("LeonFinder")
	if old then old:Destroy() end
end

-- ─── CONFIG ───────────────────────────────────────────────────────────────
local API_URL = "https://privatedontleakorelsejejjkeo3333.lovable.app/api/getPets"
local REFRESH_INTERVAL = 1
local MAX_ITEMS = 300
local DEFAULT_RARITY = "Secret"
local FORCE_INTERVAL = 3
local TITLE = "Leon-finder"
local AUTHOR = "Sources Hub Team"
local DISCORD_LINK = "https://discord.gg/REbuVnr4qt"

local POST_URL = "https://privatedontleakorelsejejjkeo3333.lovable.app/api/addPet"
local AUTO_POST = true
local POST_MIN_VALUE = 50000000
local POST_SCAN_INTERVAL = 8
local POST_COOLDOWN = 300
local POST_FIRST_DELAY = 6 -- scan pertama ditunda supaya UI muncul mulus dulu

local W_START, H_START = 480, 380
local W_MIN, W_MAX, H_MIN, H_MAX = 380, 720, 300, 520

-- ─── PALETTE (hitam + biru) ────────────────────────────────────────────────
local WHITE       = Color3.fromRGB(255, 255, 255)
local ACCENT_HI   = Color3.fromRGB(90, 170, 255)
local ACCENT      = Color3.fromRGB(40, 120, 255)
local ACCENT_DARK = Color3.fromRGB(20, 55, 130)
local ACCENT_DEEP = Color3.fromRGB(10, 25, 60)
local SUB_TEXT    = Color3.fromRGB(160, 180, 210)
local MUTED       = Color3.fromRGB(100, 120, 150)
local BG_BLACK    = Color3.fromRGB(0, 0, 0)
local BG_PANEL    = Color3.fromRGB(6, 8, 13)

local FONT_BOLD = Enum.Font.GothamBold
local FONT_MED  = Enum.Font.GothamMedium

-- ─── HELPERS ───────────────────────────────────────────────────────────────
local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	if parent then inst.Parent = parent end
	return inst
end

local function corner(parent, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function stroke(parent, color, thickness, transparency)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function gradient(parent, c0, c1, rotation)
	return new("UIGradient", {
		Color = ColorSequence.new(c0, c1),
		Rotation = rotation or 0,
	}, parent)
end

local function accentStroke(parent, thickness, transparency)
	local s = stroke(parent, WHITE, thickness, transparency)
	gradient(s, ACCENT_HI, ACCENT_DARK, 90)
	return s
end

local function label(parent, text, size, font, color, pos, sz, alignX)
	return new("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		Font = font,
		TextColor3 = color,
		Position = pos,
		Size = sz,
		TextXAlignment = alignX or Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}, parent)
end

local function button(parent, o)
	local bg = new("Frame", {
		AnchorPoint = o.anchor or Vector2.new(0, 0),
		Position = o.pos or UDim2.new(),
		Size = o.size,
		LayoutOrder = o.order or 0,
		BackgroundColor3 = WHITE,
		BackgroundTransparency = o.bgTransparency or 0,
		BorderSizePixel = 0,
	}, parent)
	corner(bg, o.radius or 8)
	gradient(bg, o.c0, o.c1, o.rotation or 90)
	if o.strokeColor then
		stroke(bg, o.strokeColor, o.strokeThickness or 1.2, o.strokeTransparency or 0)
	end
	local btn = new("TextButton", {
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = o.text,
		TextSize = o.textSize or 12,
		Font = FONT_BOLD,
		TextColor3 = o.textColor or WHITE,
		BorderSizePixel = 0,
	}, bg)
	return btn, bg
end

local function formatValue(v)
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if v >= u[1] then
			return ("$%.1f%s/s"):format(v / u[1], u[2])
		end
	end
	return ("$%d/s"):format(math.floor(v))
end

local function formatAge(tsMs)
	local s = math.max(0, math.floor(os.time() - tsMs / 1000))
	return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

local function richColor(c)
	return ("rgb(%d,%d,%d)"):format(
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5))
end

local function escapeRich(s)
	return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function httpGet(url)
	local okR, res = pcall(function()
		local fn = (syn and syn.request) or http_request or request
		if fn then
			return fn({ Url = url, Method = "GET" })
		end
		return nil
	end)
	if okR and res and res.Body then return res.Body end
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if ok and body then return body end
	local ok2, body2 = pcall(function() return HttpService:GetAsync(url) end)
	if ok2 then return body2 end
	return nil
end

-- ─── GUI ROOT + LOADING (tampil PALING AWAL, sebelum apa pun yang berat) ───
local gui = new("ScreenGui", {
	Name = "LeonFinder",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
	DisplayOrder = 50,
}, playerGui)

local loading = new("CanvasGroup", {
	Name = "Loading",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = BG_BLACK,
	BackgroundTransparency = 0.25,
	GroupTransparency = 0,
	ZIndex = 100,
}, gui)
local loadCard = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(260, 92),
	BackgroundColor3 = BG_BLACK,
	BorderSizePixel = 0,
	ZIndex = 101,
}, loading)
corner(loadCard, 12)
accentStroke(loadCard, 1.4, 0)
local loadTitle = label(loadCard, TITLE, 16, FONT_BOLD, ACCENT_HI,
	UDim2.fromOffset(0, 10), UDim2.new(1, 0, 0, 24), Enum.TextXAlignment.Center)
loadTitle.ZIndex = 102
local loadStatus = label(loadCard, "Memulai...", 11, FONT_MED, SUB_TEXT,
	UDim2.fromOffset(0, 36), UDim2.new(1, 0, 0, 18), Enum.TextXAlignment.Center)
loadStatus.ZIndex = 102
local loadTrack = new("Frame", {
	Position = UDim2.new(0, 20, 1, -22),
	Size = UDim2.new(1, -40, 0, 6),
	BackgroundColor3 = ACCENT_DEEP,
	BorderSizePixel = 0,
	ZIndex = 102,
}, loadCard)
corner(loadTrack, 3)
local loadFill = new("Frame", {
	Size = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = ACCENT_HI,
	BorderSizePixel = 0,
	ZIndex = 103,
}, loadTrack)
corner(loadFill, 3)
local loadPct = label(loadCard, "0%", 9, FONT_BOLD, WHITE,
	UDim2.new(0, 20, 1, -38), UDim2.new(1, -40, 0, 12), Enum.TextXAlignment.Right)
loadPct.ZIndex = 102

local function setProgress(p, text)
	loadStatus.Text = text
	loadPct.Text = math.floor(p * 100) .. "%"
	TweenService:Create(loadFill, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
		Size = UDim2.new(p, 0, 1, 0),
	}):Play()
	task.wait() -- beri 1 frame supaya loading benar-benar tergambar
end

setProgress(0.15, "Memuat pengaturan...")

-- shared state (dideklarasikan di atas supaya semua fungsi bisa memakainya)
local render, startForce, stopForce

-- ─── BLACKLIST ─────────────────────────────────────────────────────────────
local blacklist = {}
local blacklistFile = "LeonFinder_Blacklist.json"
local blacklistMode = false
local showingBlacklistPanel = false

local function loadBlacklist()
	if isfile and readfile and isfile(blacklistFile) then
		local ok, data = pcall(function()
			return HttpService:JSONDecode(readfile(blacklistFile))
		end)
		if ok and type(data) == "table" then
			for _, name in ipairs(data) do
				if type(name) == "string" and name ~= "" then
					blacklist[name] = true
				end
			end
		end
	end
end

local function saveBlacklist()
	if not writefile then return end
	local arr = {}
	for name in pairs(blacklist) do
		arr[#arr + 1] = name
	end
	table.sort(arr)
	pcall(function()
		writefile(blacklistFile, HttpService:JSONEncode(arr))
	end)
end

local function isBlacklisted(e)
	return e and e.name and blacklist[e.name] == true
end

loadBlacklist()

-- ─── ASSET CACHE (di latar belakang, tidak menahan UI) ─────────────────────
local rarityByName, colorByName = {}, {}
local displayByName, iconByName = {}, {}

local function findIcon(e)
	for _, k in ipairs({ "Icon", "IconId", "Image", "ImageId", "Thumbnail" }) do
		local v = e[k]
		if v ~= nil then
			local id = tostring(v):match("(%d%d%d%d%d+)")
			if id then return id end
		end
	end
	return nil
end

task.spawn(function()
	local ok, err = pcall(function()
		local dataFolder = ReplicatedStorage:WaitForChild("Data", 4)
		if not dataFolder then error("Data folder missing") end
		local assetsModule = dataFolder:WaitForChild("Assets", 4)
		if not assetsModule then error("Assets module missing") end
		local Assets = require(assetsModule)
		if type(Assets) ~= "table" or type(Assets.Directory) ~= "table" then
			error("Assets.Directory missing")
		end
		for id, e in pairs(Assets.Directory) do
			if type(e) == "table" and type(e.Rarity) == "table" then
				local r = e.Rarity.DisplayName or e.Rarity._id
				local icon = findIcon(e)
				rarityByName[id] = r
				colorByName[id] = e.Rarity.Color
				displayByName[id] = e.DisplayName or tostring(id)
				iconByName[id] = icon
				if e.DisplayName then
					rarityByName[e.DisplayName] = r
					colorByName[e.DisplayName] = e.Rarity.Color
					displayByName[e.DisplayName] = e.DisplayName
					iconByName[e.DisplayName] = icon
				end
			end
		end
	end)
	if not ok then
		warn("[Leon-finder] Assets load failed (fallback):", err)
	end
end)

local function getRarity(petName)
	return rarityByName[petName]
end

local function getRarityColor(petName)
	local c = colorByName[petName]
	if typeof(c) == "Color3" then return c end
	return nil
end

setProgress(0.4, "Membangun tampilan...")

-- ─── MAIN WINDOW ───────────────────────────────────────────────────────────
local main = new("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(W_START, H_START),
	BackgroundColor3 = BG_BLACK,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Visible = true,
}, gui)
corner(main, 12)
accentStroke(main, 1.5, 0)

-- Drag: dari sidebar atau strip atas (bukan dari daftar feed, supaya scroll tidak bentrok)
do
	local dragging, dragStart, startPos
	main.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			local rel = Vector2.new(input.Position.X, input.Position.Y) - main.AbsolutePosition
			if rel.X < 140 or rel.Y < 36 then
				dragging = true
				dragStart = input.Position
				startPos = main.Position
			end
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- ─── SIDEBAR ───────────────────────────────────────────────────────────────
local sidebar = new("Frame", {
	Name = "Sidebar",
	Size = UDim2.new(0, 140, 1, 0),
	BackgroundColor3 = BG_PANEL,
	BorderSizePixel = 0,
}, main)

local divider = new("Frame", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 0),
	Size = UDim2.new(0, 1, 1, 0),
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
}, sidebar)
gradient(divider, ACCENT_HI, ACCENT_DARK, 90)

local titleLabel = label(sidebar, TITLE, 15, FONT_BOLD, WHITE,
	UDim2.fromOffset(12, 12), UDim2.fromOffset(120, 22))
gradient(titleLabel, WHITE, ACCENT_HI, 0)

new("Frame", {
	Position = UDim2.fromOffset(13, 44),
	Size = UDim2.fromOffset(6, 6),
	BackgroundColor3 = ACCENT_HI,
	BorderSizePixel = 0,
}, sidebar)
local statusLabel = label(sidebar, "Memuat data...", 9, FONT_MED, SUB_TEXT,
	UDim2.fromOffset(25, 39), UDim2.fromOffset(108, 16))
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd

-- kolom tombol: tersusun otomatis, jarak sama
local btnCol = new("Frame", {
	Position = UDim2.fromOffset(8, 64),
	Size = UDim2.new(1, -16, 0, 4 * 30 + 3 * 8),
	BackgroundTransparency = 1,
}, sidebar)
new("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, btnCol)

local PRIMARY = { c0 = ACCENT, c1 = ACCENT_DARK, strokeColor = ACCENT_HI, strokeTransparency = 0.15 }
local SECOND = {
	c0 = Color3.fromRGB(16, 26, 48), c1 = Color3.fromRGB(8, 12, 22),
	strokeColor = ACCENT, strokeTransparency = 0.3,
}
local function sideButton(text, order, style)
	local o = {
		text = text, textSize = 10, order = order,
		size = UDim2.new(1, 0, 0, 30), radius = 7,
	}
	for k, v in pairs(style) do o[k] = v end
	return button(btnCol, o)
end

local blModeBtn = sideButton("Blacklist", 1, PRIMARY)
local unblBtn = sideButton("Unblacklist", 2, SECOND)
local COPY_TEXT = "Copy Discord"
local copyBtn = sideButton(COPY_TEXT, 3, SECOND)
local hideBtn = sideButton("Hide", 4, SECOND)

-- info bawah sidebar (menempel ke bawah, ikut saat UI di-resize)
local postLabel = label(sidebar, "Scan:0 Post:0", 8, FONT_MED, MUTED,
	UDim2.new(0, 12, 1, -22), UDim2.fromOffset(120, 14))
postLabel.TextTruncate = Enum.TextTruncate.AtEnd
local authorLabel = label(sidebar, "Author: " .. AUTHOR, 9, FONT_BOLD, SUB_TEXT,
	UDim2.new(0, 12, 1, -40), UDim2.fromOffset(120, 16))
authorLabel.TextTruncate = Enum.TextTruncate.AtEnd

-- ─── CONTENT ───────────────────────────────────────────────────────────────
local content = new("Frame", {
	Name = "Content",
	Position = UDim2.fromOffset(148, 0),
	Size = UDim2.new(1, -148, 1, 0),
	BackgroundTransparency = 1,
}, main)
-- area dalam dengan margin kanan 12 supaya semua elemen sejajar
local inner = new("Frame", {
	Name = "Inner",
	Position = UDim2.fromOffset(0, 12),
	Size = UDim2.new(1, -12, 1, -24),
	BackgroundTransparency = 1,
}, content)

-- ─── BLACKLIST PANEL ───────────────────────────────────────────────────────
local blPanel = new("Frame", {
	Name = "BlacklistPanel",
	Position = UDim2.fromOffset(148, 0),
	Size = UDim2.new(1, -148, 1, 0),
	BackgroundColor3 = BG_BLACK,
	Visible = false,
	ZIndex = 20,
}, main)
label(blPanel, "BLACKLISTED PETS", 12, FONT_BOLD, ACCENT_HI,
	UDim2.fromOffset(12, 10), UDim2.new(1, -90, 0, 24)).ZIndex = 21
local blClose = button(blPanel, {
	text = "Close",
	textSize = 10,
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -12, 0, 9),
	size = UDim2.fromOffset(60, 26),
	c0 = ACCENT_DARK,
	c1 = ACCENT_DEEP,
	strokeColor = ACCENT,
	radius = 6,
})
blClose.ZIndex = 22
local blScroll = new("ScrollingFrame", {
	Position = UDim2.fromOffset(12, 44),
	Size = UDim2.new(1, -24, 1, -56),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = ACCENT,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ZIndex = 21,
}, blPanel)
new("UIListLayout", {
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.Name,
}, blScroll)

local function refreshBlacklistPanel()
	for _, c in ipairs(blScroll:GetChildren()) do
		if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
	end
	local names = {}
	for name in pairs(blacklist) do
		names[#names + 1] = name
	end
	table.sort(names)
	if #names == 0 then
		label(blScroll, "No blacklisted pets", 12, FONT_MED, MUTED,
			UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 30)).ZIndex = 22
		return
	end
	for _, name in ipairs(names) do
		local row = new("Frame", {
			Name = name,
			Size = UDim2.new(1, -4, 0, 36),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			ZIndex = 22,
		}, blScroll)
		corner(row, 7)
		gradient(row, Color3.fromRGB(18, 28, 50), Color3.fromRGB(8, 12, 22), 0)
		label(row, name, 12, FONT_BOLD, WHITE,
			UDim2.fromOffset(10, 0), UDim2.new(1, -90, 1, 0)).ZIndex = 23
		local ub = button(row, {
			text = "Remove",
			textSize = 9,
			anchor = Vector2.new(1, 0.5),
			pos = UDim2.new(1, -6, 0.5, 0),
			size = UDim2.fromOffset(70, 24),
			c0 = ACCENT,
			c1 = ACCENT_DARK,
			strokeColor = ACCENT_HI,
			radius = 5,
		})
		ub.ZIndex = 24
		ub.MouseButton1Click:Connect(function()
			blacklist[name] = nil
			saveBlacklist()
			statusLabel.Text = "Unblacklisted: " .. tostring(name):sub(1, 12)
			refreshBlacklistPanel()
			render()
		end)
	end
end

-- ─── SHOW / HIDE ───────────────────────────────────────────────────────────
local showBtn, showBg = button(gui, {
	text = TITLE,
	textSize = 12,
	anchor = Vector2.new(0.5, 0),
	pos = UDim2.new(0.5, 0, 0, 12),
	size = UDim2.fromOffset(140, 28),
	c0 = Color3.fromRGB(20, 40, 90),
	c1 = Color3.fromRGB(4, 8, 18),
	strokeColor = ACCENT,
	strokeTransparency = 0.2,
	radius = 8,
})
showBg.Visible = false

hideBtn.MouseButton1Click:Connect(function()
	main.Visible = false
	showBg.Visible = true
end)
showBtn.MouseButton1Click:Connect(function()
	main.Visible = true
	showBg.Visible = false
end)

-- ─── TOGGLE ROW ────────────────────────────────────────────────────────────
local TRACK_OFF = Color3.fromRGB(30, 36, 50)
local function toggleCard(text, side, onChanged)
	local card = new("Frame", {
		Position = side == 0 and UDim2.new(0, 0, 0, 0) or UDim2.new(0.5, 4, 0, 0),
		Size = UDim2.new(0.5, -4, 0, 40),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
	}, inner)
	corner(card, 8)
	gradient(card, Color3.fromRGB(14, 22, 42), Color3.fromRGB(6, 9, 16), 0)
	accentStroke(card, 1, 0.25)

	label(card, text, 11, FONT_BOLD, WHITE,
		UDim2.fromOffset(10, 0), UDim2.new(1, -62, 1, 0))

	local track = new("TextButton", {
		AutoButtonColor = false,
		Text = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(42, 22),
		BackgroundColor3 = TRACK_OFF,
		BorderSizePixel = 0,
	}, card)
	corner(track, 11)
	stroke(track, ACCENT_DARK, 1, 0.25)

	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
	}, track)
	corner(knob, 8)

	local state = false
	local info = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	track.MouseButton1Click:Connect(function()
		state = not state
		TweenService:Create(knob, info, {
			Position = state and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
		}):Play()
		TweenService:Create(track, info, {
			BackgroundColor3 = state and ACCENT or TRACK_OFF,
		}):Play()
		if onChanged then onChanged(state) end
	end)
	return card
end

local autoJoinState, autoForceState = false, false
local lastAutoJoinJob = nil
local forceKey, forceJobId, forceRun = nil, nil, 0

toggleCard("Auto-Join", 0, function(v)
	autoJoinState = v
	render()
end)
toggleCard("Auto-Force", 1, function(v)
	autoForceState = v
	if not v then stopForce() end
	render()
end)

-- ─── LIVE FEED HEADER ──────────────────────────────────────────────────────
label(inner, "LIVE FEED", 10, FONT_BOLD, ACCENT_HI,
	UDim2.fromOffset(2, 50), UDim2.fromOffset(90, 20))

local clearBtn = button(inner, {
	text = "Clear",
	textSize = 9,
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, 0, 0, 50),
	size = UDim2.fromOffset(48, 20),
	c0 = ACCENT_DARK,
	c1 = ACCENT_DEEP,
	strokeColor = ACCENT,
	strokeThickness = 1,
	strokeTransparency = 0.4,
	radius = 6,
})

local detectedLabel = label(inner, "0 detected", 9, FONT_MED, MUTED,
	UDim2.new(1, -56, 0, 50), UDim2.fromOffset(80, 20), Enum.TextXAlignment.Right)
detectedLabel.AnchorPoint = Vector2.new(1, 0)

local feedBox = new("Frame", {
	Position = UDim2.fromOffset(0, 76),
	Size = UDim2.new(1, 0, 1, -76),
	BackgroundColor3 = BG_PANEL,
	BorderSizePixel = 0,
}, inner)
corner(feedBox, 10)
stroke(feedBox, ACCENT, 1, 0.55)

local feed = new("ScrollingFrame", {
	Position = UDim2.fromOffset(5, 5),
	Size = UDim2.new(1, -10, 1, -10),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = ACCENT,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, feedBox)
new("UIListLayout", {
	Padding = UDim.new(0, 5),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, feed)
new("UIPadding", { PaddingRight = UDim.new(0, 6) }, feed)

-- ─── RESIZE HANDLE (kanan bawah, tarik untuk besar/kecil) ──────────────────
local resizeHandle = new("TextButton", {
	Name = "ResizeHandle",
	AutoButtonColor = false,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -3, 1, -3),
	Size = UDim2.fromOffset(26, 26),
	BackgroundColor3 = ACCENT,
	BackgroundTransparency = 0.2,
	BorderSizePixel = 0,
	Text = "◢",
	TextSize = 14,
	Font = FONT_BOLD,
	TextColor3 = WHITE,
	ZIndex = 30,
}, main)
corner(resizeHandle, 7)

do
	local resizing, startMouse, startSize
	resizeHandle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			resizing = true
			startMouse = input.Position
			startSize = main.AbsoluteSize
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - startMouse
			local nw = math.clamp(startSize.X + delta.X, W_MIN, W_MAX)
			local nh = math.clamp(startSize.Y + delta.Y, H_MIN, H_MAX)
			main.Size = UDim2.fromOffset(nw, nh)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			resizing = false
		end
	end)
end

setProgress(0.7, "Menyiapkan fitur...")

-- ─── TELEPORT ──────────────────────────────────────────────────────────────
TeleportService.TeleportInitFailed:Connect(function(_, result, errorMessage)
	warn("[" .. TITLE .. "] TeleportInitFailed:", tostring(result), tostring(errorMessage))
	if statusLabel and statusLabel.Parent then
		statusLabel.Text = "Join failed"
	end
end)

local function joinServer(jobId)
	jobId = tostring(jobId or "")
	if jobId == "" or jobId == "nil" then
		warn("[" .. TITLE .. "] Join failed: empty jobId")
		return
	end
	if jobId == tostring(game.JobId) then
		warn("[" .. TITLE .. "] Already in this server")
		return
	end

	local placeId = game.PlaceId
	statusLabel.Text = "Joining..."

	local ok, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(placeId, jobId, player)
	end)
	if ok then return end
	warn("[" .. TITLE .. "] Join method 1 failed:", err)

	ok, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(placeId, jobId)
	end)
	if ok then return end
	warn("[" .. TITLE .. "] Join method 2 failed:", err)

	local fn = (syn and syn.request) or http_request or request
	if fn then
		ok, err = pcall(function()
			fn({
				Url = "https://gamejoin.roblox.com/v1/join-game-instance",
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["User-Agent"] = "Roblox/WinInet",
				},
				Body = HttpService:JSONEncode({
					placeId = placeId,
					gameId = jobId,
				}),
			})
		end)
		if ok then
			pcall(function()
				TeleportService:TeleportToPlaceInstance(placeId, jobId, player)
			end)
			return
		end
		warn("[" .. TITLE .. "] Join method 3 failed:", err)
	end

	statusLabel.Text = "Join failed"
	warn("[" .. TITLE .. "] All join methods failed for jobId:", jobId)
end

stopForce = function()
	forceRun += 1
	forceKey, forceJobId = nil, nil
end

startForce = function(key, jobId)
	forceRun += 1
	local myRun = forceRun
	forceKey, forceJobId = key, jobId
	task.spawn(function()
		while forceRun == myRun and autoForceState and gui.Parent do
			if jobId == game.JobId then
				stopForce()
				render()
				break
			end
			joinServer(jobId)
			task.wait(FORCE_INTERVAL)
		end
	end)
end

-- ─── FEED RENDER ───────────────────────────────────────────────────────────
local ageLabels = {}
local feedState = "loading" -- "loading" | "ready" | "error"

local function clearRows()
	for _, c in ipairs(feed:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
	table.clear(ageLabels)
end

local function subText(entry)
	local parts = {}
	table.insert(parts, formatAge(entry.ts))
	local rarityText = escapeRich(entry.rarity)
	if entry.rarityColor then
		rarityText = ("<font color=\"%s\">%s</font>"):format(richColor(entry.rarityColor), rarityText)
	end
	table.insert(parts, rarityText)
	return table.concat(parts, " • ")
end

local function addPlaceholder(text)
	local f = new("Frame", {
		Name = "Placeholder",
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundTransparency = 1,
	}, feed)
	label(f, text, 12, FONT_MED, MUTED, UDim2.new(), UDim2.fromScale(1, 1), Enum.TextXAlignment.Center)
end

local function addRow(data, order)
	local row = new("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
	}, feed)
	corner(row, 8)
	gradient(row, Color3.fromRGB(14, 22, 42), Color3.fromRGB(6, 9, 16), 0)
	accentStroke(row, 1, 0.45)

	local bar = new("Frame", {
		Position = UDim2.fromOffset(5, 5),
		Size = UDim2.fromOffset(4, 42),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
	}, row)
	corner(bar, 2)
	gradient(bar, ACCENT_HI, ACCENT_DARK, 90)

	new("ImageLabel", {
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 1,
		Image = data.iconId and ("rbxassetid://" .. tostring(data.iconId)) or "",
		ScaleType = Enum.ScaleType.Fit,
	}, row)

	-- tombol di kanan, jarak sama (6): FORCE | JOIN | BL
	local title = label(row, "", 15, FONT_BOLD, WHITE,
		UDim2.fromOffset(62, 5), UDim2.new(1, -206, 0, 22))
	title.RichText = true
	title.TextScaled = true
	new("UITextSizeConstraint", { MaxTextSize = 15, MinTextSize = 8 }, title)
	title.Text = ("%s  <font color=\"rgb(90,170,255)\">[ %s ]</font>"):format(
		escapeRich(data.name), formatValue(data.value))

	local sub = label(row, "", 10, FONT_BOLD, SUB_TEXT,
		UDim2.fromOffset(62, 28), UDim2.new(1, -206, 0, 14))
	sub.RichText = true
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	sub.Text = subText(data)
	table.insert(ageLabels, { label = sub, entry = data })

	local canForce = autoForceState
	local selected = canForce and forceKey == data.key
	local fc0, fc1, ftext, fstroke, fstrokeT
	if selected then
		fc0, fc1, ftext = ACCENT_HI, ACCENT, WHITE
		fstroke, fstrokeT = WHITE, 0.3
	elseif canForce then
		fc0, fc1, ftext = Color3.fromRGB(20, 35, 70), Color3.fromRGB(8, 14, 28), WHITE
		fstroke, fstrokeT = ACCENT, 0.2
	else
		fc0, fc1, ftext = Color3.fromRGB(24, 28, 36), Color3.fromRGB(14, 16, 22), Color3.fromRGB(80, 90, 110)
		fstroke, fstrokeT = nil, nil
	end
	local force = button(row, {
		text = "FORCE",
		textSize = 8,
		textColor = ftext,
		anchor = Vector2.new(1, 0.5),
		pos = UDim2.new(1, -8, 0.5, 0),
		size = UDim2.fromOffset(46, 26),
		c0 = fc0,
		c1 = fc1,
		strokeColor = fstroke,
		strokeTransparency = fstrokeT,
		radius = 6,
	})
	local join = button(row, {
		text = "JOIN",
		textSize = 9,
		anchor = Vector2.new(1, 0.5),
		pos = UDim2.new(1, -60, 0.5, 0),
		size = UDim2.fromOffset(46, 26),
		c0 = ACCENT,
		c1 = ACCENT_DARK,
		strokeColor = ACCENT_HI,
		strokeTransparency = 0.2,
		radius = 6,
	})
	local blBtn = button(row, {
		text = "BL",
		textSize = 9,
		anchor = Vector2.new(1, 0.5),
		pos = UDim2.new(1, -112, 0.5, 0),
		size = UDim2.fromOffset(32, 26),
		c0 = Color3.fromRGB(30, 44, 80),
		c1 = Color3.fromRGB(12, 18, 34),
		strokeColor = ACCENT,
		strokeTransparency = 0.35,
		radius = 6,
	})

	join.MouseButton1Click:Connect(function()
		joinServer(data.jobId)
	end)

	force.MouseButton1Click:Connect(function()
		if not autoForceState then return end
		if forceKey == data.key then
			stopForce()
		else
			startForce(data.key, data.jobId)
		end
		render()
	end)

	blBtn.MouseButton1Click:Connect(function()
		if data.name and data.name ~= "" then
			blacklist[data.name] = true
			saveBlacklist()
			statusLabel.Text = "Blacklisted: " .. tostring(data.name):sub(1, 12)
			render()
		end
	end)

	if blacklistMode then
		local pick = new("TextButton", {
			AutoButtonColor = false,
			Text = "TAP TO BLACKLIST",
			TextSize = 10,
			Font = FONT_BOLD,
			TextColor3 = WHITE,
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.fromRGB(20, 60, 150),
			BackgroundTransparency = 0.3,
			ZIndex = 5,
			BorderSizePixel = 0,
		}, row)
		corner(pick, 8)
		pick.MouseButton1Click:Connect(function()
			if data.name and data.name ~= "" then
				blacklist[data.name] = true
				saveBlacklist()
				blacklistMode = false
				blModeBtn.Text = "Blacklist"
				statusLabel.Text = "Blacklisted: " .. tostring(data.name):sub(1, 12)
				render()
			end
		end)
	end
end

local hidden = {}
local latest = {}

local function keyOf(e)
	return e.jobId .. "|" .. e.name .. "|" .. tostring(e.ts)
end

function render()
	local scroll = feed.CanvasPosition
	clearRows()

	local shown = 0
	for _, e in ipairs(latest) do
		if not hidden[keyOf(e)] and not isBlacklisted(e) then
			shown += 1
			if shown <= MAX_ITEMS then
				addRow(e, shown)
			end
		end
	end
	detectedLabel.Text = shown .. " detected"
	if shown == 0 then
		if feedState == "loading" then
			addPlaceholder("Memuat data pet...")
		elseif feedState == "error" then
			addPlaceholder("Gagal terhubung, mencoba lagi...")
		else
			addPlaceholder("Belum ada pet terdeteksi")
		end
	end
	feed.CanvasPosition = scroll

	if autoJoinState and #latest > 0 then
		for _, e in ipairs(latest) do
			local jid = tostring(e.jobId)
			if not hidden[keyOf(e)] and not isBlacklisted(e) and jid ~= tostring(game.JobId) and jid ~= lastAutoJoinJob then
				lastAutoJoinJob = jid
				joinServer(jid)
				break
			end
		end
	end
end

clearBtn.MouseButton1Click:Connect(function()
	for _, e in ipairs(latest) do
		hidden[keyOf(e)] = true
	end
	render()
end)

blClose.MouseButton1Click:Connect(function()
	blPanel.Visible = false
	showingBlacklistPanel = false
end)

blModeBtn.MouseButton1Click:Connect(function()
	blacklistMode = not blacklistMode
	blPanel.Visible = false
	showingBlacklistPanel = false
	if blacklistMode then
		blModeBtn.Text = "Pick log..."
		statusLabel.Text = "Click a log to blacklist"
	else
		blModeBtn.Text = "Blacklist"
		statusLabel.Text = "Connected"
	end
	render()
end)

unblBtn.MouseButton1Click:Connect(function()
	blacklistMode = false
	blModeBtn.Text = "Blacklist"
	showingBlacklistPanel = not showingBlacklistPanel
	blPanel.Visible = showingBlacklistPanel
	if showingBlacklistPanel then
		refreshBlacklistPanel()
		statusLabel.Text = "Blacklist manager"
	else
		statusLabel.Text = "Connected"
	end
end)

copyBtn.MouseButton1Click:Connect(function()
	local fn = setclipboard or toclipboard
	local ok = fn and pcall(fn, DISCORD_LINK)
	copyBtn.Text = ok and "Copied!" or "Failed"
	if not ok then
		warn("[" .. TITLE .. "] Clipboard not supported. Link: " .. DISCORD_LINK)
	end
	task.delay(1.4, function()
		if copyBtn.Parent then
			copyBtn.Text = COPY_TEXT
		end
	end)
end)

-- ─── FETCH + POST ──────────────────────────────────────────────────────────
local function fetchPets()
	local body = httpGet(API_URL)
	if not body then return false end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if not ok or type(decoded) ~= "table" then return false end

	local list = {}
	for _, p in ipairs(decoded) do
		if p.petName and p.jobId and tonumber(p.value) then
			local name = tostring(p.petName)
			local rarity = getRarity(name)
				or (p.rarity and tostring(p.rarity))
				or DEFAULT_RARITY
			table.insert(list, {
				name = name,
				value = tonumber(p.value),
				jobId = tostring(p.jobId),
				iconId = p.iconId,
				key = tostring(p.jobId) .. "|" .. name .. "|" .. tostring(p.timestamp),
				ts = tonumber(p.timestamp) or (os.time() * 1000),
				rarity = rarity,
				rarityColor = getRarityColor(name),
			})
		end
	end
	table.sort(list, function(a, b)
		return (a.ts or 0) > (b.ts or 0)
	end)
	latest = list
	return true
end

local postedAt = {}
local postOk, postFail, scanCount, lastPostStatus = 0, 0, 0, "-"
local postPauseUntil = 0

local VALUE_PATTERN = "^%s*%$?%s*([%d%.,]+)%s*([KkMmBbTt]?)%s*/%s*[sS]%s*$"
local UNIT_MUL = { K = 1e3, M = 1e6, B = 1e9, T = 1e12 }

local function parseValue(text)
	local clean = tostring(text):gsub("<[^>]+>", "")
	local num, unit = clean:match(VALUE_PATTERN)
	if not num then return nil end
	local n = tonumber((num:gsub(",", "")))
	if not n then return nil end
	return n * (UNIT_MUL[unit:upper()] or 1)
end

local function resolveName(inst)
	local cur = inst.Parent
	for _ = 1, 8 do
		if not cur or cur == workspace then return nil end
		local key = displayByName[cur.Name] and cur.Name or nil
		if not key then
			for _, ch in ipairs(cur:GetChildren()) do
				if ch:IsA("TextLabel") then
					local t = tostring(ch.Text):gsub("<[^>]+>", "")
					t = t:match("^%s*(.-)%s*$")
					if displayByName[t] then
						key = t
						break
					end
				end
			end
		end
		if key then
			return displayByName[key], iconByName[key]
		end
		cur = cur.Parent
	end
	return nil
end

local function scanPets()
	local found, seen, n = {}, {}, 0
	for _, d in ipairs(workspace:GetDescendants()) do
		n += 1
		if n % 3000 == 0 then task.wait() end
		if d:IsA("TextLabel") then
			local value = parseValue(d.Text)
			if value and value >= POST_MIN_VALUE then
				local name, icon = resolveName(d)
				if name then
					local k = name .. "|" .. math.floor(value)
					if not seen[k] then
						seen[k] = true
						table.insert(found, { name = name, value = value, icon = icon })
					end
				end
			end
		end
	end
	return found
end

local function alreadyListed(name, value)
	for _, e in ipairs(latest) do
		if e.jobId == game.JobId and e.name == name and math.abs(e.value - value) <= value * 0.05 then
			return true
		end
	end
	return false
end

local function httpPost(url, body)
	local fn = (syn and syn.request) or http_request or request
	if not fn then return nil, "no request fn" end
	local ok, res = pcall(fn, {
		Url = url,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
	})
	if ok and type(res) == "table" then
		return tonumber(res.StatusCode), res.Body
	end
	return nil, tostring(res)
end

-- ─── TAMPILKAN UI SEKARANG, data menyusul di latar belakang ────────────────
render() -- tampilkan placeholder "Memuat data pet..."
setProgress(1, "Siap!")
TweenService:Create(loading, TweenInfo.new(0.25), { GroupTransparency = 1 }):Play()
task.delay(0.3, function()
	if loading then loading:Destroy() end
end)

-- ─── LOOPS ─────────────────────────────────────────────────────────────────
-- ambil data (UI sudah terlihat, jadi tidak ada layar kosong saat menunggu)
task.spawn(function()
	while gui.Parent do
		local ok = fetchPets()
		if ok then
			feedState = "ready"
			if statusLabel.Text == "Memuat data..." or statusLabel.Text == "Disconnected" then
				statusLabel.Text = "Connected"
			end
		else
			feedState = (#latest == 0) and "error" or "ready"
			statusLabel.Text = "Disconnected"
		end
		render()
		task.wait(REFRESH_INTERVAL)
	end
end)

-- scan + post (ditunda sebentar supaya tidak membebani saat UI baru muncul)
task.spawn(function()
	task.wait(POST_FIRST_DELAY)
	while gui.Parent do
		if not AUTO_POST or game.JobId == "" then
			postLabel.Text = "Post: off"
		elseif os.clock() >= postPauseUntil then
			local ok, found = pcall(scanPets)
			if ok then
				scanCount = #found
				for _, pet in ipairs(found) do
					local key = game.JobId .. "|" .. pet.name .. "|" .. math.floor(pet.value)
					local last = postedAt[key]
					if (not last or os.clock() - last > POST_COOLDOWN) and not alreadyListed(pet.name, pet.value) then
						postedAt[key] = os.clock()
						local body = HttpService:JSONEncode({
							petName = pet.name,
							value = pet.value,
							jobId = game.JobId,
							iconId = pet.icon and tostring(pet.icon) or "",
							timestamp = os.time() * 1000,
						})
						local status, resp = httpPost(POST_URL, body)
						if status and status >= 200 and status < 300 then
							postOk += 1
						else
							postFail += 1
							postedAt[key] = os.clock() - POST_COOLDOWN + 60
							if status == 429 then
								postPauseUntil = os.clock() + 30
							end
						end
						lastPostStatus = status and tostring(status) or tostring(resp):sub(1, 14)
						if status == 429 then break end
						task.wait(0.5)
					end
				end
			else
				warn("[" .. TITLE .. "] Scan gagal:", found)
			end
			postLabel.Text = ("Scan:%d Post:%d/%d (%s)"):format(scanCount, postOk, postOk + postFail, lastPostStatus)
		end
		task.wait(POST_SCAN_INTERVAL)
	end
end)

task.spawn(function()
	while gui.Parent do
		for _, item in ipairs(ageLabels) do
			if item.label.Parent then
				item.label.Text = subText(item.entry)
			end
		end
		task.wait(1)
	end
end)
