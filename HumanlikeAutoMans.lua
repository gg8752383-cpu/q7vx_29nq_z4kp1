--==============================================================
-- SURVIVAL AI v1.0 — "Пирожок: Мастер мансов PRO"
-- LocalScript -> StarterPlayer > StarterPlayerScripts
-- Changes in v1.0 (on top of v0.9 pro-movement layer):
--   * CLUTCH DODGE: CPA (closest point of approach) prediction —
--     the character sidesteps at the LAST possible moment, exactly
--     like a pro dodging a chase, and picks the side with more room.
--   * OPEN SPACE MAP: a cached 12-ray openness ring around the
--     character; scoring now prefers wide-open escape routes, so the
--     bot stops cornering itself against walls.
--   * ANTI-PARALLEL penalty: never runs in the same direction as a
--     faster chaser — cuts across their line instead (real kiting).
--   * WALL SLIDE fallback: when every direction is blocked, slides
--     along the wall tangent toward the safest side instead of freezing.
--   * SPRING SMOOTHING: second-order critically-damped steering with
--     substeps — acceleration/turns look human, not lerpy-robotic.
--   * PANIC ADAPTATION: taking damage near threats temporarily boosts
--     juke frequency, serpentine amplitude and jump-dodges ("full mans").
--   * PATH CORNER BLEND: arcs through route waypoints instead of
--     snapping sharply at every corner.
-- Inherited from v0.9:
--   * Serpentine dual-harmonic run, orbit strafing, juke feints with
--     counter-flip, cooldown-gated jump-dodges, snappier juke turns.
-- Inherited from v0.8:
--   * Compact rounded-square toggle (tap center, drag edges).
--   * Self-repairing GUI, remembered position, owner token.
--   * Heartbeat planning / lightweight RenderStep Move().
--   * Bounded threat tracking, async pathfinding fallback, stuck logic.
-- Important:
--   * Reactive client-side controller; not omniscient.
--   * LocalScript controls movement only while a threat is active.
--   * Pathfinding requires walkable/navmesh space in the place.
--==============================================================
--==============================================================
-- SERVICES
--==============================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local OWNER_ATTRIBUTE = "SurvivalAI_PirozhokOwner"
local OWNER_TOKEN = tostring(os.clock()) .. "_" .. tostring(
    Random.new():NextInteger(100000, 999999999)
)
PlayerScripts:SetAttribute(OWNER_ATTRIBUTE, OWNER_TOKEN)
--==============================================================
-- CONFIGURATION
--==============================================================
local CONFIG = {
    START_ENABLED = true,
    TOGGLE_KEY = Enum.KeyCode.G,
    DETECTION_RADIUS = 68,
    FLEE_RADIUS = 43,
    FAST_APPROACH_SPEED = 7.5,
    EMERGENCY_DISTANCE = 12,
    EMERGENCY_CLOSING_SPEED = 12,
    EMERGENCY_CLOSING_DISTANCE = 21,
    EMERGENCY_TIME_TO_CONTACT = 0.68,
    EMERGENCY_TTC_MAX_DISTANCE = 30,
    SCAN_INTERVAL = 0.19,
    THINK_INTERVAL = 0.13,
    DIRECTION_COUNT = 8,
    PRECISE_DIRECTION_COUNT = 4,
    MAX_THREATS_TO_CONSIDER = 12,
    MAX_TRACKED_THREATS = 32,
    PROBE_DISTANCE = 10,
    LOOK_AHEAD_DISTANCE = 10,
    SIDE_PROBE_OFFSET = 1.35,
    MAX_SAFE_DROP = 5.5,
    MAX_STEP_UP = 5.5,
    PREDICTION_TIME = 0.60,
    TURN_RESPONSE = 10,
    EMERGENCY_TURN_RESPONSE = 20,
    INERTIA_WEIGHT = 0.22,
    LOW_HEALTH_RATIO = 0.30,
    WEAVE_STRENGTH = 0.20,
    WEAVE_SWITCH_MIN = 0.80,
    WEAVE_SWITCH_MAX = 1.35,
    WEAVE_FREQUENCY = 2.6,
    TACTICAL_SIDE_STEP_STRENGTH = 0.72,
    STUCK_CHECK_INTERVAL = 0.90,
    STUCK_MIN_PROGRESS = 0.65,
    STUCK_SPEED_LIMIT = 2.0,
    STUCK_PENALTY_TIME = 1.45,
    PATHFINDING_ENABLED = true,
    AVOID_WATER = true,
    PATH_RETRY_INTERVAL = 1.70,
    PATH_GOAL_DISTANCE = 34,
    PATH_START_DRIFT_LIMIT = 8,
    PATH_CANDIDATES = 4,
    PATH_AGENT_RADIUS = 2,
    PATH_AGENT_HEIGHT = 5,
    PATH_AGENT_CAN_JUMP = true,
    PATH_AGENT_CAN_CLIMB = true,
    PATH_WAYPOINT_SPACING = 4,
    PATH_REACHED_DISTANCE = 3.5,
    PATH_JUMP_TRIGGER_DISTANCE = 8,
    --==========================================================
    -- PRO-PLAYER MOVEMENT LAYER (v0.9)
    -- Direction changes only; WalkSpeed is never modified.
    --==========================================================
    JUKE_ENABLED = true,
    JUKE_MIN_INTERVAL = 1.5,
    JUKE_MAX_INTERVAL = 3.3,
    JUKE_DURATION_MIN = 0.16,
    JUKE_DURATION_MAX = 0.34,
    JUKE_REVERSE_CHANCE = 0.22,
    JUKE_TRIGGER_MAX_DISTANCE = 30,
    JUKE_EMERGENCY_BIAS = 0.35,
    JUKE_TURN_RESPONSE = 15,
    STRAFE_ENABLED = true,
    STRAFE_DISTANCE_MIN = 14,
    STRAFE_DISTANCE_MAX = 34,
    STRAFE_WEIGHT = 0.55,
    STRAFE_SIDE_FLIP_MIN = 1.1,
    STRAFE_SIDE_FLIP_MAX = 2.2,
    SERPENTINE_ENABLED = true,
    SERPENTINE_BASE_AMPLITUDE = 0.26,
    SERPENTINE_SECOND_HARMONIC = 0.13,
    SERPENTINE_FREQ_MIN = 1.9,
    SERPENTINE_FREQ_MAX = 3.1,
    SERPENTINE_FREQ_CHANGE_MIN = 2.2,
    SERPENTINE_FREQ_CHANGE_MAX = 4.4,
    JUMP_DODGE_ENABLED = true,
    JUMP_DODGE_COOLDOWN_MIN = 0.9,
    JUMP_DODGE_COOLDOWN_MAX = 2.3,
    JUMP_DODGE_TRIGGER_DISTANCE = 26,
    JUMP_DODGE_CHANCE = 0.45,
    --==========================================================
    -- CLUTCH DODGE (v1.0): last-moment CPA sidestep
    --==========================================================
    CLUTCH_DODGE_ENABLED = true,
    CLUTCH_CPA_TIME_MIN = 0.12,
    CLUTCH_CPA_TIME_MAX = 0.55,
    CLUTCH_CPA_DISTANCE = 8.0,
    CLUTCH_DODGE_DURATION = 0.26,
    CLUTCH_DODGE_COOLDOWN = 0.75,
    CLUTCH_CHECK_INTERVAL = 0.05,
    CLUTCH_TURN_RESPONSE = 18,
    CLUTCH_ESCAPE_BLEND = 0.30,
    --==========================================================
    -- OPEN SPACE MAP (v1.0): anti-cornering
    --==========================================================
    OPENNESS_ENABLED = true,
    OPENNESS_RAYS = 12,
    OPENNESS_PROBE_DISTANCE = 14,
    OPENNESS_REFRESH_INTERVAL = 0.32,
    OPENNESS_SCORE_WEIGHT = 0.55,
    ANTI_PARALLEL_WEIGHT = 0.45,
    WALL_SLIDE_ENABLED = true,
    --==========================================================
    -- SPRING SMOOTHING (v1.0): human-like steering
    --==========================================================
    SPRING_SMOOTHING_ENABLED = true,
    SPRING_DAMPING_RATIO = 1.0,
    --==========================================================
    -- PANIC ADAPTATION (v1.0): got hit -> play harder briefly
    --==========================================================
    PANIC_ENABLED = true,
    PANIC_HEALTH_DROP = 1,
    PANIC_DURATION = 3.0,
    PANIC_JUKE_SPEEDUP = 0.5,
    PANIC_SERPENTINE_BOOST = 1.6,
    PANIC_JUMP_BOOST = 1.4,
    --==========================================================
    -- PATH CORNER BLEND (v1.0)
    --==========================================================
    PATH_CORNER_BLEND_DISTANCE = 6,
    DEBUG = false,
}
--==============================================================
-- STATE
--==============================================================
local enabled = CONFIG.START_ENABLED
local alive = false
local character
local humanoid
local rootPart
local raycastParams
local threats = {}
local activeThreatsCache = {}
local candidateModels = {}
local selectedDirection = Vector3.zero
local plannedDirection = Vector3.zero
local commandDirection = Vector3.zero
local commandVelocity = Vector3.zero
local lastKnownGroundY = nil
local lastScan = 0
local lastThink = 0
local lastStatus = "Ожидание"
local lastGuiText = ""
local stuckStatusUntil = 0
local lastProgressCheck = 0
local progressPosition
local stuckDirection = Vector3.zero
local stuckUntil = 0
local weaveSign = 1
local nextWeaveFlip = 0
local weavePhase = Random.new():NextNumber(0, math.pi * 2)
local randomGenerator = Random.new()
-- Pro-movement state (v0.9)
local jukeRandom = Random.new()
local nextJukeAt = 0
local jukeActiveUntil = 0
local jukeCounterAt = 0
local jukeCountered = false
local jukePendingSide = 1
local jukeIsReverse = false
local strafeSide = 1
local nextStrafeFlip = 0
local serpentineFrequency = 2.4
local nextSerpentineFrequencyChange = 0
local nextJumpDodgeAt = 0
-- v1.0 state
local openness = {}
local opennessTime = -math.huge
local lastHealthValue
local panicUntil = 0
local panicMode = false
local lastClutchDodge = 0
local lastClutchCheck = 0
local clutchActiveUntil = 0
local clutchDirection = Vector3.zero
local activePath
local activePathBlockedConnection
local pathWaypoints = {}
local pathIndex = 2
local pathGoal
local lastPathJumpIndex = -1
local pathNeedsReplan = false
local pathRequestInFlight = false
local lastPathRequest = -math.huge
local pathRequestGeneration = 0
local characterGeneration = 0
local generalConnections = {}
local characterConnections = {}
local shuttingDown = false
local wasControllingMovement = false
--==============================================================
-- UTILITIES
--==============================================================
local function disconnectAll(list)
    for _, connection in ipairs(list) do
        if connection then
            connection:Disconnect()
        end
    end
    table.clear(list)
end
local function horizontal(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end
local function unitOrZero(vector)
    vector = horizontal(vector)
    if vector.Magnitude < 0.001 then
        return Vector3.zero
    end
    return vector.Unit
end
local function clampHorizontal(vector, maxMagnitude)
    vector = horizontal(vector)
    local magnitude = vector.Magnitude
    if magnitude > maxMagnitude and magnitude > 0 then
        return vector.Unit * maxMagnitude
    end
    return vector
end
local function getCharacterParts(model)
    if not model or not model:IsA("Model") or model == character then
        return nil, nil
    end
    local otherHumanoid = model:FindFirstChildOfClass("Humanoid")
    local otherRoot = model:FindFirstChild("HumanoidRootPart")
    if not otherRoot and otherHumanoid then
        otherRoot = otherHumanoid.RootPart
    end
    if not otherHumanoid or not otherRoot then
        return nil, nil
    end
    if otherHumanoid.Health <= 0 or not otherRoot:IsA("BasePart") then
        return nil, nil
    end
    return otherHumanoid, otherRoot
end
local function rebuildRaycastParams()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = character and { character } or {}
    params.IgnoreWater = not CONFIG.AVOID_WATER
    params.RespectCanCollide = true
    raycastParams = params
end
local function setStatus(status)
    if status and status ~= lastStatus then
        lastStatus = status
        lastGuiText = ""
    end
end
local function getHealthRatio()
    if not humanoid then
        return 1
    end
    return humanoid.Health / math.max(humanoid.MaxHealth, 1)
end
local function canCharacterJump()
    if not humanoid or not humanoid.Parent then
        return false
    end
    if not humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
        return false
    end
    if humanoid.UseJumpPower then
        return humanoid.JumpPower > 0
    end
    return humanoid.JumpHeight > 0
end
local function resetProMovementState()
    nextJukeAt = 0
    jukeActiveUntil = 0
    jukeCounterAt = 0
    jukeCountered = false
    jukePendingSide = 1
    jukeIsReverse = false
    nextStrafeFlip = 0
    nextSerpentineFrequencyChange = 0
    nextJumpDodgeAt = 0
    commandVelocity = Vector3.zero
    lastHealthValue = nil
    panicUntil = 0
    panicMode = false
    lastClutchDodge = 0
    lastClutchCheck = 0
    clutchActiveUntil = 0
    clutchDirection = Vector3.zero
    table.clear(openness)
    opennessTime = -math.huge
end
--==============================================================
-- SELF-REPAIRING DRAGGABLE GUI
--==============================================================
local UI_GUI_NAME = "SurvivalAI_Pirozhok"
local UI_BUTTON_SIZE = 64
local UI_EDGE_SIZE = 12
local UI_DRAG_THRESHOLD = 5
local UI_SCREEN_MARGIN = 5
local UI_REPAIR_INTERVAL = 0.45
local screenGui
local canvas
local buttonRoot
local toggleButton
local dragHandles = {}
local buttonPosition
local dragState
local activeTouches = {}
local guiConnections = {}
local rebuildingGui = false
local setEnabled
local updateGui
local ensureGui
local oldGui = PlayerGui:FindFirstChild(UI_GUI_NAME)
if oldGui then
    oldGui:Destroy()
end
local function clampButtonPosition(position)
    if not canvas or canvas.AbsoluteSize.X <= 0 or canvas.AbsoluteSize.Y <= 0 then
        return position
    end
    local half = UI_BUTTON_SIZE * 0.5
    local usable = canvas.AbsoluteSize
    local minX = math.min(half + UI_SCREEN_MARGIN, usable.X * 0.5)
    local minY = math.min(half + UI_SCREEN_MARGIN, usable.Y * 0.5)
    local maxX = math.max(minX, usable.X - half - UI_SCREEN_MARGIN)
    local maxY = math.max(minY, usable.Y - half - UI_SCREEN_MARGIN)
    return Vector2.new(
        math.clamp(position.X, minX, maxX),
        math.clamp(position.Y, minY, maxY)
    )
end
local function applyButtonPosition(position)
    if not canvas or not buttonRoot then
        buttonPosition = position
        return
    end
    position = clampButtonPosition(position)
    buttonPosition = position
    buttonRoot.Position = UDim2.fromOffset(position.X, position.Y)
end
local function initializeOrClampPosition()
    if not canvas or canvas.AbsoluteSize.X <= 0 or canvas.AbsoluteSize.Y <= 0 then
        return
    end
    if not buttonPosition then
        buttonPosition = Vector2.new(
            canvas.AbsoluteSize.X - (UI_BUTTON_SIZE * 0.5 + 14),
            canvas.AbsoluteSize.Y * 0.46
        )
    end
    applyButtonPosition(buttonPosition)
end
updateGui = function()
    if not toggleButton or not toggleButton.Parent then
        return
    end
    toggleButton.Text = enabled and "AI\nON" or "AI\nOFF"
    toggleButton.BackgroundColor3 = enabled
        and Color3.fromRGB(42, 112, 75)
        or Color3.fromRGB(39, 43, 51)
    toggleButton.TextColor3 = Color3.fromRGB(248, 248, 250)
    local stateText = enabled
        and (lastStatus .. " | угроз: " .. tostring(#activeThreatsCache))
        or "Выключен — обычное управление"
    toggleButton:SetAttribute("SurvivalAIStatus", stateText)
end
local function finishDrag(pointer)
    if not dragState then
        return
    end
    if pointer and dragState.input ~= pointer then
        return
    end
    dragState = nil
end
local function beginEdgeDrag(input)
    if dragState then
        return
    end
    local inputType = input.UserInputType
    if inputType ~= Enum.UserInputType.Touch
        and inputType ~= Enum.UserInputType.MouseButton1 then
        return
    end
    if inputType == Enum.UserInputType.Touch then
        for touch in pairs(activeTouches) do
            if touch ~= input then
                return
            end
        end
    end
    if not buttonPosition and buttonRoot then
        buttonPosition = Vector2.new(
            buttonRoot.Position.X.Offset,
            buttonRoot.Position.Y.Offset
        )
    end
    dragState = {
        input = input,
        inputType = inputType,
        pointerStart = Vector2.new(input.Position.X, input.Position.Y),
        positionStart = buttonPosition or Vector2.new(100, 100),
        moved = false,
    }
end
local function updateDragPosition(pointerPosition)
    local state = dragState
    if not state then
        return
    end
    local delta = pointerPosition - state.pointerStart
    if not state.moved then
        if delta.Magnitude < UI_DRAG_THRESHOLD then
            return
        end
        state.moved = true
    end
    applyButtonPosition(state.positionStart + delta)
end
local function buildGui()
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = UI_GUI_NAME
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = false
    screenGui.Enabled = true
    screenGui.DisplayOrder = 50
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = PlayerGui
    canvas = Instance.new("Frame")
    canvas.Name = "Canvas"
    canvas.BackgroundTransparency = 1
    canvas.BorderSizePixel = 0
    canvas.Size = UDim2.fromScale(1, 1)
    canvas.Position = UDim2.fromScale(0, 0)
    canvas.Visible = true
    canvas.Parent = screenGui
    buttonRoot = Instance.new("Frame")
    buttonRoot.Name = "DraggableToggle"
    buttonRoot.AnchorPoint = Vector2.new(0.5, 0.5)
    buttonRoot.Size = UDim2.fromOffset(UI_BUTTON_SIZE, UI_BUTTON_SIZE)
    buttonRoot.BackgroundColor3 = Color3.fromRGB(21, 24, 30)
    buttonRoot.BackgroundTransparency = 0.04
    buttonRoot.BorderSizePixel = 0
    buttonRoot.ClipsDescendants = true
    buttonRoot.Visible = true
    buttonRoot.ZIndex = 1
    buttonRoot.Parent = canvas
    local rootCorner = Instance.new("UICorner")
    rootCorner.CornerRadius = UDim.new(0, 15)
    rootCorner.Parent = buttonRoot
    local rootStroke = Instance.new("UIStroke")
    rootStroke.Color = Color3.fromRGB(108, 116, 131)
    rootStroke.Thickness = 1.25
    rootStroke.Transparency = 0.12
    rootStroke.Parent = buttonRoot
    local edgeSpecs = {
        {
            Name = "DragTop",
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.new(1, 0, 0, UI_EDGE_SIZE),
        },
        {
            Name = "DragBottom",
            Position = UDim2.new(0, 0, 1, -UI_EDGE_SIZE),
            Size = UDim2.new(1, 0, 0, UI_EDGE_SIZE),
        },
        {
            Name = "DragLeft",
            Position = UDim2.fromOffset(0, UI_EDGE_SIZE),
            Size = UDim2.new(0, UI_EDGE_SIZE, 1, -UI_EDGE_SIZE * 2),
        },
        {
            Name = "DragRight",
            Position = UDim2.new(1, -UI_EDGE_SIZE, 0, UI_EDGE_SIZE),
            Size = UDim2.new(0, UI_EDGE_SIZE, 1, -UI_EDGE_SIZE * 2),
        },
    }
    table.clear(dragHandles)
    for _, spec in ipairs(edgeSpecs) do
        local edge = Instance.new("TextButton")
        edge.Name = spec.Name
        edge.Position = spec.Position
        edge.Size = spec.Size
        edge.BackgroundTransparency = 1
        edge.BorderSizePixel = 0
        edge.Text = ""
        edge.AutoButtonColor = false
        edge.Active = true
        edge.Interactable = true
        edge.Selectable = false
        edge.ZIndex = 2
        edge.Parent = buttonRoot
        table.insert(dragHandles, edge)
        table.insert(guiConnections, edge.InputBegan:Connect(beginEdgeDrag))
    end
    toggleButton = Instance.new("TextButton")
    toggleButton.Name = "CenterToggle"
    toggleButton.AnchorPoint = Vector2.new(0.5, 0.5)
    toggleButton.Position = UDim2.fromScale(0.5, 0.5)
    toggleButton.Size = UDim2.fromOffset(
        UI_BUTTON_SIZE - UI_EDGE_SIZE * 2,
        UI_BUTTON_SIZE - UI_EDGE_SIZE * 2
    )
    toggleButton.BackgroundColor3 = Color3.fromRGB(39, 43, 51)
    toggleButton.BackgroundTransparency = 0
    toggleButton.BorderSizePixel = 0
    toggleButton.Text = "AI\nOFF"
    toggleButton.TextColor3 = Color3.fromRGB(248, 248, 250)
    toggleButton.TextSize = 12
    toggleButton.TextWrapped = true
    toggleButton.Font = Enum.Font.GothamBold
    toggleButton.AutoButtonColor = true
    toggleButton.Active = true
    toggleButton.Interactable = true
    toggleButton.Selectable = false
    toggleButton.ZIndex = 3
    toggleButton.Visible = true
    toggleButton.Parent = buttonRoot
    local centerCorner = Instance.new("UICorner")
    centerCorner.CornerRadius = UDim.new(0, 10)
    centerCorner.Parent = toggleButton
    table.insert(guiConnections, toggleButton.Activated:Connect(function()
        if setEnabled and not shuttingDown then
            setEnabled(not enabled)
        end
    end))
    table.insert(guiConnections, canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        initializeOrClampPosition()
    end))
    table.insert(guiConnections, screenGui.DescendantRemoving:Connect(function(instance)
        if rebuildingGui or shuttingDown then
            return
        end
        if instance == canvas or instance == buttonRoot or instance == toggleButton then
            task.defer(function()
                if not rebuildingGui and not shuttingDown and ensureGui then
                    ensureGui()
                end
            end)
            return
        end
        for _, edge in ipairs(dragHandles) do
            if instance == edge then
                task.defer(function()
                    if not rebuildingGui and not shuttingDown and ensureGui then
                        ensureGui()
                    end
                end)
                break
            end
        end
    end))
    initializeOrClampPosition()
    task.defer(initializeOrClampPosition)
    updateGui()
end
local function guiIsHealthy()
    if not screenGui or screenGui.Name ~= UI_GUI_NAME
        or screenGui.Parent ~= PlayerGui or not screenGui.Enabled then
        return false
    end
    if not canvas or canvas.Parent ~= screenGui or not canvas.Visible then
        return false
    end
    if not buttonRoot or buttonRoot.Parent ~= canvas or not buttonRoot.Visible
        or buttonRoot.Size.X.Offset ~= UI_BUTTON_SIZE
        or buttonRoot.Size.Y.Offset ~= UI_BUTTON_SIZE then
        return false
    end
    if not toggleButton or toggleButton.Parent ~= buttonRoot
        or not toggleButton.Visible or not toggleButton.Active
        or not toggleButton.Interactable then
        return false
    end
    if #dragHandles ~= 4 then
        return false
    end
    for _, edge in ipairs(dragHandles) do
        if not edge or edge.Parent ~= buttonRoot or not edge.Visible
            or not edge.Active or not edge.Interactable then
            return false
        end
    end
    return true
end
ensureGui = function()
    if shuttingDown or rebuildingGui
        or PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) ~= OWNER_TOKEN then
        return
    end
    if guiIsHealthy() then
        initializeOrClampPosition()
        updateGui()
        return
    end
    rebuildingGui = true
    finishDrag()
    disconnectAll(guiConnections)
    if screenGui then
        pcall(function()
            screenGui:Destroy()
        end)
    end
    screenGui = nil
    canvas = nil
    buttonRoot = nil
    toggleButton = nil
    table.clear(dragHandles)
    local ok, err = pcall(buildGui)
    if not ok then
        rebuildingGui = true
        disconnectAll(guiConnections)
        if screenGui then
            pcall(function()
                screenGui:Destroy()
            end)
        end
        screenGui = nil
        canvas = nil
        buttonRoot = nil
        toggleButton = nil
        table.clear(dragHandles)
        rebuildingGui = false
        if CONFIG.DEBUG then
            warn("[SurvivalAI] GUI creation failed:", err)
        end
        return
    end
    rebuildingGui = false
    updateGui()
end
table.insert(generalConnections, UserInputService.TouchStarted:Connect(function(touch)
    activeTouches[touch] = true
    if dragState
        and dragState.inputType == Enum.UserInputType.Touch
        and dragState.input ~= touch then
        finishDrag()
    end
end))
table.insert(generalConnections, UserInputService.TouchEnded:Connect(function(touch)
    activeTouches[touch] = nil
    finishDrag(touch)
end))
table.insert(generalConnections, UserInputService.TouchMoved:Connect(function(touch)
    local state = dragState
    if not state
        or state.inputType ~= Enum.UserInputType.Touch
        or state.input ~= touch then
        return
    end
    updateDragPosition(Vector2.new(touch.Position.X, touch.Position.Y))
end))
table.insert(generalConnections, UserInputService.InputChanged:Connect(function(input)
    local state = dragState
    if not state or state.inputType ~= Enum.UserInputType.MouseButton1 then
        return
    end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then
        return
    end
    updateDragPosition(Vector2.new(input.Position.X, input.Position.Y))
end))
table.insert(generalConnections, UserInputService.InputEnded:Connect(function(input)
    if dragState and dragState.inputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseButton1 then
        finishDrag(dragState.input)
    end
end))
table.insert(generalConnections, UserInputService.WindowFocusReleased:Connect(function()
    finishDrag()
    table.clear(activeTouches)
end))
table.insert(generalConnections, PlayerGui.ChildRemoved:Connect(function(child)
    if child.Name == UI_GUI_NAME then
        task.defer(function()
            if not shuttingDown and ensureGui then
                ensureGui()
            end
        end)
    end
end))
ensureGui()
task.spawn(function()
    while not shuttingDown
        and PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) == OWNER_TOKEN do
        task.wait(UI_REPAIR_INTERVAL)
        if not shuttingDown
            and PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) == OWNER_TOKEN then
            local ok, err = pcall(ensureGui)
            if not ok and CONFIG.DEBUG then
                warn("[SurvivalAI] GUI recovery error:", err)
            end
        end
    end
end)
--==============================================================
-- NO-TAG MODEL REGISTRY
--==============================================================
local function refreshCandidateModel(model)
    if not model or not model:IsA("Model") then
        return
    end
    if not model:IsDescendantOf(Workspace) then
        candidateModels[model] = nil
        return
    end
    local h = model:FindFirstChildOfClass("Humanoid")
    local r = model:FindFirstChild("HumanoidRootPart")
    if not r and h then
        r = h.RootPart
    end
    if h and r and r:IsA("BasePart") then
        candidateModels[model] = true
    else
        candidateModels[model] = nil
    end
end
local function refreshModelAncestors(instance)
    local current = instance
    while current and current ~= Workspace do
        if current:IsA("Model") then
            refreshCandidateModel(current)
        end
        current = current.Parent
    end
end
local pendingTreeRefresh = {}
local function scheduleModelTreeRefresh(model)
    if pendingTreeRefresh[model] then
        return
    end
    local ancestor = model.Parent
    while ancestor and ancestor ~= Workspace do
        if ancestor:IsA("Model") and pendingTreeRefresh[ancestor] then
            return
        end
        ancestor = ancestor.Parent
    end
    pendingTreeRefresh[model] = true
    task.defer(function()
        if shuttingDown then
            pendingTreeRefresh[model] = nil
            return
        end
        pendingTreeRefresh[model] = nil
        if not model:IsDescendantOf(Workspace) then
            return
        end
        local stack = { model }
        local processed = 0
        while #stack > 0 and not shuttingDown do
            local current = table.remove(stack)
            if current and current.Parent then
                if current:IsA("Model") then
                    refreshCandidateModel(current)
                end
                for _, child in ipairs(current:GetChildren()) do
                    stack[#stack + 1] = child
                end
            end
            processed = processed + 1
            if processed >= 300 then
                processed = 0
                task.wait()
            end
        end
    end)
end
table.insert(generalConnections, Workspace.DescendantAdded:Connect(function(instance)
    if shuttingDown then
        return
    end
    if instance:IsA("Model") then
        refreshModelAncestors(instance)
        refreshCandidateModel(instance)
        scheduleModelTreeRefresh(instance)
    elseif instance:IsA("Humanoid") or instance:IsA("BasePart") then
        refreshModelAncestors(instance)
    end
end))
table.insert(generalConnections, Workspace.DescendantRemoving:Connect(function(instance)
    if shuttingDown then
        return
    end
    local isRelevant = instance:IsA("Model")
        or instance:IsA("Humanoid")
        or instance:IsA("BasePart")
    if not isRelevant then
        return
    end
    local oldParent = instance.Parent
    if instance:IsA("Model") then
        candidateModels[instance] = nil
    end
    task.defer(function()
        if not shuttingDown and oldParent then
            refreshModelAncestors(oldParent)
        end
    end)
end))
task.spawn(function()
    local stack = { Workspace }
    local visited = 0
    while #stack > 0 and not shuttingDown do
        local instance = table.remove(stack)
        if instance and (instance == Workspace or instance.Parent ~= nil) then
            if instance:IsA("Model") then
                refreshCandidateModel(instance)
            end
            local children = instance:GetChildren()
            for _, child in ipairs(children) do
                stack[#stack + 1] = child
                visited = visited + 1
            end
        end
        if visited >= 350 then
            visited = 0
            task.wait()
        end
    end
end)
--==============================================================
-- THREAT SENSING
--==============================================================
local function insertTrackedThreat(threat)
    local insertAt = #threats + 1
    for index, existing in ipairs(threats) do
        if threat.Weight > existing.Weight then
            insertAt = index
            break
        end
    end
    if insertAt > CONFIG.MAX_TRACKED_THREATS then
        return
    end
    table.insert(threats, insertAt, threat)
    if #threats > CONFIG.MAX_TRACKED_THREATS then
        table.remove(threats)
    end
end
local function hasLineOfSight(model, otherRoot, params)
    if not rootPart or not otherRoot or not otherRoot.Parent then
        return false
    end
    local origin = rootPart.Position + Vector3.new(0, 1.2, 0)
    local target = otherRoot.Position + Vector3.new(0, 1.2, 0)
    local result = Workspace:Raycast(origin, target - origin, params)
    if not result then
        return true
    end
    return result.Instance:IsDescendantOf(model)
end
local function scanThreats()
    table.clear(threats)
    if not rootPart or not rootPart.Parent then
        return
    end
    if not raycastParams then
        rebuildRaycastParams()
    end
    local params = raycastParams
    local seen = {}
    local myPosition = rootPart.Position
    local myVelocity = clampHorizontal(rootPart.AssemblyLinearVelocity, 40)
    local function considerModel(model)
        if seen[model] then
            return
        end
        seen[model] = true
        local _, otherRoot = getCharacterParts(model)
        if not otherRoot or not otherRoot.Parent then
            candidateModels[model] = nil
            return
        end
        local offset = horizontal(otherRoot.Position - myPosition)
        local distance = offset.Magnitude
        if distance < 0.1 or distance > CONFIG.DETECTION_RADIUS then
            return
        end
        local directionToTarget = offset.Unit
        local targetVelocity = clampHorizontal(otherRoot.AssemblyLinearVelocity, 32)
        local relativeVelocity = targetVelocity - myVelocity
        local closingSpeed = relativeVelocity:Dot(-directionToTarget)
        local visible = false
        if distance > CONFIG.FLEE_RADIUS
            and closingSpeed >= CONFIG.FAST_APPROACH_SPEED then
            visible = hasLineOfSight(model, otherRoot, params)
        end
        local proximity = 1 - math.clamp(distance / CONFIG.DETECTION_RADIUS, 0, 1)
        local closingFactor = math.clamp(closingSpeed / 18, 0, 1)
        local weight = 0.25 + proximity * 1.55 + closingFactor * 0.8
        if distance > CONFIG.FLEE_RADIUS and not visible then
            weight = weight * 0.55
        end
        insertTrackedThreat({
            Model = model,
            Root = otherRoot,
            Distance = distance,
            Direction = directionToTarget,
            Velocity = targetVelocity,
            ClosingSpeed = closingSpeed,
            Visible = visible,
            Weight = weight,
        })
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            considerModel(player.Character)
        end
    end
    for model in pairs(candidateModels) do
        if model:IsDescendantOf(Workspace) then
            considerModel(model)
        else
            candidateModels[model] = nil
        end
    end
end
local function refreshThreatKinematics()
    if not rootPart or not rootPart.Parent then
        table.clear(threats)
        return
    end
    local myPosition = rootPart.Position
    local myVelocity = clampHorizontal(rootPart.AssemblyLinearVelocity, 40)
    for index = #threats, 1, -1 do
        local threat = threats[index]
        local targetHumanoid, targetRoot = getCharacterParts(threat.Model)
        if not targetHumanoid or not targetRoot or not targetRoot.Parent then
            table.remove(threats, index)
        else
            threat.Root = targetRoot
            local offset = horizontal(targetRoot.Position - myPosition)
            local distance = offset.Magnitude
            if distance > CONFIG.DETECTION_RADIUS * 1.15 or distance < 0.05 then
                table.remove(threats, index)
            else
                local direction = offset.Unit
                local targetVelocity = clampHorizontal(targetRoot.AssemblyLinearVelocity, 32)
                local closingSpeed = (targetVelocity - myVelocity):Dot(-direction)
                local proximity = 1 - math.clamp(distance / CONFIG.DETECTION_RADIUS, 0, 1)
                local closingFactor = math.clamp(closingSpeed / 18, 0, 1)
                local weight = 0.25 + proximity * 1.55 + closingFactor * 0.8
                if distance > CONFIG.FLEE_RADIUS and not threat.Visible then
                    weight = weight * 0.55
                end
                threat.Distance = distance
                threat.Direction = direction
                threat.Velocity = targetVelocity
                threat.ClosingSpeed = closingSpeed
                threat.Weight = weight
            end
        end
    end
    table.sort(threats, function(a, b)
        return a.Weight > b.Weight
    end)
    while #threats > CONFIG.MAX_TRACKED_THREATS do
        table.remove(threats)
    end
end
local function getActiveThreats()
    refreshThreatKinematics()
    local active = {}
    for _, threat in ipairs(threats) do
        if threat.Root and threat.Root.Parent then
            local closeEnough = threat.Distance <= CONFIG.FLEE_RADIUS
            local approachingFast = threat.Visible
                and threat.ClosingSpeed >= CONFIG.FAST_APPROACH_SPEED
            if closeEnough or approachingFast then
                table.insert(active, threat)
                if #active >= CONFIG.MAX_THREATS_TO_CONSIDER then
                    break
                end
            end
        end
    end
    return active
end
local function isEmergency(activeThreats)
    for _, threat in ipairs(activeThreats) do
        if threat.Distance <= CONFIG.EMERGENCY_DISTANCE then
            return true
        end
        if threat.Distance <= CONFIG.EMERGENCY_CLOSING_DISTANCE
            and threat.ClosingSpeed >= CONFIG.EMERGENCY_CLOSING_SPEED then
            return true
        end
        if threat.ClosingSpeed > 0
            and threat.Distance <= CONFIG.EMERGENCY_TTC_MAX_DISTANCE
            and threat.Distance / threat.ClosingSpeed <= CONFIG.EMERGENCY_TIME_TO_CONTACT then
            return true
        end
    end
    return false
end
--==============================================================
-- LOCAL SAFETY PROBES
--==============================================================
local function clearanceScore(position, direction, params, includeSideProbes)
    local probeLength = CONFIG.PROBE_DISTANCE
    local offsets = { Vector3.zero }
    if includeSideProbes then
        local side = Vector3.new(-direction.Z, 0, direction.X)
        offsets[2] = side * CONFIG.SIDE_PROBE_OFFSET
        offsets[3] = -side * CONFIG.SIDE_PROBE_OFFSET
    end
    local minimumClearance = 1
    for _, offset in ipairs(offsets) do
        local origin = position + offset + Vector3.new(0, 1.3, 0)
        local result = Workspace:Raycast(origin, direction * probeLength, params)
        if result then
            local distance = (result.Position - origin).Magnitude
            minimumClearance = math.min(
                minimumClearance,
                math.clamp(distance / probeLength, 0, 1)
            )
        end
    end
    return minimumClearance
end
local function getCurrentGroundY(position, params)
    local result = Workspace:Raycast(
        position + Vector3.new(0, 2, 0),
        Vector3.new(0, -16, 0),
        params
    )
    local grounded = humanoid
        and humanoid.Parent
        and humanoid.FloorMaterial ~= Enum.Material.Air
    if result and result.Normal.Y >= 0.5
        and (not CONFIG.AVOID_WATER or result.Material ~= Enum.Material.Water) then
        if grounded or lastKnownGroundY == nil then
            lastKnownGroundY = result.Position.Y
        end
    elseif not grounded then
        return lastKnownGroundY
    end
    return lastKnownGroundY
end
local function hasSafeGround(position, direction, params, currentGroundY)
    if currentGroundY == nil then
        return true
    end
    local destination = position + direction * CONFIG.LOOK_AHEAD_DISTANCE
    local groundResult = Workspace:Raycast(
        destination + Vector3.new(0, 5, 0),
        Vector3.new(0, -22, 0),
        params
    )
    if not groundResult or groundResult.Normal.Y < 0.5 then
        return false
    end
    if CONFIG.AVOID_WATER and groundResult.Material == Enum.Material.Water then
        return false
    end
    local heightDifference = groundResult.Position.Y - currentGroundY
    return heightDifference >= -CONFIG.MAX_SAFE_DROP
        and heightDifference <= CONFIG.MAX_STEP_UP
end
--==============================================================
-- OPEN SPACE MAP (v1.0)
-- A cheap cached ring of clearance samples used to bias escapes
-- toward open areas and to pick clutch-dodge sides intelligently.
--==============================================================
local function updateOpennessMap(now)
    if not CONFIG.OPENNESS_ENABLED then
        return
    end
    if now - opennessTime < CONFIG.OPENNESS_REFRESH_INTERVAL then
        return
    end
    if not rootPart or not rootPart.Parent then
        return
    end
    if not raycastParams then
        rebuildRaycastParams()
    end
    opennessTime = now
    local position = rootPart.Position
    local origin = position + Vector3.new(0, 1.3, 0)
    local count = CONFIG.OPENNESS_RAYS
    for index = 1, count do
        local angle = (index - 1) * (2 * math.pi / count)
        local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
        local result = Workspace:Raycast(
            origin, direction * CONFIG.OPENNESS_PROBE_DISTANCE, raycastParams
        )
        local clear = 1
        if result then
            clear = math.clamp(
                (result.Position - origin).Magnitude
                    / CONFIG.OPENNESS_PROBE_DISTANCE,
                0, 1
            )
        end
        local entry = openness[index]
        if entry then
            entry.Clearance = clear
        else
            openness[index] = { Clearance = clear }
        end
    end
    while #openness > count do
        table.remove(openness)
    end
end
local function sampleOpenness(direction)
    local count = #openness
    if count == 0 or direction.Magnitude < 0.001 then
        return 0.5
    end
    local angle = math.atan2(direction.Z, direction.X)
    if angle < 0 then
        angle = angle + 2 * math.pi
    end
    local indexFloat = angle / (2 * math.pi) * count + 1
    local firstIndex = math.floor(indexFloat)
    local fraction = indexFloat - firstIndex
    firstIndex = ((firstIndex - 1) % count) + 1
    local secondIndex = (firstIndex % count) + 1
    local first = openness[firstIndex]
    local second = openness[secondIndex]
    if not first or not second then
        return 0.5
    end
    return first.Clearance * (1 - fraction) + second.Clearance * fraction
end
local function coneOpenness(direction)
    direction = unitOrZero(direction)
    if direction.Magnitude < 0.001 then
        return 0
    end
    local side = Vector3.new(-direction.Z, 0, direction.X)
    local left = unitOrZero(direction + side * 0.68)
    local right = unitOrZero(direction - side * 0.68)
    local center = sampleOpenness(direction)
    local leftValue = left.Magnitude > 0.001 and sampleOpenness(left) or center
    local rightValue = right.Magnitude > 0.001 and sampleOpenness(right) or center
    return center * 0.5 + leftValue * 0.25 + rightValue * 0.25
end
--==============================================================
-- ESCAPE PLANNING + TACTICAL MOTION
--==============================================================
local function calculateEscapeBias(activeThreats)
    local vector = Vector3.zero
    for _, threat in ipairs(activeThreats) do
        local weight = threat.Weight / math.max(threat.Distance, 5)
        vector = vector - threat.Direction * weight
    end
    return unitOrZero(vector)
end
local function calculateNearestDistance(activeThreats)
    local nearest = math.huge
    local closing = 0
    for _, threat in ipairs(activeThreats) do
        nearest = math.min(nearest, threat.Distance)
        closing = math.max(closing, threat.ClosingSpeed)
    end
    return nearest, closing
end
local function wallSlideFallback(activeThreats, position, params, currentGroundY)
    -- Last resort when no candidate passes safety checks: detect the
    -- wall we are being pushed into and slide along its tangent toward
    -- the side that keeps threats farther away.
    local away = calculateEscapeBias(activeThreats)
    if away.Magnitude < 0.001 then
        local nearestThreat
        local nearestDistance = math.huge
        for _, threat in ipairs(activeThreats) do
            if threat.Distance < nearestDistance then
                nearestDistance = threat.Distance
                nearestThreat = threat
            end
        end
        if nearestThreat then
            away = unitOrZero(-nearestThreat.Direction)
        end
    end
    if away.Magnitude < 0.001 then
        return nil
    end
    local origin = position + Vector3.new(0, 1.3, 0)
    local result = Workspace:Raycast(origin, away * 8, params)
    if not result then
        return nil
    end
    local normal = unitOrZero(result.Normal)
    if normal.Magnitude < 0.001 then
        return nil
    end
    local tangentA = unitOrZero(Vector3.new(-normal.Z, 0, normal.X))
    local tangentB = -tangentA
    local function viable(sideDirection)
        if sideDirection.Magnitude < 0.001 then
            return false
        end
        if not hasSafeGround(position, sideDirection, params, currentGroundY) then
            return false
        end
        return clearanceScore(position, sideDirection, params, false) > 0.25
    end
    local aViable = viable(tangentA)
    local bViable = viable(tangentB)
    if aViable and bViable then
        local function sideValue(sideDirection)
            local value = 0
            local destination = position + sideDirection * 6
            for _, threat in ipairs(activeThreats) do
                if threat.Root and threat.Root.Parent then
                    value = value + horizontal(
                        threat.Root.Position - destination
                    ).Magnitude * threat.Weight
                end
            end
            return value
        end
        if sideValue(tangentA) >= sideValue(tangentB) then
            return tangentA
        end
        return tangentB
    elseif aViable then
        return tangentA
    elseif bViable then
        return tangentB
    end
    return nil
end
local function scoreDirection(direction, activeThreats, position, params,
    currentGroundY, escapeBias, styleSide, nearestDistance, now, includeSideProbes)
    direction = unitOrZero(direction)
    if direction.Magnitude < 0.001 then
        return -math.huge
    end
    if not hasSafeGround(position, direction, params, currentGroundY) then
        return -math.huge
    end
    local clearance = clearanceScore(position, direction, params, includeSideProbes)
    local destination = position + direction * CONFIG.LOOK_AHEAD_DISTANCE
    local weightedGain = 0
    local weightedDistance = 0
    local totalWeight = 0
    local predictionTime = CONFIG.PREDICTION_TIME
    if humanoid then
        predictionTime = math.clamp(
            CONFIG.LOOK_AHEAD_DISTANCE / math.max(humanoid.WalkSpeed, 8),
            0.25,
            0.85
        )
    end
    for _, threat in ipairs(activeThreats) do
        local targetRoot = threat.Root
        if targetRoot and targetRoot.Parent then
            local predictedPosition = targetRoot.Position
                + clampHorizontal(threat.Velocity, 32) * predictionTime
            local beforeDistance = horizontal(predictedPosition - position).Magnitude
            local afterDistance = horizontal(predictedPosition - destination).Magnitude
            local weight = threat.Weight
            local gain = (afterDistance - beforeDistance)
                / math.max(CONFIG.LOOK_AHEAD_DISTANCE, 1)
            gain = math.clamp(gain, -1.5, 1.5)
            weightedGain = weightedGain + gain * weight
            weightedDistance = weightedDistance + math.clamp(
                afterDistance / CONFIG.DETECTION_RADIUS, 0, 1
            ) * weight
            totalWeight = totalWeight + weight
        end
    end
    local threatGain = 0
    local futureDistanceScore = 0
    if totalWeight > 0 then
        threatGain = weightedGain / totalWeight
        futureDistanceScore = weightedDistance / totalWeight
    end
    local escapeAlignment = 0
    if escapeBias.Magnitude > 0.001 then
        escapeAlignment = direction:Dot(escapeBias)
    end
    local inertia = 0
    if selectedDirection.Magnitude > 0.001 then
        inertia = direction:Dot(selectedDirection)
    end
    -- v1.0: prefer routes that lead into open space (anti-cornering).
    local openBonus = 0
    if CONFIG.OPENNESS_ENABLED and #openness > 0 then
        openBonus = coneOpenness(direction) * CONFIG.OPENNESS_SCORE_WEIGHT
    end
    -- v1.0: never run parallel with a faster chaser; cut across them.
    local antiParallelPenalty = 0
    if CONFIG.ANTI_PARALLEL_WEIGHT > 0 then
        for _, threat in ipairs(activeThreats) do
            local threatVelocity = clampHorizontal(threat.Velocity, 32)
            if threatVelocity.Magnitude > 5 then
                local alignment = direction:Dot(threatVelocity.Unit)
                if alignment > 0 then
                    local proximity = math.clamp(
                        1 - threat.Distance / CONFIG.DETECTION_RADIUS, 0, 1
                    )
                    antiParallelPenalty = antiParallelPenalty + alignment * proximity
                end
            end
        end
    end
    local score = threatGain * 2.5
        + futureDistanceScore * 0.70
        + clearance * 1.75
        + openBonus
        + escapeAlignment * 0.50
        + inertia * CONFIG.INERTIA_WEIGHT
        - antiParallelPenalty * CONFIG.ANTI_PARALLEL_WEIGHT
    if styleSide.Magnitude > 0.001 and nearestDistance > CONFIG.EMERGENCY_DISTANCE then
        local styleStrength = math.clamp(
            (nearestDistance - CONFIG.EMERGENCY_DISTANCE) / 28, 0, 1
        ) * CONFIG.WEAVE_STRENGTH
        if getHealthRatio() <= CONFIG.LOW_HEALTH_RATIO then
            styleStrength = styleStrength * 0.25
        end
        score = score + direction:Dot(styleSide) * styleStrength * weaveSign
    end
    if getHealthRatio() <= CONFIG.LOW_HEALTH_RATIO then
        score = score + escapeAlignment * 0.85
    end
    if now < stuckUntil and stuckDirection.Magnitude > 0.001 then
        score = score - math.max(direction:Dot(stuckDirection), 0) * 1.4
    end
    if clearance < 0.18 then
        score = score - 1.9
    elseif clearance < 0.35 then
        score = score - 0.7
    end
    return score
end
local function chooseEscapeDirection(activeThreats)
    if not rootPart or not humanoid or #activeThreats == 0 then
        return Vector3.zero, "Рядом спокойно", false
    end
    if not raycastParams then
        rebuildRaycastParams()
    end
    local position = rootPart.Position
    local params = raycastParams
    local currentGroundY = getCurrentGroundY(position, params)
    local now = os.clock()
    updateOpennessMap(now)
    local escapeBias = calculateEscapeBias(activeThreats)
    local nearestDistance, maxClosing = calculateNearestDistance(activeThreats)
    local styleSide = Vector3.zero
    if escapeBias.Magnitude > 0.001 then
        styleSide = Vector3.new(-escapeBias.Z, 0, escapeBias.X)
    end
    local candidates = {}
    local function addCandidate(direction)
        direction = unitOrZero(direction)
        if direction.Magnitude < 0.001 then
            return
        end
        for _, candidate in ipairs(candidates) do
            if candidate:Dot(direction) > 0.985 then
                return
            end
        end
        table.insert(candidates, direction)
    end
    for index = 1, CONFIG.DIRECTION_COUNT do
        local angle = (index - 1) * (2 * math.pi / CONFIG.DIRECTION_COUNT)
        addCandidate(Vector3.new(math.cos(angle), 0, math.sin(angle)))
    end
    if escapeBias.Magnitude > 0.001 then
        addCandidate(escapeBias)
        addCandidate((escapeBias + styleSide * 0.45).Unit)
        addCandidate((escapeBias - styleSide * 0.45).Unit)
    end
    if nearestDistance <= 22 or maxClosing >= CONFIG.EMERGENCY_CLOSING_SPEED then
        for index = 1, math.min(2, #activeThreats) do
            local threat = activeThreats[index]
            local away = -threat.Direction
            local side = Vector3.new(-away.Z, 0, away.X)
            addCandidate((away * 0.55 + side * CONFIG.TACTICAL_SIDE_STEP_STRENGTH).Unit)
            addCandidate((away * 0.55 - side * CONFIG.TACTICAL_SIDE_STEP_STRENGTH).Unit)
            addCandidate((away * 0.82 + side * 0.42).Unit)
            addCandidate((away * 0.82 - side * 0.42).Unit)
        end
    end
    local preliminary = {}
    for _, direction in ipairs(candidates) do
        local score = scoreDirection(
            direction, activeThreats, position, params, currentGroundY,
            escapeBias, styleSide, nearestDistance, now, false
        )
        if score > -math.huge then
            table.insert(preliminary, { Direction = direction, Score = score })
        end
    end
    table.sort(preliminary, function(a, b)
        return a.Score > b.Score
    end)
    local bestDirection = Vector3.zero
    local bestScore = -math.huge
    local finalists = math.min(CONFIG.PRECISE_DIRECTION_COUNT, #preliminary)
    for index = 1, finalists do
        local candidate = preliminary[index].Direction
        local score = scoreDirection(
            candidate, activeThreats, position, params, currentGroundY,
            escapeBias, styleSide, nearestDistance, now, true
        )
        if score > bestScore then
            bestScore = score
            bestDirection = candidate
        end
    end
    if bestScore == -math.huge or bestDirection.Magnitude < 0.001 then
        -- v1.0: slide along the wall instead of standing still.
        if CONFIG.WALL_SLIDE_ENABLED then
            local slideDirection = wallSlideFallback(
                activeThreats, position, params, currentGroundY
            )
            if slideDirection then
                return slideDirection, "Скольжу вдоль стены", true
            end
        end
        return Vector3.zero, "Ищу другой маршрут", true
    end
    local finalClearance = clearanceScore(
        position, bestDirection, params, true
    )
    local needsPath = finalClearance < 0.32
    if finalClearance < 0.07 then
        local routeCanStart = CONFIG.PATHFINDING_ENABLED
            and humanoid.FloorMaterial ~= Enum.Material.Air
            and (pathRequestInFlight
                or os.clock() - lastPathRequest >= CONFIG.PATH_RETRY_INTERVAL)
        if routeCanStart then
            return Vector3.zero, "Препятствие — ищу обход", true
        end
    end
    if getHealthRatio() <= CONFIG.LOW_HEALTH_RATIO then
        return bestDirection, "Мало HP — отступаю", needsPath
    elseif isEmergency(activeThreats) then
        return bestDirection, "Экстренный манёвр", needsPath
    elseif nearestDistance <= 22 and maxClosing >= CONFIG.FAST_APPROACH_SPEED then
        return bestDirection, "Уклоняюсь", needsPath
    end
    return bestDirection, needsPath and "Проверяю обход" or "Меняю траекторию", needsPath
end
--==============================================================
-- ASYNCHRONOUS PATHFINDING FALLBACK
--==============================================================
local function destroyActivePath()
    if activePathBlockedConnection then
        activePathBlockedConnection:Disconnect()
        activePathBlockedConnection = nil
    end
    if activePath then
        pcall(function()
            activePath:Destroy()
        end)
    end
    activePath = nil
    pathWaypoints = {}
    pathIndex = 2
    pathGoal = nil
    lastPathJumpIndex = -1
end
local function cancelPathfinding()
    pathRequestGeneration = pathRequestGeneration + 1
    pathRequestInFlight = false
    pathNeedsReplan = false
    destroyActivePath()
end
local function addUniqueDirection(list, direction)
    direction = unitOrZero(direction)
    if direction.Magnitude < 0.001 then
        return
    end
    for _, existing in ipairs(list) do
        if existing:Dot(direction) > 0.96 then
            return
        end
    end
    table.insert(list, direction)
end
local function pathFitness(waypoints, candidateDirection, baseDirection, threatSnapshots)
    if #waypoints < 2 then
        return -math.huge
    end
    local pathLength = 0
    for index = 2, #waypoints do
        pathLength = pathLength
            + (waypoints[index].Position - waypoints[index - 1].Position).Magnitude
    end
    local endpoint = waypoints[#waypoints].Position
    local weightedSeparation = 0
    local totalWeight = 0
    for _, snapshot in ipairs(threatSnapshots) do
        local predicted = snapshot.Position + snapshot.Velocity * 0.75
        local distance = horizontal(endpoint - predicted).Magnitude
        weightedSeparation = weightedSeparation
            + math.min(distance, CONFIG.DETECTION_RADIUS) * snapshot.Weight
        totalWeight = totalWeight + snapshot.Weight
    end
    local separationScore = totalWeight > 0
        and weightedSeparation / totalWeight
        or 0
    local alignment = candidateDirection:Dot(baseDirection)
    return separationScore * 0.13 + alignment * 1.8 - pathLength * 0.022
end
local function requestEscapePath(activeThreats, directDirection, escapeBias)
    if not CONFIG.PATHFINDING_ENABLED or pathRequestInFlight then
        return
    end
    if not rootPart or not character or not alive or not humanoid then
        return
    end
    if humanoid.FloorMaterial == Enum.Material.Air then
        return
    end
    local now = os.clock()
    if now - lastPathRequest < CONFIG.PATH_RETRY_INTERVAL then
        return
    end
    local baseDirection = escapeBias.Magnitude > 0.001 and escapeBias or directDirection
    baseDirection = unitOrZero(baseDirection)
    if baseDirection.Magnitude < 0.001 then
        local nearestThreat
        local nearestDistance = math.huge
        for _, threat in ipairs(activeThreats) do
            if threat.Distance < nearestDistance then
                nearestDistance = threat.Distance
                nearestThreat = threat
            end
        end
        if nearestThreat then
            baseDirection = unitOrZero(-nearestThreat.Direction)
        end
    end
    if baseDirection.Magnitude < 0.001 then
        return
    end
    local side = Vector3.new(-baseDirection.Z, 0, baseDirection.X)
    local candidates = {}
    addUniqueDirection(candidates, baseDirection)
    addUniqueDirection(candidates, directDirection)
    addUniqueDirection(candidates, (baseDirection + side * 0.82).Unit)
    addUniqueDirection(candidates, (baseDirection - side * 0.82).Unit)
    while #candidates > CONFIG.PATH_CANDIDATES do
        table.remove(candidates)
    end
    local snapshots = {}
    for _, threat in ipairs(activeThreats) do
        if threat.Root and threat.Root.Parent then
            table.insert(snapshots, {
                Position = threat.Root.Position,
                Velocity = clampHorizontal(threat.Velocity, 32),
                Weight = threat.Weight,
            })
        end
    end
    local requestGeneration = pathRequestGeneration + 1
    pathRequestGeneration = requestGeneration
    pathRequestInFlight = true
    lastPathRequest = now
    pathNeedsReplan = true
    local requestCharacter = character
    local startPosition = rootPart.Position
    local baseSnapshot = baseDirection
    task.spawn(function()
        local bestPath = nil
        local bestWaypoints = nil
        local bestGoal = nil
        local bestScore = -math.huge
        local currentCandidatePath = nil
        local ok, err = pcall(function()
            for _, direction in ipairs(candidates) do
                if requestGeneration ~= pathRequestGeneration
                    or PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) ~= OWNER_TOKEN
                    or character ~= requestCharacter
                    or not alive then
                    break
                end
                local goal = startPosition + direction * CONFIG.PATH_GOAL_DISTANCE
                local createOK, pathOrError = pcall(function()
                    local agentParameters = {
                        AgentRadius = CONFIG.PATH_AGENT_RADIUS,
                        AgentHeight = CONFIG.PATH_AGENT_HEIGHT,
                        AgentCanJump = CONFIG.PATH_AGENT_CAN_JUMP and canCharacterJump(),
                        AgentCanClimb = CONFIG.PATH_AGENT_CAN_CLIMB,
                        WaypointSpacing = CONFIG.PATH_WAYPOINT_SPACING,
                    }
                    if CONFIG.AVOID_WATER then
                        agentParameters.Costs = {
                            Water = math.huge,
                        }
                    end
                    return PathfindingService:CreatePath(agentParameters)
                end)
                if createOK and pathOrError then
                    currentCandidatePath = pathOrError
                    local computeOK = pcall(function()
                        currentCandidatePath:ComputeAsync(startPosition, goal)
                    end)
                    if requestGeneration ~= pathRequestGeneration
                        or PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) ~= OWNER_TOKEN
                        or character ~= requestCharacter
                        or not alive then
                        pcall(function() currentCandidatePath:Destroy() end)
                        currentCandidatePath = nil
                        break
                    end
                    if computeOK
                        and currentCandidatePath.Status == Enum.PathStatus.Success then
                        local waypoints = currentCandidatePath:GetWaypoints()
                        if #waypoints >= 2 then
                            local score = pathFitness(
                                waypoints,
                                direction,
                                baseSnapshot,
                                snapshots
                            )
                            if score > bestScore then
                                if bestPath then
                                    pcall(function() bestPath:Destroy() end)
                                end
                                bestPath = currentCandidatePath
                                bestWaypoints = waypoints
                                bestGoal = waypoints[#waypoints].Position
                                bestScore = score
                                currentCandidatePath = nil
                            end
                        end
                    end
                    if currentCandidatePath then
                        pcall(function() currentCandidatePath:Destroy() end)
                        currentCandidatePath = nil
                    end
                end
            end
        end)
        if currentCandidatePath then
            pcall(function() currentCandidatePath:Destroy() end)
        end
        if requestGeneration ~= pathRequestGeneration
            or PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) ~= OWNER_TOKEN then
            if bestPath then
                pcall(function() bestPath:Destroy() end)
            end
            return
        end
        pathRequestInFlight = false
        if not ok then
            if bestPath then
                pcall(function() bestPath:Destroy() end)
            end
            pathNeedsReplan = false
            if CONFIG.DEBUG then
                warn("[SurvivalAI] Path calculation error:", err)
            end
            return
        end
        local startDrift = rootPart and rootPart.Parent
            and (rootPart.Position - startPosition).Magnitude
            or math.huge
        if not alive or character ~= requestCharacter
            or startDrift > CONFIG.PATH_START_DRIFT_LIMIT then
            if bestPath then
                pcall(function() bestPath:Destroy() end)
            end
            destroyActivePath()
            pathNeedsReplan = false
            setStatus("Маршрут устарел — продолжаю")
            updateGui()
            return
        end
        if bestPath and bestWaypoints then
            destroyActivePath()
            activePath = bestPath
            pathWaypoints = bestWaypoints
            pathIndex = math.min(2, #pathWaypoints)
            pathGoal = bestGoal
            pathNeedsReplan = false
            lastPathJumpIndex = -1
            activePathBlockedConnection = activePath.Blocked:Connect(function(blockedWaypointIndex)
                if activePath and blockedWaypointIndex >= pathIndex then
                    pathNeedsReplan = true
                    setStatus("Маршрут закрыт — ищу обход")
                end
            end)
            setStatus("Обхожу препятствие")
        else
            destroyActivePath()
            pathNeedsReplan = false
            setStatus("Пробую другой угол")
        end
        updateGui()
    end)
end
local function getPathDirection()
    if not activePath or pathNeedsReplan or #pathWaypoints < 2 or not rootPart then
        return nil
    end
    while pathIndex <= #pathWaypoints do
        local waypoint = pathWaypoints[pathIndex]
        local offset = waypoint.Position - rootPart.Position
        local flatDistance = horizontal(offset).Magnitude
        local verticalDifference = math.abs(offset.Y)
        if waypoint.Action == Enum.PathWaypointAction.Jump
            and lastPathJumpIndex ~= pathIndex
            and flatDistance <= CONFIG.PATH_JUMP_TRIGGER_DISTANCE
            and humanoid
            and humanoid.FloorMaterial ~= Enum.Material.Air
            and canCharacterJump() then
            humanoid.Jump = true
            lastPathJumpIndex = pathIndex
        end
        local closeEnough = flatDistance <= CONFIG.PATH_REACHED_DISTANCE
            and verticalDifference <= 6
        if closeEnough then
            if pathIndex >= #pathWaypoints then
                destroyActivePath()
                return nil
            end
            pathIndex = pathIndex + 1
            lastPathJumpIndex = -1
        else
            break
        end
    end
    local waypoint = pathWaypoints[pathIndex]
    if not waypoint then
        destroyActivePath()
        return nil
    end
    local direction = unitOrZero(waypoint.Position - rootPart.Position)
    -- v1.0: blend toward the next waypoint near a corner so route
    -- following arcs smoothly instead of snapping at right angles.
    local nextWaypoint = pathWaypoints[pathIndex + 1]
    local flatToWaypoint = horizontal(
        waypoint.Position - rootPart.Position
    ).Magnitude
    if nextWaypoint and direction.Magnitude > 0.001
        and flatToWaypoint < CONFIG.PATH_CORNER_BLEND_DISTANCE then
        local nextDirection = unitOrZero(nextWaypoint.Position - rootPart.Position)
        if nextDirection.Magnitude > 0.001 then
            local blend = 1 - flatToWaypoint / CONFIG.PATH_CORNER_BLEND_DISTANCE
            direction = unitOrZero(direction + nextDirection * blend * 0.85)
        end
    end
    return direction
end
local function pathGoalStillLooksSafe(activeThreats)
    if not pathGoal then
        return true
    end
    for _, threat in ipairs(activeThreats) do
        if threat.Root and threat.Root.Parent then
            local predictedThreat = threat.Root.Position
                + clampHorizontal(threat.Velocity, 32) * 0.7
            local endDistance = horizontal(pathGoal - predictedThreat).Magnitude
            if endDistance < CONFIG.EMERGENCY_DISTANCE then
                return false
            end
        end
    end
    return true
end
--==============================================================
-- STUCK DETECTION
--==============================================================
local function checkProgress(now)
    if not rootPart or not humanoid then
        return false
    end
    if now - lastProgressCheck < CONFIG.STUCK_CHECK_INTERVAL then
        return false
    end
    lastProgressCheck = now
    local position = rootPart.Position
    local stuckNow = false
    if progressPosition and commandDirection.Magnitude > 0.2
        and humanoid.FloorMaterial ~= Enum.Material.Air then
        local progress = horizontal(position - progressPosition).Magnitude
        local speed = horizontal(rootPart.AssemblyLinearVelocity).Magnitude
        if progress < CONFIG.STUCK_MIN_PROGRESS
            and speed < CONFIG.STUCK_SPEED_LIMIT then
            stuckDirection = commandDirection
            stuckUntil = now + CONFIG.STUCK_PENALTY_TIME
            stuckStatusUntil = now + 0.9
            stuckNow = true
            setStatus("Застрял — ищу другой путь")
        end
    end
    progressPosition = position
    return stuckNow
end
--==============================================================
-- PRO-PLAYER MOVEMENT LAYER (v1.0)
-- Serpentine runs, orbit strafing, juke feints, jump-dodges and
-- the clutch CPA sidestep. Style is always subordinate to
-- survival: every flashy direction is safety-checked first.
--==============================================================
local function scheduleNextJuke(now)
    local minInterval = CONFIG.JUKE_MIN_INTERVAL
    local maxInterval = CONFIG.JUKE_MAX_INTERVAL
    if panicMode then
        minInterval = minInterval * CONFIG.PANIC_JUKE_SPEEDUP
        maxInterval = maxInterval * CONFIG.PANIC_JUKE_SPEEDUP
    end
    nextJukeAt = now + jukeRandom:NextNumber(minInterval, maxInterval)
end
local function tryStartJuke(now, nearestDistance, emergency)
    if now < nextJukeAt then
        return
    end
    if nearestDistance > CONFIG.JUKE_TRIGGER_MAX_DISTANCE then
        scheduleNextJuke(now)
        return
    end
    if emergency and jukeRandom:NextNumber() > CONFIG.JUKE_EMERGENCY_BIAS then
        scheduleNextJuke(now)
        return
    end
    scheduleNextJuke(now)
    local duration = jukeRandom:NextNumber(
        CONFIG.JUKE_DURATION_MIN,
        CONFIG.JUKE_DURATION_MAX
    )
    jukeActiveUntil = now + duration
    jukeCounterAt = now + duration * jukeRandom:NextNumber(0.35, 0.55)
    jukeCountered = false
    jukePendingSide = jukeRandom:NextInteger(1, 2) == 1 and 1 or -1
    jukeIsReverse = (not emergency)
        and jukeRandom:NextNumber() < CONFIG.JUKE_REVERSE_CHANCE
end
local function maybeJumpDodge(now, activeThreats, emergency)
    if not CONFIG.JUMP_DODGE_ENABLED then
        return
    end
    if not humanoid or not humanoid.Parent or not canCharacterJump() then
        return
    end
    if now < nextJumpDodgeAt then
        return
    end
    if humanoid.FloorMaterial == Enum.Material.Air then
        return
    end
    local nearestDistance = calculateNearestDistance(activeThreats)
    if nearestDistance > CONFIG.JUMP_DODGE_TRIGGER_DISTANCE then
        return
    end
    local dodgeChance = emergency
        and CONFIG.JUMP_DODGE_CHANCE * 1.35
        or CONFIG.JUMP_DODGE_CHANCE
    if panicMode then
        dodgeChance = dodgeChance * CONFIG.PANIC_JUMP_BOOST
    end
    if jukeRandom:NextNumber() <= math.min(dodgeChance, 1) then
        humanoid.Jump = true
    end
    nextJumpDodgeAt = now + jukeRandom:NextNumber(
        CONFIG.JUMP_DODGE_COOLDOWN_MIN,
        CONFIG.JUMP_DODGE_COOLDOWN_MAX
    )
end
-- v1.0: Closest Point of Approach — when will a threat nearly touch us
-- if both keep current velocities? This is the math behind pro dodges.
local function calculateCPA(threat)
    if not rootPart or not rootPart.Parent then
        return nil
    end
    if not threat.Root or not threat.Root.Parent then
        return nil
    end
    local relativePosition = horizontal(threat.Root.Position - rootPart.Position)
    local myVelocity = clampHorizontal(rootPart.AssemblyLinearVelocity, 40)
    local relativeVelocity = clampHorizontal(threat.Velocity, 32) - myVelocity
    local velocitySquared = relativeVelocity:Dot(relativeVelocity)
    if velocitySquared < 0.5 then
        return nil
    end
    local cpaTime = -relativePosition:Dot(relativeVelocity) / velocitySquared
    if cpaTime < 0 then
        return nil
    end
    local closestVector = relativePosition + relativeVelocity * cpaTime
    return cpaTime, closestVector.Magnitude
end
local function tryClutchDodge(now, activeThreats)
    if not CONFIG.CLUTCH_DODGE_ENABLED then
        return
    end
    if now < clutchActiveUntil then
        return
    end
    if now - lastClutchDodge < CONFIG.CLUTCH_DODGE_COOLDOWN then
        return
    end
    if now - lastClutchCheck < CONFIG.CLUTCH_CHECK_INTERVAL then
        return
    end
    lastClutchCheck = now
    if not rootPart or not rootPart.Parent then
        return
    end
    if not raycastParams then
        rebuildRaycastParams()
    end
    local position = rootPart.Position
    local groundY = getCurrentGroundY(position, raycastParams)
    local escapeBias = calculateEscapeBias(activeThreats)
    for _, threat in ipairs(activeThreats) do
        local cpaTime, cpaDistance = calculateCPA(threat)
        if cpaTime
            and cpaTime >= CONFIG.CLUTCH_CPA_TIME_MIN
            and cpaTime <= CONFIG.CLUTCH_CPA_TIME_MAX
            and cpaDistance <= CONFIG.CLUTCH_CPA_DISTANCE then
            local incoming = unitOrZero(threat.Velocity)
            if incoming.Magnitude < 0.001 then
                incoming = threat.Direction
            end
            if incoming.Magnitude > 0.001 then
                local sideA = unitOrZero(Vector3.new(-incoming.Z, 0, incoming.X))
                local sideB = -sideA
                local function sideViable(sideDirection)
                    if sideDirection.Magnitude < 0.001 then
                        return false
                    end
                    return hasSafeGround(
                            position, sideDirection, raycastParams, groundY
                        )
                        and clearanceScore(
                            position, sideDirection, raycastParams, false
                        ) > 0.30
                end
                local aViable = sideViable(sideA)
                local bViable = sideViable(sideB)
                local chosen
                if aViable and bViable then
                    chosen = sampleOpenness(sideA) >= sampleOpenness(sideB)
                        and sideA or sideB
                elseif aViable then
                    chosen = sideA
                elseif bViable then
                    chosen = sideB
                end
                if chosen then
                    local blended = chosen
                    if escapeBias.Magnitude > 0.001 then
                        blended = unitOrZero(
                            chosen * (1 - CONFIG.CLUTCH_ESCAPE_BLEND)
                                + escapeBias * CONFIG.CLUTCH_ESCAPE_BLEND
                        )
                    end
                    if blended.Magnitude > 0.001 then
                        clutchDirection = blended
                        clutchActiveUntil = now + CONFIG.CLUTCH_DODGE_DURATION
                        lastClutchDodge = now
                        return
                    end
                end
            end
        end
    end
end
local function applyProMovement(desiredDirection, activeThreats, now, emergency)
    if desiredDirection.Magnitude < 0.001 or #activeThreats == 0 then
        return desiredDirection
    end
    if not rootPart or not rootPart.Parent then
        return desiredDirection
    end
    if not raycastParams then
        rebuildRaycastParams()
    end
    -- 0) CLUTCH DODGE: last-moment CPA sidestep beats every other style.
    tryClutchDodge(now, activeThreats)
    if now < clutchActiveUntil and clutchDirection.Magnitude > 0.001 then
        return clutchDirection
    end
    local result = desiredDirection
    local nearestDistance = calculateNearestDistance(activeThreats)
    if not emergency then
        -- 1) Serpentine run: dual harmonic with a drifting frequency.
        if CONFIG.SERPENTINE_ENABLED then
            if now >= nextSerpentineFrequencyChange then
                serpentineFrequency = jukeRandom:NextNumber(
                    CONFIG.SERPENTINE_FREQ_MIN,
                    CONFIG.SERPENTINE_FREQ_MAX
                )
                nextSerpentineFrequencyChange = now + jukeRandom:NextNumber(
                    CONFIG.SERPENTINE_FREQ_CHANGE_MIN,
                    CONFIG.SERPENTINE_FREQ_CHANGE_MAX
                )
            end
            local scale = math.clamp(
                (nearestDistance - CONFIG.EMERGENCY_DISTANCE) / 28, 0, 1
            )
            if getHealthRatio() <= CONFIG.LOW_HEALTH_RATIO then
                scale = scale * 0.35
            end
            local amplitude = CONFIG.SERPENTINE_BASE_AMPLITUDE
            if panicMode then
                amplitude = amplitude * CONFIG.PANIC_SERPENTINE_BOOST
            end
            local side = Vector3.new(-result.Z, 0, result.X)
            local wave = math.sin(now * serpentineFrequency + weavePhase)
            local wave2 = math.sin(
                now * serpentineFrequency * 2.13 + weavePhase * 1.7
            ) * CONFIG.SERPENTINE_SECOND_HARMONIC
            local waved = unitOrZero(
                result + side * (wave + wave2) * amplitude * scale
            )
            if waved.Magnitude > 0.001 then
                result = waved
            end
        end
        -- 2) Orbit strafe: arc around the nearest threat at mid range.
        if CONFIG.STRAFE_ENABLED
            and nearestDistance >= CONFIG.STRAFE_DISTANCE_MIN
            and nearestDistance <= CONFIG.STRAFE_DISTANCE_MAX then
            if now >= nextStrafeFlip then
                strafeSide = -strafeSide
                nextStrafeFlip = now + jukeRandom:NextNumber(
                    CONFIG.STRAFE_SIDE_FLIP_MIN,
                    CONFIG.STRAFE_SIDE_FLIP_MAX
                )
            end
            local nearestThreat
            local nearestThreatDistance = math.huge
            for _, threat in ipairs(activeThreats) do
                if threat.Distance < nearestThreatDistance then
                    nearestThreatDistance = threat.Distance
                    nearestThreat = threat
                end
            end
            if nearestThreat and nearestThreat.Direction.Magnitude > 0.001 then
                local tangent = Vector3.new(
                    -nearestThreat.Direction.Z, 0, nearestThreat.Direction.X
                ) * strafeSide
                local mid = (CONFIG.STRAFE_DISTANCE_MIN
                    + CONFIG.STRAFE_DISTANCE_MAX) * 0.5
                local halfSpan = (CONFIG.STRAFE_DISTANCE_MAX
                    - CONFIG.STRAFE_DISTANCE_MIN) * 0.5
                local strafeScale = math.clamp(
                    1 - math.abs(nearestDistance - mid)
                        / math.max(halfSpan, 0.001),
                    0, 1
                )
                local strafed = unitOrZero(
                    result + tangent * CONFIG.STRAFE_WEIGHT * strafeScale
                )
                if strafed.Magnitude > 0.001 then
                    result = strafed
                end
            end
        end
    end
    -- 3) Juke: sudden short burst sideways (or a bait step back)
    --    with a mid-juke counter-flip — the classic pro feint.
    local jukeAllowed = nearestDistance > CONFIG.EMERGENCY_DISTANCE
    if CONFIG.JUKE_ENABLED and jukeAllowed then
        tryStartJuke(now, nearestDistance, emergency)
        if now < jukeActiveUntil then
            if not jukeCountered and now >= jukeCounterAt then
                jukeCountered = true
                jukePendingSide = -jukePendingSide
            end
            local side = Vector3.new(
                -desiredDirection.Z, 0, desiredDirection.X
            ) * jukePendingSide
            local jukeDir
            if jukeIsReverse and not jukeCountered and not emergency then
                jukeDir = unitOrZero(-desiredDirection * 0.55 + side * 0.85)
            else
                jukeDir = unitOrZero(side)
            end
            if jukeDir.Magnitude > 0.001 then
                local position = rootPart.Position
                local currentGroundY = getCurrentGroundY(position, raycastParams)
                local safe = hasSafeGround(
                        position, jukeDir, raycastParams, currentGroundY
                    )
                    and clearanceScore(
                        position, jukeDir, raycastParams, false
                    ) > 0.22
                if not safe then
                    local opposite = unitOrZero(-side)
                    safe = hasSafeGround(
                            position, opposite, raycastParams, currentGroundY
                        )
                        and clearanceScore(
                            position, opposite, raycastParams, false
                        ) > 0.22
                    if safe then
                        jukeDir = opposite
                    else
                        jukeDir = nil
                    end
                end
                if jukeDir then
                    result = jukeDir
                end
            end
        end
    end
    return result
end
--==============================================================
-- CHARACTER LIFECYCLE
--==============================================================
local function stopCharacterControl()
    alive = false
    plannedDirection = Vector3.zero
    selectedDirection = Vector3.zero
    commandDirection = Vector3.zero
    commandVelocity = Vector3.zero
    lastKnownGroundY = nil
    if humanoid and humanoid.Parent and wasControllingMovement then
        pcall(function()
            humanoid:Move(Vector3.zero, false)
        end)
    end
    table.clear(threats)
    table.clear(activeThreatsCache)
    disconnectAll(characterConnections)
    cancelPathfinding()
    resetProMovementState()
    character = nil
    humanoid = nil
    rootPart = nil
    wasControllingMovement = false
    progressPosition = nil
    stuckDirection = Vector3.zero
    stuckUntil = 0
    stuckStatusUntil = 0
    rebuildRaycastParams()
end
local function setupCharacter(newCharacter)
    characterGeneration = characterGeneration + 1
    local generation = characterGeneration
    stopCharacterControl()
    character = newCharacter
    rebuildRaycastParams()
    local newHumanoid = newCharacter:WaitForChild("Humanoid", 10)
    local newRoot = newCharacter:FindFirstChild("HumanoidRootPart")
    if not newRoot and newHumanoid then
        newRoot = newHumanoid.RootPart
    end
    if not newRoot then
        newRoot = newCharacter:WaitForChild("HumanoidRootPart", 3)
    end
    if not newRoot and newHumanoid then
        newRoot = newHumanoid.RootPart
    end
    if shuttingDown or generation ~= characterGeneration
        or LocalPlayer.Character ~= newCharacter then
        return
    end
    if not newHumanoid or not newRoot then
        setStatus("Персонаж не готов")
        updateGui()
        return
    end
    humanoid = newHumanoid
    rootPart = newRoot
    alive = humanoid.Health > 0
    lastHealthValue = humanoid.Health
    plannedDirection = Vector3.zero
    selectedDirection = Vector3.zero
    commandDirection = Vector3.zero
    commandVelocity = Vector3.zero
    lastKnownGroundY = nil
    wasControllingMovement = false
    lastScan = 0
    lastThink = 0
    lastProgressCheck = os.clock()
    progressPosition = rootPart.Position
    rebuildRaycastParams()
    getCurrentGroundY(rootPart.Position, raycastParams)
    table.insert(characterConnections, humanoid.Died:Connect(function()
        alive = false
        plannedDirection = Vector3.zero
        selectedDirection = Vector3.zero
        commandDirection = Vector3.zero
        commandVelocity = Vector3.zero
        table.clear(threats)
        table.clear(activeThreatsCache)
        cancelPathfinding()
        resetProMovementState()
        setStatus("Ждём респавн")
        updateGui()
    end))
    setStatus(alive and "Готов к выживанию" or "Ждём респавн")
    updateGui()
end
local function removeCharacter()
    characterGeneration = characterGeneration + 1
    stopCharacterControl()
    setStatus("Ждём респавн")
    updateGui()
end
--==============================================================
-- ENABLE / DISABLE
--==============================================================
setEnabled = function(value)
    if PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) ~= OWNER_TOKEN then
        return
    end
    enabled = value
    plannedDirection = Vector3.zero
    selectedDirection = Vector3.zero
    commandDirection = Vector3.zero
    wasControllingMovement = false
    stuckDirection = Vector3.zero
    stuckUntil = 0
    stuckStatusUntil = 0
    lastScan = 0
    lastThink = 0
    lastProgressCheck = os.clock()
    progressPosition = rootPart and rootPart.Position or nil
    table.clear(threats)
    table.clear(activeThreatsCache)
    resetProMovementState()
    if humanoid and humanoid.Parent then
        lastHealthValue = humanoid.Health
    end
    if not enabled then
        cancelPathfinding()
        if humanoid and humanoid.Parent then
            pcall(function()
                humanoid:Move(Vector3.zero, false)
            end)
        end
        setStatus("Обычное управление")
    else
        setStatus(alive and "Ищу угрозы" or "Жду персонажа")
    end
    updateGui()
end
table.insert(generalConnections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end
    if input.KeyCode == CONFIG.TOGGLE_KEY then
        setEnabled(not enabled)
    end
end))
--==============================================================
-- MAIN UPDATE
--==============================================================
local BIND_NAME = "SurvivalAI_Pirozhok_Control_" .. tostring(LocalPlayer.UserId)
RunService:UnbindFromRenderStep(BIND_NAME)
RunService:UnbindFromRenderStep("SurvivalAI_Pirozhok_Control")
local function updatePlanning()
    if shuttingDown
        or PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) ~= OWNER_TOKEN then
        plannedDirection = Vector3.zero
        return
    end
    if not enabled or not alive then
        plannedDirection = Vector3.zero
        return
    end
    if not character or not character.Parent
        or not humanoid or not humanoid.Parent
        or not rootPart or not rootPart.Parent
        or humanoid.Health <= 0 then
        plannedDirection = Vector3.zero
        return
    end
    if humanoid.Sit or humanoid.PlatformStand then
        plannedDirection = Vector3.zero
        commandDirection = Vector3.zero
        commandVelocity = Vector3.zero
        selectedDirection = Vector3.zero
        wasControllingMovement = false
        if activePath or pathRequestInFlight or pathNeedsReplan then
            cancelPathfinding()
        end
        setStatus("Не могу двигаться")
        updateGui()
        return
    end
    local now = os.clock()
    if now - lastScan >= CONFIG.SCAN_INTERVAL then
        lastScan = now
        local ok, err = pcall(scanThreats)
        if not ok then
            table.clear(threats)
            setStatus("Ошибка обнаружения")
            if CONFIG.DEBUG then
                warn("[SurvivalAI] Scan error:", err)
            end
        end
    end
    if now - lastThink >= CONFIG.THINK_INTERVAL then
        lastThink = now
        local stuckNow = checkProgress(now)
        activeThreatsCache = getActiveThreats()
        local activeThreats = activeThreatsCache
        -- v1.0: panic adaptation — taking damage near threats makes the
        -- AI temporarily play harder (faster jukes, wider serpentine).
        if CONFIG.PANIC_ENABLED and humanoid and humanoid.Parent then
            local healthNow = humanoid.Health
            if lastHealthValue ~= nil
                and healthNow <= lastHealthValue - CONFIG.PANIC_HEALTH_DROP
                and #activeThreats > 0 then
                panicUntil = now + CONFIG.PANIC_DURATION
            end
            lastHealthValue = healthNow
        end
        panicMode = now < panicUntil
        if #activeThreats > 0 then
            if now >= nextWeaveFlip then
                weaveSign = weaveSign * -1
                nextWeaveFlip = now + randomGenerator:NextNumber(
                    CONFIG.WEAVE_SWITCH_MIN,
                    CONFIG.WEAVE_SWITCH_MAX
                )
            end
            local ok, direction, status, needsPath = pcall(
                chooseEscapeDirection, activeThreats
            )
            if ok then
                selectedDirection = typeof(direction) == "Vector3"
                    and direction or Vector3.zero
                if now < stuckStatusUntil then
                    setStatus("Застрял — ищу другой путь")
                elseif status then
                    setStatus(status)
                end
                if stuckNow or selectedDirection.Magnitude < 0.001
                    or pathNeedsReplan or needsPath then
                    requestEscapePath(
                        activeThreats,
                        selectedDirection,
                        calculateEscapeBias(activeThreats)
                    )
                end
            else
                selectedDirection = Vector3.zero
                setStatus("Ошибка выбора пути")
                if CONFIG.DEBUG then
                    warn("[SurvivalAI] Decision error:", direction)
                end
                requestEscapePath(
                    activeThreats,
                    Vector3.zero,
                    calculateEscapeBias(activeThreats)
                )
            end
        else
            selectedDirection = Vector3.zero
            if #threats > 0 then
                setStatus("Наблюдаю издали")
            else
                setStatus("Рядом спокойно")
            end
            stuckDirection = Vector3.zero
            stuckUntil = 0
            if activePath or pathRequestInFlight or pathNeedsReplan then
                cancelPathfinding()
            end
        end
        updateGui()
    end
    local activeThreats = activeThreatsCache
    local directDirection = selectedDirection
    local emergency = #activeThreats > 0 and isEmergency(activeThreats)
    local pathLooksSafe = #activeThreats > 0
        and pathGoalStillLooksSafe(activeThreats)
    if activePath and not pathLooksSafe then
        pathNeedsReplan = true
    end
    local mayUsePath = #activeThreats > 0
        and not pathNeedsReplan
        and pathLooksSafe
        and (not emergency or directDirection.Magnitude < 0.001)
    local pathDirection = nil
    if mayUsePath then
        pathDirection = getPathDirection()
    end
    local desiredDirection = pathDirection or directDirection
    -- PRO LAYER: style is applied on top of the tactical decision,
    -- never while following a computed path route.
    if desiredDirection.Magnitude > 0.001 and #activeThreats > 0 then
        if not pathDirection then
            local okPro, proDirection = pcall(
                applyProMovement, desiredDirection, activeThreats, now, emergency
            )
            if okPro then
                if typeof(proDirection) == "Vector3"
                    and proDirection.Magnitude > 0.001 then
                    desiredDirection = proDirection
                end
            elseif CONFIG.DEBUG then
                warn("[SurvivalAI] Pro movement error:", proDirection)
            end
        end
        maybeJumpDodge(now, activeThreats, emergency)
    end
    plannedDirection = desiredDirection
end
table.insert(generalConnections, RunService.Heartbeat:Connect(updatePlanning))
RunService:BindToRenderStep(
    BIND_NAME,
    Enum.RenderPriority.Character.Value + 1,
    function(deltaTime)
        if shuttingDown
            or PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) ~= OWNER_TOKEN then
            return
        end
        if not enabled or not alive
            or not character or not character.Parent
            or not humanoid or not humanoid.Parent
            or not rootPart or not rootPart.Parent
            or humanoid.Health <= 0 then
            commandDirection = Vector3.zero
            commandVelocity = Vector3.zero
            if humanoid and humanoid.Parent and wasControllingMovement then
                pcall(function()
                    humanoid:Move(Vector3.zero, false)
                end)
                wasControllingMovement = false
            end
            return
        end
        if humanoid.Sit or humanoid.PlatformStand then
            commandDirection = Vector3.zero
            commandVelocity = Vector3.zero
            wasControllingMovement = false
            return
        end
        local desiredDirection = plannedDirection
        if desiredDirection.Magnitude > 0.001 then
            local dt = math.clamp(deltaTime, 0, 0.1)
            local emergency = #activeThreatsCache > 0
                and isEmergency(activeThreatsCache)
            local nowClock = os.clock()
            local jukeActive = nowClock < jukeActiveUntil
            local clutchActive = nowClock < clutchActiveUntil
            local response
            if emergency then
                response = CONFIG.EMERGENCY_TURN_RESPONSE
            elseif clutchActive then
                response = CONFIG.CLUTCH_TURN_RESPONSE
            elseif jukeActive then
                response = CONFIG.JUKE_TURN_RESPONSE
            else
                response = CONFIG.TURN_RESPONSE
            end
            if CONFIG.SPRING_SMOOTHING_ENABLED then
                -- v1.0: critically damped spring steering, substepped for
                -- stability. Gives human-like acceleration into turns and
                -- snappy recovery after jukes instead of a robotic lerp.
                local omega = response
                local zeta = CONFIG.SPRING_DAMPING_RATIO
                local remaining = dt
                local iterations = 0
                while remaining > 0.0001 and iterations < 8 do
                    local step = math.min(remaining, 1 / 120)
                    remaining = remaining - step
                    iterations = iterations + 1
                    local accel =
                        (desiredDirection - commandDirection) * (omega * omega)
                        - commandVelocity * (2 * zeta * omega)
                    commandVelocity = commandVelocity + accel * step
                    if commandVelocity.Magnitude > 30 then
                        commandVelocity = commandVelocity.Unit * 30
                    end
                    commandDirection = commandDirection + commandVelocity * step
                end
                if commandDirection.Magnitude > 1.25 then
                    commandDirection = commandDirection.Unit * 1.25
                end
            else
                local alpha = 1 - math.exp(-response * dt)
                if commandDirection.Magnitude < 0.001 then
                    commandDirection = desiredDirection
                else
                    commandDirection = commandDirection:Lerp(desiredDirection, alpha)
                end
            end
            commandDirection = unitOrZero(commandDirection)
            humanoid:Move(commandDirection, false)
            wasControllingMovement = true
        elseif #activeThreatsCache > 0 then
            commandDirection = Vector3.zero
            commandVelocity = Vector3.zero
            humanoid:Move(Vector3.zero, false)
            wasControllingMovement = true
        else
            commandDirection = Vector3.zero
            commandVelocity = Vector3.zero
            if wasControllingMovement then
                humanoid:Move(Vector3.zero, false)
                wasControllingMovement = false
            end
        end
    end
)
--==============================================================
-- STARTUP / CLEANUP
--==============================================================
table.insert(generalConnections, LocalPlayer.CharacterAdded:Connect(function(newCharacter)
    task.spawn(setupCharacter, newCharacter)
end))
table.insert(generalConnections, LocalPlayer.CharacterRemoving:Connect(removeCharacter))
if LocalPlayer.Character then
    task.spawn(setupCharacter, LocalPlayer.Character)
end
updateGui()
print("[SurvivalAI] Пирожок v1.0 loaded")
script.Destroying:Connect(function()
    shuttingDown = true
    characterGeneration = characterGeneration + 1
    plannedDirection = Vector3.zero
    RunService:UnbindFromRenderStep(BIND_NAME)
    disconnectAll(generalConnections)
    disconnectAll(characterConnections)
    disconnectAll(guiConnections)
    table.clear(activeTouches)
    finishDrag()
    cancelPathfinding()
    resetProMovementState()
    if humanoid and humanoid.Parent then
        pcall(function()
            humanoid:Move(Vector3.zero, false)
        end)
    end
    if screenGui and screenGui.Parent then
        screenGui:Destroy()
    end
    if PlayerScripts:GetAttribute(OWNER_ATTRIBUTE) == OWNER_TOKEN then
        PlayerScripts:SetAttribute(OWNER_ATTRIBUTE, nil)
    end
end)
