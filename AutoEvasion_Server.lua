local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local REMOTE_NAME = "AutoEvasionRemote"

local CONFIG = {
    DetectionRadius = 82,
    ScanInterval = 0.075,
    MaxPartsPerScan = 140,
    MinimumHeuristicSpeed = 8,
    MaximumInferredSpeed = 360,

    PredictionHorizon = 1.20,
    PredictionStep = 0.035,
    BaseReactionThreshold = 0.22,
    PingFraction = 0.50,
    MaximumPingShift = 0.18,

    CharacterPadding = 0.55,
    CollisionSafetyMargin = 0.45,
    DefaultAOERadius = 8.0,
    DefaultInstantThreatRange = 28.0,
    DefaultExplicitProjectileGravityScale = 1.0,
    DefaultHeuristicGravityScale = 0.0,

    DodgeDuration = 0.30,
    MaximumDodgeSpeed = 28,
    MinimumDodgeSpeed = 11,
    DodgePathLength = 6.4,
    MinimumDodgeClearance = 2.45,
    MidDodgeWallCheckDistance = 1.05,
    MidDodgeWallCheckInterval = 0.045,
    DodgeCooldown = 0.42,
    SameThreatCooldown = 0.44,

    IFramesDuration = 0.24,
    PingPacketInterval = 0.25,
    TogglePacketInterval = 0.08,
    StatusUpdateInterval = 0.20,
}

local UP = Vector3.yAxis
local ZERO = Vector3.zero
local EPSILON = 1e-6

local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if remote and not remote:IsA("RemoteEvent") then
    error(REMOTE_NAME .. " exists but is not a RemoteEvent")
end

if not remote then
    remote = Instance.new("RemoteEvent")
    remote.Name = REMOTE_NAME
    remote.Parent = ReplicatedStorage
end

local playerStates = {}
local playerConnections = {}
local motionHistory = setmetatable({}, { __mode = "k" })

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.RespectCanCollide = false
overlapParams.MaxParts = CONFIG.MaxPartsPerScan
local overlapExclude = {}

overlapParams.FilterDescendantsInstances = overlapExclude

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
local raycastExclude = {}
raycastParams.FilterDescendantsInstances = raycastExclude

local function isFiniteNumber(value)
    return typeof(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function isFiniteVector(value)
    return typeof(value) == "Vector3"
        and isFiniteNumber(value.X)
        and isFiniteNumber(value.Y)
        and isFiniteNumber(value.Z)
end

local function safeUnit(vector)
    if not isFiniteVector(vector) then
        return ZERO
    end

    local magnitude = vector.Magnitude
    if not isFiniteNumber(magnitude) or magnitude <= EPSILON then
        return ZERO
    end

    return vector / magnitude
end

local function horizontalUnit(vector)
    if not isFiniteVector(vector) then
        return ZERO
    end

    return safeUnit(vector - UP * vector.Y)
end

local function readAttribute(source, fallbackPart, attributeName)
    if source then
        local value = source:GetAttribute(attributeName)
        if value ~= nil then
            return value
        end
    end

    if fallbackPart and fallbackPart ~= source then
        return fallbackPart:GetAttribute(attributeName)
    end

    return nil
end

local function readFirstNumberAttribute(source, fallbackPart, firstName, secondName)
    local value = readAttribute(source, fallbackPart, firstName)
    if isFiniteNumber(value) then
        return value
    end

    value = readAttribute(source, fallbackPart, secondName)
    if isFiniteNumber(value) then
        return value
    end

    return nil
end

local function normalizeThreatType(value)
    if typeof(value) ~= "string" then
        return nil
    end

    local kind = string.lower(value)
    kind = string.gsub(kind, "[%s_%-]", "")

    if kind == "aoe" or kind == "explosion" or kind == "grenade"
        or kind == "meteor" or kind == "areadamage" then
        return "AOE"
    end

    if kind == "instant" or kind == "hitscan" or kind == "raycast"
        or kind == "instantraycast" or kind == "meleeactive" then
        return "Instant"
    end

    if kind == "projectile" or kind == "pointprojectile"
        or kind == "ballistic" or kind == "movingthreat" then
        return "Projectile"
    end

    return nil
end

local function hasAnyTrueAttribute(instance, attributeNames)
    for index = 1, #attributeNames do
        if instance:GetAttribute(attributeNames[index]) == true then
            return true
        end
    end
    return false
end

local function getThreatMetadata(part)
    local node = part

    while node and node ~= Workspace do
        local configuredType = normalizeThreatType(node:GetAttribute("ThreatType"))
        local projectileTag = CollectionService:HasTag(node, "ProjectileThreat")
        local aoeTag = CollectionService:HasTag(node, "AOEThreat")
        local instantTag = CollectionService:HasTag(node, "InstantRaycastThreat")
        local activeAttribute = hasAnyTrueAttribute(node, {
            "ThreatActive",
            "ThreatTriggered",
            "AttackActive",
            "IsAttacking",
            "IsExploding",
        })

        if aoeTag then
            return node, "AOE", true, activeAttribute, true
        end

        if instantTag then
            return node, "Instant", true, true, true
        end

        if projectileTag then
            return node, "Projectile", true, activeAttribute, true
        end

        if configuredType then
            return node, configuredType, true, activeAttribute, false
        end

        if node:GetAttribute("IsProjectile") == true then
            return node, "Projectile", true, activeAttribute, false
        end

        if node:GetAttribute("IsThreat") == true then
            return node, nil, true, activeAttribute, false
        end

        if hasAnyTrueAttribute(node, { "AttackActive", "IsAttacking", "ThreatTriggered" }) then
            return node, "Instant", true, true, false
        end

        node = node.Parent
    end

    return part, nil, false, false, false
end

local function getSourcePart(source, fallbackPart)
    if not source then
        return fallbackPart
    end

    if source:IsA("BasePart") then
        return source
    end

    if source:IsA("Model") then
        if source.PrimaryPart and source.PrimaryPart:IsA("BasePart") then
            return source.PrimaryPart
        end

        local root = source:FindFirstChild("HumanoidRootPart")
        if root and root:IsA("BasePart") then
            return root
        end

        local anyPart = source:FindFirstChildWhichIsA("BasePart", true)
        if anyPart then
            return anyPart
        end
    end

    return fallbackPart
end

local function findHumanoidModel(instance)
    local node = instance
    while node and node ~= Workspace do
        if node:IsA("Model") and node:FindFirstChildOfClass("Humanoid") then
            return node
        end
        node = node.Parent
    end
    return nil
end

local function estimatePartVelocity(part, now)
    local physicalVelocity = ZERO
    local okVelocity, result = pcall(function()
        return part.AssemblyLinearVelocity
    end)

    if okVelocity and isFiniteVector(result) then
        physicalVelocity = result
    end

    local position = part.Position
    local previous = motionHistory[part]
    local inferredVelocity = ZERO

    if previous then
        local elapsed = now - previous.Time
        if elapsed >= 0.01 and elapsed <= 0.75 then
            local displacement = position - previous.Position
            inferredVelocity = displacement / elapsed
            if not isFiniteVector(inferredVelocity)
                or inferredVelocity.Magnitude > CONFIG.MaximumInferredSpeed then
                inferredVelocity = ZERO
            end
        end

        previous.Position = position
        previous.Time = now
        previous.Velocity = inferredVelocity
    else
        motionHistory[part] = {
            Position = position,
            Time = now,
            Velocity = ZERO,
        }
    end

    if physicalVelocity.Magnitude < 0.75 and inferredVelocity.Magnitude > physicalVelocity.Magnitude then
        return inferredVelocity
    end

    return physicalVelocity
end

local function getThreatVelocity(source, sourcePart, explicit, now)
    local attributeVelocity = readAttribute(source, sourcePart, "ProjectileVelocity")
    if not isFiniteVector(attributeVelocity) then
        attributeVelocity = readAttribute(source, sourcePart, "ThreatVelocity")
    end

    if isFiniteVector(attributeVelocity) then
        return attributeVelocity
    end

    local velocity = estimatePartVelocity(sourcePart, now)
    if not explicit and velocity.Magnitude < CONFIG.MinimumHeuristicSpeed then
        return nil
    end

    return velocity
end

local function getGravityScale(source, sourcePart, explicit)
    local usesGravity = readAttribute(source, sourcePart, "ProjectileUsesGravity")
    if usesGravity == false then
        return 0
    end

    local scale = readAttribute(source, sourcePart, "ProjectileGravityScale")
    if isFiniteNumber(scale) then
        return math.clamp(scale, 0, 4)
    end

    if explicit then
        return CONFIG.DefaultExplicitProjectileGravityScale
    end

    return CONFIG.DefaultHeuristicGravityScale
end

local function getThreatRadius(source, sourcePart)
    local configured = readFirstNumberAttribute(
        source,
        sourcePart,
        "ThreatRadius",
        "ProjectileRadius"
    )

    if configured then
        return math.clamp(configured, 0.2, 12)
    end

    local size = sourcePart.Size
    return math.clamp(math.max(size.X, size.Y, size.Z) * 0.5, 0.35, 4.5)
end

local function getAOERadius(source, sourcePart)
    local configured = readFirstNumberAttribute(
        source,
        sourcePart,
        "AOERadius",
        "ExplosionRadius"
    )

    if configured then
        return math.clamp(configured, 1, 45)
    end

    return CONFIG.DefaultAOERadius
end

local function getFuseSeconds(source, sourcePart)
    local fuse = readFirstNumberAttribute(
        source,
        sourcePart,
        "TimeToDetonate",
        "FuseRemaining"
    )

    if fuse then
        return math.clamp(fuse, 0, 60)
    end

    local serverDetonationTime = readAttribute(source, sourcePart, "DetonateAtServerTime")
    if isFiniteNumber(serverDetonationTime) then
        return math.clamp(serverDetonationTime - Workspace:GetServerTimeNow(), 0, 60)
    end

    return nil
end

local function isFriendlyThreat(player, character, source, sourcePart)
    local ownerId = readFirstNumberAttribute(
        source,
        sourcePart,
        "ProjectileOwnerUserId",
        "OwnerUserId"
    )

    if isFiniteNumber(ownerId) and ownerId == player.UserId then
        return true
    end

    local targetTeam = player.Team and player.Team.Name or character:GetAttribute("Team")
    local threatTeam = readAttribute(source, sourcePart, "ProjectileTeam")
    if threatTeam == nil then
        threatTeam = readAttribute(source, sourcePart, "ThreatTeam")
    end

    return typeof(targetTeam) == "string"
        and typeof(threatTeam) == "string"
        and targetTeam == threatTeam
end

local function getCharacterState(player)
    local character = player.Character
    if not character or not character.Parent then
        return nil, nil, nil, "NoCharacter"
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")

    if not humanoid then
        return character, nil, root, "NoHumanoid"
    end

    if not root or not root:IsA("BasePart") then
        return character, humanoid, nil, "NoRoot"
    end

    if humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead then
        return character, humanoid, root, "Dead"
    end

    if hasAnyTrueAttribute(character, {
        "Stunned", "Stun", "IsStunned", "CombatStunned", "StunLocked",
    }) or hasAnyTrueAttribute(humanoid, {
        "Stunned", "Stun", "IsStunned", "CombatStunned",
    }) then
        return character, humanoid, root, "Stunned"
    end

    if hasAnyTrueAttribute(character, {
        "Ragdolled", "Ragdoll", "IsRagdolled", "RagdollActive",
    }) or humanoid.PlatformStand then
        return character, humanoid, root, "Ragdolled"
    end

    if hasAnyTrueAttribute(character, {
        "IsAttacking", "Attacking", "AttackLocked", "IsUsingAbility", "CombatActionLocked",
    }) or hasAnyTrueAttribute(humanoid, {
        "IsAttacking", "Attacking", "AttackLocked",
    }) then
        return character, humanoid, root, "Attacking"
    end

    local stateType = humanoid:GetState()
    if stateType == Enum.HumanoidStateType.Ragdoll then
        return character, humanoid, root, "Ragdolled"
    end

    if humanoid.Sit then
        return character, humanoid, root, "Seated"
    end

    return character, humanoid, root, nil
end

local function firstContactTime(relativeStart, relativeVelocity, relativeAcceleration, radius, horizon, requestedStep)
    if not isFiniteVector(relativeStart)
        or not isFiniteVector(relativeVelocity)
        or not isFiniteVector(relativeAcceleration)
        or not isFiniteNumber(radius)
        or radius < 0 then
        return nil
    end

    local radiusSquared = radius * radius
    local initialDistanceSquared = relativeStart:Dot(relativeStart)
    if initialDistanceSquared <= radiusSquared then
        return 0
    end

    if horizon <= 0 then
        return nil
    end

    local stepCount = math.clamp(math.ceil(horizon / requestedStep), 1, 64)
    local step = horizon / stepCount
    local previousTime = 0
    local previous = relativeStart
    local previousDistanceSquared = initialDistanceSquared

    for index = 1, stepCount do
        local currentTime = index * step
        local current = relativeStart
            + relativeVelocity * currentTime
            + relativeAcceleration * (0.5 * currentTime * currentTime)
        local segment = current - previous
        local segmentLengthSquared = segment:Dot(segment)
        local closestAlpha = 0

        if segmentLengthSquared > EPSILON then
            closestAlpha = math.clamp(
                -previous:Dot(segment) / segmentLengthSquared,
                0,
                1
            )
        end

        local closestPoint = previous + segment * closestAlpha
        local closestDistanceSquared = closestPoint:Dot(closestPoint)

        if closestDistanceSquared <= radiusSquared then
            local contactAlpha = closestAlpha
            local quadraticA = segmentLengthSquared
            local quadraticB = 2 * previous:Dot(segment)
            local quadraticC = previousDistanceSquared - radiusSquared
            local discriminant = quadraticB * quadraticB
                - 4 * quadraticA * quadraticC

            if quadraticC > 0 and quadraticA > EPSILON and discriminant >= 0 then
                local firstRoot = (-quadraticB - math.sqrt(discriminant)) / (2 * quadraticA)
                if firstRoot >= 0 and firstRoot <= 1 then
                    contactAlpha = firstRoot
                end
            end

            local contactTime = previousTime + (currentTime - previousTime) * contactAlpha
            if isFiniteNumber(contactTime) then
                return math.max(0, contactTime)
            end
            return nil
        end

        previousTime = currentTime
        previous = current
        previousDistanceSquared = current:Dot(current)
    end

    return nil
end

local function isInsideTargetCharacter(instance, character)
    return instance == character or instance:IsDescendantOf(character)
end

local function makeThreatCandidate(player, character, humanoid, root, touchedPart, now, pingMs)
    if not touchedPart:IsA("BasePart") or not touchedPart.Parent then
        return nil
    end

    local source, kind, explicit, active, activeByTag = getThreatMetadata(touchedPart)
    local sourcePart = getSourcePart(source, touchedPart)
    if not sourcePart or not sourcePart.Parent then
        return nil
    end

    if isInsideTargetCharacter(sourcePart, character) or isInsideTargetCharacter(source, character) then
        return nil
    end

    if isFriendlyThreat(player, character, source, sourcePart) then
        return nil
    end

    if not explicit and findHumanoidModel(touchedPart) then
        return nil
    end

    local velocity = getThreatVelocity(source, sourcePart, explicit, now)
    if not velocity then
        return nil
    end

    if kind == nil then
        kind = "Projectile"
    end

    if kind == "Instant" then
        if not active then
            return nil
        end

        local distance = (sourcePart.Position - root.Position).Magnitude
        local configuredRange = readFirstNumberAttribute(
            source,
            sourcePart,
            "ThreatRange",
            "AttackRange"
        )
        local maximumRange = configuredRange
            and math.clamp(configuredRange, 1, CONFIG.DetectionRadius)
            or CONFIG.DefaultInstantThreatRange
        if not isFiniteNumber(distance) or distance > maximumRange then
            return nil
        end

        local shift = math.min(
            (pingMs / 1000) * CONFIG.PingFraction,
            CONFIG.MaximumPingShift
        )

        return {
            Source = source,
            Part = sourcePart,
            Kind = "Instant",
            Velocity = velocity,
            RawTTI = 0,
            EffectiveTTI = 0,
            PingShift = shift,
            ActiveByTag = activeByTag,
            AOEPosition = nil,
        }
    end

    if not explicit and velocity.Magnitude < CONFIG.MinimumHeuristicSpeed then
        return nil
    end

    if explicit and kind == "Projectile" and velocity.Magnitude < 0.15 then
        return nil
    end

    local rootVelocity = root.AssemblyLinearVelocity
    if not isFiniteVector(rootVelocity) then
        rootVelocity = ZERO
    end

    local relativePosition = sourcePart.Position - root.Position
    local relativeVelocity = velocity - rootVelocity
    local gravityScale = getGravityScale(source, sourcePart, explicit)
    local relativeAcceleration = -UP * (Workspace.Gravity * gravityScale)
    local rootRadius = math.max(root.Size.X, root.Size.Z) * 0.5 + CONFIG.CharacterPadding
    local threatRadius = getThreatRadius(source, sourcePart)
    local projectileCollisionRadius = rootRadius + threatRadius + CONFIG.CollisionSafetyMargin
    local rawTTI
    local aoePosition

    if kind == "AOE" then
        local aoeRadius = getAOERadius(source, sourcePart)
        local fuseSeconds = getFuseSeconds(source, sourcePart)
        local blastRadius = rootRadius + aoeRadius + CONFIG.CollisionSafetyMargin
        local distanceNow = (sourcePart.Position - root.Position).Magnitude
        local explosionActive = active

        if explosionActive and distanceNow <= blastRadius then
            rawTTI = 0
            aoePosition = sourcePart.Position
        elseif fuseSeconds ~= nil and fuseSeconds <= CONFIG.PredictionHorizon then
            local predictedExplosionPosition = sourcePart.Position
                + velocity * fuseSeconds
                + relativeAcceleration * (0.5 * fuseSeconds * fuseSeconds)
            local predictedPlayerPosition = root.Position + rootVelocity * fuseSeconds
            local predictedDistance = (predictedExplosionPosition - predictedPlayerPosition).Magnitude

            if predictedDistance <= blastRadius then
                rawTTI = fuseSeconds
                aoePosition = predictedExplosionPosition
            else
                rawTTI = firstContactTime(
                    relativePosition,
                    relativeVelocity,
                    relativeAcceleration,
                    projectileCollisionRadius,
                    CONFIG.PredictionHorizon,
                    CONFIG.PredictionStep
                )
            end
        else
            rawTTI = firstContactTime(
                relativePosition,
                relativeVelocity,
                relativeAcceleration,
                blastRadius,
                CONFIG.PredictionHorizon,
                CONFIG.PredictionStep
            )
            if rawTTI ~= nil then
                aoePosition = sourcePart.Position
                    + velocity * rawTTI
                    + relativeAcceleration * (0.5 * rawTTI * rawTTI)
            end
        end
    else
        rawTTI = firstContactTime(
            relativePosition,
            relativeVelocity,
            relativeAcceleration,
            projectileCollisionRadius,
            CONFIG.PredictionHorizon,
            CONFIG.PredictionStep
        )
    end

    if rawTTI == nil or not isFiniteNumber(rawTTI) then
        return nil
    end

    local pingShift = math.min(
        (pingMs / 1000) * CONFIG.PingFraction,
        CONFIG.MaximumPingShift
    )
    local effectiveTTI = math.max(0, rawTTI - pingShift)

    return {
        Source = source,
        Part = sourcePart,
        Kind = kind,
        Velocity = velocity,
        RawTTI = rawTTI,
        EffectiveTTI = effectiveTTI,
        PingShift = pingShift,
        AOEPosition = aoePosition,
        ActiveByTag = activeByTag,
    }
end

local function queryThreats(player, state, character, humanoid, root, now)
    overlapExclude[1] = character
    overlapParams.FilterDescendantsInstances = overlapExclude

    local ok, parts = pcall(function()
        return Workspace:GetPartBoundsInRadius(
            root.Position,
            CONFIG.DetectionRadius,
            overlapParams
        )
    end)

    if not ok or typeof(parts) ~= "table" then
        return nil
    end

    local seenSources = {}
    local best
    local partCount = math.min(#parts, CONFIG.MaxPartsPerScan)

    for index = 1, partCount do
        local part = parts[index]
        if part and part:IsA("BasePart") and part.Parent then
            local source = getThreatMetadata(part)
            if source and not seenSources[source] then
                seenSources[source] = true
                local candidate = makeThreatCandidate(
                    player,
                    character,
                    humanoid,
                    root,
                    part,
                    now,
                    state.PingMs
                )

                if candidate and (not best or candidate.EffectiveTTI < best.EffectiveTTI) then
                    best = candidate
                end
            end
        end
    end

    return best
end

local function setIFrames(character, enabled, untilServerTime)
    if not character or not character.Parent then
        return
    end

    character:SetAttribute("CombatIFrames", enabled == true)
    character:SetAttribute("CombatIFramesUntil", enabled and untilServerTime or 0)
end

local function stopDodge(state)
    local record = state.ActiveDodge
    if not record then
        return
    end

    state.ActiveDodge = nil

    if record.LinearVelocity and record.LinearVelocity.Parent then
        record.LinearVelocity:Destroy()
    end

    if record.Attachment and record.Attachment.Parent then
        record.Attachment:Destroy()
    end

    if record.Character and record.Character.Parent then
        setIFrames(record.Character, false, 0)
    end
end

local function updateStatus(player, state, key, detail, force)
    local now = os.clock()
    if not force and now - state.LastStatusSent < CONFIG.StatusUpdateInterval then
        if key == state.LastStatusKey then
            return
        end
    end

    state.LastStatusSent = now
    state.LastStatusKey = key
    state.LastStatusDetail = detail
    remote:FireClient(player, "Status", key, detail)
end

local function configureRaycastFilter(character, threatSource)
    raycastExclude[1] = character
    raycastExclude[2] = threatSource
    raycastParams.FilterDescendantsInstances = raycastExclude
end

local function measureClearance(character, root, direction, threatSource)
    configureRaycastFilter(character, threatSource)

    local unitDirection = horizontalUnit(direction)
    if unitDirection.Magnitude <= EPSILON then
        return 0
    end

    local side = safeUnit(unitDirection:Cross(UP))
    if side.Magnitude <= EPSILON then
        return 0
    end

    local height = math.clamp(root.Size.Y * 0.20, 0.35, 0.9)
    local baseOrigin = root.Position + UP * height
    local maxLength = CONFIG.DodgePathLength
    local smallestClearance = maxLength

    local originA = baseOrigin
    local originB = baseOrigin + side * 0.55
    local originC = baseOrigin - side * 0.55

    local origins = { originA, originB, originC }
    for index = 1, #origins do
        local origin = origins[index]
        local result = Workspace:Raycast(
            origin,
            unitDirection * maxLength,
            raycastParams
        )

        if result then
            local clearance = math.max(0, (result.Position - origin).Magnitude - 0.30)
            smallestClearance = math.min(smallestClearance, clearance)
        end
    end

    return smallestClearance
end

local function chooseDodgeDirection(character, root, threat)
    local threatSource = threat.Source

    if threat.Kind == "AOE" then
        local center = threat.AOEPosition or threat.Part.Position
        local away = horizontalUnit(root.Position - center)
        if away.Magnitude <= EPSILON then
            away = horizontalUnit(-threat.Velocity)
        end
        if away.Magnitude <= EPSILON then
            away = horizontalUnit(root.CFrame.RightVector)
        end
        if away.Magnitude <= EPSILON then
            return nil, 0, "NoAOEAwayVector"
        end

        local clearance = measureClearance(character, root, away, threatSource)
        if clearance < CONFIG.MinimumDodgeClearance then
            return nil, clearance, "AOEAwayPathBlocked"
        end

        return away, clearance, nil
    end

    local relativeVelocity = threat.Velocity - root.AssemblyLinearVelocity
    local lateral

    if threat.Kind == "Instant" then
        local attackDirection = horizontalUnit(root.Position - threat.Part.Position)
        lateral = attackDirection:Cross(UP)
    else
        lateral = horizontalUnit(relativeVelocity):Cross(UP)
    end

    lateral = horizontalUnit(lateral)

    if lateral.Magnitude <= EPSILON then
        lateral = horizontalUnit((threat.Part.Position - root.Position):Cross(UP))
    end
    if lateral.Magnitude <= EPSILON then
        lateral = horizontalUnit(root.CFrame.RightVector)
    end
    if lateral.Magnitude <= EPSILON then
        return nil, 0, "NoLateralVector"
    end

    local opposite = -lateral
    local clearanceA = measureClearance(character, root, lateral, threatSource)
    local clearanceB = measureClearance(character, root, opposite, threatSource)

    local direction = lateral
    local clearance = clearanceA
    if clearanceB > clearanceA then
        direction = opposite
        clearance = clearanceB
    end

    if clearance < CONFIG.MinimumDodgeClearance then
        return nil, clearance, "BothDodgePathsBlocked"
    end

    return direction, clearance, nil
end

local function getBlockedReason(player)
    local character, humanoid, root, reason = getCharacterState(player)
    if reason then
        return reason, character, humanoid, root
    end

    return nil, character, humanoid, root
end

local function startDodge(player, state, character, humanoid, root, threat, now)
    if state.ActiveDodge then
        return false, "AlreadyDodging"
    end

    if now - state.LastDodgeAt < CONFIG.DodgeCooldown then
        return false, "DodgeCooldown"
    end

    local lastThreatTime = state.LastThreatDodgeAt[threat.Source]
    if lastThreatTime and now - lastThreatTime < CONFIG.SameThreatCooldown then
        return false, "ThreatCooldown"
    end

    local blockedReason = getBlockedReason(player)
    if blockedReason then
        return false, blockedReason
    end

    local direction, clearance, directionError = chooseDodgeDirection(
        character,
        root,
        threat
    )

    if not direction then
        return false, directionError or "NoSafeDirection"
    end

    local availableDistance = math.max(0, math.min(clearance, CONFIG.DodgePathLength) - 0.35)
    local integratedProfileFactor = 2 / 3
    local peakSpeed = math.min(
        CONFIG.MaximumDodgeSpeed,
        availableDistance / (integratedProfileFactor * CONFIG.DodgeDuration)
    )

    if not isFiniteNumber(peakSpeed) or peakSpeed < CONFIG.MinimumDodgeSpeed then
        return false, "InsufficientClearance"
    end

    stopDodge(state)

    local attachment = Instance.new("Attachment")
    attachment.Name = "AutoEvasionAttachment"
    attachment.Parent = root

    local lateralAxis = safeUnit(direction:Cross(UP))
    if lateralAxis.Magnitude <= EPSILON then
        attachment:Destroy()
        return false, "InvalidPlaneAxis"
    end

    local linearVelocity = Instance.new("LinearVelocity")
    linearVelocity.Name = "AutoEvasionLinearVelocity"
    linearVelocity.Attachment0 = attachment
    linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
    linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
    linearVelocity.PrimaryTangentAxis = direction
    linearVelocity.SecondaryTangentAxis = lateralAxis
    linearVelocity.ForceLimitsEnabled = true
    linearVelocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
    linearVelocity.MaxForce = math.max(root.AssemblyMass * 9000, 32000)
    linearVelocity.PlaneVelocity = Vector2.zero
    linearVelocity.Parent = root

    local duration = CONFIG.DodgeDuration
    local iframeDuration = math.min(CONFIG.IFramesDuration, duration - 0.04)
    local iframeStartAt = now + (duration - iframeDuration) * 0.5
    local iframeEndAt = iframeStartAt + iframeDuration

    state.ActiveDodge = {
        Character = character,
        Humanoid = humanoid,
        Root = root,
        Direction = direction,
        PeakSpeed = peakSpeed,
        StartedAt = now,
        EndsAt = now + duration,
        IFrameStartAt = iframeStartAt,
        IFrameEndAt = iframeEndAt,
        IFramesStarted = false,
        IFramesEnded = false,
        NextWallCheckAt = now,
        Source = threat.Source,
        LinearVelocity = linearVelocity,
        Attachment = attachment,
    }

    state.LastDodgeAt = now
    state.LastThreatDodgeAt[threat.Source] = now

    remote:FireClient(player, "DodgeResult", true, "Started", threat.RawTTI, state.PingMs)
    updateStatus(
        player,
        state,
        "EVADING",
        string.format("TTI %.0f ms • ping %.0f ms", threat.RawTTI * 1000, state.PingMs),
        true
    )

    return true, "Started"
end

local function scanPlayer(player, state, now)
    local blockedReason, character, humanoid, root = getBlockedReason(player)
    if blockedReason then
        if state.ActiveDodge then
            stopDodge(state)
        end
        updateStatus(player, state, "BLOCKED", blockedReason, false)
        return
    end

    local threat = queryThreats(player, state, character, humanoid, root, now)
    if not threat then
        updateStatus(
            player,
            state,
            "CLEAR",
            string.format("No predicted hit • ping %.0f ms", state.PingMs),
            false
        )
        return
    end

    local reactionThreshold = CONFIG.BaseReactionThreshold
    if threat.EffectiveTTI > reactionThreshold then
        updateStatus(
            player,
            state,
            "THREAT",
            string.format(
                "Predicted in %.0f ms • ping %.0f ms",
                threat.EffectiveTTI * 1000,
                state.PingMs
            ),
            false
        )
        return
    end

    local started, reason = startDodge(
        player,
        state,
        character,
        humanoid,
        root,
        threat,
        now
    )

    if not started and reason ~= "DodgeCooldown" and reason ~= "ThreatCooldown" then
        updateStatus(player, state, "BLOCKED", reason, false)
    end
end

local function updateActiveDodge(player, state, now)
    local record = state.ActiveDodge
    if not record then
        return
    end

    if not state.Enabled
        or player.Character ~= record.Character
        or not record.Character.Parent
        or not record.Root.Parent
        or not record.Humanoid.Parent
        or not record.LinearVelocity
        or not record.LinearVelocity.Parent
        or not record.Attachment
        or not record.Attachment.Parent
        or record.Humanoid.Health <= 0 then
        stopDodge(state)
        return
    end

    local blockedReason = getBlockedReason(player)
    if blockedReason then
        stopDodge(state)
        updateStatus(player, state, "BLOCKED", blockedReason, true)
        return
    end

    if now >= record.NextWallCheckAt then
        record.NextWallCheckAt = now + CONFIG.MidDodgeWallCheckInterval
        configureRaycastFilter(record.Character, record.Source)
        local origin = record.Root.Position + UP * math.clamp(record.Root.Size.Y * 0.2, 0.35, 0.9)
        local wallHit = Workspace:Raycast(
            origin,
            record.Direction * CONFIG.MidDodgeWallCheckDistance,
            raycastParams
        )

        if wallHit then
            stopDodge(state)
            updateStatus(player, state, "BLOCKED", "Path changed: obstacle ahead", true)
            return
        end
    end

    if now >= record.IFrameStartAt and now < record.IFrameEndAt and not record.IFramesStarted then
        record.IFramesStarted = true
        setIFrames(
            record.Character,
            true,
            Workspace:GetServerTimeNow() + (record.IFrameEndAt - now)
        )
    end

    if record.IFramesStarted and not record.IFramesEnded and now >= record.IFrameEndAt then
        setIFrames(record.Character, false, 0)
        record.IFramesEnded = true
    end

    if now >= record.EndsAt then
        stopDodge(state)
        updateStatus(player, state, "ON", "Auto scanner ready", true)
        return
    end

    local alpha = math.clamp((now - record.StartedAt) / (record.EndsAt - record.StartedAt), 0, 1)
    local speedProfile = 4 * alpha * (1 - alpha)
    local targetSpeed = record.PeakSpeed * speedProfile

    if isFiniteNumber(targetSpeed) and targetSpeed >= 0 then
        record.LinearVelocity.PlaneVelocity = Vector2.new(targetSpeed, 0)
    end
end

local function makePlayerState(player)
    local existingState = playerStates[player]
    if existingState then
        return existingState
    end

    local state = {
        Enabled = false,
        PingMs = 0,
        ScanAccumulator = CONFIG.ScanInterval,
        LastPingPacketAt = -math.huge,
        LastTogglePacketAt = -math.huge,
        LastDodgeAt = -math.huge,
        LastThreatDodgeAt = setmetatable({}, { __mode = "k" }),
        LastStatusSent = -math.huge,
        LastStatusKey = nil,
        LastStatusDetail = nil,
        ActiveDodge = nil,
    }

    playerStates[player] = state
    player:SetAttribute("AutoEvasionEnabled", false)

    local connections = {}
    connections[#connections + 1] = player.CharacterAdded:Connect(function(character)
        stopDodge(state)
        character:SetAttribute("CombatIFrames", false)
        character:SetAttribute("CombatIFramesUntil", 0)
        if state.Enabled then
            state.ScanAccumulator = CONFIG.ScanInterval
            task.defer(function()
                if player.Parent and playerStates[player] == state then
                    updateStatus(player, state, "ON", "Reconnected after respawn", true)
                end
            end)
        end
    end)

    connections[#connections + 1] = player.CharacterRemoving:Connect(function()
        stopDodge(state)
    end)

    playerConnections[player] = connections
    return state
end

local function onRemoteEvent(player, action, value)
    if not player or not player.Parent then
        return
    end

    local state = playerStates[player]
    if not state then
        state = makePlayerState(player)
    end

    local now = os.clock()

    if action == "SetEnabled" then
        if typeof(value) ~= "boolean" then
            return
        end

        if value == state.Enabled then
            remote:FireClient(player, "State", state.Enabled, state.Enabled and "Threat scanner active" or "Tap to enable automatic dodging")
            return
        end

        if now - state.LastTogglePacketAt < CONFIG.TogglePacketInterval then
            remote:FireClient(player, "State", state.Enabled, state.Enabled and "Threat scanner active" or "Tap to enable automatic dodging")
            return
        end
        state.LastTogglePacketAt = now

        state.Enabled = value
        player:SetAttribute("AutoEvasionEnabled", value)

        if not value then
            stopDodge(state)
            updateStatus(player, state, "OFF", "Automatic evasion disabled", true)
        else
            state.ScanAccumulator = CONFIG.ScanInterval
            updateStatus(player, state, "ON", "Threat scanner active", true)
        end

        remote:FireClient(player, "State", state.Enabled, state.Enabled and "Threat scanner active" or "Tap to enable automatic dodging")
        return
    end

    if action == "Ping" then
        if not isFiniteNumber(value) then
            return
        end

        if now - state.LastPingPacketAt < CONFIG.PingPacketInterval then
            return
        end
        state.LastPingPacketAt = now

        if value >= 0 then
            state.PingMs = math.clamp(value, 0, 1000)
        end
        return
    end
end

remote.OnServerEvent:Connect(onRemoteEvent)

Players.PlayerAdded:Connect(makePlayerState)
Players.PlayerRemoving:Connect(function(player)
    local state = playerStates[player]
    if state then
        stopDodge(state)
        playerStates[player] = nil
    end

    local connections = playerConnections[player]
    if connections then
        for index = #connections, 1, -1 do
            local connection = connections[index]
            connections[index] = nil
            pcall(function()
                connection:Disconnect()
            end)
        end
    end
    playerConnections[player] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
    if not playerStates[player] then
        makePlayerState(player)
    end
end

RunService.Heartbeat:Connect(function(deltaTime)
    if not isFiniteNumber(deltaTime) or deltaTime <= 0 then
        return
    end

    local now = os.clock()

    for player, state in pairs(playerStates) do
        if player.Parent then
            local okDodge = pcall(updateActiveDodge, player, state, now)
            if not okDodge and state.ActiveDodge then
                stopDodge(state)
                updateStatus(player, state, "BLOCKED", "Maneuver safely canceled after a physics error", true)
            end

            if state.Enabled and not state.ActiveDodge then
                state.ScanAccumulator = state.ScanAccumulator + deltaTime
                if state.ScanAccumulator >= CONFIG.ScanInterval then
                    state.ScanAccumulator = state.ScanAccumulator % CONFIG.ScanInterval
                    local ok, err = pcall(scanPlayer, player, state, now)
                    if not ok then
                        if state.ActiveDodge then
                            stopDodge(state)
                        end
                        updateStatus(player, state, "BLOCKED", "Scanner recovered from an internal error", true)
                    end
                end
            end
        end
    end
end)
