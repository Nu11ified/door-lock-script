-- Door Lock Server Script: Doorgun System with SQLite Persistence, Admin Check, and Best Practices
-- DB backend: oxmysql

-- config.lua is loaded via fxmanifest.lua server_scripts

local doors = {} -- [netId] = {locked=true/false, keyType="LEO_Key", lastUnlocked=timestamp}
local discordRateLimit = {} -- [discord_id] = retryAfterTimestamp

-- SQLite helpers with error logging
local function exec(sql, params)
    exports.oxmysql:execute(sql, params or {}, function(result, err)
        if err then print("[Doorgun] DB Error:", err) end
    end)
end
local function query(sql, params, cb)
    exports.oxmysql:execute(sql, params or {}, function(result, err)
        if err then print("[Doorgun] DB Error:", err) end
        if cb then cb(result, err) end
    end)
end

-- Add chat suggestions on resource start
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    TriggerClientEvent('chat:addSuggestion', -1, '/doorgun leokey', 'Enable doorgun mode for LEO key')
    TriggerClientEvent('chat:addSuggestion', -1, '/doorgun safdkey', 'Enable doorgun mode for SAFD key')
    TriggerClientEvent('chat:addSuggestion', -1, '/doorgunremoval', 'Enable doorgun removal mode')
    exec([[CREATE TABLE IF NOT EXISTS doors (
        netId INTEGER PRIMARY KEY,
        keyType TEXT,
        locked INTEGER,
        lastUnlocked INTEGER
    )]])
    -- Load all doors
    query("SELECT * FROM doors", {}, function(results)
        for _, row in ipairs(results) do
            doors[row.netId] = {
                locked = row.locked == 1,
                keyType = row.keyType,
                lastUnlocked = row.lastUnlocked or 0
            }
        end
    end)
end)

-- Helper: Sync door state to all clients
local function syncDoorState(netId)
    local data = doors[netId]
    if data then
        TriggerClientEvent('doorgun:updateDoorState', -1, netId, data.locked, data.keyType)
    end
end

-- Helper: Send all door states to a client
local function sendAllDoorStates(target)
    for netId, data in pairs(doors) do
        TriggerClientEvent('doorgun:updateDoorState', target, netId, data.locked, data.keyType)
    end
end

-- Discord role check wrapper with rate limit handling and error logging
local function checkRoleWithRateLimit(discord_id, role_array, cb)
    local now = os.time()
    print("[Doorgun] Starting Discord API check for user:", discord_id, "roles:", json.encode(role_array))
    if discordRateLimit[discord_id] and discordRateLimit[discord_id] > now then
        print("[Doorgun] Discord API rate limited for user:", discord_id, "until", discordRateLimit[discord_id], "(now:", now, ")")
        cb(false)
        return
    end
    local url = ("https://discord.com/api/v10/guilds/%s/members/%s"):format(DISCORD_GUILD_ID, discord_id)
    local headers = { ["Authorization"] = "Bot " .. DISCORD_BOT_TOKEN }
    print("[Doorgun] Performing HTTP GET:", url)
    local errorCode, resultData, resultHeaders = PerformHttpRequestAwait(url, 'GET', '', headers)
    print("[Doorgun] Discord API response for user:", discord_id, "status:", errorCode)
    if type(resultHeaders) == "table" then
        print("[Doorgun] Discord API headers:", json.encode(resultHeaders))
    end
    if errorCode == 429 then
        local retryAfter = 60 -- default fallback
        if type(resultHeaders) == "table" and resultHeaders["Retry-After"] then
            retryAfter = tonumber(resultHeaders["Retry-After"]) or retryAfter
        end
        discordRateLimit[discord_id] = now + retryAfter
        print("[Doorgun] Discord API 429 for user:", discord_id, "Retry after:", retryAfter, "seconds (until", discordRateLimit[discord_id], ")")
        cb(false)
        return
    end
    if errorCode ~= 200 then
        print("[Doorgun] Discord API error for user:", discord_id, "status:", errorCode, "body:", resultData)
        cb(false)
        return
    end
    local data = json.decode(resultData)
    if not data or not data.roles then
        print("[Doorgun] Discord API: No roles found for user:", discord_id, "body:", resultData)
        cb(false)
        return
    end
    local found = false
    for _, role in ipairs(data.roles) do
        for _, key in ipairs(role_array) do
            if role == key then
                print("[Doorgun] Discord API: User", discord_id, "has required role:", role)
                found = true
                cb(true)
                return
            end
        end
    end
    print("[Doorgun] Discord API: User", discord_id, "does NOT have any required role.")
    cb(false)
end

-- Discord admin check (any role in ADMIN_ROLES)
local function isAdmin(discord_id, cb)
    checkRoleWithRateLimit(discord_id, ADMIN_ROLES, cb)
end

-- Discord key check (any role in key array)
local function checkPlayerHasKey(discord_id, keyType, cb)
    local key_array = _G[keyType]
    if not key_array then cb(false) return end
    checkRoleWithRateLimit(discord_id, key_array, cb)
end

-- Auto-lock thread
CreateThread(function()
    while true do
        Wait(10000) -- check every 10s
        local now = os.time()
        for netId, data in pairs(doors) do
            if not data.locked and data.lastUnlocked and (now - data.lastUnlocked) > 60 then
                data.locked = true
                exec("UPDATE doors SET locked = 1 WHERE netId = ?", {netId})
                syncDoorState(netId)
            end
        end
    end
end)

-- Register/toggle door event
RegisterNetEvent('doorgun:registerDoor')
AddEventHandler('doorgun:registerDoor', function(netId, keyType)
    local src = source
    local discord_id = nil
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:find("discord:") then
            discord_id = id:gsub("discord:", "")
            break
        end
    end
    if not discord_id then return end
    isAdmin(discord_id, function(is_admin)
        if not is_admin then return end
        checkPlayerHasKey(discord_id, keyType, function(hasKey)
            if not hasKey then return end
            local now = os.time()
            if not doors[netId] then
                doors[netId] = {locked=true, keyType=keyType, lastUnlocked=0}
                exec("INSERT OR REPLACE INTO doors (netId, keyType, locked, lastUnlocked) VALUES (?, ?, 1, 0)", {netId, keyType})
            else
                if doors[netId].locked then
                    doors[netId].locked = false
                    doors[netId].lastUnlocked = now
                    exec("UPDATE doors SET locked = 0, lastUnlocked = ? WHERE netId = ?", {now, netId})
                else
                    doors[netId].locked = true
                    exec("UPDATE doors SET locked = 1 WHERE netId = ?", {netId})
                end
            end
            syncDoorState(netId)
        end)
    end)
end)

-- Remove door event
RegisterNetEvent('doorgun:removeDoor')
AddEventHandler('doorgun:removeDoor', function(netId)
    local src = source
    local discord_id = nil
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:find("discord:") then
            discord_id = id:gsub("discord:", "")
            break
        end
    end
    if not discord_id then return end
    isAdmin(discord_id, function(is_admin)
        if not is_admin then return end
        doors[netId] = nil
        exec("DELETE FROM doors WHERE netId = ?", {netId})
        TriggerClientEvent('doorgun:removeDoorClient', -1, netId)
    end)
end)

local playerPerms = {} -- [src] = {isAdmin=bool, hasLEO=bool, hasSAFD=bool}

-- Helper to fetch all roles once and set permissions
local function fetchAndStorePerms(src, discord_id)
    local now = os.time()
    if discordRateLimit[discord_id] and discordRateLimit[discord_id] > now then
        print("[Doorgun] Skipping perms fetch (rate limited) for", discord_id)
        return
    end
    local url = ("https://discord.com/api/v10/guilds/%s/members/%s"):format(DISCORD_GUILD_ID, discord_id)
    local headers = { ["Authorization"] = "Bot " .. DISCORD_BOT_TOKEN }
    local status, body, hdrs = PerformHttpRequestAwait(url, 'GET', '', headers)
    if status == 429 then
        local retry = tonumber(hdrs and hdrs["Retry-After"] or 60) or 60
        discordRateLimit[discord_id] = now + retry
        print("[Doorgun] Rate limited while fetching perms for", discord_id)
        return
    end
    if status ~= 200 then
        print("[Doorgun] Failed to fetch perms for", discord_id, "status", status)
        return
    end
    local data = json.decode(body)
    if not data or not data.roles then return end
    local roles = data.roles
    local function hasAny(roleArray)
        for _, r in ipairs(roles) do
            for _, k in ipairs(roleArray) do
                if r == k then return true end
            end
        end
        return false
    end
    local perms = {
        isAdmin = hasAny(ADMIN_ROLES),
        hasLEO = hasAny(LEO_Key),
        hasSAFD = hasAny(SAFD_Key)
    }
    playerPerms[src] = perms
    print(string.format("[Doorgun] Player %s perms -> admin:%s LEO:%s SAFD:%s", GetPlayerName(src), tostring(perms.isAdmin), tostring(perms.hasLEO), tostring(perms.hasSAFD)))
    TriggerClientEvent('doorgun:setPerms', src, perms)
end

-- Update playerConnecting handler
AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    local src = source
    sendAllDoorStates(src)
    -- extract discord id
    local discord_id
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:find("discord:") then discord_id = id:gsub("discord:", "") break end
    end
    if discord_id then
        fetchAndStorePerms(src, discord_id)
    else
        print("[Doorgun] Player", name, "has no discord identifier, no perms fetched")
    end
end)

-- Clean up perms on drop
AddEventHandler('playerDropped', function()
    playerPerms[source] = nil
end)


AddEventHandler('playerSpawned', function()
    local src = source
    sendAllDoorStates(src)
end) 

-- User toggles door lock/unlock (must have correct key role, not admin)
RegisterNetEvent('doorgun:toggleDoor')
AddEventHandler('doorgun:toggleDoor', function(netId)
    local src = source
    local discord_id = nil
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:find("discord:") then
            discord_id = id:gsub("discord:", "")
            break
        end
    end
    if not discord_id then print("[Doorgun] No discord ID for user", src) return end
    local door = doors[netId]
    if not door then print("[Doorgun] No door found for netId", netId) return end
    print("[Doorgun] User", discord_id, "attempting to toggle door", netId, "(keyType:", door.keyType, ")")
    checkPlayerHasKey(discord_id, door.keyType, function(hasKey)
        if not hasKey then print("[Doorgun] User", discord_id, "does not have required key role for door", netId) return end
        door.locked = not door.locked
        if door.locked then
            exec("UPDATE doors SET locked = 1 WHERE netId = ?", {netId})
        else
            local now = os.time()
            door.lastUnlocked = now
            exec("UPDATE doors SET locked = 0, lastUnlocked = ? WHERE netId = ?", {now, netId})
        end
        print("[Doorgun] Door", netId, "state toggled to", door.locked and "locked" or "unlocked")
        syncDoorState(netId)
    end)
end) 