local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local K = {}
K.IMAGE_ID = "rbxassetid://80486373394899"

K.PANEL_SCALE = Vector2.new(0.72, 0.86)
K.PANEL_MIN = Vector2.new(380, 250)
K.PANEL_MAX = Vector2.new(820, 520)
K.CLOSED_SCALE = 0.85

K.OPEN_SIZE = 64
K.OPEN_DEFAULT_X = 44

K.STICK_SHEET = "rbxasset://textures/ui/TouchControlsSheet.png"
K.JUMP_SHEET = "rbxasset://textures/ui/Input/TouchControlsSheetV2.png"
K.SMALL_SCREEN_LIMIT = 500
K.SIZE_SMALL = 70
K.SIZE_BIG = 120

K.DEAD_ZONE = 0.05

K.STICK_REACH = 1
K.STICK_CURVE = 1
K.FAST_TURN = true
K.TURN_RESPONSE = 18

K.SHIFT_LOCK_DEFAULT_ON = false
K.SHIFT_OFFSET_RESPONSE = 20
K.SHIFT_SIZE = 62

K.STICK_ZONE_SCALE = 1.3
K.STICK_ZONE_ACTIVE_SCALE = K.STICK_ZONE_SCALE

K.TAP_DOES_NOT_MOVE = true
K.TAP_MOVE_THRESHOLD = 6

K.X_DELETES_MENU = true

K.CAM_BUTTON_SIZE = Vector2.new(104, 52)
K.CAM_KEY = Enum.KeyCode.Q

K.CL_DEFAULTS = {
        players = true,
        npcs = true,
        enemiesOnly = false,
        throughWalls = true,
        mode = 1,
        aimPart = 1,
        maxDist = 1000,
        afterDeath = 1,
        faceTarget = false,
        aimSpeed = 18,
        fov = 70,
        height = 0,
        side = 1.0,
        crossUp = 13,
        aimLift = 0,
        predict = true,
        predictTime = 120,
        predictCap = 10,
        predictNear = 6,
        predictSmart = true,
        showButtons = true,
        panelSize = 100,
        moveButtons = true,
        shiftSide = 1.0,
        shiftHeight = 0,
        leftNoCam = true,
        walkFast = true,
        crossAuto = true,
        camFix = true,
        zoomKeep = true,
        autoReturn = true,
        stickSmooth = 3,
        aimLead = true,
        zoomFollow = true,
        crossGuess = true,
        aimTrim = true,
        crossDot = false,
        esp = true,
        espPlayers = true,
        espNpcs = true,
        espOutline = 65,
        espFill = 10,
        espDist = 1000,
        rigs = true,
}

K.CONFIGS = {
        {
                name = "Конфиг 1",
                values = {
                        crossUp = 15,
                        aimLift = 2.0,
                },
        },
        {
                name = "Конфиг 2",
                values = {
                        crossUp = 13,
                        aimLift = 0,
                },
        },
}

K.SCALE_MIN = 50
K.SCALE_MAX = 150
K.SCALE_DEFAULT = 100

K.DRAG_THRESHOLD = 10
K.EDGE_MARGIN = 4
K.SMOOTHING = 24

K.OPEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
K.CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
K.PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
K.KNOB_RETURN_INFO = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

K.GOLD = Color3.fromRGB(205, 170, 70)
K.DARK = Color3.fromRGB(35, 15, 45)
K.PURPLE = Color3.fromRGB(90, 40, 110)
K.CREAM = Color3.fromRGB(245, 235, 215)

local connections = {}
local function track(connection)
        table.insert(connections, connection)
        return connection
end

local cleanupCamLock = nil

local controls = nil
local controlsDisabled = false
local savedTouchControls = nil
local camEdge = {show = true, hidden = false}

local isOpen = false
local menuAlive = true
local editMode = false
local sliderOwner = nil
local interactive = {}

local old = playerGui:FindFirstChild("MainPanelGui")
if old then
        old:Destroy()
end

do
        local oldLeft = playerGui:FindFirstChild("MainPanelLeftBlock")

        if oldLeft then
                oldLeft:Destroy()
        end
end

local function addCorner(parent, radius)
        local corner = Instance.new("UICorner")
        corner.CornerRadius = radius
        corner.Parent = parent
        return corner
end

local function addStroke(parent, color, thickness, transparency)
        local stroke = Instance.new("UIStroke")
        stroke.Color = color
        stroke.Thickness = thickness
        stroke.Transparency = transparency or 0
        stroke.Parent = parent
        return stroke
end

local function addBorder(parent, color, thickness, transparency)
        local stroke = addStroke(parent, color, thickness, transparency)
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        return stroke
end

K.BUMP_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function bump(uiScale)
        if not uiScale.Parent then
                return
        end

        uiScale.Scale = 0.86

        TweenService:Create(
                uiScale,
                K.BUMP_INFO,
                {Scale = 1}
        ):Play()
end

local gui = Instance.new("ScreenGui")
gui.Name = "MainPanelGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 50
gui.Parent = playerGui

track(gui.Destroying:Connect(function()
        for _, connection in ipairs(connections) do
                connection:Disconnect()
        end
        table.clear(connections)

        pcall(function()
                RunService:UnbindFromRenderStep("MainPanelRotate")
        end)

        pcall(function()
                RunService:UnbindFromRenderStep("CamLockCamera")
        end)

        pcall(function()
                RunService:UnbindFromRenderStep("MainPanelMove")
        end)

        pcall(function()
                RunService:UnbindFromRenderStep("MainPanelZoomKeeper")
        end)

        if cleanupCamLock then
                pcall(cleanupCamLock)
        end

        pcall(function()
                local leftGui = playerGui:FindFirstChild("MainPanelLeftBlock")

                if leftGui then
                        leftGui:Destroy()
                end
        end)

        if controlsDisabled and controls then
                pcall(function()
                        controls.GetMoveVector = nil
                        controls.GetIsJumping = nil
                end)

                pcall(function()
                        controls:Enable()
                end)
                controlsDisabled = false
        end

        if savedTouchControls ~= nil then
                local restore = savedTouchControls
                savedTouchControls = nil

                pcall(function()
                        GuiService.TouchControlsEnabled = restore
                end)
        end
end))

local toastLabel = Instance.new("TextLabel")
toastLabel.Name = "Toast"
toastLabel.AnchorPoint = Vector2.new(0.5, 0)
toastLabel.Position = UDim2.new(0.5, 0, 0, 12)
toastLabel.Size = UDim2.fromOffset(340, 46)
toastLabel.BackgroundColor3 = K.DARK
toastLabel.BackgroundTransparency = 0.12
toastLabel.TextColor3 = K.CREAM
toastLabel.Font = Enum.Font.SourceSansBold
toastLabel.TextSize = 18
toastLabel.TextWrapped = true
toastLabel.Text = ""
toastLabel.Visible = false
toastLabel.ZIndex = 30
toastLabel.Parent = gui
addCorner(toastLabel, UDim.new(0, 10))
local toastStroke = addBorder(toastLabel, K.GOLD, 2)

local toastToken = 0

local function showToast(text, color)
        toastToken = toastToken + 1
        local token = toastToken

        toastLabel.Text = text
        toastStroke.Color = color or K.GOLD
        toastLabel.Visible = true

        task.delay(2.2, function()
                if token == toastToken then
                        toastLabel.Visible = false
                end
        end)
end

local stickRing = Instance.new("ImageButton")
stickRing.Name = "Joystick"
stickRing.AnchorPoint = Vector2.new(0.5, 0.5)
stickRing.Position = UDim2.new(0, 60, 1, -55)
stickRing.Size = UDim2.fromOffset(K.SIZE_SMALL, K.SIZE_SMALL)
stickRing.BackgroundTransparency = 1
stickRing.AutoButtonColor = false
stickRing.Image = K.STICK_SHEET
stickRing.ImageRectOffset = Vector2.new(0, 0)
stickRing.ImageRectSize = Vector2.new(220, 220)
stickRing.ZIndex = 1
stickRing.Parent = gui

local stickKnob = Instance.new("ImageLabel")
stickKnob.Name = "StickImage"
stickKnob.AnchorPoint = Vector2.new(0.5, 0.5)
stickKnob.Position = UDim2.fromScale(0.5, 0.5)
stickKnob.Size = UDim2.fromOffset(K.SIZE_SMALL / 2, K.SIZE_SMALL / 2)
stickKnob.BackgroundTransparency = 1
stickKnob.Image = K.STICK_SHEET
stickKnob.ImageRectOffset = Vector2.new(220, 0)
stickKnob.ImageRectSize = Vector2.new(111, 111)
stickKnob.ZIndex = 2
stickKnob.Parent = stickRing

local stickOutline = Instance.new("Frame")
stickOutline.Name = "EditOutline"
stickOutline.Size = UDim2.fromScale(1, 1)
stickOutline.BackgroundTransparency = 1
stickOutline.Visible = false
stickOutline.ZIndex = 3
stickOutline.Parent = stickRing
addCorner(stickOutline, UDim.new(1, 0))
addStroke(stickOutline, K.GOLD, 3, 0.1)

local stickZone = Instance.new("TextButton")
stickZone.Name = "TouchZone"
stickZone.AnchorPoint = Vector2.new(0.5, 0.5)
stickZone.Position = UDim2.fromScale(0.5, 0.5)
stickZone.Size = UDim2.fromScale(K.STICK_ZONE_SCALE, K.STICK_ZONE_SCALE)
stickZone.BackgroundTransparency = 1
stickZone.Text = ""
stickZone.AutoButtonColor = false
stickZone.ZIndex = 1
stickZone.Parent = stickRing

local leftBlock = Instance.new("TextButton")
leftBlock.Name = "LeftNoCamera"
leftBlock.Text = ""
leftBlock.AutoButtonColor = false
leftBlock.Active = true
leftBlock.BackgroundTransparency = 1
leftBlock.BorderSizePixel = 0
leftBlock.Position = UDim2.fromScale(0, 0.4)
leftBlock.Size = UDim2.fromScale(0.4, 0.6)
leftBlock.ZIndex = 0
do
        -- Блокировщик камеры слева лежит ПОД интерфейсом игры (низкий DisplayOrder):
        -- кнопки игры слева продолжают нажиматься, а пустое место камеру не крутит.
        local leftGui = Instance.new("ScreenGui")
        leftGui.Name = "MainPanelLeftBlock"
        leftGui.ResetOnSpawn = false
        leftGui.IgnoreGuiInset = false
        leftGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        leftGui.DisplayOrder = -100000
        leftGui.Parent = playerGui
        leftBlock.Parent = leftGui
end

local jumpButton = Instance.new("ImageButton")
jumpButton.Name = "JumpButton"
jumpButton.AnchorPoint = Vector2.new(0.5, 0.5)
jumpButton.Position = UDim2.new(1, -60, 1, -55)
jumpButton.Size = UDim2.fromOffset(K.SIZE_SMALL, K.SIZE_SMALL)
jumpButton.BackgroundTransparency = 1
jumpButton.AutoButtonColor = false
jumpButton.Image = K.JUMP_SHEET
jumpButton.ImageRectOffset = Vector2.new(1, 146)
jumpButton.ImageRectSize = Vector2.new(144, 144)
jumpButton.ZIndex = 1
jumpButton.Parent = gui

local jumpOutline = Instance.new("Frame")
jumpOutline.Name = "EditOutline"
jumpOutline.Size = UDim2.fromScale(1, 1)
jumpOutline.BackgroundTransparency = 1
jumpOutline.Visible = false
jumpOutline.ZIndex = 3
jumpOutline.Parent = jumpButton
addCorner(jumpOutline, UDim.new(1, 0))
addStroke(jumpOutline, K.GOLD, 3, 0.1)

local shiftButton = Instance.new("TextButton")
shiftButton.Name = "ShiftLockButton"
shiftButton.AnchorPoint = Vector2.new(0.5, 0.5)
shiftButton.Position = UDim2.new(1, -60, 1, -150)
shiftButton.Size = UDim2.fromOffset(K.SHIFT_SIZE, K.SHIFT_SIZE)
shiftButton.BackgroundColor3 = K.DARK
shiftButton.BackgroundTransparency = 0.1
shiftButton.AutoButtonColor = false
shiftButton.Text = "SHIFT"
shiftButton.TextColor3 = K.GOLD
shiftButton.Font = Enum.Font.SourceSansBold
shiftButton.TextSize = 16
shiftButton.ZIndex = 1
shiftButton.Parent = gui
addCorner(shiftButton, UDim.new(1, 0))
local shiftStroke = addStroke(shiftButton, K.GOLD, 2)

local shiftScale = Instance.new("UIScale")
shiftScale.Parent = shiftButton

local shiftOutline = Instance.new("Frame")
shiftOutline.Name = "EditOutline"
shiftOutline.Size = UDim2.fromScale(1, 1)
shiftOutline.BackgroundTransparency = 1
shiftOutline.Visible = false
shiftOutline.ZIndex = 3
shiftOutline.Parent = shiftButton
addCorner(shiftOutline, UDim.new(1, 0))
addStroke(shiftOutline, K.GOLD, 3, 0.1)

local camButton = Instance.new("TextButton")
camButton.Name = "CamLockButton"
camButton.AnchorPoint = Vector2.new(0.5, 0.5)
camButton.Position = UDim2.new(1, -200, 1, -55)
camButton.Size = UDim2.fromOffset(K.CAM_BUTTON_SIZE.X, K.CAM_BUTTON_SIZE.Y)
camButton.BackgroundColor3 = K.DARK
camButton.BackgroundTransparency = 0.1
camButton.AutoButtonColor = false
camButton.Text = "CAM"
camButton.TextColor3 = K.GOLD
camButton.Font = Enum.Font.SourceSansBold
camButton.TextSize = 22
camButton.ZIndex = 1
camButton.Parent = gui
addCorner(camButton, UDim.new(0, 14))
local camStroke = addBorder(camButton, K.GOLD, 2)

local camScale = Instance.new("UIScale")
camScale.Parent = camButton

local camOutline = Instance.new("Frame")
camOutline.Name = "EditOutline"
camOutline.Size = UDim2.fromScale(1, 1)
camOutline.BackgroundTransparency = 1
camOutline.Visible = false
camOutline.ZIndex = 3
camOutline.Parent = camButton
addCorner(camOutline, UDim.new(0, 14))
addStroke(camOutline, K.GOLD, 3, 0.1)

local panel = Instance.new("CanvasGroup")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(K.PANEL_SCALE.X, K.PANEL_SCALE.Y)
panel.BackgroundColor3 = K.DARK
panel.BorderSizePixel = 0
panel.GroupTransparency = 1
panel.Visible = false
panel.ZIndex = 5
panel.Parent = gui

addCorner(panel, UDim.new(0, 14))
addStroke(panel, K.GOLD, 3)

local sizeLimit = Instance.new("UISizeConstraint")
sizeLimit.MinSize = K.PANEL_MIN
sizeLimit.MaxSize = K.PANEL_MAX
sizeLimit.Parent = panel

local panelScale = Instance.new("UIScale")
panelScale.Scale = K.CLOSED_SCALE
panelScale.Parent = panel

local background = Instance.new("ImageLabel")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundTransparency = 1
background.Image = K.IMAGE_ID
background.ScaleType = Enum.ScaleType.Stretch
background.ZIndex = 1
background.Parent = panel

local dragLayer = Instance.new("TextButton")
dragLayer.Name = "DragLayer"
dragLayer.Size = UDim2.fromScale(1, 1)
dragLayer.BackgroundTransparency = 1
dragLayer.Text = ""
dragLayer.AutoButtonColor = false
dragLayer.ZIndex = 2
dragLayer.Parent = panel

local content = Instance.new("Frame")
content.Name = "Content"
content.Position = UDim2.fromOffset(12, 12)
content.Size = UDim2.new(1, -24, 1, -24)
content.BackgroundTransparency = 1
content.ZIndex = 3
content.Parent = panel

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, -52, 0, 40)
header.BackgroundColor3 = K.DARK
header.BackgroundTransparency = 0.2
header.BorderSizePixel = 0
header.Parent = content
addCorner(header, UDim.new(0, 10))
addStroke(header, K.GOLD, 2, 0.2)

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.fromScale(1, 1)
title.BackgroundTransparency = 1
title.Text = "КНОПКИ УПРАВЛЕНИЯ"
title.TextColor3 = K.GOLD
title.Font = Enum.Font.SourceSansBold
title.TextSize = 22
title.Parent = header

local card = Instance.new("Frame")
card.Name = "Card"
card.Position = UDim2.fromOffset(0, 52)
card.Size = UDim2.new(1, 0, 1, -52)
card.BackgroundColor3 = K.DARK
card.BackgroundTransparency = 0.4
card.BorderSizePixel = 0
card.Parent = content
addCorner(card, UDim.new(0, 12))
addStroke(card, K.GOLD, 2, 0.45)

local cardPadding = Instance.new("UIPadding")
cardPadding.PaddingTop = UDim.new(0, 10)
cardPadding.PaddingBottom = UDim.new(0, 10)
cardPadding.PaddingLeft = UDim.new(0, 14)
cardPadding.PaddingRight = UDim.new(0, 8)
cardPadding.Parent = card

local scroller = Instance.new("ScrollingFrame")
scroller.Name = "Scroller"
scroller.Size = UDim2.fromScale(1, 1)
scroller.BackgroundTransparency = 1
scroller.BorderSizePixel = 0
scroller.CanvasSize = UDim2.new()
scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroller.ScrollingDirection = Enum.ScrollingDirection.Y
scroller.ScrollBarThickness = 6
scroller.ScrollBarImageColor3 = K.GOLD
scroller.Parent = card
table.insert(interactive, scroller)

local scrollerPadding = Instance.new("UIPadding")
scrollerPadding.PaddingRight = UDim.new(0, 10)
scrollerPadding.Parent = scroller

local cardList = Instance.new("UIListLayout")
cardList.FillDirection = Enum.FillDirection.Vertical
cardList.SortOrder = Enum.SortOrder.LayoutOrder
cardList.Padding = UDim.new(0, 8)
cardList.Parent = scroller

local sliderRow = Instance.new("Frame")
sliderRow.Name = "SliderRow"
sliderRow.LayoutOrder = 1
sliderRow.Size = UDim2.new(1, 0, 0, 76)
sliderRow.BackgroundTransparency = 1
sliderRow.Parent = scroller

local sliderRowList = Instance.new("UIListLayout")
sliderRowList.FillDirection = Enum.FillDirection.Horizontal
sliderRowList.SortOrder = Enum.SortOrder.LayoutOrder
sliderRowList.Padding = UDim.new(0, 10)
sliderRowList.Parent = sliderRow

local sliderRow2 = Instance.new("Frame")
sliderRow2.Name = "SliderRow2"
sliderRow2.LayoutOrder = 2
sliderRow2.Size = UDim2.new(1, 0, 0, 76)
sliderRow2.BackgroundTransparency = 1
sliderRow2.Parent = scroller

local sliderRow2List = Instance.new("UIListLayout")
sliderRow2List.FillDirection = Enum.FillDirection.Horizontal
sliderRow2List.SortOrder = Enum.SortOrder.LayoutOrder
sliderRow2List.Padding = UDim.new(0, 10)
sliderRow2List.Parent = sliderRow2

local bottomRow = Instance.new("Frame")
bottomRow.Name = "BottomRow"
bottomRow.LayoutOrder = 1000
bottomRow.Size = UDim2.new(1, 0, 0, 34)
bottomRow.BackgroundTransparency = 1
bottomRow.Parent = scroller

local hint = Instance.new("TextLabel")
hint.Name = "Hint"
hint.Size = UDim2.new(1, -130, 1, 0)
hint.BackgroundTransparency = 1
hint.Text = "Тяни кнопки и панель пальцем"
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.TextWrapped = true
hint.TextColor3 = K.CREAM
hint.Font = Enum.Font.SourceSans
hint.TextSize = 18
hint.Parent = bottomRow

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -12, 0, 12)
closeButton.Size = UDim2.fromOffset(40, 40)
closeButton.BackgroundColor3 = K.DARK
closeButton.BackgroundTransparency = 0.15
closeButton.AutoButtonColor = false
closeButton.Text = "X"
closeButton.TextColor3 = K.GOLD
closeButton.Font = Enum.Font.SourceSansBold
closeButton.TextSize = 24
closeButton.ZIndex = 6
closeButton.Parent = panel
addCorner(closeButton, UDim.new(1, 0))
addStroke(closeButton, K.GOLD, 2)
table.insert(interactive, closeButton)

local closeScale = Instance.new("UIScale")
closeScale.Parent = closeButton

local openButton = Instance.new("TextButton")
openButton.Name = "OpenButton"
openButton.AnchorPoint = Vector2.new(0.5, 0.5)
openButton.Position = UDim2.new(0, K.OPEN_DEFAULT_X, 0.5, 0)
openButton.Size = UDim2.fromOffset(K.OPEN_SIZE, K.OPEN_SIZE)
openButton.BackgroundColor3 = K.DARK
openButton.BackgroundTransparency = 0.1
openButton.AutoButtonColor = false
openButton.Text = ""
openButton.ZIndex = 20
openButton.Parent = gui
addCorner(openButton, UDim.new(0, 14))
addStroke(openButton, K.GOLD, 2)

local openScale = Instance.new("UIScale")
openScale.Parent = openButton

local icon = Instance.new("Frame")
icon.Name = "Icon"
icon.AnchorPoint = Vector2.new(0.5, 0.5)
icon.Position = UDim2.fromScale(0.5, 0.5)
icon.Size = UDim2.fromScale(0.5, 0.4)
icon.BackgroundTransparency = 1
icon.ZIndex = 21
icon.Parent = openButton

for i = 0, 2 do
        local bar = Instance.new("Frame")
        bar.Name = "Bar" .. i
        bar.AnchorPoint = Vector2.new(0, 0.5)
        bar.Position = UDim2.fromScale(0, i * 0.5)
        bar.Size = UDim2.new(1, 0, 0.14, 0)
        bar.BackgroundColor3 = K.GOLD
        bar.BorderSizePixel = 0
        bar.ZIndex = 21
        bar.Parent = icon
        addCorner(bar, UDim.new(1, 0))
end

local stickPercent = K.SCALE_DEFAULT
local jumpPercent = K.SCALE_DEFAULT
local stickSize = K.SIZE_SMALL
local jumpSize = K.SIZE_SMALL

K.BTN_SCALE_MAX = 200
local camPercent = K.SCALE_DEFAULT
local shiftPercent = K.SCALE_DEFAULT
local shiftSize = K.SHIFT_SIZE
local camSize = K.CAM_BUTTON_SIZE

local function camText(size)
        return math.max(8, math.floor(size * camPercent / 100 + 0.5))
end

local function baseSize()
        local view = gui.AbsoluteSize
        if math.min(view.X, view.Y) <= K.SMALL_SCREEN_LIMIT then
                return K.SIZE_SMALL
        end
        return K.SIZE_BIG
end

local function getCenter(target)
        local view = gui.AbsoluteSize
        local p = target.Position
        return Vector2.new(p.X.Scale * view.X + p.X.Offset, p.Y.Scale * view.Y + p.Y.Offset)
end

local function halfSizeOf(target)
        if target == openButton then
                return Vector2.new(K.OPEN_SIZE, K.OPEN_SIZE) / 2
        elseif target == stickRing then
                return Vector2.new(stickSize, stickSize) / 2
        elseif target == jumpButton then
                return Vector2.new(jumpSize, jumpSize) / 2
        elseif target == shiftButton then
                return Vector2.new(shiftSize, shiftSize) / 2
        elseif target == camButton then
                return camSize / 2
        end
        return target.AbsoluteSize / 2
end

local function clampCenter(target, center)
        local view = gui.AbsoluteSize
        if view.X <= 0 or view.Y <= 0 then
                return nil
        end
        local half = halfSizeOf(target)

        if target == panel then
                return Vector2.new(
                        math.clamp(center.X, 90 - half.X, view.X + half.X - 90),
                        math.clamp(center.Y, half.Y - 10, view.Y + half.Y - 60)
                )
        elseif target == openButton then
                return Vector2.new(
                        math.clamp(center.X, 26 - half.X, view.X + half.X - 26),
                        math.clamp(center.Y, 26 - half.Y, view.Y + half.Y - 26)
                )
        end

        return Vector2.new(
                math.clamp(center.X, -half.X, view.X + half.X),
                math.clamp(center.Y, -half.Y, view.Y + half.Y)
        )
end

local function applyCenter(target, center)
        local clamped = clampCenter(target, center)
        if not clamped then
                return
        end
        local view = gui.AbsoluteSize
        target.Position = UDim2.fromScale(clamped.X / view.X, clamped.Y / view.Y)

        if target == stickRing or target == jumpButton or target == shiftButton or target == camButton then
                local half = halfSizeOf(target)
                local gone = clamped.X + half.X <= 0
                        or clamped.X - half.X >= view.X
                        or clamped.Y + half.Y <= 0
                        or clamped.Y - half.Y >= view.Y

                if target == camButton then
                        camEdge.hidden = gone
                        camButton.Visible = camEdge.show and not gone
                else
                        target.Visible = not gone
                end
        end
end

local function defaultCenter(kind)
        local view = gui.AbsoluteSize
        local small = math.min(view.X, view.Y) <= K.SMALL_SCREEN_LIMIT
        local base = small and K.SIZE_SMALL or K.SIZE_BIG

        if kind == "shift" then
                return defaultCenter("jump") - Vector2.new(0, base / 2 + shiftSize / 2 + 24)
        end

        if kind == "cam" then
                return defaultCenter("jump") - Vector2.new(base / 2 + camSize.X / 2 + 16, 0)
        end

        if kind == "stick" then
                if small then
                        return Vector2.new(25 + base / 2, view.Y - 90 + base / 2)
                end
                return Vector2.new(60 + base / 2, view.Y - 210 + base / 2)
        end

        if small then
                return Vector2.new(
                        view.X - (base * 1.5 - 10) + base / 2,
                        view.Y - base - 20 + base / 2
                )
        end

        return Vector2.new(
                view.X - (base * 1.5 - 10) + base / 2,
                view.Y - base * 1.75 + base / 2
        )
end

local stickMoved = false
local jumpMoved = false
local shiftMoved = false
local camMoved = false

local function placeDefaults(force)
        if force or not stickMoved then
                applyCenter(stickRing, defaultCenter("stick"))
        end
        if force or not jumpMoved then
                applyCenter(jumpButton, defaultCenter("jump"))
        end
        if force or not shiftMoved then
                applyCenter(shiftButton, defaultCenter("shift"))
        end
        if force or not camMoved then
                applyCenter(camButton, defaultCenter("cam"))
        end
end

local function refreshControls()
        local base = baseSize()

        stickSize = math.max(1, math.floor(base * stickPercent / 100 + 0.5))
        jumpSize = math.max(1, math.floor(base * jumpPercent / 100 + 0.5))

        stickRing.Size = UDim2.fromOffset(stickSize, stickSize)
        stickKnob.Size = UDim2.fromOffset(stickSize / 2, stickSize / 2)
        jumpButton.Size = UDim2.fromOffset(jumpSize, jumpSize)

        shiftSize = math.max(1, math.floor(K.SHIFT_SIZE * shiftPercent / 100 + 0.5))
        camSize = Vector2.new(
                math.max(1, math.floor(K.CAM_BUTTON_SIZE.X * camPercent / 100 + 0.5)),
                math.max(1, math.floor(K.CAM_BUTTON_SIZE.Y * camPercent / 100 + 0.5))
        )

        shiftButton.Size = UDim2.fromOffset(shiftSize, shiftSize)
        shiftButton.TextSize = math.max(8, math.floor(16 * shiftPercent / 100 + 0.5))
        camButton.Size = UDim2.fromOffset(camSize.X, camSize.Y)
        camButton.TextSize = camText(22)

        applyCenter(stickRing, getCenter(stickRing))
        applyCenter(jumpButton, getCenter(jumpButton))
        applyCenter(shiftButton, getCenter(shiftButton))
        applyCenter(camButton, getCenter(camButton))
end

local function isPointer(input)
        return input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1
end

local function isLive(input)
        return input.UserInputState ~= Enum.UserInputState.End
                and input.UserInputState ~= Enum.UserInputState.Cancel
end

local function isSameDrag(input, active)
        if input == active then
                return true
        end

        return active.UserInputType == Enum.UserInputType.MouseButton1
                and input.UserInputType == Enum.UserInputType.MouseMovement
end

local function endsDrag(input, active)
        if input == active then
                return true
        end

        return active.UserInputType == Enum.UserInputType.MouseButton1
                and input.UserInputType == Enum.UserInputType.MouseButton1
end

local function guiPoint(input)
        return Vector2.new(input.Position.X, input.Position.Y)
end

local function pointInside(guiObject, point)
        local position = guiObject.AbsolutePosition
        local size = guiObject.AbsoluteSize

        return point.X >= position.X
                and point.X <= position.X + size.X
                and point.Y >= position.Y
                and point.Y <= position.Y + size.Y
end

local function sliderBusy()
        if sliderOwner and not isLive(sliderOwner) then
                sliderOwner = nil
        end
        return sliderOwner ~= nil
end

local function coveredByUi(input)
        if not menuAlive then
                return false
        end

        local point = guiPoint(input)

        if pointInside(openButton, point) then
                return true
        end

        if isOpen and pointInside(panel, point) then
                return true
        end

        return false
end

local function bindPress(button, callback)
        local pressed = nil

        track(button.InputBegan:Connect(function(input)
                if not isPointer(input) or editMode or coveredByUi(input) then
                        return
                end

                if pressed and isLive(pressed) then
                        return
                end

                pressed = input
                callback()
        end))

        track(UserInputService.InputEnded:Connect(function(input)
                if not pressed or not endsDrag(input, pressed) then
                        return
                end

                local mine = pressed

                task.delay(0.15, function()
                        if pressed == mine then
                                pressed = nil
                        end
                end)
        end))

        track(button.Activated:Connect(function()
                if pressed then
                        pressed = nil
                        return
                end

                if editMode then
                        return
                end

                callback()
        end))
end

local draggers = {}

local function makeDraggable(handle, target, options)
        options = options or {}

        local state = {
                target = target,
                goal = nil,
        }

        table.insert(draggers, state)

        local dragInput = nil
        local startPointer = Vector2.zero
        local startCenter = Vector2.zero
        local moved = false

        track(handle.InputBegan:Connect(function(input)
                if dragInput and not isLive(dragInput) then
                        dragInput = nil
                        state.dragging = false
                end

                if dragInput or not isPointer(input) then
                        return
                end

                if options.canStart and not options.canStart(input) then
                        return
                end

                dragInput = input
                state.dragging = true
                startPointer = Vector2.new(input.Position.X, input.Position.Y)
                startCenter = getCenter(target)
                state.goal = nil
                moved = false

                if options.onPress then
                        options.onPress(true)
                end
        end))

        track(UserInputService.InputChanged:Connect(function(input)
                if not dragInput or not isSameDrag(input, dragInput) then
                        return
                end

                local delta = Vector2.new(input.Position.X, input.Position.Y) - startPointer

                if not moved and delta.Magnitude >= K.DRAG_THRESHOLD then
                        moved = true
                end

                if moved then
                        local goal = clampCenter(target, startCenter + delta)

                        if goal then
                                state.goal = goal
                        end

                        if options.onDragged then
                                options.onDragged()
                        end
                end
        end))

        track(UserInputService.InputEnded:Connect(function(input)
                if not dragInput or not endsDrag(input, dragInput) then
                        return
                end

                local wasTap = not moved
                dragInput = nil
                state.dragging = false

                if options.onPress then
                        options.onPress(false)
                end

                if wasTap and options.onTap then
                        options.onTap()
                end
        end))
end

track(RunService.RenderStepped:Connect(function(dt)
        local alpha = 1 - math.exp(-K.SMOOTHING * dt)

        for _, state in ipairs(draggers) do
                local goal = state.goal

                if goal then
                        local nextCenter = getCenter(state.target):Lerp(goal, alpha)

                        if (goal - nextCenter).Magnitude < 0.25 then
                                nextCenter = goal
                                state.goal = nil
                        end

                        applyCenter(state.target, nextCenter)
                end
        end
end))

local function cancelDragGoals()
        for _, state in ipairs(draggers) do
                state.goal = nil
        end
end

local stickInput = nil
local stickLastEvent = 0
local jumpLastEvent = 0
K.STALE_TOUCH_TIME = 0.8
K.stickF = {prev = Vector3.zero, d = Vector3.zero}
local moveVector = Vector3.zero
local stickRaw = Vector3.zero
local needStopMove = false
local knobTween = nil
local stickAnchor = Vector2.zero
local stickStart = Vector2.zero
local stickArmed = true

local jumpInput = nil
local jumpHeld = false
local needStopJump = false

local function updateStick(input)
        stickLastEvent = os.clock()

        local point = guiPoint(input)

        if not stickArmed and (point - stickStart).Magnitude >= K.TAP_MOVE_THRESHOLD then
                stickArmed = true
        end

        local offset = point - stickAnchor
        local maxLength = stickSize / 2

        if offset.Magnitude > maxLength then
                offset = offset.Unit * maxLength
        end

        stickKnob.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)

        if not stickArmed then
                stickRaw = Vector3.zero
                return
        end

        local direction = offset / maxLength
        local magnitude = direction.Magnitude

        if magnitude <= K.DEAD_ZONE or magnitude == 0 then
                stickRaw = Vector3.zero
        else
                local t = math.clamp((magnitude - K.DEAD_ZONE) / (K.STICK_REACH - K.DEAD_ZONE), 0, 1)
                t = t ^ K.STICK_CURVE

                local unit = direction.Unit
                stickRaw = Vector3.new(unit.X * t, 0, unit.Y * t)
        end
end

local function releaseStick(immediate)
        if stickInput or moveVector ~= Vector3.zero then
                needStopMove = true
        end

        stickInput = nil
        moveVector = Vector3.zero
        stickRaw = Vector3.zero
        K.stickF.prev = Vector3.zero
        K.stickF.d = Vector3.zero

        if knobTween then
                knobTween:Cancel()
                knobTween = nil
        end

        stickZone.Size = UDim2.fromScale(K.STICK_ZONE_SCALE, K.STICK_ZONE_SCALE)

        local center = UDim2.fromScale(0.5, 0.5)

        if immediate then
                stickKnob.Position = center
                return
        end

        knobTween = TweenService:Create(
                stickKnob,
                K.KNOB_RETURN_INFO,
                {Position = center}
        )

        knobTween:Play()
end

local function releaseJump()
        if jumpInput or jumpHeld then
                needStopJump = true
        end

        jumpInput = nil
        jumpHeld = false
        jumpButton.ImageRectOffset = Vector2.new(1, 146)
end

track(stickZone.InputBegan:Connect(function(input)
        if stickInput and not isLive(stickInput) then
                releaseStick()
        end

        if editMode or not isPointer(input) or coveredByUi(input) then
                return
        end

        if stickInput then
                if os.clock() - stickLastEvent < K.STALE_TOUCH_TIME then
                        return
                end

                releaseStick(true)
        end

        stickInput = input
        stickLastEvent = os.clock()

        if knobTween then
                knobTween:Cancel()
                knobTween = nil
        end

        stickAnchor = stickRing.AbsolutePosition + stickRing.AbsoluteSize / 2
        stickStart = guiPoint(input)
        stickArmed = not K.TAP_DOES_NOT_MOVE

        stickZone.Size = UDim2.fromScale(K.STICK_ZONE_ACTIVE_SCALE, K.STICK_ZONE_ACTIVE_SCALE)

        updateStick(input)
end))

track(jumpButton.InputBegan:Connect(function(input)
        if jumpInput and not isLive(jumpInput) then
                releaseJump()
        end

        if editMode or not isPointer(input) or coveredByUi(input) then
                return
        end

        if jumpInput then
                if os.clock() - jumpLastEvent < K.STALE_TOUCH_TIME then
                        return
                end

                releaseJump()
        end

        jumpInput = input
        jumpLastEvent = os.clock()
        jumpHeld = true
        jumpButton.ImageRectOffset = Vector2.new(146, 146)
end))

track(UserInputService.InputChanged:Connect(function(input)
        if stickInput and isSameDrag(input, stickInput) then
                updateStick(input)
        end

        if jumpInput and isSameDrag(input, jumpInput) then
                jumpLastEvent = os.clock()
        end
end))

track(UserInputService.InputEnded:Connect(function(input)
        if stickInput and endsDrag(input, stickInput) then
                releaseStick()
        end

        if jumpInput and endsDrag(input, jumpInput) then
                releaseJump()
        end
end))

track(UserInputService.WindowFocusReleased:Connect(function()
        releaseStick(true)
        releaseJump()
end))

track(UserInputService.WindowFocused:Connect(function()
        releaseStick(true)
        releaseJump()
end))

track(GuiService.MenuOpened:Connect(function()
        releaseStick(true)
        releaseJump()
end))

track(GuiService.MenuClosed:Connect(function()
        releaseStick(true)
        releaseJump()
end))

track(UserInputService.TouchEnded:Connect(function(input)
        if stickInput and endsDrag(input, stickInput) then
                releaseStick()
        end

        if jumpInput and endsDrag(input, jumpInput) then
                releaseJump()
        end
end))

track(UserInputService.TextBoxFocused:Connect(function()
        releaseStick(true)
        releaseJump()
end))

track(player.CharacterAdded:Connect(function()
        releaseStick(true)
        releaseJump()
end))

track(player.CharacterRemoving:Connect(function()
        releaseStick(true)
        releaseJump()
end))

local shiftLockOn = K.SHIFT_LOCK_DEFAULT_ON
local shiftOffsetDirty = K.SHIFT_LOCK_DEFAULT_ON

local function refreshShiftButton()
        shiftButton.BackgroundColor3 = shiftLockOn and K.GOLD or K.DARK
        shiftButton.TextColor3 = shiftLockOn and K.DARK or K.GOLD
        shiftStroke.Color = shiftLockOn and K.CREAM or K.GOLD
end

local function getHumanoid()
        local character = player.Character
        return character and character:FindFirstChildOfClass("Humanoid")
end

local function setShiftLock(on)
        if on == shiftLockOn then
                return
        end

        shiftLockOn = on
        shiftOffsetDirty = true
        refreshShiftButton()
end

refreshShiftButton()

local CL, MODE_NAMES, AIM_NAMES, MAXDIST_INF
local refreshCamButtons, toggleLock

refreshCamButtons = function() end
toggleLock = function()
        showToast("Камлок не запустился. Смотри окно Output", Color3.fromRGB(235, 120, 120))
end

local Safe = {}

Safe.walkStates = {
        [Enum.HumanoidStateType.Running] = true,
        [Enum.HumanoidStateType.RunningNoPhysics] = true,
        [Enum.HumanoidStateType.Freefall] = true,
        [Enum.HumanoidStateType.Jumping] = true,
        [Enum.HumanoidStateType.Landed] = true,
}

-- игра держит персонажа (ремонт, анимация, стан): мы его не трогаем
function Safe.held(humanoid, root)
        return humanoid.WalkSpeed <= 1
                or humanoid.PlatformStand
                or humanoid.Sit
                or (root ~= nil and root.Anchored)
end

-- вода: состояние Swimming у поверхности мигает (Freefall/Jumping), поэтому смотрим ещё и сам воксель воды
Safe.water = {at = 0, root = nil, value = false}

function Safe.wetAt(root)
        local cache = Safe.water
        local now = os.clock()

        if cache.root == root and now - cache.at < 0.1 then
                return cache.value
        end

        cache.root = root
        cache.at = now
        cache.value = false

        pcall(function()
                local p = root.Position
                local region = Region3.new(p - Vector3.new(2, 2, 2), p + Vector3.new(2, 2, 2)):ExpandToGrid(4)
                local materials, occupancy = workspace.Terrain:ReadVoxels(region, 4)

                for x = 1, #materials do
                        for y = 1, #materials[x] do
                                for z = 1, #materials[x][y] do
                                        if materials[x][y][z] == Enum.Material.Water and occupancy[x][y][z] > 0.5 then
                                                cache.value = true
                                        end
                                end
                        end
                end
        end)

        return cache.value
end

function Safe.inWater(humanoid, root)
        local state = humanoid:GetState()

        if state == Enum.HumanoidStateType.Swimming then
                return true
        end

        if root and (state == Enum.HumanoidStateType.Freefall
                or state == Enum.HumanoidStateType.Jumping
                or state == Enum.HumanoidStateType.Landed)
        then
                return Safe.wetAt(root)
        end

        return false
end

-- крутить тело и менять скорость можно только когда персонаж реально ходит:
-- не плывёт, не лезет, не сидит, и игра его не держит
function Safe.canDrive(humanoid, root)
        return Safe.walkStates[humanoid:GetState()] == true
                and not Safe.held(humanoid, root)
                and not Safe.inWater(humanoid, root)
end

-- то же, что делает штатное управление Roblox: в воде вектор идёт по взгляду камеры вместе с наклоном,
-- на суше только по её горизонтальному направлению
function Safe.worldMove(humanoid, camera, v)
        if v.Magnitude < 0.0001 then
                return v
        end

        local cf = camera.CFrame

        if humanoid:GetState() == Enum.HumanoidStateType.Swimming then
                return cf:VectorToWorldSpace(v)
        end

        local _, _, _, r00, r01, r02, _, _, r12, _, _, r22 = cf:GetComponents()
        local c
        local sn

        if r12 < 1 and r12 > -1 then
                c = r22
                sn = r02
        else
                c = r00
                sn = -r01 * math.sign(r12)
        end

        local norm = math.sqrt(c * c + sn * sn)

        if norm < 0.0001 then
                return v
        end

        return Vector3.new((c * v.X + sn * v.Z) / norm, 0, (c * v.Z - sn * v.X) / norm)
end

-- живой ли: у Humanoid по здоровью и состоянию, у мобов без Humanoid по меткам, значениям и позе тела
Safe.healthNames = {"Health", "health", "HP", "hp", "Hp", "CurrentHealth", "currentHealth"}
Safe.deadNames = {"Dead", "IsDead", "isDead", "dead", "Died", "died"}
Safe.rigCache = setmetatable({}, {__mode = "k"})

function Safe.rigAlive(model)
        local now = os.clock()
        local cached = Safe.rigCache[model]

        if cached and now - cached.at < 0.25 then
                return cached.alive
        end

        cached = cached or {upright = false}

        local alive = true

        pcall(function()
                if not model.Parent then
                        alive = false
                        return
                end

                local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart

                if not root or not root.Parent then
                        alive = false
                        return
                end

                local function read(name)
                        local value = model:GetAttribute(name)

                        if value == nil then
                                local child = model:FindFirstChild(name)

                                if child and child:IsA("ValueBase") then
                                        value = child.Value
                                end
                        end

                        return value
                end

                local signal = false

                for _, name in ipairs(Safe.healthNames) do
                        local value = read(name)

                        if type(value) == "number" then
                                signal = true

                                if value <= 0 then
                                        alive = false
                                end

                                break
                        end
                end

                for _, name in ipairs(Safe.deadNames) do
                        if read(name) == true then
                                alive = false
                        end
                end

                if alive and not signal then
                        -- данных о здоровье нет: мёртвым считаем того, кто раньше стоял, а теперь лежит и не двигается
                        local up = root.CFrame.UpVector.Y

                        if up >= 0.6 then
                                cached.upright = true
                        elseif cached.upright and up < 0.3 and root.AssemblyLinearVelocity.Magnitude < 1 then
                                alive = false
                        end
                end
        end)

        cached.at = now
        cached.alive = alive
        Safe.rigCache[model] = cached

        return alive
end

function Safe.alive(hum, model)
        if typeof(hum) == "Instance" then
                if hum.Health <= 0 then
                        return false
                end

                local okState, state = pcall(hum.GetState, hum)

                if okState and state == Enum.HumanoidStateType.Dead then
                        return false
                end

                return true
        end

        return Safe.rigAlive(model)
end

-- предохранитель: если модуль падает с ошибкой несколько раз подряд, он отключается на 30 секунд,
-- а игра остаётся нетронутой. Потом включается сам
Safe.trip = {}

function Safe.bind(name, priority, fn)
        local fails = {}
        local pausedUntil = 0

        RunService:BindToRenderStep(name, priority, function(...)
                if pausedUntil > 0 then
                        if os.clock() < pausedUntil then
                                return
                        end

                        pausedUntil = 0
                end

                local ok, err = pcall(fn, ...)

                if ok then
                        return
                end

                local now = os.clock()
                fails[#fails + 1] = now

                while fails[1] and now - fails[1] > 5 do
                        table.remove(fails, 1)
                end

                if #fails == 1 then
                        warn("[MainPanel] " .. name .. ": " .. tostring(err))
                end

                if #fails >= 4 then
                        fails = {}
                        pausedUntil = now + 30

                        local handler = Safe.trip[name]

                        if handler then
                                pcall(handler)
                        end

                        showToast("Модуль " .. name .. " дал сбой и отключён на 30 с. Игра не затронута", Color3.fromRGB(235, 120, 120))
                end
        end)
end

do
        local RETURN_OUTSIDE = 0.7
        local timer = 0

        local function visibleFraction(target)
                local view = gui.AbsoluteSize
                local center = getCenter(target)
                local half = halfSizeOf(target)

                if view.X <= 0 or view.Y <= 0 or half.X <= 0 or half.Y <= 0 then
                        return 1
                end

                local w = math.min(center.X + half.X, view.X) - math.max(center.X - half.X, 0)
                local h = math.min(center.Y + half.Y, view.Y) - math.max(center.Y - half.Y, 0)

                if w <= 0 or h <= 0 then
                        return 0
                end

                return (w * h) / (4 * half.X * half.Y)
        end

        local function sendHome(target)
                if target == stickRing then
                        stickMoved = false
                        applyCenter(stickRing, defaultCenter("stick"))
                elseif target == jumpButton then
                        jumpMoved = false
                        applyCenter(jumpButton, defaultCenter("jump"))
                elseif target == shiftButton then
                        shiftMoved = false
                        applyCenter(shiftButton, defaultCenter("shift"))
                elseif target == camButton then
                        camMoved = false
                        applyCenter(camButton, defaultCenter("cam"))
                else
                        return false
                end

                return true
        end

        track(RunService.Heartbeat:Connect(function(dt)
                timer = timer + dt

                if timer < 0.15 then
                        return
                end

                timer = 0

                if not CL or CL.autoReturn == false then
                        return
                end

                local returned = 0

                for _, state in ipairs(draggers) do
                        local target = state.target

                        if not state.dragging
                                and not state.goal
                                and (target == stickRing or target == jumpButton or target == shiftButton or target == camButton)
                                and (target ~= camButton or camEdge.show)
                                and visibleFraction(target) < 1 - RETURN_OUTSIDE
                        then
                                if sendHome(target) then
                                        returned = returned + 1
                                end
                        end
                end

                if returned > 0 then
                        showToast("Кнопка ушла за экран и вернулась на место", K.GOLD)
                end
        end))
end

local function setupCamLock()
        CL = {}
        for key, value in pairs(K.CL_DEFAULTS) do
                CL[key] = value
        end

        MODE_NAMES = {"Ближе к центру экрана", "Меньше всего HP", "Ближе по расстоянию"}
        AIM_NAMES = {"Голова (нет головы — тело)", "Тело (центр)"}
        MAXDIST_INF = 1000

        local FOCUS_Y = 1.5
        local DIST_MIN = 10
        local DIST_MAX = 24
        local CAM_DIST_EXTRA = 0
        local BLEND_TIME = 0.3
        local HIDDEN_RELEASE = 1.5
        local MAX_VIS_CHECKS = 25
        local SEARCH_PERIOD = 0.25
        local TAP_RADIUS = 120
        local TAP_MAX_MOVE = 14
        local TAP_MAX_TIME = 0.35
        local SWIPE_MIN_X = 70
        local SWIPE_MAX_TIME = 0.7
        local VEL_FAST = 16
        local VEL_SLOW = 4
        local TELEPORT_DIST = 25
        local STABLE_SPEED = 4.5
        local TURN_DAMP = 0.35

        local armed = false
        local target = nil
        local targetVel = Vector3.zero
        local lastTargetPos = Vector3.zero
        local lastTargetVel = Vector3.zero
        local visTimer = 0
        local hiddenTime = 0
        local uiTimer = 0
        local searchTimer = 0

        local overlay = false
        local blend = 0
        local baseFov = 70
        local fovActive = false
        local camLook = Vector3.new(0, 0, -1)
        local camDist = 14.5

        local lockAimPoint = nil
        local AT = {rot = Vector3.zero, ndcX = nil, ndcY = nil, dot = nil}
        local leadPrev = nil
        local leadVel = Vector3.zero
        local npcSet = {}

        local function myParts()
                local character = player.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local root = humanoid and humanoid.RootPart
                return character, humanoid, root
        end

        local rotateHeld = false
        local rotateSavedAutoRotate = true
        local rotateHumanoid = nil

        local mouseCanLock = UserInputService.MouseEnabled and not UserInputService.TouchEnabled
        local mouseLockedByUs = false

        local function setMouseLock(on)
                if on and mouseCanLock then
                        mouseLockedByUs = true

                        if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
                                UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
                        end
                elseif mouseLockedByUs then
                        mouseLockedByUs = false
                        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                end
        end

        local function releaseAutoRotate()
                if rotateHeld then
                        rotateHeld = false

                        if rotateHumanoid and rotateHumanoid.Parent then
                                rotateHumanoid.AutoRotate = rotateSavedAutoRotate
                        end

                        rotateHumanoid = nil
                end
        end

        pcall(function()
                RunService:UnbindFromRenderStep("MainPanelRotate")
        end)

        Safe.trip.MainPanelRotate = function()
                releaseAutoRotate()
                setMouseLock(false)
        end

        Safe.bind("MainPanelRotate", Enum.RenderPriority.Camera.Value + 2, function(dt)
                local humanoid = getHumanoid()

                if not humanoid then
                        setMouseLock(false)
                        return
                end

                local shiftWanted = Vector3.zero

                if shiftLockOn then
                        shiftWanted = Vector3.new(CL.shiftSide, CL.shiftHeight, 0)

                        if humanoid.CameraOffset ~= shiftWanted then
                                shiftOffsetDirty = true
                        end
                end

                if shiftOffsetDirty then
                        local nextOffset = humanoid.CameraOffset:Lerp(shiftWanted, 1 - math.exp(-K.SHIFT_OFFSET_RESPONSE * dt))

                        if (nextOffset - shiftWanted).Magnitude < 0.005 then
                                nextOffset = shiftWanted
                                shiftOffsetDirty = false
                        end

                        humanoid.CameraOffset = nextOffset
                end

                local root = humanoid.RootPart
                local camera = workspace.CurrentCamera
                local canTurn = humanoid.Health > 0
                        and not humanoid.Sit
                        and not humanoid.PlatformStand
                        and root ~= nil
                        and camera ~= nil
                        and Safe.canDrive(humanoid, root)

                local owner = nil

                if canTurn then
                        if armed and target and CL.faceTarget and lockAimPoint then
                                owner = "lock"
                        elseif shiftLockOn then
                                owner = "shift"
                        elseif K.FAST_TURN and stickInput and moveVector.Magnitude >= 0.1 then
                                owner = "move"
                        end
                end

                setMouseLock(owner == "shift")

                if owner then
                        if rotateHeld and rotateHumanoid ~= humanoid then
                                rotateHeld = false
                        end

                        if not rotateHeld then
                                rotateHeld = true
                                rotateHumanoid = humanoid
                                rotateSavedAutoRotate = humanoid.AutoRotate
                        end

                        if humanoid.AutoRotate then
                                humanoid.AutoRotate = false
                        end

                        local position = root.Position
                        local flat
                        local response = nil

                        if owner == "lock" then
                                flat = Vector3.new(lockAimPoint.X - position.X, 0, lockAimPoint.Z - position.Z)
                                response = CL.aimSpeed

                                if flat.Magnitude < 0.5 then
                                        flat = Vector3.zero
                                end
                        elseif owner == "shift" then
                                local look = camera.CFrame.LookVector
                                flat = Vector3.new(look.X, 0, look.Z)
                        else
                                local world = camera.CFrame:VectorToWorldSpace(moveVector)
                                flat = Vector3.new(world.X, 0, world.Z)
                                response = K.TURN_RESPONSE
                        end

                        if flat.Magnitude > 0.001 then
                                local wanted = CFrame.lookAt(position, position + flat.Unit)

                                if response then
                                        root.CFrame = root.CFrame:Lerp(wanted, 1 - math.exp(-response * dt))
                                else
                                        root.CFrame = wanted
                                end

                                root.AssemblyAngularVelocity = Vector3.zero
                        end
                else
                        releaseAutoRotate()
                end
        end)

        local flashToken = 0

        function refreshCamButtons()
                camEdge.show = CL.showButtons
                camButton.Visible = camEdge.show and not camEdge.hidden

                if armed and target then
                        camButton.BackgroundColor3 = K.GOLD
                        camButton.TextColor3 = K.DARK
                        camButton.TextSize = camText(22)
                        camButton.Text = "LOCK"
                        camStroke.Color = K.CREAM
                else
                        camButton.BackgroundColor3 = K.DARK
                        camButton.TextColor3 = K.GOLD
                        camButton.TextSize = camText(22)
                        camButton.Text = "CAM"
                        camStroke.Color = K.GOLD
                end
        end

        -- мобы без Humanoid (кастомные риги): ищем модель с HumanoidRootPart и заводим «заместителя» со здоровьем
        local rigOf = {}
        local rigSet = {}

        local function considerRig(part)
                if part.Name ~= "HumanoidRootPart" or not part:IsA("BasePart") then
                        return
                end

                local model = part.Parent

                if not model or not model:IsA("Model") or rigOf[model] then
                        return
                end

                if model:FindFirstChildOfClass("Humanoid") then
                        return
                end

                local stand = {Parent = model, Health = 100, MaxHealth = 100}

                rigOf[model] = stand
                rigSet[stand] = true
                npcSet[stand] = true
        end

        local function dropRig(model)
                local stand = rigOf[model]

                if stand then
                        rigOf[model] = nil
                        rigSet[stand] = nil
                        npcSet[stand] = nil
                end
        end

        track(workspace.DescendantAdded:Connect(function(object)
                if object:IsA("Humanoid") then
                        npcSet[object] = true
                        dropRig(object.Parent)
                elseif object.Name == "HumanoidRootPart" then
                        considerRig(object)
                end
        end))

        track(workspace.DescendantRemoving:Connect(function(object)
                if npcSet[object] then
                        npcSet[object] = nil
                end

                if rigOf[object] then
                        dropRig(object)
                end
        end))

        task.spawn(function()
                local counter = 0

                for _, object in ipairs(workspace:GetDescendants()) do
                        if object:IsA("Humanoid") then
                                npcSet[object] = true
                        elseif object.Name == "HumanoidRootPart" then
                                considerRig(object)
                        end

                        counter = counter + 1
                        if counter % 4000 == 0 then
                                task.wait()
                        end
                end
        end)

        local function maxDistance()
                if CL.maxDist >= MAXDIST_INF then
                        return math.huge
                end
                return CL.maxDist
        end

        local function isEnemyPlayer(other)
                if not CL.enemiesOnly then
                        return true
                end

                local myTeam = player.Team
                if myTeam and other.Team == myTeam then
                        return false
                end

                return true
        end

        local function bodyPartOf(model)
                local part = model:FindFirstChild("HumanoidRootPart")
                        or model.PrimaryPart
                        or model:FindFirstChild("UpperTorso")
                        or model:FindFirstChild("Torso")

                if part and part:IsA("BasePart") then
                        return part
                end

                return model:FindFirstChildWhichIsA("BasePart")
        end

        local function aimPartOf(model)
                if CL.aimPart == 1 then
                        local head = model:FindFirstChild("Head")

                        if head and head:IsA("BasePart") then
                                return head
                        end
                end

                return bodyPartOf(model)
        end

        local rayParams = RaycastParams.new()
        rayParams.FilterType = Enum.RaycastFilterType.Exclude
        rayParams.IgnoreWater = true
        rayParams.RespectCanCollide = true

        local function castThroughCharacters(origin, vector, ignore)
                for _ = 1, 4 do
                        rayParams.FilterDescendantsInstances = ignore
                        local result = workspace:Raycast(origin, vector, rayParams)

                        if not result then
                                return nil
                        end

                        local hitModel = result.Instance:FindFirstAncestorOfClass("Model")

                        if hitModel and hitModel:FindFirstChildOfClass("Humanoid") then
                                table.insert(ignore, hitModel)
                        else
                                return result
                        end
                end

                return nil
        end

        local function isVisible(candidate)
                local camera = workspace.CurrentCamera

                if not camera then
                        return true
                end

                local character = player.Character
                local ignore = {candidate.model}

                if character then
                        table.insert(ignore, character)
                end

                local origin = camera.CFrame.Position
                local goal = candidate.part.Position

                return castThroughCharacters(origin, goal - origin, ignore) == nil
        end

        local function collectCandidates()
                local list = {}
                local character, _, root = myParts()

                if not root then
                        return list
                end

                local myPos = root.Position
                local limit = maxDistance()

                local function try(model, hum, owner)
                        if model == character or not Safe.alive(hum, model) then
                                return
                        end

                        if character and model:IsDescendantOf(character) then
                                return
                        end

                        local part = aimPartOf(model)

                        if not part then
                                return
                        end

                        local dist = (part.Position - myPos).Magnitude

                        if dist > limit then
                                return
                        end

                        list[#list + 1] = {model = model, hum = hum, player = owner, part = part, dist = dist}
                end

                if CL.players then
                        for _, other in ipairs(Players:GetPlayers()) do
                                if other ~= player and isEnemyPlayer(other) then
                                        local model = other.Character
                                        local hum = model and model:FindFirstChildOfClass("Humanoid")

                                        if hum and model.Parent then
                                                try(model, hum, other)
                                        end
                                end
                        end
                end

                if CL.npcs then
                        for hum in pairs(npcSet) do
                                local model = hum.Parent

                                if not model or not model:IsDescendantOf(workspace) then
                                        npcSet[hum] = nil
                                elseif model:IsA("Model") and not Players:GetPlayerFromCharacter(model) then
                                        if not rigSet[hum] or CL.rigs then
                                                try(model, hum, nil)
                                        end
                                end
                        end
                end

                return list
        end

        local function pickBest(excludeModel)
                local camera = workspace.CurrentCamera

                if not camera then
                        return nil
                end

                local camPos = camera.CFrame.Position
                local look = camera.CFrame.LookVector
                local scored = {}

                for _, c in ipairs(collectCandidates()) do
                        if c.model ~= excludeModel then
                                local dir = c.part.Position - camPos
                                local length = dir.Magnitude
                                local angle = 0

                                if length > 0.001 then
                                        angle = math.acos(math.clamp(look:Dot(dir / length), -1, 1))
                                end

                                if CL.mode == 1 then
                                        c.score = angle
                                elseif CL.mode == 2 then
                                        c.score = c.hum.Health + angle * 0.01
                                else
                                        c.score = c.dist + angle
                                end

                                scored[#scored + 1] = c
                        end
                end

                table.sort(scored, function(a, b)
                        return a.score < b.score
                end)

                local checks = 0

                for _, c in ipairs(scored) do
                        if CL.throughWalls then
                                return c
                        end

                        checks = checks + 1
                        if checks > MAX_VIS_CHECKS then
                                break
                        end

                        if isVisible(c) then
                                return c
                        end
                end

                return nil
        end

        local function flashNoTarget()
                flashToken = flashToken + 1
                local token = flashToken

                local text = "Нет целей рядом. Проверь настройки в меню"

                if #collectCandidates() > 0 then
                        text = "Цели есть, но за стеной. Включи «Брать через стены»"
                end

                camButton.Text = "НЕТ ЦЕЛИ"
                camButton.TextSize = camText(18)
                camStroke.Color = Color3.fromRGB(235, 80, 80)
                showToast(text, Color3.fromRGB(235, 120, 120))

                task.delay(1, function()
                        if token == flashToken then
                                refreshCamButtons()
                        end
                end)
        end

        local function turnOff()
                if not armed and not target then
                        return
                end

                armed = false
                target = nil
                lockAimPoint = nil
                leadPrev = nil
                leadVel = Vector3.zero
                refreshCamButtons()
        end

        local function beginOverlay(camera)
                if not fovActive then
                        baseFov = camera.FieldOfView
                        fovActive = true
                end

                if overlay then
                        return
                end

                overlay = true
                camLook = camera.CFrame.LookVector

                local distance = (camera.CFrame.Position - camera.Focus.Position).Magnitude
                camDist = math.clamp(distance + CAM_DIST_EXTRA, DIST_MIN, DIST_MAX)
        end

        local function setTarget(candidate)
                if not candidate then
                        return false
                end

                local camera = workspace.CurrentCamera
                local _, humanoid, root = myParts()

                if not camera or not humanoid or not root then
                        return false
                end

                armed = true
                target = candidate
                leadPrev = nil
                leadVel = Vector3.zero
                targetVel = Vector3.zero
                lastTargetVel = Vector3.zero
                lastTargetPos = candidate.part.Position
                visTimer = 0
                hiddenTime = 0

                beginOverlay(camera)
                refreshCamButtons()

                return true
        end

        local function onTargetLost()
                turnOff()
        end

        local function updateTarget(dt, camera, root)
                local c = target

                if not c then
                        return nil
                end

                if not c.hum.Parent or not Safe.alive(c.hum, c.model) or not c.model.Parent then
                        onTargetLost()
                        return nil
                end

                local part = aimPartOf(c.model)

                if not part then
                        onTargetLost()
                        return nil
                end

                c.part = part

                local pos = part.Position
                local dist = (pos - root.Position).Magnitude

                if dist > maxDistance() * 1.1 then
                        onTargetLost()
                        return nil
                end

                c.dist = dist

                visTimer = visTimer + dt

                if visTimer >= 0.2 then
                        local waited = visTimer
                        visTimer = 0

                        if CL.throughWalls or isVisible(c) then
                                hiddenTime = 0
                        else
                                hiddenTime = hiddenTime + waited
                        end
                end

                if hiddenTime >= HIDDEN_RELEASE then
                        hiddenTime = 0
                        onTargetLost()
                        return nil
                end

                local velPart = bodyPartOf(c.model) or part
                local velPos = velPart.Position
                local measured = Vector3.zero

                if c.lastVelPos and dt > 0 then
                        local jump = velPos - c.lastVelPos

                        if jump.Magnitude > TELEPORT_DIST then
                                c.vFast = nil
                                c.vSlow = nil
                        else
                                measured = jump / dt
                        end
                end

                c.lastVelPos = velPos

                local raw = velPart.AssemblyLinearVelocity

                if raw.Magnitude < 0.5 then
                        raw = measured
                end

                if not c.vFast then
                        c.vFast = raw
                        c.vSlow = raw
                elseif dt > 0 then
                        c.vFast = c.vFast:Lerp(raw, 1 - math.exp(-VEL_FAST * dt))
                        c.vSlow = c.vSlow:Lerp(raw, 1 - math.exp(-VEL_SLOW * dt))
                end

                local aim = pos

                if CL.predict and CL.predictTime > 0 then
                        local v = c.vFast

                        if c.hum.FloorMaterial ~= Enum.Material.Air then
                                v = Vector3.new(v.X, 0, v.Z)
                        else
                                v = Vector3.new(v.X, v.Y * 0.5, v.Z)
                        end

                        local flatNow = Vector3.new(v.X, 0, v.Z)

                        if v.Magnitude > STABLE_SPEED then
                                local factor = 1

                                if CL.predictNear > 0 then
                                        factor = math.clamp(dist / CL.predictNear, 0, 1)
                                end

                                if CL.predictSmart then
                                        local flatSlow = Vector3.new(c.vSlow.X, 0, c.vSlow.Z)

                                        if flatSlow.Magnitude > 2 then
                                                if flatNow.Magnitude < flatSlow.Magnitude then
                                                        factor = factor * math.clamp(flatNow.Magnitude / flatSlow.Magnitude, 0.25, 1)
                                                end

                                                if flatNow.Magnitude > 2 then
                                                        local dot = flatSlow.Unit:Dot(flatNow.Unit)

                                                        if dot < 0.7 then
                                                                factor = factor * (TURN_DAMP + (1 - TURN_DAMP) * math.clamp((dot + 1) / 1.7, 0, 1))
                                                        end
                                                end
                                        end
                                end

                                local offset = v * (CL.predictTime / 1000) * factor

                                if offset.Magnitude > CL.predictCap then
                                        offset = offset.Unit * CL.predictCap
                                end

                                aim = pos + offset
                        end
                end

                return aim
        end

        local function hardReset()
                AT.rot = Vector3.zero
                AT.gap = nil
                armed = false
                target = nil
                blend = 0
                overlay = false
                lockAimPoint = nil

                local camera = workspace.CurrentCamera

                if camera and fovActive then
                        camera.FieldOfView = baseFov
                end

                fovActive = false
                refreshCamButtons()
        end

        local function clampPitch(direction)
                local limit = 0.94

                if math.abs(direction.Y) <= limit then
                        return direction
                end

                local flat = Vector3.new(direction.X, 0, direction.Z)

                if flat.Magnitude < 0.0001 then
                        flat = Vector3.new(camLook.X, 0, camLook.Z)
                end

                if flat.Magnitude < 0.0001 then
                        flat = Vector3.new(0, 0, -1)
                end

                flat = flat.Unit

                local horizontal = math.sqrt(1 - limit * limit)

                return Vector3.new(flat.X * horizontal, limit * math.sign(direction.Y), flat.Z * horizontal)
        end

        local crossCache = {x = 0, y = 0, found = false, path = nil, last = 0, object = nil, guessed = false}
        local crossPatterns = {"crosshair", "cross", "reticle", "sight", "scope", "pricel", "прицел", "aim"}

        local function isGuiShown(object)
                local current = object

                while current and current ~= playerGui do
                        if current:IsA("GuiObject") and not current.Visible then
                                return false
                        end

                        if current:IsA("LayerCollector") and not current.Enabled then
                                return false
                        end

                        current = current.Parent
                end

                return current == playerGui
        end

        -- центр объекта в координатах экрана камеры, от -1 до 1 (читается каждый кадр)
        local function crossNdcOf(object, camera)
                local viewport = camera.ViewportSize

                if viewport.X <= 0 or viewport.Y <= 0 then
                        return nil
                end

                local size = object.AbsoluteSize
                local screen = object:FindFirstAncestorWhichIsA("LayerCollector")
                local origin = Vector2.zero

                if screen and screen:IsA("ScreenGui") and not screen.IgnoreGuiInset then
                        origin = GuiService:GetGuiInset()
                end

                local position = object.AbsolutePosition + size / 2 + origin
                local offset = position - viewport / 2

                return offset.X / (viewport.X / 2), -offset.Y / (viewport.Y / 2)
        end

        local function findCrosshair(camera)
                local viewport = camera.ViewportSize

                if viewport.X <= 0 or viewport.Y <= 0 then
                        return
                end

                local center = viewport / 2
                local inset = GuiService:GetGuiInset()
                local bestScore = nil
                local bestObject = nil
                local guessScore = nil
                local guessObject = nil

                for _, object in ipairs(playerGui:GetDescendants()) do
                        if object:IsA("GuiObject") and not object:IsA("GuiButton") and not object:IsDescendantOf(gui) then
                                local size = object.AbsoluteSize

                                if size.X >= 2 and size.Y >= 2 and size.X <= 220 and size.Y <= 220 then
                                        local lower = string.lower(object.Name)
                                        local named = false

                                        for _, pattern in ipairs(crossPatterns) do
                                                if string.find(lower, pattern, 1, true) then
                                                        named = true
                                                        break
                                                end
                                        end

                                        local guess = false

                                        if not named and CL.crossGuess and size.X <= 120 and size.Y <= 120 then
                                                if object:IsA("ImageLabel") then
                                                        guess = object.Image ~= "" and object.ImageTransparency < 0.95
                                                elseif object:IsA("Frame") then
                                                        guess = object.BackgroundTransparency < 0.95
                                                end
                                        end

                                        if (named or guess) and isGuiShown(object) then
                                                local screen = object:FindFirstAncestorWhichIsA("LayerCollector")
                                                local origin = Vector2.zero

                                                if screen and screen:IsA("ScreenGui") and not screen.IgnoreGuiInset then
                                                        origin = inset
                                                end

                                                local offset = object.AbsolutePosition + size / 2 + origin - center

                                                if named then
                                                        if math.abs(offset.X) <= viewport.X * 0.15 and math.abs(offset.Y) <= viewport.Y * 0.35 then
                                                                local score = -offset.Magnitude - (size.X + size.Y) * 0.05

                                                                if bestScore == nil or score > bestScore then
                                                                        bestScore = score
                                                                        bestObject = object
                                                                end
                                                        end
                                                elseif math.abs(offset.X) <= viewport.X * 0.03 and math.abs(offset.Y) <= viewport.Y * 0.3 then
                                                        local score = -math.abs(offset.X) - math.abs(offset.Y) * 0.2 - (size.X + size.Y) * 0.1

                                                        if guessScore == nil or score > guessScore then
                                                                guessScore = score
                                                                guessObject = object
                                                        end
                                                end
                                        end
                                end
                        end
                end

                local chosen = bestObject or guessObject

                if chosen then
                        local newPath = chosen:GetFullName()

                        if crossCache.path ~= newPath then
                                if bestObject then
                                        showToast("Прицел найден: " .. chosen.Name, K.GOLD)
                                        warn("[MainPanel] Прицел: " .. newPath)
                                else
                                        showToast("Прицел по догадке: " .. chosen.Name, K.GOLD)
                                end
                        end

                        crossCache.found = true
                        crossCache.guessed = bestObject == nil
                        crossCache.path = newPath
                        crossCache.object = chosen
                else
                        crossCache.found = false
                        crossCache.path = nil
                        crossCache.object = nil
                end
        end

        local function crosshairNdc(camera)
                if CL.crossAuto then
                        local object = crossCache.object

                        if object and object.Parent and isGuiShown(object) then
                                local x, y = crossNdcOf(object, camera)

                                if x then
                                        -- пока прицел найден, перепроверяем редко; позицию читаем живьём каждый кадр
                                        if os.clock() - crossCache.last > 1.5 then
                                                crossCache.last = os.clock()
                                                pcall(findCrosshair, camera)
                                        end

                                        -- прицел игры стоит почти по центру по горизонтали и не ниже центра сильно;
                                        -- всё остальное считаем ошибкой поиска и берём ручное значение
                                        if x == x and y == y and math.abs(x) <= 0.2 and y >= -0.2 and y <= 1 then
                                                return x, y
                                        end
                                end
                        end

                        if os.clock() - crossCache.last > 0.5 then
                                crossCache.last = os.clock()
                                pcall(findCrosshair, camera)
                        end
                end

                return 0, 2 * (CL.crossUp / 100)
        end

        local function solveLook(shoulder, target, camera, ndcX, ndcY, ignore)
                local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2)
                local viewport = camera.ViewportSize
                local aspect = viewport.X / math.max(1, viewport.Y)
                local localRay = Vector3.new(ndcX * tanHalf * aspect, ndcY * tanHalf, -1).Unit
                local toTarget = math.max(0.5, (target - shoulder).Magnitude)

                -- ошибка наводки: угол между лучом через прицел и направлением на цель
                local function evaluate(look)
                        local back = look * -camDist
                        local hit = castThroughCharacters(shoulder, back, ignore)
                        local dist = camDist

                        if hit then
                                dist = math.max(1, hit.Distance - 0.5)
                        end

                        local cameraPos = shoulder - look * dist
                        local wanted = target - cameraPos

                        if wanted.Magnitude < 0.1 then
                                return nil
                        end

                        wanted = wanted.Unit

                        local current = CFrame.lookAt(cameraPos, cameraPos + look):VectorToWorldSpace(localRay)
                        local axis = current:Cross(wanted)

                        return math.atan2(axis.Magnitude, current:Dot(wanted)), axis, dist
                end

                local look = clampPitch((target - shoulder).Unit)
                local angle, axis, dist = evaluate(look)

                if not angle then
                        return look
                end

                -- камера стоит позади плеча: поворот на x двигает её вбок на dist*x,
                -- поэтому на близких целях поправку усиливаем, а если стало хуже, смягчаем
                local gain = math.clamp((dist + toTarget) / toTarget, 1, 8)

                for _ = 1, 12 do
                        if angle < 0.0003 or axis.Magnitude < 1e-6 then
                                break
                        end

                        local tryLook = clampPitch(CFrame.fromAxisAngle(axis.Unit, angle * gain):VectorToWorldSpace(look))
                        local tryAngle, tryAxis, tryDist = evaluate(tryLook)

                        if tryAngle and tryAngle < angle then
                                look, angle, axis, dist = tryLook, tryAngle, tryAxis, tryDist
                        else
                                gain = 1 + (gain - 1) * 0.5

                                if gain < 1.03 then
                                        break
                                end
                        end
                end

                return look
        end

        local function onCameraStep(dt)
                local camera = workspace.CurrentCamera
                lockAimPoint = nil

                if not camera then
                        return
                end

                local character, humanoid, root = myParts()
                local alive = humanoid ~= nil and root ~= nil and root.Parent ~= nil and humanoid.Health > 0

                if armed and not alive then
                        turnOff()
                end

                local aimPoint = nil

                if armed and alive then
                        if target then
                                aimPoint = updateTarget(dt, camera, root)
                        else
                                turnOff()
                        end
                end

                local wantOverlay = armed and target ~= nil

                if fovActive then
                        local want = baseFov

                        if wantOverlay then
                                want = CL.fov
                        end

                        local fov = camera.FieldOfView
                        fov = fov + (want - fov) * (1 - math.exp(-10 * dt))

                        if not wantOverlay and math.abs(fov - baseFov) < 0.05 then
                                fov = baseFov
                                fovActive = false
                        end

                        camera.FieldOfView = fov
                end

                if wantOverlay then
                        blend = math.min(1, blend + dt / BLEND_TIME)
                else
                        blend = math.max(0, blend - dt / BLEND_TIME)
                end

                if not overlay then
                        return
                end

                if not alive then
                        overlay = false
                        blend = 0
                        return
                end

                local nativeCFrame = camera.CFrame
                local nativeFocus = camera.Focus

                if CL.zoomFollow and camera.CameraType == Enum.CameraType.Custom then
                        -- зум пальцами работает и во время лока: берём расстояние штатной камеры
                        local nativeDist = (nativeCFrame.Position - nativeFocus.Position).Magnitude

                        if nativeDist > 0.5 then
                                local goalDist = math.clamp(nativeDist, 4, math.max(DIST_MAX, player.CameraMaxZoomDistance))
                                camDist = camDist + (goalDist - camDist) * (1 - math.exp(-10 * dt))
                        end
                end

                local e = blend * blend * (3 - 2 * blend)

                local pivot = root.Position + Vector3.new(0, FOCUS_Y + CL.height, 0)
                local right = camLook:Cross(Vector3.yAxis)

                if right.Magnitude > 0.001 then
                        right = right.Unit
                else
                        right = nativeCFrame.RightVector
                end

                local shoulderPos = pivot + right * CL.side
                local ignore = {}

                if character then
                        table.insert(ignore, character)
                end

                if math.abs(CL.side) > 0.05 then
                        local toShoulder = shoulderPos - pivot
                        local hit = castThroughCharacters(pivot, toShoulder, ignore)

                        if hit then
                                shoulderPos = pivot + toShoulder.Unit * math.max(0, hit.Distance - 0.3)
                        end
                end

                if aimPoint then
                        if CL.aimLift ~= 0 then
                                aimPoint = aimPoint + Vector3.new(0, CL.aimLift, 0)
                        end

                        local toAim = aimPoint - shoulderPos

                        if toAim.Magnitude > 0.5 then
                                local ndcX, ndcY = crosshairNdc(camera)
                                local okSolve, solved = pcall(solveLook, shoulderPos, aimPoint, camera, ndcX, ndcY, ignore)
                                local desired

                                if okSolve and typeof(solved) == "Vector3" and solved.Magnitude > 0.5 and solved.X == solved.X and solved.Y == solved.Y and solved.Z == solved.Z then
                                        desired = solved
                                else
                                        desired = clampPitch(toAim.Unit)
                                end

                                AT.ndcX, AT.ndcY = ndcX, ndcY

                                if CL.aimTrim and (math.abs(AT.rot.X) > 0.00001 or math.abs(AT.rot.Y) > 0.00001) then
                                        -- поправка хранится как поворот вокруг вертикали (X) и вокруг «вправо» (Y):
                                        -- так она не зависит от того, куда сейчас смотрит камера
                                        local trimmed = CFrame.fromAxisAngle(Vector3.yAxis, AT.rot.X):VectorToWorldSpace(desired)
                                        local sideAxis = trimmed:Cross(Vector3.yAxis)

                                        if sideAxis.Magnitude > 0.001 then
                                                trimmed = CFrame.fromAxisAngle(sideAxis.Unit, AT.rot.Y):VectorToWorldSpace(trimmed)
                                        end

                                        if trimmed.Magnitude > 0.5 then
                                                desired = clampPitch(trimmed.Unit)
                                        end
                                end

                                AT.gap = (camLook - desired).Magnitude

                                if CL.aimLead and dt > 0 then
                                        -- фильтр сглаживания отстаёт от движущейся цели на (угловая скорость / скорость наводки):
                                        -- добавляем это опережение, чтобы на ходу прицел сидел точно на цели
                                        if leadPrev then
                                                local raw = (desired - leadPrev) / dt

                                                if raw.Magnitude > 12 then
                                                        raw = raw.Unit * 12
                                                end

                                                leadVel = leadVel:Lerp(raw, 1 - math.exp(-25 * dt))
                                        end

                                        leadPrev = desired

                                        local leaded = desired + leadVel * (1 / math.max(1, CL.aimSpeed))

                                        if leaded.Magnitude > 0.001 then
                                                desired = clampPitch(leaded.Unit)
                                        end
                                else
                                        leadPrev = nil
                                        leadVel = Vector3.zero
                                end

                                local mixed = camLook:Lerp(desired, 1 - math.exp(-CL.aimSpeed * dt))

                                if mixed.Magnitude > 0.001 then
                                        camLook = mixed.Unit
                                else
                                        camLook = desired
                                end
                        end
                end

                lockAimPoint = aimPoint

                local back = camLook * -camDist
                local cameraPos = shoulderPos + back
                local backHit = castThroughCharacters(shoulderPos, back, ignore)

                if backHit then
                        cameraPos = shoulderPos + back.Unit * math.max(1, backHit.Distance - 0.5)
                end

                local oursCFrame = CFrame.lookAt(cameraPos, cameraPos + camLook)
                local oursFocus = CFrame.new(shoulderPos)

                if blend >= 1 then
                        camera.CFrame = oursCFrame
                        camera.Focus = oursFocus
                else
                        camera.CFrame = nativeCFrame:Lerp(oursCFrame, e)
                        camera.Focus = nativeFocus:Lerp(oursFocus, e)
                end

                -- замкнутый контур: спрашиваем у самой камеры, через какую точку экрана идёт луч,
                -- и подкручиваем наводку, если цель не в прицеле (лечит любые ошибки модели FOV, отступов и т.п.)
                if CL.aimTrim and aimPoint and blend >= 1 and AT.ndcX and AT.gap and AT.gap < 0.01 and leadVel.Magnitude < 0.05 then
                        pcall(function()
                                local viewport = camera.ViewportSize
                                local ray = camera:ViewportPointToRay((AT.ndcX + 1) / 2 * viewport.X, (1 - AT.ndcY) / 2 * viewport.Y)
                                local wanted = aimPoint - ray.Origin

                                if wanted.Magnitude > 0.5 then
                                        wanted = wanted.Unit

                                        local axis = ray.Direction:Cross(wanted)
                                        local angle = math.atan2(axis.Magnitude, ray.Direction:Dot(wanted))

                                        if angle > 0.0004 and angle < 0.25 and axis.Magnitude > 1e-7 then
                                                local turn = axis.Unit * angle
                                                local sideAxis = camLook:Cross(Vector3.yAxis)

                                                if sideAxis.Magnitude > 0.001 then
                                                        sideAxis = sideAxis.Unit

                                                        AT.rot = Vector3.new(
                                                                math.clamp(AT.rot.X + turn.Y * 0.35, -0.12, 0.12),
                                                                math.clamp(AT.rot.Y + turn:Dot(sideAxis) * 0.35, -0.12, 0.12),
                                                                0
                                                        )
                                                end
                                        end
                                end
                        end)
                elseif not aimPoint then
                        AT.gap = nil
                end

                if CL.crossDot and wantOverlay and AT.ndcX then
                        pcall(function()
                                if not AT.dot or not AT.dot.Parent then
                                        local dot = Instance.new("Frame")
                                        dot.Name = "CrossDot"
                                        dot.AnchorPoint = Vector2.new(0.5, 0.5)
                                        dot.Size = UDim2.fromOffset(8, 8)
                                        dot.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
                                        dot.BorderSizePixel = 0
                                        dot.ZIndex = 50
                                        dot.Active = false

                                        local corner = Instance.new("UICorner")
                                        corner.CornerRadius = UDim.new(1, 0)
                                        corner.Parent = dot

                                        dot.Parent = gui
                                        AT.dot = dot
                                end

                                local viewport = camera.ViewportSize
                                local inset = GuiService:GetGuiInset()

                                AT.dot.Position = UDim2.fromOffset(
                                        (AT.ndcX + 1) / 2 * viewport.X - inset.X,
                                        (1 - AT.ndcY) / 2 * viewport.Y - inset.Y
                                )
                                AT.dot.Visible = true
                        end)
                elseif AT.dot then
                        AT.dot.Visible = false
                end

                uiTimer = uiTimer + dt

                if uiTimer >= 0.1 then
                        uiTimer = 0
                end

                if blend <= 0 and not wantOverlay then
                        overlay = false
                end
        end

        pcall(function()
                RunService:UnbindFromRenderStep("CamLockCamera")
        end)

        Safe.trip.CamLockCamera = function()
                hardReset()
        end

        Safe.bind("CamLockCamera", Enum.RenderPriority.Camera.Value + 1, onCameraStep)

        do
                local ZOOM_STUCK_TIME = 0.35
                local ZOOM_GIVE_UP_TIME = 0.8
                local wantedZoom = nil
                local stuckTime = 0
                local retried = false
                local restoring = false
                local lastZoomInput = 0

                local zoomParams = RaycastParams.new()
                zoomParams.FilterType = Enum.RaycastFilterType.Exclude
                zoomParams.IgnoreWater = true

                track(UserInputService.TouchPinch:Connect(function()
                        lastZoomInput = os.clock()
                end))

                track(UserInputService.InputChanged:Connect(function(input)
                        if input.UserInputType == Enum.UserInputType.MouseWheel then
                                lastZoomInput = os.clock()
                        end
                end))

                track(UserInputService.InputBegan:Connect(function(input)
                        if input.KeyCode == Enum.KeyCode.I or input.KeyCode == Enum.KeyCode.O then
                                lastZoomInput = os.clock()
                        end
                end))

                pcall(function()
                        RunService:UnbindFromRenderStep("MainPanelZoomKeeper")
                end)

                local function zoomStep(dt)
                        local camera = workspace.CurrentCamera
                        local character, humanoid = myParts()

                        if not camera
                                or not humanoid
                                or humanoid.Health <= 0
                                or overlay
                                or restoring
                                or camera.CameraType ~= Enum.CameraType.Custom
                                or not CL.zoomKeep
                                or humanoid.Sit
                                or humanoid.PlatformStand
                                or player.CameraMinZoomDistance >= player.CameraMaxZoomDistance
                        then
                                stuckTime = 0
                                return
                        end

                        local focusPos = camera.Focus.Position
                        local offset = camera.CFrame.Position - focusPos
                        local dist = offset.Magnitude

                        if dist < 1
                                or wantedZoom == nil
                                or dist >= wantedZoom - 0.15
                                or os.clock() - lastZoomInput < 1
                        then
                                wantedZoom = dist
                                stuckTime = 0
                                retried = false
                                return
                        end

                        if wantedZoom - dist < 1 then
                                stuckTime = 0
                                return
                        end

                        zoomParams.FilterDescendantsInstances = {character}

                        local blocked = workspace:Spherecast(focusPos, 0.6, offset.Unit * (wantedZoom + 0.5), zoomParams)

                        if blocked then
                                stuckTime = 0
                                return
                        end

                        stuckTime = stuckTime + dt

                        if stuckTime < ZOOM_STUCK_TIME then
                                return
                        end

                        if retried then
                                if stuckTime >= ZOOM_GIVE_UP_TIME then
                                        wantedZoom = dist
                                        stuckTime = 0
                                        retried = false
                                end

                                return
                        end

                        retried = true
                        restoring = true

                        local oldMin = player.CameraMinZoomDistance
                        local goal = math.clamp(wantedZoom, oldMin, player.CameraMaxZoomDistance)

                        pcall(function()
                                player.CameraMinZoomDistance = goal
                        end)

                        task.delay(0.2, function()
                                pcall(function()
                                        if player.CameraMinZoomDistance == goal then
                                                player.CameraMinZoomDistance = oldMin
                                        end
                                end)

                                restoring = false
                        end)
                end

                Safe.bind("MainPanelZoomKeeper", Enum.RenderPriority.Camera.Value + 3, function(dt)
                        pcall(zoomStep, dt)
                end)
        end

        function toggleLock()
                if armed then
                        turnOff()
                        return
                end

                local _, humanoid = myParts()

                if not humanoid or humanoid.Health <= 0 then
                        showToast("Персонаж ещё не появился", Color3.fromRGB(235, 120, 120))
                        return
                end

                local best = pickBest(nil)

                if best and setTarget(best) then
                        return
                end

                flashNoTarget()
        end

        track(UserInputService.InputBegan:Connect(function(input, processed)
                if processed then
                        return
                end

                if input.UserInputType == Enum.UserInputType.Keyboard then
                        if input.KeyCode == K.CAM_KEY then
                                toggleLock()
                        end
                end
        end))

        local function onCharacterAdded(character)
                hardReset()
                rotateHeld = false
                rotateHumanoid = nil
                shiftOffsetDirty = true

                if gui and not gui.Parent then
                        gui.Parent = playerGui
                end

                local humanoid = character:WaitForChild("Humanoid", 10)

                if humanoid then
                        track(humanoid.Died:Connect(function()
                                turnOff()
                        end))
                end
        end

        track(player.CharacterAdded:Connect(onCharacterAdded))

        track(player.CharacterRemoving:Connect(function()
                hardReset()
        end))

        if player.Character then
                task.spawn(onCharacterAdded, player.Character)
        end

        refreshCamButtons()

        cleanupCamLock = function()
                hardReset()
                releaseAutoRotate()
                setMouseLock(false)

                local humanoid = getHumanoid()

                if humanoid and shiftLockOn then
                        humanoid.CameraOffset = Vector3.zero
                end

        end
end

do
        local okCam, errCam = pcall(setupCamLock)

        if not okCam then
                warn("[MainPanel] Камлок не запустился: " .. tostring(errCam))
        end
end

do
        local ESP_MAX = 24
        local NPC_COLOR = Color3.fromRGB(255, 60, 60)
        local PLAYER_COLOR = Color3.fromRGB(255, 255, 255)

        local container = nil
        local active = {}
        local known = {}
        local rigOf = {}
        local rigSet = {}
        local timer = 0

        local function destroyContainer()
                for model, highlight in pairs(active) do
                        pcall(function()
                                highlight:Destroy()
                        end)
                        active[model] = nil
                end

                if container then
                        pcall(function()
                                container:Destroy()
                        end)
                        container = nil
                end
        end

        local function getContainer()
                if container and container.Parent then
                        return container
                end

                local parents = {}

                pcall(function()
                        table.insert(parents, gethui())
                end)

                pcall(function()
                        table.insert(parents, game:GetService("CoreGui"))
                end)

                if workspace.CurrentCamera then
                        table.insert(parents, workspace.CurrentCamera)
                end

                table.insert(parents, workspace)

                for _, parent in ipairs(parents) do
                        pcall(function()
                                local stale = parent:FindFirstChild("MainPanelESP")

                                if stale then
                                        stale:Destroy()
                                end
                        end)
                end

                for _, parent in ipairs(parents) do
                        local folder = Instance.new("Folder")
                        folder.Name = "MainPanelESP"

                        local placed = pcall(function()
                                folder.Parent = parent
                        end)

                        if placed and folder.Parent == parent then
                                container = folder
                                return container
                        end

                        folder:Destroy()
                end

                return nil
        end

        local function considerRig(part)
                if part.Name ~= "HumanoidRootPart" or not part:IsA("BasePart") then
                        return
                end

                local model = part.Parent

                if not model or not model:IsA("Model") or rigOf[model] then
                        return
                end

                if model:FindFirstChildOfClass("Humanoid") then
                        return
                end

                local stand = {Parent = model, Health = 100}

                rigOf[model] = stand
                rigSet[stand] = true
                known[stand] = true
        end

        track(workspace.DescendantAdded:Connect(function(object)
                if object:IsA("Humanoid") then
                        known[object] = true

                        local stand = rigOf[object.Parent]

                        if stand then
                                rigOf[object.Parent] = nil
                                rigSet[stand] = nil
                                known[stand] = nil
                        end
                elseif object.Name == "HumanoidRootPart" then
                        considerRig(object)
                end
        end))

        task.spawn(function()
                local counter = 0

                for _, object in ipairs(workspace:GetDescendants()) do
                        if object:IsA("Humanoid") then
                                known[object] = true
                        elseif object.Name == "HumanoidRootPart" then
                                considerRig(object)
                        end

                        counter = counter + 1

                        if counter % 4000 == 0 then
                                task.wait()
                        end
                end
        end)

        local function espStep()
                if not CL or not CL.esp then
                        if container or next(active) then
                                destroyContainer()
                        end

                        return
                end

                local holder = getContainer()

                if not holder then
                        return
                end

                local myCharacter = player.Character
                local camera = workspace.CurrentCamera
                local myRoot = myCharacter and myCharacter:FindFirstChild("HumanoidRootPart")
                local origin = myRoot and myRoot.Position or (camera and camera.CFrame.Position)
                local limit = CL.espDist >= MAXDIST_INF and math.huge or CL.espDist
                local list = {}

                for humanoid in pairs(known) do
                        local model = humanoid.Parent

                        if not model or not model:IsDescendantOf(workspace) then
                                known[humanoid] = nil

                                if rigSet[humanoid] then
                                        rigSet[humanoid] = nil
                                        rigOf[model or false] = nil
                                end
                        elseif rigSet[humanoid] and not CL.rigs then
                                -- модели без Humanoid выключены в меню
                        elseif model:IsA("Model") and model ~= myCharacter and Safe.alive(humanoid, model) then
                                local owner = Players:GetPlayerFromCharacter(model)
                                local isPlayer = owner ~= nil
                                local wanted = (isPlayer and CL.espPlayers) or (not isPlayer and CL.espNpcs)

                                if wanted and isPlayer and CL.enemiesOnly and owner.Team ~= nil and owner.Team == player.Team then
                                        wanted = false
                                end

                                if wanted then
                                        local part = model:FindFirstChild("HumanoidRootPart")
                                                or model.PrimaryPart
                                                or model:FindFirstChildWhichIsA("BasePart")

                                        if part then
                                                local dist = origin and (part.Position - origin).Magnitude or 0

                                                if dist <= limit then
                                                        list[#list + 1] = {model = model, dist = dist, isPlayer = isPlayer}
                                                end
                                        end
                                end
                        end
                end

                table.sort(list, function(a, b)
                        return a.dist < b.dist
                end)

                local keep = {}

                for i = 1, math.min(#list, ESP_MAX) do
                        local entry = list[i]
                        local highlight = active[entry.model]

                        if not highlight or not highlight.Parent then
                                highlight = Instance.new("Highlight")
                                highlight.Name = "MainPanelESPHighlight"
                                highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                                highlight.Adornee = entry.model
                                highlight.Parent = holder
                                active[entry.model] = highlight
                        end

                        local color = entry.isPlayer and PLAYER_COLOR or NPC_COLOR

                        highlight.FillColor = color
                        highlight.OutlineColor = color
                        highlight.FillTransparency = 1 - math.clamp(CL.espFill / 100, 0, 1)
                        highlight.OutlineTransparency = 1 - math.clamp(CL.espOutline / 100, 0, 1)

                        keep[entry.model] = true
                end

                for model, highlight in pairs(active) do
                        if not keep[model] then
                                pcall(function()
                                        highlight:Destroy()
                                end)

                                active[model] = nil
                        end
                end
        end

        local avgDt = 1 / 60

        track(RunService.Heartbeat:Connect(function(dt)
                -- чем слабее телефон (больше время кадра), тем реже обновляем подсветку
                avgDt = avgDt + (dt - avgDt) * 0.05
                timer = timer + dt

                if timer < math.clamp(0.15 * avgDt * 60, 0.15, 0.6) then
                        return
                end

                timer = 0

                local ok, err = pcall(espStep)

                if not ok then
                        warn("[MainPanel] ESP: " .. tostring(err))
                end
        end))

        -- не через track: этот обработчик должен сработать уже после отключения остальных
        gui.Destroying:Connect(destroyContainer)
end

pcall(function()
        RunService:UnbindFromRenderStep("MainPanelMove")
end)

Safe.trip.MainPanelMove = function()
        releaseStick(true)
        releaseJump()
end

Safe.bind("MainPanelMove", Enum.RenderPriority.Input.Value + 1, function(dt)
        leftBlock.Visible = CL.leftNoCam == true

        if stickInput then
                -- как в штатном Thumbstick значение берётся прямо из положения пальца.
                -- Против дрожи пальца стоит адаптивный фильтр: в покое гасит дрожь,
                -- при быстром движении почти не даёт задержки (на 0 фильтр выключен)
                local strength = CL.stickSmooth or 0
                local f = K.stickF

                if strength > 0 and dt > 0 then
                        local speedRaw = (stickRaw - f.prev) / dt
                        local aD = 1 - math.exp(-2 * math.pi * 1.5 * dt)
                        f.d = f.d:Lerp(speedRaw, aD)

                        local cutoff = 14 / strength + 15 * f.d.Magnitude
                        local a = 1 - math.exp(-2 * math.pi * cutoff * dt)
                        moveVector = moveVector:Lerp(stickRaw, math.clamp(a, 0, 1))
                else
                        moveVector = stickRaw
                end

                f.prev = stickRaw

                if stickRaw == Vector3.zero and moveVector.Magnitude < 0.03 then
                        moveVector = Vector3.zero
                end

                if moveVector.Magnitude > 1 then
                        moveVector = moveVector.Unit
                end
        end

        if stickInput and not isLive(stickInput) then
                releaseStick()
        end

        if jumpInput and not isLive(jumpInput) then
                releaseJump()
        end

        if not (stickInput or needStopMove or jumpHeld or needStopJump) then
                return
        end

        local humanoid = getHumanoid()

        if humanoid then
                if stickInput then
                        local camera = workspace.CurrentCamera

                        if camera then
                                humanoid:Move(Safe.worldMove(humanoid, camera, moveVector), false)
                        else
                                humanoid:Move(moveVector, true)
                        end
                elseif needStopMove then
                        humanoid:Move(Vector3.zero, true)
                end

                if jumpHeld then
                        humanoid.Jump = true
                elseif needStopJump then
                        humanoid.Jump = false
                end
        end

        if not stickInput then
                needStopMove = false
        end

        if not jumpHeld then
                needStopJump = false
        end
end)

do
        local WALK_SPEED = 20
        local lastHumanoid = nil
        local gameSpeed = 16
        local enforcing = false

        local function restoreSpeed(humanoid)
                if enforcing then
                        enforcing = false

                        if humanoid.WalkSpeed == WALK_SPEED then
                                humanoid.WalkSpeed = gameSpeed
                        end
                end
        end

        local blockedTime = 0
        local lastWarn = 0
        local fights = {}
        local pausedUntil = 0

        local function walkStep(dt)
                local humanoid = getHumanoid()

                if not humanoid or humanoid.Health <= 0 then
                        return
                end

                if humanoid ~= lastHumanoid then
                        lastHumanoid = humanoid
                        gameSpeed = humanoid.WalkSpeed ~= WALK_SPEED and humanoid.WalkSpeed or 16
                        enforcing = false
                        blockedTime = 0
                        fights = {}
                end

                local root = humanoid.RootPart

                if stickInput and moveVector.Magnitude > 0.2 and humanoid.MoveDirection.Magnitude < 0.05 then
                        blockedTime = blockedTime + dt

                        if blockedTime > 1.2 and os.clock() - lastWarn > 10 then
                                lastWarn = os.clock()

                                local why = "неизвестно"

                                if humanoid.WalkSpeed <= 0 then
                                        why = "WalkSpeed = 0"
                                elseif humanoid.PlatformStand then
                                        why = "PlatformStand"
                                elseif humanoid.Sit then
                                        why = "Sit"
                                elseif root and root.Anchored then
                                        why = "Anchored"
                                end

                                showToast("Игра держит персонажа: " .. why, Color3.fromRGB(235, 120, 120))
                        end
                else
                        blockedTime = 0
                end

                local now = os.clock()

                -- игра возвращает скорость сразу после нас (защита от читов?): отступаем, чтобы не словить кик и не сломать механику
                if enforcing and humanoid.WalkSpeed ~= WALK_SPEED then
                        fights[#fights + 1] = now
                end

                while fights[1] and now - fights[1] > 3 do
                        table.remove(fights, 1)
                end

                if #fights >= 8 then
                        fights = {}
                        pausedUntil = now + 20
                        enforcing = false
                        showToast("Игра сама возвращает скорость. Форсаж 20 выключен на 20 с, чтобы не сломать игру", Color3.fromRGB(235, 120, 120))
                end

                if now < pausedUntil then
                        return
                end

                if not CL.walkFast then
                        restoreSpeed(humanoid)
                        return
                end

                if not Safe.canDrive(humanoid, root) then
                        restoreSpeed(humanoid)
                        return
                end

                local speed = humanoid.WalkSpeed

                if speed < WALK_SPEED then
                        gameSpeed = speed
                        humanoid.WalkSpeed = WALK_SPEED
                        enforcing = true
                elseif speed > WALK_SPEED then
                        gameSpeed = speed
                        enforcing = false
                end
        end

        track(RunService.Heartbeat:Connect(function(dt)
                pcall(walkStep, dt)
        end))
end

do
        local unsunk = {}
        local cameraInput = nil
        local lastHeal = 0

        local function getCameraInput()
                if cameraInput ~= nil then
                        return cameraInput or nil
                end

                local ok, module = pcall(function()
                        local scripts = player:FindFirstChild("PlayerScripts")
                        local playerModule = scripts and scripts:FindFirstChild("PlayerModule")
                        local cameraModule = playerModule and playerModule:FindFirstChild("CameraModule")
                        local input = cameraModule and cameraModule:FindFirstChild("CameraInput")

                        return input and require(input)
                end)

                if ok and type(module) == "table" and type(module.setInputEnabled) == "function" then
                        cameraInput = module
                else
                        cameraInput = false
                end

                return cameraInput or nil
        end

        local function healCameraInput()
                if not CL.camFix or not UserInputService.TouchEnabled then
                        return
                end

                local input = getCameraInput()

                if not input or os.clock() - lastHeal < 0.08 then
                        return
                end

                lastHeal = os.clock()

                pcall(input.setInputEnabled, false)
                pcall(input.setInputEnabled, true)

                if type(input.getInputEnabled) == "function" then
                        local okState, state = pcall(input.getInputEnabled)

                        if okState and state == false then
                                pcall(input.setInputEnabled, true)
                        end
                end
        end

        track(UserInputService.InputBegan:Connect(function(input, processed)
                if input.UserInputType == Enum.UserInputType.Touch and not processed then
                        local first = next(unsunk) == nil
                        unsunk[input] = true

                        if first then
                                -- первый палец на мире: сбрасываем «призрачные» касания камеры, чтобы не было зума вместо поворота
                                task.defer(healCameraInput)
                        end
                end
        end))

        track(UserInputService.InputEnded:Connect(function(input)
                if unsunk[input] then
                        unsunk[input] = nil

                        if next(unsunk) == nil then
                                task.defer(healCameraInput)

                                task.delay(0.3, function()
                                        if next(unsunk) == nil then
                                                healCameraInput()
                                        end
                                end)
                        end
                end
        end))

        local idleFor = 0

        track(RunService.Heartbeat:Connect(function(dt)
                for input in pairs(unsunk) do
                        if not isLive(input) then
                                unsunk[input] = nil
                        end
                end

                -- на мир не нажато ни одним пальцем: можно безопасно сбросить застрявшие касания камеры
                if next(unsunk) == nil then
                        idleFor = idleFor + dt

                        if idleFor >= 2.5 then
                                idleFor = 0
                                healCameraInput()
                        end
                else
                        idleFor = 0
                end
        end))

        local function healWhenIdle()
                task.delay(0.3, function()
                        if next(unsunk) == nil then
                                healCameraInput()
                        end
                end)
        end

        track(GuiService.MenuClosed:Connect(healWhenIdle))
        track(GuiService.MenuOpened:Connect(healWhenIdle))
        track(UserInputService.WindowFocused:Connect(healWhenIdle))
end

makeDraggable(stickRing, stickRing, {
        canStart = function(input)
                return editMode and not coveredByUi(input)
        end,

        onDragged = function()
                stickMoved = true
        end,
})

makeDraggable(jumpButton, jumpButton, {
        canStart = function(input)
                return editMode and not coveredByUi(input)
        end,

        onDragged = function()
                jumpMoved = true
        end,
})

makeDraggable(shiftButton, shiftButton, {
        canStart = function(input)
                return editMode and not coveredByUi(input)
        end,

        onDragged = function()
                shiftMoved = true
        end,

        onTap = function()
                if editMode then
                        bump(shiftScale)
                        setShiftLock(not shiftLockOn)
                end
        end,
})

makeDraggable(camButton, camButton, {
        canStart = function(input)
                return editMode and not coveredByUi(input)
        end,

        onDragged = function()
                camMoved = true
        end,

        onTap = function()
                if editMode then
                        bump(camScale)
                        toggleLock()
                end
        end,
})

bindPress(shiftButton, function()
        bump(shiftScale)
        setShiftLock(not shiftLockOn)
end)

bindPress(camButton, function()
        bump(camScale)
        toggleLock()
end)

local gameEdit = {
        active = false,
        selected = nil,
        onSelect = nil,
}

do
        local MIN_SIDE = 14
        local saved = {}
        local base = setmetatable({}, {__mode = "k"})
        local handles = {}
        local dragInput = nil
        local dragButton = nil
        local startPointer = Vector2.zero
        local startDx = 0
        local startDy = 0
        local moved = false
        local scanTimer = 0

        local layer = Instance.new("Frame")
        layer.Name = "GameButtonEditLayer"
        layer.Size = UDim2.fromScale(1, 1)
        layer.BackgroundTransparency = 1
        layer.BorderSizePixel = 0
        layer.ZIndex = 0
        layer.Visible = false
        layer.Parent = gui

        local function keyOf(button)
                return button:GetFullName()
        end

        local function isManaged(button)
                local parent = button.Parent
                return parent ~= nil and parent:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
        end

        local function isShown(object)
                local current = object

                while current and current ~= playerGui do
                        if current:IsA("GuiObject") and not current.Visible then
                                return false
                        end

                        if current:IsA("LayerCollector") and not current.Enabled then
                                return false
                        end

                        current = current.Parent
                end

                return current == playerGui
        end

        local function applyState(button)
                if base[button] == nil then
                        base[button] = button.Position
                end

                local state = saved[keyOf(button)]

                if not state then
                        return
                end

                if not isManaged(button) then
                        button.Position = base[button] + UDim2.fromOffset(state.dx, state.dy)
                end

                local ui = button:FindFirstChild("MainPanelScale")

                if state.scale ~= 1 then
                        if not ui then
                                ui = Instance.new("UIScale")
                                ui.Name = "MainPanelScale"
                                ui.Parent = button
                        end

                        ui.Scale = state.scale
                elseif ui then
                        ui:Destroy()
                end
        end

        local function chooseButton(button)
                gameEdit.selected = button

                for other, handle in pairs(handles) do
                        local stroke = handle:FindFirstChildOfClass("UIStroke")

                        if stroke then
                                stroke.Thickness = other == button and 4 or 1.5
                                stroke.Color = other == button and K.CREAM or K.GOLD
                        end
                end

                local state = saved[keyOf(button)]

                if gameEdit.onSelect then
                        gameEdit.onSelect(math.floor((state and state.scale or 1) * 100 + 0.5))
                end

                showToast("Выбрана кнопка: " .. button.Name, K.GOLD)
        end

        local function makeHandle(button)
                local handle = Instance.new("TextButton")
                handle.Name = "GameButtonHandle"
                handle.Text = ""
                handle.AutoButtonColor = false
                handle.Active = true
                handle.BackgroundColor3 = K.GOLD
                handle.BackgroundTransparency = 0.82
                handle.BorderSizePixel = 0
                handle.ZIndex = 1
                handle.Parent = layer

                local stroke = Instance.new("UIStroke")
                stroke.Color = button == gameEdit.selected and K.CREAM or K.GOLD
                stroke.Thickness = button == gameEdit.selected and 4 or 1.5
                stroke.Parent = handle

                handle.InputBegan:Connect(function(input)
                        if not gameEdit.active or not isPointer(input) then
                                return
                        end

                        if dragInput and isLive(dragInput) then
                                return
                        end

                        local state = saved[keyOf(button)]

                        dragInput = input
                        dragButton = button
                        startPointer = guiPoint(input)
                        startDx = state and state.dx or 0
                        startDy = state and state.dy or 0
                        moved = false

                        chooseButton(button)
                end)

                handles[button] = handle
        end

        track(UserInputService.InputChanged:Connect(function(input)
                if not dragInput or not isSameDrag(input, dragInput) then
                        return
                end

                local button = dragButton

                if not button or not button.Parent then
                        return
                end

                local delta = guiPoint(input) - startPointer

                if not moved and delta.Magnitude >= K.DRAG_THRESHOLD then
                        moved = true

                        if isManaged(button) then
                                showToast("Эту кнопку двигать нельзя, только менять размер", Color3.fromRGB(235, 120, 120))
                        end
                end

                if moved and not isManaged(button) then
                        local key = keyOf(button)
                        local state = saved[key]

                        if not state then
                                state = {dx = 0, dy = 0, scale = 1}
                                saved[key] = state
                        end

                        state.dx = startDx + delta.X
                        state.dy = startDy + delta.Y
                        applyState(button)
                end
        end))

        track(UserInputService.InputEnded:Connect(function(input)
                if dragInput and endsDrag(input, dragInput) then
                        local wasMoved = moved

                        dragInput = nil
                        dragButton = nil

                        if wasMoved then
                                task.defer(function()
                                        local okBack, backCount = pcall(gameEdit.restoreOffscreen)

                                        if okBack and type(backCount) == "number" and backCount > 0 then
                                                showToast("Кнопка игры ушла за экран и вернулась", K.GOLD)
                                        end
                                end)
                        end
                end
        end))

        track(RunService.RenderStepped:Connect(function(dt)
                if not gameEdit.active then
                        return
                end

                scanTimer = scanTimer - dt

                if scanTimer <= 0 then
                        scanTimer = 0.5

                        local view = gui.AbsoluteSize

                        for _, object in ipairs(playerGui:GetDescendants()) do
                                if object:IsA("GuiButton")
                                        and not handles[object]
                                        and not object:IsDescendantOf(gui)
                                        and isShown(object)
                                then
                                        local size = object.AbsoluteSize

                                        if size.X >= MIN_SIDE
                                                and size.Y >= MIN_SIDE
                                                and size.X * size.Y < view.X * view.Y * 0.4
                                        then
                                                if base[object] == nil then
                                                        base[object] = object.Position
                                                end

                                                makeHandle(object)
                                        end
                                end
                        end
                end

                local origin = gui.AbsolutePosition

                for button, handle in pairs(handles) do
                        if not button.Parent or not isShown(button) then
                                handle:Destroy()
                                handles[button] = nil

                                if gameEdit.selected == button then
                                        gameEdit.selected = nil
                                end
                        else
                                local position = button.AbsolutePosition
                                local size = button.AbsoluteSize

                                handle.Position = UDim2.fromOffset(position.X - origin.X, position.Y - origin.Y)
                                handle.Size = UDim2.fromOffset(size.X, size.Y)
                        end
                end
        end))

        track(playerGui.DescendantAdded:Connect(function(object)
                if next(saved) ~= nil and object:IsA("GuiButton") then
                        task.defer(function()
                                if object.Parent and saved[keyOf(object)] then
                                        applyState(object)
                                end
                        end)
                end
        end))

        function gameEdit.setActive(on)
                gameEdit.active = on
                layer.Visible = on
                gui.DisplayOrder = on and 10000 or 50

                if on then
                        scanTimer = 0
                else
                        dragInput = nil
                        dragButton = nil
                        gameEdit.selected = nil

                        for button, handle in pairs(handles) do
                                handle:Destroy()
                                handles[button] = nil
                        end
                end
        end

        function gameEdit.setScale(percent)
                local button = gameEdit.selected
                local scale = percent / 100

                if not button or not button.Parent then
                        if math.abs(scale - 1) > 0.005 then
                                showToast("Сначала включи «Двигать кнопки» и нажми на кнопку игры", Color3.fromRGB(235, 120, 120))
                        end

                        return
                end

                local key = keyOf(button)
                local state = saved[key]

                if not state then
                        if math.abs(scale - 1) < 0.005 then
                                return
                        end

                        state = {dx = 0, dy = 0, scale = 1}
                        saved[key] = state
                end

                state.scale = scale
                applyState(button)
        end

        function gameEdit.resetAll()
                for _, object in ipairs(playerGui:GetDescendants()) do
                        if object:IsA("GuiButton") and saved[keyOf(object)] then
                                if base[object] then
                                        object.Position = base[object]
                                end

                                local ui = object:FindFirstChild("MainPanelScale")

                                if ui then
                                        ui:Destroy()
                                end
                        end
                end

                table.clear(saved)

                if gameEdit.selected and gameEdit.onSelect then
                        gameEdit.onSelect(100)
                end
        end

        function gameEdit.restoreOffscreen()
                local view = gui.AbsoluteSize
                local count = 0

                if view.X <= 0 or view.Y <= 0 then
                        return 0
                end

                for _, object in ipairs(playerGui:GetDescendants()) do
                        if object:IsA("GuiButton") and not object:IsDescendantOf(gui) then
                                local state = saved[keyOf(object)]

                                if state and (state.dx ~= 0 or state.dy ~= 0) then
                                        local position = object.AbsolutePosition
                                        local size = object.AbsoluteSize
                                        local visibleW = math.min(position.X + size.X, view.X) - math.max(position.X, 0)
                                        local visibleH = math.min(position.Y + size.Y, view.Y) - math.max(position.Y, 0)

                                        if visibleW <= 0 or visibleH <= 0 or (visibleW * visibleH) < (size.X * size.Y) * 0.3 then
                                                state.dx = 0
                                                state.dy = 0
                                                applyState(object)
                                                count = count + 1
                                        end
                                end
                        end
                end

                return count
        end

        function gameEdit.exportState()
                local out = {}

                for key, state in pairs(saved) do
                        out[key] = {dx = state.dx, dy = state.dy, scale = state.scale}
                end

                return out
        end

        function gameEdit.importState(data)
                if type(data) ~= "table" then
                        return
                end

                gameEdit.resetAll()

                for key, state in pairs(data) do
                        if type(key) == "string" and type(state) == "table" then
                                saved[key] = {
                                        dx = tonumber(state.dx) or 0,
                                        dy = tonumber(state.dy) or 0,
                                        scale = tonumber(state.scale) or 1,
                                }
                        end
                end

                for _, object in ipairs(playerGui:GetDescendants()) do
                        if object:IsA("GuiButton")
                                and not object:IsDescendantOf(gui)
                                and saved[keyOf(object)]
                        then
                                applyState(object)
                        end
                end
        end
end

local function setEditMode(on)
        editMode = on
        stickOutline.Visible = on
        jumpOutline.Visible = on
        shiftOutline.Visible = on
        camOutline.Visible = on
        stickZone.Visible = not on
        gameEdit.setActive(on)

        if on then
                releaseStick(true)
                releaseJump()
        else
                cancelDragGoals()
        end
end

local function refreshEditMode()
        setEditMode(menuAlive and isOpen and CL.moveButtons)
end

task.delay(3, function()
        if not gui.Parent then
                return
        end

        if not stickRing.IsLoaded then
                stickRing.BackgroundColor3 = Color3.new(1, 1, 1)
                stickRing.BackgroundTransparency = 0.7
                addCorner(stickRing, UDim.new(1, 0))

                stickKnob.BackgroundColor3 = Color3.new(1, 1, 1)
                stickKnob.BackgroundTransparency = 0.35
                addCorner(stickKnob, UDim.new(1, 0))
        end

        if not jumpButton.IsLoaded then
                jumpButton.BackgroundColor3 = Color3.new(1, 1, 1)
                jumpButton.BackgroundTransparency = 0.7
                addCorner(jumpButton, UDim.new(1, 0))

                local arrow = Instance.new("TextLabel")
                arrow.Name = "FallbackArrow"
                arrow.AnchorPoint = Vector2.new(0.5, 0.5)
                arrow.Position = UDim2.fromScale(0.5, 0.55)
                arrow.Size = UDim2.fromScale(0.5, 0.5)
                arrow.BackgroundTransparency = 1
                arrow.Text = "^"
                arrow.TextScaled = true
                arrow.TextColor3 = Color3.new(1, 1, 1)
                arrow.Font = Enum.Font.SourceSansBold
                arrow.ZIndex = 2
                arrow.Parent = jumpButton
        end
end)

if UserInputService.TouchEnabled then
        savedTouchControls = GuiService.TouchControlsEnabled

        pcall(function()
                GuiService.TouchControlsEnabled = false
        end)

        track(GuiService:GetPropertyChangedSignal("TouchControlsEnabled"):Connect(function()
                if savedTouchControls ~= nil and GuiService.TouchControlsEnabled then
                        pcall(function()
                                GuiService.TouchControlsEnabled = false
                        end)
                end
        end))

        task.spawn(function()
                local ok, result = pcall(function()
                        local playerScripts = player:WaitForChild("PlayerScripts", 15)
                        local playerModule = playerScripts and playerScripts:WaitForChild("PlayerModule", 15)
                        return playerModule and require(playerModule):GetControls()
                end)

                if ok and result and gui.Parent then
                        local disabled, err = pcall(function()
                                result:Disable()
                        end)

                        if disabled then
                                controls = result
                                controlsDisabled = true

                                -- игры читают движение через стандартное управление: отдаём им наш стик и прыжок
                                pcall(function()
                                        result.GetMoveVector = function()
                                                return moveVector
                                        end

                                        if type(result.GetIsJumping) == "function" then
                                                result.GetIsJumping = function()
                                                        return jumpHeld
                                                end
                                        end
                                end)
                        else
                                warn("[MainPanel] Не удалось отключить стандартное управление: " .. tostring(err))
                        end
                elseif not ok then
                        warn("[MainPanel] Не удалось получить стандартное управление: " .. tostring(result))
                end
        end)
end

task.spawn(function()
        while gui.Parent do
                task.wait(1)

                if savedTouchControls ~= nil and GuiService.TouchControlsEnabled then
                        pcall(function()
                                GuiService.TouchControlsEnabled = false
                        end)
                end

                if controls and controlsDisabled then
                        pcall(function()
                                if controls.controlsEnabled then
                                        controls:Disable()
                                end
                        end)
                end
        end
end)

local activeTweens = {}

local function cancelTweens()
        for _, tween in ipairs(activeTweens) do
                tween:Cancel()
        end

        table.clear(activeTweens)
end

local function setOpen(open)
        if open == isOpen then
                return
        end

        isOpen = open
        refreshEditMode()
        cancelTweens()

        local info = open and K.OPEN_INFO or K.CLOSE_INFO

        local scaleTween = TweenService:Create(
                panelScale,
                info,
                {Scale = open and (CL.panelSize / 100) or K.CLOSED_SCALE}
        )

        local fadeTween = TweenService:Create(
                panel,
                info,
                {GroupTransparency = open and 0 or 1}
        )

        activeTweens = {scaleTween, fadeTween}

        if open then
                panel.Visible = true
                applyCenter(panel, getCenter(panel))
        else
                fadeTween.Completed:Once(function(state)
                        if state == Enum.PlaybackState.Completed and not isOpen then
                                panel.Visible = false
                        end
                end)
        end

        scaleTween:Play()
        fadeTween:Play()
end

local function pressEffect(uiScale)
        return function(pressed)
                if not uiScale.Parent then
                        return
                end

                TweenService:Create(
                        uiScale,
                        K.PRESS_INFO,
                        {Scale = pressed and 0.9 or 1}
                ):Play()
        end
end

local function destroyMenu()
        if not menuAlive then
                return
        end

        menuAlive = false
        isOpen = false
        sliderOwner = nil

        setEditMode(false)
        cancelTweens()

        for index = #draggers, 1, -1 do
                local target = draggers[index].target

                if target == panel or target == openButton then
                        table.remove(draggers, index)
                end
        end

        panel:Destroy()
        openButton:Destroy()
end

makeDraggable(openButton, openButton, {
        onTap = function()
                setOpen(not isOpen)
        end,

        onPress = pressEffect(openScale),
})

makeDraggable(dragLayer, panel, {
        canStart = function(input)
                if sliderBusy() then
                        return false
                end

                local point = guiPoint(input)

                if pointInside(openButton, point) then
                        return false
                end

                for _, object in ipairs(interactive) do
                        if pointInside(object, point) then
                                return false
                        end
                end

                return true
        end,
})

do
        local press = pressEffect(closeScale)

        track(closeButton.MouseButton1Down:Connect(function()
                press(true)
        end))

        track(closeButton.MouseButton1Up:Connect(function()
                press(false)
        end))

        track(closeButton.MouseLeave:Connect(function()
                press(false)
        end))

        track(closeButton.Activated:Connect(function()
                if K.X_DELETES_MENU then
                        destroyMenu()
                else
                        setOpen(false)
                end
        end))
end

local function makeSlider(parent, order, titleText, minValue, maxValue, startValue, onChanged, options)
        options = options or {}

        local step = options.step or 1
        local format = options.format or function(value)
                return tostring(value) .. "%"
        end

        local box = Instance.new("Frame")
        box.Name = titleText .. "Slider"
        box.LayoutOrder = order
        box.Size = options.size or UDim2.new(0.5, -5, 1, 0)
        box.BackgroundColor3 = K.DARK
        box.BackgroundTransparency = 0.3
        box.BorderSizePixel = 0
        box.Parent = parent

        addCorner(box, UDim.new(0, 10))
        addStroke(box, K.GOLD, 2, 0.55)

        local boxPadding = Instance.new("UIPadding")
        boxPadding.PaddingTop = UDim.new(0, 8)
        boxPadding.PaddingBottom = UDim.new(0, 8)
        boxPadding.PaddingLeft = UDim.new(0, 10)
        boxPadding.PaddingRight = UDim.new(0, 10)
        boxPadding.Parent = box

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.62, 0, 0, 22)
        label.BackgroundTransparency = 1
        label.Text = titleText
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextColor3 = K.CREAM
        label.Font = Enum.Font.SourceSansSemibold
        label.TextSize = 19
        label.Parent = box

        local valueLabel = Instance.new("TextLabel")
        valueLabel.AnchorPoint = Vector2.new(1, 0)
        valueLabel.Position = UDim2.fromScale(1, 0)
        valueLabel.Size = UDim2.new(0.38, 0, 0, 22)
        valueLabel.BackgroundTransparency = 1
        valueLabel.TextXAlignment = Enum.TextXAlignment.Right
        valueLabel.TextColor3 = K.GOLD
        valueLabel.Font = Enum.Font.SourceSansBold
        valueLabel.TextSize = 20
        valueLabel.Parent = box

        local hit = Instance.new("TextButton")
        hit.Name = "Hit"
        hit.Position = UDim2.fromOffset(0, 32)
        hit.Size = UDim2.new(1, 0, 0, 30)
        hit.BackgroundTransparency = 1
        hit.Text = ""
        hit.AutoButtonColor = false
        hit.Parent = box
        table.insert(interactive, hit)

        local trackBar = Instance.new("Frame")
        trackBar.AnchorPoint = Vector2.new(0, 0.5)
        trackBar.Position = UDim2.new(0, 12, 0.5, 0)
        trackBar.Size = UDim2.new(1, -24, 0, 8)
        trackBar.BackgroundColor3 = Color3.fromRGB(125, 90, 145)
        trackBar.BorderSizePixel = 0
        trackBar.Parent = hit

        addCorner(trackBar, UDim.new(1, 0))
        addStroke(trackBar, K.DARK, 1, 0.3)

        local fill = Instance.new("Frame")
        fill.Size = UDim2.fromScale(0, 1)
        fill.BackgroundColor3 = K.GOLD
        fill.BorderSizePixel = 0
        fill.Parent = trackBar
        addCorner(fill, UDim.new(1, 0))

        local knob = Instance.new("Frame")
        knob.AnchorPoint = Vector2.new(0.5, 0.5)
        knob.Size = UDim2.fromOffset(24, 24)
        knob.Position = UDim2.fromScale(0, 0.5)
        knob.BackgroundColor3 = K.CREAM
        knob.BorderSizePixel = 0
        knob.Parent = trackBar

        addCorner(knob, UDim.new(1, 0))
        addStroke(knob, K.GOLD, 3)

        local knobScale = Instance.new("UIScale")
        knobScale.Parent = knob

        local current = nil

        local function setValue(value)
                value = math.clamp(math.floor(value / step + 0.5) * step, minValue, maxValue)
                value = math.floor(value * 1000 + 0.5) / 1000

                local fraction = (value - minValue) / (maxValue - minValue)

                knob.Position = UDim2.fromScale(fraction, 0.5)
                fill.Size = UDim2.fromScale(fraction, 1)
                valueLabel.Text = format(value)

                if value ~= current then
                        current = value
                        onChanged(value)
                end
        end

        local activeInput = nil

        local function setFromX(x)
                local width = trackBar.AbsoluteSize.X

                if width <= 0 then
                        return
                end

                local fraction = math.clamp(
                        (x - trackBar.AbsolutePosition.X) / width,
                        0,
                        1
                )

                setValue(minValue + (maxValue - minValue) * fraction)
        end

        local function finish()
                if sliderOwner == activeInput then
                        sliderOwner = nil
                end

                activeInput = nil
                scroller.ScrollingEnabled = true

                TweenService:Create(
                        knobScale,
                        K.PRESS_INFO,
                        {Scale = 1}
                ):Play()

                if options.onRelease then
                        options.onRelease()
                end
        end

        track(hit.InputBegan:Connect(function(input)
                if activeInput and not isLive(activeInput) then
                        finish()
                end

                if activeInput or sliderBusy() or not isPointer(input) then
                        return
                end

                activeInput = input
                sliderOwner = input
                scroller.ScrollingEnabled = false

                TweenService:Create(
                        knobScale,
                        K.PRESS_INFO,
                        {Scale = 1.25}
                ):Play()

                setFromX(input.Position.X)
        end))

        track(UserInputService.InputChanged:Connect(function(input)
                if activeInput and isSameDrag(input, activeInput) then
                        setFromX(input.Position.X)
                end
        end))

        track(UserInputService.InputEnded:Connect(function(input)
                if activeInput and endsDrag(input, activeInput) then
                        finish()
                end
        end))

        setValue(startValue)

        return setValue
end

local setStickPercent = makeSlider(
        sliderRow,
        1,
        "Джойстик",
        K.SCALE_MIN,
        K.SCALE_MAX,
        K.SCALE_DEFAULT,
        function(value)
                stickPercent = value
                refreshControls()
        end
)

local setJumpPercent = makeSlider(
        sliderRow,
        2,
        "Прыжок",
        K.SCALE_MIN,
        K.SCALE_MAX,
        K.SCALE_DEFAULT,
        function(value)
                jumpPercent = value
                refreshControls()
        end
)

local setCamPercent = makeSlider(
        sliderRow2,
        1,
        "CAM",
        K.SCALE_MIN,
        K.BTN_SCALE_MAX,
        K.SCALE_DEFAULT,
        function(value)
                camPercent = value
                refreshControls()
        end
)

local setShiftPercent = makeSlider(
        sliderRow2,
        2,
        "SHIFT",
        K.SCALE_MIN,
        K.BTN_SCALE_MAX,
        K.SCALE_DEFAULT,
        function(value)
                shiftPercent = value
                refreshControls()
        end
)

local sliderRow3 = Instance.new("Frame")
sliderRow3.Name = "SliderRow3"
sliderRow3.LayoutOrder = 3
sliderRow3.Size = UDim2.new(1, 0, 0, 76)
sliderRow3.BackgroundTransparency = 1
sliderRow3.Parent = scroller

local setGamePercent = makeSlider(
        sliderRow3,
        1,
        "Кнопка игры",
        K.SCALE_MIN,
        250,
        K.SCALE_DEFAULT,
        function(value)
                gameEdit.setScale(value)
        end,
        {size = UDim2.new(1, 0, 1, 0)}
)

gameEdit.onSelect = function(percent)
        setGamePercent(percent)
end

local resetCamLockPanel
local syncCamLockPanel

do
        local rowOrder = 10
        local rowResetters = {}
        local rowSyncers = {}
        local sliders = {setters = {}, info = {}}
        local tools = {}

        local function nextOrder()
                rowOrder = rowOrder + 1
                return rowOrder
        end

        local function addHeader(text)
                local label = Instance.new("TextLabel")
                label.Name = "Header" .. text
                label.LayoutOrder = nextOrder()
                label.Size = UDim2.new(1, 0, 0, 30)
                label.BackgroundTransparency = 1
                label.Text = text
                label.TextXAlignment = Enum.TextXAlignment.Left
                label.TextColor3 = K.GOLD
                label.Font = Enum.Font.SourceSansBold
                label.TextSize = 21
                label.Parent = scroller
        end

        local function styleRow(row)
                row.BackgroundColor3 = K.DARK
                row.BackgroundTransparency = 0.3
                row.BorderSizePixel = 0
                addCorner(row, UDim.new(0, 10))
                addBorder(row, K.GOLD, 2, 0.55)
        end

        local function addToggle(text, key, onChange)
                local row = Instance.new("TextButton")
                row.Name = key
                row.LayoutOrder = nextOrder()
                row.Size = UDim2.new(1, 0, 0, 44)
                row.AutoButtonColor = false
                row.Text = ""
                row.Parent = scroller
                styleRow(row)

                local label = Instance.new("TextLabel")
                label.Position = UDim2.fromOffset(12, 0)
                label.Size = UDim2.new(1, -84, 1, 0)
                label.BackgroundTransparency = 1
                label.Text = text
                label.TextXAlignment = Enum.TextXAlignment.Left
                label.TextColor3 = K.CREAM
                label.Font = Enum.Font.SourceSansSemibold
                label.TextSize = 19
                label.Parent = row

                local pill = Instance.new("Frame")
                pill.AnchorPoint = Vector2.new(1, 0.5)
                pill.Position = UDim2.new(1, -12, 0.5, 0)
                pill.Size = UDim2.fromOffset(50, 26)
                pill.BorderSizePixel = 0
                pill.Parent = row
                addCorner(pill, UDim.new(1, 0))

                local dot = Instance.new("Frame")
                dot.AnchorPoint = Vector2.new(0.5, 0.5)
                dot.Size = UDim2.fromOffset(20, 20)
                dot.BackgroundColor3 = K.CREAM
                dot.BorderSizePixel = 0
                dot.Parent = pill
                addCorner(dot, UDim.new(1, 0))

                local function refresh()
                        local on = CL[key]

                        pill.BackgroundColor3 = on and K.GOLD or Color3.fromRGB(125, 90, 145)
                        dot.Position = on and UDim2.new(1, -13, 0.5, 0) or UDim2.new(0, 13, 0.5, 0)
                end

                refresh()
                table.insert(rowResetters, refresh)
                table.insert(rowSyncers, refresh)

                track(row.Activated:Connect(function()
                        CL[key] = not CL[key]
                        refresh()

                        if onChange then
                                onChange()
                        end
                end))
        end

        local function addChoice(text, key, names, onChange)
                local row = Instance.new("TextButton")
                row.Name = key
                row.LayoutOrder = nextOrder()
                row.Size = UDim2.new(1, 0, 0, 54)
                row.AutoButtonColor = false
                row.Text = ""
                row.Parent = scroller
                styleRow(row)

                local label = Instance.new("TextLabel")
                label.Position = UDim2.fromOffset(12, 5)
                label.Size = UDim2.new(1, -70, 0, 20)
                label.BackgroundTransparency = 1
                label.Text = text
                label.TextXAlignment = Enum.TextXAlignment.Left
                label.TextColor3 = Color3.fromRGB(200, 185, 160)
                label.Font = Enum.Font.SourceSans
                label.TextSize = 17
                label.Parent = row

                local value = Instance.new("TextLabel")
                value.Position = UDim2.fromOffset(12, 25)
                value.Size = UDim2.new(1, -70, 0, 24)
                value.BackgroundTransparency = 1
                value.TextXAlignment = Enum.TextXAlignment.Left
                value.TextColor3 = K.GOLD
                value.Font = Enum.Font.SourceSansBold
                value.TextSize = 21
                value.Parent = row

                local tapHint = Instance.new("TextLabel")
                tapHint.AnchorPoint = Vector2.new(1, 0.5)
                tapHint.Position = UDim2.new(1, -12, 0.5, 0)
                tapHint.Size = UDim2.fromOffset(50, 20)
                tapHint.BackgroundTransparency = 1
                tapHint.Text = "тап"
                tapHint.TextXAlignment = Enum.TextXAlignment.Right
                tapHint.TextColor3 = Color3.fromRGB(150, 130, 100)
                tapHint.Font = Enum.Font.SourceSans
                tapHint.TextSize = 17
                tapHint.Parent = row

                local function refresh()
                        value.Text = names[CL[key]]
                end

                refresh()
                table.insert(rowResetters, refresh)
                table.insert(rowSyncers, refresh)

                track(row.Activated:Connect(function()
                        CL[key] = CL[key] % #names + 1
                        refresh()

                        if onChange then
                                onChange()
                        end
                end))
        end

        local function addCamSlider(text, key, minValue, maxValue, step, format, onRelease)
                local setter = makeSlider(
                        scroller,
                        nextOrder(),
                        text,
                        minValue,
                        maxValue,
                        CL[key],
                        function(value)
                                CL[key] = value
                        end,
                        {
                                step = step,
                                format = format,
                                onRelease = onRelease,
                                size = UDim2.new(1, 0, 0, 76),
                        }
                )

                sliders.setters[key] = setter
                sliders.info[key] = {text = text, format = format or tostring}

                table.insert(rowResetters, function()
                        setter(K.CL_DEFAULTS[key])
                end)

                table.insert(rowSyncers, function()
                        setter(CL[key])
                end)
        end

        local function applyPanelSize()
                if not menuAlive or not isOpen then
                        return
                end

                panelScale.Scale = CL.panelSize / 100
                applyCenter(panel, getCenter(panel))
        end

        local function plain(value)
                return tostring(value)
        end

        function resetCamLockPanel()
                for key, value in pairs(K.CL_DEFAULTS) do
                        CL[key] = value
                end

                for _, refresh in ipairs(rowResetters) do
                        refresh()
                end

                applyPanelSize()
                                refreshCamButtons()
                refreshEditMode()
        end

        function syncCamLockPanel()
                for _, sync in ipairs(rowSyncers) do
                        sync()
                end

                applyPanelSize()
                refreshCamButtons()
                refreshEditMode()
        end

        local function fmt2(value)
                return string.format("%.2f", value)
        end

        local function addActionRow(title, details, onTap)
                local row = Instance.new("TextButton")
                row.Name = "Action" .. title
                row.LayoutOrder = nextOrder()
                row.Size = UDim2.new(1, 0, 0, 64)
                row.AutoButtonColor = false
                row.Text = ""
                row.Parent = scroller
                styleRow(row)

                local label = Instance.new("TextLabel")
                label.Position = UDim2.fromOffset(12, 4)
                label.Size = UDim2.new(1, -70, 0, 22)
                label.BackgroundTransparency = 1
                label.Text = title
                label.TextXAlignment = Enum.TextXAlignment.Left
                label.TextColor3 = K.GOLD
                label.Font = Enum.Font.SourceSansBold
                label.TextSize = 21
                label.Parent = row

                local sub = Instance.new("TextLabel")
                sub.Position = UDim2.fromOffset(12, 27)
                sub.Size = UDim2.new(1, -70, 0, 34)
                sub.BackgroundTransparency = 1
                sub.Text = details
                sub.TextWrapped = true
                sub.TextXAlignment = Enum.TextXAlignment.Left
                sub.TextYAlignment = Enum.TextYAlignment.Top
                sub.TextColor3 = K.CREAM
                sub.Font = Enum.Font.SourceSans
                sub.TextSize = 17
                sub.Parent = row

                local tap = Instance.new("TextLabel")
                tap.AnchorPoint = Vector2.new(1, 0.5)
                tap.Position = UDim2.new(1, -12, 0.5, 0)
                tap.Size = UDim2.fromOffset(50, 20)
                tap.BackgroundTransparency = 1
                tap.Text = "тап"
                tap.TextXAlignment = Enum.TextXAlignment.Right
                tap.TextColor3 = Color3.fromRGB(150, 130, 100)
                tap.Font = Enum.Font.SourceSans
                tap.TextSize = 17
                tap.Parent = row

                local token = 0

                track(row.Activated:Connect(function()
                        onTap()

                        token = token + 1
                        local mine = token

                        tap.Text = "ОК"
                        tap.TextColor3 = K.GOLD

                        task.delay(1, function()
                                if mine == token and tap.Parent then
                                        tap.Text = "тап"
                                        tap.TextColor3 = Color3.fromRGB(150, 130, 100)
                                end
                        end)
                end))
        end

        function tools.describe(config)
                local keys = {}

                for key in pairs(config.values) do
                        table.insert(keys, key)
                end

                table.sort(keys)

                local parts = {}

                for _, key in ipairs(keys) do
                        local info = sliders.info[key]
                        local value = config.values[key]

                        if info then
                                table.insert(parts, info.text .. ": " .. info.format(value))
                        else
                                table.insert(parts, key .. ": " .. tostring(value))
                        end
                end

                return table.concat(parts, "  ·  ")
        end

        function tools.apply(config)
                for key, value in pairs(config.values) do
                        local setter = sliders.setters[key]

                        if setter then
                                setter(value)
                        else
                                CL[key] = value
                        end
                end
        end

        function tools.restore()
                local view = gui.AbsoluteSize
                local count = 0

                local function isOut(target)
                        if view.X <= 0 or view.Y <= 0 then
                                return false
                        end

                        local center = getCenter(target)
                        local half = halfSizeOf(target)
                        local w = math.min(center.X + half.X, view.X) - math.max(center.X - half.X, 0)
                        local h = math.min(center.Y + half.Y, view.Y) - math.max(center.Y - half.Y, 0)

                        if w <= 0 or h <= 0 then
                                return true
                        end

                        return (w * h) < (4 * half.X * half.Y) * 0.3
                end

                if not stickRing.Visible or isOut(stickRing) then
                        stickMoved = false
                        applyCenter(stickRing, defaultCenter("stick"))
                        count = count + 1
                end

                if not jumpButton.Visible or isOut(jumpButton) then
                        jumpMoved = false
                        applyCenter(jumpButton, defaultCenter("jump"))
                        count = count + 1
                end

                if not shiftButton.Visible or isOut(shiftButton) then
                        shiftMoved = false
                        applyCenter(shiftButton, defaultCenter("shift"))
                        count = count + 1
                end

                if camEdge.hidden or isOut(camButton) then
                        camMoved = false
                        applyCenter(camButton, defaultCenter("cam"))
                        count = count + 1
                end

                local okGame, gameCount = pcall(gameEdit.restoreOffscreen)

                if okGame and type(gameCount) == "number" then
                        count = count + gameCount
                end

                if count > 0 then
                        showToast("Вернул кнопок: " .. count, K.GOLD)
                else
                        showToast("Все кнопки на экране", K.GOLD)
                end
        end

        addHeader("УПРАВЛЕНИЕ")
        addToggle("Двигать кнопки пальцем (пока меню открыто)", "moveButtons", refreshEditMode)
        addToggle("Левая сторона экрана не крутит камеру", "leftNoCam")
        addToggle("Скорость ходьбы 20 (на суше, плавание не трогаем)", "walkFast")
        addToggle("Лечить зум справа при 3-4 пальцах", "camFix")
        addToggle("Вернуть зум камеры после стен", "zoomKeep")
        addToggle("Кнопка ушла за экран на 70% — вернуть", "autoReturn")
        addCamSlider("Плавность джойстика (против дёрганья)", "stickSmooth", 0, 10, 1, function(value)
                if value <= 0 then
                        return "выкл"
                end

                return tostring(value)
        end)

        addHeader("ШИФТ-ЛОК (кнопка SHIFT)")
        addCamSlider("Шифт: сдвиг вбок", "shiftSide", -3, 3, 0.25, fmt2)

        addHeader("КАМЛОК: ЦЕЛИ")
        addToggle("Игроки", "players")
        addToggle("NPC и мобы", "npcs")
        addToggle("Только чужие команды", "enemiesOnly")
        addToggle("Мобы без Humanoid (кастомные риги) тоже", "rigs")
        addToggle("Брать через стены", "throughWalls")
        addChoice("Кого брать", "mode", MODE_NAMES)
        addChoice("Куда целиться", "aimPart", AIM_NAMES)
        addCamSlider("Дистанция", "maxDist", 30, MAXDIST_INF, 10, function(value)
                if value >= MAXDIST_INF then
                        return "без лимита"
                end
                return tostring(value) .. " ст."
        end)

        addHeader("ESP (подсветка контуром)")
        addToggle("ESP включён", "esp")
        addToggle("ESP: игроки (белый)", "espPlayers")
        addToggle("ESP: NPC (красный)", "espNpcs")
        addCamSlider("ESP: яркость контура", "espOutline", 10, 100, 5, function(value)
                return tostring(value) .. "%"
        end)
        addCamSlider("ESP: заливка (0 = только края)", "espFill", 0, 40, 1, function(value)
                return tostring(value) .. "%"
        end)
        addCamSlider("ESP: дальность", "espDist", 50, 1000, 10, function(value)
                if value >= MAXDIST_INF then
                        return "без лимита"
                end

                return tostring(value) .. " ст."
        end)

        addHeader("КАМЛОК: КАМЕРА")
        addCamSlider("Скорость наводки", "aimSpeed", 6, 40, 1, plain)
        addToggle("Опережение (точнее на бегущей цели)", "aimLead")
        addToggle("Зум пальцами работает во время лока", "zoomFollow")
        addCamSlider("Угол обзора (FOV)", "fov", 50, 110, 1, function(value)
                return tostring(value) .. "°"
        end)
        addCamSlider("Сдвиг камеры вбок", "side", -3, 3, 0.25, fmt2)
        addToggle("Прицел: искать в интерфейсе (авто)", "crossAuto")
        addToggle("Прицел: угадывать, если по имени не нашёл", "crossGuess")
        addToggle("Автоподстройка наводки по реальной камере", "aimTrim")
        addToggle("Показать красную точку, куда я целюсь (проверка прицела)", "crossDot")
        addCamSlider("Прицел игры выше центра (если авто не нашёл)", "crossUp", -20, 45, 1, function(value)
                return tostring(value) .. "%"
        end)
        addCamSlider("Точка на цели выше/ниже", "aimLift", -4, 4, 0.1, function(value)
                return string.format("%.1f", value)
        end)

        addHeader("КАМЛОК: ПРЕДСКАЗАНИЕ")
        addToggle("Предсказание движения цели", "predict")
        addCamSlider("Упреждение", "predictTime", 0, 400, 10, function(value)
                return tostring(value) .. " мс"
        end)
        addCamSlider("Макс. вынос", "predictCap", 1, 30, 1, function(value)
                return tostring(value) .. " ст."
        end)
        addCamSlider("Полное с дистанции", "predictNear", 0, 30, 1, function(value)
                if value <= 0 then
                        return "везде"
                end
                return tostring(value) .. " ст."
        end)
        addToggle("Умное: тормоз и повороты", "predictSmart")

        addHeader("ИНТЕРФЕЙС")
        addToggle("Кнопка CAM на экране", "showButtons", refreshCamButtons)
        addCamSlider("Размер панели", "panelSize", 70, 130, 5, function(value)
                return tostring(value) .. "%"
        end, applyPanelSize)
        addActionRow("Вернуть спрятанные кнопки", "Кнопки, которые ушли за край экрана (свои и кнопки игры), встанут на место", tools.restore)

        addHeader("КОНФИГИ")

        for _, config in ipairs(K.CONFIGS) do
                addActionRow(config.name, tools.describe(config), function()
                        tools.apply(config)
                end)
        end
end

local resetButton = Instance.new("TextButton")
resetButton.Name = "ResetButton"
resetButton.AnchorPoint = Vector2.new(1, 0.5)
resetButton.Position = UDim2.fromScale(1, 0.5)
resetButton.Size = UDim2.fromOffset(120, 34)
resetButton.BackgroundColor3 = K.PURPLE
resetButton.AutoButtonColor = false
resetButton.Text = "СБРОС"
resetButton.TextColor3 = K.CREAM
resetButton.Font = Enum.Font.SourceSansBold
resetButton.TextSize = 20
resetButton.Parent = bottomRow

addCorner(resetButton, UDim.new(0, 10))
addStroke(resetButton, K.GOLD, 2)

table.insert(interactive, resetButton)

local resetScale = Instance.new("UIScale")
resetScale.Parent = resetButton

do
        local press = pressEffect(resetScale)

        track(resetButton.MouseButton1Down:Connect(function()
                press(true)
        end))

        track(resetButton.MouseButton1Up:Connect(function()
                press(false)
        end))

        track(resetButton.MouseLeave:Connect(function()
                press(false)
        end))

        track(resetButton.Activated:Connect(function()
                setStickPercent(K.SCALE_DEFAULT)
                setJumpPercent(K.SCALE_DEFAULT)
                setCamPercent(K.SCALE_DEFAULT)
                setShiftPercent(K.SCALE_DEFAULT)
                gameEdit.resetAll()

                stickMoved = false
                jumpMoved = false
                shiftMoved = false
                camMoved = false

                resetCamLockPanel()

                cancelDragGoals()
                refreshControls()
                placeDefaults(true)
        end))
end

do
        local S = {}
        S.HttpService = game:GetService("HttpService")
        S.SAVE_DIR = "Delta"
        S.SAVE_FILE = "Delta/MainPanel_config.json"
        S.OLD_FILE = "MainPanel_config.json"
        -- Если у экзекутора нет writefile: нажми СОХРАНИТЬ, конфиг скопируется в буфер.
        -- Вставь его сюда между [==[ и ]==] и он будет грузиться при каждом запуске.
        S.EMBEDDED_CONFIG = [==[]==]

function S.envFunction(name)
        local ok, fn = pcall(function()
                return getfenv()[name]
        end)

        if ok and type(fn) == "function" then
                return fn
        end

        return nil
end

function S.centerFraction(target)
        local view = gui.AbsoluteSize

        if view.X <= 0 or view.Y <= 0 then
                return nil
        end

        local center = getCenter(target)

        return {x = center.X / view.X, y = center.Y / view.Y}
end

function S.collectConfig()
        local data = {
                version = 13,
                cl = {},
                scale = {
                        stick = stickPercent,
                        jump = jumpPercent,
                        cam = camPercent,
                        shift = shiftPercent,
                },
                pos = {},
                game = gameEdit.exportState(),
        }

        for key in pairs(K.CL_DEFAULTS) do
                data.cl[key] = CL[key]
        end

        if stickMoved then
                data.pos.stick = S.centerFraction(stickRing)
        end

        if jumpMoved then
                data.pos.jump = S.centerFraction(jumpButton)
        end

        if shiftMoved then
                data.pos.shift = S.centerFraction(shiftButton)
        end

        if camMoved then
                data.pos.cam = S.centerFraction(camButton)
        end

        if menuAlive then
                data.pos.open = S.centerFraction(openButton)
        end

        return data
end

function S.applyConfig(data)
        if type(data.cl) == "table" then
                for key, default in pairs(K.CL_DEFAULTS) do
                        local value = data.cl[key]

                        if type(value) == type(default) then
                                CL[key] = value
                        end
                end
        end

        syncCamLockPanel()

        local scale = data.scale

        if type(scale) == "table" then
                if type(scale.stick) == "number" then
                        setStickPercent(scale.stick)
                end

                if type(scale.jump) == "number" then
                        setJumpPercent(scale.jump)
                end

                if type(scale.cam) == "number" then
                        setCamPercent(scale.cam)
                end

                if type(scale.shift) == "number" then
                        setShiftPercent(scale.shift)
                end
        end

        gameEdit.importState(data.game)
        refreshControls()

        local view = gui.AbsoluteSize
        local pos = data.pos

        if type(pos) == "table" and view.X > 0 and view.Y > 0 then
                local function place(name, target, onPlaced)
                        local p = pos[name]

                        if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
                                applyCenter(target, Vector2.new(p.x * view.X, p.y * view.Y))

                                if onPlaced then
                                        onPlaced()
                                end
                        end
                end

                place("stick", stickRing, function() stickMoved = true end)
                place("jump", jumpButton, function() jumpMoved = true end)
                place("shift", shiftButton, function() shiftMoved = true end)
                place("cam", camButton, function() camMoved = true end)

                if menuAlive then
                        place("open", openButton)
                end
        end

        cancelDragGoals()
end

S.RED = Color3.fromRGB(235, 120, 120)

function S.saveConfig()
        local ok, json = pcall(function()
                return S.HttpService:JSONEncode(S.collectConfig())
        end)

        if not ok then
                showToast("Не удалось собрать настройки", S.RED)
                warn("[MainPanel] Сохранение: " .. tostring(json))
                return
        end

        local write = S.envFunction("writefile")

        if write then
                local makeFolder = S.envFunction("makefolder")

                if makeFolder then
                        local folderExists = false
                        local isFolder = S.envFunction("isfolder")

                        if isFolder then
                                local okFolder, result = pcall(isFolder, S.SAVE_DIR)
                                folderExists = okFolder and result == true
                        end

                        if not folderExists then
                                pcall(makeFolder, S.SAVE_DIR)
                        end
                end

                local wrote, err = pcall(write, S.SAVE_FILE, json)

                if wrote then
                        showToast("Сохранено в файл " .. S.SAVE_FILE, K.GOLD)
                        return
                end

                warn("[MainPanel] writefile: " .. tostring(err))
        end

        local clip = S.envFunction("setclipboard") or S.envFunction("toclipboard")

        if clip and pcall(clip, json) then
                showToast("Файла нет. Конфиг скопирован в буфер, вставь его в EMBEDDED_CONFIG", K.GOLD)
                return
        end

        print("[MainPanel] CONFIG: " .. json)
        showToast("Конфиг выведен в Output (консоль)", K.GOLD)
end

function S.readConfigText()
        local read = S.envFunction("readfile")

        if read then
                local isfile = S.envFunction("isfile")

                for _, path in ipairs({S.SAVE_FILE, S.OLD_FILE}) do
                        local exists = true

                        if isfile then
                                local okExists, result = pcall(isfile, path)
                                exists = okExists and result == true
                        end

                        if exists then
                                local okRead, text = pcall(read, path)

                                if okRead and type(text) == "string" and text ~= "" then
                                        return text
                                end
                        end
                end
        end

        if S.EMBEDDED_CONFIG ~= "" then
                return S.EMBEDDED_CONFIG
        end

        return nil
end

function S.loadConfig(silent)
        local text = S.readConfigText()

        if not text then
                if not silent then
                        showToast("Сохранённого конфига нет", S.RED)
                end

                return false
        end

        local okDecode, data = pcall(function()
                return S.HttpService:JSONDecode(text)
        end)

        if not okDecode or type(data) ~= "table" then
                showToast("Конфиг повреждён, не загрузился", S.RED)
                return false
        end

        local okApply, err = pcall(S.applyConfig, data)

        if not okApply then
                showToast("Конфиг загрузился с ошибкой. Смотри Output", S.RED)
                warn("[MainPanel] Загрузка: " .. tostring(err))
                return false
        end

        showToast("Конфиг загружен", K.GOLD)
        return true
end

do
        local configRow = Instance.new("Frame")
        configRow.Name = "ConfigRow"
        configRow.LayoutOrder = 0
        configRow.Size = UDim2.new(1, 0, 0, 44)
        configRow.BackgroundTransparency = 1
        configRow.Parent = scroller

        local configList = Instance.new("UIListLayout")
        configList.FillDirection = Enum.FillDirection.Horizontal
        configList.SortOrder = Enum.SortOrder.LayoutOrder
        configList.Padding = UDim.new(0, 10)
        configList.Parent = configRow

        local function makeConfigButton(text, order, fill, textColor, callback)
                local button = Instance.new("TextButton")
                button.Name = text
                button.LayoutOrder = order
                button.Size = UDim2.new(0.5, -5, 1, 0)
                button.BackgroundColor3 = fill
                button.AutoButtonColor = false
                button.Text = text
                button.TextColor3 = textColor
                button.Font = Enum.Font.SourceSansBold
                button.TextSize = 20
                button.Parent = configRow

                addCorner(button, UDim.new(0, 10))
                addStroke(button, K.GOLD, 2)
                table.insert(interactive, button)

                local uiScale = Instance.new("UIScale")
                uiScale.Parent = button

                local press = pressEffect(uiScale)

                track(button.MouseButton1Down:Connect(function()
                        press(true)
                end))

                track(button.MouseButton1Up:Connect(function()
                        press(false)
                end))

                track(button.MouseLeave:Connect(function()
                        press(false)
                end))

                track(button.Activated:Connect(callback))
        end

        makeConfigButton("СОХРАНИТЬ", 1, K.GOLD, K.DARK, S.saveConfig)

        makeConfigButton("ЗАГРУЗИТЬ", 2, K.PURPLE, K.CREAM, function()
                S.loadConfig(false)
        end)
end

refreshControls()
placeDefaults(false)
S.loadConfig(true)
end

track(gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        task.defer(function()
                if not gui.Parent then
                        return
                end

                releaseStick(true)
                cancelDragGoals()
                refreshControls()
                placeDefaults(false)

                if menuAlive then
                        applyCenter(openButton, getCenter(openButton))
                        applyCenter(panel, getCenter(panel))
                end
        end)
end))
