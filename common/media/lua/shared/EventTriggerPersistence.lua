-- ============================================================
-- EventTrigger/EventTriggerPersistence.lua — JSON 文件读写（基于 ElyonLib）
-- 参考 BulletinBoard/Persistence.lua 的实现模式
-- ============================================================

local JSON = require("ElyonLib/FileUtils/JSON")
local Shared = require("EventTriggerShared")

local Persistence = {}

-- ============================================================
-- 底层工具函数
-- ============================================================

-- 读取 JSON 文件，失败时返回 nil
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

-- 写入 JSON 文件，返回成功/失败
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
-- 触发器 JSON 文件操作
-- ============================================================

-- 从磁盘加载全部触发器（通过 index.json 索引文件）
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
            -- 补齐可能缺失的字段（向后兼容）
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

-- 将全部触发器写入磁盘（每个触发器一个 JSON 文件 + index.json）
function Persistence.saveTriggers(triggers)
    triggers = type(triggers) == "table" and triggers or {}
    -- 数量上限限制（超出时丢弃最旧的）
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

-- 保存单个触发器到磁盘并更新索引（增量更新，效率更高）
function Persistence.saveOneTrigger(trigger)
    if type(trigger) ~= "table" or not trigger.id then return false end
    -- 写入触发器文件
    local filePath = Shared.DATA_DIR .. "/" .. trigger.id .. ".json"
    if not writeJsonQuiet(filePath, trigger) then return false end
    -- 更新索引（若 ID 不在索引中则追加）
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

-- 从磁盘删除单个触发器并更新索引
function Persistence.deleteOneTrigger(triggerId)
    -- PZ 无文件删除 API，写入空表标记
    local filePath = Shared.DATA_DIR .. "/" .. triggerId .. ".json"
    writeJsonQuiet(filePath, { _deleted = true, id = triggerId })
    -- 从索引中移除
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
-- 触发器历史 JSON 文件操作
-- ============================================================

-- 获取触发器历史文件路径
local function historyFilePath(triggerId)
    return Shared.HISTORY_DIR .. "/" .. triggerId .. ".json"
end

-- 加载指定触发器的历史记录
function Persistence.loadHistory(triggerId)
    local data = readJsonQuiet(historyFilePath(triggerId))
    if type(data) == "table" and type(data.entries) == "table" then
        return data.entries
    end
    return {}
end

-- 保存指定触发器的历史记录（限制最大条目数）
function Persistence.saveHistory(triggerId, entries)
    entries = type(entries) == "table" and entries or {}
    -- 条目数上限限制
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

-- 删除指定触发器的历史文件
function Persistence.deleteHistory(triggerId)
    writeJsonQuiet(historyFilePath(triggerId), { _deleted = true, triggerId = triggerId })
    return true
end

-- 追加一条历史记录并保存
function Persistence.appendHistory(triggerId, entry)
    local entries = Persistence.loadHistory(triggerId)
    entries[#entries + 1] = entry
    return Persistence.saveHistory(triggerId, entries)
end

return Persistence
