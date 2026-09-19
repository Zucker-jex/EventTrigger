-- ============================================================
-- EventTrigger/Persistence.lua — JSON file I/O (ElyonLib)
-- References BulletinBoard/Persistence.lua implementation pattern
-- ============================================================

local JSON = require("ElyonLib/FileUtils/JSON")
local Shared = require("EventTrigger/Shared")

local Persistence = {}

-- ============================================================
-- Log helper (safe server-side print)
-- ============================================================
local function log(msg)
    pcall(print, "[EventTrigger-IO] " .. tostring(msg))
end

-- ============================================================
-- Low-level utility functions
-- ============================================================

-- Read JSON file, return nil on failure
local function readJsonQuiet(filePath)
    local reader = getFileReader(filePath, false)
    if not reader then
        log("read FAILED (no reader): " .. tostring(filePath))
        return nil
    end
    local lines = {}
    local line = reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    local content = table.concat(lines, "\n")
    if content == "" then return nil end
    local ok, data = pcall(JSON.parse, content)
    if ok then return data end
    log("read FAILED (parse error): " .. tostring(filePath) .. " raw=" .. string.sub(content, 1, 120))
    return nil
end

-- Write JSON file, return success/failure
-- PZ B42.19: getFileWriter(path, true, false) returns nil for NEW files
-- Fix: create with append=true first, then overwrite with append=false
local function writeJsonQuiet(filePath, data)
    local ok, content = pcall(JSON.stringify, data)
    if not ok then
        log("stringify FAILED: " .. tostring(filePath) .. " -> " .. tostring(content))
        return false
    end
    local writer = getFileWriter(filePath, true, false)
    if not writer then
        local tmp = getFileWriter(filePath, true, true)
        if tmp then tmp:write(content); tmp:close() end
        writer = getFileWriter(filePath, true, false)
    end
    if not writer then
        log("getFileWriter FAILED: " .. tostring(filePath))
        return false
    end
    writer:write(content)
    writer:close()
    log("wrote: " .. tostring(filePath) .. " (" .. #content .. " bytes)")
    return true
end

-- ============================================================
-- Trigger JSON file operations
-- ============================================================

-- Load all triggers from disk (via index.json index file)
function Persistence.loadTriggers()
    local index = readJsonQuiet(Shared.INDEX_FILE)
    if type(index) ~= "table" or type(index.triggerIds) ~= "table" then
        return {}
    end
    local triggers = {}
    for i = 1, #index.triggerIds do
        local filePath = Shared.DATA_DIR .. "/" .. index.triggerIds[i] .. ".json"
        local trigger = readJsonQuiet(filePath)
        if type(trigger) == "table" and trigger.id and not trigger._deleted then
            -- Fill in potentially missing fields (backward compatibility)
            trigger.triggerCount  = trigger.triggerCount or 0
            trigger.range          = trigger.range or 2
            trigger.delay          = trigger.delay or 3
            trigger.outputType     = trigger.outputType or Shared.OutputType.HALO
            trigger.outputName     = trigger.outputName or ""
            trigger.maxTriggers    = trigger.maxTriggers or -1
            trigger.creator        = trigger.creator or "unknown"
            trigger.createdAt      = trigger.createdAt or os.time()
            trigger.cooldown       = Shared.makeCooldown(trigger.cooldown or trigger)
            trigger.enabled        = trigger.enabled ~= false
            if trigger.lastTriggerAt == nil then trigger.lastTriggerAt = nil end
            triggers[#triggers + 1] = trigger
        end
    end
    return triggers
end

-- Save all triggers to disk (one JSON file per trigger + index.json)
function Persistence.saveTriggers(triggers)
    triggers = type(triggers) == "table" and triggers or {}
    -- Limit max count (remove oldest)
    if #triggers > Shared.MAX_TRIGGERS then
        local keep = {}
        for i = #triggers - Shared.MAX_TRIGGERS + 1, #triggers do
            keep[#keep + 1] = triggers[i]
        end
        triggers = keep
    end
    local triggerIds = {}
    local ok = true
    for i = 1, #triggers do
        local t = triggers[i]
        if type(t) == "table" and t.id then
            triggerIds[#triggerIds + 1] = t.id
            local filePath = Shared.DATA_DIR .. "/" .. t.id .. ".json"
            ok = writeJsonQuiet(filePath, t) and ok
        end
    end
    ok = writeJsonQuiet(Shared.INDEX_FILE, Shared.makeIndexData(triggerIds)) and ok
    return ok
end

-- Save single trigger to disk and update index (incremental update, efficient)
function Persistence.saveOneTrigger(trigger)
    if type(trigger) ~= "table" or not trigger.id then return false end
    -- Write trigger file
    local filePath = Shared.DATA_DIR .. "/" .. trigger.id .. ".json"
    if not writeJsonQuiet(filePath, trigger) then return false end
    -- Update index (append ID if not in index)
    local index = readJsonQuiet(Shared.INDEX_FILE)
    local triggerIds = {}
    if type(index) == "table" and type(index.triggerIds) == "table" then
        triggerIds = index.triggerIds
    end
    local found = false
    for _, tid in ipairs(triggerIds) do
        if tid == trigger.id then found = true; break end
    end
    if not found then
        triggerIds[#triggerIds + 1] = trigger.id
    end
    return writeJsonQuiet(Shared.INDEX_FILE, Shared.makeIndexData(triggerIds))
end

-- Remove trigger from index (PZ has no file deletion API, old JSON remains but won't be loaded)
function Persistence.deleteOneTrigger(triggerId)
    local index = readJsonQuiet(Shared.INDEX_FILE)
    local triggerIds = {}
    if type(index) == "table" and type(index.triggerIds) == "table" then
        for _, tid in ipairs(index.triggerIds) do
            if tid ~= triggerId then
                triggerIds[#triggerIds + 1] = tid
            end
        end
    end
    return writeJsonQuiet(Shared.INDEX_FILE, Shared.makeIndexData(triggerIds))
end

-- ============================================================
-- Trigger history JSON file operations
-- ============================================================

-- Get trigger history file path
local function historyFilePath(triggerId)
    return Shared.HISTORY_DIR .. "/" .. triggerId .. ".json"
end

-- Load history for a specific trigger
function Persistence.loadHistory(triggerId)
    local data = readJsonQuiet(historyFilePath(triggerId))
    if type(data) == "table" and type(data.entries) == "table" then
        return data.entries
    end
    return {}
end

-- Save history for a specific trigger (limit max entries)
function Persistence.saveHistory(triggerId, entries)
    entries = type(entries) == "table" and entries or {}
    -- Limit max entries
    if #entries > Shared.MAX_HISTORY_PER_TRIGGER then
        local trimmed = {}
        for i = #entries - Shared.MAX_HISTORY_PER_TRIGGER + 1, #entries do
            trimmed[#trimmed + 1] = entries[i]
        end
        entries = trimmed
    end
    local data = Shared.makeHistoryData(triggerId, entries)
    return writeJsonQuiet(historyFilePath(triggerId), data)
end

-- Delete history file for a trigger (PZ has no file deletion API, just return success)
function Persistence.deleteHistory(triggerId)
    return true
end

-- Append a history entry and save
function Persistence.appendHistory(triggerId, entry)
    local entries = Persistence.loadHistory(triggerId)
    entries[#entries + 1] = entry
    return Persistence.saveHistory(triggerId, entries)
end

-- ============================================================
-- Delivery Point JSON file operations
-- ============================================================

-- Load all delivery points from disk (via delivery/index.json)
function Persistence.loadDeliveryPoints()
    local index = readJsonQuiet(Shared.DELIVERY_INDEX_FILE)
    if type(index) ~= "table" or type(index.deliveryIds) ~= "table" then
        return {}
    end
    local points = {}
    for i = 1, #index.deliveryIds do
        local filePath = Shared.DELIVERY_DIR .. "/" .. index.deliveryIds[i] .. ".json"
        local dp = readJsonQuiet(filePath)
        if type(dp) == "table" and dp.id and not dp._deleted and dp.type == "delivery" then
            dp.hintText      = dp.hintText or "Delivery Point"
            dp.range         = dp.range or 3
            dp.maxPlayers    = dp.maxPlayers or -1
            dp.maxPerPlayer  = dp.maxPerPlayer or -1
            dp.requiredItems = dp.requiredItems or {}
            dp.rewardItems   = dp.rewardItems or {}
            dp.branches      = dp.branches or {}
            dp.playerDeliveries = dp.playerDeliveries or {}
            dp.cooldown      = Shared.makeCooldown(dp.cooldown or dp)
            dp.playerCooldowns = dp.playerCooldowns or {}
            dp.triggerCount  = dp.triggerCount or 0
            dp.triggeredBy   = dp.triggeredBy or {}
            dp.enabled       = dp.enabled ~= false
            dp.creator       = dp.creator or "unknown"
            dp.createdAt     = dp.createdAt or os.time()
            points[#points + 1] = dp
        end
    end
    return points
end

-- Save all delivery points to disk
function Persistence.saveDeliveryPoints(points)
    points = type(points) == "table" and points or {}
    if #points > Shared.MAX_DELIVERY_POINTS then
        local keep = {}
        for i = #points - Shared.MAX_DELIVERY_POINTS + 1, #points do
            keep[#keep + 1] = points[i]
        end
        points = keep
    end
    local ids = {}
    local ok = true
    for i = 1, #points do
        local dp = points[i]
        if type(dp) == "table" and dp.id then
            ids[#ids + 1] = dp.id
            local filePath = Shared.DELIVERY_DIR .. "/" .. dp.id .. ".json"
            ok = writeJsonQuiet(filePath, dp) and ok
        end
    end
    ok = writeJsonQuiet(Shared.DELIVERY_INDEX_FILE, Shared.makeDeliveryIndexData(ids)) and ok
    return ok
end

-- Save single delivery point to disk
function Persistence.saveOneDeliveryPoint(dp)
    if type(dp) ~= "table" or not dp.id then return false end
    local filePath = Shared.DELIVERY_DIR .. "/" .. dp.id .. ".json"
    if not writeJsonQuiet(filePath, dp) then return false end
    local index = readJsonQuiet(Shared.DELIVERY_INDEX_FILE)
    local ids = {}
    if type(index) == "table" and type(index.deliveryIds) == "table" then
        ids = index.deliveryIds
    end
    local found = false
    for _, did in ipairs(ids) do
        if did == dp.id then found = true; break end
    end
    if not found then
        ids[#ids + 1] = dp.id
    end
    return writeJsonQuiet(Shared.DELIVERY_INDEX_FILE, Shared.makeDeliveryIndexData(ids))
end

-- Remove delivery point from index
function Persistence.deleteOneDeliveryPoint(dpId)
    local index = readJsonQuiet(Shared.DELIVERY_INDEX_FILE)
    local ids = {}
    if type(index) == "table" and type(index.deliveryIds) == "table" then
        for _, did in ipairs(index.deliveryIds) do
            if did ~= dpId then
                ids[#ids + 1] = did
            end
        end
    end
    return writeJsonQuiet(Shared.DELIVERY_INDEX_FILE, Shared.makeDeliveryIndexData(ids))
end

return Persistence
