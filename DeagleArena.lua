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
	AimFovPixels = 250,
	AimSmoothing = 0.25, -- 0..1, makin kecil makin halus
	TeamCheck = true,
	WallCheck = true,
	ESPMaxDistance = 2000,
	FlySpeed = 60,
	WalkSpeed = 40,
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
local gui, flyPad

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

-- ESP
local function destroyESP(player)
	local entry = espObjects[player]
	if not entry then return end
	if entry.highlight then entry.highlight:Destroy() end
	if entry.billboard then entry.billboard:Destroy() end
	espObjects[player] = nil
end

local function ensureESP(player, character)
	local entry = espObjects[player]
	if entry and entry.character == character and entry.highlight.Parent then
		return entry
	end
	destroyESP(player)

	local head = character:FindFirstChild("Head")
	if not head then return nil end

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(255, 60, 90)
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0.6
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = character

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(160, 36)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = head
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextSize = 14
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	entry = { character = character, highlight = highlight, billboard = billboard, label = label }
	espObjects[player] = entry
	return entry
end

local function updateESP()
	local _, _, myRoot = getCharacterParts(LocalPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		if not State.ESP or not isEnemy(player) then
			destroyESP(player)
		else
			local character, humanoid, root = getCharacterParts(player)
			if not character then
				destroyESP(player)
			else
				local distance = myRoot and (myRoot.Position - root.Position).Magnitude or 0
				if distance > Config.ESPMaxDistance then
					destroyESP(player)
				else
					local entry = ensureESP(player, character)
					if entry then
						entry.label.Text = string.format(
							"%s [%dm] HP %d",
							player.Name,
							math.floor(distance),
							math.floor(humanoid.Health)
						)
					end
				end
			end
		end
	end
end

-- Aimbot
local function isVisible(origin, part, character)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local result = Workspace:Raycast(origin, part.Position - origin, params)
	return result == nil or result.Instance:IsDescendantOf(character)
end

local function getAimTarget()
	local camera = Workspace.CurrentCamera
	if not camera then return nil end
	local center = camera.ViewportSize / 2
	local bestPart, bestDistance = nil, Config.AimFovPixels

	for _, player in ipairs(Players:GetPlayers()) do
		if isEnemy(player) then
			local character = getCharacterParts(player)
			local part = character and character:FindFirstChild(Config.AimPart)
			if part then
				local screenPoint, onScreen = camera:WorldToViewportPoint(part.Position)
				if onScreen then
					local d = (Vector2.new(screenPoint.X, screenPoint.Y) - center).Magnitude
					if d < bestDistance and (not Config.WallCheck or isVisible(camera.CFrame.Position, part, character)) then
						bestPart, bestDistance = part, d
					end
				end
			end
		end
	end
	return bestPart
end

local function updateAim()
	if not (State.Aim or Hold.Aim) then return end
	if not getCharacterParts(LocalPlayer) then return end
	local camera = Workspace.CurrentCamera
	local target = getAimTarget()
	if not camera or not target then return end
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

	-- Arah horizontal dari joystick/WASD bawaan Roblox, kemiringan dari arah kamera.
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
	for player in pairs(espObjects) do destroyESP(player) end
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
	panel.Size = UDim2.fromOffset(150, 40)
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

	local unloadButton = Instance.new("TextButton")
	unloadButton.LayoutOrder = 10
	unloadButton.Size = UDim2.new(1, 0, 0, 34)
	unloadButton.Text = "Unload"
	styleButton(unloadButton, Config.Colors.Danger)
	unloadButton.Parent = body
	unloadButton.Activated:Connect(unload)

	-- Tombol naik/turun untuk terbang, tahan untuk bergerak vertikal.
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
		button.TextSize = 26
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
		gui = nil
		flyPad = nil
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

table.insert(connections, RunService.Heartbeat:Connect(function()
	updateESP()
	updateFly()
	if State.Speed then updateSpeed() end
end))

table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
	savedWalkSpeed = nil
	if State.Fly then task.defer(setFly, true) end
end))

table.insert(connections, Players.PlayerRemoving:Connect(destroyESP))

buildGui()
