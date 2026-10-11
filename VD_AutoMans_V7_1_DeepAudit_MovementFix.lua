--[[
VD AUTO MANS V7.1 — DEEP AUDIT MOVEMENT FIX (compact touch panel)
Universal mode: no PlaceId restriction.

Client-side only: it steers your own character with Humanoid:Move and never
fires game remotes or attempts to read server-only scripts/modules. It can only infer threats
from replicated client-visible state; it cannot guarantee that an arbitrary game's hidden rules are known.

  * Detects hostile players, attack-like animations from unmarked players, visible NPC enemies/chases,
    predicted moving objects, and common named/tagged/flagged map hazards. It predicts approach paths
    and chooses short, scored dodges away from the most urgent visible threat. Heuristics are best-effort;
    unknown attack systems, hidden parts, server-only state, or generic animation names may be missed.
  * Point-blank killer: wall- and edge-aware close-range orbit, then control goes
    straight back to your joystick.
  * Never steers while you are hooked / carried / downed, frozen by the game
    (WalkSpeed ~ 0), climbing, seated, or while a "busy" attribute is set
    (CFG.BlockingAttributes: healing, repairing, vaulting, stunned, ...).
  * Reaction window widens a little on high ping (CFG.LatencyCompensation).
  * Compact pill: tap = ON/OFF, drag = move (stays on screen, position survives a
    UI rebuild). Dot: green = armed, blue = kiting, amber = dodge, red = close orbit.
  * Any error inside the script releases steering instead of leaving it stuck.

Soft kiting is enabled as short, interruptible movement pulses. A stuck detector
replans once and then releases steering if movement still fails. This is a client-side
prototype: server-side hitboxes, attack-specific mechanics, latency and executor
differences can still make a dodge miss, so judge it in a real match.
]]

-- Stop an older copy first so repeated executions do not duplicate connections.
local env = (getgenv and getgenv()) or _G
local previousStop = env.VD_AUTO_MANS_STOP or _G.VD_AUTO_MANS_STOP
if type(previousStop) == "function" then
    pcall(previousStop)
end

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

-- Safe to run from an auto-execute list: wait for the game and the local player.
if not game:IsLoaded() then game.Loaded:Wait() end
local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait()
    LocalPlayer = Players.LocalPlayer
end

local CFG = {
    -- Start safely paused. Tap the pill to enable Auto Mans.
    Enabled = false,

    -- Never steer while the game is holding you still or you are busy.
    FrozenWalkSpeed = 0.5, -- WalkSpeed at/below this = the game froze you (interaction, stun, lock)
    BlockingAttributes = { -- any of these set to true on your character or player = hands off
        "IsHooked", "IsCarried", "Knocked", "Downed", "IsDowned", "IsDead", "Dead",
        "Stunned", "IsStunned", "Interacting", "IsInteracting",
        "Healing", "IsHealing", "Repairing", "IsRepairing",
        "Vaulting", "IsVaulting", "InLocker", "Hiding", "IsHiding",
    },

    -- Widen reaction windows by up to LatencyMaxLead seconds (half of your ping).
    LatencyCompensation = true,
    LatencyMaxLead = 0.10,

    -- Animation listener watches every animation, then scores whether the
    -- situation is dangerous rather than blindly dodging every idle animation.
    AnimationTrigger = true,
    AnimationRange = 21,
    CriticalAnimationRange = 4.5,
    AttackAnimationRange = 11.0, -- a named attack cue is trusted only in the plausible attack zone
    AttackAnimationLead = 0.16, -- brief early step when the attack animation first begins
    EmergencyTakeoverRange = 4.6, -- full movement takeover only at point-blank range
    EmergencyTakeoverReleaseRange = 6.2, -- release with a small hysteresis margin
    MaxThreatVerticalSeparation = 5.5, -- avoid reacting to players on another floor
    CriticalVerticalSeparation = 3.5, -- close orbit is allowed only on the same level
    CloseOrbitTimeout = 3.0, -- failsafe cap; normally ends after an actual full revolution
    CloseOrbitTargetRadius = 3.8,
    OrbitReplanInterval = 0.12,
    OrbitTangentWeight = 1.0,
    StuckCheckInterval = 0.14, -- close orbit gets a little more time to accumulate progress
    ShortStuckCheckInterval = 0.18, -- avoid false stuck alarms during the first movement/network beat
    StuckMinProgress = 0.22,
    CloseFacingRange = 8,
    MinimumClosingSpeed = 1.0,
    FacingDotThreshold = 0.12,
    AttackNameHints = true,

    -- Prediction of the killer's future position.
    PlayerPrediction = true,
    PlayerScanRange = 32,
    PlayerHorizon = 0.95,
    PlayerThreatRadius = 4.6,
    MinimumApproachSpeed = 1.8,
    MinimumClosingSpeedForPrediction = 0.55,
    RequireLineOfSight = true,

    -- Adaptive NPC awareness: explicit enemy markers win; otherwise only infer
    -- hostility from a close, visible chase/approach to avoid dodging every civilian.
    NPCPrediction = true,
    NPCScanRange = 30,
    NPCThreatRadius = 5.0,
    NPCInferRange = 19,
    NPCMinClosingSpeed = 0.65,
    NPCRecheckSeconds = 0.085,

    -- Best-effort detection of fast, unanchored moving objects.
    ProjectilePrediction = true,
    ProjectileHorizon = 0.90,
    ProjectileThreatRadius = 3.8,
    ProjectileMinSpeed = 10.0,
    NamedProjectileMinSpeed = 3.0,
    ProjectileMaxDistance = 100,
    ProjectileLifetime = 4.5,
    MaxTrackedParts = 280,
    InitialScanYieldEvery = 300,
    NewPartDelay = 0.04,

    -- Environmental hazard awareness. Detection is best-effort and uses visible
    -- object names/attributes; unknown server-only hazards cannot be inferred.
    EnvironmentHazards = true,
    HazardScanRadius = 38,
    HazardTriggerDistance = 4.0,
    HazardLookAheadDistance = 10.0,
    HazardLookAheadTime = 0.85,
    HazardVerticalTolerance = 7.0,
    HazardRearmSeconds = 0.48,
    MaxTrackedHazardParts = 420,
    HazardNameHints = {
        "tesla", "hook", "trap", "mine", "spike", "laser", "hazard",
        "electric", "shock", "explosive", "bomb", "snare", "barbed",
        "sawblade", "turret", "toxic", "acid", "poison", "firetrap",
    },

    -- Smart movement / steering.
    DodgeDuration = 0.28,
    KillerCooldown = 0.16,
    MinimumDodgeInterval = 0.18,
    -- Proactive kiting: start creating space before a hit is imminent.
    -- No continuous chase/spacing movement; only brief threat-response dodges.
    KiteEnabled = true,
    -- Soft kiting: begin creating space before the killer is point-blank,
    -- but use short movement pulses with a deliberate hand-back gap.
    KiteStartRange = 18.0,
    KiteReleaseRange = 22.0,
    KiteHardRange = 8.5,
    KiteClosingThreshold = 0.25,
    KitePulseDuration = 0.22,
    KiteRestDuration = 0.16,
    KiteReplanInterval = 0.10,
    KiteAwayWeight = 3.6,
    KiteSideWeight = 0.80,
    ProbeDistance = 5.4,
    MinimumWallClearance = 0.85,
    GroundProbeAhead = 2.7,
    GroundProbeDepth = 8.5,
    MaxGroundDropAhead = 2.6, -- avoid routes that require walking off a ledge
    MaxGroundRiseAhead = 4.2, -- reject tall walls/steps the current movement cannot safely climb
    MaxGroundGapWhenAirborne = 5.2, -- if airborne, do not steer toward a distant lower floor
    CandidateCount = 8,
    RetargetFraction = 0.44,
    CandidateThreatCount = 6,
    PlayerMotionFactor = 0.83,
    NearThreatExtraAway = 0.7,
    SideBias = 0.28,
    PredictionInterval = 0.045,

    -- Short dodges get light style variation; close-range orbit has its own steering.
    MovementStylesEnabled = true,
    StyleCycleDuration = 0.46,
    StyleBlendDuration = 0.10,
    StyleSafetyInterval = 0.10,
    SteeringSmoothingSeconds = 0.075,
    StyleRadialKeepout = 0.55,

    -- Manual controls always win over automation.
    ManualInputThreshold = 0.18,
    ManualInputGrace = 0.28,
}

local shuttingDown = false
local connections = {}
local uiConnections = {}
local playerConnections = {}
local characterConnections = {}
local watchedCharacters = setmetatable({}, { __mode = "k" })
local characterTokens = setmetatable({}, { __mode = "k" })
local lastByKiller = setmetatable({}, { __mode = "k" })
local trackedParts = setmetatable({}, { __mode = "k" })
local trackedHazards = setmetatable({}, { __mode = "k" })
local trackedHazardCount = 0
local npcCandidates = setmetatable({}, { __mode = "k" })
local npcAnimationConnections = setmetatable({}, { __mode = "k" })
local npcAnimationPending = setmetatable({}, { __mode = "k" })
local watchNpcAnimations
local npcThreatCacheAt = -math.huge
local npcThreatCacheRoot = nil
local npcThreatCache = {}
local taggedHazardRoots = setmetatable({}, { __mode = "k" })
local HAZARD_COLLECTION_TAGS = { "Hazard", "Dangerous", "Trap", "Tesla", "Hook", "Lethal" }
local hazardThreatCacheAt = -math.huge
local hazardThreatCacheRoot = nil
local hazardThreatCacheRadius = nil
local hazardThreatCache = {}
local HAZARD_CACHE_SECONDS = 0.085
local lastHazardDodgeAt = setmetatable({}, { __mode = "k" })

local activeDodge = nil
local lastDodge = -math.huge
local lastPrediction = 0
local nextKitePulseAt = 0
local preferredSide = 1
local kiteFocusCharacter = nil
local kitePatternTarget = nil
local kitePatternStartAt = 0
local kiteStyleOffset = 1
local kitePatternSide = 1
local gui = nil
local authenticated = false -- UI gate only; this does not encrypt or protect the source code
local statusLabel = nil
local detailLabel = nil
local toggleButton = nil
local trackedCount = 0
local savedPanelPosition = nil
local indicatorDot = nil
local indicatorStroke = nil
local indicatorState = nil
local lastErrorWarnAt = {}

-- Manual movement ownership: use the default PlayerModule controls when available,
-- with keyboard/gamepad/touch-intent fallback for custom executors or control schemes.
local playerControls = nil
local manualOverrideUntil = 0
local heldMovementKeys = {}
local gamepadMoveUntil = 0
local touchStarts = setmetatable({}, { __mode = "k" })
local MOVEMENT_KEYS = {
    [Enum.KeyCode.W] = true, [Enum.KeyCode.A] = true,
    [Enum.KeyCode.S] = true, [Enum.KeyCode.D] = true,
    [Enum.KeyCode.Up] = true, [Enum.KeyCode.Down] = true,
    [Enum.KeyCode.Left] = true, [Enum.KeyCode.Right] = true,
}

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

local function disconnect(connection)
    if connection then
        pcall(function() connection:Disconnect() end)
    end
end

local function connectUI(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(uiConnections, connection)
    return connection
end

-- Cache hazard tags once and update the cache by signals; this avoids repeated
-- CollectionService queries for every ancestor of every map part on mobile.
for _, hazardTag in ipairs(HAZARD_COLLECTION_TAGS) do
    local ok, taggedInstances = pcall(CollectionService.GetTagged, CollectionService, hazardTag)
    if ok then
        for _, taggedInstance in ipairs(taggedInstances) do
            taggedHazardRoots[taggedInstance] = hazardTag
        end
    end
    connect(CollectionService:GetInstanceAddedSignal(hazardTag), function(instance)
        taggedHazardRoots[instance] = hazardTag
        hazardThreatCacheAt = -math.huge
    end)
    connect(CollectionService:GetInstanceRemovedSignal(hazardTag), function(instance)
        if taggedHazardRoots[instance] == hazardTag then
            taggedHazardRoots[instance] = nil
        end
        hazardThreatCacheAt = -math.huge
    end)
end

-- Run a callback under pcall: warn (rate-limited) instead of spamming errors, and
-- run onError (used to hand steering back to the player).
local function guarded(name, callback, onError)
    return function(...)
        local ok, err = pcall(callback, ...)
        if not ok then
            local now = os.clock()
            if now - (lastErrorWarnAt[name] or -math.huge) > 5 then
                lastErrorWarnAt[name] = now
                warn("[VD Auto Mans V7.1] " .. name .. " error: " .. tostring(err))
            end
            if onError then pcall(onError) end
        end
    end
end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

-- Half of the round-trip ping, capped: how much earlier to react so the dodge
-- input reaches the server before the hit does.
local cachedLead, cachedLeadAt = 0, -math.huge
local function latencyLead()
    if not CFG.LatencyCompensation then return 0 end
    local now = os.clock()
    if now - cachedLeadAt < 0.25 then return cachedLead end -- ping changes slowly
    cachedLeadAt = now
    local ok, ping = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
    if ok and type(ping) == "number" then
        cachedLead = math.clamp(ping * 0.5, 0, math.max(0, CFG.LatencyMaxLead))
    else
        cachedLead = 0
    end
    return cachedLead
end

local function unitOrZero(v)
    if v.Magnitude < 0.001 then return Vector3.zero end
    return v.Unit
end

local function markManualInput()
    local now = os.clock()
    manualOverrideUntil = math.max(manualOverrideUntil, now + CFG.ManualInputGrace)
    -- A human movement input immediately cancels our command; never fight the joystick.
    activeDodge = nil
    nextKitePulseAt = math.max(nextKitePulseAt, now + CFG.ManualInputGrace)
end

local function isLikelyJoystickZone(position)
    local camera = Workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize
    if not viewport or viewport.X <= 0 or viewport.Y <= 0 then return false end
    -- Roblox's default mobile thumbstick is normally in the lower-left region.
    -- This is only a fallback; PlayerModule.GetMoveVector is preferred when present.
    return position.X <= viewport.X * 0.58 and position.Y >= viewport.Y * 0.28
end

local function initializePlayerControls()
    while not shuttingDown and not playerControls do
        local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local module = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if module and module:IsA("ModuleScript") then
            local okModule, playerModule = pcall(require, module)
            if okModule and type(playerModule) == "table" and type(playerModule.GetControls) == "function" then
                local okControls, controls = pcall(playerModule.GetControls, playerModule)
                if okControls and controls and type(controls.GetMoveVector) == "function" then
                    playerControls = controls
                    return
                end
            end
        end
        task.wait(1)
    end
end

task.spawn(initializePlayerControls)

local function manualMovementActive(now)
    now = now or os.clock()
    if next(heldMovementKeys) ~= nil or now < gamepadMoveUntil then
        return true
    end

    -- A moved touch begun in the joystick zone remains a manual claim until TouchEnded.
    for _, touchInfo in pairs(touchStarts) do
        if touchInfo.joystick and touchInfo.moved then return true end
    end

    if playerControls and type(playerControls.GetMoveVector) == "function" then
        local ok, moveVector = pcall(playerControls.GetMoveVector, playerControls)
        if ok and typeof(moveVector) == "Vector3" then
            local magnitude = Vector3.new(moveVector.X, 0, moveVector.Z).Magnitude
            if magnitude >= CFG.ManualInputThreshold then
                manualOverrideUntil = math.max(manualOverrideUntil, now + CFG.ManualInputGrace)
                return true
            end
        end
    end
    return now < manualOverrideUntil
end

-- Track only actual movement intent, not camera drags or taps on the panel.
connect(UserInputService.InputBegan, function(input)
    if shuttingDown or not CFG.Enabled then return end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        if not UserInputService:GetFocusedTextBox() and MOVEMENT_KEYS[input.KeyCode] then
            heldMovementKeys[input.KeyCode] = true
            markManualInput()
        end
    elseif input.UserInputType == Enum.UserInputType.Touch then
        touchStarts[input] = {
            start = input.Position,
            joystick = isLikelyJoystickZone(input.Position),
            moved = false,
        }
    end
end)

connect(UserInputService.InputChanged, function(input)
    if shuttingDown or not CFG.Enabled then return end
    if input.UserInputType == Enum.UserInputType.Touch then
        local touchInfo = touchStarts[input]
        if touchInfo and touchInfo.joystick
            and (input.Position - touchInfo.start).Magnitude >= 9 then
            touchInfo.moved = true
            markManualInput()
        end
    elseif input.UserInputType == Enum.UserInputType.Gamepad1
        and input.KeyCode == Enum.KeyCode.Thumbstick1
        and Vector3.new(input.Position.X, input.Position.Y, 0).Magnitude >= CFG.ManualInputThreshold then
        gamepadMoveUntil = os.clock() + 0.12
        markManualInput()
    end
end)

connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then
        heldMovementKeys[input.KeyCode] = nil
    elseif input.UserInputType == Enum.UserInputType.Touch then
        touchStarts[input] = nil
    elseif input.UserInputType == Enum.UserInputType.Gamepad1
        and input.KeyCode == Enum.KeyCode.Thumbstick1 then
        gamepadMoveUntil = 0
    end
end)

-- Focus loss can suppress a matching InputEnded on some platforms. Clear fallback
-- input claims so a stale key/touch cannot permanently disable automation.
pcall(function()
    connect(UserInputService.WindowFocusReleased, function()
        table.clear(heldMovementKeys)
        table.clear(touchStarts)
        gamepadMoveUntil = 0
        manualOverrideUntil = math.max(manualOverrideUntil, os.clock() + 0.18)
    end)
end)

local function setStatus(message, detail)
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = message
    end
    if detailLabel and detailLabel.Parent and detail then
        detailLabel.Text = detail
    end
end

local HOSTILE_ROLE_HINTS = {
    "killer", "hunter", "enemy", "hostile", "monster", "zombie", "infected",
    "murderer", "assassin", "slasher", "attacker", "raider", "opponent", "beast",
}
local NEUTRAL_TEAM_HINTS = { "spectator", "spectators", "lobby", "neutral", "waiting", "observer" }
local HOSTILE_BOOLEAN_ATTRIBUTES = { "Killer", "Hostile", "Enemy", "IsEnemy", "IsHostile" }
local NPC_FRIENDLY_HINTS = {
    "friendly", "civilian", "shopkeeper", "merchant", "vendor", "villager",
    "companion", "pet", "ally", "neutral", "trainingdummy", "targetdummy",
    "dummy", "survivor", "spectator", "observer", "questgiver",
}
local NPC_HOSTILE_TAGS = {
    "Hostile", "Enemy", "NPCEnemy", "Monster", "Killer", "Dangerous", "Aggressive",
}
local NPC_HOSTILE_NAME_HINTS = {
    "boss", "creature", "demon", "skeleton", "ghost", "wraith", "brute",
    "chaser", "mutant", "alien", "enemybot", "killerbot", "guardbot", "turret",
}
local NPC_HOSTILE_ATTRIBUTE_NAMES = {
    hostile = true, enemy = true, isenemy = true, ishostile = true,
    iskiller = true, killer = true, aggressive = true, canattack = true,
    attackplayers = true, ismonster = true, npcenemy = true, threat = true,
}

local function containsAnyHint(value, hints)
    value = string.lower(tostring(value or ""))
    for _, hint in ipairs(hints) do
        if string.find(value, hint, 1, true) then return true end
    end
    return false
end

-- Kept under the original helper name to preserve all existing call sites.
-- On unfamiliar games, a different non-neutral team is treated as hostile.
local function isKiller(player)
    if not player then return false end

    local teamName = player.Team and player.Team.Name or ""
    if containsAnyHint(teamName, HOSTILE_ROLE_HINTS) then return true end

    local role = player:GetAttribute("Role")
    if containsAnyHint(role, HOSTILE_ROLE_HINTS) then return true end

    for _, attributeName in ipairs(HOSTILE_BOOLEAN_ATTRIBUTES) do
        if player:GetAttribute(attributeName) == true then return true end
        local character = player.Character
        if character and character:GetAttribute(attributeName) == true then return true end
    end

    if player ~= LocalPlayer and player.Team and LocalPlayer.Team and player.Team ~= LocalPlayer.Team
        and not containsAnyHint(teamName, NEUTRAL_TEAM_HINTS) then
        return true
    end
    return false
end

local function isLocalKillerRole()
    local teamName = LocalPlayer.Team and LocalPlayer.Team.Name or ""
    if containsAnyHint(teamName, HOSTILE_ROLE_HINTS) then return true end

    local role = LocalPlayer:GetAttribute("Role")
    if containsAnyHint(role, HOSTILE_ROLE_HINTS) then return true end

    for _, attributeName in ipairs(HOSTILE_BOOLEAN_ATTRIBUTES) do
        if LocalPlayer:GetAttribute(attributeName) == true then return true end
        local character = LocalPlayer.Character
        if character and character:GetAttribute(attributeName) == true then return true end
    end
    return false
end

local function getCharacterParts(character)
    if not character then return nil, nil end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("RootPart")
        or character.PrimaryPart

    if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
        return nil, nil
    end
    return humanoid, root
end

local function registerNpcModel(model)
    if not CFG.NPCPrediction or not model or not model:IsA("Model") then return end
    if model == LocalPlayer.Character or Players:GetPlayerFromCharacter(model) then return end
    if not model:IsDescendantOf(Workspace) then return end
    local humanoid, root = getCharacterParts(model)
    if humanoid and root then
        npcCandidates[model] = true
        npcThreatCacheAt = -math.huge
        if watchNpcAnimations and not npcAnimationConnections[model] and not npcAnimationPending[model] then
            npcAnimationPending[model] = true
            task.defer(function()
                if not shuttingDown and npcCandidates[model] and watchNpcAnimations then
                    watchNpcAnimations(model)
                else
                    npcAnimationPending[model] = nil
                end
            end)
        end
    end
end

local function unregisterNpcModel(model)
    if model and npcCandidates[model] then
        npcCandidates[model] = nil
        npcThreatCacheAt = -math.huge
    end
    if model then
        disconnect(npcAnimationConnections[model])
        npcAnimationConnections[model] = nil
        npcAnimationPending[model] = nil
    end
end

local function classifyNpc(model, humanoid)
    local explicitHostile = false
    local explicitlyFriendly = false
    local current = model
    local depth = 0
    while current and current ~= Workspace and depth < 5 do
        local nameLower = string.lower(current.Name or "")
        if containsAnyHint(nameLower, NPC_FRIENDLY_HINTS) then
            explicitlyFriendly = true
        end
        if containsAnyHint(nameLower, HOSTILE_ROLE_HINTS)
            or containsAnyHint(nameLower, NPC_HOSTILE_NAME_HINTS) then
            explicitHostile = true
        end
        for attributeName, value in pairs(current:GetAttributes()) do
            local key = string.lower(tostring(attributeName)):gsub("[^%a]", "")
            if value == true and NPC_HOSTILE_ATTRIBUTE_NAMES[key] then
                explicitHostile = true
            elseif type(value) == "string" then
                local v = string.lower(value)
                if (key == "role" or key == "team" or key == "faction" or key == "threattype")
                    and (containsAnyHint(v, HOSTILE_ROLE_HINTS) or containsAnyHint(v, NPC_HOSTILE_NAME_HINTS)) then
                    explicitHostile = true
                elseif (key == "role" or key == "team" or key == "faction")
                    and containsAnyHint(v, NPC_FRIENDLY_HINTS) then
                    explicitlyFriendly = true
                end
            end
        end
        local ok, tags = pcall(CollectionService.GetTags, CollectionService, current)
        if ok then
            for _, tag in ipairs(tags) do
                if containsAnyHint(tag, NPC_HOSTILE_TAGS) then explicitHostile = true end
                if containsAnyHint(tag, NPC_FRIENDLY_HINTS) then explicitlyFriendly = true end
            end
        end
        current = current.Parent
        depth = depth + 1
    end

    if humanoid then
        for attributeName, value in pairs(humanoid:GetAttributes()) do
            local key = string.lower(tostring(attributeName)):gsub("[^%a]", "")
            if value == true and NPC_HOSTILE_ATTRIBUTE_NAMES[key] then explicitHostile = true end
            if type(value) == "string" and (key == "role" or key == "faction")
                and containsAnyHint(value, HOSTILE_ROLE_HINTS) then
                explicitHostile = true
            end
        end
    end

    -- Explicit hostile markers take precedence over a friendly-looking model name.
    if explicitHostile then return true, false end
    if explicitlyFriendly then return false, true end
    return false, false
end

local BLOCKED_STATES = {}
for _, stateName in ipairs({ "Climbing", "Seated", "Ragdoll", "FallingDown", "Physics", "PlatformStanding", "Dead" }) do
    local ok, state = pcall(function() return Enum.HumanoidStateType[stateName] end)
    if ok and state then BLOCKED_STATES[state] = true end
end

local BLOCKING_ATTRIBUTES = {}
for _, attributeName in ipairs(CFG.BlockingAttributes) do
    BLOCKING_ATTRIBUTES[attributeName] = true
end

local function hasBlockingAttribute(instance)
    for name, value in pairs(instance:GetAttributes()) do
        if value == true and BLOCKING_ATTRIBUTES[name] then return true end
    end
    return false
end

local function localCharacterBlocked(character, humanoid)
    if not character or not character.Parent or not humanoid then return true end
    if humanoid.Health <= 0 or humanoid.Sit or humanoid.PlatformStand then return true end

    -- The game is holding you still (interaction / stun / lock): there is nothing to steer.
    if humanoid.WalkSpeed <= CFG.FrozenWalkSpeed then return true end
    local stateOk, state = pcall(function() return humanoid:GetState() end)
    if stateOk and BLOCKED_STATES[state] then return true end
    local rootPart = humanoid.RootPart
    if rootPart and rootPart.Anchored then return true end

    if hasBlockingAttribute(character) or hasBlockingAttribute(LocalPlayer) then return true end
    return false
end

local function isCharacterPart(instance)
    local parent = instance
    while parent and parent ~= Workspace do
        if parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") then
            return true
        end
        parent = parent.Parent
    end
    return false
end

local moveRayParams = RaycastParams.new()
moveRayParams.FilterType = Enum.RaycastFilterType.Exclude
moveRayParams.IgnoreWater = true
pcall(function() moveRayParams.RespectCanCollide = true end)

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
groundRayParams.IgnoreWater = true
pcall(function() groundRayParams.RespectCanCollide = true end)

local function buildCharacterExclusions(includeAllPlayers)
    local excluded = {}
    if LocalPlayer.Character then table.insert(excluded, LocalPlayer.Character) end
    if includeAllPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                table.insert(excluded, player.Character)
            end
        end
    end
    return excluded
end

local function makeMovementQueryContext(root)
    local exclusions = buildCharacterExclusions(true)
    moveRayParams.FilterDescendantsInstances = exclusions
    groundRayParams.FilterDescendantsInstances = exclusions
    local currentGround = Workspace:Raycast(
        root.Position + Vector3.new(0, 2.8, 0),
        Vector3.new(0, -CFG.GroundProbeDepth, 0),
        groundRayParams
    )
    return { currentGround = currentGround }
end

local function directionClearance(root, direction, context)
    direction = unitOrZero(flat(direction))
    if direction.Magnitude < 0.01 then return nil, 0 end
    context = context or makeMovementQueryContext(root)

    local clearance = CFG.ProbeDistance
    local bodyCFrame = root.CFrame + Vector3.new(0, -0.15, 0)
    local blockcastOk, bodyHit = pcall(function()
        return Workspace:Blockcast(
            bodyCFrame,
            Vector3.new(1.8, 3.0, 1.8),
            direction * CFG.ProbeDistance,
            moveRayParams
        )
    end)
    if blockcastOk and bodyHit then
        clearance = math.min(clearance, math.max(0, bodyHit.Distance - 0.25))
    elseif not blockcastOk then
        -- Runtime fallback: if shapecasts are unavailable, probe both sides too.
        local right = Vector3.new(-direction.Z, 0, direction.X)
        for _, lateralOffset in ipairs({ -0.58, 0.58 }) do
            local origin = root.Position + Vector3.new(0, -0.80, 0) + right * lateralOffset
            local sideHit = Workspace:Raycast(origin, direction * CFG.ProbeDistance, moveRayParams)
            if sideHit then
                clearance = math.min(clearance, math.max(0, sideHit.Distance - 0.25))
            end
        end
    end

    -- Keep a low center ray for legacy maps and as a fallback if Blockcast is
    -- unsupported by an executor/runtime. The full-width Blockcast handles lateral walls.
    local centerOrigin = root.Position + Vector3.new(0, -0.80, 0)
    local centerHit = Workspace:Raycast(centerOrigin, direction * CFG.ProbeDistance, moveRayParams)
    if centerHit then
        clearance = math.min(clearance, math.max(0, centerHit.Distance - 0.25))
    end
    if clearance < CFG.MinimumWallClearance then return nil, clearance end

    local groundOrigin = root.Position
        + direction * CFG.GroundProbeAhead
        + Vector3.new(0, 2.8, 0)
    local ground = Workspace:Raycast(
        groundOrigin,
        Vector3.new(0, -CFG.GroundProbeDepth, 0),
        groundRayParams
    )
    if not ground or ground.Normal.Y < 0.45 then return nil, clearance end

    local currentGround = context.currentGround
    if currentGround and currentGround.Normal.Y >= 0.45 then
        local floorDelta = currentGround.Position.Y - ground.Position.Y
        if floorDelta > CFG.MaxGroundDropAhead then return nil, clearance end
        if -floorDelta > CFG.MaxGroundRiseAhead then return nil, clearance end
    elseif (root.Position.Y - ground.Position.Y) > CFG.MaxGroundGapWhenAirborne then
        return nil, clearance
    end

    return direction, clearance
end

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.IgnoreWater = true
-- Invisible, non-collidable trigger zones must not count as walls.
pcall(function() losParams.RespectCanCollide = true end)

local function hasLineOfSight(myRoot, targetRoot, targetCharacter)
    if not myRoot or not targetRoot or not myRoot.Parent or not targetRoot.Parent then
        return false
    end

    -- Characters never block a view (other survivors included); only the world does.
    local exclusions = buildCharacterExclusions(true)
    if targetCharacter then table.insert(exclusions, targetCharacter) end
    losParams.FilterDescendantsInstances = exclusions

    local origin = myRoot.Position + Vector3.new(0, 1.2, 0)
    return Workspace:Raycast(origin, targetRoot.Position - origin, losParams) == nil
end

local function hasProjectileLineOfSight(myRoot, projectile)
    if not myRoot or not myRoot.Parent or not projectile or not projectile.Parent then
        return false
    end
    -- Ignore avatars but respect collidable map geometry. This trims false alarms
    -- from fast decorative parts or projectiles that cannot currently reach us.
    local exclusions = buildCharacterExclusions(true)
    table.insert(exclusions, projectile)
    if projectile.Parent and projectile.Parent:IsA("Model") then
        table.insert(exclusions, projectile.Parent)
    end
    losParams.FilterDescendantsInstances = exclusions
    local origin = projectile.Position
    local ray = myRoot.Position - origin
    if ray.Magnitude < 0.1 then return true end
    return Workspace:Raycast(origin, ray, losParams) == nil
end

local function attackLike(track)
    if not CFG.AttackNameHints or not track then return false end

    local names = {}
    pcall(function() table.insert(names, string.lower(track.Name or "")) end)
    pcall(function()
        if track.Animation then
            table.insert(names, string.lower(track.Animation.Name or ""))
        end
    end)

    local hints = { "attack", "lunge", "slash", "swing", "stab", "hit", "throw", "charge", "skill", "dash", "strike" }
    for _, name in ipairs(names) do
        for _, hint in ipairs(hints) do
            if string.find(name, hint, 1, true) then return true end
        end
    end
    return false
end

local function closingSpeed(myRoot, enemyRoot)
    local offset = flat(myRoot.Position - enemyRoot.Position)
    if offset.Magnitude < 0.05 then return 999 end
    local relativeVelocity = flat(myRoot.AssemblyLinearVelocity - enemyRoot.AssemblyLinearVelocity)
    return -relativeVelocity:Dot(offset.Unit)
end

local function facingUs(myRoot, enemyRoot)
    local toSurvivor = unitOrZero(flat(myRoot.Position - enemyRoot.Position))
    if toSurvivor.Magnitude < 0.05 then return true end
    local look = unitOrZero(flat(enemyRoot.CFrame.LookVector))
    if look.Magnitude < 0.05 then return false end
    return look:Dot(toSurvivor) >= CFG.FacingDotThreshold
end

-- Predict the closest approach between player and killer within a short horizon.
local function predictKillerThreat(myRoot, killerCharacter)
    local _, killerRoot = getCharacterParts(killerCharacter)
    if not killerRoot then return nil end

    local offset = flat(killerRoot.Position - myRoot.Position)
    local distance = offset.Magnitude
    if math.abs(killerRoot.Position.Y - myRoot.Position.Y) > CFG.MaxThreatVerticalSeparation then
        return nil
    end
    if distance < 0.1 or distance > CFG.PlayerScanRange then return nil end

    local relativeVelocity = flat(killerRoot.AssemblyLinearVelocity - myRoot.AssemblyLinearVelocity)
    local speedSquared = relativeVelocity:Dot(relativeVelocity)
    if speedSquared < CFG.MinimumApproachSpeed ^ 2 then return nil end

    local t = math.clamp(-offset:Dot(relativeVelocity) / speedSquared, 0, CFG.PlayerHorizon)
    local closest = offset + relativeVelocity * t
    local missDistance = closest.Magnitude
    local closing = -offset:Dot(relativeVelocity) / math.max(distance, 0.1)

    if closing <= CFG.MinimumClosingSpeedForPrediction or missDistance > CFG.PlayerThreatRadius then
        return nil
    end
    if t <= 0.035 and distance > CFG.PlayerThreatRadius then return nil end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, killerRoot, killerCharacter) then
        return nil
    end

    return {
        score = t + missDistance * 0.06,
        time = t,
        position = killerRoot.Position,
        velocity = killerRoot.AssemblyLinearVelocity,
        kind = "approach prediction",
        killerCharacter = killerCharacter,
        sourceRoot = killerRoot,
    }
end

-- Some free-for-all games leave Team/Role unset. Infer a threat only when a
-- visible, unteamed player is actually closing on a plausible intercept course.
local function predictUnmarkedPlayerThreat(myRoot, player)
    if not player or player == LocalPlayer or isKiller(player) then return nil end
    if player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team then return nil end
    local character = player.Character
    local _, enemyRoot = getCharacterParts(character)
    if not enemyRoot then return nil end

    local offset = flat(enemyRoot.Position - myRoot.Position)
    local distance = offset.Magnitude
    if distance < 0.1 or distance > CFG.NPCInferRange + 4 then return nil end
    if math.abs(enemyRoot.Position.Y - myRoot.Position.Y) > CFG.MaxThreatVerticalSeparation then return nil end

    local closing = closingSpeed(myRoot, enemyRoot)
    local facing = facingUs(myRoot, enemyRoot)
    if closing < CFG.NPCMinClosingSpeed or not facing then return nil end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, enemyRoot, character) then return nil end

    local threat = predictKillerThreat(myRoot, character)
    if threat then
        threat.kind = "inferred unmarked player approach"
        threat.inferred = true
        return threat
    end
    return nil
end

local function untrackPart(part)
    if trackedParts[part] ~= nil then
        trackedParts[part] = nil
        trackedCount = math.max(0, trackedCount - 1)
    end
end

-- Explicit flags are useful for maps that do not name their parts descriptively.
local HAZARD_TRUE_ATTRIBUTES = {
    ishazard = true, hazard = true, dangerous = true, istrap = true, trap = true,
    istesla = true, ishook = true, ismine = true, isdamaging = true,
    candamage = true, dealdamage = true, lethal = true, killontouch = true,
}
local HAZARD_STATE_ATTRIBUTES = {
    active = true, isactive = true, enabled = true, powered = true,
    armed = true, on = true,
}

local function getHazardRootForPart(part)
    if not CFG.EnvironmentHazards or not part or not part:IsA("BasePart") then return nil end
    local current = part
    local depth = 0
    while current and current ~= Workspace and depth < 8 do
        local attrs = current:GetAttributes()
        for name, value in pairs(attrs) do
            local normalized = string.lower(name):gsub("[^%a]", "")
            if value == true and HAZARD_TRUE_ATTRIBUTES[normalized] then
                return current, "tagged hazard"
            end
            if type(value) == "string"
                and (normalized == "hazardtype" or normalized == "hazardkind" or normalized == "threattype")
                and value ~= "" then
                return current, string.lower(value)
            end
        end
        local cachedTag = taggedHazardRoots[current]
        if cachedTag then return current, string.lower(cachedTag) end
        local nameLower = string.lower(current.Name)
        for _, hint in ipairs(CFG.HazardNameHints) do
            if string.find(nameLower, hint, 1, true) then
                return current, hint
            end
        end
        current = current.Parent
        depth = depth + 1
    end
    return nil
end

local function hazardExplicitlyInactive(part, hazardRoot)
    local current = part
    local depth = 0
    while current and depth < 8 do
        for name, value in pairs(current:GetAttributes()) do
            local normalized = string.lower(name):gsub("[^%a]", "")
            if HAZARD_STATE_ATTRIBUTES[normalized] and value == false then
                return true
            end
        end
        -- Many Roblox experiences replicate state as ValueObjects instead of attributes.
        -- Only an explicit false/off state suppresses a hazard; missing switches stay unknown.
        for _, child in ipairs(current:GetChildren()) do
            local normalized = string.lower(child.Name):gsub("[^%a]", "")
            if HAZARD_STATE_ATTRIBUTES[normalized] then
                if child:IsA("BoolValue") and child.Value == false then
                    return true
                elseif child:IsA("StringValue") then
                    local state = string.lower(child.Value)
                    if state == "off" or state == "inactive" or state == "disabled" or state == "unpowered" then
                        return true
                    end
                elseif child:IsA("NumberValue") and child.Value == 0 then
                    return true
                end
            end
        end
        if current == hazardRoot then break end
        current = current.Parent
        depth = depth + 1
    end
    return false
end

local function nearestPointOnPart(part, worldPosition)
    local localPoint = part.CFrame:PointToObjectSpace(worldPosition)
    local half = part.Size * 0.5
    local clamped = Vector3.new(
        math.clamp(localPoint.X, -half.X, half.X),
        math.clamp(localPoint.Y, -half.Y, half.Y),
        math.clamp(localPoint.Z, -half.Z, half.Z)
    )
    return part.CFrame:PointToWorldSpace(clamped)
end

local PROJECTILE_NAME_HINTS = {
    "projectile", "spear", "knife", "dagger", "arrow", "bolt", "missile",
    "rocket", "fireball", "shard", "thrown", "bullet", "orb",
}

local function isLikelyProjectilePart(part)
    local current = part
    local depth = 0
    while current and current ~= Workspace and depth < 5 do
        local nameLower = string.lower(current.Name)
        for _, hint in ipairs(PROJECTILE_NAME_HINTS) do
            if string.find(nameLower, hint, 1, true) then return true end
        end
        current = current.Parent
        depth = depth + 1
    end
    return false
end

-- Drop dead/anchored parts and keep the table under MaxTrackedParts (oldest first).
-- Runs only when the cap is exceeded instead of on every new part.
local function pruneTrackedParts()
    local count, oldest, oldestTime = 0, nil, math.huge
    for tracked, info in pairs(trackedParts) do
        if not tracked.Parent or (tracked.Anchored and not isLikelyProjectilePart(tracked)) then
            trackedParts[tracked] = nil
        else
            count = count + 1
            local born = type(info) == "table" and info.born or 0
            if born < oldestTime then
                oldestTime = born
                oldest = tracked
            end
        end
    end
    if count > CFG.MaxTrackedParts and oldest then
        trackedParts[oldest] = nil
        count = count - 1
    end
    trackedCount = count
end

local function pruneTrackedHazards()
    local count = 0
    local oldestPart, oldestTime = nil, math.huge
    for hazardPart, info in pairs(trackedHazards) do
        if not hazardPart.Parent or not hazardPart:IsDescendantOf(Workspace)
            or not info or not info.root or not info.root.Parent then
            trackedHazards[hazardPart] = nil
        else
            count = count + 1
            local born = info.born or 0
            if born < oldestTime then
                oldestTime = born
                oldestPart = hazardPart
            end
        end
    end
    if count > CFG.MaxTrackedHazardParts and oldestPart then
        trackedHazards[oldestPart] = nil
        count = count - 1
    end
    trackedHazardCount = count
end

local function trackPart(part)
    if shuttingDown or not part or not part:IsA("BasePart") then return end
    if not part.Parent or not part:IsDescendantOf(Workspace) then return end
    if LocalPlayer.Character and part:IsDescendantOf(LocalPlayer.Character) then return end
    if isCharacterPart(part) then return end

    if CFG.EnvironmentHazards then
        local hazardRoot, hazardLabel = getHazardRootForPart(part)
        if hazardRoot then
            local prior = trackedHazards[part]
            if not prior then trackedHazardCount = trackedHazardCount + 1 end
            hazardThreatCacheAt = -math.huge
            trackedHazards[part] = {
                root = hazardRoot,
                label = hazardLabel,
                born = prior and prior.born or os.clock(),
            }
            if trackedHazardCount > CFG.MaxTrackedHazardParts then
                pruneTrackedHazards()
            end
        end
    end

    -- Unanchored parts are tracked normally. Anchored parts are tracked only when
    -- their names suggest a projectile, because Tween/CFrame-driven attacks may
    -- move even while Anchored is true.
    local namedProjectile = isLikelyProjectilePart(part)
    if (part.Anchored and not namedProjectile) or part.Size.Magnitude > 42 then return end
    if trackedParts[part] == nil then
        local now = os.clock()
        trackedParts[part] = {
            born = now,
            lastPos = part.Position,
            lastSample = now,
            velocity = part.AssemblyLinearVelocity,
        }
        trackedCount = trackedCount + 1
        if trackedCount > CFG.MaxTrackedParts then pruneTrackedParts() end
    end
end

local function getTrackedVelocity(part, now)
    local info = trackedParts[part]
    if type(info) ~= "table" then return part.AssemblyLinearVelocity end
    if part.Anchored then
        local lastSample = info.lastSample or now
        local dt = now - lastSample
        if dt >= 0.04 then
            local currentPosition = part.Position
            local previousPosition = info.lastPos or currentPosition
            info.velocity = (currentPosition - previousPosition) / math.max(dt, 0.001)
            info.lastPos = currentPosition
            info.lastSample = now
        end
        return info.velocity or Vector3.zero
    end
    info.lastPos = part.Position
    info.lastSample = now
    info.velocity = part.AssemblyLinearVelocity
    return info.velocity
end

local function predictProjectileThreat(myRoot)
    local now = os.clock()
    local best = nil

    for part, info in pairs(trackedParts) do
        local born = type(info) == "table" and info.born or now
        if not part.Parent
            or (part.Anchored and not isLikelyProjectilePart(part))
            or (not part.Anchored and now - born > CFG.ProjectileLifetime) then
            untrackPart(part)
        else
            local velocity = getTrackedVelocity(part, now)
            local relative = part.Position - myRoot.Position
            local distance = relative.Magnitude

            local requiredSpeed = isLikelyProjectilePart(part)
                and CFG.NamedProjectileMinSpeed or CFG.ProjectileMinSpeed
            if velocity.Magnitude >= requiredSpeed
                and distance <= CFG.ProjectileMaxDistance then
                local relativeVelocity = velocity - myRoot.AssemblyLinearVelocity
                local speedSquared = relativeVelocity:Dot(relativeVelocity)

                -- Skip parts that are not moving toward the player before raycasting.
                if speedSquared > 1 and relative:Dot(relativeVelocity) < 0 then
                    local t = math.clamp(-relative:Dot(relativeVelocity) / speedSquared, 0, CFG.ProjectileHorizon)
                    local miss = (relative + relativeVelocity * t).Magnitude
                    local effectiveRadius = CFG.ProjectileThreatRadius
                        + math.clamp(part.Size.Magnitude * 0.12, 0, 1.25)
                    if miss <= effectiveRadius and hasProjectileLineOfSight(myRoot, part) then
                        local threat = {
                            score = t + miss * 0.025,
                            time = t,
                            missDistance = miss,
                            position = part.Position,
                            velocity = velocity,
                            kind = "projectile prediction",
                            projectile = part,
                        }
                        if not best or threat.score < best.score then best = threat end
                    end
                end
            end
        end
    end
    return best
end

local function collectEnvironmentHazardThreats(myRoot, maxDistance)
    if not CFG.EnvironmentHazards or not myRoot or not myRoot.Parent then return {} end
    local now = os.clock()
    if hazardThreatCacheRoot == myRoot and hazardThreatCacheRadius == maxDistance
        and now - hazardThreatCacheAt < HAZARD_CACHE_SECONDS then
        return hazardThreatCache
    end

    local byHazardRoot = {}
    for part, info in pairs(trackedHazards) do
        local hazardRoot = info and info.root
        if not part.Parent or not part:IsDescendantOf(Workspace)
            or not hazardRoot or not hazardRoot.Parent
            or not part:IsDescendantOf(hazardRoot) and part ~= hazardRoot then
            trackedHazards[part] = nil
            trackedHazardCount = math.max(0, trackedHazardCount - 1)
        elseif not hazardExplicitlyInactive(part, hazardRoot) then
            local point = nearestPointOnPart(part, myRoot.Position)
            local delta = point - myRoot.Position
            local horizontalDistance = flat(delta).Magnitude
            if math.abs(delta.Y) <= CFG.HazardVerticalTolerance and horizontalDistance <= maxDistance then
                local previous = byHazardRoot[hazardRoot]
                if not previous or horizontalDistance < previous.distance then
                    local radius = math.clamp(2.5 + part.Size.Magnitude * 0.12, 3.0, 5.5)
                    byHazardRoot[hazardRoot] = {
                        score = horizontalDistance,
                        time = 1,
                        missDistance = horizontalDistance,
                        position = point,
                        velocity = Vector3.zero,
                        kind = "ENV HAZARD: " .. tostring(info.label or hazardRoot.Name),
                        hazardPart = part,
                        hazardRoot = hazardRoot,
                        hazardLabel = info.label or hazardRoot.Name,
                        avoidRadius = radius,
                        distance = horizontalDistance,
                    }
                end
            end
        end
    end

    local result = {}
    for _, threat in pairs(byHazardRoot) do
        table.insert(result, threat)
    end
    table.sort(result, function(a, b) return a.distance < b.distance end)
    while #result > 8 do table.remove(result) end
    hazardThreatCache = result
    hazardThreatCacheRoot = myRoot
    hazardThreatCacheRadius = maxDistance
    hazardThreatCacheAt = now
    return hazardThreatCache
end

local function findEnvironmentHazardThreat(myRoot, humanoid)
    if not CFG.EnvironmentHazards or not myRoot or not humanoid then return nil end
    local now = os.clock()
    local hazards = collectEnvironmentHazardThreats(myRoot, CFG.HazardScanRadius)
    local moveDirection = unitOrZero(flat(humanoid.MoveDirection))
    local velocity = flat(myRoot.AssemblyLinearVelocity)
    if moveDirection.Magnitude < 0.12 and velocity.Magnitude >= 1.4 then
        moveDirection = velocity.Unit
    end

    local best, bestUrgency = nil, math.huge
    for _, cachedThreat in ipairs(hazards) do
        local threat = table.clone(cachedThreat)
        local hazardRoot = threat.hazardRoot
        local lastAt = hazardRoot and (lastHazardDodgeAt[hazardRoot] or -math.huge) or -math.huge
        local delta = flat(threat.position - myRoot.Position)
        local distance = delta.Magnitude
        local triggerRadius = math.max(CFG.HazardTriggerDistance, (threat.avoidRadius or 3.0) + 0.8)
        local shouldDodge, eta = distance <= triggerRadius, 0.04

        if not shouldDodge and moveDirection.Magnitude > 0.12 then
            local along = delta:Dot(moveDirection)
            local lateral = (delta - moveDirection * along).Magnitude
            if along > 0 and along <= CFG.HazardLookAheadDistance
                and lateral <= (threat.avoidRadius or 3) + 1.5 then
                local speed = math.max(velocity.Magnitude, humanoid.WalkSpeed * 0.65, 5)
                eta = along / speed
                if eta <= CFG.HazardLookAheadTime then shouldDodge = true end
            end
        end

        if shouldDodge and now - lastAt >= CFG.HazardRearmSeconds then
            threat.time = eta
            threat.score = eta + distance * 0.015
            if threat.score < bestUrgency then
                best, bestUrgency = threat, threat.score
            end
        end
    end
    return best
end

local function predictNpcModelThreat(myRoot, model)
    if not CFG.NPCPrediction or not model or not model.Parent
        or Players:GetPlayerFromCharacter(model) then return nil end
    local humanoid, root = getCharacterParts(model)
    if not humanoid or not root then
        unregisterNpcModel(model)
        return nil
    end

    local displacement = flat(root.Position - myRoot.Position)
    local distance = displacement.Magnitude
    if distance < 0.1 or distance > CFG.NPCScanRange then return nil end
    local vertical = math.abs(root.Position.Y - myRoot.Position.Y)
    if vertical > CFG.MaxThreatVerticalSeparation then return nil end
    local explicit, friendly = classifyNpc(model, humanoid)
    if friendly and not explicit then return nil end

    local closing = closingSpeed(myRoot, root)
    local facing = facingUs(myRoot, root)
    local moveDirection = unitOrZero(flat(humanoid.MoveDirection))
    local directionToUs = unitOrZero(flat(myRoot.Position - root.Position))
    local npcSpeed = flat(root.AssemblyLinearVelocity).Magnitude
    local appearsToChase = moveDirection.Magnitude > 0.05
        and moveDirection:Dot(directionToUs) >= 0.52
        and (npcSpeed >= 0.35 or humanoid.MoveDirection.Magnitude >= 0.55)

    local inferred = not explicit and distance <= CFG.NPCInferRange
        and ((appearsToChase and (closing >= 0.1 or facing))
            or (facing and closing >= 1.0 and distance <= 14))
    if not explicit and not inferred then return nil end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, root, model) then return nil end

    local relativeVelocity = flat(root.AssemblyLinearVelocity - myRoot.AssemblyLinearVelocity)
    local speedSquared = relativeVelocity:Dot(relativeVelocity)
    local t = 0
    if speedSquared > 0.5 then
        t = math.clamp(-displacement:Dot(relativeVelocity) / speedSquared, 0, CFG.PlayerHorizon)
    end
    local miss = (displacement + relativeVelocity * t).Magnitude
    local radius = explicit and CFG.NPCThreatRadius or CFG.PlayerThreatRadius
    local predictedContact = closing >= CFG.MinimumClosingSpeedForPrediction
        and miss <= radius and t <= CFG.PlayerHorizon
    local critical = distance <= CFG.EmergencyTakeoverRange
        and vertical <= CFG.CriticalVerticalSeparation

    local pressing = appearsToChase
        or closing >= CFG.KiteClosingThreshold
        or (facing and closing >= -0.4 and distance <= 12.0)
        or (distance <= CFG.KiteHardRange and facing)
    local proactive = distance <= CFG.KiteStartRange and pressing
    if not critical and not predictedContact and not proactive then return nil end

    local eta = critical and 0 or (predictedContact and t or 0.34)
    local kind = critical and "CRITICAL PROXIMITY"
        or (explicit and "hostile NPC approach" or "inferred NPC chase")
    return {
        score = eta + miss * 0.04,
        time = eta,
        position = root.Position,
        velocity = root.AssemblyLinearVelocity,
        kind = kind,
        npcModel = model,
        sourceRoot = root,
        missDistance = miss,
        kiting = not critical and not predictedContact and proactive,
        inferred = inferred,
    }
end

local function collectNpcThreats(myRoot)
    if not CFG.NPCPrediction or not myRoot then return {} end
    local now = os.clock()
    if npcThreatCacheRoot == myRoot and now - npcThreatCacheAt < CFG.NPCRecheckSeconds then
        return npcThreatCache
    end

    local result = {}
    for model in pairs(npcCandidates) do
        if not model.Parent or not model:IsDescendantOf(Workspace) then
            unregisterNpcModel(model)
        else
            local threat = predictNpcModelThreat(myRoot, model)
            if threat then table.insert(result, threat) end
        end
    end
    table.sort(result, function(a, b)
        local at = (a.time or 1) + (a.missDistance or 99) * 0.025
        local bt = (b.time or 1) + (b.missDistance or 99) * 0.025
        return at < bt
    end)
    while #result > 6 do table.remove(result) end
    npcThreatCache = result
    npcThreatCacheRoot = myRoot
    npcThreatCacheAt = now
    return result
end

local function collectNearbyThreats(primary, myRoot)
    local threats = {}
    local seen = {}

    local function add(threat)
        if not threat then return end
        local key = threat.killerCharacter or threat.npcModel or threat.projectile or threat.hazardRoot or threat
        if seen[key] then return end
        seen[key] = true
        table.insert(threats, threat)
    end

    add(primary)

    for _, npcThreat in ipairs(collectNpcThreats(myRoot)) do
        add(npcThreat)
    end

    for _, hazardThreat in ipairs(collectEnvironmentHazardThreats(myRoot, CFG.HazardScanRadius)) do
        add(hazardThreat)
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isKiller(player) then
            local _, root = getCharacterParts(player.Character)
            if root
                and math.abs(root.Position.Y - myRoot.Position.Y) <= CFG.MaxThreatVerticalSeparation
                and (root.Position - myRoot.Position).Magnitude <= CFG.PlayerScanRange
                and (not CFG.RequireLineOfSight or hasLineOfSight(myRoot, root, player.Character)) then
                add({
                    position = root.Position,
                    velocity = root.AssemblyLinearVelocity,
                    kind = "nearby killer",
                    killerCharacter = player.Character,
                    sourceRoot = root,
                    time = 0.25,
                })
            end
        end
    end

    -- Add only a handful of nearby moving objects to keep scoring lightweight.
    local projectileThreats = {}
    if CFG.ProjectilePrediction then
        for part in pairs(trackedParts) do
            if part.Parent and (not part.Anchored or isLikelyProjectilePart(part)) then
                local velocity = getTrackedVelocity(part, os.clock())
                local distance = (part.Position - myRoot.Position).Magnitude
                local requiredSpeed = isLikelyProjectilePart(part)
                    and CFG.NamedProjectileMinSpeed or CFG.ProjectileMinSpeed
                if velocity.Magnitude >= requiredSpeed and distance <= 34 then
                    local rel = part.Position - myRoot.Position
                    local relVel = velocity - myRoot.AssemblyLinearVelocity
                    local denom = relVel:Dot(relVel)
                    if denom > 1 and rel:Dot(relVel) < 0 then
                        local t = math.clamp(-rel:Dot(relVel) / denom, 0, CFG.ProjectileHorizon)
                        local miss = (rel + relVel * t).Magnitude
                        local effectiveRadius = CFG.ProjectileThreatRadius
                            + math.clamp(part.Size.Magnitude * 0.12, 0, 1.25)
                        if miss <= effectiveRadius and hasProjectileLineOfSight(myRoot, part) then
                            table.insert(projectileThreats, {
                                score = t + miss * 0.025,
                                time = t,
                                missDistance = miss,
                                position = part.Position,
                                velocity = velocity,
                                kind = "moving object",
                                projectile = part,
                            })
                        end
                    end
                end
            end
        end
    end
    table.sort(projectileThreats, function(a, b) return a.score < b.score end)
    for i = 1, math.min(CFG.CandidateThreatCount, #projectileThreats) do
        add(projectileThreats[i])
    end

    return threats
end

local function predictedThreatPosition(threat, t)
    if threat.projectile and threat.projectile.Parent then
        -- Some projectiles are Anchored and moved by Tween/CFrame; AssemblyLinearVelocity
        -- stays near zero for them, so use the tracked positional estimate instead.
        local velocity = getTrackedVelocity(threat.projectile, os.clock())
        return threat.projectile.Position + velocity * t
    end
    local targetModel = threat.killerCharacter or threat.npcModel
    if targetModel then
        local _, root = getCharacterParts(targetModel)
        if root then
            return root.Position + flat(root.AssemblyLinearVelocity) * t
        end
    end
    return (threat.position or Vector3.zero) + flat(threat.velocity or Vector3.zero) * t
end

local function scoreDirection(root, humanoid, direction, clearance, threats, primary)
    direction = unitOrZero(flat(direction))
    if direction.Magnitude < 0.01 then return -math.huge end

    local speed = math.max(humanoid.WalkSpeed, 9)
    local currentVelocity = flat(root.AssemblyLinearVelocity)
    local minSeparation = math.huge
    local endSeparation = math.huge
    local finalSampleTime = 0.56
    local sampleTimes = { 0.10, 0.19, 0.30, 0.43, finalSampleTime }

    for _, threat in ipairs(threats) do
        for _, t in ipairs(sampleTimes) do
            local myFuture = root.Position
                + currentVelocity * (t * 0.30)
                + direction * (speed * t * CFG.PlayerMotionFactor)
            local theirFuture = predictedThreatPosition(threat, t)
            local separation = flat(myFuture - theirFuture).Magnitude
            if threat.avoidRadius then
                separation = separation - threat.avoidRadius
            end
            if separation < minSeparation then minSeparation = separation end
            if t == finalSampleTime then
                endSeparation = math.min(endSeparation, separation)
            end
        end
    end

    if minSeparation == math.huge then minSeparation = 0 end
    if endSeparation == math.huge then endSeparation = 0 end

    local awayScore = 0
    local sideScore = 0
    if primary and primary.position then
        local threatPosition = predictedThreatPosition(primary, math.clamp(primary.time or 0, 0, 0.25))
        local away = unitOrZero(flat(root.Position - threatPosition))
        local enemyVelocity = flat(primary.velocity or Vector3.zero)
        local lateral = unitOrZero(Vector3.new(-enemyVelocity.Z, 0, enemyVelocity.X))
        awayScore = direction:Dot(away)
        if lateral.Magnitude > 0.01 then
            sideScore = math.abs(direction:Dot(lateral))
        end
    end

    -- A larger projected clearance from the threats outweighs pure distance
    -- from walls; side/away preferences are tie-breakers.
    local awayWeight = (primary and primary.kiting) and CFG.KiteAwayWeight or 1.25
    local sideWeight = (primary and primary.kiting) and CFG.KiteSideWeight or CFG.SideBias

    return minSeparation * 1.7
        + endSeparation * 0.40
        + math.min(clearance, CFG.ProbeDistance) * 0.65
        + awayScore * awayWeight
        + sideScore * sideWeight
end

local function chooseDodgeDirection(root, humanoid, primary)
    -- Reuse filters and one current-floor sample for the entire candidate batch.
    local queryContext = makeMovementQueryContext(root)
    local threats = collectNearbyThreats(primary, root)
    local bestDirection, bestScore = nil, -math.huge

    local away = Vector3.zero
    if primary and primary.position then
        away = unitOrZero(flat(root.Position - predictedThreatPosition(primary, math.clamp(primary.time or 0, 0, 0.22))) )
    end
    if away.Magnitude < 0.01 then away = -unitOrZero(flat(root.CFrame.LookVector)) end

    local velocity = primary and flat(primary.velocity or Vector3.zero) or Vector3.zero
    local lateral = unitOrZero(Vector3.new(-velocity.Z, 0, velocity.X))
    if lateral.Magnitude < 0.05 then
        lateral = Vector3.new(-away.Z, 0, away.X)
    end

    local candidates = {}
    local primaryDistance = primary and primary.position
        and flat(root.Position - predictedThreatPosition(primary, 0)).Magnitude or math.huge
    local near = (primary and primary.kiting) or primaryDistance <= 6.5
    local retreat = (primary and primary.kiting)
        and CFG.KiteAwayWeight
        or (near and CFG.NearThreatExtraAway or 0.24)

    table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.72))
    table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.72))
    table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.35))
    table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.35))
    table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.95))
    table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.95))

    for i = 0, CFG.CandidateCount - 1 do
        local angle = (math.pi * 2 * i / CFG.CandidateCount)
        table.insert(candidates, Vector3.new(math.cos(angle), 0, math.sin(angle)))
    end

    local bestClearance = 0
    for _, candidate in ipairs(candidates) do
        local moveDirection, clearance = directionClearance(root, candidate, queryContext)
        if moveDirection then
            local score = scoreDirection(root, humanoid, moveDirection, clearance, threats, primary)
            if near then
                score = score + moveDirection:Dot(away) * retreat
            end
            if moveDirection:Dot(lateral) * preferredSide > 0.2 then
                score = score + 0.06
            end
            if score > bestScore then
                bestScore = score
                bestDirection = moveDirection
                bestClearance = clearance
            end
        end
    end

    if bestDirection and lateral.Magnitude > 0.05 then
        local sideAlignment = bestDirection:Dot(lateral)
        if math.abs(sideAlignment) >= 0.35 then
            preferredSide = sideAlignment >= 0 and 1 or -1
        end
    end
    return bestDirection, bestScore, bestClearance
end

-- Diverse footwork patterns inspired by common game-steering methods:
-- circle strafing (https://en.wikipedia.org/wiki/Strafing_(video_games))
-- and evade/separation/orbit steering (https://github.com/cpowell/steering-behaviors).
-- The VD predictive-dodge reference also motivates predicted trajectories and ground checks:
-- https://github.com/gg8752383-cpu/AutoDodge1/blob/d53d95e15b2cf3e237775065aaf8d9b11c7e7b6b/Predictive_AutoDodge.lua
-- Each pattern retains an outward component so it does not intentionally run into the killer.
local STYLE_NAMES = {
    "ARC LEFT", "ARC RIGHT", "ZIGZAG", "S-WEAVE", "J-HOOK",
    "ORBIT", "REVERSE ORBIT", "SPIRAL", "FEINT STEP", "DIAGONAL BURST",
    "MICRO-SNAKE", "RETREAT ARC", "COUNTER-CUT", "WIDE ORBIT", "CROSS-STEP",
}

local function getStyleVector(styleIndex, elapsed, away, tangent, radial, side)
    local wave = math.sin(elapsed * 13.5)
    local vector

    if styleIndex == 1 then -- Arc to the left with outward drift
        vector = away * math.max(radial, 0.58) + tangent * side * 0.95
    elseif styleIndex == 2 then -- Reverse arc
        vector = away * math.max(radial, 0.58) - tangent * side * 0.95
    elseif styleIndex == 3 then -- Zig-zag: left/right cuts, never a straight approach
        vector = away * math.max(radial, 0.66) + tangent * (wave >= 0 and 0.88 or -0.88)
    elseif styleIndex == 4 then -- Smooth S-shaped weave
        vector = away * math.max(radial, 0.72) + tangent * math.sin(elapsed * 8.8) * 1.02
    elseif styleIndex == 5 then -- J-hook: short side-step, then hard outward cut
        local phase = elapsed % 0.62
        local flip = phase < 0.20 and side or -side
        local lateral = phase < 0.20 and 1.05 or 0.62
        vector = away * (phase < 0.20 and 0.70 or math.max(radial, 0.90)) + tangent * flip * lateral
    elseif styleIndex == 6 then -- Clockwise orbit with an outward bias
        vector = away * math.max(radial, 0.52) + tangent * side * 1.12
    elseif styleIndex == 7 then -- Counter-clockwise orbit
        vector = away * math.max(radial, 0.52) - tangent * side * 1.12
    elseif styleIndex == 8 then -- Spiral-like outward sweep
        local angle = elapsed * 6.4
        vector = away * math.max(radial, 0.72) + tangent * math.sin(angle) * 1.08
    elseif styleIndex == 9 then -- Feint-step: rapid side reversal while drifting out
        local phase = elapsed % 0.46
        local flip = phase < 0.13 and side or -side
        vector = away * math.max(radial, 0.62) + tangent * flip * (phase < 0.13 and 1.05 or 0.82)
    elseif styleIndex == 10 then -- Diagonal burst, then a controlled retreat
        local phase = elapsed % 0.68
        if phase < 0.19 then
            vector = away * 1.12 + tangent * side * 1.02
        else
            vector = away * math.max(radial, 0.72) + tangent * side * 0.42
        end
    elseif styleIndex == 11 then -- Small quick snake steps
        vector = away * math.max(radial, 0.72) + tangent * math.sin(elapsed * 21.0) * 0.72
    elseif styleIndex == 12 then -- Strong retreat arc when pressure is high
        vector = away * math.max(radial, 1.0) + tangent * side * 0.52
    elseif styleIndex == 13 then -- Counter-cut: swap the angle midway through the beat
        local phase = elapsed % 0.58
        local flip = phase < 0.29 and side or -side
        vector = away * math.max(radial, 0.80) + tangent * flip * 0.96
    elseif styleIndex == 14 then -- Wider orbit; only use when there is room
        vector = away * math.max(radial, 0.44) + tangent * side * 1.30
    else -- Cross-step: angled retreat with continuous side sway
        vector = away * math.max(radial, 0.78) + tangent * (side * 0.52 + math.sin(elapsed * 10.5) * 0.38)
    end

    return unitOrZero(flat(vector))
end

local function styledDirectionFor(dodge, now)
    if not CFG.MovementStylesEnabled or not dodge or not dodge.root then
        return dodge and dodge.direction or nil
    end

    local threat = dodge.threat
    if not threat then return dodge.direction end

    local root = dodge.root
    if not root.Parent then return dodge.direction end

    local targetPosition = predictedThreatPosition(threat, math.clamp(threat.time or 0.08, 0, 0.14))
    local targetVelocity = flat(threat.velocity or Vector3.zero)

    local targetModel = threat.killerCharacter or threat.npcModel
    if targetModel then
        local _, currentTargetRoot = getCharacterParts(targetModel)
        if currentTargetRoot then
            targetPosition = currentTargetRoot.Position + flat(currentTargetRoot.AssemblyLinearVelocity) * 0.08
            targetVelocity = flat(currentTargetRoot.AssemblyLinearVelocity)
        end
    elseif threat.projectile and threat.projectile.Parent then
        -- Keep styling aligned with the same estimated velocity used by threat scoring.
        targetVelocity = flat(getTrackedVelocity(threat.projectile, now))
        targetPosition = threat.projectile.Position + targetVelocity * 0.06
    end

    local offset = flat(root.Position - targetPosition)
    local distance = offset.Magnitude
    local away = unitOrZero(offset)
    if away.Magnitude < 0.01 then
        away = unitOrZero(flat(dodge.direction or root.CFrame.RightVector))
    end
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end

    local tangent = Vector3.new(-away.Z, 0, away.X)
    -- Prefer the side that crosses the killer's path rather than the side the killer is already moving into.
    local lateralVelocity = Vector3.new(-targetVelocity.Z, 0, targetVelocity.X)
    if lateralVelocity.Magnitude > 0.25 and lateralVelocity.Unit:Dot(tangent) < -0.1 then
        tangent = -tangent
    end

    -- Keep distance first; style supplies the lateral shape around that safety vector.
    local radial
    if distance <= 6 then
        radial = 1.18
    elseif distance <= 12 then
        radial = 0.95
    elseif distance <= 20 then
        radial = 0.74
    elseif distance <= CFG.KiteStartRange then
        radial = 0.55
    elseif distance <= CFG.KiteReleaseRange then
        radial = CFG.StyleRadialKeepout
    else
        radial = 0.22
    end

    local startedAt = dodge.patternStartAt or dodge.startedAt or now
    local elapsed = math.max(0, now - startedAt)
    local slot = math.floor(elapsed / CFG.StyleCycleDuration)
    local within = elapsed - slot * CFG.StyleCycleDuration
    local baseIndex = ((dodge.styleOffset or 1) + slot - 1) % #STYLE_NAMES + 1
    local nextIndex = baseIndex % #STYLE_NAMES + 1
    local side = (slot % 2 == 0) and (dodge.patternSide or 1) or -(dodge.patternSide or 1)

    local wanted = getStyleVector(baseIndex, elapsed, away, tangent, radial, side)
    local blendStart = CFG.StyleCycleDuration - CFG.StyleBlendDuration
    if within >= blendStart then
        local alpha = math.clamp((within - blendStart) / CFG.StyleBlendDuration, 0, 1)
        alpha = alpha * alpha * (3 - 2 * alpha) -- smoothstep to avoid harsh turns
        local nextWanted = getStyleVector(nextIndex, elapsed, away, tangent, radial, -side)
        local mixed = wanted:Lerp(nextWanted, alpha)
        if mixed.Magnitude > 0.02 then wanted = mixed.Unit end
    end

    -- Validate every selected move against walls and missing ground; if blocked,
    -- pick the safest nearby alternative rather than blindly following the pattern.
    if now - (dodge.lastStyleSafetyAt or 0) >= CFG.StyleSafetyInterval then
        dodge.lastStyleSafetyAt = now
        local queryContext = makeMovementQueryContext(root)

        local candidates = {
            wanted,
            away,
            unitOrZero(away + tangent * side * 0.8),
            unitOrZero(away - tangent * side * 0.8),
            tangent * side,
            -tangent * side,
            dodge.direction,
        }
        local best, bestScore = nil, -math.huge
        local currentThreats = collectNearbyThreats(threat, root)
        for _, candidate in ipairs(candidates) do
            local clearDirection, clearance = directionClearance(root, candidate, queryContext)
            if clearDirection then
                local threatSafety = scoreDirection(root, dodge.humanoid, clearDirection, clearance, currentThreats, threat)
                local score = clearDirection:Dot(wanted) * 2.8
                    + clearDirection:Dot(away) * 0.35
                    + math.min(clearance or 0, CFG.ProbeDistance) * 0.035
                    + threatSafety * 0.075
                if score > bestScore then
                    bestScore, best = score, clearDirection
                end
            end
        end
        if best then
            local previous = dodge.smoothedStyleDirection or dodge.direction or best
            local dt = math.max(0.001, now - (dodge.lastStyleUpdateAt or now))
            local alpha = 1 - math.exp(-dt / CFG.SteeringSmoothingSeconds)
            local smooth = previous:Lerp(best, math.clamp(alpha, 0.12, 0.85))
            if smooth.Magnitude > 0.02 then
                dodge.smoothedStyleDirection = smooth.Unit
            else
                dodge.smoothedStyleDirection = best
            end
            dodge.lastStyleUpdateAt = now
        else
            -- If every tested direction is blocked or lacks ground, stop briefly
            -- instead of blindly continuing toward a ledge.
            dodge.smoothedStyleDirection = Vector3.zero
            dodge.lastStyleUpdateAt = now
            setStatus("NO SAFE STEP", "Blocked / edge detected")
        end
    end

    local styleName = STYLE_NAMES[baseIndex]
    if dodge.lastDisplayedStyle ~= styleName then
        dodge.lastDisplayedStyle = styleName
        if dodge.kiting then
            setStatus("KITE: " .. styleName, string.format("Pattern %d/%d • %.1f studs", baseIndex, #STYLE_NAMES, distance))
        end
    end

    return dodge.smoothedStyleDirection or wanted, styleName
end

local function orbitAngle(root, targetRoot)
    if not root or not targetRoot or not root.Parent or not targetRoot.Parent then return nil end
    local offset = flat(root.Position - targetRoot.Position)
    if offset.Magnitude < 0.05 then return nil end
    return math.atan2(offset.Z, offset.X)
end

local function signedAngleDelta(fromAngle, toAngle)
    return (toAngle - fromAngle + math.pi) % (math.pi * 2) - math.pi
end

local function threatIdentity(threat)
    if not threat then return nil end
    return threat.killerCharacter or threat.npcModel or threat.projectile
        or threat.hazardRoot or threat.hazardPart or threat
end

local function requestDodge(threat, forceUrgent)
    if shuttingDown or not CFG.Enabled or isLocalKillerRole() then return false end

    local now = os.clock()
    if manualMovementActive(now) then
        activeDodge = nil
        nextKitePulseAt = math.max(nextKitePulseAt, now + CFG.ManualInputGrace)
        return false
    end
    local urgent = forceUrgent or (threat and (threat.time or 1) < 0.16)

    if activeDodge and now < activeDodge.finishAt then
        -- If a normal short dodge is already underway when the killer gets
        -- critically close, promote it into the controlled orbit immediately.
        local incomingTarget = threat and (threat.killerCharacter or threat.npcModel)
        if incomingTarget and activeDodge.root and activeDodge.root.Parent then
            local _, closeRoot = getCharacterParts(incomingTarget)
            if closeRoot then
                local closeOffset = activeDodge.root.Position - closeRoot.Position
                local closeDistance = closeOffset.Magnitude
                if closeDistance <= CFG.EmergencyTakeoverRange
                    and math.abs(closeOffset.Y) <= CFG.CriticalVerticalSeparation then
                    local activeTarget = activeDodge.threat
                        and (activeDodge.threat.killerCharacter or activeDodge.threat.npcModel)
                    local targetChanged = activeTarget ~= incomingTarget
                    if not activeDodge.orbiting or targetChanged then
                        activeDodge.orbiting = true
                        activeDodge.orbitSide = preferredSide
                        activeDodge.orbitStartedAt = now
                        activeDodge.kiting = false
                        activeDodge.orbitProgress = 0
                        activeDodge.lastOrbitAngle = orbitAngle(activeDodge.root, closeRoot)
                        activeDodge.finishAt = math.max(activeDodge.finishAt, now + CFG.CloseOrbitTimeout)
                        activeDodge.lastMotionPosition = activeDodge.root.Position
                        activeDodge.lastMotionCheckAt = now
                        activeDodge.nextOrbitPlanAt = 0
                        activeDodge.orbitDirection = nil
                    end
                    activeDodge.threat = threat
                    return true
                end
            end
        end

        -- A confirmed/imminent threat can override the continuous kite pulse.
        if activeDodge.kiting and threat and not threat.kiting and urgent then
            local wasOrbiting = activeDodge.orbiting == true
            activeDodge.kiting = false
            activeDodge.orbiting = false
            activeDodge.orbitStartedAt = nil
            activeDodge.nextOrbitPlanAt = 0
            activeDodge.threat = threat
            local replacementDuration = math.clamp(
                0.18 + math.clamp(threat.time or 0.2, 0, 0.40) * 0.24,
                0.20,
                CFG.DodgeDuration
            )
            activeDodge.finishAt = wasOrbiting and (now + replacementDuration)
                or math.max(activeDodge.finishAt, now + replacementDuration)
            activeDodge.retargeted = false
            activeDodge.retargetNow = true
            activeDodge.patternStartAt = now
            activeDodge.styleOffset = math.random(1, #STYLE_NAMES)
            activeDodge.patternSide = preferredSide
            activeDodge.smoothedStyleDirection = activeDodge.direction
            activeDodge.lastStyleSafetyAt = 0
            return true
        end
        -- Continuous kite pulses are refreshed while the killer remains nearby.
        if activeDodge.kiting and threat and threat.kiting then
            activeDodge.threat = threat
            activeDodge.finishAt = now + CFG.KitePulseDuration
            return true
        end
        -- A newly urgent, different source must be allowed to preempt stale steering.
        -- Hysteresis prevents route jitter when the same target's ETA changes by a frame.
        local activeEta = activeDodge.threat and activeDodge.threat.time or 1
        local newEta = threat and threat.time or 1
        local identityChanged = threatIdentity(activeDodge.threat) ~= threatIdentity(threat)
        if urgent and identityChanged then
            local wasOrbiting = activeDodge.orbiting == true
            activeDodge.threat = threat
            activeDodge.kiting = threat and threat.kiting == true
            activeDodge.orbiting = false
            activeDodge.orbitStartedAt = nil
            activeDodge.nextOrbitPlanAt = 0
            activeDodge.retargetNow = true
            activeDodge.retargeted = false
            local replacementDuration = math.clamp(
                0.18 + math.clamp(newEta, 0, 0.40) * 0.24,
                0.20,
                CFG.DodgeDuration
            )
            activeDodge.finishAt = wasOrbiting and (now + replacementDuration)
                or math.max(activeDodge.finishAt, now + replacementDuration)
            activeDodge.patternStartAt = now
            activeDodge.smoothedStyleDirection = activeDodge.direction
            activeDodge.lastStyleSafetyAt = 0
            return true
        elseif urgent and newEta + 0.08 < activeEta then
            activeDodge.threat = threat
            activeDodge.retargetNow = true
        end
        return false
    end

    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root or localCharacterBlocked(character, humanoid) then
        return false
    end

    local sourceCharacter = threat and (threat.killerCharacter or threat.npcModel)
    local veryClose = threat and threat.kind == "CRITICAL PROXIMITY" or false
    if sourceCharacter then
        local _, sourceRoot = getCharacterParts(sourceCharacter)
        if not sourceRoot then return false end

        local offset = root.Position - sourceRoot.Position
        local distance = offset.Magnitude
        local sameLevel = math.abs(offset.Y) <= CFG.CriticalVerticalSeparation
        veryClose = veryClose or (distance <= CFG.EmergencyTakeoverRange and sameLevel)
        if math.abs(offset.Y) > CFG.MaxThreatVerticalSeparation then return false end
        if CFG.RequireLineOfSight and not hasLineOfSight(root, sourceRoot, sourceCharacter) then
            return false
        end
        local maxThreatRange = (threat and threat.kiting)
            and (CFG.KiteReleaseRange + 1)
            or (CFG.AnimationRange + 3)
        if distance > maxThreatRange then return false end

        if not (threat and threat.kiting) then
            local previous = lastByKiller[sourceCharacter] or -math.huge
            if now - previous < CFG.KillerCooldown and not urgent then return false end
            lastByKiller[sourceCharacter] = now
        end
    end

    -- Non-urgent cues are rate-limited. Confirmed near-hit cues can bypass that
    -- limiter so a recent kite pulse cannot make an actual attack un-dodgeable.
    if not veryClose and not urgent and now - lastDodge < CFG.MinimumDodgeInterval then return false end

    local direction, score, clearance = chooseDodgeDirection(root, humanoid, threat)
    if not direction then
        setStatus("NO CLEAR PATH", "No safe route; normal control kept")
        return false
    end

    lastDodge = now
    local isKiting = threat and threat.kiting == true
    local estimatedEta = math.clamp(threat and threat.time or 0.25, 0, 0.40)
    local duration = veryClose
        and CFG.CloseOrbitTimeout
        or (isKiting and CFG.KitePulseDuration
        or math.clamp(0.18 + estimatedEta * 0.24, 0.20, CFG.DodgeDuration))

    activeDodge = {
        direction = direction,
        startedAt = now,
        finishAt = now + duration,
        retargetAt = now + (isKiting and CFG.KiteReplanInterval or duration * CFG.RetargetFraction),
        retargeted = false,
        retargetNow = false,
        kiting = isKiting,
        orbiting = veryClose and sourceCharacter ~= nil,
        orbitSide = preferredSide,
        orbitDirection = direction,
        orbitStartedAt = veryClose and now or nil,
        orbitProgress = 0,
        lastOrbitAngle = nil,
        nextOrbitPlanAt = 0,
        lastMotionPosition = root.Position,
        lastMotionCheckAt = now,
        character = character,
        humanoid = humanoid,
        root = root,
        threat = threat,
        score = score,
        clearance = clearance,
        patternStartAt = (isKiting and kitePatternTarget == sourceCharacter and kitePatternStartAt > 0)
            and kitePatternStartAt or now,
        styleOffset = (isKiting and kitePatternTarget == sourceCharacter)
            and kiteStyleOffset or math.random(1, #STYLE_NAMES),
        patternSide = (isKiting and kitePatternTarget == sourceCharacter)
            and kitePatternSide or preferredSide,
        lastStyleSafetyAt = 0,
        lastStyleUpdateAt = now,
        smoothedStyleDirection = direction,
    }

    if activeDodge.orbiting and sourceCharacter then
        local _, orbitTargetRoot = getCharacterParts(sourceCharacter)
        activeDodge.lastOrbitAngle = orbitAngle(root, orbitTargetRoot)
    end

    local directionName = "STRAFE"
    if direction:Dot(flat(root.CFrame.RightVector)) > 0.45 then
        directionName = "RIGHT CUT"
    elseif direction:Dot(flat(root.CFrame.RightVector)) < -0.45 then
        directionName = "LEFT CUT"
    end
    setStatus(veryClose and "CLOSE ORBIT" or (isKiting and ("KITE: " .. directionName) or ("DODGE: " .. directionName)),
        veryClose and "Wall-aware circular evade" or string.format("%s • %.1f studs clear", (threat and threat.kind) or "threat", clearance))
    return true
end

-- Create space in short pulses when a player threat or identified NPC enters the
-- pressure radius. Start on approach/facing/close contact, then release control.
local function resetKiteFocus()
    kiteFocusCharacter = nil
    kitePatternTarget = nil
    kitePatternStartAt = 0
end

local function setKiteFocus(character)
    if kiteFocusCharacter ~= character then
        kitePatternTarget = character
        kitePatternStartAt = os.clock()
        kiteStyleOffset = math.random(1, #STYLE_NAMES)
        kitePatternSide = preferredSide
    end
    kiteFocusCharacter = character
end

local function makeKiteThreat(character, root)
    return {
        time = CFG.KitePulseDuration,
        position = root.Position,
        velocity = root.AssemblyLinearVelocity,
        kind = "SPACE CONTROL",
        killerCharacter = character,
        sourceRoot = root,
        kiting = true,
    }
end

-- Pick the source of pressure by predicted intent, not only by raw distance.
-- In free-for-all games with no role/team metadata, infer pressure conservatively:
-- require close range or a clearly closing player, plus a plausible facing/chase cue.
-- Never infer hostility from proximity alone when both teams are defined.
local function isUnmarkedPressurePlayer(player, myRoot, enemyRoot)
    if not player or player == LocalPlayer or isKiller(player) or not myRoot or not enemyRoot then
        return false
    end
    if player.Team and LocalPlayer.Team then
        -- Same-team players are friendly; different teams are already handled by isKiller.
        return false
    end
    if player.Team or LocalPlayer.Team then
        -- Ambiguous partial team metadata is not enough to infer hostility.
        return false
    end
    local offset = flat(enemyRoot.Position - myRoot.Position)
    local distance = offset.Magnitude
    if distance > CFG.KiteStartRange or math.abs(enemyRoot.Position.Y - myRoot.Position.Y) > CFG.MaxThreatVerticalSeparation then
        return false
    end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, enemyRoot, player.Character) then
        return false
    end
    local closing = closingSpeed(myRoot, enemyRoot)
    local facing = facingUs(myRoot, enemyRoot)
    return distance <= CFG.KiteHardRange or (closing >= 0.8 and (facing or closing >= 1.5))
end

-- Keep the current focus only while it remains a plausible threat; a killer
-- walking away and looking elsewhere should not steal movement from the joystick.
local function findKiteThreat(myRoot)
    if not CFG.KiteEnabled then
        resetKiteFocus()
        return nil
    end

    local bestCharacter, bestRoot, bestPressure = nil, nil, math.huge
    local bestInferred = false
    local focus = kiteFocusCharacter
    if focus then
        local focusPlayer = Players:GetPlayerFromCharacter(focus)
        local _, focusRoot = getCharacterParts(focus)
        if focusPlayer and focusRoot
            and (isKiller(focusPlayer) or isUnmarkedPressurePlayer(focusPlayer, myRoot, focusRoot)) then
            local offset = focusRoot.Position - myRoot.Position
            local distance = offset.Magnitude
            local sameHeightBand = math.abs(offset.Y) <= CFG.MaxThreatVerticalSeparation
            local visible = not CFG.RequireLineOfSight or hasLineOfSight(myRoot, focusRoot, focus)
            local closing = closingSpeed(myRoot, focusRoot)
            local facing = facingUs(myRoot, focusRoot)
            local stillPressuring = distance <= CFG.KiteHardRange
                or closing >= CFG.KiteClosingThreshold or facing
            if sameHeightBand and distance <= CFG.KiteReleaseRange and visible and stillPressuring then
                local pressure = distance - math.clamp(closing, -6, 10) * 0.28
                    - (facing and 1.1 or 0)
                    - (distance <= CFG.KiteHardRange and 2.0 or 0)
                bestCharacter, bestRoot, bestPressure = focus, focusRoot, pressure
                bestInferred = not isKiller(focusPlayer)
            else
                resetKiteFocus()
            end
        else
            resetKiteFocus()
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local character = player.Character
            local _, killerRoot = getCharacterParts(character)
            local knownHostile = isKiller(player)
            local inferredHostile = not knownHostile and killerRoot
                and isUnmarkedPressurePlayer(player, myRoot, killerRoot)
            if (knownHostile or inferredHostile) and killerRoot and character ~= kiteFocusCharacter then
                local offset = killerRoot.Position - myRoot.Position
                local distance = offset.Magnitude
                if math.abs(offset.Y) <= CFG.MaxThreatVerticalSeparation
                    and distance <= CFG.KiteStartRange
                    and (not CFG.RequireLineOfSight or hasLineOfSight(myRoot, killerRoot, character)) then
                    local closing = closingSpeed(myRoot, killerRoot)
                    local facing = facingUs(myRoot, killerRoot)
                    local pressured = distance <= CFG.KiteHardRange
                        or closing >= CFG.KiteClosingThreshold or facing
                    if pressured then
                        local pressure = distance - math.clamp(closing, -6, 10) * 0.28
                            - (facing and 1.1 or 0)
                            - (distance <= CFG.KiteHardRange and 2.0 or 0)
                        if pressure < bestPressure then
                            bestCharacter, bestRoot, bestPressure = character, killerRoot, pressure
                            bestInferred = inferredHostile == true
                        end
                    end
                end
            end
        end
    end

    if not bestCharacter then
        resetKiteFocus()
        return nil
    end

    setKiteFocus(bestCharacter)
    local threat = makeKiteThreat(bestCharacter, bestRoot)
    if threat and bestInferred then
        threat.inferred = true
        threat.kind = "inferred unmarked player pressure"
    end
    return threat
end

local function onKillerAnimation(player, character, track)
    if shuttingDown or not CFG.Enabled or not CFG.AnimationTrigger then return end
    if player.Character ~= character then return end
    local knownHostile = isKiller(player)
    local attackHint = attackLike(track)
    if not knownHostile and not attackHint then return end

    -- Same-team avatars are allies unless an explicit hostile role/attribute overrides the team.
    -- This prevents survivors' generic tool/attack animation names from stealing joystick control.
    if not knownHostile and player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team then
        return
    end

    local myCharacter = LocalPlayer.Character
    local _, myRoot = getCharacterParts(myCharacter)
    local _, killerRoot = getCharacterParts(character)
    if not myRoot or not killerRoot or localCharacterBlocked(myCharacter, myCharacter:FindFirstChildOfClass("Humanoid")) then
        return
    end

    local animationOffset = myRoot.Position - killerRoot.Position
    local distance = animationOffset.Magnitude
    if distance > CFG.AnimationRange then return end
    if math.abs(animationOffset.Y) > CFG.MaxThreatVerticalSeparation then return end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, killerRoot, character) then
        return
    end

    local closing = closingSpeed(myRoot, killerRoot)
    local facing = facingUs(myRoot, killerRoot)
    local attackHintInRange = attackHint and distance <= CFG.AttackAnimationRange
    if not knownHostile and not attackHintInRange then return end

    -- An attack animation is a direct cue only inside a plausible attack zone.
    -- This avoids the old failure where a valid wind-up was ignored simply because
    -- root velocity had not increased yet, while far-away idle/skill tracks stay filtered.
    local critical = distance <= CFG.CriticalAnimationRange
    local smartThreat = closing >= CFG.MinimumClosingSpeed
        or (facing and distance <= CFG.CloseFacingRange)
        or attackHintInRange

    if not critical and not smartThreat then
        return
    end

    local eta
    if critical then
        eta = math.clamp((distance - 2.0) / math.max(closing, 0.1), 0, 0.12)
    elseif attackHintInRange then
        local movementEta = (distance - 2.0) / math.max(closing, CFG.MinimumClosingSpeed)
        eta = math.clamp(math.min(movementEta, CFG.AttackAnimationLead + latencyLead()),
            0.06, 0.18 + latencyLead())
    else
        eta = math.clamp((distance - 2.0) / math.max(closing, 0.1), 0, 0.45)
    end
    -- Non-attack animation cues only trigger when contact is predicted soon.
    if not critical and not attackHintInRange and eta > 0.18 + latencyLead() then return end
    local threat = {
        time = eta,
        position = killerRoot.Position,
        velocity = killerRoot.AssemblyLinearVelocity,
        kind = attackHint and "attack animation" or "killer animation",
        killerCharacter = character,
        sourceRoot = killerRoot,
    }
    requestDodge(threat, critical or attackHintInRange or eta <= 0.18 + latencyLead())
end

local guardedAnimation = guarded("animation", onKillerAnimation)

watchNpcAnimations = function(model)
    if not model then return end
    if shuttingDown or not CFG.NPCPrediction or not model.Parent
        or Players:GetPlayerFromCharacter(model) then
        npcAnimationPending[model] = nil
        return
    end
    if npcAnimationConnections[model] then
        npcAnimationPending[model] = nil
        return
    end

    task.spawn(function()
        local humanoid = model:FindFirstChildOfClass("Humanoid")
        local animator = humanoid and (humanoid:FindFirstChildOfClass("Animator")
            or humanoid:WaitForChild("Animator", 2))
        if shuttingDown or not model.Parent or not animator or not npcCandidates[model] then
            npcAnimationPending[model] = nil
            return
        end

        npcAnimationPending[model] = nil
        npcAnimationConnections[model] = animator.AnimationPlayed:Connect(function(track)
            if shuttingDown or not CFG.Enabled or not CFG.AnimationTrigger or not attackLike(track) then return end
            local myCharacter = LocalPlayer.Character
            local myHumanoid, myRoot = getCharacterParts(myCharacter)
            local npcHumanoid, npcRoot = getCharacterParts(model)
            if not myRoot or not npcRoot or not npcHumanoid
                or localCharacterBlocked(myCharacter, myHumanoid) then return end

            local offset = myRoot.Position - npcRoot.Position
            local distance = offset.Magnitude
            if distance > CFG.AttackAnimationRange
                or math.abs(offset.Y) > CFG.MaxThreatVerticalSeparation then return end
            local explicitHostile, explicitlyFriendly = classifyNpc(model, npcHumanoid)
            if explicitlyFriendly and not explicitHostile then return end
            if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, npcRoot, model) then return end

            local closing = closingSpeed(myRoot, npcRoot)
            local critical = distance <= CFG.CriticalAnimationRange
            if not explicitHostile and not critical then
                -- Attack-like names alone are too noisy in unfamiliar games. For an
                -- unclassified NPC, require either a plausible facing wind-up or approach.
                local facing = facingUs(myRoot, npcRoot)
                if not (facing and closing >= -0.6) and closing < CFG.MinimumApproachSpeed then
                    return
                end
            end
            local eta = critical and 0 or math.clamp(
                (distance - 2.0) / math.max(closing, CFG.MinimumClosingSpeed),
                0.06, 0.18 + latencyLead()
            )
            local threat = {
                time = eta,
                position = npcRoot.Position,
                velocity = npcRoot.AssemblyLinearVelocity,
                kind = "NPC attack animation",
                npcModel = model,
                sourceRoot = npcRoot,
                inferred = not explicitHostile,
            }
            requestDodge(threat, critical or eta <= 0.18 + latencyLead())
        end)
    end)
end

local function watchCharacter(player, character)
    if not character or player == LocalPlayer then return end

    -- Watch every replicated player avatar; unknown-team games can still reveal
    -- an explicit attack through animation names. The callback filters other tracks.
    if watchedCharacters[character] then return end
    watchedCharacters[character] = true
    local token = (characterTokens[character] or 0) + 1
    characterTokens[character] = token

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 5)
        local animator = humanoid and (
            humanoid:FindFirstChildOfClass("Animator")
            or humanoid:WaitForChild("Animator", 5)
        )
        if not animator then
            if characterTokens[character] == token then watchedCharacters[character] = nil end
            return
        end
        if shuttingDown or characterTokens[character] ~= token
            or player.Character ~= character then
            return
        end

        disconnect(characterConnections[character])
        characterConnections[character] = animator.AnimationPlayed:Connect(function(track)
            guardedAnimation(player, character, track)
        end)
    end)
end

local function refreshPlayer(player)
    if player.Character then watchCharacter(player, player.Character) end
end

local function watchPlayer(player)
    if player == LocalPlayer or playerConnections[player] then return end

    local conns = {}
    playerConnections[player] = conns
    table.insert(conns, player.CharacterAdded:Connect(function(character)
        watchCharacter(player, character)
    end))
    table.insert(conns, player.CharacterRemoving:Connect(function(character)
        characterTokens[character] = (characterTokens[character] or 0) + 1
        watchedCharacters[character] = nil
        disconnect(characterConnections[character])
        characterConnections[character] = nil
        lastByKiller[character] = nil
        if activeDodge and activeDodge.threat and activeDodge.threat.killerCharacter == character then
            activeDodge = nil
        end
    end))
    table.insert(conns, player:GetPropertyChangedSignal("Team"):Connect(function()
        refreshPlayer(player)
    end))
    table.insert(conns, player:GetAttributeChangedSignal("Role"):Connect(function()
        refreshPlayer(player)
    end))
    table.insert(conns, player:GetAttributeChangedSignal("Killer"):Connect(function()
        refreshPlayer(player)
    end))
    refreshPlayer(player)
end

-- Panel look ---------------------------------------------------------------
local PANEL_WIDTH, PANEL_HEIGHT, PANEL_MARGIN = 154, 44, 8
local DEFAULT_PANEL_POSITION = UDim2.new(1, -14, 0.70, 0)
local FILL_ON = Color3.fromRGB(28, 131, 84)
local FILL_OFF = Color3.fromRGB(113, 53, 60)
local STROKE_OFF = Color3.fromRGB(70, 148, 208)
local INDICATOR_COLORS = {
    off = Color3.fromRGB(176, 178, 190),
    idle = Color3.fromRGB(86, 232, 142),
    dodge = Color3.fromRGB(255, 190, 64),
    kite = Color3.fromRGB(91, 202, 255),
    orbit = Color3.fromRGB(255, 96, 96),
}

local function tweenTo(instance, properties, duration)
    local ok = pcall(function()
        TweenService:Create(
            instance,
            TweenInfo.new(duration or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            properties
        ):Play()
    end)
    if not ok then
        for property, value in pairs(properties) do
            pcall(function() instance[property] = value end)
        end
    end
end

-- Cheap enough to call every frame: it only touches the UI when the state changes.
local function refreshIndicator(force)
    if not toggleButton or not toggleButton.Parent then return end

    local state = "off"
    if CFG.Enabled then
        local dodge = activeDodge
        if dodge then
            state = dodge.orbiting and "orbit" or (dodge.kiting and "kite" or "dodge")
        else
            state = "idle"
        end
    end
    if state == indicatorState and not force then return end
    indicatorState = state

    toggleButton.Text = CFG.Enabled and "MANS  ON" or "MANS  OFF"
    tweenTo(toggleButton, { BackgroundColor3 = CFG.Enabled and FILL_ON or FILL_OFF })
    local color = INDICATOR_COLORS[state]
    if indicatorDot and indicatorDot.Parent then
        tweenTo(indicatorDot, { BackgroundColor3 = color }, 0.08)
    end
    if indicatorStroke and indicatorStroke.Parent then
        tweenTo(indicatorStroke, { Color = (state == "off") and STROKE_OFF or color }, 0.08)
    end
end

local function makeUI()
    -- The game/executor may replace PlayerGui during a location transition.
    -- Disconnect old UIS handlers before rebuilding so taps never double-toggle.
    for _, connection in ipairs(uiConnections) do disconnect(connection) end
    table.clear(uiConnections)

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        or LocalPlayer:WaitForChild("PlayerGui", 8)
    if not playerGui then return end

    local old = playerGui:FindFirstChild("VD_AutoMansV7")
    if old then old:Destroy() end

    gui = Instance.new("ScreenGui")
    gui.Name = "VD_AutoMansV7"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 9999
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = playerGui

    -- Large first-run access panel. The password is a local UI gate, not security.
    local frame = nil
    if not authenticated then
        local backdrop = Instance.new("Frame")
        backdrop.Name = "AccessBackdrop"
        backdrop.Size = UDim2.fromScale(1, 1)
        backdrop.BackgroundColor3 = Color3.fromRGB(5, 8, 15)
        backdrop.BackgroundTransparency = 0.16
        backdrop.BorderSizePixel = 0
        backdrop.ZIndex = 500
        backdrop.Parent = gui

        local card = Instance.new("Frame")
        card.Name = "AccessCard"
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.fromScale(0.5, 0.5)
        card.Size = UDim2.new(0.88, 0, 0, 285)
        card.BackgroundColor3 = Color3.fromRGB(18, 23, 34)
        card.BorderSizePixel = 0
        card.ZIndex = 501
        card.Parent = backdrop
        local cardConstraint = Instance.new("UISizeConstraint")
        cardConstraint.MinSize = Vector2.new(280, 285)
        cardConstraint.MaxSize = Vector2.new(420, 285)
        cardConstraint.Parent = card
        local cardCorner = Instance.new("UICorner")
        cardCorner.CornerRadius = UDim.new(0, 18)
        cardCorner.Parent = card
        local cardStroke = Instance.new("UIStroke")
        cardStroke.Color = Color3.fromRGB(58, 130, 190)
        cardStroke.Thickness = 1.5
        cardStroke.Transparency = 0.12
        cardStroke.Parent = card

        local heading = Instance.new("TextLabel")
        heading.BackgroundTransparency = 1
        heading.Position = UDim2.new(0, 18, 0, 24)
        heading.Size = UDim2.new(1, -36, 0, 34)
        heading.Font = Enum.Font.GothamBold
        heading.Text = "VD  •  AUTO MANS"
        heading.TextColor3 = Color3.fromRGB(240, 245, 255)
        heading.TextSize = 22
        heading.ZIndex = 502
        heading.Parent = card

        local subtitle = Instance.new("TextLabel")
        subtitle.BackgroundTransparency = 1
        subtitle.Position = UDim2.new(0, 20, 0, 63)
        subtitle.Size = UDim2.new(1, -40, 0, 24)
        subtitle.Font = Enum.Font.Gotham
        subtitle.Text = "ENTER ACCESS CODE TO CONTINUE"
        subtitle.TextColor3 = Color3.fromRGB(150, 165, 190)
        subtitle.TextSize = 10
        subtitle.ZIndex = 502
        subtitle.Parent = card

        local passwordBox = Instance.new("TextBox")
        passwordBox.Name = "AccessCode"
        passwordBox.Position = UDim2.new(0, 22, 0, 105)
        passwordBox.Size = UDim2.new(1, -44, 0, 48)
        passwordBox.BackgroundColor3 = Color3.fromRGB(10, 14, 23)
        passwordBox.BorderSizePixel = 0
        passwordBox.ClearTextOnFocus = false
        passwordBox.PlaceholderText = "Access code"
        passwordBox.Text = ""
        passwordBox.TextColor3 = Color3.fromRGB(245, 248, 255)
        passwordBox.PlaceholderColor3 = Color3.fromRGB(105, 118, 140)
        passwordBox.Font = Enum.Font.Gotham
        passwordBox.TextSize = 18
        passwordBox.ZIndex = 502
        passwordBox.Parent = card
        local inputCorner = Instance.new("UICorner")
        inputCorner.CornerRadius = UDim.new(0, 10)
        inputCorner.Parent = passwordBox

        local status = Instance.new("TextLabel")
        status.BackgroundTransparency = 1
        status.Position = UDim2.new(0, 22, 0, 158)
        status.Size = UDim2.new(1, -44, 0, 22)
        status.Font = Enum.Font.Gotham
        status.Text = "The panel stays locked until the code is accepted."
        status.TextColor3 = Color3.fromRGB(150, 165, 190)
        status.TextSize = 10
        status.TextWrapped = true
        status.ZIndex = 502
        status.Parent = card

        local unlock = Instance.new("TextButton")
        unlock.Name = "Unlock"
        unlock.Position = UDim2.new(0, 22, 0, 194)
        unlock.Size = UDim2.new(1, -44, 0, 48)
        unlock.BackgroundColor3 = Color3.fromRGB(28, 131, 84)
        unlock.BorderSizePixel = 0
        unlock.AutoButtonColor = true
        unlock.Text = "UNLOCK"
        unlock.TextColor3 = Color3.new(1, 1, 1)
        unlock.Font = Enum.Font.GothamBold
        unlock.TextSize = 14
        unlock.ZIndex = 502
        unlock.Parent = card
        local unlockCorner = Instance.new("UICorner")
        unlockCorner.CornerRadius = UDim.new(0, 10)
        unlockCorner.Parent = unlock

        local function tryUnlock()
            if passwordBox.Text == "4444" then
                authenticated = true
                backdrop:Destroy()
                frame.Visible = true
                statusLabel = nil
                refreshIndicator(true)
            else
                status.Text = "Wrong code. Try again."
                status.TextColor3 = Color3.fromRGB(255, 105, 105)
                passwordBox.Text = ""
            end
        end
        connectUI(unlock.Activated, tryUnlock)
        connectUI(passwordBox.FocusLost, function(enterPressed)
            if enterPressed then tryUnlock() end
        end)
    end

    -- Compact single-control pill; the same surface supports tap and one-finger drag.
    frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.AnchorPoint = Vector2.new(1, 0.5)
    frame.Position = savedPanelPosition or DEFAULT_PANEL_POSITION
    frame.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
    frame.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
    frame.BackgroundTransparency = 0.04
    frame.BorderSizePixel = 0
    frame.Active = false
    frame.ZIndex = 100
    frame.Visible = authenticated
    frame.Parent = gui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 11)
    frameCorner.Parent = frame

    indicatorStroke = Instance.new("UIStroke")
    indicatorStroke.Color = STROKE_OFF
    indicatorStroke.Transparency = 0.2
    indicatorStroke.Thickness = 1
    indicatorStroke.Parent = frame

    toggleButton = Instance.new("TextButton")
    toggleButton.Name = "Toggle"
    toggleButton.Position = UDim2.fromOffset(3, 3)
    toggleButton.Size = UDim2.new(1, -6, 1, -6)
    toggleButton.BorderSizePixel = 0
    toggleButton.TextColor3 = Color3.new(1, 1, 1)
    toggleButton.Font = Enum.Font.GothamBold
    toggleButton.TextSize = 14
    toggleButton.AutoButtonColor = false
    toggleButton.Active = true
    toggleButton.Selectable = false
    toggleButton.ZIndex = 101
    toggleButton.BackgroundColor3 = CFG.Enabled and FILL_ON or FILL_OFF
    toggleButton.Text = CFG.Enabled and "MANS  ON" or "MANS  OFF"
    toggleButton.Parent = frame

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 8)
    buttonCorner.Parent = toggleButton

    -- Leave room on the left for the state dot.
    local buttonPadding = Instance.new("UIPadding")
    buttonPadding.PaddingLeft = UDim.new(0, 18)
    buttonPadding.Parent = toggleButton

    -- The dot lives on the frame (not the padded button) and never eats touches.
    indicatorDot = Instance.new("Frame")
    indicatorDot.Name = "StateDot"
    indicatorDot.AnchorPoint = Vector2.new(0, 0.5)
    indicatorDot.Position = UDim2.new(0, 16, 0.5, 0)
    indicatorDot.Size = UDim2.fromOffset(10, 10)
    indicatorDot.BorderSizePixel = 0
    indicatorDot.Active = false
    indicatorDot.ZIndex = 102
    indicatorDot.BackgroundColor3 = INDICATOR_COLORS.off
    indicatorDot.Parent = frame

    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = indicatorDot

    -- Keep the legacy status labels nil: no extra text/UI is shown.
    statusLabel, detailLabel = nil, nil

    local dragging = false
    local dragMoved = false
    local dragStart, startPosition
    local activeInput

    -- Keep the whole pill on screen. ScreenGui.AbsoluteSize already accounts for
    -- the top bar / notch insets, so this is correct on every device.
    local function clampPosition(position)
        local view = gui and gui.AbsoluteSize
        if not view or view.X < PANEL_WIDTH * 2 or view.Y < PANEL_HEIGHT * 2 then
            return position
        end
        local xMin = PANEL_MARGIN + PANEL_WIDTH - position.X.Scale * view.X
        local xMax = view.X - PANEL_MARGIN - position.X.Scale * view.X
        local yMin = PANEL_HEIGHT / 2 + PANEL_MARGIN - position.Y.Scale * view.Y
        local yMax = view.Y - PANEL_HEIGHT / 2 - PANEL_MARGIN - position.Y.Scale * view.Y
        return UDim2.new(
            position.X.Scale, math.clamp(position.X.Offset, xMin, math.max(xMin, xMax)),
            position.Y.Scale, math.clamp(position.Y.Offset, yMin, math.max(yMin, yMax))
        )
    end

    local function toggleMans()
        CFG.Enabled = not CFG.Enabled
        if not CFG.Enabled then
            -- Stop the automation immediately; do not issue Move(Vector3.zero),
            -- because that briefly overrides the player's own joystick input.
            activeDodge = nil
            resetKiteFocus()
            nextKitePulseAt = 0
        end
        refreshIndicator(true)
        setStatus(CFG.Enabled and "SCANNING" or "PAUSED",
            CFG.Enabled and "Auto Mans enabled" or "Auto Mans paused")
    end

    -- Use one gesture handler for taps and drags so mobile executor/UI timing
    -- cannot fire a delayed Activated event or toggle twice.
    connectUI(toggleButton.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragMoved = false
            dragStart = input.Position
            startPosition = frame.Position
            activeInput = input
        end
    end)

    connectUI(UserInputService.InputChanged, function(input)
        if not dragging or not activeInput or not dragStart or not startPosition then return end
        local isMatchingTouch = activeInput.UserInputType == Enum.UserInputType.Touch
            and input == activeInput
        local isMouseMove = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement

        if isMatchingTouch or isMouseMove then
            local delta = input.Position - dragStart
            -- Ignore normal touch jitter. A tap toggles; a real swipe drags.
            if delta.Magnitude >= 12 then dragMoved = true end
            if dragMoved then
                frame.Position = clampPosition(UDim2.new(
                    startPosition.X.Scale, startPosition.X.Offset + delta.X,
                    startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
                ))
                savedPanelPosition = frame.Position
            end
        end
    end)

    connectUI(UserInputService.InputEnded, function(input)
        if not dragging or not activeInput then return end
        local touchEnded = input == activeInput
        local mouseEnded = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseButton1
        if touchEnded or mouseEnded then
            local wasTap = not dragMoved
            dragging = false
            activeInput = nil
            dragStart = nil
            startPosition = nil
            dragMoved = false
            if wasTap then
                toggleMans()
            end
        end
    end)

    refreshIndicator(true)
end

local function planCloseOrbit(dodge, now)
    if not dodge or not dodge.root or not dodge.root.Parent then return nil end
    local threat = dodge.threat
    local targetCharacter = threat and (threat.killerCharacter or threat.npcModel)
    local _, targetRoot = getCharacterParts(targetCharacter)
    if not targetRoot then return nil end

    if now < (dodge.nextOrbitPlanAt or 0) and dodge.orbitDirection then
        return dodge.orbitDirection
    end
    dodge.nextOrbitPlanAt = now + CFG.OrbitReplanInterval

    local root = dodge.root
    local away = unitOrZero(flat(root.Position - (targetRoot.Position + flat(targetRoot.AssemblyLinearVelocity) * 0.06)))
    if away.Magnitude < 0.01 then away = unitOrZero(flat(root.CFrame.LookVector)) end
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end

    local tangent = Vector3.new(-away.Z, 0, away.X) * (dodge.orbitSide or 1)
    local distance = flat(root.Position - targetRoot.Position).Magnitude
    -- Correct toward a stable radius; a constant outward push tends to create spirals.
    local radialError = CFG.CloseOrbitTargetRadius - distance
    local radialWeight = math.clamp(radialError * 0.55, -0.80, 0.95)
    if distance < 2.65 then
        radialWeight = math.max(radialWeight, 1.0) -- escape immediate collision range
    end
    local desired = unitOrZero(tangent * CFG.OrbitTangentWeight + away * radialWeight)
    if desired.Magnitude < 0.01 then desired = away end

    local queryContext = makeMovementQueryContext(root)

    local function rotated(v, degrees)
        local angle = math.rad(degrees)
        local c, si = math.cos(angle), math.sin(angle)
        return unitOrZero(Vector3.new(v.X * c - v.Z * si, 0, v.X * si + v.Z * c))
    end

    local candidates = {
        desired,
        rotated(desired, 25), rotated(desired, -25),
        rotated(desired, 50), rotated(desired, -50),
        rotated(desired, 80), rotated(desired, -80),
        tangent, -tangent, away,
    }
    local bestDirection, bestScore = nil, -math.huge
    local currentThreats = collectNearbyThreats(threat, root)
    for _, candidate in ipairs(candidates) do
        local clearDirection, clearance = directionClearance(root, candidate, queryContext)
        if clearDirection then
            local orbitAlignment = clearDirection:Dot(desired)
            local outward = clearDirection:Dot(away)
            local threatSafety = scoreDirection(root, dodge.humanoid, clearDirection, clearance, currentThreats, threat)
            local score = orbitAlignment * 3.0 + outward * (distance < 2.6 and 0.8 or 0.08)
                + math.min(clearance or 0, CFG.ProbeDistance) * 0.09
                + threatSafety * 0.055
            if score > bestScore then
                bestScore, bestDirection = score, clearDirection
            end
        end
    end

    if not bestDirection then
        -- If the circle points into a wall/corner, abandon it and use the
        -- general threat-scored escape planner instead of pushing into geometry.
        bestDirection = select(1, chooseDodgeDirection(root, dodge.humanoid, threat))
        dodge.orbitSide = -(dodge.orbitSide or 1)
        dodge.orbitProgress = 0
        dodge.lastOrbitAngle = orbitAngle(root, targetRoot)
        if not bestDirection then
            -- No proven safe direction: stop pushing into the obstacle and retry
            -- on the next orbit-planning tick.
            bestDirection = Vector3.zero
        end
    end

    dodge.orbitDirection = bestDirection
    dodge.direction = bestDirection
    return bestDirection
end

local function cleanup()
    if shuttingDown then return end
    shuttingDown = true
    activeDodge = nil
    resetKiteFocus()
    nextKitePulseAt = 0

    pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV7_1_Move") end)

    for _, connection in ipairs(uiConnections) do disconnect(connection) end
    table.clear(uiConnections)

    for _, connection in ipairs(connections) do disconnect(connection) end
    table.clear(connections)

    for _, conns in pairs(playerConnections) do
        for _, connection in ipairs(conns) do disconnect(connection) end
    end
    table.clear(playerConnections)

    for _, connection in pairs(characterConnections) do disconnect(connection) end
    table.clear(characterConnections)
    for _, connection in pairs(npcAnimationConnections) do disconnect(connection) end
    table.clear(npcAnimationConnections)
    table.clear(npcAnimationPending)
    table.clear(trackedParts)
    table.clear(trackedHazards)
    table.clear(npcCandidates)
    table.clear(npcThreatCache)
    npcThreatCacheAt = -math.huge
    npcThreatCacheRoot = nil
    table.clear(lastHazardDodgeAt)
    table.clear(hazardThreatCache)
    hazardThreatCacheAt = -math.huge
    hazardThreatCacheRoot = nil
    hazardThreatCacheRadius = nil
    trackedCount = 0
    trackedHazardCount = 0
    table.clear(lastByKiller)
    table.clear(heldMovementKeys)
    table.clear(touchStarts)
    gamepadMoveUntil = 0
    manualOverrideUntil = 0
    playerControls = nil

    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
    gui, statusLabel, detailLabel, toggleButton = nil, nil, nil, nil
    indicatorDot, indicatorStroke, indicatorState = nil, nil, nil
end

env.VD_AUTO_MANS_STOP = cleanup
_G.VD_AUTO_MANS_STOP = cleanup

pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV7_1_Move") end)
RunService:BindToRenderStep(
    "VD_AutoMansV7_1_Move",
    Enum.RenderPriority.Last.Value,
    guarded("steering", function()
        if shuttingDown then return end
        local dodge = activeDodge
        if not dodge then return end

        local now = os.clock()
        if not CFG.Enabled or now >= dodge.finishAt then
            -- Simply release our render-step steering; normal player controls resume.
            activeDodge = nil
            return
        end

        if LocalPlayer.Character ~= dodge.character
            or not dodge.root.Parent
            or not dodge.humanoid.Parent
            or dodge.humanoid.Health <= 0 then
            activeDodge = nil
            return
        end

        -- Release at once if the game takes over mid-maneuver (hooked, carried, frozen,
        -- interacting...). Checked a few times per second, only while a dodge is active.
        if now - (dodge.lastBlockCheckAt or 0) >= 0.1 then
            dodge.lastBlockCheckAt = now
            if localCharacterBlocked(dodge.character, dodge.humanoid) then
                activeDodge = nil
                return
            end
        end

        -- The user's keyboard/gamepad/joystick input outranks every automatic maneuver.
        -- This check is separate from Humanoid.MoveDirection because that property can
        -- reflect our own preceding Move() call while automation is active.
        if manualMovementActive(now) then
            activeDodge = nil
            nextKitePulseAt = math.max(nextKitePulseAt, now + CFG.ManualInputGrace)
            return
        end

        -- Emergency takeover is conditional: release when the target leaves the
        -- critical bubble, disappears, the actual 360 completes, or the safety timer expires.
        if dodge.orbiting then
            local _, targetRoot = getCharacterParts(dodge.threat and (dodge.threat.killerCharacter or dodge.threat.npcModel))
            if not targetRoot then
                activeDodge = nil
                return
            end

            local orbitOffset = dodge.root.Position - targetRoot.Position
            local distance = orbitOffset.Magnitude
            if math.abs(orbitOffset.Y) > CFG.CriticalVerticalSeparation
                or distance > CFG.EmergencyTakeoverReleaseRange
                or now - (dodge.orbitStartedAt or dodge.startedAt) >= CFG.CloseOrbitTimeout then
                activeDodge = nil
                return
            end

            local angle = orbitAngle(dodge.root, targetRoot)
            if angle then
                if dodge.lastOrbitAngle then
                    local delta = signedAngleDelta(dodge.lastOrbitAngle, angle)
                    dodge.orbitProgress = (dodge.orbitProgress or 0)
                        + delta * (dodge.orbitSide or 1)
                end
                dodge.lastOrbitAngle = angle
            end
            if (dodge.orbitProgress or 0) >= (math.pi * 2) then
                activeDodge = nil
                return
            end
        end

        -- One mid-maneuver re-plan: avoids locking into a bad line if the
        -- killer cuts across after the first half of the dodge.
        local shouldRetargetKite = dodge.kiting and now >= dodge.retargetAt
        local shouldRetargetDodge = not dodge.kiting and not dodge.retargeted
            and (dodge.retargetNow or now >= dodge.retargetAt)
        if shouldRetargetKite or shouldRetargetDodge then
            local threat = dodge.threat
            local freshThreat = nil

            local targetModel = threat and (threat.killerCharacter or threat.npcModel)
            if targetModel then
                local _, enemyRoot = getCharacterParts(targetModel)
                if enemyRoot then
                    freshThreat = {
                        time = 0.12,
                        position = enemyRoot.Position,
                        velocity = enemyRoot.AssemblyLinearVelocity,
                        kind = threat.kind or "re-target",
                        killerCharacter = threat.killerCharacter,
                        npcModel = threat.npcModel,
                        sourceRoot = enemyRoot,
                        kiting = dodge.kiting == true,
                    }
                end
            elseif threat and threat.projectile and threat.projectile.Parent then
                freshThreat = {
                    time = 0.12,
                    position = threat.projectile.Position,
                    velocity = getTrackedVelocity(threat.projectile, now),
                    kind = threat.kind or "projectile re-target",
                    projectile = threat.projectile,
                }
            elseif threat and threat.hazardPart and threat.hazardPart.Parent then
                local point = nearestPointOnPart(threat.hazardPart, dodge.root.Position)
                freshThreat = {
                    time = 0.08,
                    position = point,
                    velocity = Vector3.zero,
                    kind = threat.kind or "environment hazard re-target",
                    hazardPart = threat.hazardPart,
                    hazardRoot = threat.hazardRoot,
                    avoidRadius = threat.avoidRadius,
                }
            end

            if freshThreat then
                freshThreat.kiting = dodge.kiting == true
                local newDirection, newScore, clearance = chooseDodgeDirection(dodge.root, dodge.humanoid, freshThreat)
                if newDirection then
                    dodge.direction = newDirection
                    dodge.smoothedStyleDirection = newDirection
                    dodge.lastStyleSafetyAt = 0 -- validate the new route immediately
                    dodge.lastStyleUpdateAt = now
                    dodge.score = newScore
                    dodge.clearance = clearance
                    if dodge.kiting then
                        setStatus("KITE: ADJUST", string.format("Path refreshed • %.1f clear", clearance))
                    else
                        setStatus("RE-WEAVE", string.format("Updated path • %.1f studs clear", clearance))
                    end
                else
                    -- A fresh route check found no safe direction; do not keep forcing
                    -- the old vector after the world/target has changed.
                    setStatus("NO SAFE STEP", "Route blocked; joystick restored")
                    activeDodge = nil
                    return
                end
            end
            if not dodge.kiting then dodge.retargeted = true end
            dodge.retargetNow = false
            if dodge.kiting then dodge.retargetAt = now + CFG.KiteReplanInterval end
        end

        if dodge.orbiting then
            local orbitDirection = planCloseOrbit(dodge, now)
            if orbitDirection then
                if orbitDirection.Magnitude < 0.02 then
                    activeDodge = nil
                    return
                end
                dodge.direction = orbitDirection
            end

            -- Recover from corners: if we are issuing movement but make almost
            -- no horizontal progress, flip orbit direction and find another safe path.
            if now - (dodge.lastMotionCheckAt or now) >= CFG.StuckCheckInterval then
                local previousPosition = dodge.lastMotionPosition or dodge.root.Position
                local progress = flat(dodge.root.Position - previousPosition).Magnitude
                dodge.lastMotionPosition = dodge.root.Position
                dodge.lastMotionCheckAt = now
                if progress < CFG.StuckMinProgress then
                    dodge.orbitSide = -(dodge.orbitSide or 1)
                    dodge.orbitProgress = 0
                    local _, targetRoot = getCharacterParts(dodge.threat and (dodge.threat.killerCharacter or dodge.threat.npcModel))
                    dodge.lastOrbitAngle = orbitAngle(dodge.root, targetRoot)
                    dodge.orbitDirection = nil
                    dodge.nextOrbitPlanAt = 0
                    local escapeDirection = select(1, chooseDodgeDirection(dodge.root, dodge.humanoid, dodge.threat))
                    if escapeDirection then
                        dodge.direction = escapeDirection
                        dodge.orbitDirection = escapeDirection
                        dodge.nextOrbitPlanAt = now + 0.10
                    else
                        -- Never keep overriding the joystick while trapped; hand back control.
                        activeDodge = nil
                        return
                    end
                end
            end
        else
            -- General anti-stuck recovery for short dodges and kite pulses too.
            -- The old recovery only covered close orbit, so a normal sidestep could
            -- keep pushing into a corner until its timer expired.
            if now - (dodge.lastMotionCheckAt or now) >= CFG.ShortStuckCheckInterval then
                local previousPosition = dodge.lastMotionPosition or dodge.root.Position
                local progress = flat(dodge.root.Position - previousPosition).Magnitude
                dodge.lastMotionPosition = dodge.root.Position
                dodge.lastMotionCheckAt = now
                if progress < CFG.StuckMinProgress then
                    if (dodge.stuckRetries or 0) >= 1 then
                        setStatus("STUCK: CONTROL", "No progress; joystick restored")
                        activeDodge = nil
                        return
                    end
                    local escapeDirection = select(1, chooseDodgeDirection(dodge.root, dodge.humanoid, dodge.threat))
                    if not escapeDirection or escapeDirection.Magnitude <= 0.02 then
                        setStatus("NO SAFE STEP", "Blocked / edge detected; joystick restored")
                        activeDodge = nil
                        return
                    end
                    dodge.stuckRetries = (dodge.stuckRetries or 0) + 1
                    dodge.direction = escapeDirection
                    dodge.smoothedStyleDirection = escapeDirection
                    dodge.lastStyleSafetyAt = 0
                    -- Extend just enough for one more progress check after replanning.
                    dodge.finishAt = math.max(dodge.finishAt, now + CFG.ShortStuckCheckInterval + 0.035)
                else
                    dodge.stuckRetries = 0
                end
            end

            if CFG.MovementStylesEnabled then
                local styledDirection = styledDirectionFor(dodge, now)
                if not styledDirection or styledDirection.Magnitude <= 0.02 then
                    -- styledDirectionFor returns zero when every tested path is blocked.
                    -- Do not fall back to the previous direction and keep pushing the wall.
                    activeDodge = nil
                    return
                end
                dodge.direction = styledDirection
            end
        end

        dodge.humanoid:Move(dodge.direction, false)
    end, function()
        -- On any error hand control straight back to the player.
        activeDodge = nil
    end)
)

connect(Players.PlayerAdded, watchPlayer)
connect(Players.PlayerRemoving, function(player)
    if player.Character then
        local character = player.Character
        characterTokens[character] = (characterTokens[character] or 0) + 1
        disconnect(characterConnections[character])
        characterConnections[character] = nil
        watchedCharacters[character] = nil
        lastByKiller[character] = nil
        if activeDodge and activeDodge.threat and activeDodge.threat.killerCharacter == character then
            activeDodge = nil
        end
    end
    for _, connection in ipairs(playerConnections[player] or {}) do disconnect(connection) end
    playerConnections[player] = nil
end)

connect(Workspace.DescendantRemoving, function(instance)
    if instance:IsA("Model") then unregisterNpcModel(instance) end
end)

connect(Workspace.DescendantAdded, function(instance)
    if instance:IsA("Model") or instance:IsA("Humanoid") then
        task.defer(function()
            if shuttingDown then return end
            local model = instance:IsA("Model") and instance
                or (instance:IsA("Humanoid") and instance.Parent)
            if model and model:IsA("Model") then
                task.delay(0.08, function()
                    if not shuttingDown then registerNpcModel(model) end
                end)
            end
        end)
    end
    if not instance:IsA("BasePart") then return end
    task.delay(CFG.NewPartDelay, function()
        if shuttingDown then return end
        trackPart(instance)
        if instance.Name == "HumanoidRootPart" or instance.Name == "RootPart" then
            local model = instance:FindFirstAncestorOfClass("Model")
            if model then registerNpcModel(model) end
        end
    end)
end)

-- Scan existing parts without blocking a single frame for the full map.
task.spawn(function()
    local descendants = Workspace:GetDescendants()
    for index, instance in ipairs(descendants) do
        if shuttingDown then break end
        if instance:IsA("BasePart") then
            trackPart(instance)
        elseif instance:IsA("Humanoid") then
            local model = instance.Parent
            if model and model:IsA("Model") then registerNpcModel(model) end
        elseif instance:IsA("Model") and instance:FindFirstChildOfClass("Humanoid") then
            registerNpcModel(instance)
        end
        if index % CFG.InitialScanYieldEvery == 0 then task.wait() end
    end
end)

connect(RunService.Heartbeat, guarded("threat scan", function()
    if shuttingDown or not CFG.Enabled then return end
    if isLocalKillerRole() then
        -- If the role changes mid-round, never leave an old dodge steering the killer.
        activeDodge = nil
        resetKiteFocus()
        return
    end

    local now = os.clock()
    if manualMovementActive(now) then
        activeDodge = nil
        nextKitePulseAt = math.max(nextKitePulseAt, now + CFG.ManualInputGrace)
        return
    end
    if now - lastPrediction < CFG.PredictionInterval then return end
    lastPrediction = now

    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root or localCharacterBlocked(character, humanoid) then
        activeDodge = nil
        return
    end

    local nearestCriticalThreat = nil
    local nearestCriticalDistance = CFG.EmergencyTakeoverRange

    -- Hard-close contact is handled first; do not let a low-score projectile
    -- candidate hide a killer already inside the emergency bubble.
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isKiller(player) then
            local _, enemyRoot = getCharacterParts(player.Character)
            if enemyRoot then
                local offset = enemyRoot.Position - root.Position
                local distance = offset.Magnitude
                local sameLevel = math.abs(offset.Y) <= CFG.CriticalVerticalSeparation
                if sameLevel and distance <= nearestCriticalDistance
                    and hasLineOfSight(root, enemyRoot, player.Character) then
                    nearestCriticalDistance = distance
                    nearestCriticalThreat = {
                        time = 0,
                        score = -1,
                        position = enemyRoot.Position,
                        velocity = enemyRoot.AssemblyLinearVelocity,
                        kind = "CRITICAL PROXIMITY",
                        killerCharacter = player.Character,
                        sourceRoot = enemyRoot,
                    }
                end
            end
        end
    end

    local predictedKillerThreats = {}
    if CFG.PlayerPrediction then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                local threat
                if isKiller(player) then
                    threat = predictKillerThreat(root, player.Character)
                else
                    threat = predictUnmarkedPlayerThreat(root, player)
                end
                if threat then table.insert(predictedKillerThreats, threat) end
            end
        end
    end

    local npcThreats = collectNpcThreats(root)
    local projectileThreat = nil
    if CFG.ProjectilePrediction then
        projectileThreat = predictProjectileThreat(root)
    end

    local kiteThreat = findKiteThreat(root)
    local environmentHazardThreat = findEnvironmentHazardThreat(root, humanoid)
    local lead = latencyLead()
    local urgentThreat = nearestCriticalThreat
    local bestUrgency = nearestCriticalThreat and -math.huge or math.huge

    -- Compare actual time-to-contact first. Score only breaks near-equal ties;
    -- score scales from different prediction types are not directly comparable.
    if not nearestCriticalThreat then
        for _, threat in ipairs(predictedKillerThreats) do
            local eta = threat.time or 1
            if eta <= 0.18 + lead then
                local urgency = eta + math.max(0, threat.score or eta) * 0.04
                if urgency < bestUrgency then
                    urgentThreat, bestUrgency = threat, urgency
                end
            end
        end
    end

    if projectileThreat and (projectileThreat.time or 1) <= 0.24 + lead then
        local urgency = (projectileThreat.time or 1)
            + math.max(0, projectileThreat.score or 0) * 0.04
        if not nearestCriticalThreat and urgency < bestUrgency then
            urgentThreat, bestUrgency = projectileThreat, urgency
        end
    end

    for _, candidateNpcThreat in ipairs(npcThreats) do
        if (candidateNpcThreat.time or 1) <= 0.24 + lead then
            local urgency = (candidateNpcThreat.time or 1)
                + math.max(0, candidateNpcThreat.score or 0) * 0.04
            if not nearestCriticalThreat and urgency < bestUrgency then
                urgentThreat, bestUrgency = candidateNpcThreat, urgency
            end
        end
    end

    if environmentHazardThreat and (environmentHazardThreat.time or 1) <= CFG.HazardLookAheadTime then
        local urgency = (environmentHazardThreat.time or 1)
            + math.max(0, environmentHazardThreat.score or 0) * 0.025
        if not nearestCriticalThreat and urgency < bestUrgency then
            urgentThreat, bestUrgency = environmentHazardThreat, urgency
        end
    end

    local imminentHandled = false
    if urgentThreat then
        local accepted = requestDodge(urgentThreat, true)
        -- Throttle repeated route planning around the same map hazard even when
        -- every route is blocked; the anti-stuck path already handles one retry.
        if urgentThreat.hazardRoot then
            lastHazardDodgeAt[urgentThreat.hazardRoot] = now
        end
        -- A cue that could not produce a safe route must not automatically block
        -- a separate kite attempt when no movement is currently active.
        imminentHandled = accepted or (activeDodge ~= nil and now < activeDodge.finishAt)
    end

    -- A confirmed danger takes priority. Otherwise, the soft-kite controller can
    -- independently create space; failed prediction candidates do not suppress it.
    local proactiveNpcThreat = nil
    for _, candidateNpcThreat in ipairs(npcThreats) do
        if candidateNpcThreat.kiting or (candidateNpcThreat.time or 1) > 0.24 then
            proactiveNpcThreat = candidateNpcThreat
            break
        end
    end
    local proactiveThreat = kiteThreat or proactiveNpcThreat
    if not imminentHandled and proactiveThreat then
        if now >= nextKitePulseAt and (not activeDodge or now >= activeDodge.finishAt) then
            if requestDodge(proactiveThreat, true) then
                nextKitePulseAt = now + CFG.KitePulseDuration + CFG.KiteRestDuration
            else
                nextKitePulseAt = now + 0.12
            end
        end
    elseif not kiteThreat then
        resetKiteFocus()
    end
end, function()
    activeDodge = nil
end))

for _, player in ipairs(Players:GetPlayers()) do watchPlayer(player) end
makeUI()
setStatus("SCANNING", "Close-range orbit • wall-aware")

-- Recreate only the small panel if PlayerGui/ScreenGui is removed or replaced.
-- This preserves the current ON/OFF state and does not restart the movement logic.
local nextUIRepairAt = 0
connect(RunService.Heartbeat, guarded("panel", function()
    if shuttingDown then return end
    refreshIndicator()
    local now = os.clock()
    if now < nextUIRepairAt then return end

    local currentPlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local panelMissing = not gui or not gui.Parent
        or not currentPlayerGui or gui.Parent ~= currentPlayerGui
        or not gui:FindFirstChild("Panel")
    if panelMissing then
        nextUIRepairAt = now + 0.5
        if currentPlayerGui then makeUI() end
    end
end))
print("[VD Auto Mans V7.1] Deep audit movement fixes loaded; live-game behavior is not verified.")
