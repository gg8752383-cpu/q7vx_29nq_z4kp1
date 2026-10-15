--[[
	UNIVERSAL AUTO EVADE ULTRA v2.0  (ZERO-TAG, чистая физика)
	Размещение: StarterPlayer > StarterPlayerScripts  (LocalScript)

	Никаких имён, тегов CollectionService и кастомных атрибутов в детекции. Только физика и геометрия.

	ТИПЫ УГРОЗ:
	  PROJ  Движущиеся детали. Скорость: AssemblyLinearVelocity (Anchored — по смещению между проверками).
	        Угроза, если Dot((M - P), V_rel) > 0 и траектория (с гравитацией Workspace.Gravity, если она
	        подтверждена измеренным ускорением) пересекает тело за TTI_adjusted <= TriggerLead.
	        Пересечение считается по хордам между точками траектории — быстрые снаряды не "туннелируют".
	  BEAM  Лазеры / трассеры / FastCast-лучи: вытянутая (aspect >= BeamAspect) тонкая деталь.
	        Вектор луча = длинная ось (CFrame.LookVector/RightVector/UpVector). Луч ловится сразу при появлении
	        (если деталь создана в Workspace недавно и не collidable) или при удлинении, и продлевается вперёд
	        на BeamLookahead секунд — реакция ДО того, как луч дорастёт до нас.
	  AOE   Растущая сфера / цилиндр / кольцо (деталь, у которой растёт Size). Радиус предсказывается вперёд,
	        уклонение СТРОГО из центра зоны наружу.

	ЧЕГО ФИЗИКА НЕ ВИДИТ (честно):
	  - Hitscan/Raycast-урон без какой-либо видимой детали (чистый серверный Raycast) — детали нет, ловить нечего.
	  - Зоны, которые появляются сразу полного размера и не растут: включи Config.FreshStaticZones = true
	    (ловит свежесозданные non-collidable части, возможны ложные срабатывания на VFX).

	ПРОИЗВОДИТЕЛЬНОСТЬ:
	  - В Heartbeat нет Vector3.new / создания таблиц / замыканий; вся математика предикта — на числах.
	  - Скан каждый 2-й кадр в спокойствии и каждый кадр при опасности (Config.CalmScanEvery / DangerScanEvery).
	  - Статичная Anchored-геометрия проверяется редко и вразнобой (кэш watch), а не каждый кадр.
	  - Неизбежные аллокации: массив результата GetPartBoundsInRadius (API создаёт его сам) и разовая запись
	    при первом появлении новой Anchored-детали в радиусе.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local AXIS_X, AXIS_Y, AXIS_Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis

-- =====================================================================
-- КОНФИГ
-- =====================================================================
local Config = {
	StartEnabled = true,
	Debug = false,
	NpcModel = nil,             -- Model NPC-компаньона (вместо персонажа игрока)

	-- Сканирование
	ScanRadius = 80,
	MaxScanParts = 1200,
	CalmScanEvery = 2,          -- кадров между сканами в спокойствии
	DangerScanEvery = 1,        -- кадров между сканами при опасности
	DangerTTI = 0.9,
	MinRelSpeed = 28,           -- минимальная относительная скорость PROJ (studs/s)
	MaxThreatSize = 24,         -- движущиеся детали крупнее считаются платформами
	MaxProjectileRadius = 6,
	IgnoreOtherCharacters = false,
	SlowPruneSeconds = 0.4,

	-- Предикт
	Horizon = 1.4,
	SampleStep = 0.04,
	TriggerLead = 0.42,
	BodyRadius = 2.4,
	BodyHalfHeight = 2.6,
	HitMargin = 1.2,

	-- Пинг: TTI_adjusted = TTI_base + PingSign * Ping/1000  (PingSign = -1 -> уклоняться раньше на величину пинга)
	PingSign = 1,
	PingMaxMs = 600,

	-- AOE (растущие зоны)
	AOEGrowthRate = 8,          -- рост максимального размера, studs/s
	AOEMinGrowthStep = 0.3,
	ZoneLookahead = 0.35,       -- на сколько секунд вперёд предсказываем радиус
	ZoneLinger = 1.2,
	MaxZoneRadius = 150,
	MinZoneDiameter = 5,
	FreshStaticZones = false,

	-- BEAM (лазеры / лучи)
	FreshBeams = true,
	FreshWindow = 0.4,          -- сколько секунд после создания детали она считается "свежей"
	BeamAspect = 5,
	BeamMaxThickness = 8,
	BeamLookahead = 0.15,
	BeamLinger = 0.5,

	-- Рывок (собственная механика на LinearVelocity)
	DashDistance = 15,
	DashMaxDistance = 30,
	DashMinDistance = 5,
	DashDuration = 0.2,
	DashAvgSpeed = 75,          -- длинные рывки растягиваются по времени: dur = max(DashDuration, D / DashAvgSpeed)
	DashCooldown = 0.85,
	DashForce = 1e7,
	PostDashSettle = 0.12,
	WallPadding = 1.6,
	VoidCheckDepth = 45,

	-- State Guard
	TreatZeroWalkSpeedAsStun = true,
	DetectRagdollConstraints = true,
	ExtraBlockCheck = nil,      -- function() -> true, если уклоняться нельзя
	OnDodge = nil,              -- function(dirVector3, distance) — хук для твоих iFrames/анимаций
}

-- =====================================================================
-- СОСТОЯНИЕ
-- =====================================================================
local Enabled = Config.StartEnabled
local pingMs = 0
local fsm = "Idle" -- Idle | Evading | Cooldown | Blocked | Disabled
local cachedReason = nil
local MIN_SP2 = Config.MinRelSpeed * Config.MinRelSpeed

local ctx = {
	char = nil, hum = nil, hrp = nil,
	lv = nil, att = nil,
	rayParams = nil, overlapParams = nil,
	conns = {},
	dashing = false, dashStart = 0, dashDur = 0.2, dashDir = Vector3.zero, dashPeak = 0,
	cooldownEnd = 0, settleUntil = 0,
	lastDirX = 0, lastDirZ = 0, lastDirTime = -10,
}

local threats = {}
local pool = {}
local watch = setmetatable({}, { __mode = "k" })
local bornAt = setmetatable({}, { __mode = "k" })
local scanIdx = 0
local stagger = 0
local frame = 0
local dangerUntil = 0

local active = {}
local activeN = 0

local MAXC = 48
local candX, candZ, candBonus, candScore, candUsed = {}, {}, {}, {}, {}
local candN = 0
local baseCos, baseSin = {}, {}
for i = 0, 11 do
	local a = i * (math.pi * 2 / 12)
	baseCos[i + 1] = math.cos(a)
	baseSin[i + 1] = math.sin(a)
end

local MOVER_CLASSES = { "BodyVelocity", "BodyForce", "BodyPosition", "BodyThrust", "LinearVelocity", "VectorForce", "AlignPosition" }

local BAD_STATES = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Seated] = true,
}

local refreshUI -- forward declaration

-- =====================================================================
-- ХЕЛПЕРЫ
-- =====================================================================
local function dbg(...)
	if Config.Debug then
		print("[UniversalAutoEvadeUltra]", ...)
	end
end

local function hasMover(part)
	for i = 1, #MOVER_CLASSES do
		if part:FindFirstChildWhichIsA(MOVER_CLASSES[i]) then
			return true
		end
	end
	return false
end

local function getTarget()
	return Config.NpcModel or LocalPlayer.Character
end

-- квадрат расстояния от точки до отрезка (origin + dir * [0..len])
local function segDist2(ox, oy, oz, dx, dy, dz, len, px, py, pz)
	local rx, ry, rz = px - ox, py - oy, pz - oz
	local t = rx * dx + ry * dy + rz * dz
	if t < 0 then
		t = 0
	elseif t > len then
		t = len
	end
	local qx, qy, qz = rx - dx * t, ry - dy * t, rz - dz * t
	return qx * qx + qy * qy + qz * qz
end

-- =====================================================================
-- STATE MACHINE GUARD
-- =====================================================================
local function guardReason()
	local char, hum, hrp = ctx.char, ctx.hum, ctx.hrp
	if not char or char.Parent == nil or not hum or hum.Parent == nil or not hrp or hrp.Parent == nil then
		return "NoCharacter"
	end
	if hum.Health <= 0 then
		return "Dead"
	end
	if BAD_STATES[hum:GetState()] then
		return "BadHumanoidState"
	end
	if hum.PlatformStand then
		return "PlatformStand"
	end
	if hum.Sit then
		return "Seated"
	end
	if hrp.Anchored then
		return "Anchored"
	end
	if Config.TreatZeroWalkSpeedAsStun and hum.WalkSpeed <= 0.05 then
		return "Rooted"
	end
	if Config.DetectRagdollConstraints then
		local bs = char:FindFirstChildWhichIsA("BallSocketConstraint", true)
		if bs and bs.Enabled then
			return "RagdollConstraints"
		end
	end
	if Config.ExtraBlockCheck then
		local ok, r = pcall(Config.ExtraBlockCheck)
		if ok and r then
			return "Custom"
		end
	end
	return nil
end

-- =====================================================================
-- ПИНГ
-- =====================================================================
local function updatePing()
	local ok, v = pcall(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	if ok and type(v) == "number" then
		v = math.clamp(v, 0, Config.PingMaxMs)
		if pingMs == 0 then
			pingMs = v
		else
			pingMs = pingMs * 0.5 + v * 0.5
		end
	end
end

-- =====================================================================
-- РЫВОК (собственная механика на LinearVelocity)
-- =====================================================================
local function endDash()
	local c = ctx
	if c.lv then
		c.lv.VectorVelocity = Vector3.zero
		c.lv.Enabled = false
	end
	if c.dashing then
		c.settleUntil = os.clock() + Config.PostDashSettle
	end
	c.dashing = false
end

local function startDash(now, dx, dz, dist)
	local c = ctx
	if not c.lv or not c.lv.Parent then
		return false
	end
	local dur = math.max(Config.DashDuration, dist / Config.DashAvgSpeed)
	c.dashDur = dur
	c.dashDir = AXIS_X * dx + AXIS_Z * dz
	c.dashPeak = 1.5 * dist / dur
	c.dashStart = now
	c.dashing = true
	c.cooldownEnd = now + Config.DashCooldown
	c.lastDirX, c.lastDirZ, c.lastDirTime = dx, dz, now
	c.lv.VectorVelocity = c.dashDir * c.dashPeak
	c.lv.Enabled = true
	if Config.OnDodge then
		pcall(Config.OnDodge, c.dashDir, dist)
	end
	dbg("dash", dx, dz, dist, dur)
	return true
end

-- =====================================================================
-- ДЕТЕКЦИЯ: записи, наблюдение, скан
-- =====================================================================
local function releaseRecord(rec)
	rec.part = nil
	pool[#pool + 1] = rec
end

-- kind: "Proj" | "AOE" | "Beam"; m = максимальный размер детали
local function newRecord(part, kind, now, px, py, pz, vx, vy, vz, m, growth)
	local rec = pool[#pool]
	if rec then
		pool[#pool] = nil
	else
		rec = {}
	end
	rec.part = part
	rec.kind = kind
	rec.firstSeen = now
	rec.lastSeen = now
	rec.t = now
	rec.px, rec.py, rec.pz = px, py, pz
	rec.vx, rec.vy, rec.vz = vx, vy, vz
	rec.s = m
	rec.growth = growth or 0
	rec.anchored = part.Anchored
	rec.samples = 0
	rec.tti, rec.baseTti = math.huge, math.huge
	rec.urgent = false
	rec.handledUntil = 0
	rec.dirx, rec.dirz, rec.hasDir = 0, 0, false
	rec.slowSince = 0
	rec.activeUntil = math.huge
	rec.gravity = false
	rec.accY = 0
	rec.hitR, rec.radius, rec.safeR, rec.halfY = 0, 0, 0, 0
	rec.ox, rec.oy, rec.oz, rec.ax, rec.ay, rec.az, rec.blen, rec.lim = 0, 0, 0, 0, 0, 0, 0, 0
	if kind == "Proj" then
		rec.radius = math.min(m * 0.5, Config.MaxProjectileRadius)
		rec.hitR = rec.radius + Config.BodyRadius + Config.HitMargin
		rec.gravity = (not rec.anchored) and not hasMover(part)
		rec.accY = rec.gravity and -Workspace.Gravity or 0
	elseif kind == "AOE" then
		rec.radius = math.min(m * 0.5, Config.MaxZoneRadius)
		rec.halfY = rec.radius
		rec.safeR = rec.radius + Config.BodyRadius + Config.HitMargin
		rec.activeUntil = now + Config.ZoneLinger
	else
		rec.activeUntil = now + Config.BeamLinger
	end
	return rec
end

local function clearThreats()
	for part, rec in pairs(threats) do
		threats[part] = nil
		releaseRecord(rec)
	end
	activeN = 0
end

local function updateRecord(rec, now)
	local part = rec.part
	local p = part.Position
	local px, py, pz = p.X, p.Y, p.Z
	local dt = now - rec.t
	if rec.kind == "Proj" then
		local vx, vy, vz
		local anch = part.Anchored
		rec.anchored = anch
		if anch then
			-- Anchored-деталь: скорость по смещению (Tween/CFrame-снаряды, FastCast)
			if dt > 0.004 then
				vx = rec.vx * 0.4 + ((px - rec.px) / dt) * 0.6
				vy = rec.vy * 0.4 + ((py - rec.py) / dt) * 0.6
				vz = rec.vz * 0.4 + ((pz - rec.pz) / dt) * 0.6
			else
				vx, vy, vz = rec.vx, rec.vy, rec.vz
			end
			rec.gravity = false
		else
			local v = part.AssemblyLinearVelocity
			vx, vy, vz = v.X, v.Y, v.Z
			if dt > 0.01 then
				-- измеряем реальное вертикальное ускорение: действует ли гравитация (дуги: гранаты, фаерболы)
				rec.accY = rec.accY * 0.7 + ((vy - rec.vy) / dt) * 0.3
				rec.samples += 1
				if rec.samples >= 4 then
					rec.gravity = rec.accY < -0.5 * Workspace.Gravity
				end
			end
		end
		rec.vx, rec.vy, rec.vz = vx, vy, vz
		rec.t = now
	else
		-- AOE / BEAM: следим за ростом размера
		local s = part.Size
		local m = math.max(s.X, s.Y, s.Z)
		if dt > 0.004 then
			local gr = (m - rec.s) / dt
			rec.growth = rec.growth * 0.6 + gr * 0.4
			if gr >= Config.AOEGrowthRate then
				local untilT = now + (rec.kind == "AOE" and Config.ZoneLinger or Config.BeamLinger)
				if untilT > rec.activeUntil then
					rec.activeUntil = untilT
				end
			end
			rec.s = m
			rec.t = now
		end
	end
	rec.px, rec.py, rec.pz = px, py, pz
	rec.lastSeen = now
end

local function acceptZone(part, myRoot)
	if part.AssemblyRootPart == myRoot then
		return false
	end
	if Config.IgnoreOtherCharacters then
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			return false
		end
	end
	return true
end

local function acceptProj(part, m, myRoot)
	if m > Config.MaxThreatSize then
		return false -- крупные движущиеся детали = платформы/геометрия
	end
	return acceptZone(part, myRoot)
end

-- Beam, если деталь вытянутая и тонкая, иначе AOE
local function zoneKind(s, m)
	local a, b, c3 = s.X, s.Y, s.Z
	local mn = math.min(a, b, c3)
	local mid = a + b + c3 - m - mn
	if m / math.max(mid, 0.05) >= Config.BeamAspect and mid <= Config.BeamMaxThickness then
		return "Beam"
	end
	return "AOE"
end

-- Свежесозданная non-collidable деталь: мгновенный лазер или (опционально) статичная зона
local function tryFresh(part, s, m, now, px, py, pz, myRoot)
	if part.CanCollide or not acceptZone(part, myRoot) then
		return
	end
	local kind = zoneKind(s, m)
	if kind == "Beam" then
		if Config.FreshBeams and m >= 4 then
			watch[part] = nil
			threats[part] = newRecord(part, "Beam", now, px, py, pz, 0, 0, 0, m, 0)
		end
	elseif Config.FreshStaticZones and m >= Config.MinZoneDiameter and m <= Config.MaxZoneRadius * 2 then
		watch[part] = nil
		threats[part] = newRecord(part, "AOE", now, px, py, pz, 0, 0, 0, m, 0)
	end
end

-- расписание повторной проверки Anchored-детали: сначала каждый скан (проба), потом редко и вразнобой
local function scheduleWatch(w)
	if w.n < 4 then
		w.n += 1
		w.next = scanIdx + 1
	else
		stagger = (stagger + 1) % 3
		w.next = scanIdx + 3 + stagger
	end
end

local function observePart(part, w, now, mvx, mvy, mvz, myRoot)
	if part.Anchored then
		local p = part.Position
		local px, py, pz = p.X, p.Y, p.Z
		local s = part.Size
		local m = math.max(s.X, s.Y, s.Z)
		if not w then
			w = { x = px, y = py, z = pz, t = now, s = m, n = 0, next = 0 }
			watch[part] = w
			scheduleWatch(w)
			local born = bornAt[part]
			if born and now - born <= Config.FreshWindow then
				tryFresh(part, s, m, now, px, py, pz, myRoot)
			end
			return
		end
		local dt = now - w.t
		if dt > 0.25 then
			-- отметка устарела: начинаем наблюдение заново
			w.x, w.y, w.z, w.t, w.s = px, py, pz, now, m
			w.n = 0
			scheduleWatch(w)
			return
		end
		if dt <= 0.004 then
			return
		end
		local vx, vy, vz = (px - w.x) / dt, (py - w.y) / dt, (pz - w.z) / dt
		local dm = m - w.s
		local growth = dm / dt
		w.x, w.y, w.z, w.t, w.s = px, py, pz, now, m
		local rvx, rvy, rvz = vx - mvx, vy - mvy, vz - mvz
		if rvx * rvx + rvy * rvy + rvz * rvz >= MIN_SP2 then
			if acceptProj(part, m, myRoot) then
				watch[part] = nil
				threats[part] = newRecord(part, "Proj", now, px, py, pz, vx, vy, vz, m, 0)
				return
			end
		elseif growth >= Config.AOEGrowthRate and dm >= Config.AOEMinGrowthStep then
			if acceptZone(part, myRoot) then
				watch[part] = nil
				threats[part] = newRecord(part, zoneKind(s, m), now, px, py, pz, 0, 0, 0, m, growth)
				return
			end
		end
		scheduleWatch(w)
	else
		if w then
			watch[part] = nil
		end
		local v = part.AssemblyLinearVelocity
		local vx, vy, vz = v.X, v.Y, v.Z
		local rvx, rvy, rvz = vx - mvx, vy - mvy, vz - mvz
		if rvx * rvx + rvy * rvy + rvz * rvz >= MIN_SP2 then
			local s = part.Size
			local m = math.max(s.X, s.Y, s.Z)
			if acceptProj(part, m, myRoot) then
				local p = part.Position
				threats[part] = newRecord(part, "Proj", now, p.X, p.Y, p.Z, vx, vy, vz, m, 0)
			end
		end
	end
end

local function prune(now)
	local slowLimit = Config.SlowPruneSeconds
	for part, rec in pairs(threats) do
		if rec.lastSeen < now - 0.2
			or part.Parent == nil
			or now > rec.activeUntil
			or (rec.slowSince > 0 and now - rec.slowSince > slowLimit) then
			threats[part] = nil
			releaseRecord(rec)
		end
	end
end

local function ScanForThreats(now)
	scanIdx += 1
	local c = ctx
	local hrp = c.hrp
	local hv = hrp.AssemblyLinearVelocity
	local mvx, mvy, mvz = hv.X, hv.Y, hv.Z
	local myRoot = hrp.AssemblyRootPart
	local parts = Workspace:GetPartBoundsInRadius(hrp.Position, Config.ScanRadius, c.overlapParams)
	local terrain = Workspace.Terrain
	for i = 1, #parts do
		local part = parts[i]
		local rec = threats[part]
		if rec then
			updateRecord(rec, now)
		elseif part ~= terrain then
			local w = watch[part]
			if not (w and w.next > scanIdx) then
				observePart(part, w, now, mvx, mvy, mvz, myRoot)
			end
		end
	end
	prune(now)
end

-- =====================================================================
-- ОЦЕНКА УГРОЗ (скалярная математика, без аллокаций)
-- =====================================================================
local function pushActive(rec)
	rec.urgent = true
	activeN += 1
	active[activeN] = rec
end

local function evalProj(rec, mx, my, mz, mvx, mvy, mvz, pingSec, grav, now)
	local rvx, rvy, rvz = rec.vx - mvx, rec.vy - mvy, rec.vz - mvz
	local sp2 = rvx * rvx + rvy * rvy + rvz * rvz
	if sp2 < MIN_SP2 then
		if rec.slowSince == 0 then
			rec.slowSince = now
		end
		return
	end
	rec.slowSince = 0

	local rx, ry, rz = rec.px - mx, rec.py - my, rec.pz - mz

	-- Dot((M - P), V_rel) > 0  <=>  объект движется в нашу сторону
	if -(rx * rvx + ry * rvy + rz * rvz) <= 0 then
		return
	end

	local R = rec.hitR
	local R2 = R * R
	local hh = Config.BodyHalfHeight
	local g = rec.gravity and -grav or 0
	local step = Config.SampleStep
	local horizon = Config.Horizon

	-- Параболическая траектория: p(t) = r + v*t + 0.5*g*t^2, проверка по ХОРДАМ между сэмплами
	local hitT = nil
	local x0, y0, z0 = rx, ry, rz
	local t0 = 0
	while t0 < horizon do
		local t1 = t0 + step
		local x1 = rx + rvx * t1
		local z1 = rz + rvz * t1
		local y1 = ry + rvy * t1 + 0.5 * g * t1 * t1
		local ex, ey, ez = x1 - x0, y1 - y0, z1 - z0
		local l2 = ex * ex + ey * ey + ez * ez
		local u = 0
		if l2 > 1e-9 then
			u = -(x0 * ex + y0 * ey + z0 * ez) / l2
			if u < 0 then
				u = 0
			elseif u > 1 then
				u = 1
			end
		end
		local qx, qy, qz = x0 + ex * u, y0 + ey * u, z0 + ez * u
		local ay = math.abs(qy) - hh
		if ay < 0 then
			ay = 0
		end
		local d2 = qx * qx + qz * qz + ay * ay
		if d2 <= R2 then
			local back = 0
			if l2 > 1e-9 then
				back = math.sqrt(R2 - d2) / (math.sqrt(l2) / step)
			end
			hitT = t0 + u * step - back
			if hitT < 0 then
				hitT = 0
			end
			break
		end
		x0, y0, z0 = x1, y1, z1
		t0 = t1
	end
	if hitT == nil then
		return
	end

	dangerUntil = now + 0.4
	local adj = hitT + Config.PingSign * pingSec
	if adj < 0 or hitT <= 0.001 then
		adj = 0
	end
	rec.baseTti = hitT
	rec.tti = adj

	local hs2 = rvx * rvx + rvz * rvz
	if hs2 >= 4 then
		local hs = math.sqrt(hs2)
		rec.dirx, rec.dirz, rec.hasDir = rvx / hs, rvz / hs, true
	else
		rec.hasDir = false
	end

	if adj <= Config.TriggerLead then
		pushActive(rec)
	end
end

local function evalAOE(rec, mx, my, mz, now)
	local part = rec.part
	local s = part.Size
	local sx, sy, sz = s.X, s.Y, s.Z
	local m = math.max(sx, sy, sz)
	local mn = math.min(sx, sy, sz)
	local radius = math.min(m * 0.5, Config.MaxZoneRadius)
	local grow = rec.growth
	if grow < 0 then
		grow = 0
	end
	-- радиус растёт со скоростью growth/2: предсказываем его вперёд
	local radP = radius + grow * 0.5 * Config.ZoneLookahead
	rec.radius = radius
	rec.safeR = radP + Config.BodyRadius + Config.HitMargin
	-- плоский диск/кольцо (тонкий по одной оси) имеет малую высоту, иначе считаем объём сферой
	if mn < 0.35 * m then
		rec.halfY = mn * 0.5 + 1
	else
		rec.halfY = radius
	end
	local dx, dz = mx - rec.px, mz - rec.pz
	local ay = math.abs(my - rec.py) - Config.BodyHalfHeight - rec.halfY
	if ay < 0 then
		ay = 0
	end
	if math.sqrt(dx * dx + dz * dz + ay * ay) > rec.safeR then
		return
	end
	rec.tti, rec.baseTti = 0, 0
	dangerUntil = now + 0.4
	pushActive(rec)
end

local function beamGeometry(rec)
	local part = rec.part
	local s = part.Size
	local cf = part.CFrame
	local axis, len, w
	if s.Z >= s.X and s.Z >= s.Y then
		axis, len, w = cf.LookVector, s.Z, math.max(s.X, s.Y)
	elseif s.X >= s.Y then
		axis, len, w = cf.RightVector, s.X, math.max(s.Y, s.Z)
	else
		axis, len, w = cf.UpVector, s.Y, math.max(s.X, s.Z)
	end
	local ext = rec.growth
	if ext < 0 then
		ext = 0
	end
	local L = len + ext * Config.BeamLookahead -- продлеваем растущий луч вперёд
	local c = cf.Position
	local h = L * 0.5
	rec.ox, rec.oy, rec.oz = c.X - axis.X * h, c.Y - axis.Y * h, c.Z - axis.Z * h
	rec.ax, rec.ay, rec.az = axis.X, axis.Y, axis.Z
	rec.blen = L
	rec.lim = w * 0.5 + Config.BodyHalfHeight * 0.9 + Config.HitMargin * 0.5
end

local function evalBeam(rec, mx, my, mz, now)
	beamGeometry(rec)
	local d2 = segDist2(rec.ox, rec.oy, rec.oz, rec.ax, rec.ay, rec.az, rec.blen, mx, my, mz)
	if d2 <= rec.lim * rec.lim then
		rec.tti, rec.baseTti = 0, 0
		dangerUntil = now + 0.4
		pushActive(rec)
	end
end

local function evaluate(now)
	activeN = 0
	local c = ctx
	local p = c.hrp.Position
	local v = c.hrp.AssemblyLinearVelocity
	local mx, my, mz = p.X, p.Y, p.Z
	local mvx, mvy, mvz = v.X, v.Y, v.Z
	local pingSec = pingMs / 1000
	local grav = Workspace.Gravity
	for _, rec in pairs(threats) do
		rec.urgent = false
		if now >= rec.handledUntil then
			local kind = rec.kind
			if kind == "Proj" then
				evalProj(rec, mx, my, mz, mvx, mvy, mvz, pingSec, grav, now)
			elseif kind == "AOE" then
				evalAOE(rec, mx, my, mz, now)
			else
				evalBeam(rec, mx, my, mz, now)
			end
		end
	end
end

-- =====================================================================
-- ПРИНЯТИЕ РЕШЕНИЯ (одно решение на пачку угроз)
-- =====================================================================
local function addCand(x, z, bonus)
	if candN >= MAXC then
		return
	end
	local m = math.sqrt(x * x + z * z)
	if m < 1e-4 then
		return
	end
	candN += 1
	candX[candN] = x / m
	candZ[candN] = z / m
	candBonus[candN] = bonus
	candScore[candN] = 0
	candUsed[candN] = false
end

-- смещение за время t при профиле рывка v(τ) = peak * (1 - τ²), суммарная дистанция D за dur секунд
local function dashDisp(t, D, delay, dur)
	local u = (t - delay) / dur
	if u <= 0 then
		return 0
	end
	if u >= 1 then
		return D
	end
	return D * 1.5 * (u - u * u * u / 3)
end

-- clearance < 0 означает попадание. Для скоринга берём абсолютную скорость объекта,
-- т.к. наша текущая скорость заменяется рывком. Проверка по хордам, как и в детекции.
local function projClearance(rec, cx, cz, D, dur, delay, mx, my, mz, grav)
	local rx, ry, rz = rec.px - mx, rec.py - my, rec.pz - mz
	local vx, vy, vz = rec.vx, rec.vy, rec.vz
	local g = rec.gravity and -grav or 0
	local tEnd = math.min(rec.baseTti + 0.3, Config.Horizon + 0.3)
	local step = Config.SampleStep
	local hh = Config.BodyHalfHeight
	local s0 = dashDisp(0, D, delay, dur)
	local x0 = rx - cx * s0
	local z0 = rz - cz * s0
	local y0 = ry
	local minD2 = math.huge
	local t0 = 0
	while t0 < tEnd do
		local t1 = t0 + step
		local s1 = dashDisp(t1, D, delay, dur)
		local x1 = rx + vx * t1 - cx * s1
		local z1 = rz + vz * t1 - cz * s1
		local y1 = ry + vy * t1 + 0.5 * g * t1 * t1
		local ex, ey, ez = x1 - x0, y1 - y0, z1 - z0
		local l2 = ex * ex + ey * ey + ez * ez
		local u = 0
		if l2 > 1e-9 then
			u = -(x0 * ex + y0 * ey + z0 * ez) / l2
			if u < 0 then
				u = 0
			elseif u > 1 then
				u = 1
			end
		end
		local qx, qy, qz = x0 + ex * u, y0 + ey * u, z0 + ez * u
		local ay = math.abs(qy) - hh
		if ay < 0 then
			ay = 0
		end
		local d2 = qx * qx + qz * qz + ay * ay
		if d2 < minD2 then
			minD2 = d2
		end
		x0, y0, z0 = x1, y1, z1
		t0 = t1
	end
	return math.sqrt(minD2) - rec.hitR
end

local function aoeClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
	local s = dashDisp(0.16 + delay, D, delay, dur)
	local dx = mx + cx * s - rec.px
	local dz = mz + cz * s - rec.pz
	local ay = math.abs(my - rec.py) - Config.BodyHalfHeight - rec.halfY
	if ay < 0 then
		ay = 0
	end
	return math.sqrt(dx * dx + dz * dz + ay * ay) - rec.safeR
end

local function beamClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
	local s = dashDisp(0.12 + delay, D, delay, dur)
	local d2 = segDist2(rec.ox, rec.oy, rec.oz, rec.ax, rec.ay, rec.az, rec.blen, mx + cx * s, my, mz + cz * s)
	return math.sqrt(d2) - rec.lim
end

-- Обязательная Raycast-проверка: стены (грудь/ноги/голова) + пустота под серединой и концом рывка.
-- Возвращает допустимую дистанцию или nil, причина ("wall" | "void").
local function validateCandidate(i, D)
	local c = ctx
	local origin = c.hrp.Position
	local dir = AXIS_X * candX[i] + AXIS_Z * candZ[i]
	local pad = Config.WallPadding
	local free = D
	local reach = dir * (D + pad)
	local hh = Config.BodyHalfHeight

	local r1 = Workspace:Raycast(origin, reach, c.rayParams)
	if r1 then
		free = math.min(free, r1.Distance - pad)
	end
	local r2 = Workspace:Raycast(origin - AXIS_Y * (hh * 0.8), reach, c.rayParams)
	if r2 then
		free = math.min(free, r2.Distance - pad)
	end
	local r3 = Workspace:Raycast(origin + AXIS_Y * (hh * 0.7), reach, c.rayParams)
	if r3 then
		free = math.min(free, r3.Distance - pad)
	end
	if free < Config.DashMinDistance then
		return nil, "wall"
	end

	-- Void Check: пол должен быть и в середине, и в конечной точке рывка
	local down = -AXIS_Y * Config.VoidCheckDepth
	if not Workspace:Raycast(origin + dir * (free * 0.5), down, c.rayParams) then
		return nil, "void"
	end
	if not Workspace:Raycast(origin + dir * free, down, c.rayParams) then
		return nil, "void"
	end
	return free, nil
end

local function decide(now)
	local c = ctx
	local p = c.hrp.Position
	local mx, my, mz = p.X, p.Y, p.Z
	local delay = pingMs / 2000
	local grav = Workspace.Gravity
	local look = c.hrp.CFrame.LookVector
	local hh = Config.BodyHalfHeight
	local D = Config.DashDistance

	candN = 0
	for i = 1, 12 do
		addCand(baseCos[i], baseSin[i], 0)
	end

	for i = 1, activeN do
		local rec = active[i]
		local kind = rec.kind
		if kind == "Proj" then
			if rec.hasDir then
				-- V_evasion = V_dir x Vector3.yAxis = (-dz, 0, dx)
				local sx, sz = -rec.dirz, rec.dirx
				local lat = (mx - rec.px) * sx + (mz - rec.pz) * sz
				local pref = lat >= 0 and 1 or -1
				addCand(sx * pref, sz * pref, -0.9)
				addCand(-sx * pref, -sz * pref, -0.6)
			else
				addCand(mx - rec.px, mz - rec.pz, -0.9) -- вертикальное падение: уходим горизонтально
			end
		elseif kind == "AOE" then
			-- СТРОГО из центра зоны наружу
			local ax, az = mx - rec.px, mz - rec.pz
			local hd2 = ax * ax + az * az
			local ay = math.abs(my - rec.py) - hh - rec.halfY
			if ay < 0 then
				ay = 0
			end
			local dist = math.sqrt(hd2 + ay * ay)
			if hd2 < 0.09 then
				ax, az = -look.X, -look.Z
			end
			addCand(ax, az, -2.5)
			local need = rec.safeR - dist + 1.5
			if need > D then
				D = math.min(need, Config.DashMaxDistance)
			end
		else
			-- BEAM: V_evasion = V_beam x Vector3.yAxis, в сторону от оси луча
			local rx, ry, rz = mx - rec.ox, my - rec.oy, mz - rec.oz
			local t = rx * rec.ax + ry * rec.ay + rz * rec.az
			if t < 0 then
				t = 0
			elseif t > rec.blen then
				t = rec.blen
			end
			local qx, qy, qz = rx - rec.ax * t, ry - rec.ay * t, rz - rec.az * t
			local dist = math.sqrt(qx * qx + qy * qy + qz * qz)
			local hs2 = rec.ax * rec.ax + rec.az * rec.az
			if hs2 >= 0.01 then
				local hs = math.sqrt(hs2)
				local ux, uz = rec.ax / hs, rec.az / hs
				local sx, sz = -uz, ux
				local pref = (qx * sx + qz * sz) >= 0 and 1 or -1
				addCand(sx * pref, sz * pref, -2.0)
				addCand(-sx * pref, -sz * pref, -0.6)
			else
				addCand(qx, qz, -2.0) -- вертикальный луч: уходим от оси
				addCand(-look.X, -look.Z, -0.5)
			end
			local need = rec.lim - dist + 1.5
			if need > D then
				D = math.min(need, Config.DashMaxDistance)
			end
		end
	end

	-- скоринг кандидатов (меньше = лучше)
	local dur = math.max(Config.DashDuration, D / Config.DashAvgSpeed)
	local repeatActive = now - c.lastDirTime < 1.6
	for i = 1, candN do
		local cx, cz = candX[i], candZ[i]
		local sc = candBonus[i]
		if repeatActive and cx * c.lastDirX + cz * c.lastDirZ > 0.7 then
			sc += 0.35 -- не повторяем одно и то же движение подряд
		end
		for k = 1, activeN do
			local rec = active[k]
			local kind = rec.kind
			local clearance, R
			if kind == "Proj" then
				clearance = projClearance(rec, cx, cz, D, dur, delay, mx, my, mz, grav)
				R = rec.hitR
			elseif kind == "AOE" then
				clearance = aoeClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
				R = rec.safeR
			else
				clearance = beamClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
				R = rec.lim
			end
			local urgency = math.min(6, 1.5 / (0.25 + rec.tti))
			if clearance < 0 then
				sc += math.min(1, -clearance / R) * urgency
			else
				sc -= math.min(0.4, clearance / R * 0.2)
			end
		end
		candScore[i] = sc
	end

	-- выбор лучшего с валидацией. Если направление упёрлось в стену или пустоту, сразу поощряем
	-- противоположное и противоположно-диагональные направления (dot <= -0.7).
	local chosen, chosenDist = 0, 0
	for _ = 1, 12 do
		local bi, bs = 0, math.huge
		for i = 1, candN do
			if not candUsed[i] and candScore[i] < bs then
				bi, bs = i, candScore[i]
			end
		end
		if bi == 0 then
			break
		end
		candUsed[bi] = true
		local d = validateCandidate(bi, D)
		if d then
			chosen, chosenDist = bi, d
			break
		end
		local fx, fz = candX[bi], candZ[bi]
		for j = 1, candN do
			if not candUsed[j] and candX[j] * fx + candZ[j] * fz <= -0.7 then
				candScore[j] -= 2
			end
		end
	end

	for i = 1, activeN do
		active[i].handledUntil = now + 0.6
	end

	if chosen > 0 then
		startDash(now, candX[chosen], candZ[chosen], chosenDist)
	end
end

-- =====================================================================
-- ШАГ ДВИЖКА И HEARTBEAT
-- =====================================================================
local function step(now)
	local c = ctx
	if c.dashing or now < c.settleUntil then
		return
	end
	ScanForThreats(now)
	evaluate(now)
	if activeN == 0 or now < c.cooldownEnd then
		return
	end
	dangerUntil = now + 0.4
	local reason = guardReason() -- свежая проверка прямо перед рывком
	if reason then
		cachedReason = reason
		return
	end
	decide(now)
end

local function updateState(now)
	local new
	if not Enabled then
		new = "Disabled"
	elseif cachedReason then
		new = "Blocked"
	elseif ctx.dashing then
		new = "Evading"
	elseif now < ctx.cooldownEnd then
		new = "Cooldown"
	else
		new = "Idle"
	end
	if new ~= fsm then
		fsm = new
		LocalPlayer:SetAttribute("AutoEvasionState", fsm)
	end
end

local guardAcc, pingAcc = 0, 0

local function onHeartbeat(dt)
	local c = ctx
	if not c.hrp then
		return
	end
	local now = os.clock()
	frame += 1

	if c.dashing then
		local lv = c.lv
		local el = now - c.dashStart
		if el >= c.dashDur or not lv or not lv.Parent or c.hum.Health <= 0 or cachedReason or not Enabled then
			endDash()
		else
			local tau = el / c.dashDur
			lv.VectorVelocity = c.dashDir * (c.dashPeak * (1 - tau * tau))
		end
	end

	pingAcc += dt
	if pingAcc >= 0.25 then
		pingAcc = 0
		updatePing()
	end

	guardAcc += dt
	if guardAcc >= 0.1 then
		guardAcc = 0
		cachedReason = guardReason()
	end

	updateState(now)
	if not Enabled or cachedReason then
		return
	end

	-- адаптивная частота скана: каждый 2-й кадр в спокойствии, каждый кадр при опасности
	local every = Config.CalmScanEvery
	if now < dangerUntil then
		every = Config.DangerScanEvery
	end
	if frame % every == 0 then
		step(now)
	end
end

-- =====================================================================
-- ПЕРСОНАЖ / NPC
-- =====================================================================
local function teardownCharacter()
	local c = ctx
	for i = #c.conns, 1, -1 do
		c.conns[i]:Disconnect()
		c.conns[i] = nil
	end
	c.dashing = false
	if c.lv then
		c.lv:Destroy()
	end
	if c.att then
		c.att:Destroy()
	end
	c.lv, c.att = nil, nil
	c.char, c.hum, c.hrp = nil, nil, nil
	c.rayParams, c.overlapParams = nil, nil
	c.cooldownEnd = 0
	c.settleUntil = 0
	clearThreats()
	cachedReason = "NoCharacter"
end

local function onCharacter(char)
	teardownCharacter()
	local hum = char:WaitForChild("Humanoid", 10)
	local hrp = char:WaitForChild("HumanoidRootPart", 10)
	if not hum or not hrp or getTarget() ~= char then
		return
	end
	local c = ctx
	c.char, c.hum, c.hrp = char, hum, hrp

	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	ray.FilterDescendantsInstances = { char }
	ray.RespectCanCollide = true
	c.rayParams = ray

	local ov = OverlapParams.new()
	ov.FilterType = Enum.RaycastFilterType.Exclude
	ov.FilterDescendantsInstances = { char } -- единственное исключение: детали самого персонажа
	ov.MaxParts = Config.MaxScanParts
	ov.RespectCanCollide = false
	c.overlapParams = ov

	local att = Instance.new("Attachment")
	att.Name = "AutoEvadeAttachment"
	att.Parent = hrp
	local lv = Instance.new("LinearVelocity")
	lv.Name = "AutoEvadeDash"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(Config.DashForce, 0, Config.DashForce) -- Y свободен: гравитация и прыжок работают
	lv.VectorVelocity = Vector3.zero
	lv.Enabled = false
	lv.Parent = hrp
	c.att, c.lv = att, lv

	c.conns[#c.conns + 1] = hum.Died:Connect(function()
		endDash()
		clearThreats()
		cachedReason = "Dead"
	end)
	c.conns[#c.conns + 1] = char.AncestryChanged:Connect(function()
		if not char:IsDescendantOf(game) and ctx.char == char then
			teardownCharacter()
		end
	end)

	cachedReason = nil
	pingAcc = 1 -- форсируем замер пинга сразу
	dbg("target ready")
end

-- =====================================================================
-- ПЕРЕКЛЮЧАТЕЛЬ ВКЛ/ВЫКЛ
-- =====================================================================
local function setEnabled(v)
	if Enabled == v then
		return
	end
	Enabled = v
	LocalPlayer:SetAttribute("AutoEvasionEnabled", v)
	if not v then
		endDash()
		clearThreats()
	end
	if refreshUI then
		refreshUI(true)
	end
end

-- =====================================================================
-- ЗАЩИЩЁННЫЙ UI-ТУМБЛЕР
-- =====================================================================
local COLOR_ON_BG = Color3.fromRGB(14, 52, 40)
local COLOR_OFF_BG = Color3.fromRGB(46, 22, 28)
local COLOR_ON = Color3.fromRGB(70, 255, 170)
local COLOR_OFF = Color3.fromRGB(255, 85, 95)
local TWEEN_FAST = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local UI = {
	gui = nil, button = nil, title = nil, status = nil, stroke = nil, dot = nil, scale = nil,
	conns = {},
	building = false,
	validateQueued = false,
	savedPos = UDim2.new(1, -52, 0.45, 0),
	rebuildStamps = {},
}

function refreshUI(animate)
	local b = UI.button
	if not b or not UI.status or not UI.stroke or not UI.dot then
		return
	end
	local on = Enabled
	local bg = on and COLOR_ON_BG or COLOR_OFF_BG
	local accent = on and COLOR_ON or COLOR_OFF
	UI.status.Text = on and "ON" or "OFF"
	if animate then
		TweenService:Create(b, TWEEN_FAST, { BackgroundColor3 = bg }):Play()
		TweenService:Create(UI.stroke, TWEEN_FAST, { Color = accent }):Play()
		TweenService:Create(UI.status, TWEEN_FAST, { TextColor3 = accent }):Play()
		TweenService:Create(UI.dot, TWEEN_FAST, { BackgroundColor3 = accent }):Play()
	else
		b.BackgroundColor3 = bg
		UI.stroke.Color = accent
		UI.status.TextColor3 = accent
		UI.dot.BackgroundColor3 = accent
	end
end

local function disconnectUI()
	for i = #UI.conns, 1, -1 do
		UI.conns[i]:Disconnect()
		UI.conns[i] = nil
	end
end

local function destroyUI()
	disconnectUI()
	local old = UI.gui
	UI.gui, UI.button, UI.title, UI.status, UI.stroke, UI.dot, UI.scale = nil, nil, nil, nil, nil, nil, nil
	if old then
		pcall(function()
			old:Destroy()
		end)
	end
end

local buildUI -- forward declaration

local function validateUI()
	if UI.building then
		return
	end
	local gui, button = UI.gui, UI.button
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local intact = gui ~= nil and button ~= nil and playerGui ~= nil
		and gui.Parent == playerGui
		and button.Parent == gui
		and UI.title ~= nil and UI.title.Parent == button
		and UI.status ~= nil and UI.status.Parent == button
		and UI.stroke ~= nil and UI.stroke.Parent == button
		and UI.dot ~= nil and UI.dot.Parent == button
	if not intact then
		-- защита от флуда пересозданий
		local now = os.clock()
		local stamps = UI.rebuildStamps
		for i = #stamps, 1, -1 do
			if now - stamps[i] > 2 then
				table.remove(stamps, i)
			end
		end
		stamps[#stamps + 1] = now
		if #stamps > 8 then
			task.wait(0.5)
		end
		buildUI()
		return
	end
	if not gui.Enabled then
		gui.Enabled = true
	end
	if not button.Visible then
		button.Visible = true
	end
end

local function queueValidate()
	if UI.validateQueued then
		return
	end
	UI.validateQueued = true
	task.defer(function()
		UI.validateQueued = false
		validateUI()
	end)
end

function buildUI()
	if UI.building then
		return
	end
	UI.building = true
	destroyUI()

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "UniversalAutoEvadeGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true

	local button = Instance.new("TextButton")
	button.Name = "ToggleButton"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Size = UDim2.fromOffset(64, 64)
	button.Position = UI.savedPos
	button.AutoButtonColor = false
	button.Text = ""
	button.Active = true
	button.BorderSizePixel = 0
	button.BackgroundColor3 = COLOR_OFF_BG
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = COLOR_OFF
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(165, 165, 180))
	gradient.Parent = button

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = button

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0)
	dot.Position = UDim2.new(0.5, 0, 0, 7)
	dot.Size = UDim2.fromOffset(8, 8)
	dot.BorderSizePixel = 0
	dot.BackgroundColor3 = COLOR_OFF
	dot.Parent = button
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 0, 0, 17)
	title.Size = UDim2.new(1, 0, 0, 18)
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 15
	title.TextColor3 = Color3.fromRGB(240, 240, 248)
	title.Text = "AUTO"
	title.Parent = button

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Position = UDim2.new(0, 0, 0, 35)
	status.Size = UDim2.new(1, 0, 0, 18)
	status.Font = Enum.Font.GothamBold
	status.TextSize = 14
	status.TextColor3 = COLOR_OFF
	status.Text = "OFF"
	status.Parent = button

	UI.gui, UI.button, UI.title, UI.status, UI.stroke, UI.dot, UI.scale = gui, button, title, status, stroke, dot, scale

	local function track(conn)
		UI.conns[#UI.conns + 1] = conn
		return conn
	end

	-- Защита от удаления / изменения
	track(gui.AncestryChanged:Connect(queueValidate))
	track(button.AncestryChanged:Connect(queueValidate))
	track(gui.DescendantRemoving:Connect(queueValidate))
	track(gui:GetPropertyChangedSignal("Enabled"):Connect(queueValidate))
	track(button:GetPropertyChangedSignal("Visible"):Connect(queueValidate))

	-- Тап = переключение, перетаскивание = перенос кнопки
	local pressInput, pressStart, startCenter, moved = nil, nil, nil, false

	track(button.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if pressInput == nil and (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1) then
			pressInput = input
			pressStart = input.Position
			startCenter = button.AbsolutePosition + button.AbsoluteSize * 0.5
			moved = false
			TweenService:Create(scale, TWEEN_FAST, { Scale = 0.9 }):Play()
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not pressInput then
			return
		end
		local isTouch = pressInput.UserInputType == Enum.UserInputType.Touch
		if (isTouch and input == pressInput) or (not isTouch and input.UserInputType == Enum.UserInputType.MouseMovement) then
			local d = input.Position - pressStart
			if moved or d.Magnitude > 10 then
				moved = true
				local vs = gui.AbsoluteSize
				if vs.X > 0 and vs.Y > 0 then
					local x = math.clamp(startCenter.X + d.X, 32, math.max(32, vs.X - 32))
					local y = math.clamp(startCenter.Y + d.Y, 32, math.max(32, vs.Y - 32))
					button.Position = UDim2.fromScale(x / vs.X, y / vs.Y)
					UI.savedPos = button.Position
				end
			end
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if not pressInput then
			return
		end
		local isTouch = pressInput.UserInputType == Enum.UserInputType.Touch
		local matches = (isTouch and input == pressInput) or (not isTouch and input.UserInputType == Enum.UserInputType.MouseButton1)
		if matches then
			local wasMoved = moved
			pressInput = nil
			TweenService:Create(scale, TWEEN_FAST, { Scale = 1 }):Play()
			if not wasMoved then
				setEnabled(not Enabled)
			end
		end
	end))

	gui.Parent = playerGui
	refreshUI(false)
	UI.building = false
end

-- =====================================================================
-- ЗАПУСК
-- =====================================================================
LocalPlayer:SetAttribute("AutoEvasionEnabled", Enabled)
LocalPlayer:SetAttribute("AutoEvasionState", fsm)

-- внешнее управление: LocalPlayer:SetAttribute("AutoEvasionEnabled", true/false)
LocalPlayer:GetAttributeChangedSignal("AutoEvasionEnabled"):Connect(function()
	local a = LocalPlayer:GetAttribute("AutoEvasionEnabled")
	if type(a) == "boolean" and a ~= Enabled then
		setEnabled(a)
	end
end)

-- момент создания деталей: нужен, чтобы отличать только что появившиеся лучи/зоны от старой геометрии карты
Workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("BasePart") then
		bornAt[inst] = os.clock()
	end
end)

buildUI()
local playerGuiRoot = LocalPlayer:WaitForChild("PlayerGui")
playerGuiRoot.ChildRemoved:Connect(function(child)
	if child == UI.gui or child.Name == "UniversalAutoEvadeGui" then
		queueValidate()
	end
end)

if Config.NpcModel then
	task.spawn(onCharacter, Config.NpcModel)
else
	LocalPlayer.CharacterAdded:Connect(onCharacter)
	if LocalPlayer.Character then
		task.spawn(onCharacter, LocalPlayer.Character)
	else
		cachedReason = "NoCharacter"
	end
end

RunService.Heartbeat:Connect(onHeartbeat)
