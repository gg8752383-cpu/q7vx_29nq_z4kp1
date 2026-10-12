-- LocalScript
-- Куда положить: StarterPlayer > StarterPlayerScripts
--
-- ВАЖНО: удали или отключи (Disabled = true) свои СТАРЫЕ скрипты: MainPanel, джойстик, камлок, ViolenceMovement.
-- Этот скрипт один заменяет их все.
--
-- Что внутри:
--  * Свой джойстик и своя кнопка прыжка (копии оригинальных кнопок Roblox), быстрый отклик.
--  * Кнопка SHIFT (шифт-лок): персонаж стоит ровно по центру экрана и ЖЁСТКО, мгновенно смотрит туда же, куда камера
--    (никакого сдвига вбок; если захочешь сдвиг или высоту — ползунки в меню).
--  * КАМЛОК: кнопка CAM включает/выключает наводку. Цель держится до смерти.
--      - камера сзади и чуть выше, FOV 70; персонаж плавно-быстро смотрит на цель; камера работает поверх обычной
--        камеры Roblox (тип камеры не меняется), вход и выход плавные;
--      - цели: игроки и NPC/мобы; выбор: ближе к центру экрана / меньше HP / ближе по расстоянию;
--      - голова, если нет головы — центр тела; умное предсказание движения;
--      - через стены да/нет, только чужие команды, дистанция; когда цель умерла: снять лок / взять следующую /
--        искать цель САМ (кнопка CAM показывает ПОИСК);
--      - если цели нет, на экране появляется подсказка почему (нет целей рядом или цель за стеной);
--      - во время лока: тап по врагу = сменить цель, свайп вправо/влево = цель справа/слева.
--  * Гамбургер открывает меню. Меню и гамбургер таскаются пальцем, их можно утащить частично за край экрана.
--  * В меню (листай вверх/вниз): размер джойстика и прыжка, ВСЕ настройки камлока, размер панели, СБРОС.
--  * Пока меню ОТКРЫТО — режим настройки: джойстик, прыжок, SHIFT и CAM подсвечены золотой рамкой,
--    их можно таскать пальцем (а короткое нажатие SHIFT и CAM всё равно срабатывает).
--    Хочешь проверять управление при открытом меню — выключи переключатель «Двигать кнопки пальцем».
--    Когда меню закрыто — всё работает как обычные кнопки.
--  * Крестик X на меню УДАЛЯЕТ меню и гамбургер, всё остальное продолжает работать
--    (если нужно, чтобы X просто закрывал меню: X_DELETES_MENU = false).
--  * ПОВОРОТ ПЕРСОНАЖА теперь в одном месте: камлок, SHIFT и быстрый поворот больше не дерутся за него.
--  * ПК: Q — камлок, E — следующая цель, SHIFT-кнопка на экране.


local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")


local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")


------------------------------------------------------------
-- НАСТРОЙКИ
------------------------------------------------------------
local IMAGE_ID = "rbxassetid://80486373394899" -- должен быть ID КАРТИНКИ (Image), не Decal


local PANEL_SCALE = Vector2.new(0.72, 0.86) -- доля экрана
local PANEL_MIN = Vector2.new(380, 250)    -- минимум в пикселях
local PANEL_MAX = Vector2.new(820, 520)    -- максимум в пикселях
local CLOSED_SCALE = 0.85                  -- с какого масштаба "вырастает" панель


local OPEN_SIZE = 64      -- размер кнопки-гамбургера
local OPEN_DEFAULT_X = 44 -- где она стоит по умолчанию (отступ центра от левого края)


-- Кнопки управления (оригинал Roblox)
local STICK_SHEET = "rbxasset://textures/ui/TouchControlsSheet.png"
local JUMP_SHEET = "rbxasset://textures/ui/Input/TouchControlsSheetV2.png"
local SMALL_SCREEN_LIMIT = 500 -- как в оригинале: если меньшая сторона экрана <= 500, кнопки маленькие
local SIZE_SMALL = 70
local SIZE_BIG = 120


local DEAD_ZONE = 0.12 -- мёртвая зона: дрожь пальца при касании не считается движением (если «тугой» — 0.08)


-- ОТКЛИК ДЖОЙСТИКА (чтобы движение было быстрым и отзывчивым)
local STICK_REACH = 0.55  -- на какой доле радиуса кольца уже ПОЛНАЯ скорость (1 = только на самом краю; меньше = быстрее)
local STICK_CURVE = 0.75  -- кривая: 1 = линейно; меньше 1 = даже лёгкий наклон разгоняет сильнее
local FAST_TURN = true    -- персонаж быстро поворачивается в сторону движения (false = как обычный Roblox)
local TURN_RESPONSE = 22  -- скорость поворота: больше = резче


-- ШИФТ-ЛОК (кнопка SHIFT на экране): персонаж ВСЕГДА мгновенно смотрит туда же, куда камера
local SHIFT_LOCK_DEFAULT_ON = false              -- true = включён сразу при входе в игру
-- сдвиг камеры вбок и высота шифт-лока теперь в меню (по умолчанию 0 = персонаж ровно по центру экрана)
local SHIFT_OFFSET_RESPONSE = 20                 -- плавность сдвига камеры при включении/выключении
local SHIFT_SIZE = 62                            -- размер кнопки SHIFT


local STICK_ZONE_SCALE = 1.3
local STICK_ZONE_ACTIVE_SCALE = 2.6 -- пока ведёшь джойстик, зона нажатия растёт, чтобы палец не «вылетал» из неё и камера не дёргалась


local TAP_DOES_NOT_MOVE = true -- true: простое нажатие без движения пальца не двигает персонажа (ручка при этом всегда ровно под пальцем)
local TAP_MOVE_THRESHOLD = 6   -- на сколько пикселей надо сдвинуть палец, чтобы персонаж пошёл (защита от дрожи при касании)


local X_DELETES_MENU = true   -- true: крестик УДАЛЯЕТ меню и гамбургер (джойстик, прыжок и SHIFT остаются); false: просто закрывает меню


------------------------------------------------------------
-- КАМЛОК: кнопки и значения по умолчанию (потом ВСЁ меняется в панели)
------------------------------------------------------------
local CAM_BUTTON_SIZE = Vector2.new(104, 52) -- кнопка CAM
local CAM_KEY = Enum.KeyCode.Q               -- на ПК: включить/выключить камлок


local CL_DEFAULTS = {
        players = true,          -- брать игроков
        npcs = true,             -- брать NPC и мобов (любой Humanoid, который не игрок)
        enemiesOnly = true,      -- игроков из МОЕЙ команды не брать
        throughWalls = false,    -- false: цель за стеной не берём; спряталась дольше 1.5 с — лок снимается
        mode = 1,                -- 1 = ближе к центру экрана, 2 = меньше всего HP, 3 = ближе по расстоянию
        aimPart = 1,             -- 1 = голова (нет головы — тело), 2 = тело (центр)
        maxDist = 1000,          -- дистанция в студах; 1000 и больше = без ограничения
        afterDeath = 1,          -- цель умерла или пропала: всегда снять лок (цель держится пока не умрёт)
        faceTarget = true,       -- персонаж смотрит на цель
        aimSpeed = 18,           -- скорость наводки и поворота персонажа: 6 плавно ... 40 резко
        fov = 70,                -- угол обзора при локе
        height = 2.4,            -- камера выше обычной (работает и в камлоке)
        side = 0,                -- сдвиг камеры вбок при локе (0 = персонаж по центру, плюс = вправо, минус = влево)
        predict = true,          -- предсказание движения цели
        predictStrength = 85,    -- сила предсказания, % (не спешит; 100 = сильнее)
        showButtons = true,      -- показывать кнопку CAM
        panelSize = 100,         -- размер панели, %
        moveButtons = true,      -- пока меню открыто, кнопки можно таскать пальцем (выкл. = кнопки работают как обычно)
        shiftSide = 0,           -- шифт-лок: сдвиг камеры вбок (0 = персонаж ровно по центру экрана)
        shiftHeight = 0,         -- шифт-лок: камера выше на столько студов
}


local SCALE_MIN = 50
local SCALE_MAX = 150
local SCALE_DEFAULT = 100


local DRAG_THRESHOLD = 10 -- пикселей, после которых нажатие считается перетаскиванием
local EDGE_MARGIN = 4     -- отступ от края экрана
local SMOOTHING = 24      -- плавность следования за пальцем: больше = резче, меньше = мягче


local OPEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local KNOB_RETURN_INFO = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)


local GOLD = Color3.fromRGB(205, 170, 70)
local DARK = Color3.fromRGB(35, 15, 45)
local PURPLE = Color3.fromRGB(90, 40, 110)
local CREAM = Color3.fromRGB(245, 235, 215)


------------------------------------------------------------
-- ОБЩЕЕ СОСТОЯНИЕ
------------------------------------------------------------
local connections = {}
local function track(connection)
        table.insert(connections, connection)
        return connection
end


local cleanupCamLock = nil

-- Связь главной панели с AutoDodge (один скрипт, одна кнопка настройки).
local AutoDodgeController = nil
local dodgeEnabledWanted = true
local refreshDodgeToggle = nil
local publishedDodgeInput = Vector3.zero


local controls = nil
local controlsDisabled = false


local isOpen = false
local menuAlive = true
local editMode = false
local sliderOwner = nil
local interactive = {}


local old = playerGui:FindFirstChild("MainPanelGui")
if old then
        old:Destroy()
end


------------------------------------------------------------
-- ВСПОМОГАТЕЛЬНОЕ: создание элементов
------------------------------------------------------------
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


-- рамка именно по краю кнопки (у обычного UIStroke на TextButton обводится текст)
local function addBorder(parent, color, thickness, transparency)
        local stroke = addStroke(parent, color, thickness, transparency)
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        return stroke
end


-- короткая «вмятина» кнопки при нажатии: сразу видно, что нажатие дошло
local BUMP_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)


local function bump(uiScale)
        if not uiScale.Parent then
                return
        end


        uiScale.Scale = 0.86


        TweenService:Create(
                uiScale,
                BUMP_INFO,
                {Scale = 1}
        ):Play()
end


------------------------------------------------------------
-- GUI
------------------------------------------------------------
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


        if cleanupCamLock then
                pcall(cleanupCamLock)
        end


        if controlsDisabled and controls then
                pcall(function()
                        controls:Enable()
                end)
                controlsDisabled = false
        end
end))


-- подсказка сверху экрана (например, «Нет целей рядом»)
local toastLabel = Instance.new("TextLabel")
toastLabel.Name = "Toast"
toastLabel.AnchorPoint = Vector2.new(0.5, 0)
toastLabel.Position = UDim2.new(0.5, 0, 0, 12)
toastLabel.Size = UDim2.fromOffset(340, 46)
toastLabel.BackgroundColor3 = DARK
toastLabel.BackgroundTransparency = 0.12
toastLabel.TextColor3 = CREAM
toastLabel.Font = Enum.Font.SourceSansBold
toastLabel.TextSize = 18
toastLabel.TextWrapped = true
toastLabel.Text = ""
toastLabel.Visible = false
toastLabel.ZIndex = 30
toastLabel.Parent = gui
addCorner(toastLabel, UDim.new(0, 10))
local toastStroke = addBorder(toastLabel, GOLD, 2)


local toastToken = 0


local function showToast(text, color)
        toastToken = toastToken + 1
        local token = toastToken


        toastLabel.Text = text
        toastStroke.Color = color or GOLD
        toastLabel.Visible = true


        task.delay(2.2, function()
                if token == toastToken then
                        toastLabel.Visible = false
                end
        end)
end


------------------------------------------------------------
-- КНОПКИ УПРАВЛЕНИЯ: ДЖОЙСТИК И ПРЫЖОК
------------------------------------------------------------
local stickRing = Instance.new("ImageButton")
stickRing.Name = "Joystick"
stickRing.AnchorPoint = Vector2.new(0.5, 0.5)
stickRing.Position = UDim2.new(0, 60, 1, -55)
stickRing.Size = UDim2.fromOffset(SIZE_SMALL, SIZE_SMALL)
stickRing.BackgroundTransparency = 1
stickRing.AutoButtonColor = false
stickRing.Image = STICK_SHEET
stickRing.ImageRectOffset = Vector2.new(0, 0)
stickRing.ImageRectSize = Vector2.new(220, 220)
stickRing.ZIndex = 1
stickRing.Parent = gui


local stickKnob = Instance.new("ImageLabel")
stickKnob.Name = "StickImage"
stickKnob.AnchorPoint = Vector2.new(0.5, 0.5)
stickKnob.Position = UDim2.fromScale(0.5, 0.5)
stickKnob.Size = UDim2.fromOffset(SIZE_SMALL / 2, SIZE_SMALL / 2)
stickKnob.BackgroundTransparency = 1
stickKnob.Image = STICK_SHEET
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
addStroke(stickOutline, GOLD, 3, 0.1)


local stickZone = Instance.new("TextButton")
stickZone.Name = "TouchZone"
stickZone.AnchorPoint = Vector2.new(0.5, 0.5)
stickZone.Position = UDim2.fromScale(0.5, 0.5)
stickZone.Size = UDim2.fromScale(STICK_ZONE_SCALE, STICK_ZONE_SCALE)
stickZone.BackgroundTransparency = 1
stickZone.Text = ""
stickZone.AutoButtonColor = false
stickZone.ZIndex = 1
stickZone.Parent = stickRing


local jumpButton = Instance.new("ImageButton")
jumpButton.Name = "JumpButton"
jumpButton.AnchorPoint = Vector2.new(0.5, 0.5)
jumpButton.Position = UDim2.new(1, -60, 1, -55)
jumpButton.Size = UDim2.fromOffset(SIZE_SMALL, SIZE_SMALL)
jumpButton.BackgroundTransparency = 1
jumpButton.AutoButtonColor = false
jumpButton.Image = JUMP_SHEET
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
addStroke(jumpOutline, GOLD, 3, 0.1)


local shiftButton = Instance.new("TextButton")
shiftButton.Name = "ShiftLockButton"
shiftButton.AnchorPoint = Vector2.new(0.5, 0.5)
shiftButton.Position = UDim2.new(1, -60, 1, -150)
shiftButton.Size = UDim2.fromOffset(SHIFT_SIZE, SHIFT_SIZE)
shiftButton.BackgroundColor3 = DARK
shiftButton.BackgroundTransparency = 0.1
shiftButton.AutoButtonColor = false
shiftButton.Text = "SHIFT"
shiftButton.TextColor3 = GOLD
shiftButton.Font = Enum.Font.SourceSansBold
shiftButton.TextSize = 16
shiftButton.ZIndex = 1
shiftButton.Parent = gui
addCorner(shiftButton, UDim.new(1, 0))
local shiftStroke = addStroke(shiftButton, GOLD, 2)


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
addStroke(shiftOutline, GOLD, 3, 0.1)


-- кнопка камлока: CAM (включить/выключить)
local camButton = Instance.new("TextButton")
camButton.Name = "CamLockButton"
camButton.AnchorPoint = Vector2.new(0.5, 0.5)
camButton.Position = UDim2.new(1, -200, 1, -55)
camButton.Size = UDim2.fromOffset(CAM_BUTTON_SIZE.X, CAM_BUTTON_SIZE.Y)
camButton.BackgroundColor3 = DARK
camButton.BackgroundTransparency = 0.1
camButton.AutoButtonColor = false
camButton.Text = "CAM"
camButton.TextColor3 = GOLD
camButton.Font = Enum.Font.SourceSansBold
camButton.TextSize = 22
camButton.ZIndex = 1
camButton.Parent = gui
addCorner(camButton, UDim.new(0, 14))
local camStroke = addBorder(camButton, GOLD, 2)


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
addStroke(camOutline, GOLD, 3, 0.1)


------------------------------------------------------------
-- ПАНЕЛЬ
------------------------------------------------------------
local panel = Instance.new("CanvasGroup")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(PANEL_SCALE.X, PANEL_SCALE.Y)
panel.BackgroundColor3 = DARK
panel.BorderSizePixel = 0
panel.GroupTransparency = 1
panel.Visible = false
panel.ZIndex = 5
panel.Parent = gui


addCorner(panel, UDim.new(0, 14))
addStroke(panel, GOLD, 3)


local sizeLimit = Instance.new("UISizeConstraint")
sizeLimit.MinSize = PANEL_MIN
sizeLimit.MaxSize = PANEL_MAX
sizeLimit.Parent = panel


local panelScale = Instance.new("UIScale")
panelScale.Scale = CLOSED_SCALE
panelScale.Parent = panel


local background = Instance.new("ImageLabel")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundTransparency = 1
background.Image = IMAGE_ID
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
header.BackgroundColor3 = DARK
header.BackgroundTransparency = 0.2
header.BorderSizePixel = 0
header.Parent = content
addCorner(header, UDim.new(0, 10))
addStroke(header, GOLD, 2, 0.2)


local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.fromScale(1, 1)
title.BackgroundTransparency = 1
title.Text = "КНОПКИ УПРАВЛЕНИЯ"
title.TextColor3 = GOLD
title.Font = Enum.Font.SourceSansBold
title.TextSize = 22
title.Parent = header


local card = Instance.new("Frame")
card.Name = "Card"
card.Position = UDim2.fromOffset(0, 52)
card.Size = UDim2.new(1, 0, 1, -52)
card.BackgroundColor3 = DARK
card.BackgroundTransparency = 0.4
card.BorderSizePixel = 0
card.Parent = content
addCorner(card, UDim.new(0, 12))
addStroke(card, GOLD, 2, 0.45)


local cardPadding = Instance.new("UIPadding")
cardPadding.PaddingTop = UDim.new(0, 10)
cardPadding.PaddingBottom = UDim.new(0, 10)
cardPadding.PaddingLeft = UDim.new(0, 14)
cardPadding.PaddingRight = UDim.new(0, 8)
cardPadding.Parent = card


-- всё содержимое панели лежит в прокручиваемом списке (листай пальцем вверх/вниз)
local scroller = Instance.new("ScrollingFrame")
scroller.Name = "Scroller"
scroller.Size = UDim2.fromScale(1, 1)
scroller.BackgroundTransparency = 1
scroller.BorderSizePixel = 0
scroller.CanvasSize = UDim2.new()
scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroller.ScrollingDirection = Enum.ScrollingDirection.Y
scroller.ScrollBarThickness = 6
scroller.ScrollBarImageColor3 = GOLD
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
hint.TextColor3 = CREAM
hint.Font = Enum.Font.SourceSans
hint.TextSize = 18
hint.Parent = bottomRow


local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -12, 0, 12)
closeButton.Size = UDim2.fromOffset(40, 40)
closeButton.BackgroundColor3 = DARK
closeButton.BackgroundTransparency = 0.15
closeButton.AutoButtonColor = false
closeButton.Text = "X"
closeButton.TextColor3 = GOLD
closeButton.Font = Enum.Font.SourceSansBold
closeButton.TextSize = 24
closeButton.ZIndex = 6
closeButton.Parent = panel
addCorner(closeButton, UDim.new(1, 0))
addStroke(closeButton, GOLD, 2)
table.insert(interactive, closeButton)


local closeScale = Instance.new("UIScale")
closeScale.Parent = closeButton


------------------------------------------------------------
-- КНОПКА-ГАМБУРГЕР
------------------------------------------------------------
local openButton = Instance.new("TextButton")
openButton.Name = "OpenButton"
openButton.AnchorPoint = Vector2.new(0.5, 0.5)
openButton.Position = UDim2.new(0, OPEN_DEFAULT_X, 0.5, 0)
openButton.Size = UDim2.fromOffset(OPEN_SIZE, OPEN_SIZE)
openButton.BackgroundColor3 = DARK
openButton.BackgroundTransparency = 0.1
openButton.AutoButtonColor = false
openButton.Text = ""
openButton.ZIndex = 20
openButton.Parent = gui
addCorner(openButton, UDim.new(0, 14))
addStroke(openButton, GOLD, 2)


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
        bar.BackgroundColor3 = GOLD
        bar.BorderSizePixel = 0
        bar.ZIndex = 21
        bar.Parent = icon
        addCorner(bar, UDim.new(1, 0))
end


------------------------------------------------------------
-- РАЗМЕРЫ КНОПОК УПРАВЛЕНИЯ
------------------------------------------------------------
local stickPercent = SCALE_DEFAULT
local jumpPercent = SCALE_DEFAULT
local stickSize = SIZE_SMALL
local jumpSize = SIZE_SMALL


local function baseSize()
        local view = gui.AbsoluteSize
        if math.min(view.X, view.Y) <= SMALL_SCREEN_LIMIT then
                return SIZE_SMALL
        end
        return SIZE_BIG
end


------------------------------------------------------------
-- ПОЗИЦИИ
------------------------------------------------------------
local function getCenter(target)
        local view = gui.AbsoluteSize
        local p = target.Position
        return Vector2.new(p.X.Scale * view.X + p.X.Offset, p.Y.Scale * view.Y + p.Y.Offset)
end


local function halfSizeOf(target)
        if target == openButton then
                return Vector2.new(OPEN_SIZE, OPEN_SIZE) / 2
        elseif target == stickRing then
                return Vector2.new(stickSize, stickSize) / 2
        elseif target == jumpButton then
                return Vector2.new(jumpSize, jumpSize) / 2
        elseif target == shiftButton then
                return Vector2.new(SHIFT_SIZE, SHIFT_SIZE) / 2
        elseif target == camButton then
                return CAM_BUTTON_SIZE / 2
        end
        return target.AbsoluteSize / 2
end


local function clampCenter(target, center)
        local view = gui.AbsoluteSize
        if view.X <= 0 or view.Y <= 0 then
                return nil
        end
        local half = halfSizeOf(target)


        -- меню и гамбургер можно утащить частично за край экрана (на виду остаётся заголовок / часть кнопки)
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


        local x = math.clamp(
                center.X,
                math.min(half.X + EDGE_MARGIN, view.X / 2),
                math.max(view.X - half.X - EDGE_MARGIN, view.X / 2)
        )
        local y = math.clamp(
                center.Y,
                math.min(half.Y + EDGE_MARGIN, view.Y / 2),
                math.max(view.Y - half.Y - EDGE_MARGIN, view.Y / 2)
        )
        return Vector2.new(x, y)
end


local function applyCenter(target, center)
        local clamped = clampCenter(target, center)
        if not clamped then
                return
        end
        local view = gui.AbsoluteSize
        target.Position = UDim2.fromScale(clamped.X / view.X, clamped.Y / view.Y)
end


local function defaultCenter(kind)
        local view = gui.AbsoluteSize
        local small = math.min(view.X, view.Y) <= SMALL_SCREEN_LIMIT
        local base = small and SIZE_SMALL or SIZE_BIG


        if kind == "shift" then
                -- над кнопкой прыжка
                return defaultCenter("jump") - Vector2.new(0, base / 2 + SHIFT_SIZE / 2 + 24)
        end


        if kind == "cam" then
                -- слева от кнопки прыжка
                return defaultCenter("jump") - Vector2.new(base / 2 + CAM_BUTTON_SIZE.X / 2 + 16, 0)
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


        applyCenter(stickRing, getCenter(stickRing))
        applyCenter(jumpButton, getCenter(jumpButton))
        applyCenter(shiftButton, getCenter(shiftButton))
        applyCenter(camButton, getCenter(camButton))
end


------------------------------------------------------------
-- КАСАНИЯ
------------------------------------------------------------
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


-- Надёжное нажатие: срабатывает СРАЗУ при касании (InputBegan), а если вдруг касание не дошло этим путём —
-- запасной путь через Activated. Один и тот же тап дважды не сработает.
-- В режиме настройки (меню открыто и «Двигать кнопки» включено) нажатие обрабатывает makeDraggable (короткий тап).
local function bindPress(button, callback)
        local viaBegan = false


        track(button.InputBegan:Connect(function(input)
                if not isPointer(input) or editMode or coveredByUi(input) then
                        return
                end


                viaBegan = true
                callback()
        end))


        track(button.Activated:Connect(function()
                if viaBegan then
                        viaBegan = false
                        return
                end


                if editMode then
                        return
                end


                callback()
        end))
end


------------------------------------------------------------
-- ПЕРЕТАСКИВАНИЕ ПАЛЬЦЕМ
------------------------------------------------------------
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
                end


                if dragInput or not isPointer(input) then
                        return
                end


                if options.canStart and not options.canStart(input) then
                        return
                end


                dragInput = input
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


                if not moved and delta.Magnitude >= DRAG_THRESHOLD then
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


                if options.onPress then
                        options.onPress(false)
                end


                if wasTap and options.onTap then
                        options.onTap()
                end
        end))
end


track(RunService.RenderStepped:Connect(function(dt)
        local alpha = 1 - math.exp(-SMOOTHING * dt)


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


------------------------------------------------------------
-- РАБОТА КНОПОК УПРАВЛЕНИЯ
------------------------------------------------------------
local stickInput = nil
local moveVector = Vector3.zero
local needStopMove = false
local knobTween = nil
local stickAnchor = Vector2.zero
local stickStart = Vector2.zero
local stickArmed = true


local jumpInput = nil
local jumpHeld = false
local needStopJump = false


local function updateStick(input)
        local point = guiPoint(input)


        -- пока палец почти не двигался после касания, персонаж стоит
        if not stickArmed and (point - stickStart).Magnitude >= TAP_MOVE_THRESHOLD then
                stickArmed = true
        end


        -- ручка всегда ровно под пальцем (в пределах кольца)
        local offset = point - stickAnchor
        local maxLength = stickSize / 2


        if offset.Magnitude > maxLength then
                offset = offset.Unit * maxLength
        end


        stickKnob.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)


        if not stickArmed then
                moveVector = Vector3.zero
                return
        end


        local direction = offset / maxLength
        local magnitude = direction.Magnitude


        if magnitude <= DEAD_ZONE or magnitude == 0 then
                moveVector = Vector3.zero
        else
                -- полная скорость достигается уже на STICK_REACH радиуса, а не только на краю
                local t = math.clamp((magnitude - DEAD_ZONE) / (STICK_REACH - DEAD_ZONE), 0, 1)
                t = t ^ STICK_CURVE


                local unit = direction.Unit
                moveVector = Vector3.new(unit.X * t, 0, unit.Y * t)
        end
end


local function releaseStick(immediate)
        if stickInput or moveVector ~= Vector3.zero then
                needStopMove = true
        end


        stickInput = nil
        moveVector = Vector3.zero


        if knobTween then
                knobTween:Cancel()
                knobTween = nil
        end


        stickZone.Size = UDim2.fromScale(STICK_ZONE_SCALE, STICK_ZONE_SCALE)


        local center = UDim2.fromScale(0.5, 0.5)


        if immediate then
                stickKnob.Position = center
                return
        end


        knobTween = TweenService:Create(
                stickKnob,
                KNOB_RETURN_INFO,
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


        if editMode or stickInput or not isPointer(input) or coveredByUi(input) then
                return
        end


        stickInput = input


        if knobTween then
                knobTween:Cancel()
                knobTween = nil
        end


        -- центр кольца всегда фиксирован: ручка рисуется ровно под пальцем
        stickAnchor = stickRing.AbsolutePosition + stickRing.AbsoluteSize / 2
        stickStart = guiPoint(input)
        stickArmed = not TAP_DOES_NOT_MOVE


        -- пока палец на джойстике, зона шире: так палец не уходит «в пустоту» и камера не крутится
        stickZone.Size = UDim2.fromScale(STICK_ZONE_ACTIVE_SCALE, STICK_ZONE_ACTIVE_SCALE)


        updateStick(input)
end))


track(jumpButton.InputBegan:Connect(function(input)
        if jumpInput and not isLive(jumpInput) then
                releaseJump()
        end


        if editMode or jumpInput or not isPointer(input) or coveredByUi(input) then
                return
        end


        jumpInput = input
        jumpHeld = true
        jumpButton.ImageRectOffset = Vector2.new(146, 146)
end))


track(UserInputService.InputChanged:Connect(function(input)
        if stickInput and isSameDrag(input, stickInput) then
                updateStick(input)
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


------------------------------------------------------------
-- ШИФТ-ЛОК
------------------------------------------------------------
local shiftLockOn = SHIFT_LOCK_DEFAULT_ON
local shiftOffsetDirty = SHIFT_LOCK_DEFAULT_ON


local function refreshShiftButton()
        shiftButton.BackgroundColor3 = shiftLockOn and GOLD or DARK
        shiftButton.TextColor3 = shiftLockOn and DARK or GOLD
        shiftStroke.Color = shiftLockOn and CREAM or GOLD
end


local function getHumanoid()
        local character = player.Character
        return character and character:FindFirstChildOfClass("Humanoid")
end


-- AutoRotate теперь трогает только блок «ПОВОРОТ ПЕРСОНАЖА» ниже: так камлок, SHIFT и быстрый поворот не дерутся
local function setShiftLock(on)
        if on == shiftLockOn then
                return
        end


        shiftLockOn = on
        shiftOffsetDirty = true
        refreshShiftButton()
end


refreshShiftButton()


-- Эти имена нужны за пределами блока камлока (панель, кнопки)
local CL, MODE_NAMES, AIM_NAMES, MAXDIST_INF
local refreshCamButtons, toggleLock


-- Запасные функции: если камлок вдруг не запустится, всё остальное всё равно работает
refreshCamButtons = function() end
toggleLock = function()
        showToast("Камлок не запустился. Смотри окно Output", Color3.fromRGB(235, 120, 120))
end


local function setupCamLock() -- весь камлок в отдельной функции: в Roblox лимит 200 локальных переменных на одну функцию
        ------------------------------------------------------------
        -- КАМЛОК (камера работает ПОВЕРХ обычной камеры Roblox: тип камеры не меняется)
        ------------------------------------------------------------
        CL = {}
        for key, value in pairs(CL_DEFAULTS) do
                CL[key] = value
        end


        MODE_NAMES = {"Ближе к центру экрана", "Меньше всего HP", "Ближе по расстоянию"}
        AIM_NAMES = {"Голова (нет головы — тело)", "Тело (центр)"}
        MAXDIST_INF = 1000 -- значение ползунка дистанции, с которого лимита нет


        local FOCUS_Y = 2.0          -- высота «глаз» над центром тела (чуть выше)
        local DIST_MIN = 10          -- камера при локе: не ближе
        local DIST_MAX = 24          -- и не дальше (берётся твой текущий зум в этих пределах)
        local CAM_DIST_EXTRA = 2.5   -- чуть назад от текущего зума
        local BLEND_TIME = 0.3       -- за сколько секунд камера плавно переходит в лок и обратно
        local HIDDEN_RELEASE = 1.5   -- сколько секунд цель может быть за стеной (если стены выключены)
        local MAX_VIS_CHECKS = 25    -- сколько целей максимум проверять лучом при выборе (чтобы не лагало)
        local SEARCH_PERIOD = 0.25   -- как часто искать цель в режиме «авто-поиск»
        local TAP_RADIUS = 120       -- насколько близко к врагу надо тапнуть (пикселей)
        local TAP_MAX_MOVE = 14
        local TAP_MAX_TIME = 0.35
        local SWIPE_MIN_X = 70
        local SWIPE_MAX_TIME = 0.7
        local VEL_SMOOTH = 7         -- сглаживание скорости цели (меньше = спокойнее, без рывков)
        local TELEPORT_SPEED = 120   -- быстрее этого — считаем телепортом, предсказание сбрасывается
        local LEAD_SPEED = 520       -- «скорость» для расчёта упреждения (больше = меньше lead, не спешит)
        local LEAD_MIN = 0.03
        local LEAD_MAX = 0.16        -- максимум упреждения по времени — не гонит камеру вперёд
        local LEAD_CAP = 5.5         -- упреждение не больше стольких студов
        local STABLE_SPEED = 4.5     -- ниже этой скорости предикт почти не работает
        local TURN_DAMP = 0.35       -- если цель резко меняет направление — режем упреждение


        -- armed = камлок включён (кнопка CAM горит). Есть цель — ЛОК, нет цели — ПОИСК (только в режиме «авто»)
        local armed = false
        local target = nil
        local targetVel = Vector3.zero
        local lastTargetPos = Vector3.zero
        local lastTargetVel = Vector3.zero
        local visTimer = 0
        local hiddenTime = 0
        local uiTimer = 0
        local searchTimer = 0


        local overlay = false        -- наша камера сейчас поверх обычной
        local blend = 0              -- 0 = обычная камера Roblox, 1 = камера камлока
        local baseFov = 70
        local fovActive = false
        local camLook = Vector3.new(0, 0, -1)
        local camDist = 14.5


        local lockAimPoint = nil -- это читает блок поворота персонажа
        local npcSet = {}


        local function myParts()
                local character = player.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local root = humanoid and humanoid.RootPart
                return character, humanoid, root
        end


        ------------------------------------------------------------
        -- ПОВОРОТ ПЕРСОНАЖА (одно место для всех: камлок, SHIFT, быстрый поворот)
        ------------------------------------------------------------
        -- Приоритет: камлок (смотрит на цель) > SHIFT (смотрит ТОЧНО туда же, куда камера) > быстрый поворот к движению.
        -- Только этот блок трогает AutoRotate и поворачивает персонажа, поэтому «драки» за поворот нет.
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


        -- после камеры (приоритет Camera+2), чтобы поворот был по камере ЭТОГО ЖЕ кадра
        RunService:BindToRenderStep("MainPanelRotate", Enum.RenderPriority.Camera.Value + 2, function(dt)
                local humanoid = getHumanoid()


                if not humanoid then
                        setMouseLock(false)
                        return
                end


                -- плавный сдвиг камеры при включении/выключении SHIFT (по умолчанию сдвига НЕТ: персонаж ровно по центру экрана)
                local shiftWanted = Vector3.zero


                if shiftLockOn then
                        shiftWanted = Vector3.new(CL.shiftSide, CL.shiftHeight, 0)


                        if humanoid.CameraOffset ~= shiftWanted then
                                shiftOffsetDirty = true -- например, после возрождения персонажа или смены ползунка
                        end
                end


                if shiftOffsetDirty then
                        local nextOffset = humanoid.CameraOffset:Lerp(shiftWanted, 1 - math.exp(-SHIFT_OFFSET_RESPONSE * dt))


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


                local owner = nil


                if canTurn then
                        if armed and target and CL.faceTarget and lockAimPoint then
                                owner = "lock"
                        elseif shiftLockOn then
                                owner = "shift"
                        elseif FAST_TURN and stickInput and moveVector.Magnitude >= 0.05 then
                                owner = "move"
                        end
                end


                setMouseLock(owner == "shift")


                if owner then
                        if rotateHeld and rotateHumanoid ~= humanoid then
                                rotateHeld = false -- новое тело после возрождения
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
                                flat = Vector3.new(look.X, 0, look.Z) -- жёстко и мгновенно: ровно туда, куда смотрит камера (центр экрана)
                        else
                                local world = camera.CFrame:VectorToWorldSpace(moveVector)
                                flat = Vector3.new(world.X, 0, world.Z)
                                response = TURN_RESPONSE
                        end


                        if flat.Magnitude > 0.001 then
                                local wanted = CFrame.lookAt(position, position + flat.Unit)


                                if response then
                                        root.CFrame = root.CFrame:Lerp(wanted, 1 - math.exp(-response * dt))
                                else
                                        root.CFrame = wanted
                                end


                                root.AssemblyAngularVelocity = Vector3.zero -- не даём физике докручивать поворот (это и давало дрожь)
                        end
                else
                        releaseAutoRotate()
                end
        end)


        local flashToken = 0


        function refreshCamButtons()
                camButton.Visible = CL.showButtons


                if armed and target then
                        camButton.BackgroundColor3 = GOLD
                        camButton.TextColor3 = DARK
                        camButton.TextSize = 22
                        camButton.Text = "LOCK"
                        camStroke.Color = CREAM
                else
                        camButton.BackgroundColor3 = DARK
                        camButton.TextColor3 = GOLD
                        camButton.TextSize = 22
                        camButton.Text = "CAM"
                        camStroke.Color = GOLD
                end
        end


        -- список всех Humanoid в мире (NPC и мобы); игроков отсеиваем при выборе
        track(workspace.DescendantAdded:Connect(function(object)
                if object:IsA("Humanoid") then
                        npcSet[object] = true
                end
        end))


        track(workspace.DescendantRemoving:Connect(function(object)
                if npcSet[object] then
                        npcSet[object] = nil
                end
        end))


        task.spawn(function()
                local counter = 0


                for _, object in ipairs(workspace:GetDescendants()) do
                        if object:IsA("Humanoid") then
                                npcSet[object] = true
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


        -- луч, который «не замечает» чужих персонажей (их тела не считаются стеной)
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
                        if model == character or hum.Health <= 0 then
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
                                        try(model, hum, nil)
                                end
                        end
                end


                return list
        end


        -- лучшая цель по выбранному режиму (с учётом стен)
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


        -- почему цели нет: подсказка на экране (чтобы не казалось, что кнопка не работает)
        local function flashNoTarget()
                flashToken = flashToken + 1
                local token = flashToken


                local text = "Нет целей рядом. Проверь настройки в меню"


                if #collectCandidates() > 0 then
                        text = "Цели есть, но за стеной. Включи «Брать через стены»"
                end


                camButton.Text = "НЕТ ЦЕЛИ"
                camButton.TextSize = 18
                camStroke.Color = Color3.fromRGB(235, 80, 80)
                showToast(text, Color3.fromRGB(235, 120, 120))


                task.delay(1, function()
                        if token == flashToken then
                                refreshCamButtons()
                        end
                end)
        end


        -- камлок выключен: персонаж и камера возвращаются к обычным (камера плавно, через blend)
        local function turnOff()
                if not armed and not target then
                        return
                end


                armed = false
                target = nil
                lockAimPoint = nil
                refreshCamButtons()
        end


        -- наша камера включается поверх обычной: берём текущее направление и расстояние камеры
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
                -- чуть назад + в пределах DIST_MIN/DIST_MAX
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
                targetVel = Vector3.zero
                lastTargetVel = Vector3.zero
                lastTargetPos = candidate.part.Position
                visTimer = 0
                hiddenTime = 0


                beginOverlay(camera)
                refreshCamButtons()


                return true
        end


        -- цель умерла, вышла, спряталась или улетела слишком далеко — всегда снимаем лок
        local function onTargetLost()
                turnOff()
        end


        -- возвращает точку, куда целиться (с упреждением), или nil, если цель потеряна
        local function updateTarget(dt, camera, root)
                local c = target


                if not c then
                        return nil
                end


                if not c.hum.Parent or c.hum.Health <= 0 or not c.model.Parent then
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


                -- видимость проверяем не каждый кадр, а 5 раз в секунду
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


                -- скорость цели: считаем по смещению и сглаживаем, телепорты отбрасываем
                if dt > 0 then
                        local instant = (pos - lastTargetPos) / dt


                        if instant.Magnitude > TELEPORT_SPEED then
                                targetVel = Vector3.zero
                                lastTargetVel = Vector3.zero
                        else
                                -- сначала запоминаем старую скорость, потом сглаживаем новую
                                local prev = targetVel
                                targetVel = targetVel:Lerp(instant, 1 - math.exp(-VEL_SMOOTH * dt))
                                lastTargetVel = prev
                        end
                end


                lastTargetPos = pos


                local aim = pos


                if CL.predict then
                        local v = targetVel


                        -- на земле вертикальную скорость игнорируем, в прыжке берём слабее
                        if c.hum.FloorMaterial ~= Enum.Material.Air then
                                v = Vector3.new(v.X, 0, v.Z)
                        else
                                v = Vector3.new(v.X, v.Y * 0.35, v.Z)
                        end


                        local speed = v.Magnitude


                        if speed > STABLE_SPEED then
                                local fromCamera = (pos - camera.CFrame.Position).Magnitude


                                -- базовое упреждение: чем дальше — чуть больше, но жёсткий потолок
                                local leadTime = math.clamp(fromCamera / LEAD_SPEED, LEAD_MIN, LEAD_MAX)
                                leadTime = leadTime * (CL.predictStrength / 100)


                                -- вблизи почти не упреждаем
                                local near = math.clamp((dist - 6) / 14, 0, 1)


                                -- если цель тормозит — режем lead (не «спешим» в пустоту)
                                local prevSpeed = Vector3.new(lastTargetVel.X, 0, lastTargetVel.Z).Magnitude
                                local slowFactor = 1
                                if prevSpeed > 1 and speed < prevSpeed then
                                        slowFactor = math.clamp(speed / prevSpeed, 0.25, 1)
                                end


                                -- если резко повернула — тоже режем (умный предикт, не тупой)
                                local turnFactor = 1
                                local flatPrev = Vector3.new(lastTargetVel.X, 0, lastTargetVel.Z)
                                local flatNow = Vector3.new(v.X, 0, v.Z)
                                if flatPrev.Magnitude > 2 and flatNow.Magnitude > 2 then
                                        local dot = flatPrev.Unit:Dot(flatNow.Unit)
                                        if dot < 0.7 then
                                                turnFactor = TURN_DAMP + (1 - TURN_DAMP) * math.clamp((dot + 1) / 1.7, 0, 1)
                                        end
                                end


                                -- на большой скорости чуть осторожнее, чтобы не перелетать
                                local speedFactor = math.clamp(1.15 - (speed - 12) * 0.02, 0.55, 1)


                                local offset = v * leadTime * near * slowFactor * turnFactor * speedFactor


                                if offset.Magnitude > LEAD_CAP then
                                        offset = offset.Unit * LEAD_CAP
                                end


                                aim = pos + offset
                        end
                end


                return aim
        end


        -- полный сброс (возрождение, выход): камера сразу обычная, FOV на место
        local function hardReset()
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


        -- камера: сразу ПОСЛЕ обычной камеры Roblox (приоритет Camera+1), до поворота персонажа (Camera+2)
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


                -- угол обзора: к значению камлока и обратно
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


                -- то, что только что посчитала обычная камера Roblox
                local nativeCFrame = camera.CFrame
                local nativeFocus = camera.Focus


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


                -- камера у стены: плечо не должно уходить в стену
                if math.abs(CL.side) > 0.05 then
                        local toShoulder = shoulderPos - pivot
                        local hit = castThroughCharacters(pivot, toShoulder, ignore)


                        if hit then
                                shoulderPos = pivot + toShoulder.Unit * math.max(0, hit.Distance - 0.3)
                        end
                end


                if aimPoint then
                        local toAim = aimPoint - shoulderPos


                        if toAim.Magnitude > 0.5 then
                                local desired = clampPitch(toAim.Unit)
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


                uiTimer = uiTimer + dt


                if uiTimer >= 0.1 then
                        uiTimer = 0


                        if wantOverlay then
                                                        end
                end


                -- камера полностью вернулась: дальше работает только обычная камера Roblox
                if blend <= 0 and not wantOverlay then
                        overlay = false
                end
        end


        pcall(function()
                RunService:UnbindFromRenderStep("CamLockCamera")
        end)


        RunService:BindToRenderStep("CamLockCamera", Enum.RenderPriority.Camera.Value + 1, onCameraStep)


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
                        if input.KeyCode == CAM_KEY then
                                toggleLock()
                        end
                end
        end))


        

        ------------------------------------------------------------
        -- ПЕРСОНАЖ: возрождение, смерть, выход из игры
        ------------------------------------------------------------
        local function onCharacterAdded(character)
                hardReset()
                rotateHeld = false
                rotateHumanoid = nil
                shiftOffsetDirty = true -- после респавна снова применить сдвиг/высоту камеры


                -- GUI не должен пропадать после смерти / смены локации внутри места
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


track(player.CharacterAdded:Connect(function()
        -- Старое касание не должно продолжать двигать новое тело после респавна.
        releaseStick(true)
        releaseJump()
        publishedDodgeInput = Vector3.zero
        pcall(function()
                player:SetAttribute("DodgeManualInput", Vector3.zero)
        end)
end))


track(RunService.RenderStepped:Connect(function(dt)
        -- Публикуем мировое направление джойстика каждый кадр: поворот/замена камеры
        -- не оставляет AutoDodge со старым направлением.
        if stickInput then
                local camera = workspace.CurrentCamera
                local worldMove = Vector3.zero
                if camera and moveVector.Magnitude > 0.01 then
                        local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
                        local right = Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)
                        if look.Magnitude < 0.05 and right.Magnitude > 0.05 then
                                right = right.Unit
                                look = Vector3.new(right.Z, 0, -right.X)
                        else
                                look = look.Magnitude > 0.001 and look.Unit or Vector3.zero
                        end
                        right = right.Magnitude > 0.001 and right.Unit or Vector3.zero
                        worldMove = right * moveVector.X + look * (-moveVector.Z)
                end
                if (worldMove - publishedDodgeInput).Magnitude > 0.005 then
                        publishedDodgeInput = worldMove
                        pcall(function()
                                player:SetAttribute("DodgeManualInput", worldMove)
                        end)
                end
        elseif publishedDodgeInput.Magnitude > 0.001 then
                publishedDodgeInput = Vector3.zero
                pcall(function()
                        player:SetAttribute("DodgeManualInput", Vector3.zero)
                end)
        end

        if not (stickInput or needStopMove or jumpHeld or needStopJump) then
                return
        end


        local humanoid = getHumanoid()


        if humanoid then
                if stickInput then
                        humanoid:Move(moveVector, true)
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
end))


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




-- SHIFT и CAM: нажатие срабатывает сразу, без задержки
bindPress(shiftButton, function()
        bump(shiftScale)
        setShiftLock(not shiftLockOn)
end)


bindPress(camButton, function()
        bump(camScale)
        toggleLock()
end)




local function setEditMode(on)
        editMode = on
        stickOutline.Visible = on
        jumpOutline.Visible = on
        shiftOutline.Visible = on
        camOutline.Visible = on
        stickZone.Visible = not on


        if on then
                releaseStick(true)
                releaseJump()
        else
                cancelDragGoals()
        end
end


-- режим настройки: меню открыто И включён переключатель «Двигать кнопки пальцем»
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


------------------------------------------------------------
-- ОТКЛЮЧАЕМ СТАНДАРТНОЕ УПРАВЛЕНИЕ ROBLOX
------------------------------------------------------------
if UserInputService.TouchEnabled then
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
                        else
                                warn("[MainPanel] Не удалось отключить стандартное управление: " .. tostring(err))
                        end
                elseif not ok then
                        warn("[MainPanel] Не удалось получить стандартное управление: " .. tostring(result))
                end
        end)
end


------------------------------------------------------------
-- ОТКРЫТИЕ / ЗАКРЫТИЕ МЕНЮ
------------------------------------------------------------
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


        local info = open and OPEN_INFO or CLOSE_INFO


        local scaleTween = TweenService:Create(
                panelScale,
                info,
                {Scale = open and (CL.panelSize / 100) or CLOSED_SCALE}
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
                        PRESS_INFO,
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


------------------------------------------------------------
-- КРЕСТИК
------------------------------------------------------------
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
                if X_DELETES_MENU then
                        destroyMenu()
                else
                        setOpen(false)
                end
        end))
end


------------------------------------------------------------
-- ПОЛЗУНОК
------------------------------------------------------------
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
        box.BackgroundColor3 = DARK
        box.BackgroundTransparency = 0.3
        box.BorderSizePixel = 0
        box.Parent = parent


        addCorner(box, UDim.new(0, 10))
        addStroke(box, GOLD, 2, 0.55)


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
        label.TextColor3 = CREAM
        label.Font = Enum.Font.SourceSansSemibold
        label.TextSize = 19
        label.Parent = box


        local valueLabel = Instance.new("TextLabel")
        valueLabel.AnchorPoint = Vector2.new(1, 0)
        valueLabel.Position = UDim2.fromScale(1, 0)
        valueLabel.Size = UDim2.new(0.38, 0, 0, 22)
        valueLabel.BackgroundTransparency = 1
        valueLabel.TextXAlignment = Enum.TextXAlignment.Right
        valueLabel.TextColor3 = GOLD
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
        addStroke(trackBar, DARK, 1, 0.3)


        local fill = Instance.new("Frame")
        fill.Size = UDim2.fromScale(0, 1)
        fill.BackgroundColor3 = GOLD
        fill.BorderSizePixel = 0
        fill.Parent = trackBar
        addCorner(fill, UDim.new(1, 0))


        local knob = Instance.new("Frame")
        knob.AnchorPoint = Vector2.new(0.5, 0.5)
        knob.Size = UDim2.fromOffset(24, 24)
        knob.Position = UDim2.fromScale(0, 0.5)
        knob.BackgroundColor3 = CREAM
        knob.BorderSizePixel = 0
        knob.Parent = trackBar


        addCorner(knob, UDim.new(1, 0))
        addStroke(knob, GOLD, 3)


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
                        PRESS_INFO,
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
                scroller.ScrollingEnabled = false -- пока двигаешь ползунок, список не прокручивается


                TweenService:Create(
                        knobScale,
                        PRESS_INFO,
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
        SCALE_MIN,
        SCALE_MAX,
        SCALE_DEFAULT,
        function(value)
                stickPercent = value
                refreshControls()
        end
)


local setJumpPercent = makeSlider(
        sliderRow,
        2,
        "Прыжок",
        SCALE_MIN,
        SCALE_MAX,
        SCALE_DEFAULT,
        function(value)
                jumpPercent = value
                refreshControls()
        end
)


------------------------------------------------------------
-- НАСТРОЙКИ КАМЛОКА В ПАНЕЛИ
------------------------------------------------------------
local resetCamLockPanel


do -- блок строк камлока
        local rowOrder = 10
        local rowResetters = {}


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
                label.TextColor3 = GOLD
                label.Font = Enum.Font.SourceSansBold
                label.TextSize = 21
                label.Parent = scroller
        end


        local function styleRow(row)
                row.BackgroundColor3 = DARK
                row.BackgroundTransparency = 0.3
                row.BorderSizePixel = 0
                addCorner(row, UDim.new(0, 10))
                addBorder(row, GOLD, 2, 0.55)
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
                label.TextColor3 = CREAM
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
                dot.BackgroundColor3 = CREAM
                dot.BorderSizePixel = 0
                dot.Parent = pill
                addCorner(dot, UDim.new(1, 0))


                local function refresh()
                        local on = CL[key]


                        pill.BackgroundColor3 = on and GOLD or Color3.fromRGB(125, 90, 145)
                        dot.Position = on and UDim2.new(1, -13, 0.5, 0) or UDim2.new(0, 13, 0.5, 0)
                end


                refresh()
                table.insert(rowResetters, refresh)


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
                value.TextColor3 = GOLD
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


                table.insert(rowResetters, function()
                        setter(CL_DEFAULTS[key])
                end)
        end


        -- размер панели меняется, когда отпустил ползунок (иначе палец «убегает» от ползунка)
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
                for key, value in pairs(CL_DEFAULTS) do
                        CL[key] = value
                end


                for _, refresh in ipairs(rowResetters) do
                        refresh()
                end


                applyPanelSize()
                                refreshCamButtons()
                refreshEditMode()
        end


        local function fmt2(value)
                return string.format("%.2f", value)
        end


        addHeader("УПРАВЛЕНИЕ")

        -- AutoDodge встроен в эту панель; отдельная плавающая кнопка ему не нужна.
        do
                local row = Instance.new("TextButton")
                row.Name = "AutoDodgeToggle"
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
                label.Text = "Автоуклонение"
                label.TextXAlignment = Enum.TextXAlignment.Left
                label.TextColor3 = CREAM
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
                dot.BackgroundColor3 = CREAM
                dot.BorderSizePixel = 0
                dot.Parent = pill
                addCorner(dot, UDim.new(1, 0))

                refreshDodgeToggle = function()
                        if not row.Parent then
                                return
                        end
                        local on = dodgeEnabledWanted
                        pill.BackgroundColor3 = on and GOLD or Color3.fromRGB(125, 90, 145)
                        dot.Position = on and UDim2.new(1, -13, 0.5, 0) or UDim2.new(0, 13, 0.5, 0)
                        label.Text = on and "Автоуклонение: ВКЛ" or "Автоуклонение: ВЫКЛ"
                end
                refreshDodgeToggle()
                track(player:GetAttributeChangedSignal("AutoDodgeEnabled"):Connect(function()
                        local value = player:GetAttribute("AutoDodgeEnabled")
                        if type(value) == "boolean" then
                                dodgeEnabledWanted = value
                                if refreshDodgeToggle then
                                        refreshDodgeToggle()
                                end
                        end
                end))

                track(row.Activated:Connect(function()
                        dodgeEnabledWanted = not dodgeEnabledWanted
                        if AutoDodgeController and AutoDodgeController.SetEnabled then
                                local ok, err = pcall(AutoDodgeController.SetEnabled, dodgeEnabledWanted)
                                if not ok then
                                        warn("[MainPanel] Не удалось переключить AutoDodge: " .. tostring(err))
                                        showToast("Ошибка переключения автоуклонения", Color3.fromRGB(235, 120, 120))
                                end
                        end
                        if refreshDodgeToggle then
                                refreshDodgeToggle()
                        end
                end))
        end

        addToggle("Двигать кнопки пальцем (пока меню открыто)", "moveButtons", refreshEditMode)


        addHeader("ШИФТ-ЛОК (кнопка SHIFT)")
        addCamSlider("Шифт: сдвиг вбок", "shiftSide", -3, 3, 0.25, fmt2)
        addCamSlider("Шифт: высота", "shiftHeight", 0, 3, 0.25, fmt2)


        addHeader("КАМЛОК: ЦЕЛИ")
        addToggle("Игроки", "players")
        addToggle("NPC и мобы", "npcs")
        addToggle("Только чужие команды", "enemiesOnly")
        addToggle("Брать через стены", "throughWalls")
        addChoice("Кого брать", "mode", MODE_NAMES)
        addChoice("Куда целиться", "aimPart", AIM_NAMES)
        addCamSlider("Дистанция", "maxDist", 30, MAXDIST_INF, 10, function(value)
                if value >= MAXDIST_INF then
                        return "без лимита"
                end
                return tostring(value) .. " ст."
        end)


        addHeader("КАМЛОК: КАМЕРА")
        addToggle("Персонаж смотрит на цель", "faceTarget")
        addCamSlider("Скорость наводки", "aimSpeed", 6, 40, 1, plain)
        addCamSlider("Угол обзора (FOV)", "fov", 50, 110, 1, function(value)
                return tostring(value) .. "°"
        end)
        addCamSlider("Высота камеры", "height", 0, 6, 0.1, function(value)
                return string.format("%.1f", value)
        end)
        addCamSlider("Сдвиг камеры вбок", "side", -3, 3, 0.25, fmt2)


        addHeader("КАМЛОК: ПРЕДСКАЗАНИЕ")
        addToggle("Предсказание движения цели", "predict")
        addCamSlider("Сила предсказания", "predictStrength", 0, 150, 5, function(value)
                return tostring(value) .. "%"
        end)


        addHeader("ИНТЕРФЕЙС")
        addToggle("Кнопка CAM на экране", "showButtons", refreshCamButtons)
        addCamSlider("Размер панели", "panelSize", 70, 130, 5, function(value)
                return tostring(value) .. "%"
        end, applyPanelSize)
end


------------------------------------------------------------
-- КНОПКА СБРОС
------------------------------------------------------------
local resetButton = Instance.new("TextButton")
resetButton.Name = "ResetButton"
resetButton.AnchorPoint = Vector2.new(1, 0.5)
resetButton.Position = UDim2.fromScale(1, 0.5)
resetButton.Size = UDim2.fromOffset(120, 34)
resetButton.BackgroundColor3 = PURPLE
resetButton.AutoButtonColor = false
resetButton.Text = "СБРОС"
resetButton.TextColor3 = CREAM
resetButton.Font = Enum.Font.SourceSansBold
resetButton.TextSize = 20
resetButton.Parent = bottomRow


addCorner(resetButton, UDim.new(0, 10))
addStroke(resetButton, GOLD, 2)


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
                setStickPercent(SCALE_DEFAULT)
                setJumpPercent(SCALE_DEFAULT)


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


------------------------------------------------------------
-- ПОЛОЖЕНИЕ ПО УМОЛЧАНИЮ И ПОВОРОТ ЭКРАНА
------------------------------------------------------------
refreshControls()
placeDefaults(false)


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


------------------------------------------------------------
-- AUTO DODGE: встроенный модуль (локальные имена изолированы)
------------------------------------------------------------
local function runMergedAutoDodge()

local __AD_FN = {}
--==============================================================
-- AUTO DODGE v5.1 (поверх v5.0, настройки те же)
-- LocalScript -> StarterPlayer > StarterPlayerScripts
--==============================================================
-- Если файл запустили повторно, сначала аккуратно закрываем прошлый экземпляр.
if shared.__MergedMainPanelAutoDodgeCleanup then
	pcall(shared.__MergedMainPanelAutoDodgeCleanup)
end
-- Новое в v5.1 (универсальность):
--  • мобы без Humanoid (на AnimationController) тоже считаются врагами
--  • радиус удара подстраивается под размер врага (боссы, мелкие мобы)
--  • детали в папке/модели Projectiles, Hitboxes, Lava... опасны, даже если сами названы Part
--  • большие неосязаемые зоны (AoE боссов) больше не отбрасываются
--  • свои саммоны/питомцы/клоны не считаются угрозой
--  • опечатки в PROFILES/OVERRIDE дают предупреждение в Output
--  • язык кнопки: auto/ru/en (LANGUAGE)
--  • AutoDodge.Discover(): печатает, что вокруг (имена, теги, атрибуты, анимации), чтобы быстро заполнить профиль
--  • AutoDodge.CFG: меняй настройки на лету из командной строки
--
-- Новое в v5.0 (по мотивам того, как устроены боёвки в Роблоксе):
--  • тайминг удара из самой анимации: ключевые кадры/маркеры Hit, Damage, Strike...
--    читаются заранее (KeyframeSequence) и/или запоминаются по KeyframeReached
--  • снаряды, которые игра двигает по CFrame (FastCast и т.п.), ловятся по смещению
--  • точки клинка DmgPoint (RaycastHitbox / ClientCast) помогают ловить замах
--  • слабые телефоны: think сам переключается на облегчённый режим
--  • AutoDodge.HookRemote(...) для твоих ремоутов, AutoDodge.DumpLearned() для сида
--  • LEARNED_SEED / KEYFRAME_SEED в профиле: выученное сохраняется между сессиями
--
-- Новое в v4.5:
--  • режим «занят»: пока лечишь игрока / колдуешь / жмёшь предмет-лечилку,
--    уворот не дёргает тебя с места (кнопка показывает ПАУЗА)
--  • зажми LeftAlt, чтобы вручную поставить уворот на паузу
--  • не мешает собственному перекату/блоку игры и не тратится при неуязвимости
--  • API для твоих модулей: shared.AutoDodge.Busy / Pause / Resume
--
-- Новое в v4.4:
--  • профили игр: PROFILES[PlaceId] подменяет настройки под конкретную игру
--  • утечка памяти: кэши врага чистятся, когда враг пропадает
--  • части персонажей не лезут в список «летящих деталей» (быстрее)
--  • think теперь стабильно 30 Гц (раньше прыгал между 20 и 30)
--  • рывок сразу обрывается при стане / рэгдолле / выключении
--  • самообучение берёт только 1-2 ближайших врагов, смотрящих на тебя
--  • не уворачивается на лаву / килл-брики (даже огромные)
--  • ошибка в одном враге больше не ломает весь уворот
--  • кнопка не уезжает за экран при перетаскивании
--
-- Было в v4:
--  • реестр врагов/хитбоксов через события (не теряет врагов в толпе деталей)
--  • окна времени: уворот только когда удар реально долетит
--  • самообучение: запоминает анимации, после которых тебя ударили
--  • линия огня: шаг в сторону от стрелка/кастера
--  • замах оружия/рук как признак атаки, прыжок как последний шанс
--  • дэш (рывок) и уворот от огнестрела: прицел, выстрел, линия огня
--  • кнопка ВКЛ/ВЫКЛ (телефон), отладка рисунком и текстом
--==============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

--==============================================================
-- РЕЖИМ И НАСТРОЙКИ
--==============================================================

local MODE = "PARANOID" -- "CALM" (реже) | "BALANCED" | "PARANOID" (чаще, от всего)

local OVERRIDE = {
	-- сюда пиши свои значения, они сильнее режима, например:
	-- MARGIN = 3.5,
	-- ENABLE_SPEED_BOOST = false,
}

-- Профили игр: один скрипт на все твои игры. Подбирается по PlaceId или GameId.
-- Внутри любые ключи из CFG (списки заменяются целиком) и MODE.
local PROFILES = {
	-- [1234567890] = {
	-- 	MODE = "BALANCED",
	-- 	IGNORE_PART_NAMES = { "Head_Hitbox" },
	-- 	ATTACK_ANIMATION_IDS = { ["rbxassetid://123"] = true },
	-- 	DANGER_TAGS = { "Hitbox" },
	-- },
}

local MODES = {
	CALM = {
		TRIGGER_TIME = 0.45, MARGIN = 2.4, USE_ACTION_ANIMATIONS = false,
		DETECT_SWINGS = false, DODGE_LINE_OF_FIRE = false, STATIC_ZONES = false, DODGE_AIMED_GUNS = false,
	},
	BALANCED = {
		TRIGGER_TIME = 0.70, MARGIN = 3.2, USE_ACTION_ANIMATIONS = true,
		DETECT_SWINGS = true, DODGE_LINE_OF_FIRE = true, STATIC_ZONES = true, DODGE_AIMED_GUNS = true,
	},
	PARANOID = {
		TRIGGER_TIME = 0.85, MARGIN = 4.2, USE_ACTION_ANIMATIONS = true,
		DETECT_SWINGS = true, DODGE_LINE_OF_FIRE = true, STATIC_ZONES = true, DODGE_AIMED_GUNS = true,
	},
}

local CFG = {
	ENABLED = true,
	START_ENABLED = true,
	TOGGLE_BUTTON = false,
	TOGGLE_KEY = Enum.KeyCode.K,
	LANGUAGE = "auto", -- язык кнопки: "auto" (по языку Роблокса) | "ru" | "en"

	-- Поиск
	DETECT_RADIUS = 60,
	MAX_THREATS = 8,
	THINK_RATE = 1 / 30,
	ADAPTIVE_PERF = true,   -- слабый телефон: сам снижает частоту и число направлений
	PERF_BUDGET_MS = 3.0,   -- если think в среднем дольше, включаем облегчённый режим
	LOW_THINK_RATE = 1 / 20,
	LOW_DIRECTIONS = 16,

	-- Симуляция
	HORIZON = 0.85,
	STEP = 0.07,
	REACTION_LAG = 0.06,
	PING_COMP = true,
	VEL_TIME_CAP = 0.6,    -- враг не бежит за тобой дольше этого в расчёте
	STATIC_MARGIN = 1.2,   -- запас у неподвижных зон

	-- Враги
	MELEE_REACH = 8,
	SCALE_REACH = true, -- радиус удара растёт/уменьшается с размером врага (боссы, мелкие мобы)
	REACH_SIDE = 0.85,
	REACH_BACK = 0.55,
	ATTACK_CHECK_RANGE = 35,
	LUNGE_SPEED = 22,
	IGNORE_TEAMMATES = true,
	IGNORE_NAMES = {},
	-- детали, которые НИКОГДА не считаются угрозой (хитбоксы голов, рэгдолл-данные и т.п.)
	IGNORE_PART_NAMES = { "Head_Hitbox", "HitboxWeld" },
	IGNORE_ANCESTOR_NAMES = { "RagdollData" },
	IGNORE_TAGS = { "NoDodge" },
	ATTACK_END_FRACTION = 0.8, -- после этой доли анимации удар уже закончен
	SWING_TOOL_SPEED = 34,
	SWING_LIMB_SPEED = 42,

	-- Линия огня
	LINE_MIN_DIST = 14,
	LINE_MAX_DIST = 140,
	LINE_ANGLE_DOT = 0.88,

	-- Огнестрел: стрелок целится в тебя или стреляет -> уходим с линии огня
	-- (мгновенный выстрел не увидеть заранее, поэтому реагируем на прицел)
	GUN_ANGLE_DOT = 0.93,
	SHOT_ANGLE_DOT = 0.85,
	GUN_MIN_DIST = 3,
	GUN_LANE_WIDTH = 2.2,
	SHOT_WINDOW = 0.35,
	GUN_TOOL_WORDS = {
		"gun", "pistol", "rifle", "shotgun", "smg", "revolver", "sniper",
		"blaster", "crossbow", "longbow", "shortbow", "launcher", "glock",
		"deagle", "uzi", "ak47", "m4a1", "m16", "scar", "mp5", "musket",
		"cannon", "wand", "staff", "rocket", "laser", "taser",
	},
	GUN_PART_WORDS = { "muzzle", "barrel", "firepoint", "firepos", "bulletspawn", "magazine", "ammo" },
	GUN_ATTRIBUTES = { "Ammo", "FireRate", "Spread", "Magazine", "Bullets", "Recoil", "ReloadTime" },
	AIM_TAGS = { "AimThreat" }, -- тег на деталь-дуло: смотрит по LookVector (турели и т.п.)

	-- Снаряды и хитбоксы
	MIN_PROJECTILE_SPEED = 12,
	FAST_PROJECTILE_SPEED = 28,
	MAX_PART_SIZE = 80,
	MAX_PROJECTILE_SIZE = 30,
	USE_TAGS = true,
	ANCESTOR_FLAGS = true, -- детали в папке/модели с именем Projectiles, Hitboxes, Lava... опасны
	CFRAME_PROJECTILES = true, -- снаряды, которые игра двигает по CFrame (FastCast и т.п.), ловим по смещению
	YOUNG_LIFETIME = 8,        -- сколько секунд новая деталь считается «возможным снарядом»

	-- Обучение по урону
	AUTO_LEARN = true,
	LEARN_RADIUS = 30,
	LEARN_EARLY = 0.14,
	LEARN_LATE = 0.28,
	LEARNED_SEED = {},  -- предзаполнение: ["rbxassetid://123"] = { n = 2, hitAt = 0.35 } (см. AutoDodge.DumpLearned())
	KEYFRAME_SEED = {}, -- моменты удара в секундах: ["rbxassetid://123"] = { 0.35, 0.8 }

	-- Тайминги из самой анимации: ключевые кадры/маркеры с именами Hit, Damage, Strike...
	USE_KEYFRAME_DATA = true,  -- читать KeyframeSequence заранее (работает для анимаций твоей игры/группы)
	LEARN_FROM_MARKERS = true, -- запоминать моменты удара по KeyframeReached у других игроков и мобов
	HIT_MARKER_WORDS = {
		"hit", "damage", "strike", "slash", "impact", "swing", "punch", "kick", "stab",
		"smash", "slam", "attack", "hitbox", "release", "launch", "shoot", "fire", "cast",
	},
	HIT_MARKER_NAMES = { "Hit", "HitStart", "Damage", "DamageStart", "Strike", "Slash", "Impact", "Release", "Shoot", "Fire" },
	HIT_ATTACHMENT_NAMES = { "DmgPoint", "DamagePoint", "HitPoint", "HitboxPoint" }, -- точки клинка (RaycastHitbox/ClientCast)
	LEARN_MAX_ATTACKERS = 2, -- у скольких ближайших врагов учим анимации за один удар
	LEARN_MIN_HITS = 1,      -- сколько ударов нужно, чтобы анимация стала «известной» (2 = меньше ложных)

	-- Выбор направления
	DIRECTIONS = 24,
	WALL_RAY = 12,
	LEDGE_CHECK = true,
	LEDGE_DEPTH = 16,
	DANGER_GROUND_PENALTY = 10, -- штраф за шаг на лаву/килл-брик (0 = выкл)

	-- Прыжок как последний шанс
	JUMP_DODGE = true,
	JUMP_COOLDOWN = 0.7,

	-- Стабильность
	COMMIT_TIME = 0.16,
	PANIC_COMMIT_TIME = 0.08,
	PANIC_TIME = 0.28,
	HOLD_TIME = 0.30,
	SMOOTH = 22,
	SWITCH_GAIN = 0.6,

	-- Управление игроком
	MANUAL_BIAS = 1.6,
	MANUAL_BLEND = 0.12,

	-- Скорость
	ENABLE_SPEED_BOOST = true,
	SPEED_MULT = 1.18,
	PANIC_SPEED_MULT = 1.30,

	-- Не работать в этих состояниях (атрибуты на персонаже)
	PAUSE_ATTRIBUTES = { "Stunned", "Ragdoll", "Ragdolled", "Frozen", "Knocked", "Grabbed", "Gripped", "Rooted", "Cutscene", "Downed" },
	SKIP_WITH_FORCEFIELD = true,
	IMMUNE_ATTRIBUTES = { "Invincible", "Invulnerable", "IFrames", "Immune", "GodMode" }, -- неуязвим: уворот не нужен

	-- «Занят»: лечу игрока, колдую, взаимодействую... Уворот не уводит тебя с места.
	-- Признаки (любой): атрибут на персонаже/Humanoid, атрибут DodgeBusy на игроке,
	-- зажатая кнопка предмета-лечилки, твоя анимация лечения, вызов AutoDodge.Busy().
	BUSY_ATTRIBUTES = {
		"Healing", "Casting", "Channeling", "Reviving", "Interacting", "Carrying", "Busy",
		"Blocking", "Parrying", "Rolling", "Dodging", "Dashing",
	},
	BUSY_TOOL_WORDS = { "heal", "medkit", "bandage", "syringe", "revive" }, -- имя предмета в руке
	BUSY_ANIMATION_WORDS = { "heal", "channel", "revive", "bandage", "drink", "consume", "interact", "carry" },
	BUSY_ANIMATION_IDS = {}, -- ["rbxassetid://123"] = true
	BUSY_TAIL = 0.5,          -- сколько ещё «занят» после отпускания кнопки предмета
	BUSY_ALLOW_PANIC = false, -- true: даже когда занят, уходить от удара «прямо сейчас»
	SUSPEND_KEY = Enum.KeyCode.LeftAlt, -- пока держишь, уворот на паузе (nil = нет)

	-- Дэш (рывок): когда удар вот-вот попадёт, а обычным шагом не уйти
	DASH_ENABLED = true,
	DASH_SPEED = 62,      -- студов/сек во время рывка
	DASH_TIME = 0.2,      -- длительность (около 12 студов)
	DASH_COOLDOWN = 1.1,
	DASH_GAIN = 0.8,      -- насколько рывок должен быть лучше шага
	DASH_NEED = 1.0,      -- рывок только если у шага запас меньше этого
	DASH_IN_AIR = false,
	DASH_HOOK = nil,      -- function(direction, urgency) end: своя анимация/звук/ремоут

	DANGER_TAGS = {
		"AttackHitbox", "Hitbox", "DamageHitbox", "Danger",
		"Projectile", "Attack", "Hurtbox", "Damage",
	},
	DANGER_NAME_WORDS = {
		"hitbox", "hurtbox", "damage", "attack", "projectile", "danger",
		"slash", "swing", "strike", "lunge", "impact", "bullet",
		"missile", "fireball", "spell", "explosion", "blast",
		"shockwave", "aoe", "laser", "lava", "killbrick", "killpart", "killzone",
		"acid", "poison", "spike", "sawblade", "bomb", "grenade", "rocket",
		"arrow", "dart", "knife", "shuriken", "kunai",
	},
	DAMAGE_ATTRIBUTES = { "Damage", "DamageAmount", "Dmg" },
	INACTIVE_ATTRIBUTES = { "Active", "Enabled", "CanDamage", "DamageActive", "HitboxActive" },
	OWNER_NAMES = { "Owner", "Attacker", "Creator", "Source", "OwnerCharacter", "AttackerCharacter" },
	ATTACK_ATTRIBUTES = {
		"IsAttacking", "Attacking", "AttackActive", "IsAttackActive",
		"AttackCommitted", "Swinging", "Dashing", "Charging",
		"AttackingNow", "CanDamage", "DamageActive", "HitboxActive",
	},
	ATTACK_ANIMATION_WORDS = {
		"attack", "swing", "slash", "strike", "lunge", "punch", "kick",
		"stab", "shoot", "cast", "skill", "ability", "combo",
		"smash", "slam", "bite", "claw", "charge", "damage",
		"fire", "throw", "shot", "blast", "beam",
		"barrage", "uppercut", "bash", "drill", "explode", "rapid", "spin", "bullet",
	},
	IGNORE_ANIMATION_WORDS = {
		"idle", "walk", "run", "jump", "fall", "climb", "swim", "sit",
		"emote", "dance", "wave", "laugh", "cheer", "point", "toolnone",
		"block", "equip", "unequip", "hold", "stun",
		"hurt", "flinch", "react", "getup", "death", "dead",
	},
	ATTACK_ANIMATION_IDS = {}, -- сюда можно вписать "rbxassetid://123"

	DEBUG = false,
	DEBUG_DRAW = false,
	DEBUG_HUD = false,
}

-- порядок: MODE -> профиль игры -> OVERRIDE (последний сильнее всех)
local profile = PROFILES[game.PlaceId] or PROFILES[game.GameId] or {}
for k, v in pairs(MODES[profile.MODE or MODE] or MODES.BALANCED) do
	CFG[k] = v
end
-- опечатки в именах настроек: предупреждаем, а не молчим
local NIL_KEYS = { DASH_HOOK = true }
__AD_FN.checkKeys = function(tbl, label)
	for k in pairs(tbl) do
		if k ~= "MODE" and CFG[k] == nil and not NIL_KEYS[k] then
			warn(string.format("[AutoDodge] %s: неизвестная настройка '%s' (опечатка?)", label, tostring(k)))
		end
	end
end
__AD_FN.checkKeys(profile, "PROFILES")
__AD_FN.checkKeys(OVERRIDE, "OVERRIDE")
for k, v in pairs(profile) do
	if k ~= "MODE" then
		CFG[k] = v
	end
end
for k, v in pairs(OVERRIDE) do
	CFG[k] = v
end

local CAP = 7
local FAR = 1e6

local ACTION_PRIORITIES = {
	[Enum.AnimationPriority.Action] = true,
	[Enum.AnimationPriority.Action2] = true,
	[Enum.AnimationPriority.Action3] = true,
	[Enum.AnimationPriority.Action4] = true,
}

--==============================================================
-- STATE
--==============================================================

local Character, Humanoid, Root
local rayParams

local charConns, rootConns = {}, {}

local enabled = CFG.START_ENABLED
local baseSpeed, boosted, lastSet = 16, false, 0

local threats = {}
local active, panic = false, false
local targetDir, curDir = Vector3.zero, Vector3.zero
local dodgeUntil, lastChoose, lastThink = 0, 0, 0
local lastJump, lastDash = -math.huge, -math.huge
local dashDir, dashUntil, dashWas = Vector3.zero, 0, false
local pingValue, lastPing = 0, 0
local lastError = ""
local jumpPlanned = false
local lastManual, lastManualTime = Vector3.zero, 0
local lastStats = { threats = 0, tHit = nil }
local hardPauseUntil, busyUntil = 0, 0 -- Pause()/Busy() из игры и «хвост» после предмета
local suspendHeld = false              -- держишь SUSPEND_KEY
local toolDown = {}                    -- [Tool] = true, пока зажата кнопка лечилки
local holdPause, shownPause = false, false -- пауза из-за «занят»/ручная (для кнопки)
local ownAnim = { t = -1, v = false }

local humanoids = {}          -- [Humanoid] = true
local manualThreats = {}      -- угрозы из shared.AutoDodge
local flaggedParts = {}       -- [BasePart] = true
local aimParts = {}           -- [BasePart] = true (тег AimThreat)
local dynamicParts = {}       -- [BasePart] = true
local motion = setmetatable({}, { __mode = "k" })
local ownerCache = setmetatable({}, { __mode = "k" })
local animCache = setmetatable({}, { __mode = "k" })
local swingCache = setmetatable({}, { __mode = "k" })
local rangedCache = setmetatable({}, { __mode = "k" })
local shotAt = setmetatable({}, { __mode = "k" })
local watched = setmetatable({}, { __mode = "k" })
local learned = {}            -- [animationId] = { n = count, hitAt = seconds }
local kfInfo = {}             -- [animationId] = { hits = {секунды...}, src } или false (читали, ничего нет)
local kfPending = {}          -- [animationId] = true, пока грузится KeyframeSequence
local kfLive = {}             -- [animationId] = { hits = {...}, src = "live" } из наблюдения за маркерами
local hookedTracks = setmetatable({}, { __mode = "k" })
local youngParts = {}         -- [BasePart] = время появления (двигаемые по CFrame снаряды)
local scanDone = false
local thinkAvg, perfLow = 0, false
local isIgnoredModel          -- задаётся ниже (нужна и обучению, и сбору угроз)

local controls = nil
local autoDodgeApi = nil
local dynNear, dynNearT = {}, -math.huge

--==============================================================
-- HELPERS
--==============================================================

__AD_FN.flat = function(v)
	return Vector3.new(v.X, 0, v.Z)
end

__AD_FN.unit = function(v)
	local m = v.Magnitude
	if m > 1e-4 then
		return v / m
	end
	return Vector3.zero
end

__AD_FN.isAlive = function()
	return Humanoid ~= nil
		and Humanoid.Parent ~= nil
		and Humanoid.Health > 0
		and Root ~= nil
		and Root.Parent ~= nil
end

__AD_FN.containsWord = function(name, words)
	if type(name) ~= "string" or name == "" then
		return false
	end
	local lower = string.lower(name)
	for _, w in ipairs(words) do
		if string.find(lower, w, 1, true) then
			return true
		end
	end
	return false
end

__AD_FN.attrActive = function(inst)
	if not inst then
		return false
	end
	for _, name in ipairs(CFG.ATTACK_ATTRIBUTES) do
		local v = inst:GetAttribute(name)
		if v == true or (type(v) == "number" and v > 0) then
			return true
		end
	end
	return false
end

-- Враг = модель с Humanoid ИЛИ с AnimationController (боссы/мобы без Humanoid)
__AD_FN.isActorModel = function(model)
	return model:IsA("Model")
		and (model:FindFirstChildOfClass("Humanoid") ~= nil
			or model:FindFirstChildOfClass("AnimationController") ~= nil)
end

__AD_FN.actorDead = function(actor)
	return actor:IsA("Humanoid") and actor.Health <= 0
end

__AD_FN.getRoot = function(model)
	if not model:IsA("Model") then
		return nil
	end
	local r = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if r and r:IsA("BasePart") then
		return r
	end
	local t = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
	if t and t:IsA("BasePart") then
		return t
	end
	for _, n in ipairs({ "RootPart", "Root", "Hitbox", "Body" }) do
		local x = model:FindFirstChild(n)
		if x and x:IsA("BasePart") then
			return x
		end
	end
	return model:FindFirstChildWhichIsA("BasePart")
end

__AD_FN.ownerIsMe = function(value)
	if value == nil then
		return false
	end
	if typeof(value) == "Instance" then
		return value == LocalPlayer
			or (Character ~= nil and (value == Character or value:IsDescendantOf(Character)))
	end
	if type(value) == "number" then
		return value == LocalPlayer.UserId
	end
	if type(value) == "string" then
		return value == LocalPlayer.Name or value == tostring(LocalPlayer.UserId)
	end
	return false
end

-- Деталь принадлежит мне (мой снаряд/мой хитбокс). Кэш 2 сек.
__AD_FN.isMine = function(part, now)
	if Character and part:IsDescendantOf(Character) then
		return true
	end
	local rec = ownerCache[part]
	if rec and now - rec.t < 2 then
		return rec.v
	end
	local mine = false
	local cur = part
	for _ = 1, 4 do
		if not cur or cur == Workspace then
			break
		end
		for _, n in ipairs(CFG.OWNER_NAMES) do
			local child = cur:FindFirstChild(n)
			if child and child:IsA("ObjectValue") and __AD_FN.ownerIsMe(child.Value) then
				mine = true
			end
			if __AD_FN.ownerIsMe(cur:GetAttribute(n)) then
				mine = true
			end
		end
		if __AD_FN.ownerIsMe(cur:GetAttribute("OwnerUserId")) or __AD_FN.ownerIsMe(cur:GetAttribute("AttackerUserId")) then
			mine = true
		end
		if mine then
			break
		end
		cur = cur.Parent
	end
	ownerCache[part] = { v = mine, t = now }
	return mine
end

--==============================================================
-- РЕЕСТРЫ (события вместо сканирования всего вокруг)
--==============================================================

__AD_FN.computeFlag = function(part)
	if CFG.USE_TAGS then
		for _, tag in ipairs(CFG.DANGER_TAGS) do
			if CollectionService:HasTag(part, tag) then
				return true
			end
		end
	end
	if __AD_FN.containsWord(part.Name, CFG.DANGER_NAME_WORDS) then
		return true
	end
	for _, attr in ipairs(CFG.DAMAGE_ATTRIBUTES) do
		if part:GetAttribute(attr) ~= nil then
			return true
		end
	end
	return false
end

__AD_FN.ignoredPart = function(part)
	if table.find(CFG.IGNORE_PART_NAMES, part.Name) then
		return true
	end
	local cur = part.Parent
	for _ = 1, 6 do
		if not cur or cur == Workspace then
			break
		end
		if table.find(CFG.IGNORE_ANCESTOR_NAMES, cur.Name) then
			return true
		end
		cur = cur.Parent
	end
	return false
end

-- Деталь внутри персонажа/моба (с Humanoid): такие не бывают «летящим снарядом»
__AD_FN.inCharacterModel = function(inst)
	local cur = inst.Parent
	for _ = 1, 6 do
		if not cur or cur == Workspace then
			return false
		end
		if __AD_FN.isActorModel(cur) then
			return true
		end
		cur = cur.Parent
	end
	return false
end

-- Деталь лежит в папке/модели с «опасным» именем (Projectiles, Hitboxes, Lava...), даже если сама зовётся Part
local ancFlagCache = setmetatable({}, { __mode = "k" })
__AD_FN.ancestorDanger = function(part)
	local cur = part.Parent
	for _ = 1, 3 do
		if not cur or cur == Workspace then
			return false
		end
		local c = ancFlagCache[cur]
		if c == nil then
			c = __AD_FN.containsWord(cur.Name, CFG.DANGER_NAME_WORDS)
				and not __AD_FN.isActorModel(cur)
				and not __AD_FN.inCharacterModel(cur)
			ancFlagCache[cur] = c
		end
		if c then
			return true
		end
		cur = cur.Parent
	end
	return false
end

__AD_FN.classify = function(inst)
	if inst:IsA("Humanoid") or inst:IsA("AnimationController") then
		humanoids[inst] = true
	elseif inst:IsA("BasePart") then
		if flaggedParts[inst] or dynamicParts[inst] then
			return
		end
		if __AD_FN.ignoredPart(inst) then
			return
		end
		if __AD_FN.computeFlag(inst) or (CFG.ANCESTOR_FLAGS and __AD_FN.ancestorDanger(inst)) then
			flaggedParts[inst] = true
		elseif not inst.Anchored then
			if not __AD_FN.inCharacterModel(inst) then
				dynamicParts[inst] = true
			end
		elseif CFG.CFRAME_PROJECTILES and scanDone and not __AD_FN.inCharacterModel(inst) then
			local sz = inst.Size
			if math.max(sz.X, sz.Y, sz.Z) <= CFG.MAX_PROJECTILE_SIZE then
				youngParts[inst] = os.clock()
			end
		end
	end
end

__AD_FN.unclassify = function(inst)
	if humanoids[inst] then
		-- враг исчез: чистим всё, что держало на него ссылки
		humanoids[inst] = nil
		animCache[inst] = nil
		local model = inst.Parent
		if model then
			swingCache[model] = nil
			shotAt[model] = nil
		end
	end
	flaggedParts[inst] = nil
	dynamicParts[inst] = nil
	aimParts[inst] = nil
	youngParts[inst] = nil
end

__AD_FN.addTagged = function(inst)
	if not inst:IsDescendantOf(Workspace) then
		return
	end
	if inst:IsA("BasePart") then
		if not __AD_FN.ignoredPart(inst) then
			dynamicParts[inst] = nil
			flaggedParts[inst] = true
		end
	else
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") and not __AD_FN.ignoredPart(d) then
				dynamicParts[d] = nil
				flaggedParts[d] = true
			end
		end
	end
end

__AD_FN.startRegistries = function()
	table.insert(rootConns, Workspace.DescendantAdded:Connect(__AD_FN.classify))
	table.insert(rootConns, Workspace.DescendantRemoving:Connect(__AD_FN.unclassify))

	if CFG.USE_TAGS then
		for _, tag in ipairs(CFG.DANGER_TAGS) do
			table.insert(rootConns, CollectionService:GetInstanceAddedSignal(tag):Connect(__AD_FN.addTagged))
			for _, inst in ipairs(CollectionService:GetTagged(tag)) do
				if inst:IsDescendantOf(Workspace) then
					__AD_FN.addTagged(inst)
				end
			end
		end
	end

	for _, tag in ipairs(CFG.AIM_TAGS) do
		table.insert(rootConns, CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
			if inst:IsA("BasePart") and inst:IsDescendantOf(Workspace) then
				aimParts[inst] = true
			end
		end))
		for _, inst in ipairs(CollectionService:GetTagged(tag)) do
			if inst:IsA("BasePart") and inst:IsDescendantOf(Workspace) then
				aimParts[inst] = true
			end
		end
	end

	task.spawn(function()
		local all = Workspace:GetDescendants()
		for i, inst in ipairs(all) do
			pcall(__AD_FN.classify, inst)
			if i % 1500 == 0 then
				task.wait()
			end
		end
		scanDone = true
	end)
end

__AD_FN.modelFromPart = function(part, cache)
	local cur = part.Parent
	local chain = {}
	local found = false
	local depth = 0
	while cur and cur ~= Workspace and depth < 8 do
		local c = cache[cur]
		if c ~= nil then
			found = c
			break
		end
		chain[#chain + 1] = cur
		if __AD_FN.isActorModel(cur) then
			found = cur
			break
		end
		cur = cur.Parent
		depth += 1
	end
	for _, inst in ipairs(chain) do
		cache[inst] = found
	end
	return found or nil
end

--==============================================================
-- СКОРОСТЬ ПО ДВИЖЕНИЮ (для твинов и CFrame-хитбоксов)
--==============================================================

__AD_FN.measuredVel = function(part, now)
	local v = part.AssemblyLinearVelocity
	local pos = part.Position
	local rec = motion[part]
	if rec and v.Magnitude < 1 then
		local dt = now - rec.t
		if dt > 0.001 and dt < 0.25 then
			local m = (pos - rec.p) / dt
			if m.Magnitude < 400 then
				v = m
			end
		end
	end
	motion[part] = { p = pos, t = now }
	return v
end

--==============================================================
-- ПИНГ
--==============================================================

__AD_FN.updatePing = function(now)
	if now - lastPing < 1 then
		return
	end
	lastPing = now
	local ok, p = pcall(function()
		return LocalPlayer:GetNetworkPing()
	end)
	if ok and type(p) == "number" then
		pingValue = math.clamp(p, 0, 0.4)
	end
end

--==============================================================
-- АНИМАЦИИ ВРАГА
--==============================================================

__AD_FN.getAnimator = function(hum)
	local a = hum:FindFirstChildOfClass("Animator")
	if a then
		return a
	end
	return nil
end

__AD_FN.trackId = function(track)
	local anim = track.Animation
	if anim then
		return anim.AnimationId
	end
	return ""
end

__AD_FN.trackIgnored = function(track)
	if __AD_FN.containsWord(track.Name, CFG.IGNORE_ANIMATION_WORDS) then
		return true
	end
	local anim = track.Animation
	return anim ~= nil and __AD_FN.containsWord(anim.Name, CFG.IGNORE_ANIMATION_WORDS)
end

-- Выученная анимация считается «известной» только после LEARN_MIN_HITS ударов
__AD_FN.learnedRec = function(id)
	local L = learned[id]
	if L and L.n >= CFG.LEARN_MIN_HITS then
		return L
	end
	return nil
end

-- Сохранённые моменты удара (секунды от начала анимации): из KeyframeSequence, сида или наблюдения
__AD_FN.hitTimesFor = function(id)
	local k = kfInfo[id]
	if k then
		return k.hits, k.src
	end
	local l = kfLive[id]
	if l then
		return l.hits, "live"
	end
	return nil
end

-- Достаём тайминги удара из самой анимации: ключевые кадры/маркеры Hit, Damage, Strike...
-- Работает для анимаций, которыми владеет твоя игра/группа; если не вышло, молча идём дальше.
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

__AD_FN.loadKeyframeData = function(id)
	if not CFG.USE_KEYFRAME_DATA or id == "" or kfInfo[id] ~= nil or kfPending[id] then
		return
	end
	kfPending[id] = true
	task.spawn(function()
		local ok, seq = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(id)
		end)
		local hits = {}
		if ok and typeof(seq) == "Instance" then
			for _, kf in ipairs(seq:GetChildren()) do
				if kf:IsA("Keyframe") then
					local isHit = __AD_FN.containsWord(kf.Name, CFG.HIT_MARKER_WORDS)
					if not isHit then
						local okm, markers = pcall(function()
							return kf:GetMarkers()
						end)
						if okm and markers then
							for _, m in ipairs(markers) do
								if __AD_FN.containsWord(m.Name, CFG.HIT_MARKER_WORDS) then
									isHit = true
									break
								end
							end
						end
					end
					if isHit then
						hits[#hits + 1] = kf.Time
					end
				end
			end
			pcall(function()
				seq:Destroy()
			end)
		end
		table.sort(hits)
		kfInfo[id] = #hits > 0 and { hits = hits, src = "keyframe" } or false
		kfPending[id] = nil
	end)
end

-- Запоминаем момент удара, когда у чужой анимации сработал маркер/кадр Hit, Damage...
__AD_FN.recordLiveHit = function(id, t)
	local rec = kfLive[id]
	if not rec then
		rec = { hits = {}, src = "live" }
		kfLive[id] = rec
	end
	for _, h in ipairs(rec.hits) do
		if math.abs(h - t) < 0.06 then
			return
		end
	end
	if #rec.hits < 8 then
		rec.hits[#rec.hits + 1] = t
		table.sort(rec.hits)
	end
end

__AD_FN.hookTrackMarkers = function(tr, id)
	if not CFG.LEARN_FROM_MARKERS or hookedTracks[tr] then
		return
	end
	hookedTracks[tr] = true
	pcall(function()
		tr.KeyframeReached:Connect(function(name)
			if __AD_FN.containsWord(name, CFG.HIT_MARKER_WORDS) then
				__AD_FN.recordLiveHit(id, tr.TimePosition)
			end
		end)
		for _, nm in ipairs(CFG.HIT_MARKER_NAMES) do
			tr:GetMarkerReachedSignal(nm):Connect(function()
				__AD_FN.recordLiveHit(id, tr.TimePosition)
			end)
		end
	end)
end

-- M1, M2... как отдельное слово (не внутри Anim1/Item1)
__AD_FN.isComboName = function(name)
	return type(name) == "string" and string.find(string.lower(name), "%f[%w]m%d%f[%W]") ~= nil
end

-- "known" = точно атака, "generic" = любая Action-анимация, nil = не атака
__AD_FN.isAimName = function(name)
	return type(name) == "string" and string.find(string.lower(name), "%f[%a]aim") ~= nil
end

__AD_FN.classifyTrack = function(track)
	if not track.IsPlaying or track.WeightCurrent < 0.1 then
		return nil
	end
	local id = __AD_FN.trackId(track)
	if id ~= "" and (CFG.ATTACK_ANIMATION_IDS[id] or table.find(CFG.ATTACK_ANIMATION_IDS, id) or __AD_FN.learnedRec(id) or __AD_FN.hitTimesFor(id)) then
		return "known"
	end
	if __AD_FN.containsWord(track.Name, CFG.ATTACK_ANIMATION_WORDS) or __AD_FN.isComboName(track.Name) then
		return "known"
	end
	local anim = track.Animation
	if anim and (__AD_FN.containsWord(anim.Name, CFG.ATTACK_ANIMATION_WORDS) or __AD_FN.isComboName(anim.Name)) then
		return "known"
	end
	if __AD_FN.isAimName(track.Name) or (anim and __AD_FN.isAimName(anim.Name)) then
		return "aim"
	end
	if __AD_FN.trackIgnored(track) then
		return nil
	end
	if CFG.USE_ACTION_ANIMATIONS and not track.Looped and ACTION_PRIORITIES[track.Priority] then
		return "generic"
	end
	return nil
end

-- Окно опасности трека в секундах от сейчас: from, to
__AD_FN.trackWindow = function(track)
	local len = track.Length
	local pos = track.TimePosition
	local spd = track.Speed
	if spd == nil or math.abs(spd) < 0.05 then
		spd = 1
	end
	if len <= 0 then
		return 0, 0.5
	end
	local endT = len * CFG.ATTACK_END_FRACTION
	local id = __AD_FN.trackId(track)
	local L = __AD_FN.learnedRec(id)
	if L then
		local tth = (L.hitAt - pos) / spd
		local from, to = tth - CFG.LEARN_EARLY, tth + CFG.LEARN_LATE
		if to < 0 then
			return nil
		end
		return math.max(from, 0), to
	end
	local hits, hitSrc = __AD_FN.hitTimesFor(id)
	if hits then
		-- ближайший ещё не прошедший удар из анимации
		for _, h in ipairs(hits) do
			local tth = (h - pos) / spd
			if tth + CFG.LEARN_LATE >= 0 then
				return math.max(tth - CFG.LEARN_EARLY, 0), tth + CFG.LEARN_LATE
			end
		end
		if hitSrc ~= "live" then
			return nil
		end
	end
	if pos > endT then
		return nil
	end
	return 0, math.max((endT - pos) / spd, 0.15)
end

-- Возвращает список { kind, from, to } по играющим трекам. Кэш по дистанции.
__AD_FN.attackWindows = function(hum, dist, now)
	local rec = animCache[hum]
	local interval = dist < 20 and 0 or (dist < 50 and 0.06 or 0.15)
	if not rec or now - rec.t >= interval then
		local list = {}
		local animator = __AD_FN.getAnimator(hum)
		if animator then
			local ok, tracks = pcall(function()
				return animator:GetPlayingAnimationTracks()
			end)
			if ok and tracks then
				for _, tr in ipairs(tracks) do
					local kind = __AD_FN.classifyTrack(tr)
					if kind then
						list[#list + 1] = { track = tr, kind = kind }
						if kind ~= "aim" then
							local tid = __AD_FN.trackId(tr)
							if tid ~= "" then
								__AD_FN.loadKeyframeData(tid)
								__AD_FN.hookTrackMarkers(tr, tid)
							end
						end
					end
				end
			end
		end
		rec = { t = now, list = list }
		animCache[hum] = rec
	end

	local out = {}
	for _, item in ipairs(rec.list) do
		local tr = item.track
		if tr.IsPlaying then
			if item.kind == "aim" then
				out[#out + 1] = { kind = "aim", from = 0, to = FAR }
			else
				local from, to = __AD_FN.trackWindow(tr)
				if from then
					out[#out + 1] = { kind = item.kind, from = from, to = to }
				end
			end
		end
	end
	return out
end

--==============================================================
-- ЗАМАХ ОРУЖИЯ / РУК
--==============================================================

local LIMB_NAMES = { "RightHand", "LeftHand", "Right Arm", "Left Arm" }

__AD_FN.detectSwing = function(model, root, myPos, now)
	local rec = swingCache[model]
	if not rec then
		rec = { parts = {}, untilT = 0 }
		swingCache[model] = rec
	end
	if now < rec.untilT then
		return true
	end

	local candidates = {}
	local tool = model:FindFirstChildOfClass("Tool")
	if tool then
		local h = tool:FindFirstChild("Handle")
		if h and h:IsA("BasePart") then
			candidates[#candidates + 1] = { h, CFG.SWING_TOOL_SPEED }
		end
		-- точки клинка из RaycastHitbox / ClientCast (Attachment "DmgPoint")
		for _, nm in ipairs(CFG.HIT_ATTACHMENT_NAMES) do
			local a = tool:FindFirstChild(nm, true)
			if a and a:IsA("Attachment") then
				candidates[#candidates + 1] = { a, CFG.SWING_TOOL_SPEED }
				break
			end
		end
	end
	for _, n in ipairs(LIMB_NAMES) do
		local l = model:FindFirstChild(n)
		if l and l:IsA("BasePart") then
			candidates[#candidates + 1] = { l, CFG.SWING_LIMB_SPEED }
		end
	end

	local found = false
	for _, c in ipairs(candidates) do
		local part, thr = c[1], c[2]
		local prev = rec.parts[part]
		local pos = part:IsA("Attachment") and part.WorldPosition or part.Position
		local rpos = root.Position
		if prev then
			local dt = now - prev.t
			if dt > 0.01 and dt < 0.3 then
				local disp = (pos - prev.p) - (rpos - prev.r)
				local v = disp / dt
				local s = v.Magnitude
				if s > thr and s < 300 and __AD_FN.unit(v):Dot(__AD_FN.unit(myPos - pos)) > 0.2 then
					found = true
				end
			end
		end
		rec.parts[part] = { p = pos, r = rpos, t = now }
	end

	if found then
		rec.untilT = now + 0.25
	end
	return found
end

--==============================================================
-- ОБУЧЕНИЕ ПО УРОНУ
--==============================================================

__AD_FN.learnFromHit = function(myPos)
	if not CFG.AUTO_LEARN then
		return
	end

	-- кандидаты: ближайшие враги, повёрнутые к тебе (а не вся толпа вокруг)
	local cands = {}
	for hum in pairs(humanoids) do
		if hum ~= Humanoid and hum.Parent and not __AD_FN.actorDead(hum) and not isIgnoredModel(hum.Parent) then
			local root = __AD_FN.getRoot(hum.Parent)
			if root then
				local offset = myPos - root.Position
				local d = offset.Magnitude
				if d <= CFG.LEARN_RADIUS then
					local facing = __AD_FN.unit(__AD_FN.flat(root.CFrame.LookVector)):Dot(__AD_FN.unit(__AD_FN.flat(offset)))
					if facing > 0.2 or d < 6 then
						cands[#cands + 1] = { hum = hum, d = d }
					end
				end
			end
		end
	end
	table.sort(cands, function(a, b)
		return a.d < b.d
	end)

	for i = 1, math.min(#cands, CFG.LEARN_MAX_ATTACKERS) do
		local hum = cands[i].hum
		local animator = __AD_FN.getAnimator(hum)
		if animator then
			local ok, tracks = pcall(function()
				return animator:GetPlayingAnimationTracks()
			end)
			if ok and tracks then
				for _, tr in ipairs(tracks) do
					local id = __AD_FN.trackId(tr)
					if id ~= "" and tr.IsPlaying and tr.WeightCurrent >= 0.1
						and not tr.Looped and not __AD_FN.trackIgnored(tr)
						and (ACTION_PRIORITIES[tr.Priority] or __AD_FN.containsWord(tr.Name, CFG.ATTACK_ANIMATION_WORDS))
					then
						local hitAt = math.max(tr.TimePosition - pingValue, 0.05)
						local rec = learned[id]
						if rec then
							rec.hitAt = (rec.hitAt * rec.n + hitAt) / (rec.n + 1)
							rec.n += 1
						else
							learned[id] = { n = 1, hitAt = hitAt }
						end
						animCache[hum] = nil
					end
				end
			end
		end
	end

	local count = 0
	for _ in pairs(learned) do
		count += 1
	end
	pcall(function()
		LocalPlayer:SetAttribute("AutoDodgeLearned", count)
	end)
end

--==============================================================
-- СБОР УГРОЗ
--==============================================================
-- Форма угрозы:
--  эллипсоид: kind="ell", cf, rf (вперёд), rb (назад), rs (бок), ry (вверх)
--  коробка:   kind="box", cf, half
--  общее: vel, from/to (окно времени, сек), margin, dist

__AD_FN.isTeammate = function(model)
	if not CFG.IGNORE_TEAMMATES or not LocalPlayer.Team then
		return false
	end
	local plr = Players:GetPlayerFromCharacter(model)
	return plr ~= nil and plr.Team == LocalPlayer.Team
end

function isIgnoredModel(model)
	if table.find(CFG.IGNORE_NAMES, model.Name) then
		return true
	end
	for _, tag in ipairs(CFG.IGNORE_TAGS) do
		if CollectionService:HasTag(model, tag) then
			return true
		end
	end
	return __AD_FN.isTeammate(model)
end

-- Оружие дальнего боя: по имени, атрибутам или деталям (дуло, патроны)
__AD_FN.isRangedTool = function(tool, now)
	local rec = rangedCache[tool]
	if rec and (rec.v or now - rec.t < 2) then
		return rec.v
	end
	local r = __AD_FN.containsWord(tool.Name, CFG.GUN_TOOL_WORDS)
	if not r then
		for _, a in ipairs(CFG.GUN_ATTRIBUTES) do
			if tool:GetAttribute(a) ~= nil then
				r = true
				break
			end
		end
	end
	if not r then
		for _, d in ipairs(tool:GetDescendants()) do
			if __AD_FN.containsWord(d.Name, CFG.GUN_PART_WORDS) then
				r = true
				break
			end
		end
	end
	rangedCache[tool] = { v = r, t = now }
	return r
end

-- Следим за признаками выстрела: звук, вспышка, частицы, изменение патронов
__AD_FN.watchTool = function(tool, model, now)
	if watched[tool] then
		return
	end
	local conns = {}
	watched[tool] = conns
	local t0 = now

	local function shot()
		local n = os.clock()
		if n - t0 > 0.4 then
			shotAt[model] = n
		end
	end
	local function hook(inst)
		if inst:IsA("Sound") then
			table.insert(conns, inst.Played:Connect(shot))
		elseif inst:IsA("Light") or inst:IsA("ParticleEmitter") then
			table.insert(conns, inst:GetPropertyChangedSignal("Enabled"):Connect(shot))
		end
	end

	for _, d in ipairs(tool:GetDescendants()) do
		hook(d)
	end
	table.insert(conns, tool.DescendantAdded:Connect(function(d)
		hook(d)
		if d:IsA("Sound") or d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail")
			or d:IsA("Light") or d:IsA("BasePart")
		then
			shot()
		end
	end))
	table.insert(conns, tool.AttributeChanged:Connect(function(name)
		if table.find(CFG.GUN_ATTRIBUTES, name) then
			shot()
		end
	end))
	table.insert(conns, tool.AncestryChanged:Connect(function()
		if not tool:IsDescendantOf(Workspace) then
			for _, c in ipairs(conns) do
				c:Disconnect()
			end
			watched[tool] = nil
		end
	end))
end

-- Линия огня: длинная коробка от стрелка через тебя
__AD_FN.addLane = function(list, pos, lookU, dist, from, to, urgent, baseWidth)
	local length = math.min(dist + 25, CFG.LINE_MAX_DIST)
	local width = (baseWidth or 2.5) + 0.05 * dist
	local center = pos + lookU * (length * 0.5)
	list[#list + 1] = {
		kind = "box", cf = CFrame.lookAt(center, center + lookU),
		half = Vector3.new(width, 4, length * 0.5),
		vel = Vector3.zero, from = from, to = to, dist = dist, urgent = urgent,
	}
end

-- Размер врага относительно обычного персонажа (кэш 1 с): боссы бьют дальше, мелочь ближе
local scaleCache = setmetatable({}, { __mode = "k" })
__AD_FN.actorScale = function(model, now)
	local rec = scaleCache[model]
	if rec and now - rec.t < 1 then
		return rec.v
	end
	local v = 1
	local ok, size = pcall(function()
		return model:GetExtentsSize()
	end)
	if ok and size then
		v = math.clamp(size.Y / 5.4, 0.7, 3.5)
		if v > 0.9 and v < 1.15 then
			v = 1
		end
	end
	scaleCache[model] = { v = v, t = now }
	return v
end

__AD_FN.addHumanoidThreat = function(list, hum, myPos, now)
	local model = hum.Parent
	if not model or model == Character or __AD_FN.actorDead(hum) then
		return
	end
	local root = __AD_FN.getRoot(model)
	if not root then
		return
	end

	local offset = myPos - root.Position
	local dist = offset.Magnitude
	local maxRange = (CFG.DODGE_LINE_OF_FIRE or CFG.DODGE_AIMED_GUNS) and CFG.LINE_MAX_DIST or CFG.ATTACK_CHECK_RANGE
	if dist > maxRange then
		return
	end
	if isIgnoredModel(model) then
		return
	end
	-- свои саммоны/питомцы/клоны (Owner/Creator... = ты) не угроза
	if __AD_FN.isMine(root, now) then
		return
	end

	local dirToMe = __AD_FN.unit(__AD_FN.flat(offset))
	local vel = __AD_FN.flat(__AD_FN.measuredVel(root, now))
	local closing = vel:Dot(dirToMe)
	local near = dist <= CFG.ATTACK_CHECK_RANGE
	local scale = CFG.SCALE_REACH and __AD_FN.actorScale(model, now) or 1

	local look = __AD_FN.flat(root.CFrame.LookVector)
	local lookU = __AD_FN.unit(look)
	local facing = lookU:Dot(dirToMe)

	local from, to = FAR, -FAR
	local function extend(a, b)
		if a < from then from = a end
		if b > to then to = b end
	end

	local tool = model:FindFirstChildOfClass("Tool")
	local gunner = false
	if tool and __AD_FN.isRangedTool(tool, now) then
		gunner = true
		__AD_FN.watchTool(tool, model, now)
	end
	local shotT = shotAt[model]
	local recentShot = shotT ~= nil and now - shotT <= CFG.SHOT_WINDOW

	local lunging = near and closing >= CFG.LUNGE_SPEED
	local ranged = false
	local meleeSignal = false
	local aimTrack = false

	if lunging then
		extend(0, 0.6)
		meleeSignal = true
	end
	if near and (__AD_FN.attrActive(model) or __AD_FN.attrActive(root) or __AD_FN.attrActive(hum)) then
		extend(0, 0.6)
		meleeSignal = true
		ranged = true
	end
	if near and CFG.DETECT_SWINGS and __AD_FN.detectSwing(model, root, myPos, now) then
		extend(0, 0.4)
		meleeSignal = true
	end

	for _, w in ipairs(__AD_FN.attackWindows(hum, dist, now)) do
		if w.kind == "aim" then
			aimTrack = true
		elseif w.kind == "known" then
			extend(w.from, w.to)
			meleeSignal = true
			ranged = true
		elseif near and facing > 0.3 and dist < CFG.MELEE_REACH * scale * 2.2 then
			extend(w.from, w.to)
			meleeSignal = true
			ranged = true
		end
	end

	if recentShot then
		extend(0, CFG.SHOT_WINDOW)
		ranged = true
	end

	if to >= from and near and meleeSignal then
		local reach = CFG.MELEE_REACH * scale * (lunging and 1.25 or 1)
		local pos = root.Position
		local cf = CFrame.lookAt(pos, pos + (lookU.Magnitude > 0.1 and lookU or Vector3.new(0, 0, -1)))
		list[#list + 1] = {
			kind = "ell", cf = cf,
			rf = reach, rb = reach * CFG.REACH_BACK, rs = reach * CFG.REACH_SIDE,
			ry = math.max(reach * 0.6, 4),
			vel = vel, from = from, to = to, dist = dist,
		}
	end

	local laneMade = false
	if to >= from and CFG.DODGE_LINE_OF_FIRE and ranged then
		local minD = recentShot and CFG.GUN_MIN_DIST or CFG.LINE_MIN_DIST
		local minDot = recentShot and CFG.SHOT_ANGLE_DOT or CFG.LINE_ANGLE_DOT
		if dist >= minD and facing >= minDot then
			__AD_FN.addLane(list, root.Position, lookU, dist, from, to, true, recentShot and CFG.GUN_LANE_WIDTH or nil)
			laneMade = true
		end
	end

	-- Стрелок просто целится: держимся вне линии (срочным это не считаем)
	if not laneMade and CFG.DODGE_AIMED_GUNS and (gunner or aimTrack)
		and dist >= CFG.GUN_MIN_DIST and facing >= CFG.GUN_ANGLE_DOT
	then
		__AD_FN.addLane(list, root.Position, lookU, dist, 0, FAR, false, CFG.GUN_LANE_WIDTH)
	end
end

__AD_FN.boxThreat = function(part, vel, dist, static)
	return {
		kind = "box", cf = part.CFrame, half = part.Size * 0.5,
		vel = vel, from = 0, to = FAR, dist = dist,
		margin = static and CFG.STATIC_MARGIN or nil,
		urgent = not static,
	}
end

__AD_FN.inactiveHitbox = function(part)
	for _, a in ipairs(CFG.INACTIVE_ATTRIBUTES) do
		if part:GetAttribute(a) == false then
			return true
		end
	end
	return false
end

__AD_FN.gather = function(now)
	local list = {}
	local myPos = Root.Position
	local R = CFG.DETECT_RADIUS

	-- угрозы, присланные игрой через shared.AutoDodge
	for i = #manualThreats, 1, -1 do
		local m = manualThreats[i]
		if now > m.endT then
			table.remove(manualThreats, i)
		else
			local c = m.cf.Position
			local d = (c - myPos).Magnitude
			if d - m.reach <= R then
				list[#list + 1] = {
					kind = m.kind, cf = m.cf, half = m.half,
					rf = m.rf, rb = m.rb, rs = m.rs, ry = m.ry,
					vel = m.vel, from = math.max(0, m.startT - now), to = m.endT - now,
					dist = d, urgent = m.urgent,
				}
			end
		end
	end

	-- каждый враг в своём pcall: один кривой моб не ломает весь уворот
	for hum in pairs(humanoids) do
		if hum.Parent then
			local ok, err = pcall(__AD_FN.addHumanoidThreat, list, hum, myPos, now)
			if not ok then
				local msg = tostring(err)
				if msg ~= lastError then
					lastError = msg
					warn("[AutoDodge] ошибка врага:", msg)
				end
			end
		else
			humanoids[hum] = nil
		end
	end

	for part in pairs(flaggedParts) do
		if not part.Parent then
			flaggedParts[part] = nil
		else
			local size = part.Size
			local big = math.max(size.X, size.Y, size.Z)
			if big <= CFG.MAX_PART_SIZE or not part.CanCollide then
				local d = (part.Position - myPos).Magnitude
				if d - big * 0.5 <= R and not __AD_FN.inactiveHitbox(part) and not __AD_FN.isMine(part, now) then
					local vel = __AD_FN.measuredVel(part, now)
					local static = vel.Magnitude < 1
					if not static or CFG.STATIC_ZONES then
						list[#list + 1] = __AD_FN.boxThreat(part, vel, d, static)
					end
				end
			end
		end
	end

	for part in pairs(aimParts) do
		if not part.Parent then
			aimParts[part] = nil
		elseif CFG.DODGE_AIMED_GUNS then
			local off = myPos - part.Position
			local d = off.Magnitude
			if d >= 2 and d <= CFG.LINE_MAX_DIST then
				local look = __AD_FN.unit(__AD_FN.flat(part.CFrame.LookVector))
				if look.Magnitude > 0.1 and look:Dot(__AD_FN.unit(__AD_FN.flat(off))) >= CFG.GUN_ANGLE_DOT then
					__AD_FN.addLane(list, part.Position, look, d, 0, FAR, false, CFG.GUN_LANE_WIDTH)
				end
			end
		end
	end

	-- Свободные детали: тяжёлый отбор раз в 0.12 с, дальше проверяем только быстрых рядом
	if now - dynNearT >= 0.12 then
		dynNearT = now
		dynNear = {}
		for part in pairs(dynamicParts) do
			if not part.Parent then
				dynamicParts[part] = nil
			elseif not part.Anchored and part.CanTouch then
				local d = (part.Position - myPos).Magnitude
				local size = part.Size
				if d <= R + 15 and math.max(size.X, size.Y, size.Z) <= CFG.MAX_PROJECTILE_SIZE
					and part.AssemblyLinearVelocity.Magnitude >= CFG.MIN_PROJECTILE_SPEED
				then
					dynNear[#dynNear + 1] = part
				end
			end
		end
	end

	local modelCache = {}
	for _, part in ipairs(dynNear) do
		if part.Parent and not part.Anchored then
			local d = (part.Position - myPos).Magnitude
			local vel = part.AssemblyLinearVelocity
			local speed = vel.Magnitude
			if d <= R and speed >= CFG.MIN_PROJECTILE_SPEED and vel:Dot(__AD_FN.unit(myPos - part.Position)) >= 4 then
				local touchy = part:FindFirstChildOfClass("TouchTransmitter") ~= nil
				if (touchy or speed >= CFG.FAST_PROJECTILE_SPEED)
					and not __AD_FN.modelFromPart(part, modelCache)
					and not __AD_FN.isMine(part, now)
				then
					list[#list + 1] = __AD_FN.boxThreat(part, vel, d, false)
				end
			end
		end
	end

	-- Детали, которые игра двигает по CFrame (FastCast и т.п.): скорость берём по смещению
	if CFG.CFRAME_PROJECTILES then
		for part, t0 in pairs(youngParts) do
			if not part.Parent or now - t0 > CFG.YOUNG_LIFETIME then
				youngParts[part] = nil
			elseif part.Anchored then
				local d = (part.Position - myPos).Magnitude
				if d <= R then
					local vel = __AD_FN.measuredVel(part, now)
					if vel.Magnitude >= CFG.FAST_PROJECTILE_SPEED
						and vel:Dot(__AD_FN.unit(myPos - part.Position)) >= 4
						and not __AD_FN.isMine(part, now)
					then
						list[#list + 1] = __AD_FN.boxThreat(part, vel, d, false)
					end
				end
			end
		end
	end

	table.sort(list, function(a, b)
		return a.dist < b.dist
	end)
	while #list > CFG.MAX_THREATS do
		table.remove(list)
	end
	return list
end

--==============================================================
-- УПРАВЛЕНИЕ ИГРОКА
--==============================================================

task.spawn(function()
	local ok, module = pcall(function()
		return require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	end)
	if ok and module then
		local ok2, c = pcall(function()
			return module:GetControls()
		end)
		if ok2 then
			controls = c
		end
	end
end)

-- Порядок: стандартные контролы -> атрибут DodgeManualInput (для своего
-- джойстика) -> последнее направление движения до начала уворота.
__AD_FN.getManualDirection = function(now)
	-- Встроенный джойстик MainPanel публикует мировое направление каждый кадр.
	-- Берём его первым, чтобы движение не зависело от внутреннего контроллера Roblox.
	local customInput = LocalPlayer:GetAttribute("DodgeManualInput")
	if typeof(customInput) == "Vector3" and customInput.Magnitude > 0.1 then
		return __AD_FN.unit(__AD_FN.flat(customInput))
	end
	if controls then
		local ok, mv = pcall(function()
			return controls:GetMoveVector()
		end)
		local cam = Workspace.CurrentCamera
		if ok and mv and mv.Magnitude > 0.1 and cam then
			local look = __AD_FN.unit(__AD_FN.flat(cam.CFrame.LookVector))
			local right = __AD_FN.unit(__AD_FN.flat(cam.CFrame.RightVector))
			local d = __AD_FN.unit(right * mv.X + look * (-mv.Z))
			if d.Magnitude > 0.1 then
				return d
			end
		end
	end
	if now - lastManualTime < 0.5 then
		return lastManual
	end
	return Vector3.zero
end

--==============================================================
-- СИМУЛЯЦИЯ
--==============================================================

__AD_FN.marginOf = function(th)
	return th.margin or CFG.MARGIN
end

-- Запас (в студах) между точкой и угрозой через t секунд
__AD_FN.clearanceAt = function(th, point, t)
	if t < th.from or t > th.to then
		return FAR
	end
	local tt = math.min(t, CFG.VEL_TIME_CAP)
	local lp = th.cf:PointToObjectSpace(point - th.vel * tt)

	if th.kind == "ell" then
		local zr = lp.Z < 0 and th.rf or th.rb
		local nx, ny, nz = lp.X / th.rs, lp.Y / th.ry, lp.Z / zr
		local d = math.sqrt(nx * nx + ny * ny + nz * nz)
		return (d - 1) * ((th.rs + zr) * 0.5)
	end

	local h = th.half
	local dx = math.max(math.abs(lp.X) - h.X, 0)
	local dy = math.max(math.abs(lp.Y) - h.Y, 0)
	local dz = math.max(math.abs(lp.Z) - h.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

__AD_FN.totalLag = function()
	return CFG.REACTION_LAG + (CFG.PING_COMP and pingValue or 0)
end

-- Пройденный путь через t секунд (dash = { speed, time } даёт рывок в начале)
__AD_FN.travelAt = function(t, speed, lag, dash)
	local tm = math.max(t - lag, 0)
	if dash then
		local td = math.min(tm, dash.time)
		return td * dash.speed + (tm - td) * speed
	end
	return tm * speed
end

-- lift = { v0, g } для прыжка
__AD_FN.pathClearance = function(dir, myPos, speed, maxTravel, ths, lift, dash)
	local worst, endClear, pen = CAP, CAP, 0
	local lag = __AD_FN.totalLag()
	local t = 0
	while t <= CFG.HORIZON do
		local travel = math.min(__AD_FN.travelAt(t, speed, lag, dash), maxTravel)
		local point = myPos + dir * travel
		if lift then
			local tj = math.max(t - 0.03, 0)
			point += Vector3.new(0, math.max(lift.v0 * tj - 0.5 * lift.g * tj * tj, 0), 0)
		end
		for _, th in ipairs(ths) do
			local c = __AD_FN.clearanceAt(th, point, t) - __AD_FN.marginOf(th)
			if c < worst then
				worst = c
			end
			if c < 0 then
				pen += -c * CFG.STEP -- сколько времени и насколько глубоко внутри угрозы
			end
			if t + CFG.STEP > CFG.HORIZON and c < endClear then
				endClear = c
			end
		end
		t += CFG.STEP
	end
	return worst, endClear, pen
end

__AD_FN.dodgeSpeed = function()
	if CFG.ENABLE_SPEED_BOOST then
		return baseSpeed * (panic and CFG.PANIC_SPEED_MULT or CFG.SPEED_MULT)
	end
	return Humanoid.WalkSpeed
end

-- Возвращает итоговую оценку и худший запас (<0 = заденет)
__AD_FN.scoreDirection = function(dir, myPos, speed, ths, manual, lift, dash)
	local maxTravel = __AD_FN.travelAt(CFG.HORIZON, speed, __AD_FN.totalLag(), dash)
	local score = 0

	if dir.Magnitude > 0.1 then
		local hit = Workspace:Spherecast(myPos, 1.4, dir * CFG.WALL_RAY, rayParams)
		if hit then
			maxTravel = math.min(maxTravel, math.max(hit.Distance - 0.8, 0))
			if hit.Distance < 2.5 then
				score -= 6
			end
		end

		if CFG.LEDGE_CHECK then
			local reach = math.min(maxTravel, dash and 12 or 7)
			for _, f in ipairs({ 0.5, 1 }) do
				local probe = myPos + dir * (reach * f)
				local ground = Workspace:Raycast(probe, Vector3.new(0, -CFG.LEDGE_DEPTH, 0), rayParams)
				if not ground then
					score -= 8
				else
					if ground.Distance > 12 then
						score -= 3 + (ground.Distance - 12) * 0.5
					end
					-- лава / килл-брик под ногами (в том числе огромные, которых нет в угрозах)
					if CFG.DANGER_GROUND_PENALTY > 0 and flaggedParts[ground.Instance] then
						score -= CFG.DANGER_GROUND_PENALTY
					end
				end
			end
		end
	end

	local worst, endClear, pen = __AD_FN.pathClearance(dir, myPos, speed, maxTravel, ths, lift, dash)
	score += worst + endClear * 0.15 - pen * 1.0

	if targetDir.Magnitude > 0.1 and dir.Magnitude > 0.1 then
		score += math.max(dir:Dot(targetDir), 0) * 1.2
	end
	if manual.Magnitude > 0.1 and dir.Magnitude > 0.1 then
		score += dir:Dot(manual) * CFG.MANUAL_BIAS
	end

	return score, worst
end

__AD_FN.jumpParams = function()
	if not Humanoid or Humanoid.FloorMaterial == Enum.Material.Air then
		return nil
	end
	local v0
	if Humanoid.UseJumpPower then
		v0 = Humanoid.JumpPower
	else
		v0 = math.sqrt(2 * Workspace.Gravity * Humanoid.JumpHeight)
	end
	if v0 <= 1 then
		return nil
	end
	return { v0 = v0, g = Workspace.Gravity }
end

-- Возвращает dir, score, worst, wantJump
__AD_FN.chooseDirection = function(myPos, speed, ths, manual, dash)
	local n = perfLow and CFG.LOW_DIRECTIONS or CFG.DIRECTIONS
	local bestDir, bestScore, bestWorst = Vector3.zero, -math.huge, -math.huge

	local function try(dir)
		local s, w = __AD_FN.scoreDirection(dir, myPos, speed, ths, manual, nil, dash)
		if s > bestScore then
			bestDir, bestScore, bestWorst = dir, s, w
		end
	end

	local bestAngle = 0
	for i = 0, n - 1 do
		local a = (i / n) * math.pi * 2
		local before = bestScore
		try(Vector3.new(math.cos(a), 0, math.sin(a)))
		if bestScore > before then
			bestAngle = a
		end
	end
	if manual.Magnitude > 0.1 then
		try(manual)
	end
	-- уточнение вокруг лучшего
	local half = math.pi / n
	for _, d in ipairs({ -half, half }) do
		try(Vector3.new(math.cos(bestAngle + d), 0, math.sin(bestAngle + d)))
	end

	local wantJump = false
	if CFG.JUMP_DODGE and not dash and bestWorst < 0.3 then
		-- прыжок помогает только против низких волн по земле, не против ударов в рост
		local low = {}
		for _, th in ipairs(ths) do
			if th.kind == "box" and th.half.Y <= 1.6 then
				low[#low + 1] = th
			end
		end
		local lift = #low > 0 and __AD_FN.jumpParams() or nil
		if lift then
			local base = __AD_FN.scoreDirection(bestDir, myPos, speed, low, manual)
			local js = __AD_FN.scoreDirection(bestDir, myPos, speed, low, manual, lift)
			local zs = __AD_FN.scoreDirection(Vector3.zero, myPos, speed, low, manual, lift)
			if js - 1 > base or zs - 1 > base then
				wantJump = true
			end
		end
	end

	return bestDir, bestScore, bestWorst, wantJump
end

--==============================================================
-- THINK
--==============================================================

-- Твоя собственная анимация лечения/использования (кэш 0.1 с)
__AD_FN.ownBusyAnimation = function(now)
	if #CFG.BUSY_ANIMATION_WORDS == 0 and next(CFG.BUSY_ANIMATION_IDS) == nil then
		return false
	end
	if now - ownAnim.t < 0.1 then
		return ownAnim.v
	end
	ownAnim.t = now
	local v = false
	local animator = __AD_FN.getAnimator(Humanoid)
	if animator then
		local ok, tracks = pcall(function()
			return animator:GetPlayingAnimationTracks()
		end)
		if ok and tracks then
			for _, tr in ipairs(tracks) do
				if tr.IsPlaying and tr.WeightCurrent >= 0.1 then
					local id = __AD_FN.trackId(tr)
					local anim = tr.Animation
					if (id ~= "" and CFG.BUSY_ANIMATION_IDS[id])
						or __AD_FN.containsWord(tr.Name, CFG.BUSY_ANIMATION_WORDS)
						or (anim ~= nil and __AD_FN.containsWord(anim.Name, CFG.BUSY_ANIMATION_WORDS))
					then
						v = true
						break
					end
				end
			end
		end
	end
	ownAnim.v = v
	return v
end

-- «Занят»: ты сейчас лечишь, колдуешь, жмёшь лечилку и т.п.
__AD_FN.busy = function(now)
	if now < busyUntil or next(toolDown) ~= nil then
		return true
	end
	if LocalPlayer:GetAttribute("DodgeBusy") == true then
		return true
	end
	for _, name in ipairs(CFG.BUSY_ATTRIBUTES) do
		local v = Character:GetAttribute(name)
		if v == nil and Humanoid then
			v = Humanoid:GetAttribute(name)
		end
		if v == true or (type(v) == "number" and v > 0) then
			return true
		end
	end
	return __AD_FN.ownBusyAnimation(now)
end

__AD_FN.paused = function()
	holdPause = false
	if not __AD_FN.isAlive() or not enabled then
		return true
	end
	local now = os.clock()
	if suspendHeld or now < hardPauseUntil or (not CFG.BUSY_ALLOW_PANIC and __AD_FN.busy(now)) then
		holdPause = true
		return true
	end
	for _, name in ipairs(CFG.IMMUNE_ATTRIBUTES) do
		local v = Character:GetAttribute(name)
		if v == nil and Humanoid then
			v = Humanoid:GetAttribute(name)
		end
		if v == true or (type(v) == "number" and v > 0) then
			return true
		end
	end
	if Humanoid.Sit or Humanoid.PlatformStand or Humanoid.WalkSpeed <= 0 then
		return true
	end
	local st = Humanoid:GetState()
	if st == Enum.HumanoidStateType.Dead
		or st == Enum.HumanoidStateType.Ragdoll
		or st == Enum.HumanoidStateType.FallingDown
		or st == Enum.HumanoidStateType.Physics
		or st == Enum.HumanoidStateType.Seated
		or st == Enum.HumanoidStateType.Climbing
	then
		return true
	end
	for _, name in ipairs(CFG.PAUSE_ATTRIBUTES) do
		local v = Character:GetAttribute(name)
		if v == nil and Humanoid then
			v = Humanoid:GetAttribute(name)
		end
		if v == true or (type(v) == "number" and v > 0) then
			return true
		end
	end
	if CFG.SKIP_WITH_FORCEFIELD and Character:FindFirstChildOfClass("ForceField") then
		return true
	end
	return false
end

__AD_FN.think = function(now)
	__AD_FN.updatePing(now)

	if __AD_FN.paused() then
		threats = {}
		active, panic, jumpPlanned = false, false, false
		targetDir = Vector3.zero
		dashUntil, dashWas = 0, false -- стан/рэгдолл: рывок не продолжаем
		return
	end

	local myPos = Root.Position

	if not active then
		local md = __AD_FN.flat(Humanoid.MoveDirection)
		if md.Magnitude > 0.1 then
			lastManual, lastManualTime = __AD_FN.unit(md), now
		end
	end

	threats = __AD_FN.gather(now)

	-- Заденет ли, если я просто стою?
	local tHit, tUrgent = nil, nil
	for _, th in ipairs(threats) do
		local t = 0
		while t <= CFG.HORIZON do
			if __AD_FN.clearanceAt(th, myPos, t) - __AD_FN.marginOf(th) < 0 then
				if not tHit or t < tHit then
					tHit = t
				end
				-- "срочные" угрозы (атака, выстрел, снаряд) включают панику и дэш;
				-- просто прицел или неподвижная зона уворачиваются обычным шагом
				if th.urgent ~= false and (not tUrgent or t < tUrgent) then
					tUrgent = t
				end
				break
			end
			t += CFG.STEP
		end
	end
	lastStats = { threats = #threats, tHit = tHit }

	-- «занят» + BUSY_ALLOW_PANIC: уходим только от удара «прямо сейчас»
	if CFG.BUSY_ALLOW_PANIC and __AD_FN.busy(now) then
		if tUrgent ~= nil and tUrgent <= CFG.PANIC_TIME then
			dodgeUntil = now + 0.15
		end
	elseif tHit and tHit <= CFG.TRIGGER_TIME then
		dodgeUntil = now + CFG.HOLD_TIME
	end

	panic = tUrgent ~= nil and tUrgent <= CFG.PANIC_TIME
	active = #threats > 0 and now < dodgeUntil

	if not active then
		targetDir = Vector3.zero
		panic = false
		return
	end

	local speed = __AD_FN.dodgeSpeed()
	local manual = __AD_FN.getManualDirection(now)
	local commit = panic and CFG.PANIC_COMMIT_TIME or CFG.COMMIT_TIME
	local since = now - lastChoose

	local need = targetDir.Magnitude < 0.1 or since >= commit
	local curScore, curWorst
	if targetDir.Magnitude > 0.1 then
		curScore, curWorst = __AD_FN.scoreDirection(targetDir, myPos, speed, threats, manual)
		if not need and since >= 0.05 and curWorst < 0 then
			need = true
		end
	end

	if need then
		local dir, sc, _, wantJump = __AD_FN.chooseDirection(myPos, speed, threats, manual)
		if curScore and curWorst >= 0 and curScore >= sc - CFG.SWITCH_GAIN then
			dir = targetDir
		end
		if dir.Magnitude > 0.1 then
			targetDir = dir
			lastChoose = now
		end
		jumpPlanned = wantJump
	end

	if jumpPlanned and now - lastJump >= CFG.JUMP_COOLDOWN and Humanoid.FloorMaterial ~= Enum.Material.Air then
		Humanoid.Jump = true
		lastJump = now
		jumpPlanned = false
	end

	-- Дэш: срочная угроза, шагом не уйти, а рывком выходит заметно лучше
	if CFG.DASH_ENABLED and panic and now >= dashUntil and now - lastDash >= CFG.DASH_COOLDOWN
		and now - lastJump > 0.6
		and (CFG.DASH_IN_AIR or Humanoid.FloorMaterial ~= Enum.Material.Air)
		and targetDir.Magnitude > 0.1
	then
		local ns, nw = __AD_FN.scoreDirection(targetDir, myPos, speed, threats, manual)
		if nw < CFG.DASH_NEED then
			local dash = { speed = CFG.DASH_SPEED, time = CFG.DASH_TIME }
			local dd, ds = __AD_FN.chooseDirection(myPos, speed, threats, manual, dash)
			if dd.Magnitude > 0.1 and ds > ns + CFG.DASH_GAIN then
				dashDir = dd
				dashUntil = now + CFG.DASH_TIME
				lastDash = now
				targetDir, curDir, lastChoose = dd, dd, now
				dodgeUntil = math.max(dodgeUntil, dashUntil + 0.12)
				if CFG.DASH_HOOK then
					pcall(CFG.DASH_HOOK, dd, 1 - math.clamp((tUrgent or 0) / CFG.PANIC_TIME, 0, 1))
				end
			end
		end
	end

	if CFG.DEBUG then
		print("[AutoDodge] threats:", #threats, "panic:", panic, "tHit:", tHit)
	end
end

--==============================================================
-- СКОРОСТЬ
--==============================================================

__AD_FN.updateSpeed = function()
	if not CFG.ENABLE_SPEED_BOOST then
		return
	end

	local ws = Humanoid.WalkSpeed

	-- Кто-то другой поменял скорость: принимаем её как базовую
	if boosted and math.abs(ws - lastSet) > 0.01 then
		boosted = false
	end
	if not boosted then
		baseSpeed = ws
	end

	if active then
		local target = baseSpeed * (panic and CFG.PANIC_SPEED_MULT or CFG.SPEED_MULT)
		if math.abs(ws - target) > 0.01 then
			Humanoid.WalkSpeed = target
		end
		lastSet = target
		boosted = true
	elseif boosted then
		Humanoid.WalkSpeed = baseSpeed
		boosted = false
	end
end

--==============================================================
-- ДВИЖЕНИЕ
--==============================================================
-- Направление считается каждый кадр (RenderStep), а Move вызывается
-- ещё и в Stepped: это последний вызов перед физикой, поэтому свой
-- джойстик или другой скрипт не перебьёт уворот.

local finalDir = Vector3.zero

__AD_FN.advanceMovement = function(dt)
	if not __AD_FN.isAlive() then
		finalDir = Vector3.zero
		return
	end

	__AD_FN.updateSpeed()

	if not active or targetDir.Magnitude < 0.1 then
		curDir = Vector3.zero
		finalDir = Vector3.zero
		return
	end

	local smooth = CFG.SMOOTH * (panic and 1.8 or 1)
	local alpha = 1 - math.exp(-smooth * math.clamp(dt, 0, 0.05))

	if curDir.Magnitude < 0.1 then
		curDir = targetDir
	else
		curDir = __AD_FN.unit(curDir:Lerp(targetDir, alpha))
		if curDir.Magnitude < 0.1 then
			curDir = targetDir
		end
	end

	local final = curDir
	if not panic then
		local manual = __AD_FN.getManualDirection(os.clock())
		if manual.Magnitude > 0.1 then
			local blended = __AD_FN.unit(final * (1 - CFG.MANUAL_BLEND) + manual * CFG.MANUAL_BLEND)
			if blended.Magnitude > 0.1 then
				final = blended
			end
		end
	end
	finalDir = final
end

__AD_FN.applyMove = function()
	if not __AD_FN.isAlive() then
		return
	end
	if os.clock() < dashUntil and dashDir.Magnitude > 0.1 and enabled then
		-- рывок: задаём горизонтальную скорость, вертикаль не трогаем
		local v = Root.AssemblyLinearVelocity
		Root.AssemblyLinearVelocity = Vector3.new(dashDir.X * CFG.DASH_SPEED, v.Y, dashDir.Z * CFG.DASH_SPEED)
		Humanoid:Move(dashDir, false)
		dashWas = true
		return
	end
	if dashWas then
		-- конец рывка: плавно возвращаемся к обычной скорости
		dashWas = false
		local v = Root.AssemblyLinearVelocity
		local sp = Humanoid.WalkSpeed
		Root.AssemblyLinearVelocity = Vector3.new(dashDir.X * sp, v.Y, dashDir.Z * sp)
	end
	if finalDir.Magnitude > 0.1 and active then
		Humanoid:Move(finalDir, false)
	end
end

--==============================================================
-- ИНТЕРФЕЙС: кнопка, HUD, отладочный рисунок
--==============================================================

local gui, toggleBtn, hudLabel
local debugFolder, debugPool = nil, {}

local UI_TEXT = {
	ru = { on = "УВОРОТ: ВКЛ", off = "УВОРОТ: ВЫКЛ", pause = "УВОРОТ: ПАУЗА", threats = "угроз", learned = "выучено" },
	en = { on = "DODGE: ON", off = "DODGE: OFF", pause = "DODGE: PAUSED", threats = "threats", learned = "learned" },
}
local TXT
do
	local lang = CFG.LANGUAGE
	if lang == "auto" or UI_TEXT[lang] == nil then
		lang = string.sub(string.lower(LocalPlayer.LocaleId or ""), 1, 2) == "ru" and "ru" or "en"
	end
	TXT = UI_TEXT[lang]
end

__AD_FN.refreshToggle = function()
	if toggleBtn then
		if not enabled then
			toggleBtn.Text = TXT.off
			toggleBtn.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
		elseif holdPause then
			toggleBtn.Text = TXT.pause
			toggleBtn.BackgroundColor3 = Color3.fromRGB(190, 140, 20)
		else
			toggleBtn.Text = TXT.on
			toggleBtn.BackgroundColor3 = Color3.fromRGB(30, 140, 70)
		end
	end
end

__AD_FN.setEnabled = function(v)
	enabled = v and true or false
	if not enabled then
		active, panic, targetDir, curDir, finalDir = false, false, Vector3.zero, Vector3.zero, Vector3.zero
		dashUntil, dashWas = 0, false
	end
	pcall(function()
		LocalPlayer:SetAttribute("AutoDodgeEnabled", enabled)
	end)
	__AD_FN.refreshToggle()
end


--==============================================================
-- API ДЛЯ ИГРЫ: shared.AutoDodge
-- Вызывай из своих клиентских модулей атак (Replicate/*Client),
-- когда знаешь точную зону удара. Тогда скрипт не гадает.
--   AutoDodge.AddBox(cframe, size, duration, delay, opts)
--   AutoDodge.AddSphere(position, radius, duration, delay, opts)
--   AutoDodge.AddRay(origin, direction, length, width, duration, delay, opts)
--   AutoDodge.SetEnabled(bool) / AutoDodge.IsEnabled()
--   AutoDodge.Discover(радиус) -- печатает в Output врагов, теги, атрибуты, анимации и опасные детали рядом
--   AutoDodge.CFG -- таблица настроек: shared.AutoDodge.CFG.MARGIN = 3 меняет на лету
--   AutoDodge.HookRemote(имя или RemoteEvent, function(...) ... end)
--       -- слушает твой ремоут (OnClientEvent); внутри вызывай AddBox/AddSphere/AddRay
--   AutoDodge.DumpLearned() -- печатает выученное в Output, чтобы вставить в LEARNED_SEED/KEYFRAME_SEED
--   AutoDodge.Busy(seconds)  -- «занят» (лечу, колдую): уворот не уводит с места
--   AutoDodge.Pause(seconds) -- жёсткая пауза, AutoDodge.Resume() снимает паузу и «занят»
--   (то же можно через LocalPlayer:SetAttribute("DodgeBusy", true/false))
-- delay = через сколько секунд удар станет опасным (по умолчанию 0)
-- opts  = { velocity = Vector3, urgent = true/false }
--==============================================================
-- Разведка: печатает в Output, что видно вокруг (имена, теги, атрибуты, анимации),
-- чтобы быстро заполнить профиль игры. Вызов: shared.AutoDodge.Discover(радиус)
__AD_FN.discover = function(radius)
	radius = type(radius) == "number" and radius or 60
	if not __AD_FN.isAlive() then
		print("[AutoDodge] Discover: нет живого персонажа")
		return
	end
	local myPos = Root.Position
	local L = { string.format("===== AutoDodge Discover (радиус %d) =====", radius) }
	local function add(fmt, ...)
		L[#L + 1] = string.format(fmt, ...)
	end
	local function attrs(inst, label)
		for k, v in pairs(inst:GetAttributes()) do
			add("   атрибут %s: %s = %s", label, tostring(k), tostring(v))
		end
	end

	local found = 0
	for actor in pairs(humanoids) do
		local model = actor.Parent
		local root = model and model ~= Character and __AD_FN.getRoot(model)
		if root then
			local d = (root.Position - myPos).Magnitude
			if d <= radius then
				found += 1
				add("[%s] %s (%s) %.0f studs", actor.ClassName, model.Name,
					Players:GetPlayerFromCharacter(model) and "игрок" or "моб", d)
				local tags = CollectionService:GetTags(model)
				if #tags > 0 then
					add("   теги: %s", table.concat(tags, ", "))
				end
				attrs(model, "модели")
				attrs(actor, actor.ClassName)
				attrs(root, "корня")
				local tool = model:FindFirstChildOfClass("Tool")
				if tool then
					add("   предмет: %s (дальний бой: %s)", tool.Name, __AD_FN.isRangedTool(tool, os.clock()) and "да" or "нет")
					attrs(tool, "предмета")
				end
				local animator = __AD_FN.getAnimator(actor)
				if animator then
					local ok, tracks = pcall(function()
						return animator:GetPlayingAnimationTracks()
					end)
					if ok and tracks then
						for _, tr in ipairs(tracks) do
							if tr.IsPlaying then
								local id = __AD_FN.trackId(tr)
								local hitText = ""
								local hits = __AD_FN.hitTimesFor(id)
								if hits then
									local parts = {}
									for _, h in ipairs(hits) do
										parts[#parts + 1] = string.format("%.2f", h)
									end
									hitText = "  удары: " .. table.concat(parts, ", ")
								end
								add("   анимация: %s | %s | prio=%s len=%.2f loop=%s | вид=%s%s",
									tr.Name, id, tr.Priority.Name, tr.Length, tostring(tr.Looped),
									tostring(__AD_FN.classifyTrack(tr)), hitText)
							end
						end
					end
				end
			end
		end
	end

	local fc, shown = 0, 0
	for part in pairs(flaggedParts) do
		if part.Parent and (part.Position - myPos).Magnitude <= radius then
			fc += 1
			if shown < 10 then
				shown += 1
				add("[опасная деталь] %s  %.0fx%.0fx%.0f", part:GetFullName(), part.Size.X, part.Size.Y, part.Size.Z)
			end
		end
	end
	add("врагов рядом: %d, опасных деталей рядом: %d (показано %d)", found, fc, shown)
	attrs(Character, "моего персонажа")
	print(table.concat(L, "\n"))
end

__AD_FN.pushManual = function(m, delay, duration, opts)
	local now = os.clock()
	m.startT = now + (delay or 0)
	m.endT = m.startT + math.max(duration or 0.3, 0.05)
	m.vel = opts and opts.velocity or Vector3.zero
	m.urgent = not (opts and opts.urgent == false)
	if #manualThreats >= 40 then
		table.remove(manualThreats, 1)
	end
	manualThreats[#manualThreats + 1] = m
end

shared.AutoDodge = {
	AddBox = function(cf, size, duration, delay, opts)
		if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
			return
		end
		local half = size * 0.5
		__AD_FN.pushManual({ kind = "box", cf = cf, half = half, reach = math.max(half.X, half.Y, half.Z) }, delay, duration, opts)
	end,
	AddSphere = function(pos, radius, duration, delay, opts)
		if typeof(pos) ~= "Vector3" or type(radius) ~= "number" then
			return
		end
		__AD_FN.pushManual({
			kind = "ell", cf = CFrame.new(pos),
			rf = radius, rb = radius, rs = radius, ry = math.max(radius, 3), reach = radius,
		}, delay, duration, opts)
	end,
	AddRay = function(origin, direction, length, width, duration, delay, opts)
		if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 0.01 then
			return
		end
		length = length or 100
		width = width or 2.5
		local dir = direction.Unit
		local center = origin + dir * (length * 0.5)
		__AD_FN.pushManual({
			kind = "box", cf = CFrame.lookAt(center, center + dir),
			half = Vector3.new(width, 4, length * 0.5), reach = length * 0.5,
		}, delay, duration, opts)
	end,
	Busy = function(seconds)
		busyUntil = math.max(busyUntil, os.clock() + (type(seconds) == "number" and seconds or 0.5))
	end,
	Pause = function(seconds)
		hardPauseUntil = os.clock() + (type(seconds) == "number" and seconds or 0.5)
	end,
	Resume = function()
		hardPauseUntil, busyUntil = 0, 0
	end,
	Discover = __AD_FN.discover,
	CFG = CFG,
	HookRemote = function(remote, handler)
		if type(handler) ~= "function" then
			return
		end
		task.spawn(function()
			if type(remote) == "string" then
				local rs = game:GetService("ReplicatedStorage")
				local name, t0 = remote, os.clock()
				remote = nil
				while not remote and os.clock() - t0 < 15 do
					remote = rs:FindFirstChild(name, true)
					if not remote then
						task.wait(0.5)
					end
				end
			end
			if typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
				table.insert(rootConns, remote.OnClientEvent:Connect(function(...)
					local ok, err = pcall(handler, ...)
					if not ok then
						warn("[AutoDodge] HookRemote:", err)
					end
				end))
			end
		end)
	end,
	DumpLearned = function()
		local out = { "-- AutoDodge: вставь в профиль игры (PROFILES[PlaceId])", "LEARNED_SEED = {" }
		for id, rec in pairs(learned) do
			out[#out + 1] = string.format('\t["%s"] = { n = %d, hitAt = %.2f },', id, rec.n, rec.hitAt)
		end
		out[#out + 1] = "},"
		out[#out + 1] = "KEYFRAME_SEED = {"
		for id, rec in pairs(kfLive) do
			local parts = {}
			for _, h in ipairs(rec.hits) do
				parts[#parts + 1] = string.format("%.2f", h)
			end
			out[#out + 1] = string.format('\t["%s"] = { %s },', id, table.concat(parts, ", "))
		end
		out[#out + 1] = "},"
		print(table.concat(out, "\n"))
	end,
	SetEnabled = function(v)
		__AD_FN.setEnabled(v)
	end,
	IsEnabled = function()
		return enabled
	end,
}

-- Соединяем API с переключателем в MainPanel и применяем исходное состояние.
AutoDodgeController = shared.AutoDodge
autoDodgeApi = shared.AutoDodge
pcall(function()
	AutoDodgeController.SetEnabled(dodgeEnabledWanted)
end)
if refreshDodgeToggle then
	pcall(refreshDodgeToggle)
end

-- Смещение кнопки так, чтобы она не выходила за экран
__AD_FN.clampOffset = function(off, scale, view, size)
	local lo = -scale * view
	local hi = math.max(view - size, 0) + lo
	return math.clamp(off, lo, hi)
end

__AD_FN.buildGui = function()
	if not CFG.TOGGLE_BUTTON and not CFG.DEBUG_HUD then
		return
	end
	local pg = LocalPlayer:WaitForChild("PlayerGui", 10)
	if not pg then
		return
	end
	gui = Instance.new("ScreenGui")
	gui.Name = "AutoDodgeGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = pg

	if CFG.TOGGLE_BUTTON then
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromOffset(128, 34)
		btn.Position = UDim2.new(0, 12, 0.32, 0)
		btn.AutoButtonColor = false
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 14
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.BackgroundTransparency = 0.15
		btn.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = btn
		toggleBtn = btn
		__AD_FN.refreshToggle()

		local dragging, moved, dragStart, startPos, dragInput = false, false, Vector2.zero, btn.Position, nil
		local function isPointer(input)
			return input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
		end
		table.insert(rootConns, btn.InputBegan:Connect(function(input)
			if isPointer(input) then
				dragging, moved = true, false
				dragInput = input
				dragStart = Vector2.new(input.Position.X, input.Position.Y)
				startPos = btn.Position
			end
		end))
		table.insert(rootConns, UserInputService.InputChanged:Connect(function(input)
			if dragging and dragInput and (input == dragInput
				or (input.UserInputType == Enum.UserInputType.MouseMovement
					and dragInput.UserInputType == Enum.UserInputType.MouseButton1))
			then
				local d = Vector2.new(input.Position.X, input.Position.Y) - dragStart
				if d.Magnitude > 8 then
					moved = true
				end
				if moved then
					local view, size = gui.AbsoluteSize, btn.AbsoluteSize
					btn.Position = UDim2.new(
						startPos.X.Scale, __AD_FN.clampOffset(startPos.X.Offset + d.X, startPos.X.Scale, view.X, size.X),
						startPos.Y.Scale, __AD_FN.clampOffset(startPos.Y.Offset + d.Y, startPos.Y.Scale, view.Y, size.Y)
					)
				end
			end
		end))
		table.insert(rootConns, UserInputService.InputEnded:Connect(function(input)
			if dragging and input == dragInput then
				dragging = false
				dragInput = nil
				if not moved then
					__AD_FN.setEnabled(not enabled)
				end
			end
		end))
	end

	if CFG.DEBUG_HUD then
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromOffset(260, 70)
		l.Position = UDim2.new(0, 12, 0.32, 40)
		l.BackgroundColor3 = Color3.new(0, 0, 0)
		l.BackgroundTransparency = 0.5
		l.TextColor3 = Color3.new(1, 1, 1)
		l.Font = Enum.Font.Code
		l.TextSize = 13
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Top
		l.Parent = gui
		hudLabel = l
	end
end

__AD_FN.updateHud = function()
	if hudLabel then
		hudLabel.Text = string.format(
			"%s | " .. TXT.threats .. ": %d\nactive: %s panic: %s\ntHit: %s\n" .. TXT.learned .. ": %d%s",
			enabled and "ON" or "OFF", lastStats.threats, tostring(active), tostring(panic),
			lastStats.tHit and string.format("%.2f", lastStats.tHit) or "-",
			(function()
				local c = 0
				for _ in pairs(learned) do c += 1 end
				return c
			end)(),
			lastError ~= "" and ("\nERR: " .. string.sub(lastError, 1, 60)) or ""
		)
	end
end

__AD_FN.updateDraw = function()
	if not CFG.DEBUG_DRAW then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if not debugFolder or not debugFolder.Parent then
		debugFolder = Instance.new("Folder")
		debugFolder.Name = "AutoDodgeDebug"
		debugFolder.Parent = cam
		debugPool = {}
	end
	for i = 1, math.max(#threats, #debugPool) do
		local th = threats[i]
		local p = debugPool[i]
		if th and not p then
			p = Instance.new("Part")
			p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
			p.Material = Enum.Material.Neon
			p.Transparency = 0.65
			local m = Instance.new("SpecialMesh")
			m.Parent = p
			p.Parent = debugFolder
			debugPool[i] = p
		end
		if p then
			if th then
				local mesh = p:FindFirstChildOfClass("SpecialMesh")
				if th.kind == "ell" then
					p.Size = Vector3.new(th.rs * 2, th.ry * 2, th.rf + th.rb)
					p.CFrame = th.cf * CFrame.new(0, 0, -(th.rf - th.rb) / 2)
					if mesh then mesh.MeshType = Enum.MeshType.Sphere end
				else
					p.Size = th.half * 2
					p.CFrame = th.cf
					if mesh then mesh.MeshType = Enum.MeshType.Brick end
				end
				p.Color = th.from <= 0.05 and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(255, 200, 50)
				p.Transparency = 0.65
			else
				p.Transparency = 1
			end
		end
	end
end

--==============================================================
-- ПЕРСОНАЖ
--==============================================================

__AD_FN.resetState = function()
	threats = {}
	active, panic, jumpPlanned = false, false, false
	targetDir, curDir, finalDir = Vector3.zero, Vector3.zero, Vector3.zero
	dodgeUntil, lastChoose, lastThink = 0, 0, 0
	dashUntil, dashWas = 0, false
end

__AD_FN.disconnectList = function(list)
	for _, c in ipairs(list) do
		if c.Connected then
			c:Disconnect()
		end
	end
	table.clear(list)
end

__AD_FN.setupCharacter = function(char)
	__AD_FN.disconnectList(charConns)

	Character = char
	Humanoid = nil
	Root = nil
	__AD_FN.resetState()
	boosted = false

	local hum = char:WaitForChild("Humanoid", 10)
	local root = char:WaitForChild("HumanoidRootPart", 10)

	if Character ~= char or not hum or not root then
		return
	end

	Humanoid = hum
	Root = root
	baseSpeed = hum.WalkSpeed

	rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { char }
	rayParams.IgnoreWater = true
	rayParams.RespectCanCollide = true

	-- предметы-лечилки: пока зажата кнопка, ты «занят»
	table.clear(toolDown)
	local hooked = {}
	local function hookTool(tool)
		if not tool:IsA("Tool") or hooked[tool] or not __AD_FN.containsWord(tool.Name, CFG.BUSY_TOOL_WORDS) then
			return
		end
		hooked[tool] = true
		local function release()
			if toolDown[tool] then
				toolDown[tool] = nil
				busyUntil = math.max(busyUntil, os.clock() + CFG.BUSY_TAIL)
			end
		end
		table.insert(charConns, tool.Activated:Connect(function()
			toolDown[tool] = true
		end))
		table.insert(charConns, tool.Deactivated:Connect(release))
		table.insert(charConns, tool.Unequipped:Connect(release))
	end
	for _, child in ipairs(char:GetChildren()) do
		hookTool(child)
	end
	table.insert(charConns, char.ChildAdded:Connect(hookTool))

	local lastHealth = hum.Health
	table.insert(charConns, hum.HealthChanged:Connect(function(h)
		if h < lastHealth - 0.5 and Root then
			pcall(__AD_FN.learnFromHit, Root.Position)
		end
		lastHealth = h
	end))

	table.insert(charConns, hum.Died:Connect(function()
		if boosted then
			hum.WalkSpeed = baseSpeed
			boosted = false
		end
		__AD_FN.resetState()
	end))
end

--==============================================================
-- ЗАПУСК
--==============================================================

-- предзаполнение из профиля/настроек
for id, rec in pairs(CFG.LEARNED_SEED or {}) do
	if type(rec) == "table" and type(rec.hitAt) == "number" then
		learned[id] = { n = rec.n or 1, hitAt = rec.hitAt }
	end
end
for id, hits in pairs(CFG.KEYFRAME_SEED or {}) do
	if type(hits) == "table" and #hits > 0 then
		kfInfo[id] = { hits = hits, src = "seed" }
	end
end

if CFG.ENABLED then
	pcall(function()
		LocalPlayer:SetAttribute("AutoDodgeEnabled", enabled)
	end)
	table.insert(rootConns, LocalPlayer:GetAttributeChangedSignal("AutoDodgeEnabled"):Connect(function()
		local v = LocalPlayer:GetAttribute("AutoDodgeEnabled")
		if type(v) == "boolean" and v ~= enabled then
			__AD_FN.setEnabled(v)
		end
	end))

	table.insert(rootConns, UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and CFG.TOGGLE_KEY and input.KeyCode == CFG.TOGGLE_KEY then
			__AD_FN.setEnabled(not enabled)
		end
	end))

	task.spawn(function()
		local ok, err = pcall(__AD_FN.buildGui)
		if not ok then
			warn("[AutoDodge] интерфейс не создан:", err)
		end
	end)

	__AD_FN.startRegistries()

	if CFG.SUSPEND_KEY then
		table.insert(rootConns, UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and input.KeyCode == CFG.SUSPEND_KEY then
				suspendHeld = true
			end
		end))
		table.insert(rootConns, UserInputService.InputEnded:Connect(function(input)
			if input.KeyCode == CFG.SUSPEND_KEY then
				suspendHeld = false
			end
		end))
		table.insert(rootConns, UserInputService.WindowFocusReleased:Connect(function()
			suspendHeld = false
		end))
	end

	table.insert(rootConns, LocalPlayer.CharacterRemoving:Connect(function(char)
		if Character ~= char then
			return
		end
		__AD_FN.disconnectList(charConns)
		if Humanoid and boosted then
			pcall(function()
				Humanoid.WalkSpeed = baseSpeed
			end)
		end
		Character, Humanoid, Root, rayParams = nil, nil, nil, nil
		boosted = false
		__AD_FN.resetState()
	end))
	table.insert(rootConns, LocalPlayer.CharacterAdded:Connect(__AD_FN.setupCharacter))
	if LocalPlayer.Character then
		task.spawn(__AD_FN.setupCharacter, LocalPlayer.Character)
	end

	table.insert(rootConns, RunService.Heartbeat:Connect(function()
		if not __AD_FN.isAlive() or not rayParams then
			return
		end

		local now = os.clock()
		-- небольшой допуск, чтобы при 60 FPS think шёл ровно каждый 2-й кадр (30 Гц)
		if now - lastThink < (perfLow and CFG.LOW_THINK_RATE or CFG.THINK_RATE) - 0.004 then
			return
		end
		lastThink = now

		local ok, err = pcall(__AD_FN.think, now)
		if CFG.ADAPTIVE_PERF then
			thinkAvg = thinkAvg * 0.9 + (os.clock() - now) * 1000 * 0.1
			if not perfLow and thinkAvg > CFG.PERF_BUDGET_MS then
				perfLow = true
			elseif perfLow and thinkAvg < CFG.PERF_BUDGET_MS * 0.4 then
				perfLow = false
			end
		end
		if not ok then
			local msg = tostring(err)
			if msg ~= lastError then
				lastError = msg
				warn("[AutoDodge] ошибка:", msg)
			end
		end
		pcall(__AD_FN.updateDraw)
		pcall(__AD_FN.updateHud)
		if holdPause ~= shownPause then
			shownPause = holdPause
			__AD_FN.refreshToggle()
		end
	end))

	table.insert(rootConns, RunService.Stepped:Connect(__AD_FN.applyMove))

	pcall(function()
		RunService:UnbindFromRenderStep("AutoDodgeMove")
	end)
	RunService:BindToRenderStep("AutoDodgeMove", Enum.RenderPriority.Last.Value, function(dt)
		__AD_FN.advanceMovement(dt)
		__AD_FN.applyMove()
	end)
end

local autoDodgeCleaned = false
__AD_FN.cleanupAutoDodge = function()
	if autoDodgeCleaned then
		return
	end
	autoDodgeCleaned = true
	pcall(function()
		RunService:UnbindFromRenderStep("AutoDodgeMove")
	end)
	if Humanoid and boosted then
		pcall(function()
			Humanoid.WalkSpeed = baseSpeed
		end)
	end
	boosted = false
	if gui then
		pcall(function() gui:Destroy() end)
	end
	if debugFolder then
		pcall(function() debugFolder:Destroy() end)
	end
	pcall(function()
		LocalPlayer:SetAttribute("DodgeManualInput", Vector3.zero)
	end)
	__AD_FN.disconnectList(charConns)
	__AD_FN.disconnectList(rootConns)
	if shared.AutoDodge == autoDodgeApi then
		shared.AutoDodge = nil
	end
	if shared.__MergedMainPanelAutoDodgeCleanup == __AD_FN.cleanupAutoDodge then
		shared.__MergedMainPanelAutoDodgeCleanup = nil
	end
end

shared.__MergedMainPanelAutoDodgeCleanup = __AD_FN.cleanupAutoDodge
script.Destroying:Connect(__AD_FN.cleanupAutoDodge)
end

runMergedAutoDodge()
