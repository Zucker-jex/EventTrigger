-- ============================================================
-- EventTrigger/EventTriggerShared.lua — constants, commands, data structures
-- ============================================================

local EventTriggerShared = {}

EventTriggerShared.VERSION = 1
EventTriggerShared.MOD_ID = "EventTrigger"
EventTriggerShared.MODULE = "EventTrigger"
EventTriggerShared.DATA_DIR = "EventTrigger"
EventTriggerShared.HISTORY_DIR = EventTriggerShared.DATA_DIR .. "/history"

EventTriggerShared.INDEX_FILE = EventTriggerShared.DATA_DIR .. "/index.json"

-- Maximum trigger limit (prevent unbounded growth)
EventTriggerShared.MAX_TRIGGERS = 200

-- Maximum history entries retained per trigger
EventTriggerShared.MAX_HISTORY_PER_TRIGGER = 50

-- ============================================================
-- Command protocol (client <-> server)
-- ============================================================
EventTriggerShared.COMMANDS = {
    -- Client request sync (on login / manual refresh)
    REQUEST_SYNC      = "requestSync",
    -- Server pushes all triggers to a single client
    SYNC_STATE        = "syncAll",
    -- Server broadcasts all triggers to all clients (after CRUD)
    BROADCAST_ALL     = "broadcastAll",

    -- CRUD operations (client -> server)
    PLACE_TRIGGER     = "placeTrigger",
    DELETE_TRIGGER    = "deleteTrigger",
    RESET_TRIGGER     = "resetTrigger",
    DELETE_ALL        = "deleteAllTriggers",
    EDIT_MESSAGE      = "editTriggerMessage",
    EDIT_PARAMS       = "editTriggerParams",
    EDIT_OUTPUT       = "editTriggerOutput",

    -- Trigger recording (client -> server)
    RECORD_TRIGGER    = "recordTrigger",

    -- Notifications (server -> client)
    NAMED_MESSAGE     = "namedMessage",
    NOTIFY            = "notify",
}

-- ============================================================
-- Trigger output type enum
-- ============================================================
EventTriggerShared.OutputType = {
    NAMED = 1,  -- Named + system channel
    SAY   = 2,  -- /say + bubble
    DO    = 3,  -- /do environment narration
    LOW   = 4,  -- /low + bubble
    YELL  = 5,  -- /yell + bubble
    OOC   = 6,  -- /ooc global OOC
    HALO  = 7,  -- Floating text above head
}

-- ============================================================
-- ID generation (server-side unique)
-- ============================================================
EventTriggerShared.generateId = function()
    local rand = ZombRand(100000, 999999)
    return "et_" .. tostring(os.time()) .. "_" .. tostring(rand)
end

-- ============================================================
-- Build complete trigger object (factory function, ensure fields complete)
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
-- Build trigger history entry
-- ============================================================
EventTriggerShared.makeHistoryEntry = function(playerId, timestamp, timeStr)
    return {
        playerId  = tostring(playerId or "Unknown"),
        timestamp = timestamp or 0,
        timeStr   = tostring(timeStr or ""),
    }
end

-- ============================================================
-- Build server-stored trigger history file data
-- ============================================================
EventTriggerShared.makeHistoryData = function(triggerId, entries)
    return {
        triggerId = triggerId,
        version   = EventTriggerShared.VERSION,
        entries   = entries or {},
    }
end

-- ============================================================
-- Build index file data
-- ============================================================
EventTriggerShared.makeIndexData = function(triggerIds)
    return {
        version    = EventTriggerShared.VERSION,
        triggerIds = triggerIds or {},
    }
end

return EventTriggerShared
