local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- Semua angka di sini belum dikalibrasi, itu nilai awal.
local Config = {
	Keys = {
		ESP = Enum.KeyCode.E,
		Aim = Enum.KeyCode.Q,
		Fly = Enum.KeyCode.F,
		Speed = Enum.KeyCode.G,
		Unload = Enum.KeyCode.End,
	},
	AimHoldInput = Enum.UserInputType.MouseButton2, -- khusus PC, tahan untuk aim
	AimPart = "Head",
	AimFovPixels = 300,
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
		Panel = Color3.fromRGB(20, 20, 26),
		Danger = Color3.fromRGB(190, 55, 70),
	},
}

local State = { ESP = false, Aim = false, Fly = false, Speed = false }
local Hold = { Aim = false, FlyUp = false, FlyDown = false }

local connections = {}
local espObjects = {}
local buttons = {}
local savedWalkSpeed = nil
local unloaded = false
local gui, flyPad, statusLabel

local scanModels = {}
local scanAt = -math.huge
local targetCounts = { players = 0, scanned = 0 }
local lastLock = "none"

local AIM_BIND_NAME = "DeagleArenaAim"

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

local function refreshButton(name)
	local button = buttons[name]
	if not button then return end
	local on = State[name]
	button.Text = string.format("%s: %s", name, on and "ON" or "OFF")
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

-- ESP
local function destroyESP(model)
	local entry = espObjects[model]
	if not entry then return end
	if entry.highlight then entry.highlight:Destroy() end
	if entry.billboard then entry.billboard:Destroy() end
	espObjects[model] = nil
end

local function ensureESP(target)
	local model = target.model
	local entry = espObjects[model]
	if entry and entry.highlight.Parent and entry.billboard.Parent then
		return entry
	end
	destroyESP(model)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(255, 60, 90)
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0.6
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = model

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(160, 36)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = target.head
	billboard.Parent = target.head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextSize = 14
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	entry = { highlight = highlight, billboard = billboard, label = label }
	espObjects[model] = entry
	return entry
end

local function updateESP()
	local active = {}
	if State.ESP then
		local myRoot = select(3, getCharacterParts(LocalPlayer))
		for _, target in ipairs(getTargets()) do
			local distance = myRoot and (myRoot.Position - target.root.Position).Magnitude or 0
			if distance <= Config.ESPMaxDistance then
				local entry = ensureESP(target)
				if entry then
					active[target.model] = true
					local hp = target.humanoid and math.floor(target.humanoid.Health) or 0
					entry.label.Text = string.format("%s [%dm] HP %d", target.name, math.floor(distance), hp)
				end
			end
		end
	end
	for model in pairs(espObjects) do
		if not active[model] then destroyESP(model) end
	end
end

-- Aimbot
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
	local bestPart, bestName, bestDistance = nil, nil, Config.AimFovPixels

	for _, target in ipairs(getTargets()) do
		local part = target.model:FindFirstChild(Config.AimPart) or target.head
		if part then
			local screenPoint, onScreen = camera:WorldToViewportPoint(part.Position)
			if onScreen then
				local d = (Vector2.new(screenPoint.X, screenPoint.Y) - center).Magnitude
				if d < bestDistance
					and (not Config.WallCheck or isVisible(camera.CFrame.Position, part, target.model)) then
					bestPart, bestName, bestDistance = part, target.name, d
				end
			end
		end
	end
	return bestPart, bestName
end

local function updateAim()
	if not (State.Aim or Hold.Aim) then
		lastLock = "off"
		return
	end
	if not getCharacterParts(LocalPlayer) then
		lastLock = "dead"
		return
	end
	local camera = Workspace.CurrentCamera
	local target, name = getAimTarget()
	if not camera or not target then
		lastLock = "none"
		return
	end
	lastLock = name
	local goal = CFrame.lookAt(camera.CFrame.Position, target.Position)
	camera.CFrame = camera.CFrame:Lerp(goal, Config.AimSmoothing)
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

local function toggle(name)
	if name == "Fly" then
		setFly(not State.Fly)
	elseif name == "Speed" then
		State.Speed = not State.Speed
		updateSpeed()
		refreshButton("Speed")
	else
		State[name] = not State[name]
		refreshButton(name)
	end
end

-- Unload
local function unload()
	if unloaded then return end
	unloaded = true
	State.ESP, State.Aim, State.Speed = false, false, false
	setFly(false)
	updateSpeed()
	pcall(function() RunService:UnbindFromRenderStep(AIM_BIND_NAME) end)
	for model in pairs(espObjects) do destroyESP(model) end
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
	if gui then gui:Destroy() end
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
	button.TextSize = 16
	button.AutoButtonColor = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "DeagleArenaPanel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.new(0, 12, 0.3, 0)
	panel.Size = UDim2.fromOffset(170, 40)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Config.Colors.Panel
	panel.BackgroundTransparency = 0.15
	panel.Parent = gui
	do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = panel
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 6)
		padding.PaddingBottom = UDim.new(0, 6)
		padding.PaddingLeft = UDim.new(0, 6)
		padding.PaddingRight = UDim.new(0, 6)
		padding.Parent = panel
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = panel
	end

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.LayoutOrder = 2
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.BackgroundTransparency = 1
	body.Parent = panel
	do
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = body
	end

	local header = Instance.new("TextButton")
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Text = "Deagle Arena  [-]"
	styleButton(header, Config.Colors.Off)
	header.TextSize = 14
	header.Parent = panel
	header.Activated:Connect(function()
		body.Visible = not body.Visible
		header.Text = body.Visible and "Deagle Arena  [-]" or "Deagle Arena  [+]"
	end)

	for index, name in ipairs({ "ESP", "Aim", "Fly", "Speed" }) do
		local button = Instance.new("TextButton")
		button.Name = name
		button.LayoutOrder = index
		button.Size = UDim2.new(1, 0, 0, 40)
		styleButton(button, Config.Colors.Off)
		button.Parent = body
		buttons[name] = button
		refreshButton(name)
		button.Activated:Connect(function() toggle(name) end)
	end

	statusLabel = Instance.new("TextLabel")
	statusLabel.LayoutOrder = 9
	statusLabel.Size = UDim2.new(1, 0, 0, 34)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 12
	statusLabel.TextWrapped = true
	statusLabel.Text = "Targets: -"
	statusLabel.Parent = body

	local unloadButton = Instance.new("TextButton")
	unloadButton.LayoutOrder = 10
	unloadButton.Size = UDim2.new(1, 0, 0, 34)
	unloadButton.Text = "Unload"
	styleButton(unloadButton, Config.Colors.Danger)
	unloadButton.Parent = body
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

	if not attachGui(gui) then
		gui:Destroy()
		gui, flyPad, statusLabel = nil, nil, nil
		warn("[DeagleArena] panel gagal dipasang ke GUI manapun, hotkey keyboard tetap aktif")
	end
end

-- Input keyboard dan mouse (PC)
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType == Config.AimHoldInput then
		Hold.Aim = true
	elseif input.KeyCode == Config.Keys.ESP then
		toggle("ESP")
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

local lastStatusAt = 0
table.insert(connections, RunService.Heartbeat:Connect(function()
	updateESP()
	updateFly()
	if State.Speed then updateSpeed() end

	local now = os.clock()
	if statusLabel and now - lastStatusAt >= 0.5 then
		lastStatusAt = now
		if not State.ESP then getTargets() end
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

buildGui()
