--[[
VD AUTO MANS V7.3 — PULSE FOOTWORK (compact touch panel)
Originally tuned for PlaceId 93978595733734; no longer hard-blocks other PlaceIds.
Other games remain best-effort and may need different timing/attack cues.

Client-side only: it steers your own character with Humanoid:Move and never
fires game remotes. ThreatMode = "ANY_PLAYER" is the default; it does not require
recognizing a killer role to react to other players.

  * Filters common idle/walk/run/emote tracks; attack hints and closing-path prediction
    take priority over generic facing cues.
  * Proactive footwork uses short pulses with real hand-back gaps. Footwork.Enabled
    smooths turns, ramps input and brakes through reversals.
  * Point-blank target: wall- and edge-aware short emergency side-cut, then control returns
    to your joystick.
  * Never steers while you are hooked / carried / downed, frozen by the game
    (WalkSpeed ~ 0), climbing, seated, or while a "busy" attribute is set
    (CFG.BlockingAttributes: healing, repairing, vaulting, stunned, ...).
  * Reaction window widens a little on high ping (CFG.LatencyCompensation).
  * After a close emergency cut ends you get your joystick back for CFG.OrbitCooldown seconds,
    so you can steer manually instead of being orbited endlessly.
  * Compact pill: tap = ON/OFF, drag = move (stays on screen, position survives a
    UI rebuild). Dot: green = armed, amber = dodging, red = emergency cut.
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
    LatencyMaxLead = 0.10,

    -- After a close orbit ends, hand control back for this long before another orbit
    -- may start (0 = keep orbiting for as long as the target stays point-blank).
    OrbitCooldown = 0.30,

    -- Animation listener watches every animation, then scores whether the
    -- situation is dangerous rather than blindly dodging every idle animation.
    AnimationTrigger = true,
    AnimationRange = 21,
    CriticalAnimationRange = 4.5,
    EmergencyTakeoverRange = 5.2, -- emergency escape when contact is imminent
    EmergencyTakeoverReleaseRange = 8.0, -- release after creating a useful gap
    MaxThreatVerticalSeparation = 5.5, -- avoid reacting to players on another floor
    CriticalVerticalSeparation = 3.5, -- close orbit is allowed only on the same level
    CloseOrbitTimeout = 0.48, -- one short arc/cut, not a full circle around the target
    CloseOrbitTargetRadius = 7.5, -- create a larger gap rather than orbiting at contact range
    OrbitReplanInterval = 0.085,
    OrbitTangentWeight = 1.0,
    StuckCheckInterval = 0.22,
    StuckMinProgress = 0.32,
    CloseFacingRange = 8,
    CriticalFacingRange = 4.4, -- react to a close attacker facing us even if they briefly stop moving
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
    DodgeDuration = 0.36,
    TargetCooldown = 0.13,
    MinimumDodgeInterval = 0.13,
-- Proactive spacing stays close-range, pulse-based and obstacle-aware.
    KiteEnabled = true,
    -- Nearby/approaching only: don't hijack the joystick at long range.
    KiteStartRange = 15.0,
    KiteReleaseRange = 17.2,
    KiteHardRange = 8.8,
    KiteClosingThreshold = 1.10,
    -- Brief committed step, then a hand-back gap to the player's joystick.
    KitePulseDuration = 0.30,
    KitePulseGapMin = 0.16,
    KitePulseGapMax = 0.28,
    KiteReplanInterval = 0.11,
    KiteAwayWeight = 0.14,
    KiteSideWeight = 3.0,
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
    PredictionInterval = 0.075, -- avoid needless 35 ms re-triggering

    -- Short dodges get light style variation; close-range orbit has its own steering.
    MovementStylesEnabled = true,
    StyleCycleDuration = 0.90,
    StyleBlendDuration = 0.14,
    StyleSafetyInterval = 0.075,
    SteeringSmoothingSeconds = 0.095,
    StyleRadialKeepout = 0.66,

    -- Set Enabled=false to compare with direct full-strength Move() input.
    -- The actuator ramps input, rate-limits turns, and brakes through reversals.
    Footwork = {
        Enabled = true,
        PeakInput = 0.82,
        MinimumInput = 0.10,
        Acceleration = 5.0,
        Braking = 8.8,
        TurnRate = 3.8,
        ReverseDotThreshold = -0.38,
        ReverseZeroThreshold = 0.12,
        ReversePause = 0.075,
        PulseRampSeconds = 0.075,
        PulseFadeSeconds = 0.14,
        EmergencyPeakInput = 0.92,
    },
}

if CFG.ThreatMode ~= "ANY_PLAYER" and CFG.ThreatMode ~= "KILLERS_ONLY" then
    warn("[VD Auto Mans V7.3] Invalid ThreatMode; falling back to ANY_PLAYER.")
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
local kitePulseBlockedUntil = 0
local kiteDirectionSide = 1
local nextKiteSideChangeAt = 0
local footworkStateByCharacter = setmetatable({}, { __mode = "k" })
local gui = nil
local statusLabel = nil
local detailLabel = nil
local toggleButton = nil
local trackedCount = 0
local savedPanelPosition = env.VD_AUTO_MANS_PANEL -- survives re-running the script
local orbitBlockedUntil = 0
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
                warn("[VD Auto Mans V7.3] " .. name .. " error: " .. tostring(err))
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

local function locomotionLike(track)
    if not track then return false end
    local names = {}
    pcall(function() table.insert(names, tostring(track.Name or "")) end)
    pcall(function()
        if track.Animation then table.insert(names, tostring(track.Animation.Name or "")) end
    end)
    local locomotionTokens = {
        idle = true, walk = true, walking = true, run = true, running = true,
        jog = true, strafe = true, locomotion = true, emote = true, dance = true,
        sit = true, fall = true, falling = true, jump = true, landing = true,
        climb = true, swimming = true,
    }
    for _, raw in ipairs(names) do
        local normalized = raw:gsub("(%l)(%u)", "%1 %2"):lower()
        for token in normalized:gmatch("[%w]+") do
            if locomotionTokens[token] then return true end
        end
    end
    local priority
    pcall(function() priority = track.Priority end)
    if priority == Enum.AnimationPriority.Core
        or priority == Enum.AnimationPriority.Idle
        or priority == Enum.AnimationPriority.Movement then
        return true
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

    local t = math.clamp(-offset:Dot(relativeVelocity) / speedSquared, 0, CFG.PlayerHorizon)
    local closest = offset + relativeVelocity * t
    local missDistance = closest.Magnitude
    local closing = -offset:Dot(relativeVelocity) / math.max(distance, 0.1)

    if closing <= CFG.MinimumClosingSpeedForPrediction or missDistance > CFG.PlayerThreatRadius then
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
    "ARC LEFT", "ARC RIGHT", "DIAGONAL CUT", "CHECK STEP", "COUNTER CUT",
}

-- Discrete paths, not continuous high-frequency sine waves. The actuator below
-- limits how quickly the selected direction can change and how strongly it is applied.
local function getStyleVector(styleIndex, elapsed, away, tangent, radial, side)
    local vector
    local phase = elapsed % 0.66
    if styleIndex == 1 then
        vector = away * math.max(radial, 0.34) + tangent * side * 1.00
    elseif styleIndex == 2 then
        vector = away * math.max(radial, 0.34) - tangent * side * 1.00
    elseif styleIndex == 3 then
        vector = away * 0.40 + tangent * side * 1.10
    elseif styleIndex == 4 then
        if phase < 0.18 then
            vector = away * 0.52 + tangent * side * 0.72
        else
            vector = away * math.max(radial, 0.30) + tangent * side * 1.05
        end
    else
        local cutSide = phase < 0.34 and side or -side
        vector = away * math.max(radial, 0.32) + tangent * cutSide * 0.92
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
        if now >= nextKiteSideChangeAt then
            if nextKiteSideChangeAt > 0 then kiteDirectionSide = -kiteDirectionSide end
            nextKiteSideChangeAt = now + math.random(115, 205) / 100
        end
        local kiteSide = kiteDirectionSide
        -- A low, held bias varies the path without a metronomic sine-wave weave.
        if not dodge.kiteFeintBias then dodge.kiteFeintBias = math.random(-8, 8) / 100 end
        local weave = dodge.kiteFeintBias
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
    local isKiteRequest = threat and threat.kiting == true
    local activeKitePulse = activeDodge and activeDodge.kiting
        and now < activeDodge.finishAt
    if isKiteRequest and not urgent and now < kitePulseBlockedUntil
        and not activeKitePulse then return false end

    if activeDodge and now < activeDodge.finishAt then
        -- If a normal short dodge is already underway when the target gets
        -- critically close, promote it into the controlled orbit immediately.
        if threat and threat.targetCharacter and activeDodge.root and activeDodge.root.Parent then
            local _, closeRoot = getCharacterParts(threat.targetCharacter)
            if closeRoot then
                local closeOffset = activeDodge.root.Position - closeRoot.Position
                local closeDistance = closeOffset.Magnitude
                if closeDistance <= CFG.EmergencyTakeoverRange
                    and now >= orbitBlockedUntil
                    and not (threat and threat.kiting)
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
                    if activeDodge.kiting and threat and not threat.kiting and urgent then
                        activeDodge.kiting = false
                    end
                    activeDodge.threat = threat
                    return true
                end
            end
        end

        -- A confirmed/imminent threat can override the continuous kite pulse.
        if activeDodge.kiting and threat and not threat.kiting and urgent then
            activeDodge.kiting = false
            activeDodge.threat = threat
            activeDodge.finishAt = math.max(activeDodge.finishAt, now + 0.24)
            activeDodge.retargeted = false
            activeDodge.retargetNow = true
            return true
        end
        -- Keep the target position fresh, but never extend the pulse deadline here.
        -- That deadline creates a real control hand-back gap after each step.
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
        return false
    end

    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root or localCharacterBlocked(character, humanoid) then
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
            return false
        end
        local maxThreatRange = (threat and threat.kiting)
            and (CFG.KiteReleaseRange + 1)
            or (CFG.AnimationRange + 3)
        if distance > maxThreatRange then return false end

        if not (threat and threat.kiting) then
            local previous = lastByTarget[sourceCharacter] or -math.huge
            if now - previous < CFG.TargetCooldown and not urgent then return false end
        end
    end

    -- Point-blank takeovers bypass the regular cooldown; ordinary player and
    -- projectile dodges remain rate-limited to avoid repetitive movement bursts.
    if not veryClose and now - lastDodge < CFG.MinimumDodgeInterval then return false end

    local direction, score, clearance = chooseDodgeDirection(root, humanoid, threat)
    if not direction then
        setStatus("NO CLEAR PATH", "No safe route; normal control kept")
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
        or (isKiting and CFG.KitePulseDuration
        or math.clamp(0.22 + estimatedEta * 0.35, 0.22, CFG.DodgeDuration))
    if isKiting then
        local gap = math.random(math.floor(CFG.KitePulseGapMin * 100), math.floor(CFG.KitePulseGapMax * 100)) / 100
        kitePulseBlockedUntil = now + duration + gap
    end
    local savedFootwork = footworkStateByCharacter[character]
    local launchVelocity = flat(root.AssemblyLinearVelocity)
    local hasClearMovementHeading = launchVelocity.Magnitude >= 3.0
    -- Resume the previous control heading across the hand-back gap. Re-seeding
    -- from physical velocity every pulse can erase a slow reversal before it ends.
    -- If the actual movement points strongly against the saved heading, assume the
    -- player changed direction manually during the gap and accept that new heading.
    local savedDirection = savedFootwork and savedFootwork.direction
    local savedStateFresh = savedFootwork
        and now - (savedFootwork.updatedAt or 0) <= 0.85
        and savedDirection and savedDirection.Magnitude > 0.01
    local manualHeadingOverride = savedStateFresh and hasClearMovementHeading
        and savedDirection:Dot(launchVelocity.Unit) < -0.10
    local resumeSavedFootwork = savedStateFresh and not manualHeadingOverride
    local initialFootworkDirection = resumeSavedFootwork and savedDirection
        or (hasClearMovementHeading and launchVelocity.Unit or direction)

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
        footworkDirection = initialFootworkDirection,
        footworkThrottle = 0,
        lastFootworkAt = now,
        reversePauseUntil = resumeSavedFootwork and savedFootwork.reversePauseUntil or nil,
        reverseReady = resumeSavedFootwork and savedFootwork.reverseReady or false,
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
        veryClose and "Wall-aware side cut" or string.format("%s • %.1f studs clear", (threat and threat.kind) or "threat", clearance))
    return true
end

-- Short footwork pulses for close/approaching targets; no constant auto-run.
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
        local closing = closingSpeed(myRoot, focusRoot)
        local facing = facingUs(myRoot, focusRoot)
        local stillRelevant = distance <= CFG.KiteHardRange
            or closing >= CFG.KiteClosingThreshold
            or (facing and distance <= 11.0)
        local visible = stillRelevant and (not CFG.RequireLineOfSight
            or hasLineOfSight(myRoot, focusRoot, focusCharacter))
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
                        or (facing and distance <= 11.0)
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

local function onThreatAnimation(player, character, track)
    if shuttingDown or not CFG.Enabled or not CFG.AnimationTrigger then return end
    if player.Character ~= character or not isThreatPlayer(player) then return end

    local attackHint = attackLike(track)
    -- Idle/walk/run/jump/emote tracks are not attacks. An unknown low-priority
    -- animation cannot take over merely because its owner happens to face us.
    if not attackHint and locomotionLike(track) then return end

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
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, targetRoot, character) then return end

    local closing = closingSpeed(myRoot, targetRoot)
    local facing = facingUs(myRoot, targetRoot)
    local withinCriticalRange = distance <= CFG.CriticalAnimationRange
    -- Opaque action tracks get a weak fallback only at point-blank distance;
    -- facing alone at 7+ studs no longer triggers a dodge.
    local facingThreatCue = facing and distance <= 3.6 and not locomotionLike(track)
    local critical = withinCriticalRange and (
        attackHint
        or closing >= CFG.MinimumClosingSpeed
        or (facing and distance <= 3.3 and not locomotionLike(track))
    )

    if attackHint and not critical then
        if distance > CFG.AttackHintMaxRange then return end
        if distance > CFG.CloseFacingRange and not facing and closing < CFG.MinimumClosingSpeed then return end
    end

    local smartThreat = attackHint or closing >= CFG.MinimumClosingSpeed or facingThreatCue
    if not critical and not smartThreat then return end

    local eta = math.clamp((distance - 2.0) / math.max(closing, 0.1), 0, 0.45)
    if not critical and not attackHint and not facingThreatCue and eta > 0.18 + latencyLead() then return end
    local attackLead = 0.14 + latencyLead()
    local threat = {
        time = critical and math.min(eta, 0.12)
            or ((attackHint or facingThreatCue) and math.min(eta, attackLead) or eta),
        position = targetRoot.Position,
        velocity = targetRoot.AssemblyLinearVelocity,
        kind = attackHint and "attack animation"
            or (facingThreatCue and "close action cue" or "player approach"),
        targetCharacter = character,
        sourceRoot = targetRoot,
    }
    requestDodge(threat, critical or attackHint or facingThreatCue)
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

    local old = playerGui:FindFirstChild("VD_AutoMansV7_3")
    if old then old:Destroy() end

    gui = Instance.new("ScreenGui")
    gui.Name = "VD_AutoMansV7_3"
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
            kiteFocusCharacter = nil
            kitePulseBlockedUntil = 0
            footworkStateByCharacter[LocalPlayer.Character] = nil
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

local function approachNumber(current, target, maxDelta)
    if target > current then return math.min(target, current + maxDelta) end
    return math.max(target, current - maxDelta)
end

local function rotateFlatTowards(current, target, maxAngle)
    current = unitOrZero(flat(current))
    target = unitOrZero(flat(target))
    if current.Magnitude < 0.01 then return target end
    if target.Magnitude < 0.01 then return current end
    local currentAngle = math.atan2(current.Z, current.X)
    local targetAngle = math.atan2(target.Z, target.X)
    local delta = (targetAngle - currentAngle + math.pi) % (math.pi * 2) - math.pi
    local angle = currentAngle + math.clamp(delta, -maxAngle, maxAngle)
    return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

local function footworkInputFor(dodge, now)
    local fw = CFG.Footwork
    local duration = math.max(0.05, (dodge.finishAt or now) - (dodge.startedAt or now))
    local elapsed = math.max(0, now - (dodge.startedAt or now))
    local ramp = math.max(0.03, math.min(fw.PulseRampSeconds, duration * 0.45))
    local fade = math.max(0.03, math.min(fw.PulseFadeSeconds, duration * 0.45))
    local target = fw.PeakInput
    if dodge.kiting then
        if elapsed < ramp then
            target = fw.PeakInput * (elapsed / ramp)
        elseif elapsed > duration - fade then
            target = fw.PeakInput * math.max(0, (duration - elapsed) / fade)
        else
            target = fw.PeakInput
        end
    elseif dodge.orbiting then
        local peak = math.min(fw.EmergencyPeakInput, 0.88)
        if elapsed > duration - fade then
            target = peak * math.max(0, (duration - elapsed) / fade)
        else
            target = peak
        end
    else
        local rise = math.clamp(elapsed / math.max(0.06, duration * 0.35), 0, 1)
        target = fw.MinimumInput + (fw.EmergencyPeakInput - fw.MinimumInput) * rise
        if elapsed > duration * 0.68 then
            target = target * math.clamp((duration - elapsed) / math.max(0.03, duration * 0.32), 0, 1)
        end
    end
    -- Force a short final braking window before the control deadline. This ensures
    -- the final automated command is near-zero before the joystick is handed back.
    if elapsed >= duration - (1 / 30) then target = 0 end
    return math.clamp(target, 0, 1)
end

local function applyFootwork(dodge, now, dt)
    local desired = unitOrZero(flat(dodge.direction or Vector3.zero))
    if desired.Magnitude < 0.01 then
        dodge.footworkThrottle = approachNumber(dodge.footworkThrottle or 0, 0, CFG.Footwork.Braking * dt)
        if dodge.footworkThrottle > 0.01 and dodge.footworkDirection then
            footworkStateByCharacter[dodge.character] = {
                direction = dodge.footworkDirection, reverseReady = dodge.reverseReady == true,
                reversePauseUntil = dodge.reversePauseUntil, updatedAt = now,
            }
            dodge.humanoid:Move(dodge.footworkDirection * dodge.footworkThrottle, false)
        else
            footworkStateByCharacter[dodge.character] = {
                direction = dodge.footworkDirection or desired, reverseReady = dodge.reverseReady == true,
                reversePauseUntil = dodge.reversePauseUntil, updatedAt = now,
            }
            dodge.humanoid:Move(Vector3.zero, false)
        end
        return
    end

    if not CFG.Footwork.Enabled then
        dodge.footworkDirection = desired
        dodge.footworkThrottle = 1
        dodge.reversePauseUntil = nil
        footworkStateByCharacter[dodge.character] = {
            direction = desired, reverseReady = false, reversePauseUntil = nil, updatedAt = now,
        }
        dodge.humanoid:Move(desired, false)
        return
    end

    local fw = CFG.Footwork
    local currentDirection = dodge.footworkDirection
    if not currentDirection or currentDirection.Magnitude < 0.01 then
        local velocity = flat(dodge.root.AssemblyLinearVelocity)
        local savedState = footworkStateByCharacter[dodge.character]
        if velocity.Magnitude >= 3.0 then
            currentDirection = velocity.Unit
            dodge.reverseReady = false
            dodge.reversePauseUntil = nil
        elseif savedState and savedState.direction and savedState.direction.Magnitude > 0.01 then
            currentDirection = savedState.direction
            dodge.reverseReady = savedState.reverseReady == true
            dodge.reversePauseUntil = savedState.reversePauseUntil
        else
            currentDirection = desired
            dodge.reverseReady = false
        end
        dodge.footworkDirection = currentDirection
    end

    local throttle = dodge.footworkThrottle or 0
    local targetThrottle = footworkInputFor(dodge, now)
    local reversing = currentDirection:Dot(desired) <= fw.ReverseDotThreshold
    if reversing and throttle > fw.ReverseZeroThreshold and not dodge.reverseReady then
        targetThrottle = 0
        desired = currentDirection -- hold heading while braking through near-zero input
        dodge.reversePauseUntil = nil
        dodge.reverseReady = false
    elseif reversing and throttle <= fw.ReverseZeroThreshold and not dodge.reverseReady then
        if not dodge.reversePauseUntil then dodge.reversePauseUntil = now + fw.ReversePause end
        if now < dodge.reversePauseUntil then
            targetThrottle = 0
            desired = currentDirection
        else
            dodge.reversePauseUntil = nil
            dodge.reverseReady = true
        end
    elseif not reversing then
        dodge.reversePauseUntil = nil
        dodge.reverseReady = false
    end

    local rate = targetThrottle < throttle and fw.Braking or fw.Acceleration
    throttle = approachNumber(throttle, targetThrottle, rate * dt)
    local maxTurn = fw.TurnRate * dt
    if reversing and throttle <= fw.ReverseZeroThreshold then maxTurn = maxTurn * 1.15 end
    currentDirection = rotateFlatTowards(currentDirection, desired, maxTurn)

    dodge.footworkDirection = currentDirection
    dodge.footworkThrottle = math.clamp(throttle, 0, 1)
    footworkStateByCharacter[dodge.character] = {
        direction = currentDirection,
        reverseReady = dodge.reverseReady == true,
        reversePauseUntil = dodge.reversePauseUntil,
        updatedAt = now,
    }
    dodge.humanoid:Move(currentDirection * dodge.footworkThrottle, false)
end

local function cleanup()
    if shuttingDown then return end
    shuttingDown = true
    activeDodge = nil
    kiteFocusCharacter = nil

    pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV7_3_Move") end)

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
    table.clear(footworkStateByCharacter)

    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
    gui, statusLabel, detailLabel, toggleButton = nil, nil, nil, nil
    indicatorDot, indicatorStroke, indicatorState = nil, nil, nil
    orbitBlockedUntil = 0
    kitePulseBlockedUntil = 0
    nextKiteSideChangeAt = 0
end

env.VD_AUTO_MANS_STOP = cleanup
_G.VD_AUTO_MANS_STOP = cleanup

pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV7_3_Move") end)
RunService:BindToRenderStep(
    "VD_AutoMansV7_3_Move",
    Enum.RenderPriority.Last.Value,
    guarded("steering", function()
        if shuttingDown then return end
        local dodge = activeDodge
        if not dodge then return end

        local now = os.clock()
        local dt = math.clamp(now - (dodge.lastFootworkAt or (now - 1 / 60)), 1 / 240, 1 / 25)
        dodge.lastFootworkAt = now
        if not CFG.Enabled or now >= dodge.finishAt then
            -- Simply release our render-step steering; normal player controls resume.
            if CFG.Enabled and dodge.orbiting then orbitBlockedUntil = now + CFG.OrbitCooldown end
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
        -- critical bubble, disappears, or the short side-cut timer expires.
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
        local shouldRetargetKite = dodge.kiting and now >= dodge.retargetAt
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

        applyFootwork(dodge, now, dt)
    end, function()
        -- On any error hand control straight back to the player.
        activeDodge = nil
    end)
)

connect(Players.PlayerAdded, watchPlayer)
connect(LocalPlayer.CharacterRemoving, function(character)
    footworkStateByCharacter[character] = nil
    if activeDodge and activeDodge.character == character then
        activeDodge = nil
    end
    kiteFocusCharacter = nil
    exclusionCache = nil
    exclusionCacheOwner = nil
end)
connect(LocalPlayer.CharacterAdded, function()
    activeDodge = nil
    kiteFocusCharacter = nil
    kitePulseBlockedUntil = 0
    nextKiteSideChangeAt = 0
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

    local kiteThreat = findKiteThreat(root)

    -- Prefer predicted emergencies, but use spacing movement to preserve distance
    -- from nearby players before their attack is already in contact range.
    local lead = latencyLead()
    if bestThreat and bestThreat.projectile then
        if (bestThreat.time or 1) <= 0.24 + lead then
            requestDodge(bestThreat, (bestThreat.time or 1) <= 0.14 + lead)
        end
    elseif bestThreat and bestThreat.targetCharacter
        and ((bestThreat.time or 1) <= 0.18 + lead or bestThreat.kind == "CRITICAL PROXIMITY") then
        requestDodge(bestThreat, true)
    elseif kiteThreat then
        -- Non-urgent short pulse: after it ends, the joystick gets an actual gap.
        requestDodge(kiteThreat, false)
    else
        kiteFocusCharacter = nil
    end
end, function()
    activeDodge = nil
end))

for _, player in ipairs(Players:GetPlayers()) do watchPlayer(player) end
makeUI()
setStatus("SCANNING", CFG.ThreatMode == "ANY_PLAYER" and "Any player • moving hazards" or "Detected killers • moving hazards")

-- Recreate only the small panel if PlayerGui/ScreenGui is removed or replaced.
-- This preserves the current ON/OFF state and does not restart the movement logic.
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
                warn("[VD Auto Mans V7.3] Panel repair failed: " .. tostring(err))
            end
        end
    end
end))
print("[VD Auto Mans V7.3] Pulse footwork loaded; live-match behavior is not verified.")
