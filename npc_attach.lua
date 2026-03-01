local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
local liveFolder = workspace:WaitForChild("Live")

local attached         = false
local autoRaid         = false
local isBlocking       = false
local shaEvasionActive = false
local shaHiding        = false   -- true while standing on safe part waiting out SHA
local selectedNPC      = nil
local mode             = "Behind"
local distance         = 5
local wasLowHealth     = false
local targetFilter     = ""
local yogaActive       = false
local lastYogaTime     = 0
local yogaFired        = false
local YOGA_INTERVAL    = 3

local LOW_HEALTH_THRESHOLD   = 0.35
local AIR_SAFETY_HEIGHT      = 50
local HOSTAGE_SAFE_RADIUS    = 20
local SHA_DANGER_RADIUS      = 30
local SHA_HIDE_DURATION      = 5   -- seconds to stand on safe part before returning

local SKILL_INTERVAL = 0.3
local M1_INTERVAL    = 0.1
local lastM1Time     = 0
local lastSkillTime  = 0

local SKILL_KEYS = {"Z", "X", "C", "R", "E"}
local skillIndex = 1

local KEYBINDS = {
	toggleAutoRaid = Enum.KeyCode.LeftAlt,
	toggleAttach   = Enum.KeyCode.G,
	toggleMode     = Enum.KeyCode.H,
	selectBestNPC  = Enum.KeyCode.N,
}

-- ============================================================
-- HELPERS
-- ============================================================

local function cleanName(name)
	name = string.sub(name, 2)
	return string.match(name, "^[^%d]+") or name
end

local function getRemote(name)
	local char = player.Character
	if not char then return nil end
	local ctrl = char:FindFirstChild("client_character_controller")
	if not ctrl then return nil end
	return ctrl:FindFirstChild(name)
end

local function fireM1()
	local r = getRemote("M1")
	if r then r:FireServer(true, true) end
end

local function fireSkill()
	local key = SKILL_KEYS[skillIndex]
	local r = getRemote("Skill")
	if r then r:FireServer(key, true) end
	skillIndex = skillIndex % #SKILL_KEYS + 1
end

local function firePose()
	pcall(function()
		game:GetService("VirtualInputManager"):SendKeyEvent(true, Enum.KeyCode.P, false, game)
	end)
	task.delay(0.05, function()
		pcall(function()
			game:GetService("VirtualInputManager"):SendKeyEvent(false, Enum.KeyCode.P, false, game)
		end)
		local r = getRemote("Pose")
		if r then r:FireServer() end
	end)
end

local function fireBlock(state)
	if isBlocking == state then return end
	local r = getRemote("Block")
	if r then r:FireServer(state) end
	isBlocking = state
end

local function teleportAwayFrom(pos)
	local character = player.Character
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local dir = (root.Position - pos)
	if dir.Magnitude < 1 then dir = Vector3.new(1, 0, 0) end
	character:PivotTo(CFrame.new(pos + dir.Unit * 80 + Vector3.new(0, 10, 0)))
end

local function isHostage(model)
	return string.find(string.lower(model.Name), "hostage") ~= nil
end

local function isNearHostage(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	for _, other in ipairs(liveFolder:GetChildren()) do
		if other ~= model and other:IsA("Model") and isHostage(other) then
			local otherRoot = other:FindFirstChild("HumanoidRootPart")
			if otherRoot and (otherRoot.Position - root.Position).Magnitude <= HOSTAGE_SAFE_RADIUS then
				return true
			end
		end
	end
	return false
end

local function matchesFilter(model)
	-- Filter is active whenever targetFilter has text, period
	if targetFilter == "" then return true end
	return string.find(string.lower(model.Name), targetFilter, 1, true) ~= nil
end

-- ============================================================
-- YOGA MAT PROXIMITY PROMPT
-- workspace > map > Meditation > Yoga Mat > ProximityPrompt
-- ============================================================

local function getYogaPrompt()
	local map = workspace:FindFirstChild("Map")
	if not map then return nil, nil end
	local meditation = map:FindFirstChild("Meditation")
	if not meditation then return nil, nil end
	local yogaMat = meditation:FindFirstChild("Yoga Mat")
	if not yogaMat then return nil, nil end
	local pp = yogaMat:FindFirstChildOfClass("ProximityPrompt")
	if pp then return pp, yogaMat end
	for _, d in ipairs(yogaMat:GetDescendants()) do
		if d:IsA("ProximityPrompt") then return d, yogaMat end
	end
	return nil, nil
end

local function fireDialogue(arg2)
	local remote = game:GetService("ReplicatedStorage")
		:WaitForChild("requests")
		:WaitForChild("character")
		:WaitForChild("dialogue")
	local npc = workspace:WaitForChild("Npcs"):WaitForChild("The Self")
	remote:FireServer(npc, arg2)
end

local function triggerYogaMat()
	local prompt, yogaMat = getYogaPrompt()
	if not prompt then return end

	local character = player.Character
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local promptPart = yogaMat:IsA("BasePart") and yogaMat or prompt.Parent
	if not (promptPart and promptPart:IsA("BasePart")) then return end

	local savedCFrame = root.CFrame
	local vim = game:GetService("VirtualInputManager")

	-- TP right on top of the mat AND face it (RequiresLineOfSight = true)
	character:PivotTo(CFrame.new(
		promptPart.Position + Vector3.new(0, 3, 0),
		promptPart.Position
	))

	task.delay(0.15, function()
		if not character or not character.Parent then return end

		-- Hold E for 0.65s (HoldDuration is 0.5 so this has margin)
		pcall(function() vim:SendKeyEvent(true, Enum.KeyCode.E, false, game) end)

		task.delay(0.65, function()
			pcall(function() vim:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)

			-- TP back after releasing
			task.delay(0.05, function()
				if character and character.Parent then
					character:PivotTo(savedCFrame)
				end

				-- 2s after prompt: fire dialogue(The Self, 1)
				task.delay(2, function()
					pcall(function() fireDialogue(1) end)

					-- then after 2s delay: fire dialogue(The Self, "Yes.")
					task.delay(2, function()
						pcall(function() fireDialogue("Yes.") end)
					end)
				end)
			end)
		end)
	end)
end

-- ============================================================
-- SERVER SHA + BEFOREEXPLOSION
-- ============================================================

local effectsFolder = workspace:FindFirstChild("Effects")
if not effectsFolder then
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "Effects" then effectsFolder = child end
	end)
end

local function getSHAPart()
	if not effectsFolder then return nil end
	local sha = effectsFolder:FindFirstChild("Server SHA")
	if not sha then return nil end
	if sha.PrimaryPart then return sha.PrimaryPart end
	for _, v in ipairs(sha:GetDescendants()) do
		if v:IsA("BasePart") then return v end
	end
	return nil
end

local function isSHAClose()
	local shaPart = getSHAPart()
	if not shaPart then return false end
	local char = player.Character
	if not char then return false end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	return (shaPart.Position - root.Position).Magnitude <= SHA_DANGER_RADIUS
end

local function hasBeforeExplosion()
	if not effectsFolder then return false end
	for _, child in ipairs(effectsFolder:GetChildren()) do
		if string.find(string.lower(child.Name), "beforeexplosion") then return true end
	end
	return false
end

-- ============================================================
-- (highlight dodge removed)

-- ============================================================
-- GUI
-- ============================================================

local existing = player.PlayerGui:FindFirstChild("NPC_Attach_GUI")
if existing then existing:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "NPC_Attach_GUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.new(0, 260, 0, 596)
frame.Position = UDim2.new(0.5, -130, 0.5, -298)
frame.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = false
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local outerStroke = Instance.new("UIStroke", frame)
outerStroke.Color = Color3.fromRGB(180, 30, 30)
outerStroke.Thickness = 1.5
outerStroke.Transparency = 0.3

-- Header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 44)
header.BackgroundColor3 = Color3.fromRGB(180, 25, 25)
header.BorderSizePixel = 0
header.Active = true
header.Parent = frame
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)
local headerSquare = Instance.new("Frame")
headerSquare.Size = UDim2.new(1, 0, 0.5, 0)
headerSquare.Position = UDim2.new(0, 0, 0.5, 0)
headerSquare.BackgroundColor3 = Color3.fromRGB(180, 25, 25)
headerSquare.BorderSizePixel = 0
headerSquare.Parent = header
local accentLine = Instance.new("Frame")
accentLine.Size = UDim2.new(1, 0, 0, 2)
accentLine.Position = UDim2.new(0, 0, 0, 44)
accentLine.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
accentLine.BorderSizePixel = 0
accentLine.Parent = frame
for i = 0, 2 do
	local dot = Instance.new("Frame")
	dot.Size = UDim2.new(0, 6, 0, 6)
	dot.Position = UDim2.new(0, 12 + i * 14, 0.5, -3)
	dot.BackgroundColor3 = i == 0 and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(255, 255, 255)
	dot.BackgroundTransparency = i == 0 and 0 or 0.7
	dot.BorderSizePixel = 0
	dot.Parent = header
	Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
end
local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -60, 0, 18)
titleLabel.Position = UDim2.new(0, 58, 0, 5)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "RAID TOOL"
titleLabel.TextColor3 = Color3.new(1, 1, 1)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 14
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = header
local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(1, -60, 0, 12)
subtitle.Position = UDim2.new(0, 58, 0, 26)
subtitle.BackgroundTransparency = 1
subtitle.Text = "NPC ATTACH  //  AUTO MODE"
subtitle.TextColor3 = Color3.fromRGB(255, 180, 180)
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 9
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header
local dragHint = Instance.new("TextLabel")
dragHint.Size = UDim2.new(0, 50, 0, 10)
dragHint.Position = UDim2.new(1, -54, 0, 17)
dragHint.BackgroundTransparency = 1
dragHint.Text = "drag ↕"
dragHint.TextColor3 = Color3.fromRGB(255, 160, 160)
dragHint.Font = Enum.Font.Gotham
dragHint.TextSize = 8
dragHint.TextXAlignment = Enum.TextXAlignment.Right
dragHint.Parent = header

-- Header drag
local draggingFrame = false
local dragStart, frameStart = nil, nil
header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		draggingFrame = true dragStart = input.Position frameStart = frame.Position
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		draggingFrame = false
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if draggingFrame and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(frameStart.X.Scale, frameStart.X.Offset + delta.X, frameStart.Y.Scale, frameStart.Y.Offset + delta.Y)
	end
end)

-- Builders
local function makeSection(text, yPos)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -20, 0, 14)
	lbl.Position = UDim2.new(0, 10, 0, yPos)
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.TextColor3 = Color3.fromRGB(180, 50, 50)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 10
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = frame
	return lbl
end

local function makeButton(text, yPos, h, bgColor)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -20, 0, h or 32)
	btn.Position = UDim2.new(0, 10, 0, yPos)
	btn.BackgroundColor3 = bgColor or Color3.fromRGB(22, 22, 28)
	btn.BorderSizePixel = 0
	btn.Text = text
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 12
	btn.AutoButtonColor = false
	btn.Parent = frame
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Color = Color3.fromRGB(50, 50, 60)
	stroke.Thickness = 1
	btn.MouseEnter:Connect(function() stroke.Color = Color3.fromRGB(180, 30, 30) stroke.Thickness = 1.5 end)
	btn.MouseLeave:Connect(function() stroke.Color = Color3.fromRGB(50, 50, 60) stroke.Thickness = 1 end)
	return btn, stroke
end

-- ── PLAYER FILTER ────────────────────────────────────────────
makeSection("PLAYER FILTER", 58)

-- Text input row
local filterBg = Instance.new("Frame")
filterBg.Size = UDim2.new(1, -20, 0, 30)
filterBg.Position = UDim2.new(0, 10, 0, 76)
filterBg.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
filterBg.BorderSizePixel = 0
filterBg.Parent = frame
Instance.new("UICorner", filterBg).CornerRadius = UDim.new(0, 6)
local filterStroke = Instance.new("UIStroke", filterBg)
filterStroke.Color = Color3.fromRGB(50, 50, 60)
filterStroke.Thickness = 1

local filterBox = Instance.new("TextBox")
filterBox.Size = UDim2.new(1, -40, 1, -6)
filterBox.Position = UDim2.new(0, 10, 0, 3)
filterBox.BackgroundTransparency = 1
filterBox.Text = ""
filterBox.PlaceholderText = "enter username..."
filterBox.PlaceholderColor3 = Color3.fromRGB(65, 65, 75)
filterBox.TextColor3 = Color3.new(1, 1, 1)
filterBox.Font = Enum.Font.Gotham
filterBox.TextSize = 11
filterBox.TextXAlignment = Enum.TextXAlignment.Left
filterBox.ClearTextOnFocus = false
filterBox.Parent = filterBg

local clearFilterBtn = Instance.new("TextButton")
clearFilterBtn.Size = UDim2.new(0, 24, 0, 22)
clearFilterBtn.Position = UDim2.new(1, -28, 0.5, -11)
clearFilterBtn.BackgroundColor3 = Color3.fromRGB(80, 16, 16)
clearFilterBtn.BorderSizePixel = 0
clearFilterBtn.Text = "✕"
clearFilterBtn.TextColor3 = Color3.new(1,1,1)
clearFilterBtn.Font = Enum.Font.GothamBold
clearFilterBtn.TextSize = 10
clearFilterBtn.AutoButtonColor = false
clearFilterBtn.Parent = filterBg
Instance.new("UICorner", clearFilterBtn).CornerRadius = UDim.new(0, 4)
clearFilterBtn.MouseButton1Click:Connect(function()
	filterBox.Text = ""
	targetFilter = ""
	filterStroke.Color = Color3.fromRGB(50, 50, 60)
end)

filterBox:GetPropertyChangedSignal("Text"):Connect(function()
	targetFilter = string.lower(filterBox.Text)
	filterStroke.Color = targetFilter ~= "" and Color3.fromRGB(220, 50, 50) or Color3.fromRGB(50, 50, 60)
	if selectedNPC and targetFilter ~= "" and not matchesFilter(selectedNPC) then
		selectedNPC = nil
	end
end)

-- Filter toggle button (separate button as requested)
local filterActiveBtn, filterActiveBtnStroke = makeButton("🔍  FILTER: OFF", 112, 28, Color3.fromRGB(18, 18, 24))
filterActiveBtnStroke.Color = Color3.fromRGB(50, 50, 60)
local filterEnabled = false
filterActiveBtn.MouseButton1Click:Connect(function()
	filterEnabled = not filterEnabled
	if filterEnabled then
		filterActiveBtn.Text = "🔍  FILTER: ON  (".. (targetFilter ~= "" and targetFilter or "any") ..")"
		filterActiveBtn.BackgroundColor3 = Color3.fromRGB(0, 20, 36)
		filterActiveBtnStroke.Color = Color3.fromRGB(0, 140, 220)
	else
		filterBox.Text = ""
		targetFilter = ""
		filterActiveBtn.Text = "🔍  FILTER: OFF"
		filterActiveBtn.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
		filterActiveBtnStroke.Color = Color3.fromRGB(50, 50, 60)
		filterStroke.Color = Color3.fromRGB(50, 50, 60)
	end
end)

-- Auto-enable filter button when user types
filterBox:GetPropertyChangedSignal("Text"):Connect(function()
	targetFilter = string.lower(filterBox.Text)
	if targetFilter ~= "" then
		filterEnabled = true
		filterActiveBtn.Text = "🔍  FILTER: ON  ("..targetFilter..")"
		filterActiveBtn.BackgroundColor3 = Color3.fromRGB(0, 20, 36)
		filterActiveBtnStroke.Color = Color3.fromRGB(0, 140, 220)
		filterStroke.Color = Color3.fromRGB(220, 50, 50)
	else
		filterEnabled = false
		filterActiveBtn.Text = "🔍  FILTER: OFF"
		filterActiveBtn.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
		filterActiveBtnStroke.Color = Color3.fromRGB(50, 50, 60)
		filterStroke.Color = Color3.fromRGB(50, 50, 60)
	end
	if selectedNPC and targetFilter ~= "" and not matchesFilter(selectedNPC) then
		selectedNPC = nil
	end
end)

-- ── TARGET ───────────────────────────────────────────────────
makeSection("TARGET", 152)
local dropdown, _ = makeButton("⬡  Select NPC  [N]", 170, 32)
dropdown.TextXAlignment = Enum.TextXAlignment.Left
Instance.new("UIPadding", dropdown).PaddingLeft = UDim.new(0, 10)

local npcHealthBg = Instance.new("Frame")
npcHealthBg.Size = UDim2.new(1, -20, 0, 4)
npcHealthBg.Position = UDim2.new(0, 10, 0, 204)
npcHealthBg.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
npcHealthBg.BorderSizePixel = 0
npcHealthBg.Parent = frame
Instance.new("UICorner", npcHealthBg).CornerRadius = UDim.new(1, 0)
local npcHealthFill = Instance.new("Frame")
npcHealthFill.Size = UDim2.new(0, 0, 1, 0)
npcHealthFill.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
npcHealthFill.BorderSizePixel = 0
npcHealthFill.Parent = npcHealthBg
Instance.new("UICorner", npcHealthFill).CornerRadius = UDim.new(1, 0)
local npcHealthLabel = Instance.new("TextLabel")
npcHealthLabel.Size = UDim2.new(1, -20, 0, 12)
npcHealthLabel.Position = UDim2.new(0, 10, 0, 210)
npcHealthLabel.BackgroundTransparency = 1
npcHealthLabel.Text = "No target selected"
npcHealthLabel.TextColor3 = Color3.fromRGB(100, 100, 110)
npcHealthLabel.Font = Enum.Font.Gotham
npcHealthLabel.TextSize = 9
npcHealthLabel.TextXAlignment = Enum.TextXAlignment.Left
npcHealthLabel.Parent = frame

-- ── MODE ─────────────────────────────────────────────────────
makeSection("POSITION MODE", 230)
local modeButton, modeStroke = makeButton("◈  Mode: Behind  [H]", 248, 32)
modeButton.TextXAlignment = Enum.TextXAlignment.Left
Instance.new("UIPadding", modeButton).PaddingLeft = UDim.new(0, 10)

-- ── DISTANCE ─────────────────────────────────────────────────
makeSection("DISTANCE", 290)
local distanceValues = {5, 10, 15, 20}
local distanceButtons = {}
local btnW = (260 - 20 - 9) / 4
for i, val in ipairs(distanceValues) do
	local isSelected = val == distance
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, btnW, 0, 28)
	btn.Position = UDim2.new(0, 10 + (i-1) * (btnW + 3), 0, 308)
	btn.BackgroundColor3 = isSelected and Color3.fromRGB(160, 25, 25) or Color3.fromRGB(22, 22, 28)
	btn.BorderSizePixel = 0
	btn.Text = tostring(val)
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 12
	btn.AutoButtonColor = false
	btn.Parent = frame
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Color = isSelected and Color3.fromRGB(220, 50, 50) or Color3.fromRGB(50, 50, 60)
	stroke.Thickness = 1
	distanceButtons[val] = {btn = btn, stroke = stroke}
	btn.MouseButton1Click:Connect(function()
		distance = val
		for _, dval in ipairs(distanceValues) do
			local db = distanceButtons[dval]
			if dval == val then
				db.btn.BackgroundColor3 = Color3.fromRGB(160, 25, 25)
				db.stroke.Color = Color3.fromRGB(220, 50, 50)
			else
				db.btn.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
				db.stroke.Color = Color3.fromRGB(50, 50, 60)
			end
		end
	end)
end

-- ── SKILLS ───────────────────────────────────────────────────
makeSection("SKILLS  (auto-cycles)", 346)
local skillRowBg = Instance.new("Frame")
skillRowBg.Size = UDim2.new(1, -20, 0, 28)
skillRowBg.Position = UDim2.new(0, 10, 0, 362)
skillRowBg.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
skillRowBg.BorderSizePixel = 0
skillRowBg.Parent = frame
Instance.new("UICorner", skillRowBg).CornerRadius = UDim.new(0, 6)
Instance.new("UIStroke", skillRowBg).Color = Color3.fromRGB(40, 40, 50)
local skillIndicators = {}
local keyW = (240 - 8) / #SKILL_KEYS
for i, key in ipairs(SKILL_KEYS) do
	local pip = Instance.new("TextLabel")
	pip.Size = UDim2.new(0, keyW, 1, -6)
	pip.Position = UDim2.new(0, 4 + (i-1) * keyW, 0, 3)
	pip.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
	pip.Text = key
	pip.TextColor3 = Color3.fromRGB(140, 140, 160)
	pip.Font = Enum.Font.GothamBold
	pip.TextSize = 11
	pip.BorderSizePixel = 0
	pip.Parent = skillRowBg
	Instance.new("UICorner", pip).CornerRadius = UDim.new(0, 4)
	skillIndicators[i] = pip
end
local function updateSkillIndicator()
	for i, pip in ipairs(skillIndicators) do
		if i == skillIndex then
			pip.BackgroundColor3 = Color3.fromRGB(160, 25, 25)
			pip.TextColor3 = Color3.new(1, 1, 1)
		else
			pip.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
			pip.TextColor3 = Color3.fromRGB(140, 140, 160)
		end
	end
end

-- ── YOGA MAT ─────────────────────────────────────────────────
makeSection("YOGA MAT", 400)
local yogaButton, yogaStroke = makeButton("🧘  Yoga Mat Prompt: OFF", 418, 32, Color3.fromRGB(18, 18, 24))
yogaStroke.Color = Color3.fromRGB(50, 50, 60)
yogaButton.MouseButton1Click:Connect(function()
	yogaActive = not yogaActive
	if yogaActive then
		yogaButton.Text = "🧘  Yoga Mat Prompt: ON"
		yogaButton.BackgroundColor3 = Color3.fromRGB(0, 20, 16)
		yogaStroke.Color = Color3.fromRGB(0, 200, 120)
	else
		yogaButton.Text = "🧘  Yoga Mat Prompt: OFF"
		yogaButton.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
		yogaStroke.Color = Color3.fromRGB(50, 50, 60)
	end
end)

-- ── CONTROL ──────────────────────────────────────────────────
makeSection("CONTROL", 460)
local attachButton, attachStroke = makeButton("▶  ATTACH  [G]", 478, 36, Color3.fromRGB(18, 18, 24))
attachStroke.Color = Color3.fromRGB(80, 80, 100)
local autoRaidButton, autoStroke = makeButton("⚡  AUTO RAID: OFF  [ALT]", 520, 36, Color3.fromRGB(18, 18, 24))
autoStroke.Color = Color3.fromRGB(80, 80, 100)

-- Keybind hint
local keybindHint = Instance.new("TextLabel")
keybindHint.Size = UDim2.new(1, -20, 0, 12)
keybindHint.Position = UDim2.new(0, 10, 0, 562)
keybindHint.BackgroundTransparency = 1
keybindHint.Text = "ALT = raid   G = attach   H = mode   N = best npc"
keybindHint.TextColor3 = Color3.fromRGB(55, 55, 65)
keybindHint.Font = Enum.Font.Gotham
keybindHint.TextSize = 8
keybindHint.TextXAlignment = Enum.TextXAlignment.Center
keybindHint.Parent = frame

-- Status bar
local statusBg = Instance.new("Frame")
statusBg.Size = UDim2.new(1, -20, 0, 24)
statusBg.Position = UDim2.new(0, 10, 0, 578)
statusBg.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
statusBg.BorderSizePixel = 0
statusBg.Parent = frame
Instance.new("UICorner", statusBg).CornerRadius = UDim.new(0, 6)
local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.new(0, 6, 0, 6)
statusDot.Position = UDim2.new(0, 8, 0.5, -3)
statusDot.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
statusDot.BorderSizePixel = 0
statusDot.Parent = statusBg
Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 1, 0)
statusLabel.Position = UDim2.new(0, 22, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Idle"
statusLabel.TextColor3 = Color3.fromRGB(100, 100, 110)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 10
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = statusBg

local function setStatus(text, color)
	statusLabel.Text = text
	statusLabel.TextColor3 = color or Color3.fromRGB(100, 100, 110)
	statusDot.BackgroundColor3 = color or Color3.fromRGB(60, 60, 70)
end

-- ============================================================
-- NPC LOGIC
-- ============================================================

local npcList  = {}
local npcIndex = 0

local function refreshNPCs()
	npcList = {}
	for _, model in ipairs(liveFolder:GetChildren()) do
		if model:IsA("Model")
		and string.sub(model.Name, 1, 1) == "."
		and model:FindFirstChild("Humanoid")
		and model:FindFirstChild("HumanoidRootPart")
		and not isHostage(model)
		and not isNearHostage(model)
		and matchesFilter(model) then   -- always enforced when text is set
			table.insert(npcList, model)
		end
	end
	if selectedNPC and not table.find(npcList, selectedNPC) then
		selectedNPC = nil
		dropdown.Text = "⬡  Select NPC  [N]"
		npcHealthFill.Size = UDim2.new(0, 0, 1, 0)
		npcHealthLabel.Text = "No target selected"
	end
end

local function getBestNPC()
	local character = player.Character
	if not character then return nil end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return nil end
	local best, bestScore = nil, math.huge
	for _, model in ipairs(npcList) do
		local npcRoot  = model:FindFirstChild("HumanoidRootPart")
		local npcHuman = model:FindFirstChild("Humanoid")
		if npcRoot and npcHuman and npcHuman.MaxHealth > 0 and npcHuman.Health > 0 then
			local dist      = (npcRoot.Position - rootPart.Position).Magnitude
			local healthPct = npcHuman.Health / npcHuman.MaxHealth
			local score     = healthPct * 0.6 + (dist / 500) * 0.4
			if score < bestScore then bestScore = score best = model end
		end
	end
	return best
end

local function detachPlayer()
	attached = false
	wasLowHealth = false
	lastM1Time = 0
	lastSkillTime = 0
	attachButton.Text = "▶  ATTACH  [G]"
	attachStroke.Color = Color3.fromRGB(80, 80, 100)
	setStatus("Idle")
	local character = player.Character
	if character then
		local h = character:FindFirstChildOfClass("Humanoid")
		if h then h.PlatformStand = false h.AutoRotate = true end
	end
end

local function doAttach()
	attached = true
	attachButton.Text = "◼  DETACH  [G]"
	attachStroke.Color = Color3.fromRGB(180, 30, 30)
	setStatus("Attached", Color3.fromRGB(180, 30, 30))
	local character = player.Character
	if not character then return end
	local h = character:FindFirstChildOfClass("Humanoid")
	if h then h.PlatformStand = true h.AutoRotate = false end
end

local function updateNPCHealthBar()
	if selectedNPC then
		local h = selectedNPC:FindFirstChild("Humanoid")
		if h and h.MaxHealth > 0 then
			local pct = h.Health / h.MaxHealth
			npcHealthFill.Size = UDim2.new(pct, 0, 1, 0)
			local r = math.floor(math.clamp(2 - pct * 2, 0, 1) * 220 + 35)
			local g = math.floor(math.clamp(pct * 2, 0, 1) * 180)
			npcHealthFill.BackgroundColor3 = Color3.fromRGB(r, g, 30)
			npcHealthLabel.Text = cleanName(selectedNPC.Name).."  "..math.floor(h.Health).." / "..math.floor(h.MaxHealth)
			return
		end
	end
	npcHealthFill.Size = UDim2.new(0, 0, 1, 0)
	npcHealthLabel.Text = "No target selected"
end

-- ============================================================
-- TOGGLE FUNCTIONS
-- ============================================================

local function toggleAutoRaid()
	autoRaid = not autoRaid
	if autoRaid then
		autoRaidButton.Text = "⚡  AUTO RAID: ON  [ALT]"
		autoStroke.Color = Color3.fromRGB(220, 180, 0)
		autoRaidButton.BackgroundColor3 = Color3.fromRGB(22, 18, 0)
	else
		autoRaidButton.Text = "⚡  AUTO RAID: OFF  [ALT]"
		autoStroke.Color = Color3.fromRGB(80, 80, 100)
		autoRaidButton.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
		detachPlayer()
		fireBlock(false)
		shaEvasionActive = false
		selectedNPC = nil
		dropdown.Text = "⬡  Select NPC  [N]"
		npcHealthFill.Size = UDim2.new(0, 0, 1, 0)
		npcHealthLabel.Text = "No target selected"
	end
end

local function toggleAttach()
	if attached then detachPlayer() else doAttach() end
end

local function toggleMode()
	mode = (mode == "Behind") and "OnTop" or "Behind"
	modeButton.Text = "◈  Mode: "..mode.."  [H]"
end

local function selectBestNPC()
	refreshNPCs()
	local best = getBestNPC()
	if best then
		selectedNPC = best
		dropdown.Text = "⬡  "..cleanName(selectedNPC.Name).." ★  [N]"
	elseif #npcList > 0 then
		npcIndex = npcIndex % #npcList + 1
		selectedNPC = npcList[npcIndex]
		dropdown.Text = "⬡  "..cleanName(selectedNPC.Name).."  [N]"
	end
end

-- ============================================================
-- CONNECTIONS
-- ============================================================

liveFolder.ChildAdded:Connect(refreshNPCs)
liveFolder.ChildRemoved:Connect(refreshNPCs)
refreshNPCs()

dropdown.MouseButton1Click:Connect(selectBestNPC)
modeButton.MouseButton1Click:Connect(toggleMode)
attachButton.MouseButton1Click:Connect(toggleAttach)
autoRaidButton.MouseButton1Click:Connect(toggleAutoRaid)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if     input.KeyCode == KEYBINDS.toggleAutoRaid then toggleAutoRaid()
	elseif input.KeyCode == KEYBINDS.toggleAttach   then toggleAttach()
	elseif input.KeyCode == KEYBINDS.toggleMode     then toggleMode()
	elseif input.KeyCode == KEYBINDS.selectBestNPC  then selectBestNPC()
	end
end)

if player.Character then end  -- no highlight setup needed
player.CharacterAdded:Connect(function(character)
	detachPlayer()
	isBlocking = false
	shaEvasionActive = false
	shaHiding = false
	autoRaid = false
	yogaFired = false
	selectedNPC = nil

	-- Keep autoRaid state but pause everything for 3 seconds
	local wasAutoRaiding = autoRaid
	autoRaid = false
	attachButton.Text = "▶  ATTACH  [G]"
	attachStroke.Color = Color3.fromRGB(80, 80, 100)
	autoRaidButton.Text = "⚡  AUTO RAID: OFF  [ALT]"
	autoStroke.Color = Color3.fromRGB(80, 80, 100)
	autoRaidButton.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	dropdown.Text = "⬡  Select NPC  [N]"
	npcHealthFill.Size = UDim2.new(0, 0, 1, 0)
	npcHealthLabel.Text = "No target selected"
	setStatus("💀 Respawning... 8s", Color3.fromRGB(150, 150, 160))

	task.delay(8, function()
		if wasAutoRaiding then
			autoRaid = true
			autoRaidButton.Text = "⚡  AUTO RAID: ON  [ALT]"
			autoStroke.Color = Color3.fromRGB(220, 180, 0)
			autoRaidButton.BackgroundColor3 = Color3.fromRGB(22, 18, 0)
			setStatus("Idle")
		end
	end)
end)

-- ============================================================
-- MAIN LOOP
-- ============================================================

RunService.RenderStepped:Connect(function()
	local now = tick()

	updateNPCHealthBar()
	updateSkillIndicator()

	-- Yoga Mat auto prompt (only once per NPC kill)
	if yogaActive and not yogaFired and now - lastYogaTime >= YOGA_INTERVAL then
		lastYogaTime = now
		yogaFired = true
		triggerYogaMat()
	end

	-- SHA detection — spawn a safe part to stand on, wait 5s, resume
	local shaClose      = isSHAClose()
	local beforeExplode = hasBeforeExplosion()

	if beforeExplode then
		fireBlock(true)
	elseif isBlocking and not shaHiding then
		fireBlock(false)
	end

	if shaClose and not shaEvasionActive then
		shaEvasionActive = true
		shaHiding = true
		fireBlock(true)

		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root then
				-- Pick a random safe spot away from SHA
				local shaPart = getSHAPart()
				local origin = shaPart and shaPart.Position or root.Position
				local angle = math.random() * math.pi * 2
				local safeDist = math.random(40, 70)
				local safePos = Vector3.new(
					origin.X + math.cos(angle) * safeDist,
					origin.Y + 8,
					origin.Z + math.sin(angle) * safeDist
				)

				-- Spawn a platform at that spot
				local platform = Instance.new("Part")
				platform.Name = "SHA_SafePlatform"
				platform.Size = Vector3.new(6, 1, 6)
				platform.Position = safePos
				platform.Anchored = true
				platform.CanCollide = true
				platform.Transparency = 0.1
				platform.BrickColor = BrickColor.new("Dark red")
				platform.Parent = workspace

				-- Stand on it
				character:PivotTo(CFrame.new(safePos + Vector3.new(0, 3, 0)))
				setStatus("🛡 SHA — SAFE SPOT", Color3.fromRGB(100, 150, 255))

				-- After 5 seconds remove platform and resume
				task.delay(SHA_HIDE_DURATION, function()
					pcall(function() platform:Destroy() end)
					fireBlock(false)
					shaEvasionActive = false
					shaHiding = false
				end)
			end
		end
	end

	if shaHiding then
		setStatus("🛡 SHA — SAFE SPOT", Color3.fromRGB(100, 150, 255))
		return
	end

	if not shaClose and not beforeExplode then
		if shaEvasionActive and not shaHiding then
			shaEvasionActive = false
		end
	end

	if autoRaid then
		refreshNPCs()
		if selectedNPC and (isNearHostage(selectedNPC) or not matchesFilter(selectedNPC)) then
			selectedNPC = nil
			dropdown.Text = "⬡  Select NPC  [N]"
		end
		local best = getBestNPC()
		if best and best ~= selectedNPC then
			selectedNPC = best
			dropdown.Text = "⬡  "..cleanName(selectedNPC.Name).." ★  [N]"
		end
		if selectedNPC and not attached then doAttach() end
	else
		if not attached then return end
	end

	if not (attached and selectedNPC and selectedNPC.Parent) then return end

	local npcRoot  = selectedNPC:FindFirstChild("HumanoidRootPart")
	local npcHuman = selectedNPC:FindFirstChild("Humanoid")
	local character = player.Character
	if not (npcRoot and npcHuman and character) then return end

	if isNearHostage(selectedNPC) then
		selectedNPC = nil
		dropdown.Text = "⬡  Select NPC  [N]"
		setStatus("⚠ Hostage nearby — retargeting", Color3.fromRGB(255, 200, 0))
		return
	end

	if npcHuman.Health <= 0 then
		local deathPos = npcRoot.Position
		selectedNPC = nil
		dropdown.Text = "⬡  Select NPC  [N]"
		detachPlayer()
		teleportAwayFrom(deathPos)
		yogaFired = false  -- allow yoga mat to fire again for next NPC
		setStatus("💥 Escaped explosion!", Color3.fromRGB(255, 120, 0))

		-- Trigger yoga mat again 8s after kill
		if yogaActive then
			task.delay(8, function()
				yogaFired = false
				lastYogaTime = 0
			end)
		end

		task.delay(2.5, function() if not attached then setStatus("Idle") end end)
		return
	end

	local localHuman  = character:FindFirstChildOfClass("Humanoid")
	local isLowHealth = localHuman
		and localHuman.MaxHealth > 0
		and (localHuman.Health / localHuman.MaxHealth) <= LOW_HEALTH_THRESHOLD

	if isLowHealth then
		setStatus("⚠  LOW HP — AIR SAFE", Color3.fromRGB(220, 60, 60))
		character:PivotTo(CFrame.new(
			npcRoot.Position + Vector3.new(0, AIR_SAFETY_HEIGHT, 0),
			npcRoot.Position
		))
		if not wasLowHealth then
			wasLowHealth = true
			task.delay(0.3, function()
				if wasLowHealth then firePose() end
			end)
		end
	else
		if wasLowHealth then
			wasLowHealth = false
			task.delay(0.3, function()
				if not wasLowHealth then firePose() end
			end)
		end

		setStatus("Tracking: "..cleanName(selectedNPC.Name), Color3.fromRGB(180, 30, 30))

		if mode == "Behind" then
			local offset = npcRoot.CFrame.LookVector * -distance
			character:PivotTo(CFrame.new(npcRoot.Position + offset, npcRoot.Position))
		else
			character:PivotTo(CFrame.new(
				npcRoot.Position + Vector3.new(0, distance, 0),
				npcRoot.Position - Vector3.new(0, 5, 0)
			))
		end

		if now - lastM1Time >= M1_INTERVAL then
			lastM1Time = now
			fireM1()
		end
		if now - lastSkillTime >= SKILL_INTERVAL then
			lastSkillTime = now
			fireSkill()
		end
	end
end)
