local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then
    return
end

local REMOTE_NAME = "AutoEvasionRemote"
local GUI_NAME = "AutoEvasionToggleGui"
local PING_UPDATE_INTERVAL = 0.45
local UI_WATCHDOG_INTERVAL = 0.40
local TOGGLE_KEY = Enum.KeyCode.Q

local remote = ReplicatedStorage:WaitForChild(REMOTE_NAME)
if not remote:IsA("RemoteEvent") then
    error(REMOTE_NAME .. " must be a RemoteEvent")
end

local running = true
local autoEnabled = player:GetAttribute("AutoEvasionEnabled") == true
local pingMs = -1
local pingAccumulator = 0
local uiAccumulator = 0
local ensureQueued = false
local screenGui
local panel
local toggleButton
local buttonGradient
local statusLabel
local detailLabel
local guiConnections = {}
local globalConnections = {}
local playerGui

local COLORS = {
    Panel = Color3.fromRGB(19, 23, 38),
    PanelBorder = Color3.fromRGB(75, 91, 130),
    Text = Color3.fromRGB(241, 245, 255),
    Muted = Color3.fromRGB(166, 177, 203),
    On = Color3.fromRGB(56, 205, 146),
    Off = Color3.fromRGB(104, 117, 145),
    Critical = Color3.fromRGB(255, 104, 115),
    BlueA = Color3.fromRGB(46, 125, 255),
    BlueB = Color3.fromRGB(141, 74, 255),
}

local function isFiniteNumber(value)
    return typeof(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function disconnectConnections(list)
    for index = #list, 1, -1 do
        local connection = list[index]
        list[index] = nil
        if connection then
            pcall(function()
                connection:Disconnect()
            end)
        end
    end
end

local function readPingMs()
    local item
    local okItem, resultItem = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]
    end)

    if okItem then
        item = resultItem
    end

    if not item then
        return nil
    end

    local okValue, value = pcall(function()
        return item:GetValue()
    end)

    if okValue and isFiniteNumber(value) then
        return math.clamp(value, 0, 1000)
    end

    local okText, text = pcall(function()
        return item:GetValueString()
    end)

    if okText and typeof(text) == "string" then
        local numericText = string.match(text, "[%d%.]+")
        local parsed = numericText and tonumber(numericText)
        if isFiniteNumber(parsed) then
            return math.clamp(parsed, 0, 1000)
        end
    end

    return nil
end

local function updateButton()
    if not toggleButton or not toggleButton.Parent then
        return
    end

    if autoEnabled then
        toggleButton.Text = "AUTO-EVADE\nON"
        toggleButton.BackgroundColor3 = COLORS.On
        toggleButton.TextColor3 = Color3.fromRGB(12, 33, 29)
        if buttonGradient then
            buttonGradient.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(84, 232, 170)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(33, 160, 112)),
            })
        end
    else
        toggleButton.Text = "AUTO-EVADE\nOFF"
        toggleButton.BackgroundColor3 = COLORS.Off
        toggleButton.TextColor3 = COLORS.Text
        if buttonGradient then
            buttonGradient.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, COLORS.BlueA),
                ColorSequenceKeypoint.new(1, COLORS.BlueB),
            })
        end
    end
end

local function updateStatus()
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = autoEnabled and "AUTO EVASION ENABLED" or "AUTO EVASION DISABLED"
        statusLabel.TextColor3 = autoEnabled and COLORS.On or COLORS.Muted
    end

    updateButton()
end

local scheduleEnsureUI

local function createUI()
    if not running then
        return
    end

    playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return
    end

    disconnectConnections(guiConnections)

    local oldGui = playerGui:FindFirstChild(GUI_NAME)
    if oldGui and oldGui ~= screenGui then
        oldGui:Destroy()
    end

    if screenGui and screenGui.Parent then
        screenGui:Destroy()
    end

    screenGui = Instance.new("ScreenGui")
    screenGui.Name = GUI_NAME
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 80
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.AnchorPoint = Vector2.new(1, 1)
    panel.Position = UDim2.new(1, -14, 1, -98)
    panel.Size = UDim2.fromOffset(304, 78)
    panel.BackgroundColor3 = COLORS.Panel
    panel.BackgroundTransparency = 0.08
    panel.BorderSizePixel = 0
    panel.Parent = screenGui

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 15)
    panelCorner.Parent = panel

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = COLORS.PanelBorder
    panelStroke.Thickness = 1.25
    panelStroke.Transparency = 0.15
    panelStroke.Parent = panel

    local panelGradient = Instance.new("UIGradient")
    panelGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 36, 59)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(15, 19, 32)),
    })
    panelGradient.Rotation = 15
    panelGradient.Parent = panel

    statusLabel = Instance.new("TextLabel")
    statusLabel.Name = "Status"
    statusLabel.BackgroundTransparency = 1
    statusLabel.Position = UDim2.fromOffset(13, 10)
    statusLabel.Size = UDim2.fromOffset(160, 23)
    statusLabel.Font = Enum.Font.GothamBold
    statusLabel.Text = "AUTO EVASION DISABLED"
    statusLabel.TextColor3 = COLORS.Muted
    statusLabel.TextSize = 12
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
    statusLabel.Parent = panel

    detailLabel = Instance.new("TextLabel")
    detailLabel.Name = "Details"
    detailLabel.BackgroundTransparency = 1
    detailLabel.Position = UDim2.fromOffset(13, 34)
    detailLabel.Size = UDim2.fromOffset(160, 32)
    detailLabel.Font = Enum.Font.Gotham
    detailLabel.Text = "Tap to enable automatic dodging"
    detailLabel.TextColor3 = COLORS.Muted
    detailLabel.TextSize = 10
    detailLabel.TextWrapped = true
    detailLabel.TextXAlignment = Enum.TextXAlignment.Left
    detailLabel.TextYAlignment = Enum.TextYAlignment.Center
    detailLabel.Parent = panel

    toggleButton = Instance.new("TextButton")
    toggleButton.Name = "AutoEvasionToggle"
    toggleButton.AnchorPoint = Vector2.new(1, 0.5)
    toggleButton.Position = UDim2.new(1, -10, 0.5, 0)
    toggleButton.Size = UDim2.fromOffset(119, 58)
    toggleButton.BackgroundColor3 = COLORS.Off
    toggleButton.BorderSizePixel = 0
    toggleButton.AutoButtonColor = false
    toggleButton.Font = Enum.Font.GothamBold
    toggleButton.Text = "AUTO-EVADE\nOFF"
    toggleButton.TextColor3 = COLORS.Text
    toggleButton.TextSize = 13
    toggleButton.TextWrapped = true
    toggleButton.Parent = panel

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 13)
    buttonCorner.Parent = toggleButton

    buttonGradient = Instance.new("UIGradient")
    buttonGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, COLORS.BlueA),
        ColorSequenceKeypoint.new(1, COLORS.BlueB),
    })
    buttonGradient.Rotation = 28
    buttonGradient.Parent = toggleButton

    local buttonStroke = Instance.new("UIStroke")
    buttonStroke.Color = Color3.fromRGB(230, 238, 255)
    buttonStroke.Transparency = 0.28
    buttonStroke.Thickness = 1.2
    buttonStroke.Parent = toggleButton

    local buttonScale = Instance.new("UIScale")
    buttonScale.Name = "PressScale"
    buttonScale.Scale = 1
    buttonScale.Parent = toggleButton

    guiConnections[#guiConnections + 1] = toggleButton.Activated:Connect(function()
        autoEnabled = not autoEnabled
        updateStatus()
        remote:FireServer("SetEnabled", autoEnabled)
    end)

    guiConnections[#guiConnections + 1] = toggleButton.AncestryChanged:Connect(function(_, newParent)
        if newParent ~= panel then
            scheduleEnsureUI()
        end
    end)

    guiConnections[#guiConnections + 1] = screenGui.AncestryChanged:Connect(function(_, newParent)
        if newParent ~= playerGui then
            scheduleEnsureUI()
        end
    end)

    guiConnections[#guiConnections + 1] = panel.AncestryChanged:Connect(function(_, newParent)
        if newParent ~= screenGui then
            scheduleEnsureUI()
        end
    end)

    screenGui.Parent = playerGui
    updateStatus()
end

scheduleEnsureUI = function()
    if ensureQueued or not running then
        return
    end

    ensureQueued = true
    task.defer(function()
        ensureQueued = false
        if running then
            local currentPlayerGui = player:FindFirstChildOfClass("PlayerGui")
            if currentPlayerGui ~= playerGui
                or not screenGui
                or screenGui.Parent ~= currentPlayerGui
                or not panel
                or panel.Parent ~= screenGui
                or not toggleButton
                or toggleButton.Parent ~= panel then
                createUI()
            end
        end
    end)
end

local function setStatus(key, detail)
    if detailLabel and detailLabel.Parent then
        detailLabel.Text = tostring(detail or "")
    end

    if statusLabel and statusLabel.Parent then
        local textByKey = {
            OFF = "AUTO EVASION DISABLED",
            ON = "AUTO EVASION ENABLED",
            CLEAR = "SCANNING • CLEAR",
            THREAT = "THREAT DETECTED",
            EVADING = "AUTO-EVASION ACTIVE",
            BLOCKED = "MANEUVER BLOCKED",
            READY = "AUTO EVASION READY",
        }
        statusLabel.Text = textByKey[key] or tostring(key or "AUTO EVASION")
        if key == "THREAT" or key == "EVADING" then
            statusLabel.TextColor3 = COLORS.Critical
        elseif key == "ON" or key == "CLEAR" or key == "READY" then
            statusLabel.TextColor3 = COLORS.On
        else
            statusLabel.TextColor3 = autoEnabled and COLORS.On or COLORS.Muted
        end
    end

    updateButton()
end

local function setEnabled(value, sendToServer)
    autoEnabled = value == true
    updateStatus()
    if sendToServer then
        remote:FireServer("SetEnabled", autoEnabled)
    end
end

local function handleServerMessage(action, a, b, c, d)
    if action == "State" then
        setEnabled(a == true, false)
        if autoEnabled then
            setStatus("ON", typeof(b) == "string" and b or "Threat scanner active")
        else
            setStatus("OFF", typeof(b) == "string" and b or "Tap to enable automatic dodging")
        end
    elseif action == "Status" then
        setStatus(a, b)
    elseif action == "DodgeResult" then
        if a == true then
            local tti = isFiniteNumber(c) and string.format("%.0f ms", c * 1000) or "--"
            local ping = isFiniteNumber(d) and string.format("%.0f ms", d) or "--"
            setStatus("EVADING", "TTI " .. tti .. " • ping " .. ping)
        else
            setStatus("BLOCKED", tostring(b or "Maneuver unavailable"))
        end
    end
end

globalConnections[#globalConnections + 1] = remote.OnClientEvent:Connect(handleServerMessage)

globalConnections[#globalConnections + 1] = UserInputService.InputBegan:Connect(function(input, processed)
    if processed or not running then
        return
    end

    if input.KeyCode == TOGGLE_KEY then
        setEnabled(not autoEnabled, true)
    end
end)

globalConnections[#globalConnections + 1] = player.CharacterAdded:Connect(function()
    task.delay(0.25, function()
        if running then
            remote:FireServer("SetEnabled", autoEnabled)
            scheduleEnsureUI()
        end
    end)
end)

globalConnections[#globalConnections + 1] = RunService.Heartbeat:Connect(function(deltaTime)
    if not running then
        return
    end

    pingAccumulator = pingAccumulator + deltaTime
    if pingAccumulator >= PING_UPDATE_INTERVAL then
        pingAccumulator = pingAccumulator % PING_UPDATE_INTERVAL
        local sample = readPingMs()
        if sample ~= nil then
            pingMs = sample
        end
        remote:FireServer("Ping", pingMs)
    end

    uiAccumulator = uiAccumulator + deltaTime
    if uiAccumulator >= UI_WATCHDOG_INTERVAL then
        uiAccumulator = uiAccumulator % UI_WATCHDOG_INTERVAL
        local currentPlayerGui = player:FindFirstChildOfClass("PlayerGui")
        if currentPlayerGui ~= playerGui
            or not screenGui
            or screenGui.Parent ~= currentPlayerGui
            or not panel
            or panel.Parent ~= screenGui
            or not toggleButton
            or toggleButton.Parent ~= panel then
            scheduleEnsureUI()
        end
    end
end)

globalConnections[#globalConnections + 1] = script.Destroying:Connect(function()
    running = false
    disconnectConnections(guiConnections)
    disconnectConnections(globalConnections)
    if screenGui then
        pcall(function()
            screenGui:Destroy()
        end)
    end
end)

createUI()
remote:FireServer("SetEnabled", autoEnabled)
local initialPing = readPingMs()
if initialPing ~= nil then
    pingMs = initialPing
end
remote:FireServer("Ping", pingMs)
