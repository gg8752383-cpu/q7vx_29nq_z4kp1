-- Script -> ServerScriptService (серверный Script, НЕ LocalScript)
-- Хранит настройки панели Aim Assist в DataStore. Нужен только для сохранения между сессиями.
-- Для проверки в Studio включи: Game Settings > Security > Enable Studio Access to API Services.
-- ВАЖНО: DataStore привязан к конкретной игре (experience). Между разными играми
-- настройки не переносятся, в каждой игре с этим скриптом они хранятся отдельно.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STORE_NAME = "AimPanelSettings_v1"
local FOLDER_NAME = "AimPanelSettings" -- должно совпадать с CONFIG.REMOTES_FOLDER клиента
local SPEED_MIN, SPEED_MAX = 8, 50     -- должно совпадать с клиентом
local SAVE_DELAY = 5                   -- не чаще одной записи в 5 секунд на игрока
local MIN_EVENT_GAP = 0.3              -- защита от спама событиями
local RETRIES = 3

local function boolean(v)
	if type(v) == "boolean" then
		return v
	end
end

-- Строгая проверка каждого поля: клиенту нельзя доверять
local SANITIZE = {
	enabled = boolean,
	mode = function(v)
		if v == "ENEMIES" or v == "PLAYERS" or v == "NPC" then
			return v
		end
	end,
	strength = function(v)
		if type(v) == "number" and v == v then
			return math.clamp(math.floor(v + 0.5), 0, 100)
		end
	end,
	lineOfSight = boolean,
	aimPoint = function(v)
		if v == "Head" or v == "Torso" then
			return v
		end
	end,
	onlyWhileAiming = boolean,
	speedEnabled = boolean,
	speedValue = function(v)
		if type(v) == "number" and v == v then
			return math.clamp(math.floor(v + 0.5), SPEED_MIN, SPEED_MAX)
		end
	end,
}

local store = DataStoreService:GetDataStore(STORE_NAME)

local cache = {}     -- [userId] = проверенные настройки
local loading = {}   -- [userId] = true пока идёт чтение
local pending = {}   -- [userId] = изменения, ещё не записанные
local scheduled = {} -- [userId] = true если запись уже запланирована
local lastEvent = {} -- [userId] = os.clock() последнего события

-- Remotes
local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
if not folder then
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
end
local loadFn = folder:FindFirstChild("Load")
if not loadFn then
	loadFn = Instance.new("RemoteFunction")
	loadFn.Name = "Load"
	loadFn.Parent = folder
end
local saveEvt = folder:FindFirstChild("Save")
if not saveEvt then
	saveEvt = Instance.new("RemoteEvent")
	saveEvt.Name = "Save"
	saveEvt.Parent = folder
end
folder.Parent = ReplicatedStorage

local function sanitizeAll(raw)
	local out = {}
	if type(raw) == "table" then
		for key, fn in pairs(SANITIZE) do
			local v = fn(raw[key])
			if v ~= nil then
				out[key] = v
			end
		end
	end
	return out
end

local function readStored(userId)
	for attempt = 1, RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(tostring(userId))
		end)
		if ok then
			return true, result
		end
		warn(("[AimPanelSettings] GetAsync %d/%d: %s"):format(attempt, RETRIES, tostring(result)))
		task.wait(attempt)
	end
	return false, nil
end

local schedule

local function flush(userId)
	local changes = pending[userId]
	if not changes then
		return
	end
	pending[userId] = nil

	for attempt = 1, RETRIES do
		local ok, err = pcall(function()
			store:UpdateAsync(tostring(userId), function(old)
				-- слияние: старые и неизвестные поля НЕ теряются, обновляются только присланные
				local merged = {}
				if type(old) == "table" then
					for k, v in pairs(old) do
						merged[k] = v
					end
				end
				for k, v in pairs(changes) do
					merged[k] = v
				end
				return merged
			end)
		end)
		if ok then
			return
		end
		warn(("[AimPanelSettings] UpdateAsync %d/%d: %s"):format(attempt, RETRIES, tostring(err)))
		task.wait(attempt * 2)
	end

	-- не удалось: вернуть изменения в очередь (более новые значения имеют приоритет)
	local newer = pending[userId] or {}
	for k, v in pairs(changes) do
		if newer[k] == nil then
			newer[k] = v
		end
	end
	pending[userId] = newer
	if Players:GetPlayerByUserId(userId) then
		schedule(userId, 30)
	end
end

schedule = function(userId, delay)
	if scheduled[userId] then
		return
	end
	scheduled[userId] = true
	task.delay(delay or SAVE_DELAY, function()
		scheduled[userId] = nil
		flush(userId)
	end)
end

loadFn.OnServerInvoke = function(player)
	local userId = player.UserId
	if cache[userId] then
		return cache[userId]
	end
	if loading[userId] then
		while loading[userId] and player.Parent do
			task.wait(0.1)
		end
		return cache[userId]
	end
	loading[userId] = true
	local ok, raw = readStored(userId)
	loading[userId] = nil
	if not ok then
		return nil -- клиент поймёт, что загрузка не удалась, и не будет перезаписывать данные
	end
	cache[userId] = sanitizeAll(raw)
	return cache[userId]
end

saveEvt.OnServerEvent:Connect(function(player, payload)
	local userId = player.UserId
	local now = os.clock()
	if now - (lastEvent[userId] or 0) < MIN_EVENT_GAP then
		return
	end
	lastEvent[userId] = now
	if type(payload) ~= "table" then
		return
	end

	local changes = pending[userId] or {}
	local any = false
	for key, fn in pairs(SANITIZE) do
		local v = fn(payload[key])
		if v ~= nil then
			changes[key] = v
			any = true
		end
	end
	if not any then
		return
	end
	pending[userId] = changes
	if cache[userId] then
		for k, v in pairs(changes) do
			cache[userId][k] = v
		end
	end
	schedule(userId)
end)

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	task.spawn(function()
		flush(userId)
		cache[userId] = nil
		loading[userId] = nil
		lastEvent[userId] = nil
	end)
end)

game:BindToClose(function()
	local ids = {}
	for userId in pairs(pending) do
		ids[#ids + 1] = userId
	end
	local remaining = #ids
	for _, userId in ipairs(ids) do
		task.spawn(function()
			flush(userId)
			remaining -= 1
		end)
	end
	local started = os.clock()
	while remaining > 0 and os.clock() - started < 25 do
		task.wait(0.2)
	end
end)
