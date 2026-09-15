-- ============================================================
-- EventTrigger/EventTriggerPersistence.lua — JSON file I/O (ElyonLib)
-- References BulletinBoard/Persistence.lua implementation pattern
-- ============================================================

local JSON = require("ElyonLib/FileUtils/JSON")
local Shared = require("EventTriggerShared")

local Persistence = {}

-- ============================================================
-- Low-level utility functions
-- ============================================================

-- Read JSON file, return nil on failure
local function readJsonQuiet(filePath)
    local reader = getFileReader(filePath, false)
    if not reader then return nil end
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
    return nil
end

-- Write JSON file, return success/failure
local function writeJsonQuiet(filePath, data)
    local ok, content = pcall(JSON.stringify, data)
    if not ok then return false end
    local writer = getFileWriter(filePath, true, false)
    if not writer then return false end
    writer:write(content)
    writer:close()
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
        if type(trigger) == "table" and trigger.id then
            -- Fill in potentially missing fields (backward compatibility)
            trigger.triggerCount  = trigger.triggerCount or 0
            trigger.range          = trigger.range or 2
            trigger.delay          = trigger.delay or 3
            trigger.outputType     = trigger.outputType or Shared.OutputType.HALO
            trigger.outputName     = trigger.outputName or ""
            trigger.maxTriggers    = trigger.maxTriggers or -1
            trigger.creator        = trigger.creator or "unknown"
            trigger.createdAt      = trigger.createdAt or os.time()
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

-- Delete single trigger from disk and update index
function Persistence.deleteOneTrigger(triggerId)
    -- PZ has no file deletion API, write empty table marker
    local filePath = Shared.DATA_DIR .. "/" .. triggerId .. ".json"
    writeJsonQuiet(filePath, { _deleted = true, id = triggerId })
    -- Remove from index
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

-- Delete history file for a trigger
function Persistence.deleteHistory(triggerId)
    writeJsonQuiet(historyFilePath(triggerId), { _deleted = true, triggerId = triggerId })
    return true
end

-- Append a history entry and save
function Persistence.appendHistory(triggerId, entry)
    local entries = Persistence.loadHistory(triggerId)
    entries[#entries + 1] = entry
    return Persistence.saveHistory(triggerId, entries)
end

return Persistence
