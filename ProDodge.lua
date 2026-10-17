-- =====================================================================
--  PRO DODGE v8  ·  Fight Arena
--  LocalScript  ->  StarterPlayer > StarterPlayerScripts
--
--  Как думает скрипт (по шагам):
--   1) ВИДИТ атаку:  анимации врагов (универсально, без ID),
--                    хитбоксы/зоны, летящие снаряды, рывки на тебя.
--   2) СЧИТАЕТ угрозу: форма поражения (конус/круг/сфера) + время удара
--                    (учится на каждом попадании и на ключевых кадрах).
--   3) НЕ дёргается зря: если стоишь в безопасной точке - ничего не делает.
--   4) ПЕРЕБИРАЕТ ТЕХНИКИ: шаг, рывок, диагональ, фланг, прыжок, блок,
--                    симулирует каждую до момента удара и берёт лучшую.
--   5) ТАЙМИНГ: стартует в последний момент (с поправкой на пинг),
--                    чтобы враг не успел довернуть.
--   6) НЕ ПОВТОРЯЕТСЯ: штраф за одно и то же движение подряд.
--   7) КОНТРА: враг промахнулся и "отдыхает" -> подходит и бьёт.
-- =====================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local LP = Players.LocalPlayer

----------------------------------------------------------------------
-- 1. НАСТРОЙКИ
----------------------------------------------------------------------
local CFG = {
	Enabled = true,
	Debug = false,         -- true = печатать решения в Output

	DetectRadius = 55,     -- кого вообще отслеживаем (студы)

	MeleeReach = 6.5,      -- базовая дальность удара (дальше учится сам)
	MeleeHalfWidth = 3.2,  -- полуширина удара
	SafeMargin = 1.6,      -- запас безопасности

	StepDist = 7,   StepTime = 0.13, StepCooldown = 0.28,   -- короткий шаг
	DashDist = 14,  DashTime = 0.18, DashCooldown = 0.85,   -- рывок
	JumpCooldown = 0.8,
	BlockCooldown = 0.5,

	UseJump = true,        -- прыжок как вариант уворота
	AutoBlock = true,      -- блок как запасной вариант (нужен BlockRemote)
	AutoCounter = true,    -- контратака после промаха врага (нужен AttackRemote)
	CounterRange = 6,
	CounterCooldown = 0.38,

	FaceTarget = true,     -- во время уворота смотреть на врага
	IgnoreTeammates = true,
	DetectParts = true,    -- хитбоксы и снаряды (parts в Workspace)
	Learn = true,          -- учиться на попаданиях
	Variety = true,        -- не повторять одно движение подряд
	Humanize = 0.02,       -- случайный разброс тайминга (сек)
}

----------------------------------------------------------------------
-- 2. РЕМОУТЫ БОЁВКИ  (поправь аргументы под свою CombatLocal)
----------------------------------------------------------------------
local remoteCache, remoteMiss = {}, {}

local function findRemote(name)
	local r = ReplicatedStorage:FindFirstChild(name, true)
	if not r then
		local ps = LP:FindFirstChild("PlayerScripts")
		if ps then r = ps:FindFirstChild(name, true) end
	end
	if r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then
		return r
	end
	return nil
end

local function getRemote(name)
	local r = remoteCache[name]
	if r and r.Parent then return r end
	local miss = remoteMiss[name]
	if miss and os.clock() - miss < 3 then return nil end
	r = findRemote(name)
	remoteCache[name] = r
	if not r then remoteMiss[name] = os.clock() end
	return r
end

local function callRemote(r, ...)
	if not r then return end
	local args = table.pack(...)
	task.spawn(function()
		pcall(function()
			if r:IsA("RemoteEvent") then
				r:FireServer(table.unpack(args, 1, args.n))
			else
				r:InvokeServer(table.unpack(args, 1, args.n))
			end
		end)
	end)
end

local Hooks = {
	HasBlock = function() return getRemote("BlockRemote") ~= nil end,
	Block = function(on) callRemote(getRemote("BlockRemote"), on) end,
	HasAttack = function() return getRemote("AttackRemote") ~= nil end,
	Attack = function() callRemote(getRemote("AttackRemote")) end,
}

----------------------------------------------------------------------
-- 3. СОСТОЯНИЕ И УТИЛИТЫ
----------------------------------------------------------------------
local me = { char = nil, hum = nil, root = nil }
local enemies = {}          -- [Model] = запись о враге
local meleeThreats = {}     -- угрозы от анимаций (живут ~0.5с)
local recentMelee = {}      -- последние угрозы для обучения
local tracked = {}          -- [BasePart] = запись (снаряды / хитбоксы)
local trackedCount = 0

local learnedDelay = {}     -- animKey -> через сколько сек после старта удар
local learnedReach = {}     -- animKey -> дальность удара
local learnedOmni = {}      -- animKey -> удар по кругу вокруг врага

local handled = setmetatable({}, { __mode = "k" })
local jitters = setmetatable({}, { __mode = "k" })
local noises = setmetatable({}, { __mode = "k" })

local history = {}          -- последние выбранные движения
local cd = { dash = 0, step = 0, jump = 0, block = 0 }
local dash = nil            -- активный рывок
local commitUntil = 0
local counter = nil
local faceTarget, faceUntil = nil, 0
local facingActive, prevAutoRotate = false, true
local lastMove = "-"
local lastMyAttack = -9
local lastHealth = 100
local marginBoost = 0
local cachedRTT, rttAt = 0.06, -9

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function dbg(...)
	if CFG.Debug then print("[ProDodge]", ...) end
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function unitFlat(v, fallback)
	local f = flat(v)
	if f.Magnitude < 0.01 then return fallback or Vector3.new(0, 0, -1) end
	return f.Unit
end

local function hasWord(s, list)
	for i = 1, #list do
		if string.find(s, list[i], 1, true) then return true end
	end
	return false
end

local function alive()
	return me.hum ~= nil and me.root ~= nil and me.root.Parent ~= nil and me.hum.Health > 0
end

local function getRTT(now)
	if now - rttAt > 0.5 then
		rttAt = now
		local ok, v = pcall(function()
			return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if ok and type(v) == "number" then
			cachedRTT = math.clamp(v / 1000, 0, 0.35)
		end
	end
	return cachedRTT
end

local function jitterFor(key)
	local j = jitters[key]
	if not j then
		j = (math.random() * 2 - 1) * CFG.Humanize
		jitters[key] = j
	end
	return j
end

local function noiseFor(key, name)
	local t = noises[key]
	if not t then
		t = {}
		noises[key] = t
	end
	local v = t[name]
	if not v then
		v = math.random() * 1.6 - 0.8
		t[name] = v
	end
	return v
end

local function repeatPenalty(name, now)
	local pen = 0
	for i = #history, 1, -1 do
		local h = history[i]
		if now - h.t > 4 then break end
		if h.name == name then pen = pen + 2.2 end
	end
	return pen
end

----------------------------------------------------------------------
-- 4. ДВИЖЕНИЕ: рывок / шаг, поворот к врагу
----------------------------------------------------------------------
local function stopDash()
	if dash then
		if dash.lv then dash.lv:Destroy() end
		if dash.att then dash.att:Destroy() end
		dash = nil
	end
end

local function startDash(dir, dist, dur)
	local root = me.root
	if not root then return end
	stopDash()
	local att = Instance.new("Attachment")
	att.Name = "PD_Att"
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "PD_Dash"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(1e6, 0, 1e6)
	lv.VectorVelocity = dir * (dist / dur * 2)
	lv.Parent = root
	dash = { lv = lv, att = att, dir = dir, dist = dist, dur = dur, t0 = os.clock() }
	commitUntil = os.clock() + dur + 0.05
end

local function updateDash(now)
	if not dash then return end
	if not alive() then
		stopDash()
		return
	end
	local p = (now - dash.t0) / dash.dur
	if p >= 1 then
		local vy = me.root.AssemblyLinearVelocity.Y
		stopDash()
		me.root.AssemblyLinearVelocity = Vector3.new(0, vy, 0)
		commitUntil = now + 0.04
		return
	end
	-- профиль скорости: быстрый старт, плавное торможение (интеграл = dist)
	dash.lv.VectorVelocity = dash.dir * (dash.dist / dash.dur * 2 * (1 - p))
end

local function setFace(root, untilT)
	faceTarget = root
	if untilT > faceUntil then faceUntil = untilT end
end

local function updateFace(now)
	if not CFG.FaceTarget or not alive() then return end
	local hum, root = me.hum, me.root
	if now < faceUntil and faceTarget and faceTarget.Parent then
		if not facingActive then
			facingActive = true
			prevAutoRotate = hum.AutoRotate
			hum.AutoRotate = false
		end
		local p = root.Position
		local dir = flat(faceTarget.Position - p)
		if dir.Magnitude > 0.5 then
			local goal = CFrame.lookAt(p, p + dir.Unit)
			root.CFrame = root.CFrame:Lerp(goal, 0.3)
		end
	elseif facingActive then
		facingActive = false
		hum.AutoRotate = prevAutoRotate
	end
end

local function resetCombat()
	stopDash()
	counter = nil
	faceUntil = 0
	if facingActive and me.hum then
		me.hum.AutoRotate = prevAutoRotate
	end
	facingActive = false
	for i = #meleeThreats, 1, -1 do
		local th = meleeThreats[i]
		if th.conn1 then th.conn1:Disconnect() end
		if th.conn2 then th.conn2:Disconnect() end
		meleeThreats[i] = nil
	end
	table.clear(tracked)
	trackedCount = 0
end

----------------------------------------------------------------------
-- 5. ЗРЕНИЕ #1: анимации врагов
----------------------------------------------------------------------
local NAME_ATTACK = {
	"attack", "punch", "slash", "swing", "hit", "m1", "m2", "combo", "kick", "strike",
	"slam", "smash", "skill", "ability", "cast", "heavy", "light", "uppercut", "sweep",
	"stab", "thrust", "bite", "claw", "chop", "jab", "hook", "lunge", "bash", "swipe",
	"melee", "fist", "sword", "axe", "spear", "knife", "shoot", "fire", "throw", "blast",
	"spin", "stomp", "crash", "ult", "special", "slice", "cleave", "barrage", "rush",
}
local NAME_IGNORE = {
	"idle", "walk", "run", "jump", "fall", "climb", "swim", "sit", "emote", "dance",
	"block", "guard", "parry", "equip", "unequip", "hurt", "stun", "death", "dead",
	"ragdoll", "getup", "land", "taunt", "cheer", "laugh", "salute", "toolnone", "pose",
	"hold", "aim", "reload", "knockback", "flinch", "dodge", "dash", "roll", "evade",
	"sprint", "crouch", "react", "gethit", "gothit", "stagger",
}
local NAME_OMNI = {
	"slam", "smash", "spin", "shockwave", "quake", "nova", "cyclone", "whirl", "aoe",
	"stomp", "crash", "burst", "explo", "ground", "ult",
}
local KEYFRAME_HIT = { "hit", "damage", "strike", "impact", "hitbox", "attack" }

local function isAttackTrack(track)
	local nm = string.lower(track.Name or "")
	if hasWord(nm, NAME_IGNORE) then return false end
	if hasWord(nm, NAME_ATTACK) then return true end
	local pv = track.Priority.Value
	local actionish = pv >= Enum.AnimationPriority.Action.Value and pv <= Enum.AnimationPriority.Action4.Value
	if actionish and not track.Looped then
		local len = track.Length
		if len == 0 or (len >= 0.2 and len <= 3) then return true end
	end
	return false
end

local function trackKey(track)
	local a = track.Animation
	if a and a.AnimationId ~= "" then return a.AnimationId end
	return track.Name
end

local function onEnemyTrack(e, track)
	if not CFG.Enabled or not me.root then return end
	if not isAttackTrack(track) then return end
	local now = os.clock()
	local key = trackKey(track)
	local speed = track.Speed
	if speed < 0.05 then speed = 1 end
	local len = track.Length
	if len < 0.05 then len = 0.7 end

	local delay = learnedDelay[key] or (math.clamp(len * 0.38, 0.12, 0.55) / speed)
	local omni = learnedOmni[key]
	if omni == nil then omni = hasWord(string.lower(track.Name), NAME_OMNI) end

	local th = {
		kind = "melee", src = track, enemy = e, key = key,
		t0 = now, hitAt = now + delay, active = 0.2,
		endAt = now + len / speed,
		reach = learnedReach[key] or CFG.MeleeReach,
		halfW = CFG.MeleeHalfWidth,
		omni = omni, radius = learnedReach[key] or 11,
		n = 5, t0w = now + delay - 0.04, t1w = now + delay + 0.2,
	}
	e.lastAttack = now
	meleeThreats[#meleeThreats + 1] = th
	recentMelee[#recentMelee + 1] = th
	if #recentMelee > 10 then table.remove(recentMelee, 1) end

	th.conn1 = track.Stopped:Connect(function() th.stopped = true end)
	th.conn2 = track.KeyframeReached:Connect(function(kf)
		if th.kfDone then return end
		if hasWord(string.lower(tostring(kf)), KEYFRAME_HIT) then
			th.kfDone = true
			learnedDelay[key] = os.clock() - th.t0
		end
	end)
end

local function trackHumanoid(hum)
	local model = hum.Parent
	if not model or not model:IsA("Model") or enemies[model] then return end
	if model == me.char then return end
	local plr = Players:GetPlayerFromCharacter(model)
	if plr == LP then return end
	if plr and CFG.IgnoreTeammates and plr.Team ~= nil and plr.Team == LP.Team then return end
	task.spawn(function()
		local root = model:WaitForChild("HumanoidRootPart", 6)
		if not root or enemies[model] then return end
		local e = { model = model, hum = hum, root = root, vel = Vector3.zero, conns = {}, lastAttack = -9 }
		enemies[model] = e
		local function hook(an)
			e.conns[#e.conns + 1] = an.AnimationPlayed:Connect(function(tr)
				onEnemyTrack(e, tr)
			end)
		end
		local an = hum:FindFirstChildOfClass("Animator")
		if an then hook(an) end
		e.conns[#e.conns + 1] = hum.ChildAdded:Connect(function(c)
			if c:IsA("Animator") then hook(c) end
		end)
	end)
end

local function updateEnemies()
	for model, e in pairs(enemies) do
		if not model.Parent or not e.root.Parent or e.hum.Health <= 0 then
			for _, c in ipairs(e.conns) do c:Disconnect() end
			enemies[model] = nil
		else
			e.vel = e.root.AssemblyLinearVelocity
		end
	end
end

local function nearestEnemy(pos)
	local best, bd = nil, 1e9
	for _, e in pairs(enemies) do
		local d = (e.root.Position - pos).Magnitude
		if d < bd then
			bd = d
			best = e
		end
	end
	return best, bd
end

----------------------------------------------------------------------
-- 6. ЗРЕНИЕ #2: хитбоксы и снаряды (parts)
----------------------------------------------------------------------
local function inCharacter(p)
	local a = p.Parent
	local depth = 0
	while a and a ~= Workspace and depth < 6 do
		if a:IsA("Model") and a:FindFirstChildOfClass("Humanoid") then return true end
		a = a.Parent
		depth = depth + 1
	end
	return false
end

local function enemyOrigin(pos, now)
	local e, dEn = nearestEnemy(pos)
	if not e then return false end
	local dMe = (pos - me.root.Position).Magnitude
	if dEn + 2.5 < dMe then return true end
	if now - e.lastAttack < 1.0 and dEn < 28 and now - lastMyAttack > 0.9 then return true end
	return false
end

local function registerPart(p, now)
	if tracked[p] or trackedCount >= 80 then return end
	if not p.Parent or p:IsA("Terrain") then return end
	local sz = p.Size
	local md = math.max(sz.X, sz.Y, sz.Z)
	if md < 1.2 or md > 90 then return end
	if p:FindFirstAncestorOfClass("Tool") then return end
	if (p.Position - me.root.Position).Magnitude > CFG.DetectRadius + 20 then return end
	if inCharacter(p) then return end
	if not enemyOrigin(p.Position, now) then return end
	tracked[p] = { part = p, born = now, last = p.Position, lastT = now, vel = Vector3.zero, n = 0 }
	trackedCount = trackedCount + 1
end

local function updateTracked(now)
	for p, r in pairs(tracked) do
		local drop = false
		if not p.Parent or now - r.born > 4 then
			drop = true
		else
			local pos = p.Position
			local dtt = now - r.lastT
			if dtt > 0.0001 then
				local v = (pos - r.last) / dtt
				if r.n == 0 then r.vel = v else r.vel = r.vel:Lerp(v, 0.5) end
				r.last = pos
				r.lastT = now
				r.n = r.n + 1
			end
			if r.n == 1 and inCharacter(p) then drop = true end
		end
		if drop then
			tracked[p] = nil
			trackedCount = trackedCount - 1
		end
	end
end

local function buildPartThreats(list, now, p0)
	for p, r in pairs(tracked) do
		local h = handled[p]
		if r.n >= 2 and not (h and h > now) then
			local speed = r.vel.Magnitude
			local size = p.Size
			local md = math.max(size.X, size.Y, size.Z)
			if speed > 22 then
				-- летящий снаряд
				local rad = math.clamp(md * 0.5, 1.2, 8)
				local rel = p0 - r.last
				local tcl = math.clamp(rel:Dot(r.vel) / (speed * speed), 0, 1.5)
				local miss = (rel - r.vel * tcl).Magnitude
				if miss < rad + CFG.SafeMargin + 3.5 then
					list[#list + 1] = {
						kind = "proj", src = p, pos = r.last, vel = r.vel, radius = rad,
						hitAt = now + tcl, t0w = now, t1w = now + math.min(tcl + 0.3, 1.5), n = 8,
					}
				end
			elseif now - r.born < 3 and speed < 10 then
				-- неподвижная зона (хитбокс / AoE)
				if (p.Position - p0).Magnitude < md * 0.5 + 18 then
					local hitAt = math.max(now, r.born + 0.12)
					list[#list + 1] = {
						kind = "zone", src = p, cf = p.CFrame, half = size * 0.5,
						ball = (p:IsA("Part") and p.Shape == Enum.PartType.Ball),
						hitAt = hitAt, t0w = hitAt, t1w = hitAt + 0.8, n = 5,
					}
				end
			end
		end
	end
end

local function buildLungeThreats(list, now, p0)
	for _, e in pairs(enemies) do
		local h = handled[e]
		if not (h and h > now) then
			local r = e.root
			local v = flat(r.AssemblyLinearVelocity)
			local sp = v.Magnitude
			if sp > 30 then
				local rel = flat(p0 - r.Position)
				local dist = rel.Magnitude
				if dist < 26 and dist > 0.1 and v.Unit:Dot(rel.Unit) > 0.8 then
					local tcl = math.max(0, (dist - 2.5) / sp)
					list[#list + 1] = {
						kind = "proj", src = e, enemy = e, pos = r.Position, vel = v, radius = 3.2,
						hitAt = now + tcl, t0w = now, t1w = now + tcl + 0.3, n = 8,
					}
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- 7. ГЕОМЕТРИЯ ОПАСНОСТИ: >0 безопасно, <0 попадёшь
----------------------------------------------------------------------
local function sdf(th, q, t, now)
	local k = th.kind
	if k == "melee" then
		local e = th.enemy
		local root = e.root
		if not root.Parent then return 99 end
		local dt = math.clamp(t - now, 0, 0.6)
		local pos = root.Position + flat(e.vel) * dt * 0.5
		local m = CFG.SafeMargin + marginBoost
		if th.omni then
			local d = flat(q - pos).Magnitude - th.radius - m
			local sy = math.abs(q.Y - pos.Y) - 4.5
			return math.max(d, sy)
		end
		local lv = unitFlat(root.CFrame.LookVector)
		local cf = CFrame.lookAt(pos, pos + lv)
		local lp = cf:PointToObjectSpace(q)
		local fz = -lp.Z
		local rem = math.max(0, th.hitAt - now)
		local ang = math.min(0.65, rem * 1.8)   -- враг ещё может довернуть
		local hx = th.halfW + m + math.max(0, fz) * math.tan(ang)
		local reach = th.reach + m * 0.5 + flat(e.vel).Magnitude * 0.12
		local sx = math.abs(lp.X) - hx
		local sz = math.max(fz - reach, -1.5 - fz)
		local sy = math.abs(lp.Y) - 4.5
		return math.max(sx, sz, sy)
	elseif k == "proj" then
		local p = th.pos + th.vel * (t - now)
		return (q - p).Magnitude - th.radius - 1.4 - (CFG.SafeMargin + marginBoost) * 0.5
	else
		local lp = th.cf:PointToObjectSpace(q)
		local m = (CFG.SafeMargin + marginBoost) * 0.9
		if th.ball then return lp.Magnitude - th.half.X - m end
		local d = Vector3.new(math.abs(lp.X) - th.half.X, math.abs(lp.Y) - th.half.Y, math.abs(lp.Z) - th.half.Z)
		local outside = Vector3.new(math.max(d.X, 0), math.max(d.Y, 0), math.max(d.Z, 0)).Magnitude
		local inside = math.min(math.max(d.X, math.max(d.Y, d.Z)), 0)
		return outside + inside - m
	end
end

local function originOf(th)
	if th.kind == "melee" then return th.enemy.root.Position end
	if th.kind == "zone" then return th.cf.Position end
	return th.pos
end

----------------------------------------------------------------------
-- 8. ТЕХНИКИ И ВЫБОР
----------------------------------------------------------------------
local function candPos(c, p0, t, ts)
	if c.kind == "move" then
		local p = math.clamp((t - ts) / c.dur, 0, 1)
		return p0 + c.dir * (c.dist * (1 - (1 - p) * (1 - p)))
	elseif c.kind == "jump" then
		local u = t - ts
		if u > 0 then
			local y = c.v0 * u - 0.5 * c.g * u * u
			if y > 0 then return p0 + Vector3.new(0, y, 0) end
		end
	end
	return p0
end

local function buildCands(p0, away, side, now, blockOK)
	local L = {}

	local function mv(name, dirRaw, dist, dur, key, cost)
		local d = flat(dirRaw)
		if d.Magnitude < 0.01 then return end
		d = d.Unit
		local hit = Workspace:Raycast(p0 + Vector3.new(0, 0.3, 0), d * (dist + 1.8), rayParams)
		if hit then dist = hit.Distance - 1.8 end
		if dist < 2.5 then return end
		local ground = Workspace:Raycast(p0 + d * dist + Vector3.new(0, 3, 0), Vector3.new(0, -18, 0), rayParams)
		if not ground then return end
		L[#L + 1] = {
			kind = "move", name = name, dir = d, dist = dist, dur = dur,
			cdKey = key, cost = cost, lead = dur * 0.75,
		}
	end

	local sd, st = CFG.StepDist, CFG.StepTime
	local dd, dt = CFG.DashDist, CFG.DashTime

	if now >= cd.step then
		mv("BACKSTEP", away, sd * 1.2, st, "step", 1.5)
		mv("SIDESTEP L", -side, sd, st, "step", 1.0)
		mv("SIDESTEP R", side, sd, st, "step", 1.0)
		mv("DIAG STEP L", away - side, sd * 1.15, st, "step", 1.4)
		mv("DIAG STEP R", away + side, sd * 1.15, st, "step", 1.4)
	end
	if now >= cd.dash then
		mv("DASH BACK", away, dd, dt, "dash", 4.0)
		mv("DASH L", -side, dd * 0.85, dt, "dash", 3.5)
		mv("DASH R", side, dd * 0.85, dt, "dash", 3.5)
		mv("DASH DIAG L", away - side, dd, dt, "dash", 4.0)
		mv("DASH DIAG R", away + side, dd, dt, "dash", 4.0)
		mv("FLANK L", -side - away * 0.6, dd * 0.8, dt, "dash", 3.0)
		mv("FLANK R", side - away * 0.6, dd * 0.8, dt, "dash", 3.0)
	end
	if CFG.UseJump and now >= cd.jump and me.hum.FloorMaterial ~= Enum.Material.Air then
		local g = Workspace.Gravity
		local h
		if me.hum.UseJumpPower then
			h = me.hum.JumpPower * me.hum.JumpPower / (2 * g)
		else
			h = me.hum.JumpHeight
		end
		local v0 = math.sqrt(2 * g * h)
		L[#L + 1] = { kind = "jump", name = "JUMP", cost = 3.0, lead = v0 / g, v0 = v0, g = g }
	end
	if blockOK then
		L[#L + 1] = { kind = "block", name = "BLOCK", cost = 4.0, lead = 0.05 }
	end
	L[#L + 1] = { kind = "hold", name = "HOLD", cost = 0, lead = 0 }
	return L
end

local function evaluate(c, list, primary, now, p0, rtt, jit)
	c.ts = math.max(now + 0.004, primary.hitAt - rtt - c.lead + jit)

	local minClr = 99
	if c.kind == "block" then
		minClr = 2.0
	else
		for i = 1, #list do
			local th = list[i]
			if th.hitAt <= primary.hitAt + 0.9 then
				local n = th.n or 5
				for k = 0, n - 1 do
					local t = th.t0w + (th.t1w - th.t0w) * (k / (n - 1))
					-- сервер видит нас с задержкой пинга
					local q = candPos(c, p0, t - rtt, c.ts)
					local s = sdf(th, q, t, now)
					if s < minClr then minClr = s end
				end
			end
		end
		if c.kind == "jump" then minClr = math.min(minClr, 1.5) end
	end

	local score
	if minClr >= 0 then
		score = math.min(minClr, 4) * 5
	else
		score = minClr * 10 - 30
	end
	score = score - c.cost

	if c.kind == "move" then
		local endP = p0 + c.dir * c.dist
		if primary.kind == "melee" then
			local o = primary.enemy.root.Position
			local dEnd = flat(endP - o).Magnitude
			-- остаёмся на дистанции контратаки
			if dEnd >= 2.5 and dEnd <= CFG.CounterRange + 2 then score = score + 3 end
			-- оказались сбоку / сзади врага
			local lp = CFrame.lookAt(o, o + unitFlat(primary.enemy.root.CFrame.LookVector)):PointToObjectSpace(endP)
			if -lp.Z < 1 then score = score + 2.5 end
		end
		-- не лезем к другим врагам
		for _, e in pairs(enemies) do
			if e ~= primary.enemy then
				if flat(endP - e.root.Position).Magnitude < 7 then score = score - 5 end
			end
		end
		score = score - c.dist * 0.12
	end

	if CFG.Variety and c.kind ~= "hold" then
		score = score - repeatPenalty(c.name, now) + noiseFor(primary.src or primary, c.name)
	end
	c.score = score
	return score
end

local function plan(list, now, p0)
	-- 1) кто реально угрожает, если стоять на месте
	local primary
	for i = 1, #list do
		local th = list[i]
		local worst = 99
		local n = th.n or 5
		for k = 0, n - 1 do
			local t = th.t0w + (th.t1w - th.t0w) * (k / (n - 1))
			local s = sdf(th, p0, t, now)
			if s < worst then worst = s end
		end
		th.holdClr = worst
		if not primary and worst < 1.0 then primary = th end
	end
	if not primary then return nil end

	-- 2) система координат угрозы
	local origin = originOf(primary)
	local back = -unitFlat(me.root.CFrame.LookVector)
	local away = unitFlat(p0 - origin, back)
	local side
	if primary.kind == "proj" then
		local vd = unitFlat(primary.vel)
		side = Vector3.new(-vd.Z, 0, vd.X)
	else
		side = Vector3.new(-away.Z, 0, away.X)
	end

	-- 3) блок только против ударов и снарядов
	local blockOK = CFG.AutoBlock and now >= cd.block and Hooks.HasBlock()
	if blockOK then
		for i = 1, #list do
			local th = list[i]
			if th.kind == "zone" and th.holdClr < 1.0 and th.hitAt <= primary.hitAt + 0.9 then
				blockOK = false
			end
		end
	end

	-- 4) пробуем все техники, берём лучшую
	local rtt = getRTT(now)
	local jit = jitterFor(primary.src or primary)
	local cands = buildCands(p0, away, side, now, blockOK)
	local best, bestScore
	for i = 1, #cands do
		local s = evaluate(cands[i], list, primary, now, p0, rtt, jit)
		if not bestScore or s > bestScore then
			best = cands[i]
			bestScore = s
		end
	end
	return best, primary, rtt
end

----------------------------------------------------------------------
-- 9. ИСПОЛНЕНИЕ, GUI, ОБУЧЕНИЕ, КОНТРАТАКА
----------------------------------------------------------------------
local ui = {}

local function refreshGui()
	if not ui.title then return end
	ui.title.Text = "PRO DODGE  ·  " .. lastMove
	local n = 0
	for _ in pairs(learnedDelay) do n = n + 1 end
	ui.info.Text = string.format("learned: %d   ping: %d ms", n, math.floor(cachedRTT * 1000))
end

local function execute(c, th, now)
	lastMove = c.name
	history[#history + 1] = { name = c.name, t = now }
	if #history > 12 then table.remove(history, 1) end
	handled[th.src or th] = now + 0.7
	th.handled = true

	if c.kind == "move" then
		cd[c.cdKey] = now + (c.cdKey == "dash" and CFG.DashCooldown or CFG.StepCooldown)
		startDash(c.dir, c.dist, c.dur)
	elseif c.kind == "jump" then
		cd.jump = now + CFG.JumpCooldown
		commitUntil = now + 0.3
		me.hum:ChangeState(Enum.HumanoidStateType.Jumping)
	elseif c.kind == "block" then
		cd.block = now + CFG.BlockCooldown
		Hooks.Block(true)
		local hold = math.max(0.18, th.hitAt + (th.active or 0.2) + 0.1 - now)
		task.delay(hold, function() Hooks.Block(false) end)
	end
	if th.enemy then setFace(th.enemy.root, now + 0.6) end
	dbg(c.name, th.kind, string.format("score %.1f", c.score or 0))
	refreshGui()
end

local function onDamaged(now)
	counter = nil
	if CFG.Learn and me.root then
		local best, bestDiff
		for i = #recentMelee, 1, -1 do
			local th = recentMelee[i]
			if th.enemy.root.Parent then
				local diff = math.abs(now - th.hitAt)
				if diff < 0.5 and (not bestDiff or diff < bestDiff) then
					best = th
					bestDiff = diff
				end
			end
		end
		if best then
			best.hurt = true
			local key = best.key
			local obs = now - best.t0
			if obs > 0.05 and obs < 1.2 then
				local old = learnedDelay[key]
				if old then learnedDelay[key] = old * 0.5 + obs * 0.5 else learnedDelay[key] = obs end
			end
			local er = best.enemy.root
			local d = flat(er.Position - me.root.Position).Magnitude
			learnedReach[key] = math.clamp(math.max(learnedReach[key] or 0, d + 0.8), CFG.MeleeReach, 30)
			local toMe = unitFlat(me.root.Position - er.Position)
			if unitFlat(er.CFrame.LookVector):Dot(toMe) < 0.35 then learnedOmni[key] = true end
			dbg("hit by", key, "delay", obs, "reach", learnedReach[key], "omni", learnedOmni[key])
		end
	end
	marginBoost = math.min(2.5, marginBoost + 0.35)
	refreshGui()
end

local function startCounter(e, untilT)
	counter = { e = e, untilT = untilT, lastAtk = 0 }
end

local function updateCounter(now)
	if not counter then return end
	local e = counter.e
	if now > counter.untilT or not CFG.AutoCounter or not e.root.Parent then
		counter = nil
		return
	end
	if dash or now < commitUntil then return end
	local d = flat(e.root.Position - me.root.Position)
	local dist = d.Magnitude
	if dist > 16 or dist < 0.1 then
		counter = nil
		return
	end
	setFace(e.root, now + 0.25)
	if dist > CFG.CounterRange - 0.5 then
		local adv = math.min(dist - 3.5, 9)
		if adv > 1.5 and now >= cd.step then
			cd.step = now + CFG.StepCooldown
			lastMove = "ADVANCE"
			startDash(d.Unit, adv, 0.14)
		end
	elseif now - counter.lastAtk > CFG.CounterCooldown and Hooks.HasAttack() then
		counter.lastAtk = now
		lastMove = "COUNTER"
		Hooks.Attack()
		refreshGui()
	end
end

local function gatherThreats(now, p0)
	local list = {}
	for i = #meleeThreats, 1, -1 do
		local th = meleeThreats[i]
		local root = th.enemy.root
		local gone = (th.stopped and now < th.hitAt - 0.05)
			or now > th.hitAt + th.active + 0.15
			or not root.Parent
		if not gone and not th.hurt and not th.cStarted and now > th.hitAt + th.active then
			th.cStarted = true
			if CFG.AutoCounter and th.endAt > now + 0.05 then
				if flat(root.Position - p0).Magnitude < CFG.CounterRange * 2.5 then
					startCounter(th.enemy, th.endAt + 0.1)
				end
			end
		end
		if gone then
			if th.conn1 then th.conn1:Disconnect() end
			if th.conn2 then th.conn2:Disconnect() end
			table.remove(meleeThreats, i)
		elseif not th.handled and now < th.hitAt + th.active
			and flat(root.Position - p0).Magnitude < CFG.DetectRadius then
			th.t0w = th.hitAt - 0.04
			th.t1w = th.hitAt + th.active
			list[#list + 1] = th
		end
	end
	buildPartThreats(list, now, p0)
	buildLungeThreats(list, now, p0)
	table.sort(list, function(a, b) return a.hitAt < b.hitAt end)
	return list
end

local function decide(now)
	if dash or now < commitUntil then return end
	local p0 = me.root.Position
	local list = gatherThreats(now, p0)
	if #list == 0 then return end
	local best, primary, rtt = plan(list, now, p0)
	if not best or best.kind == "hold" then return end
	-- старт в последний момент; если опаздываем - сразу
	if best.ts <= now + 0.017 or (primary.hitAt - rtt - now) < 0.04 then
		execute(best, primary, now)
	end
end

----------------------------------------------------------------------
-- 10. GUI (тап по кнопкам, удобно с телефона)
----------------------------------------------------------------------
local function makeGui()
	local pg = LP:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("ProDodgeGui")
	if old then old:Destroy() end

	local sg = Instance.new("ScreenGui")
	sg.Name = "ProDodgeGui"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 50
	sg.Parent = pg

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(206, 90)
	frame.Position = UDim2.new(0, 10, 0.5, -45)
	frame.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Parent = sg
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 10)
	fc.Parent = frame
	local fs = Instance.new("UIStroke")
	fs.Color = Color3.fromRGB(70, 75, 95)
	fs.Thickness = 1
	fs.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -16, 0, 20)
	title.Position = UDim2.fromOffset(8, 4)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 12
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(235, 235, 245)
	title.Parent = frame

	local info = Instance.new("TextLabel")
	info.BackgroundTransparency = 1
	info.Size = UDim2.new(1, -16, 0, 16)
	info.Position = UDim2.fromOffset(8, 24)
	info.Font = Enum.Font.Gotham
	info.TextSize = 11
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextColor3 = Color3.fromRGB(150, 155, 175)
	info.Parent = frame

	ui.title = title
	ui.info = info

	local function pill(label, idx, key)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(62, 28)
		b.Position = UDim2.fromOffset(8 + (idx - 1) * 66, 52)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 10
		b.Text = label
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		b.Parent = frame
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 8)
		bc.Parent = b
		local function paint()
			local on = CFG[key]
			if on then
				b.BackgroundColor3 = Color3.fromRGB(40, 150, 90)
				b.TextColor3 = Color3.new(1, 1, 1)
			else
				b.BackgroundColor3 = Color3.fromRGB(55, 58, 70)
				b.TextColor3 = Color3.fromRGB(170, 172, 185)
			end
		end
		b.Activated:Connect(function()
			CFG[key] = not CFG[key]
			paint()
			if key == "Enabled" and not CFG.Enabled then resetCombat() end
		end)
		paint()
	end
	pill("DODGE", 1, "Enabled")
	pill("JUMP", 2, "UseJump")
	pill("COUNTER", 3, "AutoCounter")
	refreshGui()
end

----------------------------------------------------------------------
-- 11. ПРИВЯЗКА К ПЕРСОНАЖУ И ГЛАВНЫЙ ЦИКЛ
----------------------------------------------------------------------
local function bindCharacter(char)
	local hum = char:WaitForChild("Humanoid")
	local root = char:WaitForChild("HumanoidRootPart")
	me.char, me.hum, me.root = char, hum, root
	rayParams.FilterDescendantsInstances = { char }
	resetCombat()
	table.clear(handled)
	marginBoost = 0
	lastHealth = hum.Health

	hum.HealthChanged:Connect(function(h)
		if h < lastHealth - 0.01 then onDamaged(os.clock()) end
		lastHealth = h
	end)

	local an = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 3)
	if an then
		an.AnimationPlayed:Connect(function(tr)
			if isAttackTrack(tr) then lastMyAttack = os.clock() end
		end)
	end
end

LP.CharacterAdded:Connect(bindCharacter)
if LP.Character then task.spawn(bindCharacter, LP.Character) end

Workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("Humanoid") then
		trackHumanoid(inst)
	elseif CFG.DetectParts and inst:IsA("BasePart") then
		task.defer(function()
			if inst.Parent and CFG.Enabled and alive() then
				registerPart(inst, os.clock())
			end
		end)
	end
end)

for _, d in ipairs(Workspace:GetDescendants()) do
	if d:IsA("Humanoid") then trackHumanoid(d) end
end

task.spawn(makeGui)

local guiAt = 0
RunService.Heartbeat:Connect(function(dt)
	local ok, err = pcall(function()
		local now = os.clock()
		marginBoost = math.max(0, marginBoost - dt * 0.08)
		if not CFG.Enabled or not alive() then
			if dash then stopDash() end
			return
		end
		updateEnemies()
		updateTracked(now)
		decide(now)
		updateDash(now)
		updateCounter(now)
		updateFace(now)
		if now - guiAt > 0.5 then
			guiAt = now
			refreshGui()
		end
	end)
	if not ok and CFG.Debug then warn("[ProDodge]", err) end
end)

print("[ProDodge v8] ready")
