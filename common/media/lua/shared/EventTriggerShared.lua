-- ============================================================
-- EventTrigger/EventTriggerShared.lua — 常量、指令、数据结构
-- ============================================================

local EventTriggerShared = {}

EventTriggerShared.VERSION = 1
EventTriggerShared.MOD_ID = "EventTrigger"
EventTriggerShared.MODULE = "EventTrigger"
EventTriggerShared.DATA_DIR = "EventTrigger"
EventTriggerShared.HISTORY_DIR = EventTriggerShared.DATA_DIR .. "/history"

EventTriggerShared.INDEX_FILE = EventTriggerShared.DATA_DIR .. "/index.json"

-- 触发器数量上限（防止无限增长）
EventTriggerShared.MAX_TRIGGERS = 200

-- 每个触发器保留的历史记录条数上限
EventTriggerShared.MAX_HISTORY_PER_TRIGGER = 50

-- ============================================================
-- 指令协议（客户端 <-> 服务器）
-- ============================================================
EventTriggerShared.COMMANDS = {
    -- 客户端请求同步（登录时 / 手动刷新）
    REQUEST_SYNC      = "requestSync",
    -- 服务器向单个客户端推送全部触发器
    SYNC_STATE        = "syncAll",
    -- 服务器向所有客户端广播全部触发器（CRUD 之后）
    BROADCAST_ALL     = "broadcastAll",

    -- CRUD 操作（客户端 -> 服务器）
    PLACE_TRIGGER     = "placeTrigger",
    DELETE_TRIGGER    = "deleteTrigger",
    RESET_TRIGGER     = "resetTrigger",
    DELETE_ALL        = "deleteAllTriggers",
    EDIT_MESSAGE      = "editTriggerMessage",
    EDIT_PARAMS       = "editTriggerParams",
    EDIT_OUTPUT       = "editTriggerOutput",

    -- 触发记录（客户端 -> 服务器）
    RECORD_TRIGGER    = "recordTrigger",

    -- 通知（服务器 -> 客户端）
    NAMED_MESSAGE     = "namedMessage",
    NOTIFY            = "notify",
}

-- ============================================================
-- 触发器输出类型枚举
-- ============================================================
EventTriggerShared.OutputType = {
    NAMED = 1,  -- 具名 + 系统频道
    SAY   = 2,  -- /say + 气泡
    DO    = 3,  -- /do 环境旁白
    LOW   = 4,  -- /low + 气泡
    YELL  = 5,  -- /yell + 气泡
    OOC   = 6,  -- /ooc 全局 OOC
    HALO  = 7,  -- 头顶漂浮文字
}

-- ============================================================
-- ID 生成（服务器端唯一）
-- ============================================================
EventTriggerShared.generateId = function()
    local rand = ZombRand(100000, 999999)
    return "et_" .. tostring(os.time()) .. "_" .. tostring(rand)
end

-- ============================================================
-- 构建完整触发器对象（工厂函数，确保字段完整）
-- ============================================================
EventTriggerShared.makeTrigger = function(args)
    return {
        id          = args.id or EventTriggerShared.generateId(),
        x           = args.x or 0,
        y           = args.y or 0,
        z           = args.z or 0,
        message     = tostring(args.message or "Trigger activated!"):sub(1, 500),
        delay       = math.max(0, args.delay or 3),
        range       = math.max(0.5, args.range or 2),
        outputType  = args.outputType or EventTriggerShared.OutputType.HALO,
        outputName  = tostring(args.outputName or ""):sub(1, 100),
        maxTriggers = args.maxTriggers or -1,
        triggerCount = args.triggerCount or 0,
        creator     = tostring(args.creator or "unknown"),
        createdAt   = args.createdAt or os.time(),
    }
end

-- ============================================================
-- 构建触发器历史记录条目
-- ============================================================
EventTriggerShared.makeHistoryEntry = function(playerId, timestamp, timeStr)
    return {
        playerId  = tostring(playerId or "Unknown"),
        timestamp = timestamp or 0,
        timeStr   = tostring(timeStr or ""),
    }
end

-- ============================================================
-- 构建服务器端存储的触发器历史文件数据
-- ============================================================
EventTriggerShared.makeHistoryData = function(triggerId, entries)
    return {
        triggerId = triggerId,
        version   = EventTriggerShared.VERSION,
        entries   = entries or {},
    }
end

-- ============================================================
-- 构建索引文件数据
-- ============================================================
EventTriggerShared.makeIndexData = function(triggerIds)
    return {
        version    = EventTriggerShared.VERSION,
        triggerIds = triggerIds or {},
    }
end

return EventTriggerShared
