--[[
VD AUTO MANS V8.2 — NO-LOOK FOOTWORK + COPY BUTTON (compact touch panel)
V8.2: both buttons can be dragged partly off the screen (CFG.PanelPeekPx pixels always stay
visible, so you can drag them back); the copied report is laid out in aligned columns.
V8.1: a separate COPY LOG button under the MANS pill (tap = copy, drag = move). One tap copies
everything the script learned in one piece: hit reports, tuned settings, learned attack timings
and the latest events. Nothing is copied automatically any more.
V8.0: the script NEVER rotates your character (no facing / lock-on): it only steers with
Humanoid:Move. Hits that land together count as one burst and tune the settings once.
From V7.9: no stop-start between steps, charge-aware dodging, longer spacing range.

V7.8: spacing is now bursts of committed steps (sidestep / back-side / backstep / bait-in)
with pauses where YOU steer, flank-aware side choice, speed ramps, and wander noise.
Tune everything in CFG.Footwork* / CFG.Kite*.

(V7.2 notes follow)
Originally tuned for PlaceId 93978595733734; no longer hard-blocks other PlaceIds.
Other games remain best-effort and may need different timing/attack cues.

Client-side only: it steers your own character with Humanoid:Move and never
fires game remotes. ThreatMode = "ANY_PLAYER" is the default; it does not require
recognizing a killer role to react to other players.

  * Reads player animations, predicted approach paths and fast moving loose parts, and
    reacts only to imminent danger (short, scored dodges away from the threat).
  * Point-blank target: wall- and edge-aware close-range orbit, then control goes
    straight back to your joystick.
  * Never steers while you are hooked / carried / downed, frozen by the game
    (WalkSpeed ~ 0), climbing, seated, or while a "busy" attribute is set
    (CFG.BlockingAttributes: healing, repairing, vaulting, stunned, ...).
  * Reaction window widens a little on high ping (CFG.LatencyCompensation).
  * After a close orbit ends you get your joystick back for CFG.OrbitCooldown seconds,
    so you can run off or fight back instead of being orbited endlessly.
  * Compact pill: tap = ON/OFF, drag = move (stays on screen, position survives a
    UI rebuild). Dot: green = armed, amber = dodging, red = close orbit.
  * Any error inside the script releases steering instead of leaving it stuck.
  * Lighter on phones: fewer raycasts per decision, less garbage per frame.
  * CFG.Debug = true prints every decision (dodge / orbit / no path) to the console,
    so after a match you can see what it did and why.

ThreatMode defaults to ANY_PLAYER, so detection is not tied to the killer role;
KILLERS_ONLY remains available in CFG. Proactive spacing is enabled. This is a client-side prototype: server-side hitboxes,
attack-specific mechanics, latency and executor differences can still make a dodge
miss, so judge it in a real match.
]]

-- Stop an older copy first, even when a place transition means this script must exit.
local env = (getgenv and getgenv()) or _G
local previousStop = env.VD_AUTO_MANS_STOP or _G.VD_AUTO_MANS_STOP
if type(previousStop) == "function" then
    pcall(previousStop)
end

-- Deliberately no PlaceId gate: initialize in other games that use standard
-- Player / Character / Humanoid objects. Detection quality is game-dependent.

local Players = game:GetService("Players")
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

    -- ANY_PLAYER = react to any other player and tracked moving hazards.
    -- KILLERS_ONLY = restrict player prediction/animation/orbit to detected killers.
    ThreatMode = "ANY_PLAYER",

    -- true = print each decision to the console (for tuning after a match).
    Debug = false,

    -- Never steer while the game is holding you still or you are busy.
    FrozenWalkSpeed = 0.5, -- WalkSpeed at/below this = the game froze you (interaction, stun, lock)
    BlockingAttributes = { -- any of these set to true on your character or player = hands off
        "IsHooked", "Hooked", "IsCarried", "Carried", "BeingCarried",
        "Knocked", "Downed", "IsDowned", "IsDead", "Dead",
        "Stunned", "IsStunned", "Stun", "Ragdoll", "Ragdolled", "IsRagdolled",
        "Interacting", "IsInteracting", "Healing", "IsHealing", "Repairing", "IsRepairing",
        "Vaulting", "IsVaulting", "InLocker", "Hiding", "IsHiding", "Busy", "IsBusy",
    },

    -- Widen reaction windows by up to LatencyMaxLead seconds (half of your ping).
    LatencyCompensation = true,
    LatencyMaxLead = 0.50,

    -- After a close orbit ends, hand control back for this long before another orbit
    -- may start (0 = keep orbiting for as long as the target stays point-blank).
    OrbitCooldown = 0.45,

    -- Animation listener watches every animation, then scores whether the
    -- situation is dangerous rather than blindly dodging every idle animation.
    AnimationTrigger = true,
    AnimationRange = 21,
    CriticalAnimationRange = 5.8,
    EmergencyTakeoverRange = 5.2, -- emergency escape when contact is imminent
    EmergencyTakeoverReleaseRange = 8.0, -- release after creating a useful gap
    MaxThreatVerticalSeparation = 5.5, -- avoid reacting to players on another floor
    CriticalVerticalSeparation = 3.5, -- close orbit is allowed only on the same level
    CloseOrbitTimeout = 0.70, -- V7.8: was 1.25; a long circle looks like a bot -- brief emergency escape; smooth spacing takes over afterward
    CloseOrbitTargetRadius = 7.5, -- create a larger gap rather than orbiting at contact range
    OrbitReplanInterval = 0.085,
    OrbitTangentWeight = 1.0,
    StuckCheckInterval = 0.22,
    StuckMinProgress = 0.32,
    CloseFacingRange = 8,
    CriticalFacingRange = 4.4, -- react to a close attacker facing us even if they briefly stop moving
    FacingThreatRange = 9.5, -- earlier cue when a nearby player starts an unnamed attack animation
    MinimumClosingSpeed = 1.0,
    FacingDotThreshold = 0.12,
    AttackNameHints = true,
    AttackHintMaxRange = 18, -- name-based attack cue range; true hitboxes remain server-owned

    -- Prediction of eligible players' future positions.
    PlayerPrediction = true,
    PlayerScanRange = 32,
    PlayerHorizon = 0.95,
    PlayerThreatRadius = 4.6,
    MinimumApproachSpeed = 1.8,
    MinimumClosingSpeedForPrediction = 0.55,
    RequireLineOfSight = true,

    -- Best-effort detection of fast, unanchored moving objects.
    ProjectilePrediction = true,
    ProjectileHorizon = 0.85,
    ProjectileThreatRadius = 3.4,
    ProjectileMinSpeed = 17,
    ProjectileMaxDistance = 95,
    ProjectileLifetime = 4.0,
    MaxTrackedParts = 240,
    InitialScanYieldEvery = 300,
    NewPartDelay = 0.04,

    -- Smart movement / steering.
    DodgeDuration = 0.44,
    TargetCooldown = 0.05,
    MinimumDodgeInterval = 0.06,
-- Proactive spacing: maintain room from nearby players instead of waiting for a hit.
    -- Smooth short pulses are replanned against walls and nearby threats.
    KiteEnabled = true,
    KiteStartRange = 18.0,   -- V7.9: was 15 (V7.8) / 28 (older)
    KiteReleaseRange = 23.0, -- V7.9: was 19
    KiteHardRange = 8.5,     -- V7.9: was 7; this close counts without approach/facing evidence
    KiteClosingThreshold = 0.45, -- V7.9: was 0.60; must be walking toward us
    KiteFacingRange = 13.0,  -- V7.9: was 11; facing us inside this range also counts
    KitePulseDuration = 0.56,
    KiteReplanInterval = 0.085,
    KiteAwayWeight = 0.38, -- favor lateral movement unless danger is immediate
    KiteSideWeight = 3.6, -- strongly favor side-steps and orbit arcs
    ProbeDistance = 5.4,
    MinimumWallClearance = 0.85,
    GroundProbeAhead = 2.7,
    GroundProbeDepth = 8.5,
    CandidateCount = 12,
    RetargetFraction = 0.44,
    CandidateThreatCount = 6,
    PlayerMotionFactor = 0.83,
    NearThreatExtraAway = 0.7,
    SideBias = 0.28,
    PredictionInterval = 0.0,

    -- Short dodges get light style variation; close-range orbit has its own steering.
    MovementStylesEnabled = true,
    StyleCycleDuration = 0.90,
    StyleBlendDuration = 0.14,
    StyleSafetyInterval = 0.075,
    SteeringSmoothingSeconds = 0.045,
    StyleRadialKeepout = 0.66,

    -- V7.8 human footwork: short committed steps with pauses instead of endless running.
    -- A "burst" = 1-3 steps; between bursts the joystick is YOURS again.
    FootworkBurstMin = 0.70, FootworkBurstMax = 1.40,
    FootworkPauseMin = 0.04, FootworkPauseMax = 0.14, -- V7.9: pause between bursts (far), was 0.14-0.42
    FootworkPauseNearMin = 0.00, FootworkPauseNearMax = 0.04, -- V7.9: pause when close (danger)
    FootworkStepMin = 0.30, FootworkStepMax = 0.62,
    FootworkRampIn = 0.035,    -- seconds to reach full speed at the start of a step
    FootworkStartSpeed = 0.65, -- speed fraction on the first frame of a step (was a fixed 0.25)
    FootworkRampOut = 0.08,    -- seconds of easing at the end of a step
    FootworkEndSpeed = 0.70,   -- speed fraction at the end of a step (was 0.35: that felt weak)
    FootworkMinSpeed = 0.50,   -- a step never drops below this speed fraction (was 0.20)
    FootworkTurnTau = 0.05,    -- seconds: smaller = snappier direction changes (path stays curved)
    FootworkWanderAngle = 0.22, -- radians of smooth noise so the path is never a clean line
    FootworkRandomSide = 0.22,  -- chance to ignore the "go to their flank" choice

    -- V7.9 charge-aware dodging: when the opponent runs AT you fast, step OFF their line
    -- (sideways) instead of backing away in a straight line they can simply run down.
    ChargeDodge = true,
    ChargeSpeed = 6.0,         -- closing speed (studs/s) that counts as a charge
    ChargeRange = 13.0,

    -- V7.8 smart timing: the script LEARNS each attack animation's real hit delay from the
    -- damage you take, then starts the evade so the step lands right before the hit.
    HitReport = true,         -- record a diagnostic report (console + COPY LOG button) when you take damage
    -- V8.0: hits closer together than HitBatchQuiet seconds form ONE burst = one entry in the
    -- report. A burst is closed at the latest after HitBatchMax seconds.
    HitBatchQuiet = 1.2,
    HitBatchMax = 6.0,
    HitBatchFullDetail = 3,   -- full breakdown for the first N hits of a burst, one line for the rest
    PanelPeekPx = 28,         -- V8.2: buttons may leave the screen, this many pixels always stay visible
    -- V7.8 wall intelligence
    WallSlide = true,          -- slide along walls instead of pushing into them
    WallLookahead = 4.2,       -- studs ahead that are checked for walls
    StuckCheckEvery = 0.14,    -- seconds between "am I actually moving?" checks
    StuckSpeedFraction = 0.40, -- less than this fraction of the expected distance = stuck
    MaxStuckBeforeRelease = 3, -- after this many stuck checks in a row the joystick is yours
    AutoHop = true,            -- hop over low obstacles when stuck against them (auto-disables if jumping does nothing)
    Adaptive = true,           -- V7.8: tune detection / timing / wall caution from the hits you take
    LearnAttackTiming = true,
    EvadeStepTime = 0.20,     -- how long an evade step needs to leave the hitbox
    EarlyBias = 0.04,         -- react this much earlier than the computed moment (seconds)
}

-- V7.8: values tuned by earlier hits survive re-running the script.
local adaptStore = env.VD_AUTO_MANS_ADAPT or {}
env.VD_AUTO_MANS_ADAPT = adaptStore
if CFG.Adaptive then
    for key, value in pairs(adaptStore) do
        if CFG[key] ~= nil and type(value) == "number" then CFG[key] = value end
    end
end
local learnedAttack = env.VD_AUTO_MANS_ATTACKS or {} -- animation ids proven to hurt us
env.VD_AUTO_MANS_ATTACKS = learnedAttack
local lastDodgeInfo = nil
local lastHitchAt = -math.huge

if CFG.ThreatMode ~= "ANY_PLAYER" and CFG.ThreatMode ~= "KILLERS_ONLY" then
    warn("[VD Auto Mans V8.2] Invalid ThreatMode; falling back to ANY_PLAYER.")
    CFG.ThreatMode = "ANY_PLAYER"
end

local shuttingDown = false
local connections = {}
local uiConnections = {}
local playerConnections = {}
local characterConnections = {}
local watchedCharacters = setmetatable({}, { __mode = "k" })
local characterTokens = setmetatable({}, { __mode = "k" })
local lastByTarget = setmetatable({}, { __mode = "k" })
local trackedParts = setmetatable({}, { __mode = "k" })

local activeDodge = nil
local lastDodge = -math.huge
local lastPrediction = 0
local preferredSide = 1
local kiteFocusCharacter = nil
local gui = nil
local statusLabel = nil
local detailLabel = nil
local toggleButton = nil
local trackedCount = 0
local savedPanelPosition = env.VD_AUTO_MANS_PANEL -- survives re-running the script
local attackStats = env.VD_AUTO_MANS_STATS or {} -- learned hit delays, survive re-running
env.VD_AUTO_MANS_STATS = attackStats
local pendingAttacks = {}
local healthConn, lastHealth = nil, nil
local orbitBlockedUntil = 0
local kitePauseUntil = 0 -- V7.8: joystick is yours until this time (between footwork bursts)
local indicatorDot = nil
local indicatorStroke = nil
local indicatorState = nil
local lastErrorWarnAt = {}

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

-- Run a callback under pcall: warn (rate-limited) instead of spamming errors, and
-- run onError (used to hand steering back to the player).
local function guarded(name, callback, onError)
    return function(...)
        local ok, err = pcall(callback, ...)
        if not ok then
            local now = os.clock()
            if now - (lastErrorWarnAt[name] or -math.huge) > 5 then
                lastErrorWarnAt[name] = now
                warn("[VD Auto Mans V8.2] " .. name .. " error: " .. tostring(err))
            end
            if onError then pcall(onError) end
        end
    end
end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

-- Ping model: round-trip time (Stats "Data Ping" when available, else GetNetworkPing) with a
-- fast-attack / slow-decay average (a spike is believed at once, recovery slowly) plus jitter.
local Stats = game:GetService("Stats")
local pingEma, pingJitter, pingSampledAt = 0, 0, -math.huge

local function samplePing()
    local now = os.clock()
    if now - pingSampledAt < 0.2 then return end
    pingSampledAt = now
    local rtt = nil
    pcall(function()
        rtt = Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if not rtt or rtt <= 0 then
        local ok, ping = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
        if ok and type(ping) == "number" then rtt = ping end
    end
    if not rtt then return end
    if pingEma == 0 then pingEma = rtt end
    local deviation = math.abs(rtt - pingEma)
    local alpha = (rtt > pingEma) and 0.6 or 0.15
    pingEma = pingEma + (rtt - pingEma) * alpha
    pingJitter = pingJitter + (deviation - pingJitter) * 0.3
end

-- How much earlier to react so the dodge input reaches the server before the hit does.
local function latencyLead()
    if not CFG.LatencyCompensation then return CFG.EarlyBias end
    samplePing()
    local lead = pingEma * 0.5 + pingJitter * 0.8
    return math.clamp(lead, 0, math.max(0, CFG.LatencyMaxLead)) + CFG.EarlyBias
end

-- 1 on a good connection, up to 2 when lagging: longer, more committed evades.
local function lagScale()
    samplePing()
    return 1 + math.clamp((pingEma - 0.12) * 1.6, 0, 1.0)
end

local function unitOrZero(v)
    if v.Magnitude < 0.001 then return Vector3.zero end
    return v.Unit
end

local lastDebugLine = nil
local function setStatus(message, detail)
    if CFG.Debug then
        local line = detail and (tostring(message) .. "  |  " .. tostring(detail)) or tostring(message)
        if line ~= lastDebugLine then -- skip identical consecutive lines
            lastDebugLine = line
            print("[VD Auto Mans] " .. line)
        end
    end
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = message
    end
    if detailLabel and detailLabel.Parent and detail then
        detailLabel.Text = detail
    end
end

local function roleMarkerSaysKiller(instance)
    if not instance then return false end

    local role = instance:GetAttribute("Role")
    if typeof(role) == "string" then
        role = string.lower(role)
        if string.find(role, "killer", 1, true)
            or string.find(role, "hunter", 1, true) then
            return true
        end
    end

    return instance:GetAttribute("Killer") == true
        or instance:GetAttribute("IsKiller") == true
        or instance:GetAttribute("Hunter") == true
        or instance:GetAttribute("IsHunter") == true
end

local function isKiller(player)
    if not player then return false end

    local teamName = player.Team and string.lower(player.Team.Name) or ""
    if string.find(teamName, "killer", 1, true)
        or string.find(teamName, "hunter", 1, true) then
        return true
    end

    if roleMarkerSaysKiller(player) then return true end
    return roleMarkerSaysKiller(player.Character)
end

-- Role-independent by default. Keeping this predicate centralized prevents a
-- hidden killer-only filter from remaining in one scanner or animation callback.
local function isThreatPlayer(player)
    if not player or player == LocalPlayer then return false end
    if CFG.ThreatMode == "KILLERS_ONLY" then
        return isKiller(player)
    end
    return true
end

local function localRoleBlocksAutomation()
    return CFG.ThreatMode == "KILLERS_ONLY" and isKiller(LocalPlayer)
end

local function getCharacterParts(character)
    if not character then return nil, nil end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("RootPart")

    if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
        return nil, nil
    end
    return humanoid, root
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

    if hasBlockingAttribute(character)
        or hasBlockingAttribute(humanoid)
        or (rootPart and hasBlockingAttribute(rootPart))
        or hasBlockingAttribute(LocalPlayer) then
        return true
    end
    return false
end

-- ===================== V7.8 DIAGNOSTICS =====================
-- Rolling event log. Every hit adds a report; tap the COPY LOG button to copy everything
-- (needs an executor with setclipboard) and paste it to see exactly why a dodge failed.
local eventLog, fullLog = {}, {}

local function logEvent(text)
    local now = os.clock()
    local last = eventLog[#eventLog]
    if last and last.text == text and now - last.t < 0.25 then return end
    eventLog[#eventLog + 1] = { t = now, text = text }
    if #eventLog > 60 then table.remove(eventLog, 1) end
    if CFG.Debug then print("[VD] " .. text) end
end

local function describeBlock(character, humanoid)
    if not character or not humanoid then return "no character/humanoid" end
    if humanoid.Health <= 0 then return "dead" end
    if humanoid.Sit or humanoid.PlatformStand then return "sit/platformstand" end
    if humanoid.WalkSpeed <= CFG.FrozenWalkSpeed then
        return "walkspeed=" .. tostring(humanoid.WalkSpeed) .. " (frozen by game)"
    end
    local ok, state = pcall(function() return humanoid:GetState() end)
    if ok and BLOCKED_STATES[state] then return "state=" .. tostring(state) end
    local rootPart = humanoid.RootPart
    if rootPart and rootPart.Anchored then return "root anchored" end
    local holders = { character, humanoid, LocalPlayer }
    if rootPart then table.insert(holders, rootPart) end
    for _, holder in ipairs(holders) do
        for name, value in pairs(holder:GetAttributes()) do
            if value == true and BLOCKING_ATTRIBUTES[name] then
                return "attribute " .. name .. " on " .. holder.Name
            end
        end
    end
    return "unknown"
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

local exclusionCache, exclusionCacheOwner, exclusionCacheAt = nil, nil, -math.huge

-- The list is cached for a few frames and shared: callers must not modify it.
local function buildCharacterExclusions(includeAllPlayers)
    local now = os.clock()
    if includeAllPlayers and exclusionCache
        and exclusionCacheOwner == LocalPlayer.Character
        and now - exclusionCacheAt < 0.04 then
        return exclusionCache
    end

    local excluded = {}
    if LocalPlayer.Character then table.insert(excluded, LocalPlayer.Character) end
    if includeAllPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                table.insert(excluded, player.Character)
            end
        end
        exclusionCache, exclusionCacheOwner, exclusionCacheAt = excluded, LocalPlayer.Character, now
    end
    return excluded
end

local LATERAL_OFFSETS = { 0, -0.58, 0.58 }
local BODY_BOX = Vector3.new(1.8, 3.0, 1.8)

local function directionClearance(root, direction)
    direction = unitOrZero(flat(direction))
    if direction.Magnitude < 0.01 then return nil, 0 end

    local clearance = CFG.ProbeDistance
    local rootPosition = root.Position
    local reach = direction * CFG.ProbeDistance

    -- Cheap rays first (hip height: centre + both shoulders). Most blocked directions
    -- are rejected here, without paying for the box sweep or the ground probe.
    -- They also catch corners/partial overlap that Roblox Blockcast does not report
    -- for parts already intersecting the start shape.
    local right = Vector3.new(-direction.Z, 0, direction.X)
    for _, lateralOffset in ipairs(LATERAL_OFFSETS) do
        local origin = rootPosition + Vector3.new(0, -0.80, 0) + right * lateralOffset
        local wall = Workspace:Raycast(origin, reach, moveRayParams)
        if wall then
            clearance = math.min(clearance, math.max(0, wall.Distance - 0.25))
        end
    end
    if clearance < CFG.MinimumWallClearance then return nil, clearance end

    -- Sweep a box approximating the avatar's body so shoulder/hip corners are checked too.
    -- Lowered and lengthened: an older cast started too high and could miss low walls.
    local ok, bodyHit = pcall(
        Workspace.Blockcast, Workspace,
        CFrame.new(rootPosition + Vector3.new(0, -0.15, 0)), BODY_BOX, reach, moveRayParams
    )
    if ok and bodyHit then
        clearance = math.min(clearance, math.max(0, bodyHit.Distance - 0.25))
    end
    if clearance < CFG.MinimumWallClearance then return nil, clearance end

    -- Reject edges and near-vertical surfaces masquerading as ground.
    local groundOrigin = rootPosition
        + direction * CFG.GroundProbeAhead
        + Vector3.new(0, 2.8, 0)
    local ground = Workspace:Raycast(
        groundOrigin,
        Vector3.new(0, -CFG.GroundProbeDepth, 0),
        groundRayParams
    )
    if not ground or ground.Normal.Y < 0.45 then return nil, clearance end

    return direction, clearance
end

-- Pick the best-scoring walkable direction. Candidates are tried best-first by an
-- optimistic score (as if the path were fully clear); the search stops as soon as no
-- remaining candidate can beat the best real score. The winner is the same as testing
-- every candidate, but most of the raycasts are never made.
local function searchBestDirection(root, candidates, optimisticScore, realScore)
    local ranked = {}
    for order, candidate in ipairs(candidates) do
        local unit = unitOrZero(flat(candidate))
        if unit.Magnitude >= 0.01 then
            local bound = optimisticScore(unit)
            if bound ~= bound then bound = math.huge end -- NaN: never prune on it
            ranked[#ranked + 1] = { candidate = candidate, bound = bound, order = order }
        end
    end
    table.sort(ranked, function(a, b)
        if a.bound ~= b.bound then return a.bound > b.bound end
        return a.order < b.order
    end)

    local bestDirection, bestScore, bestClearance = nil, -math.huge, 0
    for _, entry in ipairs(ranked) do
        if entry.bound <= bestScore then break end
        local direction, clearance = directionClearance(root, entry.candidate)
        if direction then
            local score = realScore(direction, clearance)
            if score > bestScore then
                bestScore, bestDirection, bestClearance = score, direction, clearance
            end
        end
    end
    return bestDirection, bestScore, bestClearance
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
    -- (the list already holds every player's character, the target's included)
    losParams.FilterDescendantsInstances = buildCharacterExclusions(true)

    local origin = myRoot.Position + Vector3.new(0, 1.2, 0)
    return Workspace:Raycast(origin, targetRoot.Position - origin, losParams) == nil
end

local function attackLike(track)
    if not CFG.AttackNameHints or not track then return false end

    local names = {}
    pcall(function() table.insert(names, tostring(track.Name or "")) end)
    pcall(function()
        if track.Animation then
            table.insert(names, tostring(track.Animation.Name or ""))
        end
    end)

    for _, rawName in ipairs(names) do
        -- Split camelCase before lowercasing, so "LightHit" becomes "light hit".
        local spaced = rawName:gsub("(%l)(%u)", "%1 %2"):lower()
        local compact = spaced:gsub("[^%w]", "")
        local tokens = {}
        for token in spaced:gmatch("[%w]+") do tokens[token] = true end

        -- Avoid generic "skill"/"dash" hints and arbitrary substring hits.
        -- Compound attack names (BasicAttack, HeavySlash, ChargedStrike) still match.
        if string.find(compact, "attack", 1, true)
            or string.find(compact, "lunge", 1, true)
            or string.find(compact, "slash", 1, true)
            or string.find(compact, "swing", 1, true)
            or string.find(compact, "stab", 1, true)
            or string.find(compact, "throw", 1, true)
            or string.find(compact, "charge", 1, true)
            or string.find(compact, "strike", 1, true)
            or string.find(compact, "melee", 1, true)
            or tokens.hit == true
            or tokens.m1 == true then
            return true
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

-- Predict the closest approach between the local player and an eligible target.
local function predictPlayerThreat(myRoot, targetCharacter)
    local _, targetRoot = getCharacterParts(targetCharacter)
    if not targetRoot then return nil end

    local offset = flat(targetRoot.Position - myRoot.Position)
    local distance = offset.Magnitude
    if math.abs(targetRoot.Position.Y - myRoot.Position.Y) > CFG.MaxThreatVerticalSeparation then
        return nil
    end
    if distance < 0.1 or distance > CFG.PlayerScanRange then return nil end

    local relativeVelocity = flat(targetRoot.AssemblyLinearVelocity - myRoot.AssemblyLinearVelocity)
    local speedSquared = relativeVelocity:Dot(relativeVelocity)
    if speedSquared < CFG.MinimumApproachSpeed ^ 2 then return nil end

    local t = math.clamp(-offset:Dot(relativeVelocity) / speedSquared, 0, CFG.PlayerHorizon + math.min(pingEma, 0.5))
    local closest = offset + relativeVelocity * t
    local missDistance = closest.Magnitude
    local closing = -offset:Dot(relativeVelocity) / math.max(distance, 0.1)

    if closing <= CFG.MinimumClosingSpeedForPrediction or missDistance > CFG.PlayerThreatRadius + math.min(pingEma * 5, 2.5) then
        return nil
    end
    if t <= 0.035 and distance > CFG.PlayerThreatRadius then return nil end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, targetRoot, targetCharacter) then
        return nil
    end

    return {
        score = t + missDistance * 0.06,
        time = t,
        position = targetRoot.Position,
        velocity = targetRoot.AssemblyLinearVelocity,
        kind = "approach prediction",
        targetCharacter = targetCharacter,
        sourceRoot = targetRoot,
    }
end

local function untrackPart(part)
    if trackedParts[part] ~= nil then
        trackedParts[part] = nil
        trackedCount = math.max(0, trackedCount - 1)
    end
end

-- Drop dead/anchored parts and keep the table under MaxTrackedParts (oldest first).
-- Runs only when the cap is exceeded instead of on every new part.
local function pruneTrackedParts()
    local count, oldest, oldestTime = 0, nil, math.huge
    for tracked, born in pairs(trackedParts) do
        if not tracked.Parent or tracked.Anchored then
            trackedParts[tracked] = nil
        else
            count = count + 1
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

local function trackPart(part)
    if shuttingDown or not part or not part:IsA("BasePart") then return end
    if not part.Parent or part.Anchored or not part:IsDescendantOf(Workspace) then return end
    if part.Size.Magnitude > 42 then return end
    if LocalPlayer.Character and part:IsDescendantOf(LocalPlayer.Character) then return end
    if isCharacterPart(part) then return end

    if trackedParts[part] == nil then
        trackedParts[part] = os.clock()
        trackedCount = trackedCount + 1
        if trackedCount > CFG.MaxTrackedParts then pruneTrackedParts() end
    end
end

local function predictProjectileThreat(myRoot)
    local now = os.clock()
    local best = nil

    for part, born in pairs(trackedParts) do
        if not part.Parent or part.Anchored or now - born > CFG.ProjectileLifetime then
            untrackPart(part)
        else
            local velocity = part.AssemblyLinearVelocity
            local relative = part.Position - myRoot.Position
            local distance = relative.Magnitude

            if velocity.Magnitude >= CFG.ProjectileMinSpeed
                and distance <= CFG.ProjectileMaxDistance then
                local relativeVelocity = velocity - myRoot.AssemblyLinearVelocity
                local speedSquared = relativeVelocity:Dot(relativeVelocity)

                -- Skip parts that are not moving toward the player.
                if speedSquared > 1 and relative:Dot(relativeVelocity) < 0 then
                    local t = math.clamp(-relative:Dot(relativeVelocity) / speedSquared, 0, CFG.ProjectileHorizon)
                    local miss = (relative + relativeVelocity * t).Magnitude
                    if miss <= CFG.ProjectileThreatRadius then
                        local threat = {
                            score = t + miss * 0.07,
                            time = t,
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

local function collectNearbyThreats(primary, myRoot)
    local threats = {}
    local seen = {}

    local function add(threat)
        if not threat then return end
        local key = threat.targetCharacter or threat.projectile or threat
        if seen[key] then return end
        seen[key] = true
        table.insert(threats, threat)
    end

    add(primary)

    for _, player in ipairs(Players:GetPlayers()) do
        if isThreatPlayer(player) then
            local _, root = getCharacterParts(player.Character)
            if root
                and math.abs(root.Position.Y - myRoot.Position.Y) <= CFG.MaxThreatVerticalSeparation
                and (root.Position - myRoot.Position).Magnitude <= CFG.PlayerScanRange then
                add({
                    position = root.Position,
                    velocity = root.AssemblyLinearVelocity,
                    kind = "nearby player",
                    targetCharacter = player.Character,
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
            if part.Parent and not part.Anchored then
                local velocity = part.AssemblyLinearVelocity
                local distance = (part.Position - myRoot.Position).Magnitude
                if velocity.Magnitude >= CFG.ProjectileMinSpeed and distance <= 30 then
                    local rel = part.Position - myRoot.Position
                    local relVel = velocity - myRoot.AssemblyLinearVelocity
                    local denom = relVel:Dot(relVel)
                    if denom > 1 and rel:Dot(relVel) < 0 then
                        local t = math.clamp(-rel:Dot(relVel) / denom, 0, CFG.ProjectileHorizon)
                        local miss = (rel + relVel * t).Magnitude
                        if miss < 10 then
                            table.insert(projectileThreats, {
                                score = t + miss * 0.08,
                                time = t,
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
        return threat.projectile.Position + threat.projectile.AssemblyLinearVelocity * t
    end
    if threat.targetCharacter then
        local _, root = getCharacterParts(threat.targetCharacter)
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
        local lateral
        if primary.kiting then
            -- Footwork is defined relative to the opponent's position, not their
            -- velocity; a stationary opponent must still produce an orbit step.
            lateral = Vector3.new(-away.Z, 0, away.X)
        else
            lateral = unitOrZero(Vector3.new(-enemyVelocity.Z, 0, enemyVelocity.X))
        end
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
    -- Reuse one exclusion list for all candidate raycasts in this planning pass.
    local exclusions = buildCharacterExclusions(true)
    moveRayParams.FilterDescendantsInstances = exclusions
    groundRayParams.FilterDescendantsInstances = exclusions

    local threats = collectNearbyThreats(primary, root)
    local bestDirection, bestScore = nil, -math.huge

    local away = Vector3.zero
    if primary and primary.position then
        away = unitOrZero(flat(root.Position - predictedThreatPosition(primary, math.clamp(primary.time or 0, 0, 0.22))) )
    end
    if away.Magnitude < 0.01 then away = -unitOrZero(flat(root.CFrame.LookVector)) end

    local velocity = primary and flat(primary.velocity or Vector3.zero) or Vector3.zero
    local lateral
    if primary and primary.kiting then
        -- Orbit tangent: switch sides around the target even when they stand still.
        lateral = Vector3.new(-away.Z, 0, away.X)
    else
        lateral = unitOrZero(Vector3.new(-velocity.Z, 0, velocity.X))
        if primary and primary.attackDir and primary.attackDir.Magnitude > 0.05 then
            -- Attack animation: the safe line is perpendicular to where the attacker faces.
            lateral = unitOrZero(Vector3.new(-primary.attackDir.Z, 0, primary.attackDir.X))
        end
        if lateral.Magnitude < 0.05 then
            lateral = Vector3.new(-away.Z, 0, away.X)
        end
    end

    local candidates = {}
    local primaryDistance = primary and primary.position
        and flat(root.Position - predictedThreatPosition(primary, 0)).Magnitude or math.huge
    local near = (primary and primary.kiting) or primaryDistance <= 6.5
    local retreat = (primary and primary.kiting)
        and CFG.KiteAwayWeight
        or (near and CFG.NearThreatExtraAway or 0.24)

    if primary and primary.kiting then
        -- Mostly lateral arcs with a small radial correction; never choose a
        -- pure retreat as the default when a clear side route exists.
        table.insert(candidates, unitOrZero(lateral * preferredSide + away * 0.18))
        table.insert(candidates, unitOrZero(-lateral * preferredSide + away * 0.18))
        table.insert(candidates, unitOrZero(lateral * preferredSide + away * 0.38))
        table.insert(candidates, unitOrZero(-lateral * preferredSide + away * 0.38))
        table.insert(candidates, unitOrZero(lateral * preferredSide + away * 0.62))
        table.insert(candidates, unitOrZero(-lateral * preferredSide + away * 0.62))
    else
        table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.72))
        table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.72))
        table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.35))
        table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.35))
        table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.95))
        table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.95))
    end

    if primary and primary.attackDir and primary.attackDir.Magnitude > 0.05 and not primary.kiting then
        table.insert(candidates, unitOrZero(lateral * preferredSide + away * 0.15))
        table.insert(candidates, unitOrZero(-lateral * preferredSide + away * 0.15))
    end

    for i = 0, CFG.CandidateCount - 1 do
        local angle = (math.pi * 2 * i / CFG.CandidateCount)
        table.insert(candidates, Vector3.new(math.cos(angle), 0, math.sin(angle)))
    end

    local function totalScore(moveDirection, clearance)
        local score = scoreDirection(root, humanoid, moveDirection, clearance, threats, primary)
        if near then
            score = score + moveDirection:Dot(away) * retreat
        end

        if primary and primary.kiting then
            -- Kiting is not an escape sprint: reward travel along the orbit tangent.
            -- The distance score above used to dominate this term and kept selecting
            -- straight-away paths even when a clear lateral route was available.
            local tangentAlignment = moveDirection:Dot(lateral * preferredSide)
            local radialAlignment = moveDirection:Dot(away)
            score = score + tangentAlignment * 5.4
            if primaryDistance < 5.8 then
                score = score + radialAlignment * 5.0 -- create room only at contact range
            elseif primaryDistance < 7.8 then
                score = score + radialAlignment * 1.0
                    - math.max(0, radialAlignment) * 1.6
            else
                score = score - math.max(0, radialAlignment) * 4.0 -- don't reward running away
            end
        elseif moveDirection:Dot(lateral) * preferredSide > 0.2 then
            score = score + 0.06
        end
        return score
    end

    local bestClearance
    bestDirection, bestScore, bestClearance = searchBestDirection(
        root, candidates,
        function(unit) return totalScore(unit, CFG.ProbeDistance) end,
        totalScore
    )

    if bestDirection then
        preferredSide = -preferredSide
    end
    return bestDirection, bestScore, bestClearance
end

-- Diverse footwork patterns inspired by common game-steering methods:
-- circle strafing (https://en.wikipedia.org/wiki/Strafing_(video_games))
-- and evade/separation/orbit steering (https://github.com/cpowell/steering-behaviors).
-- The VD predictive-dodge reference also motivates predicted trajectories and ground checks:
-- https://github.com/gg8752383-cpu/AutoDodge1/blob/d53d95e15b2cf3e237775065aaf8d9b11c7e7b6b/Predictive_AutoDodge.lua
-- Each pattern retains an outward component so it does not intentionally run into the target.
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

-- ===================== V7.8 WALL INTELLIGENCE =====================
-- 1) slideAlongWalls: if the move direction runs into a wall, remove the part that pushes
--    into it (slide along the wall); head-on goes toward the side with more room.
-- 2) openness: free distance in a direction, used to avoid dead ends and corners.
-- 3) Stuck detection (in the steering loop) with replan / hop / hand-back.
-- Places where we recently got stuck: planners avoid them for a few seconds.
local blockedZones = {}
local function rememberBlockedZone(position)
    blockedZones[#blockedZones + 1] = { pos = position, expires = os.clock() + 5 }
    if #blockedZones > 12 then table.remove(blockedZones, 1) end
end
local function zoneBlocked(position)
    local now = os.clock()
    for i = #blockedZones, 1, -1 do
        local zone = blockedZones[i]
        if now > zone.expires then
            table.remove(blockedZones, i)
        elseif flat(position - zone.pos).Magnitude < 3.2 then
            return true
        end
    end
    return false
end

-- Jumping may be removed/disabled by the game (no jump button, JumpPower 0): detect it and
-- verify that a hop really lifted us, otherwise treat low obstacles as walls.
local hopAvailable = true
local hopDisabledUntil, hopFails = 0, 0
local function canJumpNow(humanoid)
    local ok, enabled = pcall(function() return humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) end)
    if ok and enabled == false then return false end
    local power = humanoid.UseJumpPower and humanoid.JumpPower or humanoid.JumpHeight
    return (tonumber(power) or 0) > 0.5
end

local function prepareRays()
    local exclusions = buildCharacterExclusions(true)
    moveRayParams.FilterDescendantsInstances = exclusions
    groundRayParams.FilterDescendantsInstances = exclusions
end

local function wallRay(root, direction, length, yOffset, sideOffset)
    local right = Vector3.new(-direction.Z, 0, direction.X)
    local origin = root.Position + Vector3.new(0, yOffset, 0) + right * (sideOffset or 0)
    return Workspace:Raycast(origin, direction * length, moveRayParams)
end

local function openness(root, direction, maxLength)
    direction = unitOrZero(flat(direction))
    if direction.Magnitude < 0.01 then return 0 end
    local hit = wallRay(root, direction, maxLength, -0.8, 0)
    return hit and hit.Distance or maxLength
end

local function groundAhead(root, direction)
    local origin = root.Position + direction * CFG.GroundProbeAhead + Vector3.new(0, 2.8, 0)
    local ground = Workspace:Raycast(origin, Vector3.new(0, -CFG.GroundProbeDepth, 0), groundRayParams)
    return ground ~= nil and ground.Normal.Y >= 0.45
end

local function slideAlongWalls(root, desired)
    desired = unitOrZero(flat(desired))
    if desired.Magnitude < 0.01 then return desired, false end
    prepareRays()

    local nearest, normal = math.huge, nil
    for _, offset in ipairs({ 0, -0.7, 0.7 }) do
        local hit = wallRay(root, desired, CFG.WallLookahead, -0.8, offset)
        if hit and hit.Distance < nearest and math.abs(hit.Normal.Y) < 0.6 then
            nearest, normal = hit.Distance, hit.Normal
        end
        if not hopAvailable then
            -- Cannot jump: low obstacles (curbs, small crates) are walls too.
            local low = wallRay(root, desired, CFG.WallLookahead, -2.2, offset)
            if low and low.Distance < nearest and math.abs(low.Normal.Y) < 0.6 then
                nearest, normal = low.Distance, low.Normal
            end
        end
    end
    if not normal then return desired, false end

    local wallNormal = unitOrZero(flat(normal))
    if wallNormal.Magnitude < 0.01 then return desired, true end
    local into = desired:Dot(wallNormal)
    if into >= -0.05 then return desired, false end -- moving away from / along the wall

    local slide = desired - wallNormal * into
    if slide.Magnitude < 0.25 then
        -- Head-on: go along the wall toward the side with more room, nudged away from it.
        local tangent = Vector3.new(-wallNormal.Z, 0, wallNormal.X)
        local roomA = openness(root, tangent, 6)
        local roomB = openness(root, -tangent, 6)
        slide = ((roomA >= roomB) and tangent or -tangent) + wallNormal * 0.25
    end
    slide = unitOrZero(slide)

    local urgency = math.clamp(1 - nearest / CFG.WallLookahead, 0.15, 1)
    if nearest < 1.4 then urgency = 1 end
    local blended = unitOrZero(desired:Lerp(slide, urgency))
    if blended.Magnitude < 0.01 then blended = slide end
    if not groundAhead(root, blended) then return desired, true end -- never slide off an edge
    return blended, true
end

-- Low obstacle (curb/step) in front of the feet but clear above: hop instead of grinding.
local function tryHop(dodge, now)
    if not CFG.AutoHop or not hopAvailable then return end
    if now - (dodge.lastHopAt or -math.huge) < 0.6 then return end
    local direction = unitOrZero(flat(dodge.direction or Vector3.zero))
    if direction.Magnitude < 0.01 or not dodge.root.Parent then return end
    prepareRays()
    local low = wallRay(dodge.root, direction, 2.4, -2.2, 0)
    local high = wallRay(dodge.root, direction, 2.4, 1.2, 0)
    if low and not high then
        dodge.lastHopAt = now
        dodge.hopCheck = { at = now + 0.30, y = dodge.root.Position.Y }
        dodge.humanoid.Jump = true
        logEvent("stuck on a low obstacle: hop")
    end
end

-- Scan 16 directions for the most open one (away from the opponent preferred).
local function bestOpenDirection(root, away)
    prepareRays()
    local best, bestScore = nil, -math.huge
    for i = 0, 15 do
        local angle = i * math.pi / 8
        local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
        local room = openness(root, direction, 10)
        if room >= 3 and groundAhead(root, direction) then
            local score = room + direction:Dot(away) * 2.5
            if zoneBlocked(root.Position + direction * 3.5) then score = score - 6 end
            if score > bestScore then best, bestScore = direction, score end
        end
    end
    return best
end

-- ===================== V7.8 HUMAN FOOTWORK =====================
-- Instead of "always run in a circle", a burst is 1-3 committed steps picked from a small
-- repertoire (sidestep / back-side / backstep / bait-in), expressed relative to the opponent
-- (so they bend into arcs as the opponent moves), with ramp-up/brake, smooth wander noise,
-- and a pause between bursts in which you control the character yourself.
local function rotateFlat(v, radians)
    local c, si = math.cos(radians), math.sin(radians)
    return Vector3.new(v.X * c - v.Z * si, 0, v.X * si + v.Z * c)
end

local function chooseFootworkStep(distance, previousName)
    local options
    if distance < 5 then
        options = {
            { name = "BACK-SIDE", r = 0.75, t = 0.65, w = 0.45 },
            { name = "SIDESTEP",  r = 0.20, t = 1.00, w = 0.30 },
            { name = "BACKSTEP",  r = 1.00, t = 0.00, w = 0.25 },
        }
    elseif distance < 9 then
        options = {
            { name = "SIDESTEP",  r = 0.15,  t = 1.00, w = 0.40 },
            { name = "BACK-SIDE", r = 0.60,  t = 0.80, w = 0.30 },
            { name = "BAIT-IN",   r = -0.45, t = 0.90, w = 0.18 },
            { name = "BACKSTEP",  r = 1.00,  t = 0.00, w = 0.12 },
        }
    else
        options = {
            { name = "SIDESTEP",  r = 0.10,  t = 1.00, w = 0.40 },
            { name = "BAIT-IN",   r = -0.55, t = 0.85, w = 0.35 },
            { name = "BACK-SIDE", r = 0.45,  t = 0.90, w = 0.25 },
        }
    end
    local total = 0
    for _, option in ipairs(options) do
        if option.name == previousName then option.w = option.w * 0.3 end -- avoid repeating
        total = total + option.w
    end
    local roll = math.random() * total
    for _, option in ipairs(options) do
        roll = roll - option.w
        if roll <= 0 then return option end
    end
    return options[#options]
end

-- Step toward the side the opponent is NOT pointing at (their flank / back).
local function chooseFlankSide(away, targetRoot)
    local look = unitOrZero(flat(targetRoot.CFrame.LookVector))
    local tangent = Vector3.new(-away.Z, 0, away.X)
    local d = tangent:Dot(look)
    local side
    if math.abs(d) < 0.15 then
        side = (math.random() < 0.5) and 1 or -1
    else
        side = (d > 0) and -1 or 1
    end
    if math.random() < CFG.FootworkRandomSide then side = -side end
    return side
end

local function footworkDirection(dodge, now, root, away, distance, threat)
    dodge.kiteDistance = distance
    local _, targetRoot = getCharacterParts(threat.targetCharacter)
    if not targetRoot then return Vector3.zero, "FOOTWORK" end

    local step = dodge.fwStep
    if not step or now >= step.endAt then
        local picked = chooseFootworkStep(distance, step and step.name)
        if CFG.ChargeDodge and distance < CFG.ChargeRange then
            -- Closing speed along the line between us (positive = running at us).
            local chargeSpeed = -flat(targetRoot.AssemblyLinearVelocity):Dot(away)
            if chargeSpeed >= CFG.ChargeSpeed then
                picked = { name = "OFF-LINE", r = 0.10, t = 1.0 } -- leave their line, don't back up on it
            end
        end
        local side
        if not step then
            side = chooseFlankSide(away, targetRoot)
        elseif math.random() < (lagScale() > 1.5 and 0.85 or 0.6) then
            side = step.side         -- keep going the same way, new step shape
        else
            side = -step.side        -- change direction (a feint), but not every step
        end
        -- Look at the room around us before committing: avoid walls, break out of corners.
        prepareRays()
        local sideTangent = Vector3.new(-away.Z, 0, away.X)
        local roomSide = openness(root, sideTangent * side, 8)
        local roomOther = openness(root, -sideTangent * side, 8)
        if roomSide < 4.0 and roomOther > roomSide + 2 then
            side = -side
            roomSide, roomOther = roomOther, roomSide
        end
        local roomBack = openness(root, away, 8)
        if picked.r > 0.3 and roomBack < 4.0 then
            picked = { name = "SIDESTEP", r = 0.0, t = 1.0 } -- no room behind: go sideways
        end
        if roomSide < 3.0 and roomBack < 3.5 then
            -- Cornered: cut diagonally past the opponent toward the most open side.
            picked = { name = "BREAKOUT", r = -0.35, t = 1.0 }
            logEvent(string.format("CORNERED (side %.1f, back %.1f): breakout", roomSide, roomBack))
        end
        local length = CFG.FootworkStepMin
            + math.random() * (CFG.FootworkStepMax - CFG.FootworkStepMin)
        if picked.name == "BACKSTEP" or picked.name == "BAIT-IN" then length = length * 0.75 end
        length = length * lagScale()
        step = {
            name = picked.name, r = picked.r, t = picked.t, side = side,
            startAt = now, endAt = now + length, seed = math.random() * 100,
        }
        dodge.fwStep = step
        dodge.fwRot = 0
        logEvent(string.format("step %s (%.1f studs)", step.name, distance))
        setStatus("STEP: " .. step.name, string.format("%.1f studs • side %d", distance, side))
    end

    -- Radial component, adjusted so we neither run away from a far player nor stay at contact.
    local radial = step.r
    if distance > 11 and radial > 0 then radial = radial * 0.35 end
    if distance < 4.2 and radial < 0.6 then radial = 0.9 end

    local tangent = Vector3.new(-away.Z, 0, away.X) * step.side
    local wanted = unitOrZero(away * radial + tangent * step.t)
    if wanted.Magnitude < 0.01 then wanted = away end

    -- Smooth wander so the path is never a perfect line or circle.
    local noise = math.clamp(math.noise(now * 2.2, step.seed, 0) * 2, -1, 1)
    wanted = rotateFlat(wanted, noise * CFG.FootworkWanderAngle)
    if dodge.fwEscape and now < dodge.fwEscape.untilAt then wanted = dodge.fwEscape.dir end

    -- Wall / edge check a few times per second; remember which rotation was safe.
    if now - (dodge.fwSafeAt or 0) >= CFG.StyleSafetyInterval then
        dodge.fwSafeAt = now
        local exclusions = buildCharacterExclusions(true)
        moveRayParams.FilterDescendantsInstances = exclusions
        groundRayParams.FilterDescendantsInstances = exclusions
        local foundRot = nil
        for pass = 1, 2 do
            for _, degrees in ipairs({ 0, 25, -25, 55, -55, 90, -90 }) do
                local candidate = rotateFlat(wanted, math.rad(degrees))
                if (pass == 2 or not zoneBlocked(root.Position + candidate * 3.5))
                    and directionClearance(root, candidate) then
                    foundRot = degrees
                    break
                end
            end
            if foundRot then break end
        end
        if not foundRot and distance < 5.5 then
            if directionClearance(root, away) then
                wanted = away
                foundRot = 0
            end
        end
        if not foundRot then
            -- Trapped or at an edge: give the joystick back and rest briefly.
            kitePauseUntil = now + 0.30
            return Vector3.zero, "FOOTWORK"
        end
        dodge.fwRot = foundRot
        if math.abs(foundRot) >= 55 then
            step.endAt = now -- this step is blocked; pick another next frame
            step.side = -step.side
        end
    end
    local direction = rotateFlat(wanted, math.rad(dodge.fwRot or 0))

    -- Steering inertia: turn in an arc instead of snapping between directions.
    local dt = math.clamp(now - (dodge.fwLastAt or (now - 0.016)), 0.001, 0.1)
    dodge.fwLastAt = now
    local previous = dodge.fwDir
    if previous then
        local alpha = math.clamp(1 - math.exp(-dt / math.max(CFG.FootworkTurnTau, 0.01)), 0.15, 0.9)
        local mixed = previous:Lerp(direction, alpha)
        if mixed.Magnitude > 0.05 then direction = mixed.Unit end
    end
    dodge.fwDir = direction

    -- Speed profile: quick start, brake at the end of each step.
    local age = now - step.startAt
    local remaining = step.endAt - now
    local speed = math.clamp(age / CFG.FootworkRampIn, CFG.FootworkStartSpeed, 1)
    if remaining < CFG.FootworkRampOut then
        local k = math.clamp(remaining / CFG.FootworkRampOut, 0, 1)
        speed = speed * (CFG.FootworkEndSpeed + (1 - CFG.FootworkEndSpeed) * k)
    end
    dodge.speedMul = math.clamp(speed, CFG.FootworkMinSpeed, 1)

    return direction, step.name
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

    if threat.targetCharacter then
        local _, currentTargetRoot = getCharacterParts(threat.targetCharacter)
        if currentTargetRoot then
            targetPosition = currentTargetRoot.Position + flat(currentTargetRoot.AssemblyLinearVelocity) * 0.08
            targetVelocity = flat(currentTargetRoot.AssemblyLinearVelocity)
        end
    elseif threat.projectile and threat.projectile.Parent then
        targetPosition = threat.projectile.Position + threat.projectile.AssemblyLinearVelocity * 0.06
        targetVelocity = flat(threat.projectile.AssemblyLinearVelocity)
    end

    local offset = flat(root.Position - targetPosition)
    local distance = offset.Magnitude
    local away = unitOrZero(offset)
    if away.Magnitude < 0.01 then
        away = unitOrZero(flat(dodge.direction or root.CFrame.RightVector))
    end
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end

    if dodge.kiting and threat.targetCharacter and not dodge.orbiting then
        return footworkDirection(dodge, now, root, away, distance, threat)
    end

    local tangent = Vector3.new(-away.Z, 0, away.X)
    -- Prefer the side that crosses the target's path rather than the side the target is already moving into.
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

    local wanted
    if dodge.kiting then
        -- Keep a readable orbit for a short beat, then make an irregular feint.
        -- The old side*flip calculation cancelled itself, so it almost never
        -- reversed the actual orbit. Store the chosen side and change it only
        -- occasionally; this avoids both endless running and rapid left/right jitter.
        if not dodge.kiteSide then
            dodge.kiteSide = dodge.patternSide or preferredSide or 1
            dodge.nextKiteFeintAt = now + (math.random(125, 185) / 100)
        elseif now >= (dodge.nextKiteFeintAt or math.huge) then
            dodge.kiteSide = -dodge.kiteSide
            dodge.nextKiteFeintAt = now + (math.random(135, 205) / 100)
        end
        local kiteSide = dodge.kiteSide
        local weave = math.sin(elapsed * 5.8 + (dodge.styleOffset or 1)) * 0.16
        -- Push out only when too close; at useful spacing, keep the path mostly tangent.
        local radialNudge
        if distance < 4.5 then
            radialNudge = 0.92 -- emergency outward component only when nearly touching
        elseif distance < 6.2 then
            radialNudge = 0.52
        elseif distance < 8.0 then
            radialNudge = 0.20
        else
            radialNudge = 0.0 -- outside the close band, travel around the target
        end
        wanted = unitOrZero(tangent * (kiteSide + weave) + away * radialNudge)
    else
        wanted = getStyleVector(baseIndex, elapsed, away, tangent, radial, side)
    end
    local blendStart = CFG.StyleCycleDuration - CFG.StyleBlendDuration
    if within >= blendStart and not dodge.kiting then
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
        local exclusions = buildCharacterExclusions(true)
        moveRayParams.FilterDescendantsInstances = exclusions
        groundRayParams.FilterDescendantsInstances = exclusions

        local candidates
        local styleThreats = collectNearbyThreats(threat, root)
        local secondaryThreats = {}

        if dodge.kiting and threat.targetCharacter then
            -- Do not let the current target's separation score veto orbiting; its
            -- proximity is handled explicitly below. Keep all OTHER players and
            -- moving hazards in the obstacle/safety score.
            for _, otherThreat in ipairs(styleThreats) do
                local sameTarget = threat.targetCharacter ~= nil
                    and otherThreat.targetCharacter == threat.targetCharacter
                local sameProjectile = threat.projectile ~= nil
                    and otherThreat.projectile == threat.projectile
                if not sameTarget and not sameProjectile and otherThreat ~= threat then
                    table.insert(secondaryThreats, otherThreat)
                end
            end
            candidates = {
                wanted,
                unitOrZero(tangent * kiteSide),
                unitOrZero(tangent * kiteSide + away * 0.22),
                unitOrZero(tangent * kiteSide - away * 0.20),
                unitOrZero(-tangent * kiteSide + away * radialNudge),
                unitOrZero(-tangent * kiteSide - away * 0.16),
            }
            -- A straight retreat is a valid emergency option only when contact is near.
            if distance < 5.5 then
                table.insert(candidates, away)
            end
            -- Prevent the old retreat-biased seed direction from winning by inertia.
            if not dodge.kiteStyleSeeded then
                dodge.smoothedStyleDirection = wanted
                dodge.kiteStyleSeeded = true
            end
        else
            candidates = {
                wanted,
                away,
                unitOrZero(away + tangent * side * 0.8),
                unitOrZero(away - tangent * side * 0.8),
                tangent * side,
                -tangent * side,
                dodge.direction,
            }
        end

        local function styleScore(clearDirection, clearance)
            if dodge.kiting and threat.targetCharacter then
                -- Split-space steering: tangent motion is the default, radial motion
                -- is used to break contact only when close. Use a short prediction to
                -- reject routes that actually cut into the target, rather than reward
                -- every direction that increases distance indefinitely.
                local secondarySafety = scoreDirection(
                    root, dodge.humanoid, clearDirection, clearance, secondaryThreats, nil
                )
                local tangentAlignment = clearDirection:Dot(tangent * kiteSide)
                local radialAlignment = clearDirection:Dot(away)
                local speed = math.max(dodge.humanoid.WalkSpeed, 9)
                local closest = math.huge
                for _, sampleTime in ipairs({ 0.12, 0.24, 0.36 }) do
                    local myFuture = root.Position
                        + flat(root.AssemblyLinearVelocity) * (sampleTime * 0.20)
                        + clearDirection * (speed * sampleTime * CFG.PlayerMotionFactor)
                    local theirFuture = predictedThreatPosition(threat, sampleTime)
                    local separation = flat(myFuture - theirFuture).Magnitude
                    if separation < closest then closest = separation end
                end
                local contactPenalty = math.max(0, 5.4 - closest)
                contactPenalty = contactPenalty * contactPenalty * 4.0

                local radialScore
                if distance < 5.8 then
                    radialScore = radialAlignment * 4.8
                elseif distance < 7.8 then
                    radialScore = radialAlignment * 0.8
                        - math.max(0, radialAlignment) * 1.5
                else
                    radialScore = -math.max(0, radialAlignment) * 4.0
                end

                return secondarySafety * 0.72
                    + tangentAlignment * 7.0
                    + radialScore
                    - contactPenalty
                    + math.min(clearance or 0, CFG.ProbeDistance) * 0.06
            end

            local safety = scoreDirection(
                root, dodge.humanoid, clearDirection, clearance, styleThreats, threat
            )
            return safety
                + clearDirection:Dot(wanted) * 0.35
                + math.min(clearance or 0, CFG.ProbeDistance) * 0.01
        end
        local best = searchBestDirection(
            root, candidates,
            function(unit) return styleScore(unit, CFG.ProbeDistance) end,
            styleScore
        )
        if best then
            local previous = dodge.smoothedStyleDirection or dodge.direction or best
            local dt = math.max(0.001, now - (dodge.lastStyleUpdateAt or now))
            local alpha = 1 - math.exp(-dt / CFG.SteeringSmoothingSeconds)
            local smooth = previous:Lerp(best, math.clamp(alpha, 0.12, 0.85))
            local smoothedUnit = smooth.Magnitude > 0.02 and smooth.Unit or best
            -- Interpolation itself can cut a corner, so validate the final vector too.
            local safeSmoothed = select(1, directionClearance(root, smoothedUnit))
            dodge.smoothedStyleDirection = safeSmoothed or best
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

local function requestDodge(threat, forceUrgent)
    if shuttingDown or not CFG.Enabled or localRoleBlocksAutomation() then return false end

    local now = os.clock()
    local urgent = forceUrgent or (threat and (threat.time or 1) < 0.16)

    if activeDodge and now < activeDodge.finishAt then
        -- If a normal short dodge is already underway when the target gets
        -- critically close, promote it into the controlled orbit immediately.
        if threat and threat.targetCharacter and activeDodge.root and activeDodge.root.Parent then
            local _, closeRoot = getCharacterParts(threat.targetCharacter)
            if closeRoot then
                local closeOffset = activeDodge.root.Position - closeRoot.Position
                local closeDistance = closeOffset.Magnitude
                if closeDistance <= CFG.EmergencyTakeoverRange
                    and not threat.kiting
                    and now >= orbitBlockedUntil
                    and math.abs(closeOffset.Y) <= CFG.CriticalVerticalSeparation then
                    local targetChanged = activeDodge.threat
                        and activeDodge.threat.targetCharacter ~= threat.targetCharacter
                    if not activeDodge.orbiting or targetChanged then
                        activeDodge.orbiting = true
                        activeDodge.orbitSide = preferredSide
                        activeDodge.orbitStartedAt = now
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
            activeDodge.kiting = false
            activeDodge.speedMul, activeDodge.fwStep, activeDodge.fwDir = nil, nil, nil
            activeDodge.threat = threat
            activeDodge.finishAt = math.max(activeDodge.finishAt, now + 0.24)
            activeDodge.retargeted = false
            activeDodge.retargetNow = true
            return true
        end
        -- Continuous kite pulses are refreshed while the target remains nearby.
        if activeDodge.kiting and threat and threat.kiting then
            activeDodge.threat = threat
            return true
        end
        -- If a more urgent second threat appears, retarget the existing motion.
        local activeEta = activeDodge.threat and activeDodge.threat.time or 1
        local newEta = threat and threat.time or 1
        if urgent and newEta + 0.04 < activeEta then
            activeDodge.threat = threat
            activeDodge.retargetNow = true
        end
        if threat and not threat.kiting then
            logEvent("cue IGNORED: already moving (" .. tostring(threat.kind) .. ")")
        end
        return false
    end

    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root or localCharacterBlocked(character, humanoid) then
        logEvent("REFUSED dodge: script hands off (" .. describeBlock(character, humanoid) .. ")")
        return false
    end

    local sourceCharacter = threat and threat.targetCharacter
    local veryClose = threat and threat.kind == "CRITICAL PROXIMITY" or false
    if sourceCharacter then
        local _, sourceRoot = getCharacterParts(sourceCharacter)
        if not sourceRoot then return false end

        local offset = root.Position - sourceRoot.Position
        local distance = offset.Magnitude
        local sameLevel = math.abs(offset.Y) <= CFG.CriticalVerticalSeparation
        veryClose = veryClose or (distance <= CFG.EmergencyTakeoverRange and sameLevel
            and not (threat and threat.kiting))
        if veryClose and now < orbitBlockedUntil then
            -- Orbit cooldown: the player keeps control. A predicted hit may still
            -- trigger an ordinary short dodge, but not another full takeover.
            if threat and threat.kind == "CRITICAL PROXIMITY" then return false end
            veryClose = false
        end
        if math.abs(offset.Y) > CFG.MaxThreatVerticalSeparation then return false end
        if CFG.RequireLineOfSight and not hasLineOfSight(root, sourceRoot, sourceCharacter) then
            if not (threat and threat.kiting) then logEvent("cue IGNORED: no line of sight to attacker") end
            return false
        end
        local maxThreatRange = (threat and threat.kiting)
            and (CFG.KiteReleaseRange + 1)
            or (CFG.AnimationRange + 3)
        if distance > maxThreatRange then
            if not (threat and threat.kiting) then
                logEvent(string.format("cue IGNORED: attacker too far (%.1f studs)", distance))
            end
            return false
        end

        if not (threat and threat.kiting) then
            local previous = lastByTarget[sourceCharacter] or -math.huge
            if now - previous < CFG.TargetCooldown and not urgent then return false end
        end
    end

    -- Point-blank takeovers bypass the regular cooldown; ordinary player and
    -- projectile dodges remain rate-limited to avoid repetitive movement bursts.
    if not veryClose and now - lastDodge < CFG.MinimumDodgeInterval then
        if threat and not threat.kiting then logEvent("cue IGNORED: dodge interval cooldown") end
        return false
    end

    local direction, score, clearance = chooseDodgeDirection(root, humanoid, threat)
    if not direction then
        setStatus("NO CLEAR PATH", "No safe route; normal control kept")
        logEvent("REFUSED dodge: no safe direction (walls/edges everywhere)")
        return false
    end

    -- Only start the target cooldown after we have a usable route. A failed plan
    -- must not suppress the next cue that might have a clear escape path.
    if sourceCharacter and not (threat and threat.kiting) then
        lastByTarget[sourceCharacter] = now
    end

    lastDodge = now
    local isKiting = threat and threat.kiting == true
    local estimatedEta = math.clamp(threat and threat.time or 0.25, 0, 0.40)
    local duration = veryClose
        and CFG.CloseOrbitTimeout
        or (isKiting and (CFG.FootworkBurstMin + math.random() * (CFG.FootworkBurstMax - CFG.FootworkBurstMin))
        or math.clamp(0.22 + estimatedEta * 0.35, 0.22, CFG.DodgeDuration) * lagScale())

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
        patternStartAt = now,
        styleOffset = math.random(1, #STYLE_NAMES),
        -- chooseDodgeDirection flips the global preference after scoring; for a
        -- kite pulse, keep the side that the chosen opening direction was scored for.
        patternSide = isKiting and -preferredSide or preferredSide,
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
    lastDodgeInfo = { t = now, key = threat and threat.key }
    do
        local _, srcRoot = getCharacterParts(sourceCharacter)
        local dist = srcRoot and (srcRoot.Position - root.Position).Magnitude or -1
        logEvent(string.format("DODGE start: %s | %s | eta %.2f | enemy %.1f studs | clear %.1f",
            tostring(threat and threat.kind or "?"), directionName,
            (threat and threat.time) or -1, dist, clearance))
    end
    return true
end

-- Hold space when a target enters the pressure radius. Start only when it is
-- approaching/facing us (or critically close), then continue until separation is restored.
local function findKiteThreat(myRoot)
    if not CFG.KiteEnabled then
        kiteFocusCharacter = nil
        return nil
    end

    -- Keep the current target to prevent focus flicker, but still scan for a
    -- much closer attacker. The old early return locked onto the first target
    -- until it left the full release radius, even when another player got close.
    local focusCharacter = kiteFocusCharacter
    local focusPlayer = focusCharacter and Players:GetPlayerFromCharacter(focusCharacter) or nil
    local _, focusRoot = getCharacterParts(focusCharacter)
    local bestCharacter, bestRoot, bestDistance = nil, nil, math.huge

    if focusPlayer and isThreatPlayer(focusPlayer) and focusRoot then
        local offset = focusRoot.Position - myRoot.Position
        local distance = offset.Magnitude
        local visible = not CFG.RequireLineOfSight or hasLineOfSight(myRoot, focusRoot, focusCharacter)
        if math.abs(offset.Y) <= CFG.MaxThreatVerticalSeparation
            and distance <= CFG.KiteReleaseRange and visible then
            bestCharacter, bestRoot, bestDistance = focusCharacter, focusRoot, distance
        end
    end
    local hadValidFocus = bestCharacter ~= nil

    for _, player in ipairs(Players:GetPlayers()) do
        if isThreatPlayer(player) and player.Character then
            local targetCharacter = player.Character
            local _, targetRoot = getCharacterParts(targetCharacter)
            if targetRoot then
                local offset = targetRoot.Position - myRoot.Position
                local distance = offset.Magnitude
                if math.abs(offset.Y) <= CFG.MaxThreatVerticalSeparation
                    and distance <= CFG.KiteStartRange then
                    local closing = closingSpeed(myRoot, targetRoot)
                    local facing = facingUs(myRoot, targetRoot)
                    local eligible = distance <= CFG.KiteHardRange
                        or closing >= CFG.KiteClosingThreshold
                        or (facing and distance <= CFG.KiteFacingRange)
                    local visible = eligible and (not CFG.RequireLineOfSight
                        or hasLineOfSight(myRoot, targetRoot, targetCharacter))
                    if eligible and visible then
                        local isCurrent = targetCharacter == bestCharacter
                        local materiallyCloser = distance < bestDistance - 1.8
                        local immediateDanger = distance <= CFG.EmergencyTakeoverRange
                            and distance < bestDistance - 0.75
                        local shouldSelect = not bestCharacter or isCurrent
                            or (not hadValidFocus and distance < bestDistance)
                            or (hadValidFocus and (materiallyCloser or immediateDanger))
                        if shouldSelect then
                            bestCharacter, bestRoot, bestDistance = targetCharacter, targetRoot, distance
                        end
                    end
                end
            end
        end
    end

    if not bestCharacter then
        kiteFocusCharacter = nil
        return nil
    end

    kiteFocusCharacter = bestCharacter
    return {
        time = CFG.KitePulseDuration,
        position = bestRoot.Position,
        velocity = bestRoot.AssemblyLinearVelocity,
        kind = "SPACE CONTROL",
        targetCharacter = bestCharacter,
        sourceRoot = bestRoot,
        kiting = true,
    }
end

-- ===================== V7.8 ATTACK TIMING LEARNING =====================
local function trackKey(track)
    local key = nil
    pcall(function() key = track.Animation and track.Animation.AnimationId end)
    if type(key) ~= "string" or key == "" then
        key = tostring(track.Name or "?")
    end
    return key
end

-- When we take damage, attribute it to the most recent attack-like animation that started
-- 0.04-1.4 s earlier, and remember how long that animation takes to hurt.
local function learnFromHit(now)
    if not CFG.LearnAttackTiming then return end
    local best = nil
    for i = #pendingAttacks, 1, -1 do
        local entry = pendingAttacks[i]
        local age = now - entry.start
        if age > 1.4 then
            table.remove(pendingAttacks, i)
        elseif not entry.matched and age >= 0.04 and not best then
            best = entry
        end
    end
    if not best then return end
    best.matched = true
    local delay = math.clamp(now - best.start, 0.05, 1.0)
    local stat = attackStats[best.key]
    if stat then
        if stat.n >= 2 and math.abs(delay - stat.delay) > 0.35 then return end -- outlier
        stat.delay = stat.delay * 0.55 + delay * 0.45
        stat.n = stat.n + 1
    else
        attackStats[best.key] = { delay = delay, n = 1 }
    end
    local learned = attackStats[best.key]
    if learned and learned.n >= 2 and not learnedAttack[best.key] then
        learnedAttack[best.key] = true -- proven to hurt: always treated as an attack from now on
        logEvent("ADAPT: animation " .. (tostring(best.key):match("%d+$") or tostring(best.key)) .. " marked as an attack")
    end
    if learned and lastDodgeInfo and lastDodgeInfo.key == best.key and now - lastDodgeInfo.t < 1.2 then
        local lead = now - lastDodgeInfo.t
        if lead < 0.14 then
            learned.bias = math.min(0.2, (learned.bias or 0) + 0.03)
            logEvent(string.format("ADAPT: dodge was too LATE (%.2fs before the hit): start earlier, bias %.2f", lead, learned.bias))
        elseif lead > 0.55 then
            learned.bias = math.max(-0.1, (learned.bias or 0) - 0.03)
            logEvent(string.format("ADAPT: dodge was too EARLY (%.2fs before the hit): start later, bias %.2f", lead, learned.bias))
        end
    end
    if CFG.Debug then
        print(string.format("[VD Auto Mans] learned hit delay %.2fs (avg %.2f, n=%d)",
            delay, attackStats[best.key].delay, attackStats[best.key].n))
    end
end

-- Tune global settings from what the last hit looked like.
local function adaptSet(key, value, reason)
    if not CFG.Adaptive or CFG[key] == nil then return end
    CFG[key] = value
    adaptStore[key] = value
    logEvent(string.format("ADAPT: %s -> %.2f (%s)", key, value, reason))
end

local function adaptFromHit(now)
    if not CFG.Adaptive then return end
    local sawCue, sawStuck, sawIgnore = false, false, false
    for _, entry in ipairs(eventLog) do
        local age = entry.t - now
        if age > -1.5 then
            if entry.text:find("^CUE") or entry.text:find("^DODGE") then sawCue = true end
            if entry.text:find("^STUCK") or entry.text:find("^CORNERED") then sawStuck = true end
            if entry.text:find("^anim IGNORED") or entry.text:find("^cue IGNORED") then sawIgnore = true end
        end
    end
    local _, root = getCharacterParts(LocalPlayer.Character)
    local nearest = math.huge
    if root then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                local _, enemyRoot = getCharacterParts(player.Character)
                if enemyRoot then nearest = math.min(nearest, (enemyRoot.Position - root.Position).Magnitude) end
            end
        end
    end
    if not sawCue and nearest <= CFG.AnimationRange + 12 then
        adaptSet("AnimationRange", math.min(34, CFG.AnimationRange + 2), "hit with no warning")
        adaptSet("FacingThreatRange", math.min(13, CFG.FacingThreatRange + 0.6), "hit with no warning")
        adaptSet("CriticalAnimationRange", math.min(8, CFG.CriticalAnimationRange + 0.3), "hit with no warning")
    end
    if sawIgnore then
        adaptSet("MinimumClosingSpeed", math.max(0.2, CFG.MinimumClosingSpeed - 0.15), "ignored a cue that then hit")
    end
    if sawStuck then
        adaptSet("WallLookahead", math.min(6.5, CFG.WallLookahead + 0.5), "stuck before a hit")
        adaptSet("StuckCheckEvery", math.max(0.09, CFG.StuckCheckEvery - 0.01), "stuck before a hit")
    end
    if activeDodge and not activeDodge.kiting and not activeDodge.orbiting then
        adaptSet("DodgeDuration", math.min(0.70, CFG.DodgeDuration + 0.03), "hit during a dodge: longer evades")
    end
end

-- V8.0: hits that land close together form ONE burst: they are collected and reported once
-- (a single console print and a single clipboard write) instead of one report per hit.
local HitBatcher = {
    batch = nil, scheduled = false, lastHitAt = -math.huge,
    hits = 0, bursts = 0, damage = 0,                  -- this session
    copyButton = nil, copyConns = {}, copyFlashUntil = 0,
    copyBase = Color3.fromRGB(34, 56, 96),
}

function HitBatcher.build(amount, health, index)
    local now = os.clock()
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    local okPing, ping = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    local dodgeState = "none"
    if activeDodge then
        dodgeState = activeDodge.orbiting and "ORBIT" or (activeDodge.kiting and "KITE" or "DODGE")
    end
    add(string.format("===== HIT #%d -%.0f hp (left %.0f) | script=%s | state=%s | ping=%.0fms (model %.0f, jitter %.0f) | hop=%s =====",
        index or 1, amount, health, CFG.Enabled and "ON" or "OFF", dodgeState, okPing and ping * 1000 or -1,
        pingEma * 1000, pingJitter * 1000, tostring(hopAvailable)))
    if humanoid and localCharacterBlocked(character, humanoid) then
        add("  script was HANDS-OFF: " .. describeBlock(character, humanoid))
    end

    -- Nearby players and what they are playing right now.
    if root then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                local _, enemyRoot = getCharacterParts(player.Character)
                if enemyRoot then
                    local distance = (enemyRoot.Position - root.Position).Magnitude
                    if distance <= 22 then
                        add(string.format("  enemy %s: %.1f studs, closing %.1f, facing=%s, dY=%.1f, LOS=%s",
                            player.Name, distance, closingSpeed(root, enemyRoot), tostring(facingUs(root, enemyRoot)),
                            enemyRoot.Position.Y - root.Position.Y,
                            tostring(hasLineOfSight(root, enemyRoot, player.Character))))
                        pcall(function()
                            local enemyHumanoid = player.Character:FindFirstChildOfClass("Humanoid")
                            local animator = enemyHumanoid and enemyHumanoid:FindFirstChildOfClass("Animator")
                            if animator then
                                for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                                    if not track.Looped then
                                        add(string.format("    playing %s (%s) t=%.2f/%.2f looped=%s",
                                            tostring(trackKey(track)):match("%d+$") or tostring(trackKey(track)),
                                            tostring(track.Name), track.TimePosition, track.Length, tostring(track.Looped)))
                                    end
                                end
                            end
                        end)
                    end
                end
            end
        end
    end

    -- What the script did in the last 2 seconds.
    local sawCue = false
    for _, entry in ipairs(eventLog) do
        local age = entry.t - now
        if age > -2.0 then
            add(string.format("  %+.2fs  %s", age, entry.text))
            if age > -1.5 and (entry.text:find("^CUE") or entry.text:find("^DODGE")) then sawCue = true end
        end
    end
    if not sawCue then
        add("  !! no CUE and no DODGE in the 1.5 s before this hit: the script did not see it coming")
        add("     (attack from outside range / no line of sight / animation not recognised / damage from a non-player source)")
    end

    return lines
end

function HitBatcher.flush()
    local batch = HitBatcher.batch
    HitBatcher.batch = nil
    if not batch then return end
    local lines = {}
    if batch.count > 1 then
        lines[#lines + 1] = string.format(
            "===== %d HITS in %.1fs | -%.0f hp in total (left %.0f) =====",
            batch.count, batch.lastAt - batch.startedAt, batch.total, batch.lastHealth)
    end
    for _, section in ipairs(batch.sections) do
        for _, line in ipairs(section) do lines[#lines + 1] = line end
    end
    lines[#lines + 1] = "" -- blank line between bursts
    print(table.concat(lines, "\n"))
    for _, line in ipairs(lines) do fullLog[#fullLog + 1] = line end
    while #fullLog > 400 do table.remove(fullLog, 1) end
    env.VD_AUTO_MANS_LOG = function() return table.concat(fullLog, "\n") end
end

-- Wakes up after the quiet window; flushes when no new hit arrived (or the burst got too long).
function HitBatcher.check()
    HitBatcher.scheduled = false
    local batch = HitBatcher.batch
    if not batch then return end
    local now = os.clock()
    local wait = math.min(batch.lastAt + CFG.HitBatchQuiet - now, batch.startedAt + CFG.HitBatchMax - now)
    if wait <= 0 then
        HitBatcher.flush()
    else
        HitBatcher.scheduled = true
        task.delay(math.max(wait, 0.05), function() pcall(HitBatcher.check) end)
    end
end

-- V8.1: everything the script knows, as one text (V8.2: aligned columns): session totals,
-- settings tuned by hits, learned attack timings, every hit report and the latest events.
function HitBatcher.report()
    local now = os.clock()
    local out = {}
    local function add(text) out[#out + 1] = text end
    local function section(title)
        add("")
        add(string.format("-- %s %s", title, string.rep("-", math.max(3, 58 - #title))))
    end
    local okPing, ping = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)

    add(string.rep("=", 62))
    add(" VD AUTO MANS V8.2  |  FULL REPORT")
    add(string.rep("=", 62))
    add(string.format(" place    : %s", tostring(game.PlaceId)))
    add(string.format(" script   : %s     threat mode: %s", CFG.Enabled and "ON" or "OFF", tostring(CFG.ThreatMode)))
    add(string.format(" ping     : %.0f ms  (model %.0f, jitter %.0f)",
        okPing and ping * 1000 or -1, pingEma * 1000, pingJitter * 1000))
    add(string.format(" session  : %d hits in %d bursts, %.0f hp lost",
        HitBatcher.hits, HitBatcher.bursts, HitBatcher.damage))

    section("SETTINGS TUNED BY HITS")
    local keys = {}
    for key, value in pairs(adaptStore) do
        if type(value) == "number" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    if #keys == 0 then add("  (nothing tuned yet)") end
    for _, key in ipairs(keys) do
        add(string.format("  %-24s %8.2f", key, adaptStore[key]))
    end

    section("LEARNED ATTACK ANIMATIONS")
    local ids = {}
    for key, stat in pairs(attackStats) do
        if type(stat) == "table" then ids[#ids + 1] = key end
    end
    table.sort(ids, function(a, b) return (attackStats[a].n or 0) > (attackStats[b].n or 0) end)
    if #ids == 0 then
        add("  (no attack timing learned yet)")
    else
        add(string.format("  %-14s %8s %4s %7s  %s", "animation id", "delay", "n", "bias", "status"))
    end
    for _, key in ipairs(ids) do
        local stat = attackStats[key]
        add(string.format("  %-14s %7.2fs %4d %+7.2f  %s",
            tostring(key):match("%d+$") or tostring(key), stat.delay or 0, stat.n or 0, stat.bias or 0,
            learnedAttack[key] and "ATTACK" or "candidate"))
    end

    section("HITS (oldest first)")
    if #fullLog == 0 then add("  (no hits recorded yet)") end
    for _, line in ipairs(fullLog) do add(line) end

    section("LATEST SCRIPT EVENTS (seconds before now)")
    if #eventLog == 0 then add("  (nothing yet)") end
    for _, entry in ipairs(eventLog) do
        add(string.format("  %+7.1fs  %s", entry.t - now, entry.text))
    end
    add("")
    add(string.rep("=", 62))
    return table.concat(out, "\n")
end

-- Closes a hit burst that is still being collected, then puts the full report on the clipboard.
-- Returns copied (boolean) and the text, so the caller can show it when there is no clipboard.
function HitBatcher.copyAll()
    pcall(HitBatcher.flush)
    local text = HitBatcher.report()
    local copied = false
    pcall(function()
        local write = setclipboard or toclipboard or set_clipboard or (Clipboard and Clipboard.set)
        if write then
            write(text)
            copied = true
        end
    end)
    return copied, text
end
env.VD_AUTO_MANS_COPY = function() return HitBatcher.copyAll() end -- console: VD_AUTO_MANS_COPY()

local function reportHit(amount, health)
    if not CFG.HitReport then return end
    local now = os.clock()
    local batch = HitBatcher.batch
    if not batch then
        batch = { startedAt = now, lastAt = now, count = 0, total = 0, lastHealth = health, sections = {} }
        HitBatcher.batch = batch
    end
    batch.count = batch.count + 1
    batch.total = batch.total + amount
    batch.lastAt = now
    batch.lastHealth = health
    if batch.count <= CFG.HitBatchFullDetail then
        batch.sections[#batch.sections + 1] = HitBatcher.build(amount, health, batch.count)
    else
        local state = "none"
        if activeDodge then
            state = activeDodge.orbiting and "ORBIT" or (activeDodge.kiting and "KITE" or "DODGE")
        end
        batch.sections[#batch.sections + 1] = {
            string.format("  hit #%d  +%.2fs  -%.0f hp (left %.0f)  state=%s",
                batch.count, now - batch.startedAt, amount, health, state),
        }
    end
    if not HitBatcher.scheduled then
        HitBatcher.scheduled = true
        task.delay(CFG.HitBatchQuiet, function() pcall(HitBatcher.check) end)
    end
end

local function hookHealth(character)
    disconnect(healthConn)
    healthConn = nil
    if not character then return end
    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 5)
        if not humanoid or shuttingDown or LocalPlayer.Character ~= character then return end
        lastHealth = humanoid.Health
        disconnect(healthConn)
        healthConn = humanoid.HealthChanged:Connect(guarded("health", function(health)
            local previous = lastHealth or health
            lastHealth = health
            if health < previous - 0.5 then
                local hitAt = os.clock()
                -- Hits that land together are ONE burst: tune the settings once, not once per hit.
                local newBurst = hitAt - HitBatcher.lastHitAt > CFG.HitBatchQuiet
                HitBatcher.lastHitAt = hitAt
                HitBatcher.hits = HitBatcher.hits + 1
                HitBatcher.damage = HitBatcher.damage + (previous - health)
                if newBurst then HitBatcher.bursts = HitBatcher.bursts + 1 end
                learnFromHit(hitAt)
                if newBurst then adaptFromHit(hitAt) end
                reportHit(previous - health, health)
                if HitBatcher.refreshCopyLabel then HitBatcher.refreshCopyLabel() end
            end
        end))
    end)
end

local function onThreatAnimation(player, character, track)
    if shuttingDown or not CFG.Enabled or not CFG.AnimationTrigger then return end
    if player.Character ~= character or not isThreatPlayer(player) then return end

    local myCharacter = LocalPlayer.Character
    local _, myRoot = getCharacterParts(myCharacter)
    local _, targetRoot = getCharacterParts(character)
    if not myRoot or not targetRoot or localCharacterBlocked(myCharacter, myCharacter:FindFirstChildOfClass("Humanoid")) then
        return
    end

    local animationOffset = myRoot.Position - targetRoot.Position
    local distance = animationOffset.Magnitude
    if distance > CFG.AnimationRange then return end
    if math.abs(animationOffset.Y) > CFG.MaxThreatVerticalSeparation then return end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, targetRoot, character) then
        return
    end

    local closing = closingSpeed(myRoot, targetRoot)
    local facing = facingUs(myRoot, targetRoot)
    local key = trackKey(track)
    local attackHint = attackLike(track) or learnedAttack[key] == true
    local looped = false
    pcall(function() looped = track.Looped end)
    if CFG.LearnAttackTiming and not looped and distance <= 14 then
        pendingAttacks[#pendingAttacks + 1] = { key = key, start = os.clock() }
        if #pendingAttacks > 24 then table.remove(pendingAttacks, 1) end
    end

    -- In KILLERS_ONLY mode, retain the original emergency close cue. In ANY_PLAYER
    -- mode, a close idle/emote is not enough: require an attack cue, approach, or facing.
    local withinCriticalRange = distance <= CFG.CriticalAnimationRange
    -- Some game animations have opaque/numbered names, so attackLike() cannot
    -- identify them. A nearby animation start from someone facing us is still
    -- a useful early warning even when the target is momentarily stationary.
    local facingThreatCue = facing and distance <= CFG.FacingThreatRange
    local critical = withinCriticalRange and (
        CFG.ThreatMode ~= "ANY_PLAYER"
        or attackHint
        or closing >= CFG.MinimumClosingSpeed
        or (facing and distance <= CFG.CriticalFacingRange)
    )

    if attackHint and not critical then
        if distance > CFG.AttackHintMaxRange then return end
        if distance > CFG.CloseFacingRange and not facing and closing < CFG.MinimumClosingSpeed then return end
    end

    local smartThreat = closing >= CFG.MinimumClosingSpeed
        or (facing and distance <= CFG.CloseFacingRange)
        or attackHint

    if not critical and not smartThreat then
        if distance <= 14 then
            logEvent(string.format("anim IGNORED %s: %.1f studs, closing %.1f, facing=%s, attackName=%s",
                tostring(key):match("%d+$") or tostring(key), distance, closing, tostring(facing), tostring(attackHint)))
        end
        return
    end

    local eta = math.clamp((distance - 2.0) / math.max(closing, 0.1), 0, 0.45)
    -- Ordinary movement cues need a near-term ETA; attack-name and facing cues get
    -- a short response window because attacks may start without closing speed.
    if not critical and not attackHint and not facingThreatCue
        and eta > 0.30 + latencyLead() then
        logEvent(string.format("anim IGNORED %s: eta %.2f too late-to-matter/too early", tostring(key):match("%d+$") or tostring(key), eta))
        return
    end
    local attackLead = 0.24 + latencyLead()
    local threat = {
        time = critical and math.min(eta, 0.12)
            or ((attackHint or facingThreatCue) and math.min(eta, attackLead) or eta),
        position = targetRoot.Position,
        velocity = targetRoot.AssemblyLinearVelocity,
        kind = attackHint and "attack animation"
            or (facingThreatCue and "facing animation cue" or "player animation"),
        targetCharacter = character,
        sourceRoot = targetRoot,
        attackDir = flat(targetRoot.CFrame.LookVector),
        key = key,
    }
    local urgentCue = critical or attackHint or facingThreatCue
    do
        local learned = CFG.LearnAttackTiming and attackStats[key] or nil
        logEvent(string.format("CUE %s: %.1f studs, closing %.1f, facing=%s, attackName=%s, critical=%s%s",
            tostring(key):match("%d+$") or tostring(key), distance, closing, tostring(facing),
            tostring(attackHint), tostring(critical),
            learned and string.format(", learned delay %.2f (n=%d)", learned.delay, learned.n) or ", no timing learned yet"))
    end

    -- Learned timing: wait so that the evade step lands just before the hit, and skip the
    -- dodge entirely if the attacker cancels the animation (feint).
    local stat = CFG.LearnAttackTiming and attackStats[key] or nil
    if stat and urgentCue then
        local wait = stat.delay - (CFG.EvadeStepTime * lagScale() + latencyLead() + (stat.bias or 0))
        if wait > 0.03 then
            task.delay(math.min(wait, 0.8), function()
                if shuttingDown or not CFG.Enabled or player.Character ~= character then return end
                local stillPlaying = true
                pcall(function() stillPlaying = track.IsPlaying end)
                if not stillPlaying then return end
                local _, myRoot2 = getCharacterParts(LocalPlayer.Character)
                local _, enemyRoot2 = getCharacterParts(character)
                if not myRoot2 or not enemyRoot2 then return end
                if (myRoot2.Position - enemyRoot2.Position).Magnitude > CFG.AnimationRange + 4 then return end
                requestDodge({
                    time = 0.10,
                    position = enemyRoot2.Position,
                    velocity = enemyRoot2.AssemblyLinearVelocity,
                    kind = "learned attack timing",
                    targetCharacter = character,
                    sourceRoot = enemyRoot2,
                    attackDir = flat(enemyRoot2.CFrame.LookVector),
                    key = key,
                }, true)
            end)
            return
        end
    end
    requestDodge(threat, urgentCue)
end

local guardedAnimation = guarded("animation", onThreatAnimation)

local function watchCharacter(player, character)
    if not character or player == LocalPlayer then return end

    if not isThreatPlayer(player) then
        disconnect(characterConnections[character])
        characterConnections[character] = nil
        watchedCharacters[character] = nil
        characterTokens[character] = (characterTokens[character] or 0) + 1
        return
    end

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
            if characterTokens[character] == token then
                watchedCharacters[character] = nil
                -- Some characters add Animator late or replace it after spawn. Retry
                -- rather than permanently losing animation cues for this character.
                task.delay(1, function()
                    if not shuttingDown and player.Character == character
                        and characterTokens[character] == token then
                        watchCharacter(player, character)
                    end
                end)
            end
            return
        end
        if shuttingDown or characterTokens[character] ~= token
            or player.Character ~= character or not isThreatPlayer(player) then
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
        lastByTarget[character] = nil
        if activeDodge and activeDodge.threat and activeDodge.threat.targetCharacter == character then
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
    table.insert(conns, player:GetAttributeChangedSignal("IsKiller"):Connect(function()
        refreshPlayer(player)
    end))
    table.insert(conns, player:GetAttributeChangedSignal("Hunter"):Connect(function()
        refreshPlayer(player)
    end))
    table.insert(conns, player:GetAttributeChangedSignal("IsHunter"):Connect(function()
        refreshPlayer(player)
    end))
    refreshPlayer(player)
end

-- Panel look ---------------------------------------------------------------
local PANEL_WIDTH, PANEL_HEIGHT, PANEL_MARGIN = 116, 38, 6
local DEFAULT_PANEL_POSITION = UDim2.new(1, -12, 0.70, 0)
local FILL_ON = Color3.fromRGB(28, 131, 84)
local FILL_OFF = Color3.fromRGB(113, 53, 60)
local STROKE_OFF = Color3.fromRGB(70, 148, 208)
local INDICATOR_COLORS = {
    off = Color3.fromRGB(176, 178, 190),
    idle = Color3.fromRGB(86, 232, 142),
    dodge = Color3.fromRGB(255, 190, 64),
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
            state = dodge.orbiting and "orbit" or "dodge"
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

    local old = playerGui:FindFirstChild("VD_AutoMansV8_2")
    if old then old:Destroy() end

    gui = Instance.new("ScreenGui")
    gui.Name = "VD_AutoMansV8_2"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 9999
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = playerGui

    -- Compact single-control pill; the same surface supports tap and one-finger drag.
    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.AnchorPoint = Vector2.new(1, 0.5)
    frame.Position = savedPanelPosition or DEFAULT_PANEL_POSITION
    frame.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
    frame.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
    frame.BackgroundTransparency = 0.04
    frame.BorderSizePixel = 0
    frame.Active = false
    frame.ZIndex = 100
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
    toggleButton.TextSize = 13
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
    buttonPadding.PaddingLeft = UDim.new(0, 16)
    buttonPadding.Parent = toggleButton

    -- The dot lives on the frame (not the padded button) and never eats touches.
    indicatorDot = Instance.new("Frame")
    indicatorDot.Name = "StateDot"
    indicatorDot.AnchorPoint = Vector2.new(0, 0.5)
    indicatorDot.Position = UDim2.new(0, 15, 0.5, 0)
    indicatorDot.Size = UDim2.fromOffset(9, 9)
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

    -- The pill may leave the screen, but CFG.PanelPeekPx pixels always stay visible so it can be
    -- dragged back. ScreenGui.AbsoluteSize already accounts for the top bar / notch insets.
    local function clampPosition(position)
        local view = gui and gui.AbsoluteSize
        if not view or view.X < PANEL_WIDTH * 2 or view.Y < PANEL_HEIGHT * 2 then
            return position
        end
        local peek = math.clamp(CFG.PanelPeekPx or 28, 8, 30)
        local xMin = peek - position.X.Scale * view.X
        local xMax = view.X - peek + PANEL_WIDTH - position.X.Scale * view.X
        local yMin = peek - PANEL_HEIGHT / 2 - position.Y.Scale * view.Y
        local yMax = view.Y - peek + PANEL_HEIGHT / 2 - position.Y.Scale * view.Y
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
            kiteFocusCharacter = nil
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
            tweenTo(toggleButton, { BackgroundTransparency = 0.2 }, 0.06)
        end
    end)

    connectUI(UserInputService.InputChanged, function(input)
        if not dragging or not activeInput or not dragStart or not startPosition then return end
        local isMatchingTouch = activeInput.UserInputType == Enum.UserInputType.Touch
            and input == activeInput
        local isMouseMove = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement

        if isMouseMove and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
            -- The release happened outside the window: drop the gesture without toggling.
            dragging, dragMoved = false, false
            activeInput, dragStart, startPosition = nil, nil, nil
            tweenTo(toggleButton, { BackgroundTransparency = 0 }, 0.12)
            return
        end

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
                env.VD_AUTO_MANS_PANEL = savedPanelPosition
            end
        end
    end)

    connectUI(UserInputService.InputEnded, function(input)
        if not dragging or not activeInput then return end
        local touchEnded = input == activeInput
        local mouseEnded = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseButton1
        if touchEnded or mouseEnded then
            tweenTo(toggleButton, { BackgroundTransparency = 0 }, 0.12)
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

    -- A remembered position may not fit this screen (rotation, another device):
    -- re-clamp it once the layout size is known.
    task.defer(function()
        if frame.Parent then frame.Position = clampPosition(frame.Position) end
    end)

    -- V8.1: separate COPY LOG button (errors here must never break the MANS pill).
    pcall(HitBatcher.buildCopyButton)
end

-- ===================== V8.1 COPY LOG BUTTON =====================
function HitBatcher.disconnectCopy()
    for _, connection in ipairs(HitBatcher.copyConns) do disconnect(connection) end
    table.clear(HitBatcher.copyConns)
end

function HitBatcher.refreshCopyLabel()
    local button = HitBatcher.copyButton
    if not button or not button.Parent then return end
    if os.clock() < HitBatcher.copyFlashUntil then return end
    button.Text = (HitBatcher.hits > 0) and string.format("COPY LOG (%d)", HitBatcher.hits) or "COPY LOG"
end

function HitBatcher.flashCopy(text, color)
    local button = HitBatcher.copyButton
    if not button or not button.Parent then return end
    HitBatcher.copyFlashUntil = os.clock() + 1.6
    button.Text = text
    tweenTo(button, { BackgroundColor3 = color }, 0.08)
    task.delay(1.7, function()
        if shuttingDown then return end
        local current = HitBatcher.copyButton
        if current and current.Parent then
            tweenTo(current, { BackgroundColor3 = HitBatcher.copyBase }, 0.2)
            HitBatcher.refreshCopyLabel()
        end
    end)
end

-- Fallback when the executor has no clipboard function: show the report in a selectable box.
function HitBatcher.showBox(text)
    if not gui or not gui.Parent then return end
    local stale = gui:FindFirstChild("ReportBox")
    if stale then stale:Destroy() end
    if #text > 150000 then text = text:sub(-150000) end

    local box = Instance.new("Frame")
    box.Name = "ReportBox"
    box.AnchorPoint = Vector2.new(0.5, 0.5)
    box.Position = UDim2.fromScale(0.5, 0.5)
    box.Size = UDim2.fromScale(0.86, 0.72)
    box.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
    box.BorderSizePixel = 0
    box.ZIndex = 300
    box.Parent = gui
    local boxCorner = Instance.new("UICorner")
    boxCorner.CornerRadius = UDim.new(0, 10)
    boxCorner.Parent = box

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(10, 6)
    title.Size = UDim2.new(1, -90, 0, 26)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 12
    title.TextColor3 = Color3.new(1, 1, 1)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "No clipboard here: long-press the text, select all, copy"
    title.ZIndex = 301
    title.Parent = box

    local close = Instance.new("TextButton")
    close.Position = UDim2.new(1, -74, 0, 6)
    close.Size = UDim2.fromOffset(66, 26)
    close.BackgroundColor3 = FILL_OFF
    close.BorderSizePixel = 0
    close.Font = Enum.Font.GothamBold
    close.TextSize = 12
    close.TextColor3 = Color3.new(1, 1, 1)
    close.Text = "CLOSE"
    close.ZIndex = 301
    close.Parent = box
    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0, 7)
    closeCorner.Parent = close

    local scroll = Instance.new("ScrollingFrame")
    scroll.Position = UDim2.fromOffset(8, 38)
    scroll.Size = UDim2.new(1, -16, 1, -46)
    scroll.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 5
    scroll.CanvasSize = UDim2.new()
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.ZIndex = 301
    scroll.Parent = box

    local input = Instance.new("TextBox")
    input.Size = UDim2.new(1, -8, 0, 0)
    input.AutomaticSize = Enum.AutomaticSize.Y
    input.BackgroundTransparency = 1
    input.ClearTextOnFocus = false
    input.MultiLine = true
    input.TextWrapped = true
    input.Font = Enum.Font.Code
    input.TextSize = 11
    input.TextColor3 = Color3.fromRGB(220, 224, 235)
    input.TextXAlignment = Enum.TextXAlignment.Left
    input.TextYAlignment = Enum.TextYAlignment.Top
    input.ZIndex = 302
    input.Text = text
    input.Parent = scroll

    local conns = HitBatcher.copyConns
    conns[#conns + 1] = close.Activated:Connect(function() box:Destroy() end)
end

function HitBatcher.tapCopy()
    local ok, copied, text = pcall(HitBatcher.copyAll)
    if not ok then
        warn("[VD Auto Mans V8.2] copy failed: " .. tostring(copied))
        HitBatcher.flashCopy("ERROR", Color3.fromRGB(150, 60, 60))
        return
    end
    if copied then
        HitBatcher.flashCopy("COPIED", FILL_ON)
    else
        print(text)
        HitBatcher.flashCopy("NO CLIPBOARD", Color3.fromRGB(176, 120, 40))
        pcall(HitBatcher.showBox, text)
    end
end

-- Separate pill under the MANS pill: tap = copy everything, drag = move (position survives a rebuild).
function HitBatcher.buildCopyButton()
    HitBatcher.disconnectCopy()
    HitBatcher.copyButton = nil
    if not gui or not gui.Parent then return end
    local stale = gui:FindFirstChild("CopyPanel")
    if stale then stale:Destroy() end

    local width, height, margin = 116, 30, 6
    local frame = Instance.new("Frame")
    frame.Name = "CopyPanel"
    frame.AnchorPoint = Vector2.new(1, 0.5)
    frame.Position = env.VD_AUTO_MANS_COPYPOS or UDim2.new(1, -12, 0.70, 44)
    frame.Size = UDim2.fromOffset(width, height)
    frame.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
    frame.BackgroundTransparency = 0.04
    frame.BorderSizePixel = 0
    frame.Active = false
    frame.ZIndex = 100
    frame.Parent = gui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 10)
    frameCorner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = STROKE_OFF
    stroke.Transparency = 0.2
    stroke.Thickness = 1
    stroke.Parent = frame

    local button = Instance.new("TextButton")
    button.Name = "Copy"
    button.Position = UDim2.fromOffset(3, 3)
    button.Size = UDim2.new(1, -6, 1, -6)
    button.BorderSizePixel = 0
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.AutoButtonColor = false
    button.Active = true
    button.Selectable = false
    button.ZIndex = 101
    button.BackgroundColor3 = HitBatcher.copyBase
    button.Text = "COPY LOG"
    button.Parent = frame

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 7)
    buttonCorner.Parent = button

    HitBatcher.copyButton = button
    HitBatcher.refreshCopyLabel()

    -- Same rule as the MANS pill: may leave the screen, PanelPeekPx pixels stay visible.
    local function clampPosition(position)
        local view = gui and gui.AbsoluteSize
        if not view or view.X < width * 2 or view.Y < height * 2 then return position end
        local peek = math.clamp(CFG.PanelPeekPx or 28, 8, 30)
        local xMin = peek - position.X.Scale * view.X
        local xMax = view.X - peek + width - position.X.Scale * view.X
        local yMin = peek - height / 2 - position.Y.Scale * view.Y
        local yMax = view.Y - peek + height / 2 - position.Y.Scale * view.Y
        return UDim2.new(
            position.X.Scale, math.clamp(position.X.Offset, xMin, math.max(xMin, xMax)),
            position.Y.Scale, math.clamp(position.Y.Offset, yMin, math.max(yMin, yMax))
        )
    end

    local dragging, dragMoved = false, false
    local dragStart, startPosition, activeInput = nil, nil, nil
    local conns = HitBatcher.copyConns

    conns[#conns + 1] = button.InputBegan:Connect(guarded("copy button", function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragMoved = true, false
            dragStart, startPosition, activeInput = input.Position, frame.Position, input
            tweenTo(button, { BackgroundTransparency = 0.2 }, 0.06)
        end
    end))

    conns[#conns + 1] = UserInputService.InputChanged:Connect(guarded("copy button drag", function(input)
        if not dragging or not activeInput or not dragStart or not startPosition then return end
        local isMatchingTouch = activeInput.UserInputType == Enum.UserInputType.Touch
            and input == activeInput
        local isMouseMove = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement

        if isMouseMove and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
            dragging, dragMoved = false, false
            activeInput, dragStart, startPosition = nil, nil, nil
            tweenTo(button, { BackgroundTransparency = 0 }, 0.12)
            return
        end
        if isMatchingTouch or isMouseMove then
            local delta = input.Position - dragStart
            if delta.Magnitude >= 12 then dragMoved = true end -- jitter below this is still a tap
            if dragMoved then
                frame.Position = clampPosition(UDim2.new(
                    startPosition.X.Scale, startPosition.X.Offset + delta.X,
                    startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
                ))
                env.VD_AUTO_MANS_COPYPOS = frame.Position
            end
        end
    end))

    conns[#conns + 1] = UserInputService.InputEnded:Connect(guarded("copy button tap", function(input)
        if not dragging or not activeInput then return end
        local touchEnded = input == activeInput
        local mouseEnded = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseButton1
        if touchEnded or mouseEnded then
            tweenTo(button, { BackgroundTransparency = 0 }, 0.12)
            local wasTap = not dragMoved
            dragging, dragMoved = false, false
            activeInput, dragStart, startPosition = nil, nil, nil
            if wasTap then HitBatcher.tapCopy() end
        end
    end))

    task.defer(function()
        if frame.Parent then frame.Position = clampPosition(frame.Position) end
    end)
end

local function planCloseOrbit(dodge, now)
    if not dodge or not dodge.root or not dodge.root.Parent then return nil end
    local threat = dodge.threat
    local targetCharacter = threat and threat.targetCharacter
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

    local exclusions = buildCharacterExclusions(true)
    moveRayParams.FilterDescendantsInstances = exclusions
    groundRayParams.FilterDescendantsInstances = exclusions

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
    local function orbitScore(clearDirection, clearance)
        return clearDirection:Dot(desired) * 3.0
            + clearDirection:Dot(away) * (distance < 2.6 and 0.8 or 0.08)
            + math.min(clearance or 0, CFG.ProbeDistance) * 0.09
    end
    local bestDirection = searchBestDirection(
        root, candidates,
        function(unit) return orbitScore(unit, CFG.ProbeDistance) end,
        orbitScore
    )

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
    pcall(HitBatcher.flush)
    pcall(HitBatcher.disconnectCopy)
    activeDodge = nil
    kiteFocusCharacter = nil
    disconnect(healthConn)
    healthConn = nil

    pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV8_2_Move") end)

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
    table.clear(trackedParts)
    trackedCount = 0
    exclusionCache = nil
    table.clear(lastByTarget)

    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
    gui, statusLabel, detailLabel, toggleButton = nil, nil, nil, nil
    indicatorDot, indicatorStroke, indicatorState = nil, nil, nil
    orbitBlockedUntil = 0
end

env.VD_AUTO_MANS_STOP = cleanup
_G.VD_AUTO_MANS_STOP = cleanup

pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV8_2_Move") end)
RunService:BindToRenderStep(
    "VD_AutoMansV8_2_Move",
    Enum.RenderPriority.Last.Value,
    guarded("steering", function()
        if shuttingDown then return end
        local dodge = activeDodge
        if not dodge then return end

        local now = os.clock()
        if not CFG.Enabled or now >= dodge.finishAt then
            -- Simply release our render-step steering; normal player controls resume.
            if CFG.Enabled and dodge.orbiting then orbitBlockedUntil = now + CFG.OrbitCooldown end
            if CFG.Enabled and dodge.kiting and not dodge.orbiting then
                -- Burst finished: hand the joystick back for a short, random while.
                local near = (dodge.kiteDistance or 99) < 6.5
                local lo = near and CFG.FootworkPauseNearMin or CFG.FootworkPauseMin
                local hi = near and CFG.FootworkPauseNearMax or CFG.FootworkPauseMax
                kitePauseUntil = now + lo + math.random() * (hi - lo)
            end
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

        -- Emergency takeover is conditional: release when the target leaves the
        -- critical bubble, disappears, the actual 360 completes, or the safety timer expires.
        if dodge.orbiting then
            local _, targetRoot = getCharacterParts(dodge.threat and dodge.threat.targetCharacter)
            if not targetRoot then
                activeDodge = nil
                return
            end

            local orbitOffset = dodge.root.Position - targetRoot.Position
            local distance = orbitOffset.Magnitude
            local timedOut = now - (dodge.orbitStartedAt or dodge.startedAt) >= CFG.CloseOrbitTimeout
            if timedOut
                or math.abs(orbitOffset.Y) > CFG.CriticalVerticalSeparation
                or distance > CFG.EmergencyTakeoverReleaseRange then
                if timedOut then orbitBlockedUntil = now + CFG.OrbitCooldown end
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
                orbitBlockedUntil = now + CFG.OrbitCooldown -- full revolution done
                activeDodge = nil
                return
            end
        end

        -- One mid-maneuver re-plan: avoids locking into a bad line if the
        -- target cuts across after the first half of the dodge.
        local shouldRetargetKite = false -- V7.8: footworkDirection plans the kite itself
        local shouldRetargetDodge = not dodge.kiting and not dodge.retargeted
            and (dodge.retargetNow or now >= dodge.retargetAt)
        if shouldRetargetKite or shouldRetargetDodge then
            local threat = dodge.threat
            local freshThreat = nil

            if threat and threat.targetCharacter then
                local _, enemyRoot = getCharacterParts(threat.targetCharacter)
                if enemyRoot then
                    freshThreat = {
                        time = 0.12,
                        position = enemyRoot.Position,
                        velocity = enemyRoot.AssemblyLinearVelocity,
                        kind = threat.kind or "re-target",
                        targetCharacter = threat.targetCharacter,
                        sourceRoot = enemyRoot,
                        attackDir = threat.attackDir,
                        kiting = dodge.kiting == true,
                    }
                end
            elseif threat and threat.projectile and threat.projectile.Parent then
                freshThreat = {
                    time = 0.12,
                    position = threat.projectile.Position,
                    velocity = threat.projectile.AssemblyLinearVelocity,
                    kind = threat.kind or "projectile re-target",
                    projectile = threat.projectile,
                }
            end

            if freshThreat then
                freshThreat.kiting = dodge.kiting == true
                local newDirection, newScore, clearance = chooseDodgeDirection(dodge.root, dodge.humanoid, freshThreat)
                if newDirection then
                    dodge.direction = newDirection
                    dodge.score = newScore
                    dodge.clearance = clearance
                    if dodge.kiting then
                        setStatus("KITE: ADJUST", string.format("Path refreshed • %.1f clear", clearance))
                    else
                        setStatus("RE-WEAVE", string.format("Updated path • %.1f studs clear", clearance))
                    end
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
                    local _, targetRoot = getCharacterParts(dodge.threat and dodge.threat.targetCharacter)
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
        elseif CFG.MovementStylesEnabled then
            local styledDirection = styledDirectionFor(dodge, now)
            if not styledDirection or styledDirection.Magnitude <= 0.02 then
                -- styledDirectionFor returns zero when every tested path is blocked.
                -- Do not fall back to the previous direction and keep pushing the wall.
                activeDodge = nil
                return
            end
            dodge.direction = styledDirection
        end

        if not dodge.kiting and not dodge.orbiting then
            local remaining = dodge.finishAt - now
            dodge.speedMul = (remaining < 0.09) and math.clamp(0.45 + 0.55 * remaining / 0.09, 0.45, 1) or 1
        end
        -- Universal "am I really moving?" check (orbit has its own).
        if not dodge.orbiting then
            -- hop verification: did the jump actually lift us?
            if dodge.hopCheck and now >= dodge.hopCheck.at then
                if dodge.root.Position.Y - dodge.hopCheck.y < 0.8 then
                    hopFails = hopFails + 1
                    if hopFails >= 2 then
                        hopDisabledUntil = now + 10
                        hopAvailable = false
                        hopFails = 0
                        logEvent("jumping does nothing here: hop disabled for 10s, low obstacles are walls now")
                    end
                else
                    hopFails = 0
                end
                dodge.hopCheck = nil
            end
            if now >= hopDisabledUntil then
                hopAvailable = CFG.AutoHop and canJumpNow(dodge.humanoid)
            end
            if now - lastHitchAt < 0.35 then
                dodge.stuckCheckAt = nil -- lag spike: position data is unreliable, skip this check
            elseif not dodge.stuckCheckAt then
                dodge.stuckCheckAt, dodge.stuckPos = now, dodge.root.Position
            elseif now - dodge.stuckCheckAt >= CFG.StuckCheckEvery then
                local interval = now - dodge.stuckCheckAt
                local moved = flat(dodge.root.Position - dodge.stuckPos).Magnitude
                local expected = math.max(dodge.humanoid.WalkSpeed, 9) * (dodge.speedMul or 1)
                    * interval * CFG.StuckSpeedFraction
                dodge.stuckCheckAt, dodge.stuckPos = now, dodge.root.Position
                if now - dodge.startedAt > 0.15 and moved < expected then
                    dodge.stuckCount = (dodge.stuckCount or 0) + 1
                    logEvent(string.format("STUCK x%d: moved %.2f of %.2f expected", dodge.stuckCount, moved, expected))
                    rememberBlockedZone(dodge.root.Position + unitOrZero(flat(dodge.direction or Vector3.zero)) * 2.5)
                    tryHop(dodge, now)
                    local _, enemyRoot = getCharacterParts(dodge.threat and dodge.threat.targetCharacter)
                    local awayFromEnemy = enemyRoot and unitOrZero(flat(dodge.root.Position - enemyRoot.Position)) or Vector3.zero
                    if dodge.stuckCount >= 2 then
                        local openDirection = bestOpenDirection(dodge.root, awayFromEnemy)
                        if openDirection then
                            dodge.fwEscape = { dir = openDirection, untilAt = now + 0.40 }
                            dodge.direction = openDirection
                            dodge.smoothedStyleDirection = openDirection
                            logEvent("STUCK: escaping toward the most open direction")
                        end
                    end
                    if dodge.kiting then
                        local step = dodge.fwStep
                        if step then step.endAt = now; step.side = -step.side end
                        dodge.fwDir = nil
                    else
                        local freshDirection = select(1, chooseDodgeDirection(dodge.root, dodge.humanoid, dodge.threat))
                        if freshDirection then
                            dodge.direction = freshDirection
                            dodge.smoothedStyleDirection = freshDirection
                            dodge.patternSide = -(dodge.patternSide or 1)
                        end
                    end
                    if dodge.stuckCount >= CFG.MaxStuckBeforeRelease then
                        logEvent("STUCK for good: joystick handed back")
                        kitePauseUntil = now + 0.40
                        activeDodge = nil
                        return
                    end
                else
                    dodge.stuckCount = 0
                end
            end
        end
        local moveDirection = dodge.direction
        if CFG.WallSlide and dodge.root.Parent then
            moveDirection = slideAlongWalls(dodge.root, dodge.direction)
        end
        dodge.humanoid:Move(moveDirection * (dodge.speedMul or 1), false)
    end, function()
        -- On any error hand control straight back to the player.
        activeDodge = nil
    end)
)

connect(Players.PlayerAdded, watchPlayer)
connect(LocalPlayer.CharacterRemoving, function(character)
    if activeDodge and activeDodge.character == character then
        activeDodge = nil
    end
    kiteFocusCharacter = nil
    exclusionCache = nil
    exclusionCacheOwner = nil
end)
connect(LocalPlayer.CharacterAdded, function(newCharacter)
    hookHealth(newCharacter)
    kitePauseUntil = 0
    activeDodge = nil
    kiteFocusCharacter = nil
    orbitBlockedUntil = 0
    lastDodge = -math.huge
    exclusionCache = nil
    exclusionCacheOwner = nil
end)
connect(Players.PlayerRemoving, function(player)
    if player.Character then
        local character = player.Character
        characterTokens[character] = (characterTokens[character] or 0) + 1
        disconnect(characterConnections[character])
        characterConnections[character] = nil
        watchedCharacters[character] = nil
        lastByTarget[character] = nil
        if activeDodge and activeDodge.threat and activeDodge.threat.targetCharacter == character then
            activeDodge = nil
        end
    end
    for _, connection in ipairs(playerConnections[player] or {}) do disconnect(connection) end
    playerConnections[player] = nil
end)

connect(Workspace.DescendantAdded, function(instance)
    if not CFG.ProjectilePrediction or not instance:IsA("BasePart") then return end
    task.delay(CFG.NewPartDelay, function()
        if not shuttingDown then trackPart(instance) end
    end)
end)

connect(Workspace.DescendantRemoving, function(instance)
    if instance:IsA("BasePart") then
        untrackPart(instance)
    end
end)

-- Scan existing parts without blocking a single frame for the full map.
task.spawn(function()
    local descendants = Workspace:GetDescendants()
    for index, instance in ipairs(descendants) do
        if shuttingDown then break end
        if instance:IsA("BasePart") then trackPart(instance) end
        descendants[index] = nil -- release processed references as early as possible
        if index % CFG.InitialScanYieldEvery == 0 then task.wait() end
    end
    table.clear(descendants)
end)

connect(RunService.Heartbeat, guarded("threat scan", function()
    if shuttingDown or not CFG.Enabled then return end
    if localRoleBlocksAutomation() then
        activeDodge = nil
        kiteFocusCharacter = nil
        return
    end

    local now = os.clock()
    if now - lastPrediction < CFG.PredictionInterval then return end
    lastPrediction = now

    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root or localCharacterBlocked(character, humanoid) then
        activeDodge = nil
        return
    end

    local bestThreat = nil

    -- Emergency proximity takeover: role-filtered in KILLERS_ONLY mode. In ANY_PLAYER
    -- mode, require approach/facing evidence to avoid orbiting harmless passers-by.
    local nearestCriticalDistance = CFG.EmergencyTakeoverRange
    for _, player in ipairs(Players:GetPlayers()) do
        if isThreatPlayer(player) then
            local _, enemyRoot = getCharacterParts(player.Character)
            if enemyRoot then
                local offset = enemyRoot.Position - root.Position
                local distance = offset.Magnitude
                local sameLevel = math.abs(offset.Y) <= CFG.CriticalVerticalSeparation
                -- Cheap checks first: the line-of-sight raycast only runs for an eligible target in range.
                local criticalTargetCue = true
                if CFG.ThreatMode == "ANY_PLAYER" then
                    local closing = closingSpeed(root, enemyRoot)
                    local facing = facingUs(root, enemyRoot)
                    criticalTargetCue = closing >= CFG.MinimumClosingSpeed
                        or (facing and distance <= CFG.CriticalFacingRange)
                end
                if sameLevel and distance <= nearestCriticalDistance and criticalTargetCue
                    and now >= orbitBlockedUntil
                    and hasLineOfSight(root, enemyRoot, player.Character) then
                    nearestCriticalDistance = distance
                    bestThreat = {
                        time = 0,
                        score = -1,
                        position = enemyRoot.Position,
                        velocity = enemyRoot.AssemblyLinearVelocity,
                        kind = "CRITICAL PROXIMITY",
                        targetCharacter = player.Character,
                        sourceRoot = enemyRoot,
                    }
                end
            end
        end
    end

    if CFG.PlayerPrediction and not bestThreat then
        for _, player in ipairs(Players:GetPlayers()) do
            if isThreatPlayer(player) then
                local threat = predictPlayerThreat(root, player.Character)
                if threat and (not bestThreat or threat.score < bestThreat.score) then
                    bestThreat = threat
                end
            end
        end
    end

    if CFG.ProjectilePrediction then
        local projectile = predictProjectileThreat(root)
        if projectile and (not bestThreat or projectile.score < bestThreat.score) then
            bestThreat = projectile
        end
    end

    local kiteThreat = nil
    if now >= kitePauseUntil then kiteThreat = findKiteThreat(root) end

    -- Prefer predicted emergencies, but use spacing movement to preserve distance
    -- from nearby players before their attack is already in contact range.
    local lead = latencyLead()
    if bestThreat and bestThreat.projectile then
        if (bestThreat.time or 1) <= 0.36 + lead then
            requestDodge(bestThreat, (bestThreat.time or 1) <= 0.22 + lead)
        end
    elseif bestThreat and bestThreat.targetCharacter
        and ((bestThreat.time or 1) <= 0.32 + lead or bestThreat.kind == "CRITICAL PROXIMITY") then
        requestDodge(bestThreat, true)
    elseif kiteThreat then
        -- Spacing pulse: preserve distance while the nearest player remains in range.
        requestDodge(kiteThreat, true)
    else
        kiteFocusCharacter = nil
    end
end, function()
    activeDodge = nil
end))

for _, player in ipairs(Players:GetPlayers()) do watchPlayer(player) end
hookHealth(LocalPlayer.Character)
makeUI()
setStatus("SCANNING", CFG.ThreatMode == "ANY_PLAYER" and "Any player • moving hazards" or "Detected killers • moving hazards")

-- Recreate only the small panel if PlayerGui/ScreenGui is removed or replaced.
-- This preserves the current ON/OFF state and does not restart the movement logic.
connect(RunService.Heartbeat, function(dt)
    if dt > 0.12 then lastHitchAt = os.clock() end
end)

local nextUIRepairAt = 0
connect(RunService.Heartbeat, guarded("panel", function()
    if shuttingDown then return end
    refreshIndicator()
    local now = os.clock()
    if now < nextUIRepairAt then return end

    local currentPlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local currentPanel = gui and gui:FindFirstChild("Panel")
    local currentToggle = currentPanel and currentPanel:FindFirstChild("Toggle")

    -- Cutscenes sometimes remove only the button or disable/hide the ScreenGui,
    -- leaving Panel behind. Checking Panel alone falsely treated that UI as healthy.
    local uiHealthy = gui ~= nil
        and currentPlayerGui ~= nil
        and gui.Parent == currentPlayerGui
        and gui.Enabled
        and currentPanel ~= nil
        and currentPanel:IsA("GuiObject")
        and currentPanel.Visible
        and currentToggle ~= nil
        and currentToggle:IsA("GuiObject")
        and currentToggle.Visible
        and toggleButton == currentToggle
        and toggleButton.Parent == currentPanel

    if not uiHealthy then
        nextUIRepairAt = now + 0.5
        if currentPlayerGui then
            local ok, err = pcall(makeUI)
            if not ok then
                warn("[VD Auto Mans V8.2] Panel repair failed: " .. tostring(err))
            end
        end
    end

    -- Only the COPY LOG button vanished: rebuild just that (the MANS pill is fine).
    if uiHealthy and (not HitBatcher.copyButton or not HitBatcher.copyButton.Parent) then
        nextUIRepairAt = now + 1.0
        pcall(HitBatcher.buildCopyButton)
    end
end))
print("[VD Auto Mans V8.2] Loaded. Tap the COPY LOG button to copy everything the script learned (hits, tuned settings, attack timings, events) - paste it to Claude. Full log: VD_AUTO_MANS_LOG()")
