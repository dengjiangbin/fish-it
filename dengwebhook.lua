-- DENG Fish Webhook
-- Clean-room replacement based on static behavioral recovery.
-- No hidden webhooks, license checks, remote code loading, or embedded credentials.

local VERSION = "1.0.0"

local Config = {
    MainWebhook = "",
    PlayerWebhook = "",
    EventWebhook = "",

    BotName = "DENG",
    BotAvatar = "",
    TimezoneOffsetSeconds = 7 * 60 * 60,

    CatchNotifications = true,
    PlayerNotifications = false,
    EventNotifications = false,
    WatchChat = true,
    WatchVisibleText = true,

    MinimumRarity = "Common",
    EnabledRarities = {
        Common = false,
        Uncommon = false,
        Rare = false,
        Epic = true,
        Legendary = true,
        Mythical = true,
        Secret = true,
        Forgotten = true,
        Custom = true,
    },

    CustomFishNames = {},
    CustomMutations = {},
    MentionUserIds = {},
    MentionRoleIds = {},
    AllowEveryoneMention = false,

    RequestTimeoutSeconds = 15,
    MaximumQueueSize = 50,
    DuplicateWindowSeconds = 8,
    VisibleTextScanInterval = 0.75,
    ConfigDirectory = "DENGFishWebhook",
    ConfigFile = "config.json",

    -- Optional manual adapters. Each function receives Runtime and may call:
    -- Runtime.EmitCatch(data), Runtime.EmitEvent(data), or Runtime.EmitPlayer(data).
    Adapters = {},
}

local UserConfig = rawget(_G, "DENGFishWebhookConfig")
if type(UserConfig) == "table" then
    for key, value in pairs(UserConfig) do
        Config[key] = value
    end
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer

local Runtime = {
    Version = VERSION,
    Config = Config,
    Running = true,
    Connections = {},
    Tasks = {},
    Queue = {},
    Sending = false,
    Seen = {},
    SeenText = setmetatable({}, { __mode = "k" }),
    Status = "Starting",
    Gui = nil,
}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeSpace(value)
    return trim(tostring(value or ""):gsub("%s+", " "))
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function clampNumber(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not value then
        return fallback
    end
    return math.max(minimum, math.min(maximum, value))
end

local function safeText(value, maximum)
    value = normalizeSpace(value)
    value = value:gsub("@everyone", "@ everyone"):gsub("@here", "@ here")
    if #value > maximum then
        value = value:sub(1, maximum - 3) .. "..."
    end
    return value
end

local function stripRichText(value)
    return normalizeSpace(tostring(value or ""):gsub("<[^>]->", ""))
end

local function maskWebhook(url)
    url = tostring(url or "")
    local id = url:match("/webhooks/(%d+)/")
    if not id then
        return "not configured"
    end
    return "Discord webhook …" .. id:sub(-4)
end

local function validateWebhook(url)
    url = trim(url)
    if url == "" then
        return nil, "Webhook is empty"
    end
    if #url > 500 or url:find("[%c%s]") then
        return nil, "Webhook contains invalid characters"
    end
    local host, id, token = url:match("^https://([^/]+)/api/webhooks/(%d+)/([%w%-%._]+)/*$")
    if not host then
        return nil, "Expected an HTTPS Discord webhook URL"
    end
    host = lower(host)
    local allowed = {
        ["discord.com"] = true,
        ["discordapp.com"] = true,
        ["canary.discord.com"] = true,
        ["ptb.discord.com"] = true,
    }
    if not allowed[host] then
        return nil, "Webhook host is not allowed"
    end
    if #token < 20 then
        return nil, "Webhook token is incomplete"
    end
    return "https://" .. host .. "/api/webhooks/" .. id .. "/" .. token
end

local function getRequestFunction()
    local candidates = {
        rawget(_G, "request"),
        rawget(_G, "http_request"),
        rawget(_G, "httprequest"),
    }
    local synTable = rawget(_G, "syn")
    if type(synTable) == "table" then
        table.insert(candidates, synTable.request)
    end
    local fluxusTable = rawget(_G, "fluxus")
    if type(fluxusTable) == "table" then
        table.insert(candidates, fluxusTable.request)
    end
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "function" then
            return candidate
        end
    end
    return nil
end

local Request = getRequestFunction()

local function setStatus(message)
    Runtime.Status = safeText(message, 180)
    if Runtime.StatusLabel then
        Runtime.StatusLabel.Text = Runtime.Status
    end
end

local function trackConnection(connection)
    table.insert(Runtime.Connections, connection)
    return connection
end

local function jsonEncode(value)
    local ok, result = pcall(function()
        return HttpService:JSONEncode(value)
    end)
    if ok then
        return result
    end
    return nil, "JSON encoding failed"
end

local function webhookPost(url, payload)
    if not Request then
        return false, "No supported HTTP request function is available"
    end
    local normalized, validationError = validateWebhook(url)
    if not normalized then
        return false, validationError
    end
    local body, encodingError = jsonEncode(payload)
    if not body then
        return false, encodingError
    end
    local ok, response = pcall(Request, {
        Url = normalized,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = body,
        Timeout = clampNumber(Config.RequestTimeoutSeconds, 5, 30, 15),
    })
    if not ok then
        return false, "Request failed before receiving a response"
    end
    local statusCode = tonumber(response and (response.StatusCode or response.Status)) or 0
    if statusCode >= 200 and statusCode < 300 then
        return true
    end
    if statusCode == 429 then
        return false, "Discord rate limit reached"
    end
    return false, "Webhook returned HTTP " .. tostring(statusCode)
end

local function queueSend(url, payload, label)
    if #Runtime.Queue >= clampNumber(Config.MaximumQueueSize, 5, 100, 50) then
        table.remove(Runtime.Queue, 1)
    end
    table.insert(Runtime.Queue, { url = url, payload = payload, label = label or "notification" })
    if Runtime.Sending then
        return
    end
    Runtime.Sending = true
    task.spawn(function()
        while Runtime.Running and #Runtime.Queue > 0 do
            local item = table.remove(Runtime.Queue, 1)
            setStatus("Sending " .. item.label .. " to " .. maskWebhook(item.url))
            local ok, err = webhookPost(item.url, item.payload)
            if ok then
                setStatus("Sent " .. item.label)
            else
                setStatus("Failed: " .. safeText(err, 120))
            end
            task.wait(0.35)
        end
        Runtime.Sending = false
    end)
end

local function colorForRarity(rarity)
    local colors = {
        Common = 0x95A5A6,
        Uncommon = 0x2ECC71,
        Rare = 0x3498DB,
        Epic = 0xB373F8,
        Legendary = 0xFFD72B,
        Mythical = 0xFF1D19,
        Secret = 0x18C098,
        Forgotten = 0x111111,
        Custom = 0xFF69B4,
    }
    return colors[rarity] or colors.Common
end

local function normalizeRarity(value)
    local aliases = {
        forgotten = "Forgotten",
        forgottens = "Forgotten",
        mythic = "Mythical",
        mythical = "Mythical",
        legendary = "Legendary",
        legend = "Legendary",
        secret = "Secret",
        epic = "Epic",
        rare = "Rare",
        uncommon = "Uncommon",
        common = "Common",
        custom = "Custom",
    }
    return aliases[lower(trim(value))] or "Common"
end

local function listContains(list, value)
    value = lower(normalizeSpace(value))
    for _, item in ipairs(type(list) == "table" and list or {}) do
        if lower(normalizeSpace(item)) == value then
            return true
        end
    end
    return false
end

local function normalizeSnowflakeList(list)
    local result = {}
    local seen = {}
    for _, value in ipairs(type(list) == "table" and list or {}) do
        local id = tostring(value):match("^(%d+)$")
        if id and #id >= 15 and #id <= 20 and not seen[id] then
            seen[id] = true
            table.insert(result, id)
        end
    end
    return result
end

local function buildMentionText()
    local parts = {}
    for _, id in ipairs(normalizeSnowflakeList(Config.MentionUserIds)) do
        table.insert(parts, "<@" .. id .. ">")
    end
    for _, id in ipairs(normalizeSnowflakeList(Config.MentionRoleIds)) do
        table.insert(parts, "<@&" .. id .. ">")
    end
    if Config.AllowEveryoneMention then
        table.insert(parts, "@everyone")
    end
    return table.concat(parts, " ")
end

local function timestampIso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time())
end

local function duplicateKey(parts)
    local value = table.concat(parts, "|"):lower()
    local now = os.clock()
    local prior = Runtime.Seen[value]
    Runtime.Seen[value] = now
    for key, seenAt in pairs(Runtime.Seen) do
        if now - seenAt > 60 then
            Runtime.Seen[key] = nil
        end
    end
    return prior and now - prior < clampNumber(Config.DuplicateWindowSeconds, 1, 60, 8)
end

local function guessRarity(text)
    local candidates = { "Forgotten", "Secret", "Mythical", "Legendary", "Epic", "Rare", "Uncommon", "Common" }
    local lowered = lower(text)
    for _, rarity in ipairs(candidates) do
        if lowered:find(lower(rarity), 1, true) then
            return rarity
        end
    end
    return "Common"
end

local function parseCatchText(rawText)
    local text = stripRichText(rawText)
    if #text < 8 or #text > 600 then
        return nil
    end
    local lowered = lower(text)
    if not lowered:find("caught", 1, true) and not lowered:find("catch", 1, true) then
        return nil
    end

    local player, fish, weight = text:match("^(.+) caught an? (.-) weighing ([%d%.,]+)%s*[Kk][Gg]")
    if not fish then
        player, fish, weight = text:match("^(.+) caught an? (.-) %(([%d%.,]+)%s*[Kk][Gg]%)")
    end
    if not fish then
        player, fish, weight = text:match("^(.+) caught:? (.-) %- ([%d%.,]+)%s*[Kk][Gg]")
    end
    if not fish then
        fish, weight = text:match("[Cc]aught:? an? (.-) %(([%d%.,]+)%s*[Kk][Gg]%)")
    end
    if not fish then
        fish = text:match("[Cc]aught:? an? ([^!]+)")
    end
    if not fish then
        return nil
    end

    fish = normalizeSpace(fish:gsub("%b[]", ""):gsub("%b()", ""))
    player = normalizeSpace(player or (LocalPlayer and LocalPlayer.Name) or "Unknown")
    weight = weight and weight:gsub(",", ".") or "Unknown"
    local mutation = text:match("%[([^%]]+)%]") or text:match("[Mm]utation:?%s*([%w%s%-_]+)") or "None"
    mutation = normalizeSpace(mutation)
    local rarity = guessRarity(text)
    if listContains(Config.CustomFishNames, fish) or listContains(Config.CustomMutations, mutation) then
        rarity = "Custom"
    end
    return {
        player = player,
        fish = fish,
        weight = weight,
        mutation = mutation,
        rarity = rarity,
        raw = text,
    }
end

local function catchAllowed(data)
    if not Config.CatchNotifications then
        return false
    end
    if type(Config.EnabledRarities) == "table" and Config.EnabledRarities[data.rarity] then
        return true
    end
    return listContains(Config.CustomFishNames, data.fish) or listContains(Config.CustomMutations, data.mutation)
end

function Runtime.EmitCatch(data)
    if type(data) ~= "table" then
        return false, "Catch data must be a table"
    end
    data.player = safeText(data.player or "Unknown", 100)
    data.fish = safeText(data.fish or "Unknown fish", 150)
    data.weight = safeText(data.weight or "Unknown", 50)
    data.mutation = safeText(data.mutation or "None", 100)
    data.rarity = normalizeRarity(data.rarity)
    if not catchAllowed(data) then
        return false, "Catch filtered"
    end
    if duplicateKey({ data.player, data.fish, data.weight, data.mutation, data.rarity }) then
        return false, "Duplicate catch"
    end
    local fields = {
        { name = "Fish", value = data.fish, inline = true },
        { name = "Rarity", value = data.rarity, inline = true },
        { name = "Weight", value = data.weight == "Unknown" and data.weight or data.weight .. " kg", inline = true },
        { name = "Mutation", value = data.mutation, inline = true },
        { name = "Player", value = data.player, inline = true },
    }
    if data.location and trim(data.location) ~= "" then
        table.insert(fields, { name = "Location", value = safeText(data.location, 120), inline = true })
    end
    local mentionUsers = normalizeSnowflakeList(Config.MentionUserIds)
    local mentionRoles = normalizeSnowflakeList(Config.MentionRoleIds)
    local payload = {
        username = safeText(Config.BotName, 80),
        avatar_url = trim(Config.BotAvatar),
        content = buildMentionText(),
        allowed_mentions = { parse = Config.AllowEveryoneMention and { "everyone" } or {}, users = mentionUsers, roles = mentionRoles },
        embeds = {{
            title = "Fish Caught",
            description = "A configured catch was detected.",
            color = colorForRarity(data.rarity),
            fields = fields,
            timestamp = timestampIso(),
            footer = { text = "DENG Fish Webhook v" .. VERSION },
        }},
    }
    queueSend(Config.MainWebhook, payload, "catch notification")
    return true
end

function Runtime.EmitPlayer(data)
    if not Config.PlayerNotifications or type(data) ~= "table" then
        return false, "Player notifications disabled"
    end
    local action = data.action == "left" and "left" or "joined"
    local name = safeText(data.name or "Unknown", 100)
    if duplicateKey({ "player", action, tostring(data.userId), name }) then
        return false, "Duplicate player event"
    end
    local payload = {
        username = safeText(Config.BotName, 80),
        avatar_url = trim(Config.BotAvatar),
        embeds = {{
            title = action == "joined" and "Player Joined" or "Player Left",
            description = "**" .. name .. "** " .. action .. " the server.",
            color = action == "joined" and 0x2ECC71 or 0xE74C3C,
            fields = {{ name = "User ID", value = safeText(data.userId or "Unknown", 30), inline = true }},
            timestamp = timestampIso(),
        }},
    }
    local target = trim(Config.PlayerWebhook) ~= "" and Config.PlayerWebhook or Config.MainWebhook
    queueSend(target, payload, "player notification")
    return true
end

function Runtime.EmitEvent(data)
    if not Config.EventNotifications or type(data) ~= "table" then
        return false, "Event notifications disabled"
    end
    local name = safeText(data.name or "Unknown event", 150)
    local state = safeText(data.state or "active", 50)
    if duplicateKey({ "event", name, state }) then
        return false, "Duplicate event"
    end
    local payload = {
        username = safeText(Config.BotName, 80),
        avatar_url = trim(Config.BotAvatar),
        embeds = {{
            title = "Event Update",
            description = "**" .. name .. "** is now **" .. state .. "**.",
            color = state == "ended" and 0x95A5A6 or 0x9B59B6,
            timestamp = timestampIso(),
        }},
    }
    local target = trim(Config.EventWebhook) ~= "" and Config.EventWebhook or Config.MainWebhook
    queueSend(target, payload, "event notification")
    return true
end

local function processPossibleCatch(text)
    local data = parseCatchText(text)
    if data then
        Runtime.EmitCatch(data)
    end
end

local function installChatWatcher()
    if not Config.WatchChat then
        return
    end
    pcall(function()
        trackConnection(TextChatService.MessageReceived:Connect(function(message)
            if Runtime.Running then
                processPossibleCatch(message.Text)
            end
        end))
    end)
    for _, player in ipairs(Players:GetPlayers()) do
        trackConnection(player.Chatted:Connect(processPossibleCatch))
    end
    trackConnection(Players.PlayerAdded:Connect(function(player)
        trackConnection(player.Chatted:Connect(processPossibleCatch))
        Runtime.EmitPlayer({ action = "joined", name = player.Name, userId = player.UserId })
    end))
    trackConnection(Players.PlayerRemoving:Connect(function(player)
        Runtime.EmitPlayer({ action = "left", name = player.Name, userId = player.UserId })
    end))
end

local function installVisibleTextWatcher()
    if not Config.WatchVisibleText or not LocalPlayer then
        return
    end
    task.spawn(function()
        while Runtime.Running do
            local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            if playerGui then
                for _, object in ipairs(playerGui:GetDescendants()) do
                    if (object:IsA("TextLabel") or object:IsA("TextButton")) and object.Visible then
                        local text = object.Text
                        if Runtime.SeenText[object] ~= text then
                            Runtime.SeenText[object] = text
                            processPossibleCatch(text)
                        end
                    end
                end
            end
            task.wait(clampNumber(Config.VisibleTextScanInterval, 0.25, 5, 0.75))
        end
    end)
end

local function configPath()
    return tostring(Config.ConfigDirectory) .. "/" .. tostring(Config.ConfigFile)
end

local function saveConfig()
    if type(writefile) ~= "function" or type(makefolder) ~= "function" then
        return false, "File persistence is unavailable"
    end
    local export = {
        MainWebhook = Config.MainWebhook,
        PlayerWebhook = Config.PlayerWebhook,
        EventWebhook = Config.EventWebhook,
        BotName = Config.BotName,
        BotAvatar = Config.BotAvatar,
        CatchNotifications = Config.CatchNotifications,
        PlayerNotifications = Config.PlayerNotifications,
        EventNotifications = Config.EventNotifications,
        WatchChat = Config.WatchChat,
        WatchVisibleText = Config.WatchVisibleText,
        EnabledRarities = Config.EnabledRarities,
        CustomFishNames = Config.CustomFishNames,
        CustomMutations = Config.CustomMutations,
        MentionUserIds = Config.MentionUserIds,
        MentionRoleIds = Config.MentionRoleIds,
    }
    local body, err = jsonEncode(export)
    if not body then
        return false, err
    end
    local ok = pcall(function()
        if type(isfolder) ~= "function" or not isfolder(Config.ConfigDirectory) then
            makefolder(Config.ConfigDirectory)
        end
        writefile(configPath(), body)
    end)
    return ok, ok and nil or "Could not save configuration"
end

local function loadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" or not isfile(configPath()) then
        return false, "No saved configuration"
    end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(configPath()))
    end)
    if not ok or type(decoded) ~= "table" then
        return false, "Saved configuration is invalid"
    end
    local allowedKeys = {
        MainWebhook = "string", PlayerWebhook = "string", EventWebhook = "string",
        BotName = "string", BotAvatar = "string", CatchNotifications = "boolean",
        PlayerNotifications = "boolean", EventNotifications = "boolean",
        WatchChat = "boolean", WatchVisibleText = "boolean", EnabledRarities = "table",
        CustomFishNames = "table", CustomMutations = "table",
        MentionUserIds = "table", MentionRoleIds = "table",
    }
    for key, value in pairs(decoded) do
        if allowedKeys[key] == type(value) then
            Config[key] = value
        end
    end
    Config.MentionUserIds = normalizeSnowflakeList(Config.MentionUserIds)
    Config.MentionRoleIds = normalizeSnowflakeList(Config.MentionRoleIds)
    return true
end

function Runtime.TestWebhook()
    local payload = {
        username = safeText(Config.BotName, 80),
        avatar_url = trim(Config.BotAvatar),
        embeds = {{
            title = "DENG Fish Webhook",
            description = "The webhook connection is working.",
            color = 0x3498DB,
            fields = {{ name = "Version", value = VERSION, inline = true }},
            timestamp = timestampIso(),
        }},
    }
    queueSend(Config.MainWebhook, payload, "test notification")
end

function Runtime.SaveConfig()
    local ok, err = saveConfig()
    setStatus(ok and "Configuration saved" or ("Save failed: " .. tostring(err)))
    return ok, err
end

function Runtime.Unload()
    if not Runtime.Running then
        return
    end
    Runtime.Running = false
    for _, connection in ipairs(Runtime.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    Runtime.Connections = {}
    Runtime.Queue = {}
    if Runtime.Gui then
        pcall(function()
            Runtime.Gui:Destroy()
        end)
    end
    if rawget(_G, "DENGFishWebhook") == Runtime then
        _G.DENGFishWebhook = nil
    end
end

local function createButton(parent, text, position, callback)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(0.48, 0, 0, 34)
    button.Position = position
    button.BackgroundColor3 = Color3.fromRGB(47, 55, 75)
    button.TextColor3 = Color3.fromRGB(240, 243, 250)
    button.Font = Enum.Font.GothamMedium
    button.TextSize = 13
    button.Text = text
    button.Parent = parent
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
    trackConnection(button.MouseButton1Click:Connect(callback))
    return button
end

local function createInput(parent, placeholder, y)
    local input = Instance.new("TextBox")
    input.Size = UDim2.new(1, -24, 0, 36)
    input.Position = UDim2.new(0, 12, 0, y)
    input.BackgroundColor3 = Color3.fromRGB(27, 32, 45)
    input.TextColor3 = Color3.fromRGB(238, 241, 248)
    input.PlaceholderColor3 = Color3.fromRGB(130, 139, 158)
    input.Font = Enum.Font.Code
    input.TextSize = 12
    input.TextXAlignment = Enum.TextXAlignment.Left
    input.ClearTextOnFocus = false
    input.PlaceholderText = placeholder
    input.Parent = parent
    Instance.new("UICorner", input).CornerRadius = UDim.new(0, 7)
    local padding = Instance.new("UIPadding", input)
    padding.PaddingLeft = UDim.new(0, 9)
    padding.PaddingRight = UDim.new(0, 9)
    return input
end

local function createGui()
    local gui = Instance.new("ScreenGui")
    gui.Name = "DENGFishWebhookUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false

    local parent = CoreGui
    if type(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and result then
            parent = result
        end
    elseif LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui") then
        parent = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    end
    gui.Parent = parent
    Runtime.Gui = gui

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 420, 0, 300)
    frame.Position = UDim2.new(0.5, -210, 0.5, -150)
    frame.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = Color3.fromRGB(70, 82, 110)
    stroke.Thickness = 1

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -48, 0, 42)
    title.Position = UDim2.new(0, 14, 0, 0)
    title.BackgroundTransparency = 1
    title.TextColor3 = Color3.fromRGB(245, 247, 252)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "DENG Fish Webhook  v" .. VERSION
    title.Parent = frame

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 34, 0, 30)
    close.Position = UDim2.new(1, -40, 0, 6)
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.fromRGB(215, 95, 95)
    close.Font = Enum.Font.GothamBold
    close.TextSize = 18
    close.Text = "×"
    close.Parent = frame
    trackConnection(close.MouseButton1Click:Connect(Runtime.Unload))

    local webhookInput = createInput(frame, "Paste your Discord webhook URL", 48)
    webhookInput.Text = Config.MainWebhook
    trackConnection(webhookInput.FocusLost:Connect(function()
        local value, err = validateWebhook(webhookInput.Text)
        if value then
            Config.MainWebhook = value
            setStatus("Webhook accepted: " .. maskWebhook(value))
        elseif trim(webhookInput.Text) == "" then
            Config.MainWebhook = ""
            setStatus("Webhook cleared")
        else
            webhookInput.Text = Config.MainWebhook
            setStatus("Invalid webhook: " .. err)
        end
    end))

    local botInput = createInput(frame, "Webhook display name", 92)
    botInput.Text = Config.BotName
    trackConnection(botInput.FocusLost:Connect(function()
        Config.BotName = safeText(botInput.Text, 80)
        botInput.Text = Config.BotName
    end))

    createButton(frame, "Test Webhook", UDim2.new(0, 12, 0, 140), Runtime.TestWebhook)
    createButton(frame, "Save Config", UDim2.new(0.52, 0, 0, 140), Runtime.SaveConfig)

    local catchButton = createButton(frame, "Catch: " .. (Config.CatchNotifications and "ON" or "OFF"), UDim2.new(0, 12, 0, 182), function()
        Config.CatchNotifications = not Config.CatchNotifications
    end)
    local playerButton = createButton(frame, "Players: " .. (Config.PlayerNotifications and "ON" or "OFF"), UDim2.new(0.52, 0, 0, 182), function()
        Config.PlayerNotifications = not Config.PlayerNotifications
    end)
    trackConnection(catchButton.MouseButton1Click:Connect(function()
        catchButton.Text = "Catch: " .. (Config.CatchNotifications and "ON" or "OFF")
    end))
    trackConnection(playerButton.MouseButton1Click:Connect(function()
        playerButton.Text = "Players: " .. (Config.PlayerNotifications and "ON" or "OFF")
    end))

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -24, 0, 52)
    status.Position = UDim2.new(0, 12, 1, -64)
    status.BackgroundColor3 = Color3.fromRGB(24, 29, 40)
    status.TextColor3 = Color3.fromRGB(175, 185, 205)
    status.Font = Enum.Font.Gotham
    status.TextSize = 12
    status.TextWrapped = true
    status.Text = Runtime.Status
    status.Parent = frame
    Instance.new("UICorner", status).CornerRadius = UDim.new(0, 7)
    Runtime.StatusLabel = status

    local dragging = false
    local dragStart
    local startPosition
    trackConnection(title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = frame.Position
        end
    end))
    trackConnection(title.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    local UserInputService = game:GetService("UserInputService")
    trackConnection(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end))
end

loadConfig()
Config.MentionUserIds = normalizeSnowflakeList(Config.MentionUserIds)
Config.MentionRoleIds = normalizeSnowflakeList(Config.MentionRoleIds)
if type(Config.EnabledRarities) ~= "table" then
    Config.EnabledRarities = {}
end

if rawget(_G, "DENGFishWebhook") and type(_G.DENGFishWebhook.Unload) == "function" then
    pcall(_G.DENGFishWebhook.Unload)
end
_G.DENGFishWebhook = Runtime

installChatWatcher()
installVisibleTextWatcher()

for index, adapter in ipairs(type(Config.Adapters) == "table" and Config.Adapters or {}) do
    if type(adapter) == "function" then
        local ok, result = pcall(adapter, Runtime)
        if not ok then
            warn("DENGFishWebhook adapter " .. tostring(index) .. " failed")
        elseif type(result) == "userdata" or type(result) == "table" then
            table.insert(Runtime.Connections, result)
        end
    end
end

local guiOk = pcall(createGui)
if not guiOk then
    warn("DENGFishWebhook UI could not be created; runtime API remains available")
end

setStatus(Request and "Ready — configure your webhook" or "Ready, but this executor has no HTTP request function")

return Runtime
