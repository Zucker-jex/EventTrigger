-- ============================================================
-- EventTrigger/Shared.lua — 常量、指令、数据结构
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

-- 触发器数量上限（防止无限增长）
EventTriggerShared.MAX_TRIGGERS = 200

-- 交付点数量上限
EventTriggerShared.MAX_DELIVERY_POINTS = 100

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
    TOGGLE_TRIGGER    = "toggleTrigger",
    DISABLE_ALL       = "disableAll",

    -- 触发记录（客户端 -> 服务器）
    RECORD_TRIGGER    = "recordTrigger",

    -- 通知（服务器 -> 客户端）
    NAMED_MESSAGE     = "namedMessage",
    NOTIFY            = "notify",

    -- ==================== 交付点指令 ====================
    -- CRUD（客户端 -> 服务器）
    PLACE_DELIVERY    = "placeDeliveryPoint",
    DELETE_DELIVERY   = "deleteDeliveryPoint",
    DELETE_ALL_DELIVERY = "deleteAllDeliveryPoints",
    EDIT_DELIVERY     = "editDelivery",
    RESET_DELIVERY    = "resetDelivery",
    TOGGLE_DELIVERY   = "toggleDelivery",

    -- 交付交易（客户端 -> 服务器）
    REQUEST_DELIVERY  = "requestDelivery",
    CONFIRM_DELIVERY  = "confirmDelivery",

    -- 交付通知（服务器 -> 客户端）
    DELIVERY_RESULT   = "deliveryResult",
}

-- ============================================================
-- 触发器输出类型枚举
-- ============================================================
EventTriggerShared.OutputType = {
    NAMED     = 1,  -- 具名 + 系统频道（仅本地显示）
    SAY       = 2,  -- /say + 气泡
    DO        = 3,  -- /do 环境旁白
    LOW       = 4,  -- /low + 气泡
    YELL      = 5,  -- /yell + 气泡
    OOC       = 6,  -- /ooc 全局 OOC
    HALO      = 7,  -- 头顶漂浮文字（仅本地显示）
    BROADCAST = 8,  -- 服务器广播（全服可见，可具名）
}

-- ============================================================
-- ID 生成（服务器端唯一）
-- ============================================================
EventTriggerShared.generateId = function()
    local rand = ZombRand(100000, 999999)
    return "et_" .. tostring(os.time()) .. "_" .. tostring(rand)
end

-- ============================================================
-- 冷却（真实时钟 vs 游戏时钟）数据 + 辅助函数
-- ============================================================
EventTriggerShared.COOLDOWN_NONE = 0  -- 无冷却
EventTriggerShared.COOLDOWN_WALL = 1  -- 真实/墙上时钟（os.time 秒）
EventTriggerShared.COOLDOWN_GAME = 2  -- 游戏内时钟（世界年龄秒）

local function _clampInt(v)
    v = tonumber(v)
    if not v then return 0 end
    v = math.floor(v)
    if v < 0 then return 0 end
    return v
end

-- 从参数构建冷却表（支持嵌套 cooldown 表或平铺字段），
-- 并包含交付点的旧版 cooldownType/cooldownValue 迁移。
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

    -- 兼容旧版交付字段：cooldownType（0=无,1=游戏,2=真实）+ cooldownValue（分钟）
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

-- 无冷却时返回 true（模式为 NONE，或所有时长字段均为 0）。
EventTriggerShared.isCooldownZero = function(cd)
    cd = cd or {}
    if cd.mode == EventTriggerShared.COOLDOWN_NONE then return true end
    return (cd.years or 0) == 0 and (cd.months or 0) == 0 and (cd.days or 0) == 0
        and (cd.hours or 0) == 0 and (cd.minutes or 0) == 0
end

-- 冷却总时长（秒），两种模式统一单位。
EventTriggerShared.cooldownDurationSeconds = function(cd)
    cd = cd or {}
    local y = cd.years or 0
    local mo = cd.months or 0
    local d = cd.days or 0
    local h = cd.hours or 0
    local mi = cd.minutes or 0
    return (((y * 365 + mo * 30 + d) * 24 + h) * 60 + mi) * 60
end

-- 给定模式下的当前时钟秒值。
-- 墙上时钟 -> os.time() 秒；游戏时钟 -> 世界年龄秒。
EventTriggerShared.cooldownNowSeconds = function(mode)
    if mode == EventTriggerShared.COOLDOWN_GAME then
        return getGameTime():getWorldAgeHours() * 3600
    end
    return os.time()
end

-- 人类可读的冷却字符串（用于日志 / UI 显示）。
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
        enabled     = args.enabled ~= false,
        cooldown    = EventTriggerShared.makeCooldown(args.cooldown or args),
        lastTriggerAt = args.lastTriggerAt,
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

-- ============================================================
-- 交付点数据结构
-- ============================================================

-- 构建单个交付物品条目
-- customName：非空表示该条目要求"被改名的物品"，值为自定义名原文（语言无关）；
--             为空表示要求"未改名的普通物品"。用于区分同 fullType 的改名/未改名实例。
EventTriggerShared.makeDeliveryItem = function(args)
    return {
        fullType    = tostring(args.fullType or ""),
        displayName = tostring(args.displayName or ""),
        customName  = tostring(args.customName or ""),
        count       = math.max(1, args.count or 1),
    }
end

-- 构建单个消耗选项（需求3：多个可选消耗物品之一）
EventTriggerShared.makeCostOption = function(args)
    return {
        fullType    = tostring(args.fullType or ""),
        displayName = tostring(args.displayName or ""),
        customName  = tostring(args.customName or ""),
        count       = math.max(1, args.count or 1),
    }
end

-- 构建单个兑换分支（需求2：相同消耗，多个奖励分支；
-- 需求3：通过 costOptions 支持多个消耗选项）
EventTriggerShared.makeBranch = function(args)
    return {
        id          = args.id,                 -- 从 1 开始的分支索引
        enabled     = args.enabled ~= false,
        costOptions = args.costOptions or {},  -- 可选消耗物（单选其一）
        rewards     = args.rewards or {},      -- 该分支奖励
    }
end

-- 构建完整交付点对象
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
        matchMode     = args.matchMode or "all",  -- "all" = AND 逻辑，"any" = OR 逻辑
        costMode      = args.costMode or "all",   -- 消耗物品模式："all" = 全部扣除（默认）/ "any" = 任选其一
        branches      = args.branches or {},      -- 多兑换分支（为空则回退旧字段）
        maxPlayers    = math.max(-1, args.maxPlayers or -1),
        maxPerPlayer  = math.max(-1, args.maxPerPlayer or -1),
        cooldown      = EventTriggerShared.makeCooldown(args.cooldown or args),
        playerDeliveries = args.playerDeliveries or {},  -- playerId -> 次数
        playerCooldowns  = args.playerCooldowns or {},   -- playerId -> 上次交付时间戳（秒）
        triggerCount  = args.triggerCount or 0,
        triggeredBy   = args.triggeredBy or {},
        enabled       = args.enabled ~= false,
        creator       = tostring(args.creator or "unknown"),
        createdAt     = args.createdAt or os.time(),
    }
end

-- 校验单个交付物品条目
EventTriggerShared.validateDeliveryItem = function(item)
    if type(item) ~= "table" then return false end
    if not item.fullType or #item.fullType == 0 then return false end
    if not item.count or item.count < 1 then return false end
    return true
end

-- 需求物品（requiredItems）一律仅作资格门槛，永不扣除。
-- 需要消耗时请配置"消耗物品"（costOptions）。
-- 旧数据中的 collect 字段被忽略；旧版 makeDeliveryItem 曾写入该字段，仅作向后兼容读取。

-- 解析交付点的有效兑换方案（结合玩家选择）。
-- 返回 costOptions（扣除列表）+ rewards，存在分支时优先使用分支。
-- branchId：选中的分支（从 1 开始）；costOptionIndex：选中的消耗选项（从 1 开始，需求3）
-- 解析交付点的有效兑换方案（结合玩家选择）。
-- 返回 qualifyItems（需求物品/资格门槛）、costs（消耗扣除）、rewards、err。
--   qualifyItems：requiredItems — 玩家必须满足（按 matchMode）才能兑换；**永不扣除**。
--   costs：实际扣除的物品 = 消耗选项（costOptions / 选中分支）
--   rewards：发放的物品。
EventTriggerShared.resolveExchange = function(dp, branchId, costOptionIndex)
    dp = dp or {}
    local branches = dp.branches or {}

    -- 资格门槛：requiredItems（需求物品）—— 仅检查，不参与扣除
    local qualifyItems = {}
    for _, req in ipairs(dp.requiredItems or {}) do
        qualifyItems[#qualifyItems + 1] = {
            fullType = tostring(req.fullType or ""),
            displayName = tostring(req.displayName or ""),
            customName = tostring(req.customName or ""),
            count = math.max(1, req.count or 1),
        }
    end

    -- 旧版路径：无分支且无消耗选项 → 不扣除任何物品（仅门槛 + 奖励）
    if #branches == 0 then
        return qualifyItems, {}, dp.rewardItems or {}, nil
    end

    -- 分支路径：选择指定分支（默认为 1）
    local branch = branches[1]
    if branchId and branches[branchId] and branches[branchId].enabled ~= false then
        branch = branches[branchId]
    end
    if not branch or branch.enabled == false then
        return qualifyItems, nil, nil, "Branch unavailable"
    end

    -- 分支内部：需求物品永不扣除，扣除来自消耗选项（costOptions）。
    --   costMode == "all" → 扣除全部消耗选项；
    --   costMode == "any" → 扣除选中的那一个（未选则回退到第一个）。
    local costs = {}

    local costOptions = branch.costOptions or {}
    local costMode = dp.costMode or "all"
    if costMode == "all" then
        for _, co in ipairs(costOptions) do
            costs[#costs + 1] = {
                fullType = co.fullType,
                displayName = co.displayName,
                customName = co.customName or "",
                count = co.count,
            }
        end
    else
        local chosen
        if costOptionIndex and costOptions[costOptionIndex] then
            chosen = costOptions[costOptionIndex]
        elseif #costOptions > 0 then
            chosen = costOptions[1]
        end
        if chosen then
            costs[#costs + 1] = {
                fullType = chosen.fullType,
                displayName = chosen.displayName,
                customName = chosen.customName or "",
                count = chosen.count,
            }
        end
    end

    return qualifyItems, costs, branch.rewards or {}, nil
end

-- 构建交付索引文件数据
EventTriggerShared.makeDeliveryIndexData = function(ids)
    return {
        version = EventTriggerShared.VERSION,
        deliveryIds = ids or {},
    }
end

return EventTriggerShared
