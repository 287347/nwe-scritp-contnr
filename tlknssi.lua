--[[
	WARNING: Heads up! This script has not been verified by ScriptBlox. Use at your own risk!
]]
-- LocalScript ready to paste into StarterPlayerScripts
-- Telekinesis + Mobile UI (integration: force panel integrated into the bar,
-- magnet hides Throw/Grab and shows "Force", when grabbing shows "Throw", only allows numbers)

-- GLOBAL VARIABLES
local player = game.Players.LocalPlayer
local mouse = player:GetMouse()
local camera = workspace.CurrentCamera

local holding, target, holdDistance, anchoredWhileHolding = false, nil, 10, false

local run, UIS = game:GetService("RunService"), game:GetService("UserInputService")

-- Physical forces
local vel = Instance.new("BodyVelocity")
vel.MaxForce = Vector3.new(1, 1, 1) * 1e5
vel.P = 12500

local gyro = Instance.new("BodyGyro")
gyro.MaxTorque = Vector3.new(1, 1, 1) * 1e6
gyro.P = 3000

local originalRotation = nil

-- SelectionBox (outline)
local SelectionBox = Instance.new("SelectionBox")
SelectionBox.Name = "Outline"
SelectionBox.LineThickness = 0.08
SelectionBox.Parent = game:GetService("CoreGui")

-- Magnet
local magnetActive, magnetRadius, magnetForce = false, 30, 200
local magnetObjects, gravityBackup = {}, {}
local currentRadius = magnetRadius
local magnetForceMin, magnetForceMax = 50, 2000

-- Normal throw
local throwForce, throwForceMin, throwForceMax = 1000, 100, 4000

-- Advanced visual circle
local usingDrawing = Drawing and Drawing.new and typeof(Drawing.new)=="function"
local magnetCircle, circleGui, circleImg
local circleColor = Color3.fromRGB(0,170,255)
local surfacePos, surfaceNormal = Vector3.zero, Vector3.new(0,1,0)

if usingDrawing then
	magnetCircle = Drawing.new("Circle")
	magnetCircle.Visible, magnetCircle.Transparency, magnetCircle.Color, magnetCircle.Thickness, magnetCircle.Filled = false, 1, circleColor, 2, false
else
	circleGui = Instance.new("BillboardGui")
	circleGui.Name, circleGui.Size, circleGui.SizeOffset, circleGui.AlwaysOnTop = "MagnetCircleGui", UDim2.new(2,0,2,0), Vector2.new(0,0), true
	circleGui.Parent = workspace
	circleImg = Instance.new("ImageLabel")
	circleImg.BackgroundTransparency, circleImg.Image, circleImg.ImageColor3 = 1, "rbxassetid://13523341990", circleColor
	circleImg.AnchorPoint, circleImg.Position, circleImg.Size = Vector2.new(0.5,0.5), UDim2.fromScale(0.5,0.5), UDim2.fromScale(1,1)
	circleImg.Parent, circleGui.Enabled = circleGui, false
end

-- Force GUI (CoreGui) — we keep it but hide it on mobile (integrated into the bar)
local forceGui = Instance.new("ScreenGui")
forceGui.Name = "MagnetForceGui"
forceGui.ResetOnSpawn = false
forceGui.Parent = game:GetService("CoreGui")
local forceLabel = Instance.new("TextLabel")
forceLabel.Name = "MagnetForceLabel"
forceLabel.BackgroundTransparency = 1
forceLabel.Size = UDim2.new(0, 240, 0, 48)
forceLabel.Position = UDim2.new(1, -260, 1, -60) -- bottom-right
forceLabel.TextScaled = true
forceLabel.Font = Enum.Font.GothamBold
forceLabel.TextColor3 = Color3.new(1,1,1)
forceLabel.TextStrokeTransparency = 0.5
forceLabel.Visible = true
forceLabel.Parent = forceGui

-- Mobile / PC controls
local holdLeft, holdRight, holdQ, holdE = false, false, false, false
local usingGamepad = UIS.GamepadEnabled
UIS.GamepadConnected:Connect(function() usingGamepad = true end)
UIS.GamepadDisconnected:Connect(function() usingGamepad = false end)

-- Virtual mouse (pixel coordinates)
local virtualMousePos = nil -- Vector2 in pixels; nil means not set yet
-- now the virtual cursor appears centered by default (request)
local virtualMouseCenter = Vector2.new(0.5, 0.5) -- center of screen
local virtualMouseSize = 64 -- pixels diameter
local virtualMouseEnabled = UIS.TouchEnabled -- enable virtual mouse only on touch devices

-- GUI references to update states from anywhere
local GUIrefs = {}

-- Utilities
local function isPartOfCharacter(obj)
	for _, plr in ipairs(game.Players:GetPlayers()) do
		if plr.Character and obj:IsDescendantOf(plr.Character) then return true end
	end
	return false
end

local function hasUnanchoredWeld(obj)
	for _, c in ipairs(obj:GetConnectedParts()) do
		if c ~= obj and not c.Anchored then return true end
	end
	return false
end

local function restoreGravity()
	for obj, oldGravity in pairs(gravityBackup) do
		if obj and obj:IsDescendantOf(workspace) then obj.CustomPhysicalProperties = oldGravity end
	end
	gravityBackup = {}
end

local function lerpVec3(a, b, t) return a + (b - a) * t end

-- Screen size helpers
local function getScreenSize()
	local vs = camera.ViewportSize
	return vs.X, vs.Y
end

local function computeVirtualCenterPixels()
	local sx, sy = getScreenSize()
	return Vector2.new(sx * virtualMouseCenter.X, sy * virtualMouseCenter.Y)
end

-- Initialize virtualMousePos to center if touch device
if virtualMouseEnabled then
	virtualMousePos = computeVirtualCenterPixels()
end

-- GUI hidden state
local guiHidden = false

-- getInputPosition: prioritize virtual mouse on touch devices, otherwise use real mouse (player:GetMouse for accurate viewport coords)
local function getInputPosition()
	-- If touch & virtual mouse enabled -> use virtual position
	if UIS.TouchEnabled and virtualMouseEnabled and virtualMousePos then
		return virtualMousePos.X, virtualMousePos.Y
	end
	-- For PC use player's mouse.X/Y
	if mouse and mouse.X and mouse.Y then
		return mouse.X, mouse.Y
	end
	-- Fallback
	local pos = UIS:GetMouseLocation()
	return pos.X, pos.Y
end

-- Auxiliary raycast from screen
local function raycastFromScreen(x, y, maxDist)
	local ray = camera:ScreenPointToRay(x, y)
	local dist = maxDist or 1000
	return workspace:FindPartOnRayWithIgnoreList(Ray.new(ray.Origin, ray.Direction * dist), {player.Character})
end

-- Find surface under the pointed point (used by advanced magnet)
local function getSurfaceAtPoint(point, ignore)
	local rayLength = 50
	local directions = {
		Vector3.new(0,-1,0), -- Down (floor)
		camera.CFrame.LookVector, -- Forward (wall)
		-camera.CFrame.LookVector, -- Back
	}
	for _,dir in ipairs(directions) do
		local ray = Ray.new(point, dir * rayLength)
		local part, pos, norm = workspace:FindPartOnRayWithIgnoreList(ray, ignore or {})
		if part then return pos, norm end
	end
	return point, Vector3.new(0,1,0)
end

-- Update button appearance based on states
local function updateButtonStates()
	-- Magnet and Grab change color when active
	if GUIrefs.magnetBtn then
		if magnetActive then
			GUIrefs.magnetBtn.BackgroundColor3 = Color3.fromRGB(25,130,255)
			GUIrefs.magnetBtn.TextColor3 = Color3.fromRGB(255,255,255)
			GUIrefs.magnetBtn.Text = "Magnet ✓"
		else
			GUIrefs.magnetBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
			GUIrefs.magnetBtn.TextColor3 = Color3.fromRGB(240,240,240)
			GUIrefs.magnetBtn.Text = "Magnet"
		end
	end
	if GUIrefs.grabBtn then
		if holding then
			GUIrefs.grabBtn.BackgroundColor3 = Color3.fromRGB(45,195,100)
			GUIrefs.grabBtn.Text = "Release"
		else
			GUIrefs.grabBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
			GUIrefs.grabBtn.Text = "Grab"
		end
	end
	-- Anchor visual (if there is an object and anchored)
	if GUIrefs.anchorBtn then
		if anchoredWhileHolding then
			GUIrefs.anchorBtn.BackgroundColor3 = Color3.fromRGB(200,160,60)
			GUIrefs.anchorBtn.Text = "Anchored"
		else
			GUIrefs.anchorBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
			GUIrefs.anchorBtn.Text = "Anchor"
		end
	end
end

-- Visual of the virtual mouse and magnet radius overlay in UI
local radiusScreenScale = 2.0 -- factor to convert magnetRadius to pixels in UI (adjustable)
local function updateVMVisuals()
	local screenX, screenY = getScreenSize()
	if not GUIrefs.screenGui then return end
	-- Virtual mouse frame (position)
	if GUIrefs.vm and virtualMousePos then
		local px = math.clamp(virtualMousePos.X - virtualMouseSize/2, 0, screenX - virtualMouseSize)
		local py = math.clamp(virtualMousePos.Y - virtualMouseSize/2, 0, screenY - virtualMouseSize)
		GUIrefs.vm.Position = UDim2.new(0, px, 0, py)
	end
	-- Magnet overlay on UI: center at virtualMousePos (or mouse pos)
	if GUIrefs.vmCircle then
		local cx, cy = getInputPosition()
		local radPx = math.clamp(math.floor(magnetRadius * radiusScreenScale), 8, math.min(screenX, screenY))
		GUIrefs.vmCircle.Size = UDim2.new(0, radPx*2, 0, radPx*2)
		GUIrefs.vmCircle.Position = UDim2.new(0, cx - radPx, 0, cy - radPx)
		GUIrefs.vmCircle.ImageColor3 = magnetActive and Color3.fromRGB(60,170,255) or Color3.fromRGB(80,80,80)
		GUIrefs.vmCircle.Visible = not guiHidden
	end
end

-- =======================
-- CREATE IMPROVED MOBILE INTERFACE
-- =======================

local draggingWidget = nil -- nil or string id ("hide"/"vm"/"bar")
local barHeight = 86
local barBottomOffset = 80 -- will be adjusted by alignBarToJumpButton
local jumpButtonDetected = nil

-- Find a possible jump button and return its GUIObject (or nil)
local function findJumpButton()
	local function searchIn(container)
		for _, obj in ipairs(container:GetDescendants()) do
			if obj:IsA("GuiObject") then
				local name = (obj.Name or ""):lower()
				if name:match("jump") or name:match("jumpbutton") or name:match("jump_frame") or name:match("jumpbuttonimage") then
					if obj.Visible and obj.AbsoluteSize and obj.AbsoluteSize.Y > 10 then
						return obj
					end
				end
			end
		end
		return nil
	end

	if player:FindFirstChild("PlayerGui") then
		local found = searchIn(player.PlayerGui)
		if found then return found end
	end
	local core = game:GetService("CoreGui")
	local ok, res = pcall(function() return searchIn(core) end)
	if ok and res then return res end

	-- heuristic fallback bottom-right
	if player:FindFirstChild("PlayerGui") then
		local fallback
		local sx, sy = getScreenSize()
		for _, obj in ipairs(player.PlayerGui:GetDescendants()) do
			if obj:IsA("GuiObject") and obj.Visible and obj.AbsoluteSize and obj.AbsoluteSize.Y > 10 then
				local centerY = obj.AbsolutePosition.Y + obj.AbsoluteSize.Y * 0.5
				local centerX = obj.AbsolutePosition.X + obj.AbsoluteSize.X * 0.5
				if centerX > sx * 0.55 and centerY > sy * 0.45 then
					fallback = obj
					break
				end
			end
		end
		return fallback
	end

	return nil
end

local function alignBarToJumpButton(bottomBar)
	local sx, sy = getScreenSize()
	if not bottomBar then return end
	if not jumpButtonDetected or not jumpButtonDetected.Parent then
		jumpButtonDetected = findJumpButton()
	end
	if jumpButtonDetected and jumpButtonDetected.AbsoluteSize and jumpButtonDetected.AbsoluteSize.Y > 0 then
		local jumpCenterY = jumpButtonDetected.AbsolutePosition.Y + jumpButtonDetected.AbsoluteSize.Y * 0.5
		local newOffset = math.floor(sy - jumpCenterY - (barHeight * 0.5))
		newOffset = math.clamp(newOffset, 0, math.max(0, sy - barHeight))
		barBottomOffset = newOffset
		-- keep current left
		local leftPx = bottomBar.AbsolutePosition.X
		bottomBar.Position = UDim2.new(0, leftPx, 1, -barBottomOffset)
	end
end

local function createGUI_Mobile()
	local playerGui = player:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LevitatoMobileGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui
	GUIrefs.screenGui = screenGui

	-- Get dimensions and adapt sizes
	local screenW, screenH = getScreenSize()
	local barWidthScale = screenW < 900 and 0.88 or 0.75
	local buttonBigW = screenW < 900 and 92 or 116
	local smallBtnW = screenW < 900 and 48 or 56
	barHeight = 86
	barBottomOffset = math.clamp(math.floor(screenH * 0.12), 60, 140)

	-- Base: semi-transparent bottom bar positioned on the left
	local bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.AnchorPoint = Vector2.new(0, 1)
	bottomBar.Size = UDim2.new(barWidthScale, 0, 0, barHeight)
	bottomBar.Position = UDim2.new(0.03, 0, 1, -barBottomOffset)
	bottomBar.BackgroundColor3 = Color3.fromRGB(20,20,20)
	bottomBar.BackgroundTransparency = 0.45
	bottomBar.BorderSizePixel = 0
	bottomBar.Parent = screenGui
	GUIrefs.bottomBar = bottomBar
	bottomBar.ClipsDescendants = true
	bottomBar.Active = true -- capture inputs so they don't pass through

	local corner = Instance.new("UICorner", bottomBar)
	corner.CornerRadius = UDim.new(0, 18)
	local stroke = Instance.new("UIStroke", bottomBar)
	stroke.Color = Color3.fromRGB(80,80,80)
	stroke.Transparency = 0.6
	stroke.Thickness = 2

	-- Padding and centered layout with uniform spacing
	local padding = Instance.new("UIPadding", bottomBar)
	padding.PaddingLeft = UDim.new(0, 18)
	padding.PaddingRight = UDim.new(0, 18)
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)

	local layout = Instance.new("UIListLayout", bottomBar)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 14)
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	-- Helper for buttons
	local function makeButton(name, text, size)
		local b = Instance.new("TextButton")
		b.Name = name
		b.Text = text
		b.Font = Enum.Font.GothamBold
		b.TextScaled = true
		b.TextColor3 = Color3.fromRGB(240,240,240)
		b.BackgroundColor3 = Color3.fromRGB(30,30,30)
		b.BackgroundTransparency = 0.55
		b.BorderSizePixel = 0
		b.Size = size or UDim2.new(0,buttonBigW,0,56)
		b.AutoButtonColor = false
		b.Active = true -- capture touch; prevents pass-through
		local uic = Instance.new("UICorner", b)
		uic.CornerRadius = UDim.new(0,14)
		local vstroke = Instance.new("UIStroke", b)
		vstroke.Color = Color3.fromRGB(110,110,110)
		vstroke.Transparency = 0.6
		vstroke.Thickness = 1.2
		return b
	end

	-- Create buttons in order: Throw | Anchor | + | - | Magnet | Grab
	local throwBtn = makeButton("ThrowBtn", "Throw", UDim2.new(0,buttonBigW,0,60)); throwBtn.LayoutOrder = 1; throwBtn.Parent = bottomBar
	local anchorBtn = makeButton("AnchorBtn", "Anchor", UDim2.new(0,buttonBigW,0,60)); anchorBtn.LayoutOrder = 2; anchorBtn.Parent = bottomBar
	local zoomInBtn = makeButton("ZoomInBtn", "+", UDim2.new(0,smallBtnW,0,52)); zoomInBtn.LayoutOrder = 3; zoomInBtn.Parent = bottomBar
	local zoomOutBtn = makeButton("ZoomOutBtn", "-", UDim2.new(0,smallBtnW,0,52)); zoomOutBtn.LayoutOrder = 4; zoomOutBtn.Parent = bottomBar
	local magnetBtn = makeButton("MagnetBtn", "Magnet", UDim2.new(0,buttonBigW,0,60)); magnetBtn.LayoutOrder = 5; magnetBtn.Parent = bottomBar
	local grabBtn = makeButton("GrabBtn", "Grab", UDim2.new(0,buttonBigW,0,60)); grabBtn.LayoutOrder = 6; grabBtn.Parent = bottomBar

	GUIrefs.anchorBtn = anchorBtn
	GUIrefs.zoomInBtn = zoomInBtn
	GUIrefs.zoomOutBtn = zoomOutBtn
	GUIrefs.magnetBtn = magnetBtn
	GUIrefs.grabBtn = grabBtn
	GUIrefs.throwBtn = throwBtn

	-- HideBtn: fixed by default, movable only with short long-press (0.1s)
	local hideBtn = Instance.new("TextButton")
	hideBtn.Name = "HideBtn"
	hideBtn.Text = "⦿"
	hideBtn.Font = Enum.Font.GothamBold
	hideBtn.TextScaled = true
	hideBtn.TextColor3 = Color3.fromRGB(255,255,255)
	hideBtn.BackgroundColor3 = Color3.fromRGB(20,20,20)
	hideBtn.BackgroundTransparency = 0.5
	hideBtn.Size = UDim2.new(0,48,0,48)
	hideBtn.AnchorPoint = Vector2.new(1,0)
	hideBtn.Position = UDim2.new(1, -18, 0, 18)
	hideBtn.Parent = screenGui
	GUIrefs.hideBtn = hideBtn
	local hideCorner = Instance.new("UICorner", hideBtn); hideCorner.CornerRadius = UDim.new(0, 12)
	local hideStroke = Instance.new("UIStroke", hideBtn); hideStroke.Color = Color3.fromRGB(100,100,100); hideStroke.Transparency = 0.5; hideStroke.Thickness = 2
	hideBtn.Active = true

	-- Virtual mouse visual
	local vm = Instance.new("TextButton")
	vm.Name = "VirtualMouse"
	vm.AnchorPoint = Vector2.new(0, 0)
	vm.Size = UDim2.new(0, virtualMouseSize, 0, virtualMouseSize)
	vm.BackgroundTransparency = 0.6
	vm.BackgroundColor3 = Color3.fromRGB(10,10,10)
	vm.Text = ""
	vm.AutoButtonColor = false
	vm.Parent = screenGui
	GUIrefs.vm = vm
	local vmCorner = Instance.new("UICorner", vm); vmCorner.CornerRadius = UDim.new(1,0)
	local vmStroke = Instance.new("UIStroke", vm); vmStroke.Color = Color3.fromRGB(60,160,255); vmStroke.Transparency = 0.4; vmStroke.Thickness = 2
	local vmDot = Instance.new("Frame"); vmDot.Name = "Dot"; vmDot.AnchorPoint = Vector2.new(0.5,0.5); vmDot.Size = UDim2.new(0,12,0,12); vmDot.Position = UDim2.fromScale(0.5,0.5); vmDot.BackgroundColor3 = Color3.fromRGB(60,160,255); vmDot.Parent = vm; local vmDotCorner = Instance.new("UICorner", vmDot); vmDotCorner.CornerRadius = UDim.new(1,0)

	-- Overlay circle image to represent magnet radius on screen
	local vmCircle = Instance.new("ImageLabel")
	vmCircle.Name = "VirtualMagnetCircle"
	vmCircle.BackgroundTransparency = 1
	vmCircle.Image = "rbxassetid://13523341990"
	vmCircle.ImageColor3 = circleColor
	vmCircle.AnchorPoint = Vector2.new(0,0)
	vmCircle.Size = UDim2.new(0, 100, 0, 100)
	vmCircle.Position = UDim2.new(0, 0, 0, 0)
	vmCircle.ZIndex = 2
	vmCircle.Visible = false
	vmCircle.Parent = screenGui
	GUIrefs.vmCircle = vmCircle

	-- Drag handle (button) with "<>"
	local dragHandle = Instance.new("TextButton")
	dragHandle.Name = "DragHandle"
	dragHandle.Size = UDim2.new(0, 48, 1, -20)
	dragHandle.LayoutOrder = 999
	dragHandle.BackgroundColor3 = Color3.fromRGB(24,24,24)
	dragHandle.BackgroundTransparency = 0.6
	dragHandle.BorderSizePixel = 0
	dragHandle.Parent = bottomBar
	dragHandle.AutoButtonColor = false
	dragHandle.Font = Enum.Font.GothamBlack
	dragHandle.Text = "<>"
	dragHandle.TextColor3 = Color3.fromRGB(200,200,200)
	dragHandle.TextScaled = true
	dragHandle.Active = true
	local dhCorner = Instance.new("UICorner", dragHandle); dhCorner.CornerRadius = UDim.new(0, 10)
	local dhStroke = Instance.new("UIStroke", dragHandle); dhStroke.Color = Color3.fromRGB(80,80,80); dhStroke.Transparency = 0.6; dhStroke.Thickness = 1

	-- Force panel placed at the end (right) inside the bar: will show "Force" or "Throw" depending on the mode
	local forcePanel = Instance.new("Frame")
	forcePanel.Name = "ForcePanel"
	forcePanel.Size = UDim2.new(0, 180, 1, -20)
	forcePanel.LayoutOrder = 998
	forcePanel.BackgroundTransparency = 1
	forcePanel.Parent = bottomBar

	local forceLabelSmall = Instance.new("TextLabel")
	forceLabelSmall.Name = "ForceLabelSmall"
	forceLabelSmall.Size = UDim2.new(0.5, 0, 1, 0)
	forceLabelSmall.Position = UDim2.new(0, 0, 0, 0)
	forceLabelSmall.BackgroundTransparency = 1
	forceLabelSmall.Font = Enum.Font.GothamBold
	forceLabelSmall.TextColor3 = Color3.fromRGB(220,220,220)
	forceLabelSmall.TextScaled = true
	forceLabelSmall.Text = "Force"
	forceLabelSmall.TextXAlignment = Enum.TextXAlignment.Left
	forceLabelSmall.Parent = forcePanel

	local forceInput = Instance.new("TextBox")
	forceInput.Name = "ForceInput"
	forceInput.Size = UDim2.new(0.5, -8, 0.7, 0)
	forceInput.Position = UDim2.new(0.5, 8, 0.15, 0)
	forceInput.BackgroundColor3 = Color3.fromRGB(35,35,35)
	forceInput.TextColor3 = Color3.fromRGB(230,230,230)
	forceInput.Font = Enum.Font.Gotham
	forceInput.TextScaled = true
	forceInput.Text = tostring(math.floor(magnetForce))
	forceInput.ClearTextOnFocus = false
	forceInput.PlaceholderText = "Value"
	forceInput.Parent = forcePanel
	local fiCorner = Instance.new("UICorner", forceInput); fiCorner.CornerRadius = UDim.new(0,8)
	local fiStroke = Instance.new("UIStroke", forceInput); fiStroke.Color = Color3.fromRGB(70,70,70); fiStroke.Transparency = 0.6

	-- Save references
	GUIrefs.dragHandle = dragHandle
	GUIrefs.forcePanel = forcePanel
	GUIrefs.forceLabelSmall = forceLabelSmall
	GUIrefs.forceInput = forceInput

	-- Position VM initially (center if virtualMousePos exists)
	local function placeVMAtPixels(p)
		local sx, sy = getScreenSize()
		vm.Position = UDim2.new(0, math.clamp(p.X - virtualMouseSize/2, 0, sx - virtualMouseSize), 0, math.clamp(p.Y - virtualMouseSize/2, 0, sy - virtualMouseSize))
	end
	if virtualMousePos then
		placeVMAtPixels(virtualMousePos)
	else
		virtualMousePos = computeVirtualCenterPixels()
		placeVMAtPixels(virtualMousePos)
	end

	-- =======================
	-- Function to update the bar based on mode: magnet / holding / normal
	-- =======================
	local function updateBarMode()
		-- If it's a touch device, hide the global force and use the integrated panel
		if UIS.TouchEnabled and forceGui then forceGui.Enabled = false end

		-- Case: if holding something -> hide Magnet and DragHandle, show panel as "Throw"
		if holding and target then
			GUIrefs.magnetBtn.Visible = false
			GUIrefs.throwBtn.Visible = true -- throw button can be changed; request: "when grabbing something hide the magnet and drag buttons and show another that says throw"
			-- hide drag handle (per request) and show the panel with "Throw" instead
			GUIrefs.dragHandle.Visible = false
			GUIrefs.forcePanel.Visible = true
			GUIrefs.forceLabelSmall.Text = "Throw"
			GUIrefs.forceInput.Text = tostring(math.floor(throwForce))
			-- optional: hide Magnet for safety (already hidden), keep other buttons
			GUIrefs.grabBtn.Visible = true -- 'Release' should be visible
			GUIrefs.throwBtn.Visible = true
		elseif magnetActive then
			-- If magnet active -> hide throw and grab and use "Force" panel
			GUIrefs.throwBtn.Visible = false
			GUIrefs.grabBtn.Visible = false
			GUIrefs.magnetBtn.Visible = true
			GUIrefs.dragHandle.Visible = true
			GUIrefs.forcePanel.Visible = true
			GUIrefs.forceLabelSmall.Text = "Force"
			GUIrefs.forceInput.Text = tostring(math.floor(magnetForce))
		else
			-- Normal mode: show all buttons and leave panel (can be hidden if preferred)
			GUIrefs.throwBtn.Visible = true
			GUIrefs.grabBtn.Visible = true
			GUIrefs.magnetBtn.Visible = true
			GUIrefs.dragHandle.Visible = true
			-- by default hide panel if not in magnet or holding mode (less intrusive)
			GUIrefs.forcePanel.Visible = false
		end
	end

	-- =======================
	-- Button connections (simple click)
	-- =======================
	magnetBtn.MouseButton1Click:Connect(function()
		-- activate/deactivate magnet
		if holding then
			pcall(function()
				game.StarterGui:SetCore("SendNotification", {
					Title = "❌ Not available",
					Text = "Release the object to activate the magnet",
					Duration = 2
				})
			end)
			return
		end
		magnetActive = not magnetActive
		if not magnetActive then restoreGravity() end
		updateButtonStates()
		updateBarMode()
		pcall(function()
			game.StarterGui:SetCore("SendNotification", {
				Title = magnetActive and "🧲 Magnet Mode ACTIVATED" or "🧲 Magnet Mode DEACTIVATED",
				Text = "Attracts only loose pieces in the blue circle",
				Duration = 2
			})
		end)
	end)
	grabBtn.MouseButton1Click:Connect(function()
		grabOrRelease()
		updateButtonStates()
		updateBarMode()
	end)
	throwBtn.MouseButton1Click:Connect(function()
		throwBtn.BackgroundColor3 = Color3.fromRGB(200,70,70)
		throw()
		wait(0.08)
		throwBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
		updateBarMode()
	end)
	anchorBtn.MouseButton1Click:Connect(function()
		toggleAnchor()
		updateButtonStates()
		updateBarMode()
	end)

	-- Zoom buttons behavior (hold)
	zoomInBtn.MouseButton1Down:Connect(function()
		holdRight = true
		zoomInBtn.BackgroundColor3 = Color3.fromRGB(70,150,255)
	end)
	zoomInBtn.MouseButton1Up:Connect(function()
		holdRight = false
		zoomInBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
	end)
	zoomInBtn.MouseLeave:Connect(function() holdRight = false; zoomInBtn.BackgroundColor3 = Color3.fromRGB(30,30,30) end)

	zoomOutBtn.MouseButton1Down:Connect(function()
		holdLeft = true
		zoomOutBtn.BackgroundColor3 = Color3.fromRGB(70,150,255)
	end)
	zoomOutBtn.MouseButton1Up:Connect(function()
		holdLeft = false
		zoomOutBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
	end)
	zoomOutBtn.MouseLeave:Connect(function() holdLeft = false; zoomOutBtn.BackgroundColor3 = Color3.fromRGB(30,30,30) end)

	-- =======================
	-- Draggable helper with requiredHold (per your request: 0.1s)
	-- =======================
	local function makeDraggableInstance(uiElement, id, requiredHold, onStart, onMove, onEnd)
		requiredHold = requiredHold or 0
		local activeInputs = {}
		uiElement.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
			if draggingWidget then return end
			local startPos = input.Position or UIS:GetMouseLocation()
			if not startPos then return end
			activeInputs[input] = {start = startPos, moved = false, ready = false, ended = false}
			-- timer for requiredHold
			if requiredHold > 0 then
				spawn(function()
					local t0 = tick()
					while tick() - t0 < requiredHold do
						if activeInputs[input] == nil or activeInputs[input].ended then return end
						wait(0.02)
					end
					if activeInputs[input] then activeInputs[input].ready = true end
				end)
			else
				activeInputs[input].ready = true
			end
			local conn
			conn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					if draggingWidget == id and onEnd then onEnd() end
					activeInputs[input] = nil
					if conn then conn:Disconnect() end
					if draggingWidget == id then draggingWidget = nil end
				end
			end)
		end)

		UIS.InputChanged:Connect(function(input)
			local info = activeInputs[input]
			if not info then return end
			local pos = input.Position or UIS:GetMouseLocation()
			if not pos then return end
			-- threshold to consider movement (avoids accidental starts)
			if not info.moved then
				if (pos - info.start).Magnitude > 8 and info.ready then
					info.moved = true
					draggingWidget = id
					if onStart then onStart(pos) end
				end
			else
				if onMove then onMove(pos) end
			end
		end)
	end

	-- Drag VM (requiredHold 0)
	makeDraggableInstance(vm, "vm", 0,
		function(startPos) virtualMousePos = Vector2.new(startPos.X, startPos.Y); placeVMAtPixels(virtualMousePos) end,
		function(pos) virtualMousePos = Vector2.new(pos.X, pos.Y); placeVMAtPixels(virtualMousePos) end,
		function() end
	)
	vm.MouseButton1Click:Connect(function()
		if draggingWidget == nil or draggingWidget == "vm" then grabOrRelease() end
	end)

	-- Drag for hideBtn (requiredHold 0.1s). Short click = toggle
	makeDraggableInstance(hideBtn, "hide", 0.1,
		function(startPos)
			local sx, sy = getScreenSize()
			local newX = math.clamp(startPos.X / sx, 0.02, 0.98)
			local newY = math.clamp(startPos.Y / sy, 0.02, 0.98)
			hideBtn.Position = UDim2.new(newX, 0, newY, 0)
		end,
		function(pos)
			local sx, sy = getScreenSize()
			local newX = math.clamp(pos.X / sx, 0.02, 0.98)
			local newY = math.clamp(pos.Y / sy, 0.02, 0.98)
			hideBtn.Position = UDim2.new(newX, 0, newY, 0)
		end,
		function() end
	)

	hideBtn.MouseButton1Click:Connect(function()
		if draggingWidget ~= nil and draggingWidget ~= "hide" then return end
		if draggingWidget == "hide" then return end
		guiHidden = not guiHidden
		if guiHidden then
			if GUIrefs.bottomBar then GUIrefs.bottomBar.Visible = false end
			if GUIrefs.vm then GUIrefs.vm.Visible = false end
			if GUIrefs.vmCircle then GUIrefs.vmCircle.Visible = false end
			if SelectionBox and SelectionBox.Parent then SelectionBox.Parent = nil end
			hideBtn.Text = "◤"
			hideBtn.BackgroundTransparency = 0
			hideBtn.BackgroundColor3 = Color3.fromRGB(30,30,30)
		else
			if GUIrefs.bottomBar then GUIrefs.bottomBar.Visible = true end
			if GUIrefs.vm then GUIrefs.vm.Visible = true end
			if SelectionBox and not SelectionBox.Parent then SelectionBox.Parent = game:GetService("CoreGui") end
			hideBtn.Text = "⦿"
			hideBtn.BackgroundTransparency = 0.5
		end
	end)

	-- Drag handle to move the bar horizontally (requiredHold 0.1s)
	makeDraggableInstance(dragHandle, "bar", 0.1,
		function(startPos)
			local startX = startPos.X
			local barLeft = bottomBar.AbsolutePosition.X
			local dragOffset = startX - barLeft
			dragHandle:SetAttribute("dragOffset", dragOffset)
		end,
		function(pos)
			local dragOffset = dragHandle:GetAttribute("dragOffset") or 0
			local sx, sy = getScreenSize()
			local barWnow = bottomBar.AbsoluteSize.X
			local newLeft = pos.X - dragOffset
			newLeft = math.clamp(newLeft, 0, math.max(0, sx - barWnow))
			bottomBar.Position = UDim2.new(0, newLeft, 1, -barBottomOffset)
		end,
		function() end
	)

	-- =======================
	-- Force Input: allow only numeric characters and apply value
	-- =======================
	local function sanitizeNumberText(s)
		-- Allow only digits and an optional decimal point
		local out = s:gsub("[^%d%.]", "")
		-- allow only one point
		local first, rest = out:match("^([%d]*%.?)(.*)")
		if first then
			-- remove extra points in 'rest'
			rest = rest:gsub("%.", "")
			out = first .. rest
		end
		-- avoid unnecessary leading zeros (leave as the user types)
		return out
	end

	forceInput:GetPropertyChangedSignal("Text"):Connect(function()
		-- filter characters on each change
		local sanitized = sanitizeNumberText(forceInput.Text or "")
		if sanitized ~= forceInput.Text then
			forceInput.Text = sanitized
		end
	end)

	forceInput.FocusLost:Connect(function(enterPressed)
		-- apply the value only if it's a valid number
		local text = forceInput.Text or ""
		local num = tonumber(text)
		if num then
			-- if the panel represents Magnet Force
			if GUIrefs.forceLabelSmall and GUIrefs.forceLabelSmall.Text == "Force" then
				num = math.clamp(num, magnetForceMin, magnetForceMax)
				magnetForce = num
				forceInput.Text = tostring(math.floor(magnetForce))
			-- if it represents Throw
			elseif GUIrefs.forceLabelSmall and GUIrefs.forceLabelSmall.Text == "Throw" then
				num = math.clamp(num, throwForceMin, throwForceMax)
				throwForce = num
				forceInput.Text = tostring(math.floor(throwForce))
			end
		else
			-- restore to current value if invalid
			if GUIrefs.forceLabelSmall and GUIrefs.forceLabelSmall.Text == "Force" then
				forceInput.Text = tostring(math.floor(magnetForce))
			else
				forceInput.Text = tostring(math.floor(throwForce))
			end
		end
	end)

	-- Show only if the device has touch
	screenGui.Enabled = UIS.TouchEnabled

	-- save UI refs for external use
	GUIrefs.bottomBar = bottomBar
	GUIrefs.throwBtn = throwBtn
	GUIrefs.anchorBtn = anchorBtn
	GUIrefs.zoomInBtn = zoomInBtn
	GUIrefs.zoomOutBtn = zoomOutBtn
	GUIrefs.magnetBtn = magnetBtn
	GUIrefs.grabBtn = grabBtn
	GUIrefs.dragHandle = dragHandle

	-- Initialize mode
	updateBarMode()
end

-- Create the mobile GUI if applicable
createGUI_Mobile()

-- Try to detect the jump button periodically and align the bar
spawn(function()
	while true do
		wait(0.5)
		if GUIrefs and GUIrefs.bottomBar then
			alignBarToJumpButton(GUIrefs.bottomBar)
		end
	end
end)

-- =======================
-- Render/Heartbeat: magnet logic, selection and visual updates
-- =======================
run.RenderStepped:Connect(function()
	-- Highlight / selection (use mouse.Target if there is mouse)
	if guiHidden then
		if SelectionBox and SelectionBox.Parent then SelectionBox.Parent = nil end
	else
		if SelectionBox and not SelectionBox.Parent then SelectionBox.Parent = game:GetService("CoreGui") end

		if magnetActive and not holding then
			SelectionBox.Adornee = nil
		else
			if holding and target then
				SelectionBox.Color3, SelectionBox.Adornee = Color3.fromRGB(0,255,0), target
			else
				local sx, sy = getInputPosition()
				local part = nil
				if not UIS.TouchEnabled and mouse and mouse.Target then
					part = mouse.Target
				else
					local hit = raycastFromScreen(sx, sy, 1000)
					part = hit
				end
				if part and part:IsA("BasePart") and not part.Anchored and not isPartOfCharacter(part) then
					SelectionBox.Color3, SelectionBox.Adornee = Color3.fromRGB(0,170,255), part
				else
					SelectionBox.Adornee = nil
				end
			end
		end
	end

	-- Update magnet in world: now its center uses getInputPosition (virtual mouse on mobile or mouse on PC)
	if magnetActive then
		local sx, sy = getInputPosition()
		local ray = camera:ScreenPointToRay(sx, sy)
		local hit, pos, norm = workspace:FindPartOnRayWithIgnoreList(Ray.new(ray.Origin, ray.Direction * 1000), {player.Character})
		if hit then
			surfacePos, surfaceNormal = lerpVec3(surfacePos,pos,0.35), lerpVec3(surfaceNormal,norm,0.35)
		else
			local defPos = ray.Origin + ray.Direction * 15
			surfacePos, surfaceNormal = lerpVec3(surfacePos,defPos,0.15), lerpVec3(surfaceNormal,Vector3.new(0,1,0),0.15)
		end
		currentRadius = currentRadius + (magnetRadius - currentRadius) * 0.25

		-- Circle color based on magnetForce
		local forcePercent = (magnetForce-magnetForceMin)/(magnetForceMax-magnetForceMin)
		local colorScale = Color3.fromHSV(0.58 + forcePercent*0.3, 1, 1)

		if usingDrawing then
			local screenPos = camera:WorldToViewportPoint(surfacePos)
			magnetCircle.Visible, magnetCircle.Position, magnetCircle.Radius = true, Vector2.new(screenPos.X, screenPos.Y), currentRadius
			magnetCircle.Color = colorScale
		else
			circleGui.Enabled, circleGui.Size = true, UDim2.new(0,currentRadius*2,0,currentRadius*2)
			circleGui.CFrame = CFrame.new(surfacePos, surfacePos + camera.CFrame.LookVector)
				* CFrame.fromMatrix(Vector3.zero,
					surfaceNormal:Cross(Vector3.new(0,1,0)).Magnitude>0.01 and surfaceNormal:Cross(Vector3.new(0,1,0)).Unit or Vector3.new(1,0,0),
					surfaceNormal,
					-surfaceNormal:Cross(Vector3.new(1,0,0)).Unit)
			circleGui.Position = surfacePos
			if circleImg then circleImg.ImageColor3 = colorScale end
		end
	else
		if usingDrawing then magnetCircle.Visible = false
		elseif circleGui then circleGui.Enabled = false end
	end

	-- Update global force GUI only if not on touch (integrated into the bar on mobile)
	if not UIS.TouchEnabled then
		if magnetActive then
			forceLabel.Visible = true
			forceLabel.Text = "Magnet force: "..math.floor(magnetForce)
			local forcePercent = (magnetForce-magnetForceMin)/(magnetForceMax-magnetForceMin)
			forceLabel.TextColor3 = Color3.fromHSV(0.58 + forcePercent*0.3, 1, 1)
		else
			forceLabel.Visible = true
			forceLabel.Text = "Throw force: "..math.floor(throwForce)
			local forcePercent = (throwForce-throwForceMin)/(throwForceMax-throwForceMin)
			forceLabel.TextColor3 = Color3.fromHSV(0.58 + forcePercent*0.3, 1, 1)
		end
	else
		-- on mobile don't show the separate label
		forceLabel.Visible = false
	end

	-- update VM visuals and button states
	updateVMVisuals()
	updateButtonStates()
end)

-- Heartbeat: object movement, magnet, distance adjustments
run.Heartbeat:Connect(function()
	-- Normal telekinesis
	if holding and target then
		if not anchoredWhileHolding then
			local grabPos
			if usingGamepad then
				grabPos = camera.CFrame.Position + camera.CFrame.LookVector.Unit * holdDistance
			else
				local sx, sy = getInputPosition()
				local ray = camera:ScreenPointToRay(sx, sy)
				grabPos = ray.Origin + ray.Direction.Unit * holdDistance
			end
			vel.Velocity = (grabPos - target.Position) * 5
			if originalRotation then
				gyro.CFrame = originalRotation + target.Position
			end
		else
			vel.Velocity = Vector3.zero
		end
	end

	-- Improved magnet block (scaled force and stuck to surfaces)
	if magnetActive then
		local center, newAttracted = surfacePos, {}
		local scaledForce = magnetForce * (magnetRadius/30)^1.5 -- force increases with radius
		local nearby = workspace:GetPartBoundsInBox(CFrame.new(center), Vector3.new(magnetRadius*2, magnetRadius*2, magnetRadius*2))
		for _, obj in ipairs(nearby) do
			if obj:IsA("BasePart") and not obj.Anchored and not isPartOfCharacter(obj)
				and not hasUnanchoredWeld(obj) and obj.Transparency < 1 and obj.CanCollide and obj ~= target then
				local distance = (obj.Position - center).Magnitude
				if distance <= magnetRadius then
					local surfPos, surfNorm = getSurfaceAtPoint(obj.Position, {player.Character})
					local towardsCenter = (center - surfPos)
					local newPos = surfPos + (towardsCenter.Magnitude>0 and towardsCenter.Unit or Vector3.new(0,0,0)) * math.min(towardsCenter.Magnitude, 1.5)
					local dirFinal = (newPos - obj.Position)
					dirFinal = dirFinal - surfNorm * dirFinal:Dot(surfNorm)
					local bv = obj:FindFirstChild("MagnetBV") or Instance.new("BodyVelocity")
					bv.Name, bv.MaxForce, bv.P = "MagnetBV", Vector3.new(1,1,1)*1e5, 15000
					if dirFinal.Magnitude > 0 then
						bv.Velocity = dirFinal.Unit * scaledForce
					else
						bv.Velocity = Vector3.zero
					end
					bv.Parent = obj
					if not gravityBackup[obj] then
						gravityBackup[obj] = obj.CustomPhysicalProperties
						obj.CustomPhysicalProperties = PhysicalProperties.new(0, 0.3, 0.5, 1, 1)
					end
					newAttracted[obj] = true
				end
			end
		end
		for obj in pairs(magnetObjects) do
			if not newAttracted[obj] then
				if obj and obj:FindFirstChild("MagnetBV") then obj.MagnetBV:Destroy() end
				if gravityBackup[obj] then obj.CustomPhysicalProperties = gravityBackup[obj]; gravityBackup[obj] = nil end
			end
		end
		magnetObjects = newAttracted
	else
		for obj in pairs(magnetObjects) do if obj and obj:FindFirstChild("MagnetBV") then obj.MagnetBV:Destroy() end end
		restoreGravity()
		magnetObjects = {}
	end

	-- Adjust distance/radius
	if magnetActive then
		if holdLeft or holdQ then magnetRadius = math.max(5, magnetRadius - 1.3)
		elseif holdRight or holdE then magnetRadius = math.min(200, magnetRadius + 1.3) end
	else
		if holdLeft or holdQ then holdDistance = math.max(2, holdDistance - 0.4)
		elseif holdRight or holdE then holdDistance = math.min(1000, holdDistance + 0.4) end
	end
end)

-- =======================
-- Main actions (used from mobile buttons and PC controls)
-- =======================
function grabOrRelease()
	-- If magnet active, indicate to release the magnet first
	if magnetActive then
		pcall(function()
			game.StarterGui:SetCore("SendNotification", {
				Title = "🧲 Magnet active",
				Text = "Release the magnet to grab objects",
				Duration = 2
			})
		end)
		return
	end

	if holding then
		originalRotation = nil
		vel.Parent, gyro.Parent, anchoredWhileHolding, target, holding = nil, nil, false, nil, false
		updateButtonStates()
	else
		-- use the input position (mouse or virtual) for raycast
		local sx, sy = getInputPosition()
		local part, pos = raycastFromScreen(sx, sy, 1000)
		if part and part:IsA("BasePart") and not isPartOfCharacter(part) then
			-- if the piece is anchored, only grab it if it was anchored by telekinesis (attribute)
			if part.Anchored and not part:GetAttribute("TelekinesisAnchored") then
				-- don't grab it (it's part of the map)
				return
			end
			-- if you anchored it, unanchor it and remove attribute
			if part.Anchored and part:GetAttribute("TelekinesisAnchored") then
				part.Anchored = false
				part:SetAttribute("TelekinesisAnchored", nil)
			end

			target, anchoredWhileHolding = part, false
			originalRotation = part.CFrame - part.Position
			gyro.CFrame = originalRotation + part.Position
			gyro.Parent = part
			vel.Velocity, vel.Parent = Vector3.zero, part
			if pos then
				holdDistance = (camera.CFrame.Position - pos).Magnitude
			else
				holdDistance = (camera.CFrame.Position - part.Position).Magnitude
			end
			holding = true
			updateButtonStates()
		end
	end
	-- visually update the bar (show Throw input if applicable)
	if GUIrefs and GUIrefs.forcePanel then
		-- call the function defined inside createGUI_Mobile updates the panel, we use a small hack: force its re-evaluation
		-- (the updateBarMode variable is local inside createGUI_Mobile; if you need to expose it, it could be refactored)
		-- As workaround, re-evaluate visibility here:
		if GUIrefs.forcePanel then
			-- simulate the same checks (minimal duplicate)
			if holding and target then
				GUIrefs.magnetBtn.Visible = false
				GUIrefs.dragHandle.Visible = false
				GUIrefs.forcePanel.Visible = true
				GUIrefs.forceLabelSmall.Text = "Throw"
				GUIrefs.forceInput.Text = tostring(math.floor(throwForce))
				GUIrefs.grabBtn.Visible = true
				GUIrefs.throwBtn.Visible = true
			elseif magnetActive then
				GUIrefs.throwBtn.Visible = false
				GUIrefs.grabBtn.Visible = false
				GUIrefs.magnetBtn.Visible = true
				GUIrefs.dragHandle.Visible = true
				GUIrefs.forcePanel.Visible = true
				GUIrefs.forceLabelSmall.Text = "Force"
				GUIrefs.forceInput.Text = tostring(math.floor(magnetForce))
			else
				GUIrefs.throwBtn.Visible = true
				GUIrefs.grabBtn.Visible = true
				GUIrefs.magnetBtn.Visible = true
				GUIrefs.dragHandle.Visible = true
				GUIrefs.forcePanel.Visible = false
			end
		end
	end
end

function throw()
	if magnetActive then
		pcall(function()
			game.StarterGui:SetCore("SendNotification", {
				Title = "🧲 Magnet active",
				Text = "Deactivate the magnet to throw objects",
				Duration = 2
			})
		end)
		return
	end

	if holding and target then
		if anchoredWhileHolding then target.Anchored, anchoredWhileHolding = false, false end
		vel.Parent, gyro.Parent, holding = nil, nil, false
		originalRotation = nil
		local impulse = Instance.new("BodyVelocity")
		impulse.Velocity = camera.CFrame.LookVector * throwForce
		impulse.MaxForce, impulse.P, impulse.Parent = Vector3.new(1,1,1)*1e6, 12500, target
		game:GetService("Debris"):AddItem(impulse, 0.5)
		target = nil
		updateButtonStates()
	end
end

function toggleAnchor()
	if magnetActive then
		pcall(function()
			game.StarterGui:SetCore("SendNotification", {
				Title = "❌ Not available",
				Text = "Release the object to activate the magnet",
				Duration = 2
			})
		end)
		return
	end

	if holding and target then
		anchoredWhileHolding = not anchoredWhileHolding
		target.Anchored = anchoredWhileHolding

		if anchoredWhileHolding then
			-- MARK with attribute that you anchored it (to be able to grab it later despite being anchored)
			target:SetAttribute("TelekinesisAnchored", true)

			vel.Parent = nil
			gyro.Parent = nil
			target.AssemblyLinearVelocity = Vector3.zero
			target.AssemblyAngularVelocity = Vector3.zero

			local humanoidRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if humanoidRoot and (humanoidRoot.Position - target.Position).Magnitude < 5 then
				humanoidRoot.Velocity = Vector3.zero
				humanoidRoot.AssemblyLinearVelocity = Vector3.zero
				humanoidRoot.CFrame = humanoidRoot.CFrame + Vector3.new(0, 3, 0)
			end
		else
			-- REMOVE the attribute when unanchoring
			target:SetAttribute("TelekinesisAnchored", nil)

			vel.Parent = target
			gyro.Parent = target
		end

		pcall(function()
			game.StarterGui:SetCore("SendNotification", {
				Title = anchoredWhileHolding and "📌 Anchored" or "📎 Unanchored",
				Text = "Touch anchor to toggle",
				Duration = 2
			})
		end)
		updateButtonStates()
	end
end

local function toggleMagnet()
	if holding then
		pcall(function()
			game.StarterGui:SetCore("SendNotification", {
				Title = "❌ Not available",
				Text = "Release the object to activate the magnet",
				Duration = 2
			})
		end)
		return
	end
	magnetActive = not magnetActive
	if not magnetActive then restoreGravity() end
	updateButtonStates()
	-- update bar if exists
	if GUIrefs and GUIrefs.forcePanel then
		-- visibility handled in RenderStepped via updateBarMode inside createGUI_Mobile
		-- force minimal re-evaluation:
		if magnetActive then
			GUIrefs.throwBtn.Visible = false
			GUIrefs.grabBtn.Visible = false
			GUIrefs.forcePanel.Visible = true
			GUIrefs.forceLabelSmall.Text = "Force"
			GUIrefs.forceInput.Text = tostring(math.floor(magnetForce))
		else
			if GUIrefs.forcePanel then GUIrefs.forcePanel.Visible = false end
			GUIrefs.throwBtn.Visible = true
			GUIrefs.grabBtn.Visible = true
		end
	end
	pcall(function()
		game.StarterGui:SetCore("SendNotification", {
			Title = magnetActive and "🧲 Magnet Mode ACTIVATED" or "🧲 Magnet Mode DEACTIVATED",
			Text = "Attracts only loose pieces in the blue circle",
			Duration = 2
		})
	end)
end

-- =======================
-- Input handlers (includes Z/X for force)
-- =======================
UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == Enum.KeyCode.Q then holdQ = true
		elseif input.KeyCode == Enum.KeyCode.E then holdE = true
		elseif input.KeyCode == Enum.KeyCode.R then toggleAnchor()
		elseif input.KeyCode == Enum.KeyCode.F then throw()
		elseif input.KeyCode == Enum.KeyCode.T then
			if holding then
				pcall(function()
					game.StarterGui:SetCore("SendNotification", {
						Title = "❌ Not available",
						Text = "Release the object to activate the magnet",
						Duration = 2
					})
				end)
				return
			end
			toggleMagnet()
		elseif input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
			pcall(function()
				game.StarterGui:SetCore("SendNotification", {
					Title = "PC Help",
					Text = "⌨️ PC Controls:\n• Left Click → Grab / Release\n• F → Throw\n• Q/E (hold) → Zoom In/Out -- or change magnet area\n• R → Anchor/Unanchor\n• T → Magnet Mode\n• Z/X → Decrease/Increase force\n• Ctrl → Show this panel",
					Duration = 8
				})
			end)
		elseif input.KeyCode == Enum.KeyCode.Z then
			-- decrease force
			if magnetActive then
				magnetForce = math.max(magnetForceMin, magnetForce - 25)
				pcall(function() game.StarterGui:SetCore("SendNotification", {Title = "Magnet force", Text = "↘ " .. math.floor(magnetForce), Duration = 1}) end)
			else
				throwForce = math.max(throwForceMin, throwForce - 100)
				pcall(function() game.StarterGui:SetCore("SendNotification", {Title = "Throw force", Text = "↘ " .. math.floor(throwForce), Duration = 1}) end)
			end
		elseif input.KeyCode == Enum.KeyCode.X then
			-- increase force
			if magnetActive then
				magnetForce = math.min(magnetForceMax, magnetForce + 25)
				pcall(function() game.StarterGui:SetCore("SendNotification", {Title = "Magnet force", Text = "↗ " .. math.floor(magnetForce), Duration = 1}) end)
			else
				throwForce = math.min(throwForceMax, throwForce + 100)
				pcall(function() game.StarterGui:SetCore("SendNotification", {Title = "Throw force", Text = "↗ " .. math.floor(throwForce), Duration = 1}) end)
			end
		end
	end

	if input.UserInputType == Enum.UserInputType.Gamepad1 and usingGamepad then
		if input.KeyCode == Enum.KeyCode.ButtonX then grabOrRelease()
		elseif input.KeyCode == Enum.KeyCode.ButtonB then throw()
		elseif input.KeyCode == Enum.KeyCode.ButtonY then toggleAnchor()
		elseif input.KeyCode == Enum.KeyCode.DPadLeft then holdLeft = true
		elseif input.KeyCode == Enum.KeyCode.DPadRight then holdRight = true
		elseif input.KeyCode == Enum.KeyCode.DPadDown then
			pcall(function()
				game.StarterGui:SetCore("SendNotification", {
					Title = "Controller Help",
					Text = "🎮 Controller Controls:\n• X → Grab/Release\n• B → Throw\n• ⬅/➡ (hold) → Zoom In/Out -- or change magnet area\n• Y → Anchor/Unanchor\n• LB → Magnet Mode (only loose pieces in the blue circle)\n• DPadDown → Show this panel",
					Duration = 9
				})
			end)
		elseif input.KeyCode == Enum.KeyCode.ButtonL1 then
			if holding then
				pcall(function()
					game.StarterGui:SetCore("SendNotification", {
						Title = "❌ Not available",
						Text = "Release the object to activate the magnet",
						Duration = 2
					})
				end)
				return
			end
			toggleMagnet()
		end
	end
end)

UIS.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == Enum.KeyCode.Q then holdQ = false
		elseif input.KeyCode == Enum.KeyCode.E then holdE = false end
	elseif input.UserInputType == Enum.UserInputType.Gamepad1 then
		if input.KeyCode == Enum.KeyCode.DPadLeft then holdLeft = false
		elseif input.KeyCode == Enum.KeyCode.DPadRight then holdRight = false end
	end
end)

-- Keep mouse support (PC): left click to grab / release
mouse.Button1Down:Connect(function()
	if not UIS.TouchEnabled then
		grabOrRelease()
	end
end)

-- Initial UI states update
updateButtonStates()

-- END OF SCRIPT
