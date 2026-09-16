-- ============================================================
-- EventTrigger/Shared.lua — constants, commands, data structures
-- ============================================================

local EventTriggerShared = {}

EventTriggerShared.VERSION = 1
EventTriggerShared.MOD_ID = "EventTrigger"
EventTriggerShared.MODULE = "EventTrigger"
EventTriggerShared.DATA_DIR = "EventTrigger"
EventTriggerShared.HISTORY_DIR = EventTriggerShared.DATA_DIR .. "/history"
EventTriggerShared.DELIVERY_DIR = EventTriggerShared.DATA_DIR .. "/delivery"

EventTriggerShared.INDEX_FILE = EventTriggerShared.DATA_DIR .. "/index.json"
EventTriggerShared.DELIVERY_INDEX_FILE = EventTriggerShared.DELIVERY_DIR .. "/index.json"

-- Maximum trigger limit (prevent unbounded growth)
EventTriggerShared.MAX_TRIGGERS = 200

-- Maximum delivery points
EventTriggerShared.MAX_DELIVERY_POINTS = 100

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

    -- ==================== Delivery Point Commands ====================
    -- CRUD (client -> server)
    PLACE_DELIVERY    = "placeDeliveryPoint",
    DELETE_DELIVERY   = "deleteDeliveryPoint",
    DELETE_ALL_DELIVERY = "deleteAllDeliveryPoints",
    EDIT_DELIVERY     = "editDelivery",
    RESET_DELIVERY    = "resetDelivery",

    -- Delivery transaction (client -> server)
    REQUEST_DELIVERY  = "requestDelivery",
    CONFIRM_DELIVERY  = "confirmDelivery",

    -- Delivery notifications (server -> client)
    DELIVERY_RESULT   = "deliveryResult",
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
-- Cooldown (wall clock vs game clock) data + helpers
-- ============================================================
EventTriggerShared.COOLDOWN_NONE = 0  -- no cooldown
EventTriggerShared.COOLDOWN_WALL = 1  -- real / wall clock (os.time seconds)
EventTriggerShared.COOLDOWN_GAME = 2  -- in-game clock (world age seconds)

local function _clampInt(v)
    v = tonumber(v)
    if not v then return 0 end
    v = math.floor(v)
    if v < 0 then return 0 end
    return v
end

-- Build a cooldown table from args (nested `cooldown` table or flat fields),
-- plus legacy cooldownType/cooldownValue migration for delivery points.
EventTriggerShared.makeCooldown = function(args)
    args = args or {}
    local src
    if type(args.cooldown) == "table" then
        src = args.cooldown
    else
        src = args
    end

    local mode = tonumber(src.mode or src.cooldownMode)
    local years   = _clampInt(src.years or src.cooldownYears)
    local months  = _clampInt(src.months or src.cooldownMonths)
    local days    = _clampInt(src.days or src.cooldownDays)
    local hours   = _clampInt(src.hours or src.cooldownHours)
    local minutes = _clampInt(src.minutes or src.cooldownMinutes)

    -- Legacy delivery fields: cooldownType (0=none,1=game,2=real) + cooldownValue (minutes)
    local legacyType = tonumber(src.cooldownType) or 0
    local legacyValue = tonumber(src.cooldownValue) or 0
    if legacyValue > 0 and years == 0 and months == 0 and days == 0 and hours == 0 and minutes == 0 then
        minutes = _clampInt(legacyValue)
        if legacyType == 1 then mode = mode or EventTriggerShared.COOLDOWN_GAME end
        if legacyType == 2 then mode = mode or EventTriggerShared.COOLDOWN_WALL end
    end

    if mode == nil then mode = EventTriggerShared.COOLDOWN_NONE end
    if mode ~= EventTriggerShared.COOLDOWN_GAME and mode ~= EventTriggerShared.COOLDOWN_WALL then
        mode = EventTriggerShared.COOLDOWN_NONE
    end
    if mode == EventTriggerShared.COOLDOWN_NONE then
        return { mode = EventTriggerShared.COOLDOWN_NONE, years = 0, months = 0, days = 0, hours = 0, minutes = 0 }
    end

    return {
        mode    = mode,
        years   = years,
        months  = months,
        days    = days,
        hours   = hours,
        minutes = minutes,
    }
end

-- True when there is no cooldown (mode NONE, or every duration field is 0).
EventTriggerShared.isCooldownZero = function(cd)
    cd = cd or {}
    if cd.mode == EventTriggerShared.COOLDOWN_NONE then return true end
    return (cd.years or 0) == 0 and (cd.months or 0) == 0 and (cd.days or 0) == 0
        and (cd.hours or 0) == 0 and (cd.minutes or 0) == 0
end

-- Total cooldown length in seconds (uniform unit for both modes).
EventTriggerShared.cooldownDurationSeconds = function(cd)
    cd = cd or {}
    local y = cd.years or 0
    local mo = cd.months or 0
    local d = cd.days or 0
    local h = cd.hours or 0
    local mi = cd.minutes or 0
    return (((y * 365 + mo * 30 + d) * 24 + h) * 60 + mi) * 60
end

-- Current clock value in seconds for the given mode.
-- wall clock -> os.time() seconds; game clock -> world age in seconds.
EventTriggerShared.cooldownNowSeconds = function(mode)
    if mode == EventTriggerShared.COOLDOWN_GAME then
        return getGameTime():getWorldAgeHours() * 3600
    end
    return os.time()
end

-- Human-readable cooldown string (for logs / UI display).
EventTriggerShared.formatCooldown = function(cd)
    cd = cd or {}
    if EventTriggerShared.isCooldownZero(cd) then return "None" end
    local modeStr = (cd.mode == EventTriggerShared.COOLDOWN_GAME) and "Game Clock" or "Wall Clock"
    local parts = {}
    if (cd.years or 0) > 0 then parts[#parts + 1] = cd.years .. "y" end
    if (cd.months or 0) > 0 then parts[#parts + 1] = cd.months .. "mo" end
    if (cd.days or 0) > 0 then parts[#parts + 1] = cd.days .. "d" end
    if (cd.hours or 0) > 0 then parts[#parts + 1] = cd.hours .. "h" end
    if (cd.minutes or 0) > 0 then parts[#parts + 1] = cd.minutes .. "m" end
    return modeStr .. " " .. table.concat(parts, " ")
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
        cooldown    = EventTriggerShared.makeCooldown(args.cooldown or args),
        lastTriggerAt = args.lastTriggerAt,
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

-- ============================================================
-- Delivery Point data structures
-- ============================================================

-- Build a single delivery item entry
EventTriggerShared.makeDeliveryItem = function(args)
    return {
        fullType    = tostring(args.fullType or ""),
        displayName = tostring(args.displayName or ""),
        count       = math.max(1, args.count or 1),
        collect     = args.collect ~= false,
    }
end

-- Build complete delivery point object
EventTriggerShared.makeDeliveryPoint = function(args)
    return {
        id            = args.id or EventTriggerShared.generateId(),
        type          = "delivery",
        x             = args.x or 0,
        y             = args.y or 0,
        z             = args.z or 0,
        hintText      = tostring(args.hintText or "Delivery Point"):sub(1, 500),
        range         = math.max(0.5, args.range or 3),
        requiredItems = args.requiredItems or {},
        rewardItems   = args.rewardItems or {},
        matchMode     = args.matchMode or "all",  -- "all" = AND logic, "any" = OR logic
        maxPlayers    = math.max(-1, args.maxPlayers or -1),
        maxPerPlayer  = math.max(-1, args.maxPerPlayer or -1),
        cooldown      = EventTriggerShared.makeCooldown(args.cooldown or args),
        playerDeliveries = args.playerDeliveries or {},  -- playerId -> count
        playerCooldowns  = args.playerCooldowns or {},   -- playerId -> last delivery timestamp (seconds)
        triggerCount  = args.triggerCount or 0,
        triggeredBy   = args.triggeredBy or {},
        creator       = tostring(args.creator or "unknown"),
        createdAt     = args.createdAt or os.time(),
    }
end

-- Validate a delivery item entry
EventTriggerShared.validateDeliveryItem = function(item)
    if type(item) ~= "table" then return false end
    if not item.fullType or #item.fullType == 0 then return false end
    if not item.count or item.count < 1 then return false end
    return true
end

-- Build delivery index file data
EventTriggerShared.makeDeliveryIndexData = function(ids)
    return {
        version = EventTriggerShared.VERSION,
        deliveryIds = ids or {},
    }
end

return EventTriggerShared
