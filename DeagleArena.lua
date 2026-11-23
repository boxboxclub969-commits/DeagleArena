local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if type(env.SlothUnload) == "function" then
	pcall(env.SlothUnload)
end

-- Semua angka di sini belum dikalibrasi, itu nilai awal.
local Config = {
	Title = "Sloth",
	LogoAssetId = nil, -- unset: isi angka asset Roblox kalau punya
	LogoUrl = "https://raw.githubusercontent.com/boxboxclub969-commits/DeagleArena/main/sloth.jpg",
	LogoFile = "sloth_logo.jpg",
	LogoFallbackText = "💀",
	Keys = {
		Menu = Enum.KeyCode.RightShift,
		Aim = Enum.KeyCode.Q,
		Fly = Enum.KeyCode.F,
		Speed = Enum.KeyCode.G,
		Unload = Enum.KeyCode.End,
	},
	AimHoldInput = Enum.UserInputType.MouseButton2, -- khusus PC, tahan untuk aim
	AimPart = "Head",
	AimFovPixels = 250, -- radius lingkaran aim
	AimFovMin = 60,
	AimFovMax = 600,
	AimFovStep = 25,
	AimSmoothing = 0.35, -- 0..1, makin kecil makin halus
	TeamCheck = true,
	WallCheck = false, -- true bisa bikin Aim gagal kalau ada part tak terlihat di jalur
	ESPMaxDistance = 2000,
	FlySpeed = 60,
	WalkSpeed = 40,
	ScanNonPlayers = true, -- cari model ber-Humanoid di luar daftar Players
	ScanInterval = 2, -- detik antar scan Workspace
	MaxScanTargets = 64,
	Colors = {
		On = Color3.fromRGB(46, 160, 90),
		Off = Color3.fromRGB(45, 45, 55),
		Panel = Color3.fromRGB(14, 14, 20),
		Danger = Color3.fromRGB(190, 55, 70),
		Accent = Color3.fromRGB(70, 130, 220),
		Box = Color3.fromRGB(255, 80, 100),
		Skeleton = Color3.fromRGB(255, 255, 255),
		Circle = Color3.fromRGB(255, 255, 255),
		Lock = Color3.fromRGB(80, 255, 120),
	},
}

local State = {
	Aim = false,
	Circle = true,
	ESPName = false,
	ESPBox = false,
	ESPSkeleton = false,
	Fly = false,
	Speed = false,
}
local Hold = { Aim = false, FlyUp = false, FlyDown = false }
local Labels = {
	Aim = "Aim",
	Circle = "Circle",
	ESPName = "ESP Name",
	ESPBox = "ESP Box",
	ESPSkeleton = "ESP Skeleton",
	Fly = "Fly",
	Speed = "Speed",
}

local R15_PAIRS = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local R6_PAIRS = {
	{ "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
	{ "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}
local MAX_LINES = 14

local connections = {}
local espEntries = {}
local buttons = {}
local savedWalkSpeed = nil
local unloaded = false
local aimRadius = Config.AimFovPixels

local gui, overlay, flyPad, statusLabel, fovLabel, panelFrame
local circleFrame, circleStroke

local scanModels = {}
local scanAt = -math.huge
local targetCounts = { players = 0, scanned = 0 }
local lastLock = "off"

local AIM_BIND_NAME = "SlothAim"
local ESP_BIND_NAME = "SlothESP"

local function getCharacterParts(player)
	local character = player.Character
	if not character then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then return nil end
	return character, humanoid, root
end

local function isEnemy(player)
	if player == LocalPlayer then return false end
	if Config.TeamCheck and player.Team ~= nil and player.Team == LocalPlayer.Team then
		return false
	end
	return true
end

local function refreshButton(key)
	local button = buttons[key]
	if not button then return end
	local on = State[key]
	button.Text = string.format("%s: %s", Labels[key], on and "ON" or "OFF")
	button.BackgroundColor3 = on and Config.Colors.On or Config.Colors.Off
end

-- Target discovery
local function pickRoot(model)
	return model:FindFirstChild("HumanoidRootPart")
		or model.PrimaryPart
		or model:FindFirstChild("Head")
		or model:FindFirstChildWhichIsA("BasePart")
end

local function describeModel(model, player)
	local root = pickRoot(model)
	if not root then return nil end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then return nil end
	return {
		model = model,
		player = player,
		humanoid = humanoid,
		root = root,
		head = model:FindFirstChild("Head") or root,
		name = player and player.Name or model.Name,
	}
end

local function getTargets()
	local list, seen = {}, {}
	local playerCount = 0

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if player ~= LocalPlayer and character then
			seen[character] = true
			if isEnemy(player) then
				local target = describeModel(character, player)
				if target then
					table.insert(list, target)
					playerCount += 1
				end
			end
		end
	end

	local scannedCount = 0
	if Config.ScanNonPlayers then
		local now = os.clock()
		if now - scanAt >= Config.ScanInterval then
			scanAt = now
			local found = {}
			for _, descendant in ipairs(Workspace:GetDescendants()) do
				if descendant:IsA("Humanoid") then
					local model = descendant.Parent
					if model and model:IsA("Model") then table.insert(found, model) end
				end
			end
			scanModels = found
		end

		local myCharacter = LocalPlayer.Character
		for _, model in ipairs(scanModels) do
			if scannedCount >= Config.MaxScanTargets then break end
			if model.Parent
				and model ~= myCharacter
				and not seen[model]
				and not (myCharacter and model:IsDescendantOf(myCharacter)) then
				seen[model] = true
				local target = describeModel(model, nil)
				if target then
					table.insert(list, target)
					scannedCount += 1
				end
			end
		end
	end

	targetCounts.players, targetCounts.scanned = playerCount, scannedCount
	return list
end

-- ESP (Name, Box, Skeleton) digambar dengan elemen GUI, tanpa Drawing API
local function setLine(frame, a, b)
	local delta = b - a
	frame.Size = UDim2.fromOffset(delta.Magnitude, 1.5)
	frame.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	frame.Visible = true
end

local function createEntry()
	local entry = { lines = {} }

	local box = Instance.new("Frame")
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Visible = false
	box.Parent = overlay
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Config.Colors.Box
	stroke.Parent = box
	entry.box = box

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Size = UDim2.fromOffset(160, 16)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextSize = 13
	label.Font = Enum.Font.GothamBold
	label.Visible = false
	label.Parent = overlay
	entry.label = label

	for i = 1, MAX_LINES do
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.BorderSizePixel = 0
		line.BackgroundColor3 = Config.Colors.Skeleton
		line.Visible = false
		line.Parent = overlay
		entry.lines[i] = line
	end
	return entry
end

local function destroyEntry(entry)
	entry.box:Destroy()
	entry.label:Destroy()
	for _, line in ipairs(entry.lines) do line:Destroy() end
end

local function hideLinesFrom(entry, first)
	for i = first, MAX_LINES do entry.lines[i].Visible = false end
end

local function drawSkeleton(entry, model, camera)
	local pairsList
	if model:FindFirstChild("UpperTorso") then
		pairsList = R15_PAIRS
	elseif model:FindFirstChild("Torso") then
		pairsList = R6_PAIRS
	end

	local used = 0
	if pairsList then
		for _, pair in ipairs(pairsList) do
			local a = model:FindFirstChild(pair[1])
			local b = model:FindFirstChild(pair[2])
			if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
				local pa = camera:WorldToViewportPoint(a.Position)
				local pb = camera:WorldToViewportPoint(b.Position)
				if pa.Z > 0 and pb.Z > 0 then
					used += 1
					setLine(entry.lines[used], Vector2.new(pa.X, pa.Y), Vector2.new(pb.X, pb.Y))
				end
			end
		end
	end
	hideLinesFrom(entry, used + 1)
end

local function updateESP()
	local camera = Workspace.CurrentCamera
	local wantAny = State.ESPName or State.ESPBox or State.ESPSkeleton
	local seen = {}

	if wantAny and camera and overlay then
		local myRoot = select(3, getCharacterParts(LocalPlayer))
		local origin = myRoot and myRoot.Position or camera.CFrame.Position

		for _, target in ipairs(getTargets()) do
			local model = target.model
			local okBox, cf, size = pcall(function()
				local boxCf, boxSize = model:GetBoundingBox()
				return boxCf, boxSize
			end)
			if okBox then
				local top = camera:WorldToViewportPoint(cf.Position + Vector3.new(0, size.Y / 2, 0))
				local bottom = camera:WorldToViewportPoint(cf.Position - Vector3.new(0, size.Y / 2, 0))
				local distance = (origin - cf.Position).Magnitude
				local height = math.abs(bottom.Y - top.Y)

				if distance <= Config.ESPMaxDistance
					and top.Z > 0 and bottom.Z > 0
					and height == height and height > 2 and height < 4000 then
					local entry = espEntries[model]
					if not entry then
						entry = createEntry()
						espEntries[model] = entry
					end
					seen[model] = true

					local width = height * 0.55
					local centerX = (top.X + bottom.X) / 2
					local topY = math.min(top.Y, bottom.Y)

					entry.box.Visible = State.ESPBox
					entry.box.Position = UDim2.fromOffset(centerX - width / 2, topY)
					entry.box.Size = UDim2.fromOffset(width, height)

					entry.label.Visible = State.ESPName
					if State.ESPName then
						local hp = target.humanoid and math.floor(target.humanoid.Health) or 0
						entry.label.Position = UDim2.fromOffset(centerX, topY - 2)
						entry.label.Text = string.format("%s [%dm] HP %d", target.name, math.floor(distance), hp)
					end

					if State.ESPSkeleton then
						drawSkeleton(entry, model, camera)
					else
						hideLinesFrom(entry, 1)
					end
				end
			end
		end
	end

	for model, entry in pairs(espEntries) do
		if not seen[model] then
			destroyEntry(entry)
			espEntries[model] = nil
		end
	end
end

-- Aimbot dengan lingkaran
local function isVisible(origin, part, model)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local result = Workspace:Raycast(origin, part.Position - origin, params)
	return result == nil or result.Instance:IsDescendantOf(model)
end

local function getAimTarget()
	local camera = Workspace.CurrentCamera
	if not camera then return nil end
	local center = camera.ViewportSize / 2
	local bestPart, bestName, bestDistance = nil, nil, aimRadius

	for _, target in ipairs(getTargets()) do
		local part = target.model:FindFirstChild(Config.AimPart) or target.head
		if part then
			local point, onScreen = camera:WorldToViewportPoint(part.Position)
			if onScreen then
				local d = (Vector2.new(point.X, point.Y) - center).Magnitude
				if d < bestDistance
					and (not Config.WallCheck or isVisible(camera.CFrame.Position, part, target.model)) then
					bestPart, bestName, bestDistance = part, target.name, d
				end
			end
		end
	end
	return bestPart, bestName
end

local function updateCircle(locked)
	if not circleFrame then return end
	local show = State.Circle and (State.Aim or Hold.Aim)
	circleFrame.Visible = show
	if show then
		circleFrame.Size = UDim2.fromOffset(aimRadius * 2, aimRadius * 2)
		circleStroke.Color = locked and Config.Colors.Lock or Config.Colors.Circle
	end
end

local function updateAim()
	local active = State.Aim or Hold.Aim
	local locked = false

	if active and getCharacterParts(LocalPlayer) then
		local camera = Workspace.CurrentCamera
		local part, name = getAimTarget()
		if camera and part then
			locked = true
			lastLock = name
			local goal = CFrame.lookAt(camera.CFrame.Position, part.Position)
			camera.CFrame = camera.CFrame:Lerp(goal, Config.AimSmoothing)
		else
			lastLock = "none"
		end
	else
		lastLock = active and "dead" or "off"
	end

	updateCircle(locked)
end

-- Fly dan Speed
local function setFly(enabled)
	State.Fly = enabled
	Hold.FlyUp, Hold.FlyDown = false, false
	local _, humanoid = getCharacterParts(LocalPlayer)
	if humanoid then humanoid.PlatformStand = enabled end
	if flyPad then flyPad.Visible = enabled end
	refreshButton("Fly")
end

local function updateFly()
	if not State.Fly then return end
	local _, humanoid, root = getCharacterParts(LocalPlayer)
	local camera = Workspace.CurrentCamera
	if not humanoid or not root or not camera then return end

	local direction = Vector3.zero
	local move = humanoid.MoveDirection
	if move.Magnitude > 0 then
		direction += move
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.001 then
			local forward = move:Dot(flat.Unit)
			local tilt = math.clamp(look.Y / flat.Magnitude, -2, 2)
			direction += Vector3.yAxis * tilt * forward
		end
	end

	if Hold.FlyUp or UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		direction += Vector3.yAxis
	end
	if Hold.FlyDown or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		direction -= Vector3.yAxis
	end

	if direction.Magnitude > 1 then direction = direction.Unit end
	root.AssemblyLinearVelocity = direction * Config.FlySpeed
end

local function updateSpeed()
	local _, humanoid = getCharacterParts(LocalPlayer)
	if not humanoid then return end
	if State.Speed then
		if savedWalkSpeed == nil then savedWalkSpeed = humanoid.WalkSpeed end
		humanoid.WalkSpeed = Config.WalkSpeed
	elseif savedWalkSpeed ~= nil then
		humanoid.WalkSpeed = savedWalkSpeed
		savedWalkSpeed = nil
	end
end

local function toggle(key)
	if key == "Fly" then
		setFly(not State.Fly)
	elseif key == "Speed" then
		State.Speed = not State.Speed
		updateSpeed()
		refreshButton("Speed")
	else
		State[key] = not State[key]
		refreshButton(key)
	end
end

-- Unload
local function unload()
	if unloaded then return end
	unloaded = true
	State.Aim, State.Speed = false, false
	State.ESPName, State.ESPBox, State.ESPSkeleton = false, false, false
	setFly(false)
	updateSpeed()
	pcall(function() RunService:UnbindFromRenderStep(AIM_BIND_NAME) end)
	pcall(function() RunService:UnbindFromRenderStep(ESP_BIND_NAME) end)
	for model, entry in pairs(espEntries) do
		destroyEntry(entry)
		espEntries[model] = nil
	end
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
	if gui then gui:Destroy() end
	if overlay then overlay:Destroy() end
	if env.SlothUnload == unload then env.SlothUnload = nil end
end

-- GUI
local function attachGui(screenGui)
	local candidates = {}
	local ok, hidden = pcall(function() return gethui and gethui() end)
	if ok and hidden then table.insert(candidates, hidden) end
	local okCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if okCore and coreGui then table.insert(candidates, coreGui) end
	table.insert(candidates, LocalPlayer:WaitForChild("PlayerGui"))

	for _, parent in ipairs(candidates) do
		local attached = pcall(function() screenGui.Parent = parent end)
		if attached and screenGui.Parent == parent then return true end
	end
	return false
end

local function styleButton(button, color)
	button.BackgroundColor3 = color
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 15
	button.AutoButtonColor = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button
end

local function buildOverlay()
	overlay = Instance.new("ScreenGui")
	overlay.Name = "SlothOverlay"
	overlay.ResetOnSpawn = false
	overlay.IgnoreGuiInset = true
	overlay.DisplayOrder = 998

	circleFrame = Instance.new("Frame")
	circleFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	circleFrame.Position = UDim2.fromScale(0.5, 0.5)
	circleFrame.BackgroundTransparency = 1
	circleFrame.BorderSizePixel = 0
	circleFrame.Visible = false
	circleFrame.Parent = overlay
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = circleFrame
	circleStroke = Instance.new("UIStroke")
	circleStroke.Thickness = 2
	circleStroke.Color = Config.Colors.Circle
	circleStroke.Parent = circleFrame

	if not attachGui(overlay) then
		overlay:Destroy()
		overlay, circleFrame, circleStroke = nil, nil, nil
		warn("[Sloth] overlay gagal dipasang, ESP dan lingkaran tidak tampil")
	end
end

local function applyLogo(logo, fallback)
	if Config.LogoAssetId then
		logo.Image = "rbxassetid://" .. tostring(Config.LogoAssetId)
		fallback.Visible = false
		return
	end
	if Config.LogoUrl and writefile and getcustomasset then
		task.spawn(function()
			local ok, asset = pcall(function()
				local data = game:HttpGet(Config.LogoUrl)
				local isJpg = data:sub(1, 2) == "\255\216"
				local isPng = data:sub(2, 4) == "PNG"
				if #data < 200 or not (isJpg or isPng) then return nil end
				writefile(Config.LogoFile, data)
				return getcustomasset(Config.LogoFile)
			end)
			if ok and asset and not unloaded then
				logo.Image = asset
				fallback.Visible = false
			end
		end)
	end
end

local function makeDraggable(handle, target, onTap)
	local dragging, moved = false, false
	local tracked, startPointer, startPosition

	table.insert(connections, handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging, moved = true, false
			tracked = input
			startPointer = input.Position
			startPosition = target.Position
		end
	end))

	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		local isTracked = (input == tracked)
			or (tracked.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseMovement)
		if not isTracked then return end
		local delta = input.Position - startPointer
		if delta.Magnitude > 6 then moved = true end
		if moved then
			target.Position = UDim2.new(
				startPosition.X.Scale, startPosition.X.Offset + delta.X,
				startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
			)
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if not dragging then return end
		if input == tracked or (tracked.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			if not moved then onTap() end
		end
	end))
end

local function buildMenu()
	gui = Instance.new("ScreenGui")
	gui.Name = "Sloth"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999

	local root = Instance.new("Frame")
	root.Size = UDim2.fromOffset(56, 56)
	root.Position = UDim2.new(0, 12, 0.4, 0)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local logo = Instance.new("ImageButton")
	logo.Size = UDim2.fromOffset(56, 56)
	logo.Rotation = 0
	logo.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
	logo.AutoButtonColor = false
	logo.ScaleType = Enum.ScaleType.Crop
	logo.Image = ""
	logo.Parent = root
	do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = logo
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Config.Colors.Accent
		stroke.Parent = logo
	end

	local fallback = Instance.new("TextLabel")
	fallback.Size = UDim2.fromScale(1, 1)
	fallback.BackgroundTransparency = 1
	fallback.Text = Config.LogoFallbackText
	fallback.TextSize = 30
	fallback.Active = false
	fallback.Parent = logo
	applyLogo(logo, fallback)

	local viewportY = 400
	pcall(function() viewportY = Workspace.CurrentCamera.ViewportSize.Y end)
	local panelHeight = math.clamp(viewportY - 60, 180, 320)

	panelFrame = Instance.new("Frame")
	panelFrame.Position = UDim2.fromOffset(64, 0)
	panelFrame.Size = UDim2.fromOffset(250, panelHeight)
	panelFrame.BackgroundColor3 = Config.Colors.Panel
	panelFrame.BackgroundTransparency = 0.08
	panelFrame.Visible = false
	panelFrame.Parent = root
	do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = panelFrame
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Color = Config.Colors.Accent
		stroke.Parent = panelFrame
	end

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 34)
	title.BackgroundTransparency = 1
	title.Text = Config.Title
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.Parent = panelFrame

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(0, 34)
	scroll.Size = UDim2.new(1, 0, 1, -34)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = panelFrame
	do
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = scroll
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 8)
		padding.PaddingRight = UDim.new(0, 12)
		padding.PaddingBottom = UDim.new(0, 8)
		padding.Parent = scroll
	end

	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	local function addSection(text)
		local label = Instance.new("TextLabel")
		label.LayoutOrder = nextOrder()
		label.Size = UDim2.new(1, 0, 0, 20)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Config.Colors.Accent
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = scroll
	end

	local function addToggle(key)
		local button = Instance.new("TextButton")
		button.LayoutOrder = nextOrder()
		button.Size = UDim2.new(1, 0, 0, 36)
		styleButton(button, Config.Colors.Off)
		button.Parent = scroll
		buttons[key] = button
		refreshButton(key)
		button.Activated:Connect(function() toggle(key) end)
	end

	local function addFovStepper()
		local row = Instance.new("Frame")
		row.LayoutOrder = nextOrder()
		row.Size = UDim2.new(1, 0, 0, 36)
		row.BackgroundTransparency = 1
		row.Parent = scroll

		local function refreshFov()
			fovLabel.Text = "Circle size " .. tostring(aimRadius)
		end

		local minus = Instance.new("TextButton")
		minus.Size = UDim2.new(0.25, -3, 1, 0)
		minus.Text = "-"
		styleButton(minus, Config.Colors.Off)
		minus.TextSize = 20
		minus.Parent = row

		fovLabel = Instance.new("TextLabel")
		fovLabel.Position = UDim2.fromScale(0.25, 0)
		fovLabel.Size = UDim2.fromScale(0.5, 1)
		fovLabel.BackgroundTransparency = 1
		fovLabel.TextColor3 = Color3.new(1, 1, 1)
		fovLabel.Font = Enum.Font.GothamBold
		fovLabel.TextSize = 12
		fovLabel.Parent = row

		local plus = Instance.new("TextButton")
		plus.Position = UDim2.new(0.75, 3, 0, 0)
		plus.Size = UDim2.new(0.25, -3, 1, 0)
		plus.Text = "+"
		styleButton(plus, Config.Colors.Off)
		plus.TextSize = 20
		plus.Parent = row

		minus.Activated:Connect(function()
			aimRadius = math.clamp(aimRadius - Config.AimFovStep, Config.AimFovMin, Config.AimFovMax)
			refreshFov()
		end)
		plus.Activated:Connect(function()
			aimRadius = math.clamp(aimRadius + Config.AimFovStep, Config.AimFovMin, Config.AimFovMax)
			refreshFov()
		end)
		refreshFov()
	end

	addSection("AIM")
	addToggle("Aim")
	addToggle("Circle")
	addFovStepper()

	addSection("ESP")
	addToggle("ESPName")
	addToggle("ESPBox")
	addToggle("ESPSkeleton")

	addSection("MOVE")
	addToggle("Fly")
	addToggle("Speed")

	statusLabel = Instance.new("TextLabel")
	statusLabel.LayoutOrder = nextOrder()
	statusLabel.Size = UDim2.new(1, 0, 0, 32)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 12
	statusLabel.TextWrapped = true
	statusLabel.Text = "Targets: -"
	statusLabel.Parent = scroll

	local unloadButton = Instance.new("TextButton")
	unloadButton.LayoutOrder = nextOrder()
	unloadButton.Size = UDim2.new(1, 0, 0, 34)
	unloadButton.Text = "Unload"
	styleButton(unloadButton, Config.Colors.Danger)
	unloadButton.Parent = scroll
	unloadButton.Activated:Connect(unload)

	flyPad = Instance.new("Frame")
	flyPad.Name = "FlyPad"
	flyPad.AnchorPoint = Vector2.new(1, 1)
	flyPad.Position = UDim2.new(1, -16, 1, -160)
	flyPad.Size = UDim2.fromOffset(70, 150)
	flyPad.BackgroundTransparency = 1
	flyPad.Visible = false
	flyPad.Parent = gui

	local function makeHold(text, yScale, key)
		local button = Instance.new("TextButton")
		button.Position = UDim2.fromScale(0, yScale)
		button.Size = UDim2.new(1, 0, 0.48, 0)
		button.Text = text
		styleButton(button, Config.Colors.Panel)
		button.TextSize = 26
		button.BackgroundTransparency = 0.2
		button.Parent = flyPad
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1 then
				Hold[key] = true
			end
		end)
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1 then
				Hold[key] = false
			end
		end)
	end
	makeHold("▲", 0, "FlyUp")
	makeHold("▼", 0.52, "FlyDown")

	makeDraggable(logo, root, function()
		panelFrame.Visible = not panelFrame.Visible
	end)

	if not attachGui(gui) then
		gui:Destroy()
		gui, flyPad, statusLabel, panelFrame = nil, nil, nil, nil
		warn("[Sloth] menu gagal dipasang ke GUI manapun, hotkey keyboard tetap aktif")
	end
end

-- Input keyboard dan mouse (PC)
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType == Config.AimHoldInput then
		Hold.Aim = true
	elseif input.KeyCode == Config.Keys.Menu then
		if panelFrame then panelFrame.Visible = not panelFrame.Visible end
	elseif input.KeyCode == Config.Keys.Aim then
		toggle("Aim")
	elseif input.KeyCode == Config.Keys.Fly then
		toggle("Fly")
	elseif input.KeyCode == Config.Keys.Speed then
		toggle("Speed")
	elseif input.KeyCode == Config.Keys.Unload then
		unload()
	end
end))

table.insert(connections, UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Config.AimHoldInput then Hold.Aim = false end
end))

table.insert(connections, UserInputService.WindowFocusReleased:Connect(function()
	Hold.Aim, Hold.FlyUp, Hold.FlyDown = false, false, false
end))

RunService:BindToRenderStep(AIM_BIND_NAME, Enum.RenderPriority.Camera.Value + 1, updateAim)
RunService:BindToRenderStep(ESP_BIND_NAME, Enum.RenderPriority.Camera.Value + 2, updateESP)

local lastStatusAt = 0
table.insert(connections, RunService.Heartbeat:Connect(function()
	updateFly()
	if State.Speed then updateSpeed() end

	local now = os.clock()
	if statusLabel and now - lastStatusAt >= 0.5 then
		lastStatusAt = now
		getTargets()
		statusLabel.Text = string.format(
			"Targets: %d (P%d S%d)\nLock: %s",
			targetCounts.players + targetCounts.scanned,
			targetCounts.players,
			targetCounts.scanned,
			lastLock
		)
	end
end))

table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
	savedWalkSpeed = nil
	if State.Fly then task.defer(setFly, true) end
end))

env.SlothUnload = unload
buildOverlay()
buildMenu()
