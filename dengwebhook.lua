-- DENG Fish Webhook
-- Clean-room replacement based on static behavioral recovery.
-- No hidden webhooks, license checks, remote code loading, or embedded credentials.

local VERSION = "2.3.0"

local Config = {
    SchemaVersion = 2,
    MainWebhook = "",
    PlayerWebhook = "",
    EventWebhook = "",
    GlobalWebhook = "",

    BotName = "DENG",
    BotAvatar = "",
    EmbedLayout = 1,
    CatchTitleTemplate = "{rarity} Fish Caught",
    CatchDescriptionTemplate = "{player} caught {fish}.",
    FooterTemplate = "DENG Fish Webhook • {date}",
    NotificationPrefix = "",
    DefaultFishThumbnail = "https://i.ibb.co.com/q38LKrcJ/image.png",
    TimezoneOffsetSeconds = 7 * 60 * 60,

    CatchNotifications = true,
    GlobalCatchNotifications = true,
    PlayerNotifications = false,
    EventNotifications = false,
    AfkNotifications = false,
    CrystalNotifications = false,
    ServerLuckNotifications = false,
    AdminEventNotifications = false,
    WatchChat = false,
    WatchVisibleText = false,

    MinimumRarity = "Common",
    EnabledRarities = {
        Common = true,
        Uncommon = true,
        Rare = true,
        Epic = true,
        Legendary = true,
        Mythical = true,
        Secret = true,
        Forgotten = true,
        Custom = true,
    },

    CustomFishNames = { "Sea Eater" },
    CustomMutations = {},
    MentionUserIds = {},
    MentionRoleIds = {},
    AllowEveryoneMention = false,

    RequestTimeoutSeconds = 15,
    MaximumQueueSize = 50,
    DuplicateWindowSeconds = 8,
    VisibleTextScanInterval = 0.75,
    AfkThresholdSeconds = 300,
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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
    Stats = { catches = 0, globalCatches = 0, players = 0, events = 0, crystals = 0, afk = 0, filtered = 0 },
    FeatureState = { serverLuck = nil, serverLuckTimer = nil, adminEvents = {}, adminSeenAt = {} },
    LastInputAt = os.clock(),
    AfkSent = false,
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
    local environments = { _G }
    if type(getgenv) == "function" then
        local ok, environment = pcall(getgenv)
        if ok and type(environment) == "table" and environment ~= _G then
            table.insert(environments, environment)
        end
    end

    local candidates = {}
    for _, environment in ipairs(environments) do
        table.insert(candidates, rawget(environment, "request"))
        table.insert(candidates, rawget(environment, "http_request"))
        table.insert(candidates, rawget(environment, "httprequest"))
        for _, namespace in ipairs({ "syn", "fluxus", "http", "krnl" }) do
            local requestTable = rawget(environment, namespace)
            if type(requestTable) == "table" then
                table.insert(candidates, requestTable.request)
            end
        end
    end
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "function" then
            return candidate
        end
    end
    return nil
end

local Request = getRequestFunction()

local function performRequest(options)
    local errors = {}

    if Request then
        local ok, response = pcall(Request, options)
        if ok and response then
            return response
        end
        table.insert(errors, "executor request failed")
    end

    local requestOptions = {
        Url = options.Url,
        Method = options.Method,
        Headers = options.Headers,
        Body = options.Body,
    }
    local requestOk, requestResponse = pcall(function()
        return HttpService:RequestAsync(requestOptions)
    end)
    if requestOk and requestResponse then
        return requestResponse
    end
    table.insert(errors, "RequestAsync unavailable")

    local postOk, postResponse = pcall(function()
        return HttpService:PostAsync(
            options.Url,
            options.Body,
            Enum.HttpContentType.ApplicationJson,
            false
        )
    end)
    if postOk then
        return { StatusCode = 204, Body = postResponse, Success = true }
    end
    table.insert(errors, "PostAsync unavailable")

    return nil, table.concat(errors, "; ")
end

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
    local normalized, validationError = validateWebhook(url)
    if not normalized then
        return false, validationError
    end
    local body, encodingError = jsonEncode(payload)
    if not body then
        return false, encodingError
    end
    local response, requestError = performRequest({
        Url = normalized,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = body,
        Timeout = clampNumber(Config.RequestTimeoutSeconds, 5, 30, 15),
    })
    if not response then
        return false, "HTTP POST unavailable: " .. tostring(requestError)
    end
    local statusCode = tonumber(response.StatusCode or response.Status or response.status_code) or 0
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

local function jakartaDate()
    return os.date("!%d %B %Y", os.time() + clampNumber(Config.TimezoneOffsetSeconds, -43200, 50400, 25200))
end

local function applyTemplate(template, variables)
    local output = tostring(template or "")
    output = output:gsub("{([%w_]+)}", function(key)
        return safeText(variables[key] or "", 500)
    end)
    return safeText(output, 1000)
end

local function assetThumbnail(value)
    value = trim(value)
    if value == "" then return nil end
    if value:match("^https://") then return value end
    local id = value:match("rbxassetid://(%d+)") or value:match("[?&]id=(%d+)") or value:match("^(%d+)$")
    if id then
        return "https://www.roblox.com/asset-thumbnail/image?assetId=" .. id .. "&width=420&height=420&format=png"
    end
    return nil
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
    if #text < 3 or #text > 600 then return nil end
    local lowered = lower(text)
    local catchStart, catchEnd = lowered:find("you caught", 1, true)
    local player
    if catchStart then
        player = LocalPlayer and LocalPlayer.Name or "Unknown"
    else
        catchStart, catchEnd = lowered:find("caught", 1, true)
        if catchStart and catchStart > 1 then player = trim(text:sub(1, catchStart - 1)) end
    end
    if not catchEnd then
        local newStart, newEnd = lowered:find("new fish", 1, true)
        catchStart, catchEnd = newStart, newEnd
    end
    if not catchEnd then return nil end

    local fish = trim(text:sub(catchEnd + 1))
    fish = fish:gsub("^%s*[:%-]%s*", ""):gsub("^[Aa][Nn]?%s+", ""):gsub("^[Tt][Hh][Ee]%s+", "")
    local weight = fish:match("[%(%[]?([%d%.,]+)%s*[Kk][Gg][%)]?%s*[!%.]*$")
        or fish:match("[Ww]eighing%s+([%d%.,]+)")
        or fish:match("%+%s*([%d%.,]+)%s*[Kk]?[Gg]?%s*$")
    fish = fish:gsub("%s+[Ww]eighing%s+[%d%.,]+%s*[Kk][Gg].*$", "")
        :gsub("%s*[%(%[]?[%d%.,]+%s*[Kk][Gg][%)]?%s*[!%.]*$", "")
        :gsub("%s*%+%s*[%d%.,]+%s*[Kk]?[Gg]?%s*$", "")
        :gsub("%s*[!]+$", "")
    local mutation = text:match("%[([^%]]+)%]") or text:match("[Mm]utation:?%s*([%w%s%-_]+)")
    for _, configuredMutation in ipairs(type(Config.CustomMutations) == "table" and Config.CustomMutations or {}) do
        local prefix = lower(configuredMutation) .. " "
        if lower(fish):sub(1, #prefix) == prefix then
            mutation = configuredMutation
            fish = trim(fish:sub(#prefix + 1))
            break
        end
    end
    fish = normalizeSpace(fish:gsub("%b[]", ""))
    if #fish < 2 or not fish:match("%a") then return nil end
    player = normalizeSpace(player or (LocalPlayer and LocalPlayer.Name) or "Unknown")
    weight = weight and weight:gsub(",", ".") or "Unknown"
    mutation = normalizeSpace(mutation or "None")
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
    if lower(data.fish):find("shark", 1, true)
        and (lower(data.mutation):find("color burn", 1, true) or lower(data.mutation):find("colour burn", 1, true)) then
        data.rarity = "Custom"
    end
    if not catchAllowed(data) then
        Runtime.Stats.filtered = Runtime.Stats.filtered + 1
        return false, "Catch filtered"
    end
    if duplicateKey({ data.player, data.fish, data.weight, data.mutation, data.rarity }) then
        return false, "Duplicate catch"
    end
    local fishRecord = Runtime.FindFish and Runtime.FindFish(data.fish) or nil
    local thumbnail = assetThumbnail(data.thumbnail or data.image or (fishRecord and fishRecord.thumbnail) or "")
        or assetThumbnail(Config.DefaultFishThumbnail)
        or Config.DefaultFishThumbnail
    local variables = {
        player = data.player, fish = data.fish, weight = data.weight, mutation = data.mutation,
        rarity = data.rarity, location = data.location or "Unknown", date = jakartaDate(), version = VERSION,
    }
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
    local title = applyTemplate(Config.CatchTitleTemplate, variables)
    local description = applyTemplate(Config.CatchDescriptionTemplate, variables)
    local footer = applyTemplate(Config.FooterTemplate, variables)
    local layout = math.floor(clampNumber(Config.EmbedLayout, 1, 3, 1))
    local embed
    if layout == 2 then
        embed = {
            author = { name = Config.NotificationPrefix ~= "" and Config.NotificationPrefix .. " DENG Fish It" or "DENG Fish It" },
            title = title,
            description = description .. "\n\n**Weight:** " .. variables.weight .. (variables.weight == "Unknown" and "" or " kg")
                .. "\n**Mutation:** " .. variables.mutation .. "\n**Location:** " .. variables.location,
            color = colorForRarity(data.rarity), thumbnail = { url = thumbnail }, timestamp = timestampIso(),
            footer = { text = footer },
        }
    elseif layout == 3 then
        embed = {
            title = (Config.NotificationPrefix ~= "" and Config.NotificationPrefix .. " " or "") .. data.fish,
            description = "**" .. data.rarity .. "** • " .. description,
            color = colorForRarity(data.rarity), fields = fields, image = { url = thumbnail },
            timestamp = timestampIso(), footer = { text = footer },
        }
    else
        embed = {
            title = (Config.NotificationPrefix ~= "" and Config.NotificationPrefix .. " " or "") .. title,
            description = description, color = colorForRarity(data.rarity), fields = fields,
            thumbnail = { url = thumbnail }, timestamp = timestampIso(), footer = { text = footer },
        }
    end
    local payload = {
        username = safeText(Config.BotName, 80),
        avatar_url = trim(Config.BotAvatar),
        content = buildMentionText(),
        allowed_mentions = { parse = Config.AllowEveryoneMention and { "everyone" } or {}, users = mentionUsers, roles = mentionRoles },
        embeds = { embed },
    }
    queueSend(Config.MainWebhook, payload, "catch notification")
    Runtime.Stats.catches = Runtime.Stats.catches + 1
    return true
end

local function isColorBurnShark(data)
    local fish = lower(normalizeSpace(data and data.fish))
    local mutation = lower(normalizeSpace(data and data.mutation))
    return fish:find("shark", 1, true) ~= nil
        and (mutation:find("color burn", 1, true) ~= nil or mutation:find("colour burn", 1, true) ~= nil)
end

function Runtime.EmitGlobalCatch(data)
    if not Config.GlobalCatchNotifications or type(data) ~= "table" then
        return false, "Global catch notifications disabled"
    end
    data.player = safeText(data.player or "Unknown", 100)
    data.fish = safeText(data.fish or "Unknown fish", 150)
    data.weight = safeText(data.weight or "Unknown", 50)
    data.mutation = safeText(data.mutation or "None", 100)
    data.rarity = normalizeRarity(data.rarity)
    if isColorBurnShark(data) then data.rarity = "Custom" end
    if duplicateKey({ "global", data.player, data.fish, data.weight, data.mutation }) then
        return false, "Duplicate global catch"
    end
    local fishRecord = Runtime.FindFish and Runtime.FindFish(data.fish) or nil
    local thumbnail = assetThumbnail(data.thumbnail or data.image or (fishRecord and fishRecord.thumbnail) or "")
        or assetThumbnail(Config.DefaultFishThumbnail) or Config.DefaultFishThumbnail
    local variables = {
        player = data.player, fish = data.fish, weight = data.weight, mutation = data.mutation,
        rarity = data.rarity, location = data.location or "Unknown", date = jakartaDate(), version = VERSION,
    }
    local target = trim(Config.GlobalWebhook) ~= "" and Config.GlobalWebhook or Config.MainWebhook
    queueSend(target, {
        username = safeText(Config.BotName, 80), avatar_url = trim(Config.BotAvatar), content = buildMentionText(),
        allowed_mentions = { parse = Config.AllowEveryoneMention and { "everyone" } or {}, users = normalizeSnowflakeList(Config.MentionUserIds), roles = normalizeSnowflakeList(Config.MentionRoleIds) },
        embeds = {{
            title = applyTemplate("Global {rarity} Catch", variables),
            description = applyTemplate("**{player}** caught **{fish}**.", variables),
            color = colorForRarity(data.rarity),
            fields = {
                { name = "Weight", value = data.weight == "Unknown" and data.weight or data.weight .. " kg", inline = true },
                { name = "Mutation", value = data.mutation, inline = true },
                { name = "Location", value = safeText(data.location or "Unknown", 120), inline = true },
            },
            image = { url = thumbnail }, timestamp = timestampIso(),
            footer = { text = applyTemplate(Config.FooterTemplate, variables) },
        }},
    }, "global catch notification")
    Runtime.Stats.globalCatches = Runtime.Stats.globalCatches + 1
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
            thumbnail = tonumber(data.userId) and { url = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. tostring(data.userId) .. "&width=150&height=150&format=png" } or nil,
            timestamp = timestampIso(),
        }},
    }
    local target = trim(Config.PlayerWebhook) ~= "" and Config.PlayerWebhook or Config.MainWebhook
    queueSend(target, payload, "player notification")
    Runtime.Stats.players = Runtime.Stats.players + 1
    return true
end

function Runtime.EmitEvent(data)
    if type(data) ~= "table" or (not Config.EventNotifications and not data.featureEnabled) then
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
    Runtime.Stats.events = Runtime.Stats.events + 1
    return true
end

function Runtime.EmitCrystal(data)
    if not Config.CrystalNotifications or type(data) ~= "table" then
        return false, "Crystal notifications disabled"
    end
    local name = safeText(data.name or "Crystal", 150)
    local detail = safeText(data.detail or "A crystal event was detected.", 500)
    if duplicateKey({ "crystal", name, detail }) then
        return false, "Duplicate crystal event"
    end
    local target = trim(Config.EventWebhook) ~= "" and Config.EventWebhook or Config.MainWebhook
    queueSend(target, {
        username = safeText(Config.BotName, 80), avatar_url = trim(Config.BotAvatar),
        embeds = {{ title = name, description = detail, color = 0x42D9C8, timestamp = timestampIso(),
            footer = { text = "DENG Fish Webhook v" .. VERSION } }},
    }, "crystal notification")
    Runtime.Stats.crystals = Runtime.Stats.crystals + 1
    return true
end

function Runtime.EmitAFK(data)
    if not Config.AfkNotifications or type(data) ~= "table" then
        return false, "AFK notifications disabled"
    end
    local name = safeText(data.name or (LocalPlayer and LocalPlayer.Name) or "Player", 100)
    local seconds = math.floor(clampNumber(data.seconds, 0, 86400, 0))
    local target = trim(Config.PlayerWebhook) ~= "" and Config.PlayerWebhook or Config.MainWebhook
    queueSend(target, {
        username = safeText(Config.BotName, 80), avatar_url = trim(Config.BotAvatar),
        embeds = {{ title = "Player AFK", description = "**" .. name .. "** has been inactive for " .. tostring(seconds) .. " seconds.",
            color = 0xF1C40F, timestamp = timestampIso() }},
    }, "AFK notification")
    Runtime.Stats.afk = Runtime.Stats.afk + 1
    return true
end

Runtime.FishDatabase = {}

function Runtime.RegisterFish(record)
    if type(record) ~= "table" then return false, "Fish record must be a table" end
    local name = safeText(record.name, 150)
    if name == "" then return false, "Fish name is required" end
    local key = lower(name)
    Runtime.FishDatabase[key] = {
        name = name,
        rarity = normalizeRarity(record.rarity),
        thumbnail = safeText(record.thumbnail or record.image or record.icon or record.assetId or "", 500),
        location = safeText(record.location or "", 120),
        value = tonumber(record.value) or nil,
    }
    return true
end

function Runtime.FindFish(name)
    return Runtime.FishDatabase[lower(normalizeSpace(name))]
end

function Runtime.ParseCatchText(text)
    return parseCatchText(text)
end

function Runtime.GetPlayerSnapshot()
    local snapshot = {}
    for _, player in ipairs(Players:GetPlayers()) do
        table.insert(snapshot, { name = player.Name, displayName = player.DisplayName, userId = player.UserId })
    end
    return snapshot
end

function Runtime.GetLocationContext()
    return { placeId = game.PlaceId, jobId = safeText(game.JobId, 100), playerCount = #Players:GetPlayers() }
end

local function processPossibleCatch(text)
    local data = parseCatchText(text)
    if data then
        Runtime.EmitCatch(data)
    end
end

local syncServerLuck, syncAdminEvent

local function processPossibleFeature(text)
    text = stripRichText(text)
    local lowered = lower(text)
    local catch = parseCatchText(text)
    local isGlobal = lowered:find("global", 1, true) and lowered:find("caught", 1, true)
    if catch then
        if isGlobal then Runtime.EmitGlobalCatch(catch) else Runtime.EmitCatch(catch) end
    end
    if Config.CrystalNotifications and (lowered:find("crystal", 1, true) or lowered:find("gemstone", 1, true)) then
        Runtime.EmitCrystal({ name = "Crystal Update", detail = text })
    elseif lowered:find("server luck", 1, true) then
        syncServerLuck(text)
    elseif lowered:find("admin event", 1, true) or lowered:find("administrator event", 1, true) then
        syncAdminEvent(text)
    end
end

local function parseServerLuck(text)
    local cleaned = normalizeSpace(stripRichText(text))
    local lowered = lower(cleaned)
    if not lowered:find("server luck", 1, true) then return nil end
    local multiplier = cleaned:match("[Ss]erver%s+[Ll]uck%s*[:%-]?%s*[xX]?([%d%.]+)")
    local timer = cleaned:match("(%d%d?:%d%d:%d%d)") or cleaned:match("(%d%d?:%d%d)")
    return { multiplier = multiplier or "Default", timer = timer or "Unknown", raw = cleaned }
end

syncServerLuck = function(text)
    if not Config.ServerLuckNotifications then return end
    local info = parseServerLuck(text)
    if not info then return end
    local identity = lower(info.multiplier)
    Runtime.FeatureState.serverLuckTimer = info.timer
    if Runtime.FeatureState.serverLuck == identity then return end
    Runtime.FeatureState.serverLuck = identity
    Runtime.EmitEvent({ name = "Server Luck x" .. info.multiplier, state = info.timer == "Unknown" and "active" or info.timer, featureEnabled = true })
end

syncAdminEvent = function(text)
    if not Config.AdminEventNotifications then return end
    local cleaned = normalizeSpace(stripRichText(text))
    local lowered = lower(cleaned)
    if not (lowered:find("admin event", 1, true) or lowered:find("administrator event", 1, true)) then return end
    local identity = lower(cleaned:gsub("%d%d?:%d%d:?%d*", ""))
    Runtime.FeatureState.adminSeenAt[identity] = os.clock()
    if Runtime.FeatureState.adminEvents[identity] then return end
    Runtime.FeatureState.adminEvents[identity] = cleaned
    Runtime.EmitEvent({ name = "Administrator Event", state = cleaned, featureEnabled = true })
end

local function installFeatureStateTracker()
    task.spawn(function()
        while Runtime.Running do
            local now = os.clock()
            for identity, lastSeen in pairs(Runtime.FeatureState.adminSeenAt) do
                if now - lastSeen > 8 then
                    local prior = Runtime.FeatureState.adminEvents[identity]
                    Runtime.FeatureState.adminSeenAt[identity] = nil
                    Runtime.FeatureState.adminEvents[identity] = nil
                    if prior and Config.AdminEventNotifications then
                        Runtime.EmitEvent({ name = "Administrator Event Ended", state = safeText(prior, 300), featureEnabled = true })
                    end
                end
            end
            task.wait(3)
        end
    end)
end

local function installChatWatcher()
    if not Config.WatchChat then
        return
    end
    pcall(function()
        trackConnection(TextChatService.MessageReceived:Connect(function(message)
            if Runtime.Running then
                processPossibleFeature(message.Text)
            end
        end))
    end)
    for _, player in ipairs(Players:GetPlayers()) do
        trackConnection(player.Chatted:Connect(processPossibleFeature))
    end
    trackConnection(Players.PlayerAdded:Connect(function(player)
        trackConnection(player.Chatted:Connect(processPossibleFeature))
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
                            processPossibleFeature(text)
                        end
                    end
                end
            end
            task.wait(clampNumber(Config.VisibleTextScanInterval, 0.25, 5, 0.75))
        end
    end)
end

local function installCatchRemoteWatcher()
    local hooked = setmetatable({}, { __mode = "k" })
    local function emitRecord(name, record, source)
        if type(name) ~= "string" or trim(name) == "" then return false end
        record = type(record) == "table" and record or {}
        local direct = parseCatchText("You caught " .. name) or {}
        local tierRarity = ({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Forgotten" })[tonumber(record.Tier or record.tier) or 0]
        local packetPlayer = record.Username or record.username or record.PlayerName or record.playerName
            or record.DisplayName or record.displayName
        if not packetPlayer and typeof(record.Player or record.player) == "Instance" then
            packetPlayer = (record.Player or record.player).Name
        end
        direct.player = packetPlayer or (LocalPlayer and LocalPlayer.Name) or "Unknown"
        direct.fish = direct.fish or normalizeSpace(name)
        direct.weight = record.Weight or record.weight or record.WeightKg or record.weightKg or direct.weight or "Unknown"
        direct.mutation = record.Mutation or record.mutation or direct.mutation or "None"
        direct.rarity = record.Rarity or record.rarity or tierRarity or direct.rarity or guessRarity(name)
        direct.location = record.Location or record.location or direct.location
        direct.thumbnail = record.Thumbnail or record.thumbnail or record.Image or record.image
            or record.Icon or record.icon or record.AssetId or record.assetId
        direct.source = source
        if direct.weight ~= "Unknown" then direct.weight = tostring(direct.weight) end
        Runtime.RegisterFish({
            name = direct.fish,
            rarity = direct.rarity,
            thumbnail = direct.thumbnail,
            location = direct.location,
            value = record.Value or record.value or record.Price or record.price,
        })
        local global = record.Global == true or record.global == true or record.IsGlobal == true or record.isGlobal == true
            or lower(source):find("global", 1, true) ~= nil
            or (LocalPlayer and lower(direct.player) ~= lower(LocalPlayer.Name))
        return global and Runtime.EmitGlobalCatch(direct) or Runtime.EmitCatch(direct)
    end
    local function inspectArguments(remoteName, ...)
        local values = { ... }
        -- Recovered Fish It handler signature: (playerKey, context, itemName, data),
        -- where itemName is a string and data is a table containing Weight.
        local itemName, packet = values[3], values[4]
        if type(itemName) == "string" and type(packet) == "table"
            and (packet.Weight ~= nil or packet.weight ~= nil) then
            emitRecord(itemName, packet, "catch_packet")
            return
        end

        -- Only catch/fish/reward-named remotes may use alternate packet layouts.
        local likelyCatchRemote = remoteName:find("catch", 1, true)
            or remoteName:find("fish", 1, true) or remoteName:find("reward", 1, true)
        if not likelyCatchRemote then return end
        for _, value in ipairs(values) do
            if type(value) == "table" then
                local name = value.FishName or value.fishName or value.ItemName or value.itemName or value.DisplayName or value.displayName or value.Name or value.name
                if type(name) == "string" and (value.Weight ~= nil or value.weight ~= nil) then
                    if emitRecord(name, value, "remote_record") then return end
                end
            end
        end
        for _, value in ipairs(values) do
            if type(value) == "string" then
                local parsed = parseCatchText(value)
                if parsed then
                    if lower(value):find("global", 1, true) then Runtime.EmitGlobalCatch(parsed) else Runtime.EmitCatch(parsed) end
                    return
                end
            end
        end
    end
    local function hook(object)
        if hooked[object] or not object:IsA("RemoteEvent") then return end
        local name = lower(object.Name)
        if name:find("analytic", 1, true) or name:find("telemetry", 1, true) then return end
        hooked[object] = true
        local ok, connection = pcall(function()
            return object.OnClientEvent:Connect(function(...)
                if Runtime.Running then pcall(inspectArguments, name, ...) end
            end)
        end)
        if ok and connection then trackConnection(connection) end
    end
    for _, object in ipairs(ReplicatedStorage:GetDescendants()) do hook(object) end
    trackConnection(ReplicatedStorage.DescendantAdded:Connect(hook))
end

local function readAttribute(object, names)
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return object:GetAttribute(name) end)
        if ok and value ~= nil and value ~= "" then return value end
    end
    return nil
end

local function registerFishInstance(object)
    if not object or object:IsA("RemoteEvent") or object:IsA("RemoteFunction") then return false end
    local explicitName = readAttribute(object, { "FishName", "fishName", "DisplayName", "displayName" })
    local rarity = readAttribute(object, { "Rarity", "rarity" })
    local tier = tonumber(readAttribute(object, { "Tier", "tier" }))
    local thumbnail = readAttribute(object, { "Thumbnail", "thumbnail", "Image", "image", "Icon", "icon", "AssetId", "assetId" })
    local location = readAttribute(object, { "Location", "location", "Zone", "zone" })
    local value = readAttribute(object, { "Value", "value", "Price", "price", "SellPrice", "sellPrice" })
    if not explicitName and not rarity and not tier and not thumbnail and not location and not value then return false end
    if not explicitName and not rarity and not tier then return false end
    local tierRarity = ({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Forgotten" })[tier or 0]
    return Runtime.RegisterFish({
        name = explicitName or object.Name,
        rarity = rarity or tierRarity or guessRarity(object.Name),
        thumbnail = thumbnail,
        location = location,
        value = value,
    })
end

local function installFishDatabaseWatcher()
    for _, object in ipairs(ReplicatedStorage:GetDescendants()) do
        pcall(registerFishInstance, object)
    end
    trackConnection(ReplicatedStorage.DescendantAdded:Connect(function(object)
        if Runtime.Running then pcall(registerFishInstance, object) end
    end))
end

local function installAfkTracker()
    local UserInputService = game:GetService("UserInputService")
    trackConnection(UserInputService.InputBegan:Connect(function()
        Runtime.LastInputAt = os.clock()
        Runtime.AfkSent = false
    end))
    task.spawn(function()
        while Runtime.Running do
            local inactive = os.clock() - Runtime.LastInputAt
            local threshold = clampNumber(Config.AfkThresholdSeconds, 60, 86400, 300)
            if Config.AfkNotifications and inactive >= threshold and not Runtime.AfkSent then
                Runtime.AfkSent = true
                Runtime.EmitAFK({ name = LocalPlayer and LocalPlayer.Name, seconds = inactive })
            end
            task.wait(5)
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
        SchemaVersion = Config.SchemaVersion,
        MainWebhook = Config.MainWebhook,
        PlayerWebhook = Config.PlayerWebhook,
        EventWebhook = Config.EventWebhook,
        GlobalWebhook = Config.GlobalWebhook,
        BotName = Config.BotName,
        BotAvatar = Config.BotAvatar,
        EmbedLayout = Config.EmbedLayout,
        CatchTitleTemplate = Config.CatchTitleTemplate,
        CatchDescriptionTemplate = Config.CatchDescriptionTemplate,
        FooterTemplate = Config.FooterTemplate,
        NotificationPrefix = Config.NotificationPrefix,
        DefaultFishThumbnail = Config.DefaultFishThumbnail,
        CatchNotifications = Config.CatchNotifications,
        GlobalCatchNotifications = Config.GlobalCatchNotifications,
        PlayerNotifications = Config.PlayerNotifications,
        EventNotifications = Config.EventNotifications,
        AfkNotifications = Config.AfkNotifications,
        CrystalNotifications = Config.CrystalNotifications,
        ServerLuckNotifications = Config.ServerLuckNotifications,
        AdminEventNotifications = Config.AdminEventNotifications,
        WatchChat = Config.WatchChat,
        WatchVisibleText = Config.WatchVisibleText,
        EnabledRarities = Config.EnabledRarities,
        CustomFishNames = Config.CustomFishNames,
        CustomMutations = Config.CustomMutations,
        MentionUserIds = Config.MentionUserIds,
        MentionRoleIds = Config.MentionRoleIds,
        AllowEveryoneMention = Config.AllowEveryoneMention,
        AfkThresholdSeconds = Config.AfkThresholdSeconds,
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
        SchemaVersion = "number",
        MainWebhook = "string", PlayerWebhook = "string", EventWebhook = "string", GlobalWebhook = "string",
        BotName = "string", BotAvatar = "string", EmbedLayout = "number",
        CatchTitleTemplate = "string", CatchDescriptionTemplate = "string",
        FooterTemplate = "string", NotificationPrefix = "string", DefaultFishThumbnail = "string",
        CatchNotifications = "boolean", GlobalCatchNotifications = "boolean",
        PlayerNotifications = "boolean", EventNotifications = "boolean",
        AfkNotifications = "boolean", CrystalNotifications = "boolean",
        ServerLuckNotifications = "boolean", AdminEventNotifications = "boolean",
        WatchChat = "boolean", WatchVisibleText = "boolean", EnabledRarities = "table",
        CustomFishNames = "table", CustomMutations = "table",
        MentionUserIds = "table", MentionRoleIds = "table",
        AllowEveryoneMention = "boolean", AfkThresholdSeconds = "number",
    }
    for key, value in pairs(decoded) do
        if allowedKeys[key] == type(value) then
            Config[key] = value
        end
    end
    -- v2.3 replaces the noisy legacy broad text sources with the recovered
    -- typed catch packet. Old saved configs did not have a schema marker.
    if decoded.SchemaVersion == nil then
        Config.WatchChat = false
        Config.WatchVisibleText = false
        Config.SchemaVersion = 2
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

-- Full DENG dashboard. The compact v1 builder above is retained only as a
-- readable fallback reference; this definition is the active interface.
local function createGui()
    local palette = {
        bg = Color3.fromRGB(10, 13, 20), panel = Color3.fromRGB(17, 22, 32),
        panel2 = Color3.fromRGB(23, 29, 42), input = Color3.fromRGB(29, 36, 51),
        accent = Color3.fromRGB(71, 196, 255), accent2 = Color3.fromRGB(106, 92, 255),
        text = Color3.fromRGB(242, 246, 255), muted = Color3.fromRGB(143, 154, 178),
        good = Color3.fromRGB(62, 207, 142), bad = Color3.fromRGB(235, 91, 104),
    }
    local gui = Instance.new("ScreenGui")
    gui.Name = "DENGFishWebhookUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local parent = CoreGui
    if type(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and result then parent = result end
    elseif LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui") then
        parent = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    end
    gui.Parent = parent
    Runtime.Gui = gui

    local function corner(object, radius)
        Instance.new("UICorner", object).CornerRadius = UDim.new(0, radius or 8)
    end
    local function stroke(object, color, transparency)
        local item = Instance.new("UIStroke", object)
        item.Color = color or Color3.fromRGB(55, 66, 88)
        item.Transparency = transparency or 0.2
        return item
    end
    local function textLabel(parentObject, text, size, color, bold)
        local item = Instance.new("TextLabel")
        item.BackgroundTransparency = 1
        item.Size = UDim2.new(1, 0, 0, size + 8)
        item.Text = text
        item.TextColor3 = color or palette.text
        item.TextSize = size
        item.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.TextWrapped = true
        item.Parent = parentObject
        return item
    end
    local root = Instance.new("Frame")
    root.Name = "Window"
    root.Size = UDim2.new(0, 720, 0, 500)
    root.Position = UDim2.new(0.5, -360, 0.5, -250)
    root.BackgroundColor3 = palette.bg
    root.ClipsDescendants = true
    root.Parent = gui
    corner(root, 14); stroke(root, Color3.fromRGB(67, 83, 112), 0.1)

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 60)
    header.BackgroundColor3 = palette.panel
    header.Parent = root
    local brand = textLabel(header, "DENG", 20, palette.text, true)
    brand.Position = UDim2.new(0, 18, 0, 8); brand.Size = UDim2.new(0, 120, 0, 24)
    local subtitle = textLabel(header, "FISH WEBHOOK  •  v" .. VERSION, 10, palette.accent, true)
    subtitle.Position = UDim2.new(0, 18, 0, 31); subtitle.Size = UDim2.new(0, 250, 0, 18)

    local minimize = Instance.new("TextButton")
    minimize.Size = UDim2.new(0, 34, 0, 32); minimize.Position = UDim2.new(1, -76, 0, 14)
    minimize.BackgroundColor3 = palette.input; minimize.Text = "—"; minimize.TextColor3 = palette.muted
    minimize.TextSize = 17; minimize.Font = Enum.Font.GothamBold; minimize.Parent = header; corner(minimize, 8)
    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 34, 0, 32); close.Position = UDim2.new(1, -38, 0, 14)
    close.BackgroundColor3 = palette.input; close.Text = "×"; close.TextColor3 = palette.bad
    close.TextSize = 18; close.Font = Enum.Font.GothamBold; close.Parent = header; corner(close, 8)
    trackConnection(close.MouseButton1Click:Connect(Runtime.Unload))

    local sidebar = Instance.new("Frame")
    sidebar.Position = UDim2.new(0, 0, 0, 60); sidebar.Size = UDim2.new(0, 158, 1, -60)
    sidebar.BackgroundColor3 = palette.panel; sidebar.Parent = root
    local navLayout = Instance.new("UIListLayout", sidebar)
    navLayout.Padding = UDim.new(0, 7); navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    local navPadding = Instance.new("UIPadding", sidebar)
    navPadding.PaddingTop = UDim.new(0, 15)

    local content = Instance.new("Frame")
    content.Position = UDim2.new(0, 158, 0, 60); content.Size = UDim2.new(1, -158, 1, -96)
    content.BackgroundTransparency = 1; content.Parent = root
    local statusBar = Instance.new("TextLabel")
    statusBar.Position = UDim2.new(0, 170, 1, -30); statusBar.Size = UDim2.new(1, -184, 0, 22)
    statusBar.BackgroundTransparency = 1; statusBar.Text = Runtime.Status; statusBar.TextColor3 = palette.muted
    statusBar.TextSize = 11; statusBar.Font = Enum.Font.Gotham; statusBar.TextXAlignment = Enum.TextXAlignment.Left
    statusBar.TextTruncate = Enum.TextTruncate.AtEnd; statusBar.Parent = root
    Runtime.StatusLabel = statusBar

    local pages, navButtons = {}, {}
    local activePage
    local function newPage(name, description)
        local page = Instance.new("ScrollingFrame")
        page.Name = name; page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1
        page.BorderSizePixel = 0; page.ScrollBarThickness = 3; page.ScrollBarImageColor3 = palette.accent
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y; page.CanvasSize = UDim2.new(); page.Visible = false; page.Parent = content
        local layout = Instance.new("UIListLayout", page); layout.Padding = UDim.new(0, 10); layout.SortOrder = Enum.SortOrder.LayoutOrder
        local padding = Instance.new("UIPadding", page)
        padding.PaddingTop = UDim.new(0, 16); padding.PaddingBottom = UDim.new(0, 16)
        padding.PaddingLeft = UDim.new(0, 16); padding.PaddingRight = UDim.new(0, 16)
        textLabel(page, name, 22, palette.text, true)
        local desc = textLabel(page, description, 11, palette.muted, false); desc.Size = UDim2.new(1, 0, 0, 32)
        pages[name] = page
        return page
    end
    local function showPage(name)
        activePage = name
        for key, page in pairs(pages) do page.Visible = key == name end
        for key, button in pairs(navButtons) do
            button.BackgroundColor3 = key == name and palette.input or palette.panel
            button.TextColor3 = key == name and palette.accent or palette.muted
        end
    end
    local function nav(name)
        local button = Instance.new("TextButton")
        button.Size = UDim2.new(1, -18, 0, 38); button.BackgroundColor3 = palette.panel
        button.Text = "  " .. name; button.TextColor3 = palette.muted; button.TextSize = 12
        button.Font = Enum.Font.GothamMedium; button.TextXAlignment = Enum.TextXAlignment.Left
        button.Parent = sidebar; corner(button, 8); navButtons[name] = button
        trackConnection(button.MouseButton1Click:Connect(function() showPage(name) end))
    end
    local function card(parentObject, titleText)
        local box = Instance.new("Frame")
        box.Size = UDim2.new(1, 0, 0, 54); box.AutomaticSize = Enum.AutomaticSize.Y
        box.BackgroundColor3 = palette.panel2; box.Parent = parentObject; corner(box, 10); stroke(box, nil, 0.5)
        local layout = Instance.new("UIListLayout", box); layout.Padding = UDim.new(0, 8); layout.SortOrder = Enum.SortOrder.LayoutOrder
        local pad = Instance.new("UIPadding", box)
        pad.PaddingTop = UDim.new(0, 12); pad.PaddingBottom = UDim.new(0, 12)
        pad.PaddingLeft = UDim.new(0, 12); pad.PaddingRight = UDim.new(0, 12)
        if titleText then textLabel(box, titleText, 13, palette.text, true) end
        return box
    end
    local function input(parentObject, labelText, initial, callback, secret)
        local box = card(parentObject, labelText)
        local field = Instance.new("TextBox")
        field.Size = UDim2.new(1, 0, 0, 36); field.BackgroundColor3 = palette.input
        field.Text = secret and (trim(initial) ~= "" and "Webhook configured — replace to change" or "") or tostring(initial or "")
        field.PlaceholderText = secret and "Paste Discord webhook URL" or labelText
        field.TextColor3 = palette.text; field.PlaceholderColor3 = palette.muted; field.TextSize = 11
        field.Font = Enum.Font.Code; field.TextXAlignment = Enum.TextXAlignment.Left; field.ClearTextOnFocus = secret
        field.Parent = box; corner(field, 7)
        local pad = Instance.new("UIPadding", field); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10)
        trackConnection(field.FocusLost:Connect(function()
            callback(field.Text, field)
        end))
        return field
    end
    local function toggle(parentObject, labelText, getter, setter)
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, 0, 0, 42); row.BackgroundColor3 = palette.input
        row.TextColor3 = palette.text; row.TextSize = 12; row.Font = Enum.Font.GothamMedium
        row.TextXAlignment = Enum.TextXAlignment.Left; row.Parent = parentObject; corner(row, 8)
        local pad = Instance.new("UIPadding", row); pad.PaddingLeft = UDim.new(0, 11); pad.PaddingRight = UDim.new(0, 11)
        local function refresh() row.Text = labelText .. (getter() and "                                      ON" or "                                      OFF"); row.TextColor3 = getter() and palette.good or palette.muted end
        refresh()
        trackConnection(row.MouseButton1Click:Connect(function() setter(not getter()); refresh() end))
        return row
    end
    local function button(parentObject, labelText, callback, danger)
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, 0, 0, 38); item.BackgroundColor3 = danger and Color3.fromRGB(75, 31, 39) or palette.input
        item.Text = labelText; item.TextColor3 = danger and palette.bad or palette.accent
        item.TextSize = 12; item.Font = Enum.Font.GothamBold; item.Parent = parentObject; corner(item, 8)
        trackConnection(item.MouseButton1Click:Connect(callback)); return item
    end
    local function splitCsv(value, maximum)
        local result, seen = {}, {}
        for part in tostring(value or ""):gmatch("[^,\n]+") do
            local item = safeText(part, 100)
            local key = lower(item)
            if item ~= "" and not seen[key] and #result < (maximum or 100) then
                seen[key] = true; table.insert(result, item)
            end
        end
        return result
    end
    local function webhookInput(page, labelText, key)
        input(page, labelText, Config[key], function(value, field)
            if trim(value) == "" then Config[key] = ""; field.Text = ""; setStatus(labelText .. " cleared"); return end
            local normalized, err = validateWebhook(value)
            if normalized then Config[key] = normalized; field.Text = "Webhook configured — replace to change"; setStatus(labelText .. " accepted: " .. maskWebhook(normalized))
            else field.Text = Config[key] ~= "" and "Webhook configured — replace to change" or ""; setStatus("Invalid webhook: " .. err) end
        end, true)
    end

    local overview = newPage("Overview", "Live status, delivery queue, player context, and module health.")
    local overviewCard = card(overview, "Runtime status")
    local overviewText = textLabel(overviewCard, "", 12, palette.muted, false); overviewText.Size = UDim2.new(1, 0, 0, 90)
    local function refreshOverview()
        overviewText.Text = string.format("Player: %s\nPlayers in server: %d   •   Queue: %d\nSent: %d catches, %d global, %d player, %d event, %d crystal, %d AFK\nFiltered catches: %d",
            LocalPlayer and LocalPlayer.Name or "Unavailable", #Players:GetPlayers(), #Runtime.Queue,
            Runtime.Stats.catches, Runtime.Stats.globalCatches, Runtime.Stats.players, Runtime.Stats.events, Runtime.Stats.crystals, Runtime.Stats.afk, Runtime.Stats.filtered)
    end
    refreshOverview(); button(overview, "Refresh dashboard", refreshOverview)
    local safety = card(overview, "Safety profile")
    textLabel(safety, "No embedded webhook • No license lock • No hidden logging • No remote code update • Credentials masked in status", 11, palette.good, false).Size = UDim2.new(1, 0, 0, 38)

    local webhooks = newPage("Webhooks", "Configure visible destinations. Empty specialized destinations fall back to Main.")
    webhookInput(webhooks, "Main webhook", "MainWebhook")
    webhookInput(webhooks, "Player webhook", "PlayerWebhook")
    webhookInput(webhooks, "Event webhook", "EventWebhook")
    webhookInput(webhooks, "Global catch webhook", "GlobalWebhook")
    input(webhooks, "Webhook display name", Config.BotName, function(value, field) Config.BotName = safeText(value, 80); field.Text = Config.BotName end)
    input(webhooks, "Webhook avatar URL", Config.BotAvatar, function(value, field) Config.BotAvatar = trim(value); field.Text = Config.BotAvatar end)
    button(webhooks, "Send test notification", Runtime.TestWebhook)

    local catches = newPage("Catches", "Catch parser, rarity routing, custom fish, mutations, and source watchers.")
    local sourceCard = card(catches, "Detection sources")
    toggle(sourceCard, "Catch notifications", function() return Config.CatchNotifications end, function(v) Config.CatchNotifications = v end)
    toggle(sourceCard, "Global catch notifications", function() return Config.GlobalCatchNotifications end, function(v) Config.GlobalCatchNotifications = v end)
    toggle(sourceCard, "Watch chat messages", function() return Config.WatchChat end, function(v) Config.WatchChat = v end)
    toggle(sourceCard, "Watch visible game text", function() return Config.WatchVisibleText end, function(v) Config.WatchVisibleText = v end)
    local rarityCard = card(catches, "Rarity filters")
    for _, rarity in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Forgotten", "Custom" }) do
        toggle(rarityCard, rarity, function() return Config.EnabledRarities[rarity] == true end, function(v) Config.EnabledRarities[rarity] = v end)
    end
    input(catches, "Custom fish names (comma separated)", table.concat(Config.CustomFishNames, ", "), function(value, field) Config.CustomFishNames = splitCsv(value, 200); field.Text = table.concat(Config.CustomFishNames, ", ") end)
    input(catches, "Custom mutations (comma separated)", table.concat(Config.CustomMutations, ", "), function(value, field) Config.CustomMutations = splitCsv(value, 200); field.Text = table.concat(Config.CustomMutations, ", ") end)
    local layoutCard = card(catches, "Embed layout and formatting")
    input(layoutCard, "Embed layout (1, 2, or 3)", Config.EmbedLayout, function(value, field)
        Config.EmbedLayout = math.floor(clampNumber(value, 1, 3, 1)); field.Text = tostring(Config.EmbedLayout)
    end)
    input(layoutCard, "Catch title template", Config.CatchTitleTemplate, function(value, field) Config.CatchTitleTemplate = safeText(value, 250); field.Text = Config.CatchTitleTemplate end)
    input(layoutCard, "Catch description template", Config.CatchDescriptionTemplate, function(value, field) Config.CatchDescriptionTemplate = safeText(value, 500); field.Text = Config.CatchDescriptionTemplate end)
    input(layoutCard, "Footer template", Config.FooterTemplate, function(value, field) Config.FooterTemplate = safeText(value, 250); field.Text = Config.FooterTemplate end)
    input(layoutCard, "Notification prefix", Config.NotificationPrefix, function(value, field) Config.NotificationPrefix = safeText(value, 80); field.Text = Config.NotificationPrefix end)
    input(layoutCard, "Fallback fish image URL or asset ID", Config.DefaultFishThumbnail, function(value, field) Config.DefaultFishThumbnail = trim(value); field.Text = Config.DefaultFishThumbnail end)
    textLabel(layoutCard, "Template variables: {player}, {fish}, {weight}, {mutation}, {rarity}, {location}, {date}, {version}", 10, palette.muted, false).Size = UDim2.new(1, 0, 0, 34)

    local playersPage = newPage("Players", "Join, leave, avatar-ready identity, and inactivity monitoring.")
    local playerCard = card(playersPage, "Player tracking")
    toggle(playerCard, "Join and leave notifications", function() return Config.PlayerNotifications end, function(v) Config.PlayerNotifications = v end)
    toggle(playerCard, "AFK notifications", function() return Config.AfkNotifications end, function(v) Config.AfkNotifications = v end)
    input(playersPage, "AFK threshold in seconds", Config.AfkThresholdSeconds, function(value, field) Config.AfkThresholdSeconds = clampNumber(value, 60, 86400, 300); field.Text = tostring(Config.AfkThresholdSeconds) end)
    button(playersPage, "Test player notification", function()
        Runtime.EmitPlayer({ action = "joined", name = LocalPlayer and LocalPlayer.Name or "DENG Test", userId = LocalPlayer and LocalPlayer.UserId or 0 })
    end)
    button(playersPage, "Test AFK notification", function() Runtime.EmitAFK({ name = LocalPlayer and LocalPlayer.Name or "DENG Test", seconds = Config.AfkThresholdSeconds }) end)

    local eventsPage = newPage("Events", "General, administrator, server-luck, and crystal transition notifications.")
    local eventCard = card(eventsPage, "Event modules")
    toggle(eventCard, "General event notifications", function() return Config.EventNotifications end, function(v) Config.EventNotifications = v end)
    toggle(eventCard, "Server luck detection", function() return Config.ServerLuckNotifications end, function(v) Config.ServerLuckNotifications = v; if v then Config.EventNotifications = true end end)
    toggle(eventCard, "Administrator event detection", function() return Config.AdminEventNotifications end, function(v) Config.AdminEventNotifications = v; if v then Config.EventNotifications = true end end)
    toggle(eventCard, "Crystal and gemstone detection", function() return Config.CrystalNotifications end, function(v) Config.CrystalNotifications = v end)
    button(eventsPage, "Test general event", function() Runtime.EmitEvent({ name = "DENG Event Test", state = "active" }) end)
    button(eventsPage, "Test crystal event", function() Runtime.EmitCrystal({ name = "DENG Crystal Test", detail = "Crystal notification routing is working." }) end)

    local settings = newPage("Settings", "Mentions, persistence, lifecycle, and manual integration API.")
    input(settings, "Discord user IDs (comma separated)", table.concat(Config.MentionUserIds, ", "), function(value, field) Config.MentionUserIds = normalizeSnowflakeList(splitCsv(value, 50)); field.Text = table.concat(Config.MentionUserIds, ", ") end)
    input(settings, "Discord role IDs (comma separated)", table.concat(Config.MentionRoleIds, ", "), function(value, field) Config.MentionRoleIds = normalizeSnowflakeList(splitCsv(value, 50)); field.Text = table.concat(Config.MentionRoleIds, ", ") end)
    local mentionCard = card(settings, "Mention policy")
    toggle(mentionCard, "Allow @everyone", function() return Config.AllowEveryoneMention end, function(v) Config.AllowEveryoneMention = v end)
    button(settings, "Save configuration", Runtime.SaveConfig)
    button(settings, "Reload saved configuration", function() local ok, err = loadConfig(); setStatus(ok and "Configuration reloaded" or tostring(err)) end)
    button(settings, "Unload DENG Fish Webhook", Runtime.Unload, true)
    local apiCard = card(settings, "Manual adapter API")
    textLabel(apiCard, "_G.DENGFishWebhook.EmitCatch(data)\n_G.DENGFishWebhook.EmitPlayer(data)\n_G.DENGFishWebhook.EmitEvent(data)\n_G.DENGFishWebhook.EmitCrystal(data)", 11, palette.muted, false).Size = UDim2.new(1, 0, 0, 72)

    for _, name in ipairs({ "Overview", "Webhooks", "Catches", "Players", "Events", "Settings" }) do nav(name) end
    showPage("Overview")

    local collapsed = false
    trackConnection(minimize.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        sidebar.Visible = not collapsed; content.Visible = not collapsed; statusBar.Visible = not collapsed
        root.Size = collapsed and UDim2.new(0, 260, 0, 60) or UDim2.new(0, 720, 0, 500)
        minimize.Text = collapsed and "+" or "—"
    end))
    local dragging, dragStart, startPosition = false, nil, nil
    trackConnection(header.InputBegan:Connect(function(inputObject)
        if inputObject.UserInputType == Enum.UserInputType.MouseButton1 or inputObject.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = inputObject.Position; startPosition = root.Position
        end
    end))
    trackConnection(header.InputEnded:Connect(function(inputObject)
        if inputObject.UserInputType == Enum.UserInputType.MouseButton1 or inputObject.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
    local UserInputService = game:GetService("UserInputService")
    trackConnection(UserInputService.InputChanged:Connect(function(inputObject)
        if dragging and (inputObject.UserInputType == Enum.UserInputType.MouseMovement or inputObject.UserInputType == Enum.UserInputType.Touch) then
            local delta = inputObject.Position - dragStart
            root.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
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
installFishDatabaseWatcher()
installCatchRemoteWatcher()
installAfkTracker()
installFeatureStateTracker()

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

setStatus(Request and "Ready — executor HTTP detected" or "Ready — using Roblox HTTP fallback")

return Runtime
