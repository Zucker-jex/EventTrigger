-- ============================================================
-- EventTriggerClient — 客户端主逻辑（单机/联机共用）
-- 负责触发器增删改查、玩家检测、消息调度与 UI
-- ============================================================

-- ============================================================
-- 引导顺序（重要）：
--   1) 在 require 之前先确保 EventTrigger / EventTrigger.Delivery 全局表存在，
--      以便 EventTriggerDelivery.lua 能安全地挂载到它们上面。
--   2) require 依赖模块。
--   3) 为缺失的 Delivery 方法安装占位桩，确保任何调用方
--      （OnTick、右键菜单、UI 按钮、服务器指令）在交付模块不可用时不会崩溃。
-- ============================================================
EventTrigger = EventTrigger or {}
EventTrigger.Delivery = EventTrigger.Delivery or {}

require "ISUI/ISTextBox"
require "EventTriggerDelivery"

do
    -- 当交付模块正常加载时，EventTrigger.Delivery 上应存在的方法列表。
    local expectedMethods = {
        "CheckPlayerInRange", "StartSetup", "EditDelivery", "DeleteDelivery",
        "ResetDelivery", "ShowHistory", "OnDeliveryResult",
        "CloseAllUIs", "Validate", "MatchItem", "CountItems",
    }

    -- 占位桩的返回值，避免期望 (ok, msg) 的调用方拿到 nil 后崩溃。
    local stubFactories = {
        Validate   = function() return false, "Delivery module not loaded" end,
        MatchItem  = function() return false end,
        CountItems = function() return {} end,
    }

    local missing = {}
    for _, name in ipairs(expectedMethods) do
        if type(EventTrigger.Delivery[name]) ~= "function" then
            local factory = stubFactories[name]
            if factory then
                EventTrigger.Delivery[name] = factory
            else
                EventTrigger.Delivery[name] = function() end
            end
            missing[#missing + 1] = name
        end
    end

    -- 模块间共享的状态表。
    EventTrigger.Delivery._activePrompt = EventTrigger.Delivery._activePrompt or {}
    EventTrigger.Delivery._pendingDpId  = EventTrigger.Delivery._pendingDpId  or {}

    -- 若模块未加载，只打印一条醒目的警告。
    EventTrigger.DeliveryLoaded = (#missing == 0)
    if #missing > 0 then
        print("[EventTrigger-CLIENT] EventTriggerDelivery NOT loaded. Stubbed: " .. table.concat(missing, ", "))
        print("[EventTrigger-CLIENT] >>> Check that EventTriggerDelivery.lua ships with the client mod and is reachable via require()")
    end
end

EventTrigger.triggers = EventTrigger.triggers or {}
EventTrigger.deliveryPoints = EventTrigger.deliveryPoints or {}
EventTrigger.timers = {}
EventTrigger.tickCounter = 0
EventTrigger.timerIdCounter = 0
EventTrigger._ui = nil
EventTrigger._editIndex = nil
EventTrigger._mode = "local"
EventTrigger.DEBUG = true

-- 调试输出函数，由 EventTrigger.DEBUG 开关控制
local function dbg(...)
    if EventTrigger.DEBUG then
        print("[EventTrigger-CLIENT]", ...)
    end
end

-- UTF-8 安全文本适配：将文本裁剪至 maxWidth 像素内（末尾附加 "..."）
-- 按 UTF-8 字符（而非字节）迭代，避免 CJK 文本被从码点中间截断。
function EventTrigger.fitText(text, font, maxWidth)
    text = tostring(text or "")
    if not maxWidth or maxWidth <= 0 then return text end
    local tm = getTextManager()
    if not tm then return text end
    if tm:MeasureStringX(font, text) <= maxWidth then return text end

    local ellipsis = "..."
    local avail = maxWidth - tm:MeasureStringX(font, ellipsis)
    if avail <= 0 then return ellipsis end

    local out = ""
    for ch in text:gmatch("[^\128-\191][\128-\191]*") do
        if tm:MeasureStringX(font, out .. ch) > avail then break end
        out = out .. ch
    end
    return out .. ellipsis
end

-- 全局 UI 缩放系数：放大所有窗口和间距（约 1.75 倍）以减少拥挤。
EventTrigger.US = 1.5

-- 将窗口宽度限制在可见屏幕内（留出小边距）。
function EventTrigger.fitW(baseW)
    local sw = getCore():getScreenWidth()
    return math.min(math.floor(baseW * EventTrigger.US), math.floor(sw * 0.94))
end

function EventTrigger.fitH(baseH)
    local sh = getCore():getScreenHeight()
    return math.min(math.floor(baseH * EventTrigger.US), math.floor(sh * 0.94))
end

-- 测量 PZ 实际给按钮分配的宽度（ISButton 会自动扩展以适配标题）。
function EventTrigger.btnW(title)
    return getTextManager():MeasureStringX(UIFont.Small, title) + 10
end

-- ============================================================
-- 冷却辅助（真实时钟 vs 游戏时钟）
-- ============================================================
EventTrigger.COOLDOWN_NONE = 0  -- 无冷却
EventTrigger.COOLDOWN_WALL = 1  -- 真实/墙上时钟（os.time 秒）
EventTrigger.COOLDOWN_GAME = 2  -- 游戏内时钟（世界年龄秒）

local function clampInt(v)
    v = tonumber(v)
    if not v then return 0 end
    v = math.floor(v)
    if v < 0 then return 0 end
    return v
end

function EventTrigger.makeCooldown(args)
    args = args or {}
    local src = (type(args.cooldown) == "table") and args.cooldown or args

    local mode = tonumber(src.mode or src.cooldownMode)
    local years   = clampInt(src.years or src.cooldownYears)
    local months  = clampInt(src.months or src.cooldownMonths)
    local days    = clampInt(src.days or src.cooldownDays)
    local hours   = clampInt(src.hours or src.cooldownHours)
    local minutes = clampInt(src.minutes or src.cooldownMinutes)

    -- 兼容旧版交付字段：cooldownType（0=无,1=游戏,2=真实）+ cooldownValue（分钟）
    local legacyType = tonumber(src.cooldownType) or 0
    local legacyValue = tonumber(src.cooldownValue) or 0
    if legacyValue > 0 and years == 0 and months == 0 and days == 0 and hours == 0 and minutes == 0 then
        minutes = clampInt(legacyValue)
        if legacyType == 1 then mode = mode or EventTrigger.COOLDOWN_GAME end
        if legacyType == 2 then mode = mode or EventTrigger.COOLDOWN_WALL end
    end

    if mode == nil then mode = EventTrigger.COOLDOWN_NONE end
    if mode ~= EventTrigger.COOLDOWN_GAME and mode ~= EventTrigger.COOLDOWN_WALL then
        mode = EventTrigger.COOLDOWN_NONE
    end
    if mode == EventTrigger.COOLDOWN_NONE then
        return { mode = EventTrigger.COOLDOWN_NONE, years = 0, months = 0, days = 0, hours = 0, minutes = 0 }
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

function EventTrigger.isCooldownZero(cd)
    cd = cd or {}
    if cd.mode == EventTrigger.COOLDOWN_NONE then return true end
    return (cd.years or 0) == 0 and (cd.months or 0) == 0 and (cd.days or 0) == 0
        and (cd.hours or 0) == 0 and (cd.minutes or 0) == 0
end

function EventTrigger.cooldownDurationSeconds(cd)
    cd = cd or {}
    return ((((cd.years or 0) * 365 + (cd.months or 0) * 30 + (cd.days or 0)) * 24 + (cd.hours or 0)) * 60 + (cd.minutes or 0)) * 60
end

function EventTrigger.cooldownNowSeconds(mode)
    if mode == EventTrigger.COOLDOWN_GAME then
        return getGameTime():getWorldAgeHours() * 3600
    end
    return os.time()
end

function EventTrigger.formatCooldown(cd)
    cd = cd or {}
    if EventTrigger.isCooldownZero(cd) then return getText("UI_ET_Cd_None") end
    local modeStr = (cd.mode == EventTrigger.COOLDOWN_GAME) and getText("UI_ET_Cd_Game") or getText("UI_ET_Cd_Wall")
    local parts = {}
    if (cd.years or 0) > 0 then parts[#parts + 1] = cd.years .. getText("UI_ET_Cd_UnitY") end
    if (cd.months or 0) > 0 then parts[#parts + 1] = cd.months .. getText("UI_ET_Cd_UnitMo") end
    if (cd.days or 0) > 0 then parts[#parts + 1] = cd.days .. getText("UI_ET_Cd_UnitD") end
    if (cd.hours or 0) > 0 then parts[#parts + 1] = cd.hours .. getText("UI_ET_Cd_UnitH") end
    if (cd.minutes or 0) > 0 then parts[#parts + 1] = cd.minutes .. getText("UI_ET_Cd_UnitM") end
    return modeStr .. " " .. table.concat(parts, " ")
end

-- 当触发器可以再次触发时返回 true（全局冷却已过）。
function EventTrigger.isTriggerCooldownReady(t)
    local cd = t.cooldown or {}
    if EventTrigger.isCooldownZero(cd) then return true end
    if not t.lastTriggerAt then return true end
    local now = EventTrigger.cooldownNowSeconds(cd.mode)
    return (now - t.lastTriggerAt) >= EventTrigger.cooldownDurationSeconds(cd)
end

-- 触发器消息输出模式枚举（对应 MongooseChat 频道）
EventTrigger.OutputType = {
    NAMED     = 1,  -- 具名系统频道（仅本地显示）
    SAY       = 2,  -- /say  触发者身份 + 气泡
    DO        = 3,  -- /do   环境旁白
    LOW       = 4,  -- /low  低语 + 气泡
    YELL      = 5,  -- /yell 大喊 + 气泡
    OOC       = 6,  -- /ooc  全局 OOC
    HALO      = 7,  -- 头顶漂浮文字（仅本地显示，不写入聊天日志）
    BROADCAST = 8,  -- 服务器广播（全服可见，可具名）
}

-- 输出类型名称查找表（用于 UI 显示）
local OutputTypeNames = {
    [1] = getText("UI_ET_Out_Named"),
    [2] = getText("UI_ET_Out_Say"),
    [3] = getText("UI_ET_Out_Do"),
    [4] = getText("UI_ET_Out_Low"),
    [5] = getText("UI_ET_Out_Yell"),
    [6] = getText("UI_ET_Out_Ooc"),
    [7] = getText("UI_ET_Out_Halo"),
    [8] = getText("UI_ET_Out_Broadcast"),
}

-- 获取稳定的玩家标识（优先 Steam 用户名，回退为 "unknown"）
local function GetPlayerIdentifier(player)
    if not player then return "unknown" end
    return player:getUsername() or "unknown"
end

-- 判断当前玩家是否为管理员
function EventTrigger.IsAdmin()
    local player = getPlayer()
    return player and player:getAccessLevel() == "admin"
end

-- 获取当前玩家 ID
function EventTrigger.GetCurrentPlayerId()
    return GetPlayerIdentifier(getPlayer())
end

-- 获取用户配置（Global ModData 存储，按玩家区分）
function EventTrigger.GetConfig()
    local data = ModData.getOrCreate("EventTrigger")
    local cfg = data.config or {}
    return {
        outputName = cfg.outputName or "System",
        defaultRange = cfg.defaultRange or 2,
    }
end

-- 设置用户配置项（如 outputName、defaultRange）
function EventTrigger.SetConfig(key, value)
    local data = ModData.getOrCreate("EventTrigger")
    if not data.config then data.config = {} end
    data.config[key] = value
end

-- 检测是否处于联机模式（用 world:getGameMode()，比 isClient() 更可靠）
function EventTrigger.IsMultiplayer()
    local world = getWorld()
    if world then
        return world:getGameMode() == "Multiplayer"
    end
    return false
end

-- 获取指定坐标的格子
function EventTrigger.GetSquare(x, y, z)
    local cell = getCell()
    if not cell then return nil end
    return cell:getGridSquare(x, y, z)
end

-- 自增 ID 计数器（生成唯一触发器 ID，跨客户端不冲突）
EventTrigger._idCounter = EventTrigger._idCounter or 0

-- 生成唯一触发器 ID（前缀 "trig_" + Unix 时间戳 + 自增序号）
function EventTrigger._generateId()
    EventTrigger._idCounter = EventTrigger._idCounter + 1
    return "trig_" .. tostring(os.time()) .. "_" .. tostring(EventTrigger._idCounter)
end

-- 将触发器数据写入格子 ModData（仅单机）
-- 联机模式下由服务器 JSON 文件为准，跳过格子写入
function EventTrigger.WriteToSquare(x, y, z, data)
    if EventTrigger.IsMultiplayer() then return true end
    local sq = EventTrigger.GetSquare(x, y, z)
    if not sq then dbg("WriteToSquare: no square at", x, y, z) return false end
    local md = sq:getModData()
    if not md.EventTrigger then md.EventTrigger = {} end
        data.id = data.id or EventTrigger._generateId()
    table.insert(md.EventTrigger, data)
    sq:transmitModdata()
    return true
end

-- 从格子读取全部触发器数据
function EventTrigger.ReadFromSquare(x, y, z)
    local sq = EventTrigger.GetSquare(x, y, z)
    if not sq then return nil end
    return sq:getModData().EventTrigger
end

-- 按 ID 更新格子上的指定触发器字段（仅单机）
function EventTrigger.UpdateSquareTrigger(id, x, y, z, partialData)
    if EventTrigger.IsMultiplayer() then return true end
    local sq = EventTrigger.GetSquare(x, y, z)
    if not sq then return false end
    local md = sq:getModData()
    local arr = md.EventTrigger
    if not arr then return false end
    for i, entry in ipairs(arr) do
        if entry.id == id then
            for k, v in pairs(partialData) do
                entry[k] = v
            end
            sq:transmitModdata()
            return true
        end
    end
    return false
end

-- 按 ID 从格子中移除触发器（仅单机）
function EventTrigger.RemoveFromSquare(id, x, y, z)
    if EventTrigger.IsMultiplayer() then return true end
    local sq = EventTrigger.GetSquare(x, y, z)
    if not sq then return false end
    local md = sq:getModData()
    local arr = md.EventTrigger
    if not arr then return false end
    for i, entry in ipairs(arr) do
        if entry.id == id then
            table.remove(arr, i)
            sq:transmitModdata()
            return true
        end
    end
    return false
end

-- 清空格子上的全部触发器数据（仅单机）
function EventTrigger.ClearFromSquare(x, y, z)
    if EventTrigger.IsMultiplayer() then return true end
    local sq = EventTrigger.GetSquare(x, y, z)
    if not sq then return false end
    local md = sq:getModData()
    md.EventTrigger = nil
    sq:transmitModdata()
    return true
end

-- 扫描玩家周围 30 格范围，收集触发器数据
-- 返回带坐标信息的触发器列表（兼容旧版单对象格式）
function EventTrigger.ScanNearbySquares()
    local player = getPlayer()
    if not player then return {} end
    local sq = player:getSquare()
    if not sq then return {} end
    local cell = getCell()
    if not cell then return {} end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local area = 30
    local found = {}
    for x = px - area, px + area do
        for y = py - area, py + area do
            for z = pz - 1, pz + 1 do
                if z >= 0 then
                    local gs = cell:getGridSquare(x, y, z)
                    if gs then
                        local md = gs:getModData()
                        local arr = md and md.EventTrigger
                        if arr then
                        if arr.message then
                                arr = { arr }
                            end
                            for _, td in ipairs(arr) do
                                if td and td.message then
                                    if not td.id then
                                        td.id = EventTrigger._generateId()
                                    end
                                    td.x = x
                                    td.y = y
                                    td.z = z
                                    table.insert(found, td)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return found
end

-- 由坐标生成唯一键字符串（用于坐标匹配）
function EventTrigger._makeKey(x, y, z)
    return tostring(math.floor(x or 0)) .. "_" .. tostring(math.floor(y or 0)) .. "_" .. tostring(math.floor(z or 0))
end

-- 在运行时列表中按 ID 查找触发器索引
function EventTrigger._findIndexById(id)
    for i, t in ipairs(EventTrigger.triggers) do
        if t.id == id then return i end
    end
    return nil
end

-- 从周围格子重建运行时触发器列表（仅单机）
-- 联机模式下由服务器 JSON 文件为准；syncAll 会提供完整列表
function EventTrigger.RebuildList()
    if EventTrigger.IsMultiplayer() then
        dbg("RebuildList: MP mode, skipped (server is authoritative)")
        return
    end
    local scanned = EventTrigger.ScanNearbySquares()
    local changed = false

    -- 构建扫描到的 ID 集合，用于检测已从格子中移除的触发器
    local scannedIds = {}
    for _, td in ipairs(scanned) do
        if td.id then scannedIds[td.id] = true end
    end

    for _, td in ipairs(scanned) do
        local idx = EventTrigger._findIndexById(td.id)
        if idx then
            local t = EventTrigger.triggers[idx]
            -- 若格子中的 triggerCount 更新，取较大者
            if td.triggerCount and td.triggerCount > (t.triggerCount or 0) then
                t.triggerCount = td.triggerCount
            end
            -- 若本地无触发历史，则从格子恢复
            if td.triggeredBy and #td.triggeredBy > 0 and (not t.triggeredBy or #t.triggeredBy == 0) then
                t.triggeredBy = td.triggeredBy
            end
            t.message = td.message or t.message
            t.delay = td.delay or t.delay
            t.range = td.range or t.range
            t.outputType = td.outputType or t.outputType
            t.outputName = td.outputName or t.outputName
            t.maxTriggers = td.maxTriggers or t.maxTriggers
            t.creator = td.creator or t.creator
            t.enabled = td.enabled ~= false
            -- 更新坐标（保持兼容）
            t.x = td.x
            t.y = td.y
            t.z = td.z
        else
            -- 从格子 ModData 中恢复已持久化的 triggerCount + triggeredBy
            local restoredCount = td.triggerCount or 0
            local restoredHistory = td.triggeredBy or {}
            table.insert(EventTrigger.triggers, {
                id = td.id,
                x = td.x, y = td.y, z = td.z,
                message = td.message or "Trigger activated!",
                delay = td.delay or 3,
                range = td.range or 2,
                outputType = td.outputType or EventTrigger.OutputType.HALO,
                outputName = td.outputName or "",
                maxTriggers = td.maxTriggers or -1,
                triggerCount = restoredCount,
                triggeredBy = restoredHistory,
                cooldown = EventTrigger.makeCooldown(td.cooldown or td),
                lastTriggerAt = td.lastTriggerAt,
                enabled = td.enabled ~= false,
                inRangePlayers = {},
                creator = td.creator or "unknown",
            })
            changed = true
            if restoredCount > 0 then
                dbg("RebuildList: restored triggerCount=" .. restoredCount .. " for id=" .. (td.id or "?"))
            end
        end
    end

    -- 清理本地列表中位于扫描范围内、但已不在格子上的条目
    -- 针对"联机删除不同步"的第二道防线：
    -- 即使 _removeMissingFromServer 未触发，RebuildList 也能检测并移除它们
    local player = getPlayer()
    if player then
        local psq = player:getSquare()
        if psq then
            local px, py, pz = psq:getX(), psq:getY(), psq:getZ()
            local area = 30
            local newList = {}
            local removedCount = 0
            for _, t in ipairs(EventTrigger.triggers) do
                local dx = math.abs((t.x or 0) - px)
                local dy = math.abs((t.y or 0) - py)
                local dz = math.abs((t.z or 0) - pz)
                -- 在扫描范围之外则保留（可能位于其他区域）；在范围内但格子中不存在则移除
                if dx > area or dy > area or dz > 1 or scannedIds[t.id] then
                    table.insert(newList, t)
                else
                    removedCount = removedCount + 1
                    dbg("RebuildList: cleaned stale trigger id=" .. tostring(t.id) .. " (within scan range, not in square)")
                end
            end
            if removedCount > 0 then
                EventTrigger.triggers = newList
                changed = true
                dbg("RebuildList: removed " .. removedCount .. " stale trigger(s) within scan range")
            end
        end
    end

    if changed then
        EventTrigger._saveToModData()
    end
    dbg("RebuildList: scanned", #scanned, "triggers from squares, total in list:", #EventTrigger.triggers)
end

-- 双模式执行：先本地更新（乐观 UI），再在联机模式下发送到服务器进行权威持久化
-- 服务器 syncAll 会提供最终对账
-- 使用 sendClientCommand（与 BulletinBoard 相同），由服务器 OnClientCommand 接收
function EventTrigger.SendCommand(command, args)
    args = args or {}
    dbg("SendCommand:", command, "multiplayer=", tostring(EventTrigger.IsMultiplayer()))
    -- 总是先本地执行，以获得即时的 UI 反馈
    EventTrigger.ExecuteLocal(command, args)
    if EventTrigger.IsMultiplayer() then
        sendClientCommand("EventTrigger", command, args)
        dbg("SendCommand: also sent to server, command=", command)
    end
end

-- 本地执行指令（单机/联机共用）：更新 ModData，随后刷新列表和 UI
function EventTrigger.ExecuteLocal(command, args)
    if command == "placeTrigger" then
        local x, y, z = args.x, args.y, args.z
        local triggerId = EventTrigger._generateId()
        args.id = triggerId
        local sqData = {
            id = triggerId,
            message = args.message or "Trigger activated!",
            delay = args.delay or 3,
            range = args.range or 2,
            outputType = args.outputType or EventTrigger.OutputType.HALO,
            outputName = args.outputName or "",
            maxTriggers = args.maxTriggers or -1,
            cooldown = EventTrigger.makeCooldown(args.cooldown or { mode = EventTrigger.COOLDOWN_NONE }),
            enabled = true,
            creator = args.creator or GetPlayerIdentifier(getPlayer()),
        }
        if not EventTrigger.WriteToSquare(x, y, z, sqData) then
            dbg("placeTrigger FAILED: square not loaded at", x, y, z)
        end
        -- 联机模式：直接插入本地列表（联机下 WriteToSquare 与 RebuildList 会跳过格子操作）
        if EventTrigger.IsMultiplayer() then
            table.insert(EventTrigger.triggers, {
                id = triggerId,
                x = x, y = y, z = z,
                message = sqData.message,
                delay = sqData.delay,
                range = sqData.range,
                outputType = sqData.outputType,
                outputName = sqData.outputName,
                maxTriggers = sqData.maxTriggers,
                cooldown = sqData.cooldown,
                enabled = true,
                triggerCount = 0,
                triggeredBy = {},
                inRangePlayers = {},
                creator = sqData.creator,
            })
        end
        EventTrigger.RebuildList()
        if EventTrigger._ui then EventTrigger._ui:refreshList() end

    elseif command == "deleteTrigger" then
        local idx = args.index
        if idx and idx >= 1 and idx <= #EventTrigger.triggers then
            local t = EventTrigger.triggers[idx]
            EventTrigger.RemoveFromSquare(t.id, t.x, t.y, t.z)
            table.remove(EventTrigger.triggers, idx)
            EventTrigger._saveToModData()
            if EventTrigger._ui then EventTrigger._ui:refreshList() end
        end

    elseif command == "resetTrigger" then
        local idx = args.index
        if idx and idx >= 1 and idx <= #EventTrigger.triggers then
            local t = EventTrigger.triggers[idx]
            t.triggerCount = 0
            t.triggeredBy = {}
            t.inRangePlayers = {}
            -- 将计数与历史同步清零到格子 ModData
            EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, { triggerCount = 0, triggeredBy = {} })
            EventTrigger._saveToModData()
            if EventTrigger._ui then EventTrigger._ui:refreshList() end
        end

    elseif command == "toggleTrigger" then
        local idx = args.index
        if idx and idx >= 1 and idx <= #EventTrigger.triggers then
            local t = EventTrigger.triggers[idx]
            if args.enabled ~= nil then t.enabled = args.enabled and true or false end
            EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, { enabled = t.enabled })
            EventTrigger._saveToModData()
            if EventTrigger._ui then EventTrigger._ui:refreshList() end
        end

    elseif command == "disableAll" then
        for _, t in ipairs(EventTrigger.triggers) do
            t.enabled = false
            EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, { enabled = false })
        end
        for _, dp in ipairs(EventTrigger.deliveryPoints or {}) do
            if dp and dp.type == "delivery" then
                dp.enabled = false
            end
        end
        EventTrigger._saveToModData()
        if EventTrigger._ui then EventTrigger._ui:refreshList() end

    elseif command == "deleteAllTriggers" then
        if args.all then
            for _, t in ipairs(EventTrigger.triggers) do
                EventTrigger.RemoveFromSquare(t.id, t.x, t.y, t.z)
            end
            EventTrigger.triggers = {}
        else
            local creator = EventTrigger.GetCurrentPlayerId()
            local new = {}
            for _, t in ipairs(EventTrigger.triggers) do
                if t.creator == creator then
                    EventTrigger.RemoveFromSquare(t.id, t.x, t.y, t.z)
                else
                    table.insert(new, t)
                end
            end
            EventTrigger.triggers = new
        end
        EventTrigger._saveToModData()
        if EventTrigger._ui then EventTrigger._ui:refreshList() end

    elseif command == "editTriggerMessage" then
        local idx = args.index
        if idx and idx >= 1 and idx <= #EventTrigger.triggers then
            local t = EventTrigger.triggers[idx]
            t.message = args.message
            EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, { message = args.message })
            EventTrigger._saveToModData()
        end

    elseif command == "editTriggerParams" then
        local idx = args.index
        if idx and idx >= 1 and idx <= #EventTrigger.triggers then
            local t = EventTrigger.triggers[idx]
            if args.delay ~= nil then t.delay = math.max(0, args.delay or 0) end
            if args.range ~= nil then t.range = math.max(0.5, args.range or 2) end
            if args.maxTriggers ~= nil then t.maxTriggers = args.maxTriggers end
            if args.cooldown ~= nil then t.cooldown = EventTrigger.makeCooldown(args.cooldown) end
            local partial = {}
            if args.delay ~= nil then partial.delay = t.delay end
            if args.range ~= nil then partial.range = t.range end
            if args.maxTriggers ~= nil then partial.maxTriggers = t.maxTriggers end
            if args.cooldown ~= nil then partial.cooldown = t.cooldown end
            EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, partial)
            EventTrigger._saveToModData()
        end

    elseif command == "editTriggerOutput" then
        local idx = args.index
        if idx and idx >= 1 and idx <= #EventTrigger.triggers then
            local t = EventTrigger.triggers[idx]
            if args.outputType ~= nil then t.outputType = args.outputType end
            if args.outputName ~= nil then t.outputName = args.outputName end
            local partial = {}
            if args.outputType ~= nil then partial.outputType = t.outputType end
            if args.outputName ~= nil then partial.outputName = t.outputName end
            EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, partial)
            EventTrigger._saveToModData()
        end

    -- 同时把 triggerCount 写入格子 ModData 以持久化（仅单机）
    elseif command == "recordTrigger" then
        local idx = args.index
        if idx and idx >= 1 and idx <= #EventTrigger.triggers then
            local t = EventTrigger.triggers[idx]
            if not t.triggeredBy then t.triggeredBy = {} end
            table.insert(t.triggeredBy, {
                playerId = args.playerId or "Unknown",
                timestamp = args.timestamp or 0,
                timeStr = args.timeStr or "",
            })
            t.triggerCount = (t.triggerCount or 0) + 1
            local cd = t.cooldown or {}
            if not EventTrigger.isCooldownZero(cd) then
                t.lastTriggerAt = EventTrigger.cooldownNowSeconds(cd.mode)
            end
            -- 关键：同步写入格子 ModData（仅单机）
            if not EventTrigger.IsMultiplayer() then
                local recent = {}
                local total = #t.triggeredBy
                local start = math.max(1, total - 49)
                for j = start, total do
                    table.insert(recent, t.triggeredBy[j])
                end
                EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, {
                    triggerCount = t.triggerCount,
                    triggeredBy = recent,
                })
            end
            EventTrigger._saveToModData()
            dbg("recordTrigger: trigger #" .. idx .. " (id=" .. t.id .. ") count=" .. t.triggerCount .. " history=" .. #t.triggeredBy)
        end
    end
end

-- 移除本地列表中在服务器上已不存在的触发器（服务器为权威）
-- 解决联机删除不同步问题：RebuildList() 只会新增，从不移除，
-- 因此需要服务器列表来清理本地陈旧条目
-- 同时清理格子 ModData，防止 RebuildList 再次扫回它们
function EventTrigger._removeMissingFromServer(serverTriggers)
    local serverIds = {}
    for _, st in ipairs(serverTriggers) do
        if st.id then serverIds[st.id] = true end
    end
    local newList = {}
    local removed = 0
    for _, t in ipairs(EventTrigger.triggers) do
        if serverIds[t.id] then
            table.insert(newList, t)
        else
            -- 同时从格子 ModData 中移除，防止 RebuildList 再次扫回
            EventTrigger.RemoveFromSquare(t.id, t.x, t.y, t.z)
            removed = removed + 1
            dbg("_removeMissingFromServer: removed stale trigger id=" .. tostring(t.id) .. " from list + square")
        end
    end
    if removed > 0 then
        EventTrigger.triggers = newList
        EventTrigger._saveToModData()
        dbg("_removeMissingFromServer: cleaned up " .. removed .. " stale trigger(s)")
    end
end

-- 前向声明：GetMongooseChatPanel 稍后定义（MongooseChat 集成部分）
-- OnServerCommand 和 ShowChatMessage 会在此定义之前引用它。
local GetMongooseChatPanel

-- 服务器指令回调：syncAll → 全量列表替换（服务器 JSON 为权威）
-- namedMessage → NAMED 广播
function EventTrigger.OnServerCommand(module, command, args)
    if module ~= "EventTrigger" then
        return
    end
    dbg("OnServerCommand: received command=", command)
    if command == "syncAll" then
        -- 联机：服务器 JSON 文件为权威，完全替换本地列表
        if EventTrigger.IsMultiplayer() and args and args.triggers then
            -- 保留本地运行时状态（inRangePlayers），基于服务器数据重建
            local oldInRange = {}
            for _, t in ipairs(EventTrigger.triggers) do
                if t.id and t.inRangePlayers then
                    oldInRange[t.id] = t.inRangePlayers
                end
            end
            local newList = {}
            for _, src in ipairs(args.triggers) do
                local trigger = {
                    id          = src.id,
                    x           = src.x,
                    y           = src.y,
                    z           = src.z,
                    message     = src.message or "Trigger activated!",
                    delay       = src.delay or 3,
                    range       = src.range or 2,
                    outputType  = src.outputType or EventTrigger.OutputType.HALO,
                    outputName  = src.outputName or "",
                    maxTriggers = src.maxTriggers or -1,
                    triggerCount = src.triggerCount or 0,
                    triggeredBy = src.triggeredBy or {},
                    cooldown = EventTrigger.makeCooldown(src.cooldown or src),
                    lastTriggerAt = src.lastTriggerAt,
                    enabled = src.enabled ~= false,
                    inRangePlayers = oldInRange[src.id] or {},
                    creator     = src.creator or "unknown",
                }
                newList[#newList + 1] = trigger
            end
            EventTrigger.triggers = newList
            dbg("OnServerCommand: replaced trigger list from server, count=", #newList)

            -- 处理服务器同步过来的交付点（像触发器 inRangePlayers 一样，按对象保留 _dlvPrompted）
            if args.deliveryPoints then
                local oldDlvState = {}
                for _, oldDp in ipairs(EventTrigger.deliveryPoints) do
                    if oldDp.id and oldDp._dlvPrompted then
                        oldDlvState[oldDp.id] = oldDp._dlvPrompted
                    end
                end
                EventTrigger.deliveryPoints = {}
                for _, src in ipairs(args.deliveryPoints) do
                    local dp = {
                        id            = src.id,
                        type          = src.type or "delivery",
                        x             = src.x,
                        y             = src.y,
                        z             = src.z,
                        hintText      = src.hintText or "Delivery Point",
                        range         = src.range or 3,
                        maxPlayers    = src.maxPlayers or -1,
                        maxPerPlayer  = src.maxPerPlayer or -1,
                        requiredItems = src.requiredItems or {},
                        rewardItems   = src.rewardItems or {},
                        matchMode     = src.matchMode or "all",
                        costMode      = src.costMode or "all",
                        branches      = src.branches or {},
                        cooldown      = EventTrigger.makeCooldown(src.cooldown or src),
                        playerDeliveries = src.playerDeliveries or {},
                        playerCooldowns  = src.playerCooldowns or {},
                        enabled       = src.enabled ~= false,
                        creator       = src.creator or "unknown",
                        createdAt     = src.createdAt or os.time(),
                        triggerCount  = src.triggerCount or 0,
                        triggeredBy   = src.triggeredBy or {},
                        _dlvPrompted   = oldDlvState[src.id] or {},
                    }
                    EventTrigger.deliveryPoints[#EventTrigger.deliveryPoints + 1] = dp
                end
            end
        else
            -- 单机回退：从格子 ModData 扫描重建
            EventTrigger.RebuildList()
            if args and args.triggers then
                EventTrigger._mergeHistory(args.triggers)
                EventTrigger._removeMissingFromServer(args.triggers)
            end
        end
        if EventTrigger._ui then
            EventTrigger._ui:refreshList()
        end
    elseif command == "namedMessage" then
        -- NAMED 模式服务器广播：在所有客户端显示面板消息
        local mcPanel = type(GetMongooseChatPanel) == "function" and GetMongooseChatPanel() or nil
        if mcPanel and args then
            local cfg = EventTrigger.GetConfig()
            local author = args.outputName
            if not author or #author == 0 then author = cfg.outputName end
            mcPanel.addMessage({
                channel = "system",
                message = args.message or "",
                timestamp = os.time(),
                characterName = author,
                username = "EventTrigger",
            })
        end
    elseif command == "deliveryResult" then
        -- 交付占位桩保证 OnDeliveryResult 存在，但仍需防止整表被替换
        local player = getPlayer()
        if args and player then
            local success = (args.action == "completed")
            local msg = args.message or args.reason or ""
            local fn = EventTrigger.Delivery and EventTrigger.Delivery.OnDeliveryResult
            if type(fn) == "function" then
                fn(player, success, msg, args.rewardItems)
            end
        end
    end
end

-- 获取当前游戏内时间戳（数值时间 + 格式化的 "Day X HH:MM"）
function EventTrigger.GetTimestamp()
    local gt = getGameTime()
    if not gt then return 0, "" end
    local day = gt:getDay()
    local hour = gt:getHour()
    local min = gt:getMinutes()
    return gt:getTimeOfDay(),
        string.format("Day %d %02d:%02d", (day or 0) + 1, hour or 0, min or 0)
end

-- 将运行时统计数据持久化到 Global ModData（仅单机）
function EventTrigger._saveToModData()
    if EventTrigger.IsMultiplayer() then return end
    local data = ModData.getOrCreate("EventTrigger")
    data.triggers = EventTrigger.triggers
    data.deliveryPoints = EventTrigger.deliveryPoints
end

-- 将来源历史合并进运行时列表（按 ID 匹配，仅合并历史字段）
-- 仅单机；联机下历史通过服务器 syncAll 下发
function EventTrigger._mergeHistory(sourceTriggers)
    if not sourceTriggers then
        dbg("_mergeHistory: sourceTriggers is nil, skipping")
        return
    end
    local merged = 0
    for _, src in ipairs(sourceTriggers) do
        if src and src.id then
            local idx = EventTrigger._findIndexById(src.id)
            if idx then
                local t = EventTrigger.triggers[idx]
                if src.triggerCount and src.triggerCount > (t.triggerCount or 0) then
                    dbg("_mergeHistory: id=" .. src.id .. " oldCount=" .. (t.triggerCount or 0) .. " newCount=" .. src.triggerCount)
                    t.triggerCount = src.triggerCount
                    merged = merged + 1
                end
                if src.triggeredBy and #src.triggeredBy > 0 then
                    t.triggeredBy = src.triggeredBy
                    -- 同时写回格子 ModData 以实现格子持久化
                    EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, { triggeredBy = src.triggeredBy })
                    dbg("_mergeHistory: id=" .. src.id .. " restored " .. #src.triggeredBy .. " history entries + wrote to square")
                end
            else
                dbg("_mergeHistory: id=" .. src.id .. " not found in current triggers, skipping")
            end
        end
    end
    dbg("_mergeHistory: merged " .. merged .. " triggerCount(s), saving...")
    EventTrigger._saveToModData()
end

-- 游戏启动加载入口
-- 单机：从格子 ModData 扫描，若为空则从旧版 Global 迁移
-- 联机：向服务器请求同步（服务器 JSON 文件为权威）
function EventTrigger.Load()
    if not EventTrigger.IsMultiplayer() then
        dbg("Load: single-player not supported, skipping")
        return
    end
    if EventTrigger.IsMultiplayer() then
        dbg("Load: MP mode, requesting sync from server...")
        EventTrigger.RequestSync()
        return
    end
    -- 单机路径：从格子 ModData / Global ModData 加载
    local data = ModData.getOrCreate("EventTrigger")
    local saved = data.triggers
    local hasSaved = (saved and type(saved) == "table" and #saved > 0)
    dbg("Load: Global ModData has " .. (hasSaved and #saved or 0) .. " saved triggers")

    EventTrigger.RebuildList()

    if hasSaved then
        EventTrigger._mergeHistory(saved)
    end

    -- 单机：从 Global ModData 加载交付点
    if data.deliveryPoints and type(data.deliveryPoints) == "table" and #data.deliveryPoints > 0 then
        EventTrigger.deliveryPoints = {}
        for _, dp in ipairs(data.deliveryPoints) do
            if dp.id and dp.type == "delivery" then
                local restored = {
                    id            = dp.id,
                    type          = dp.type,
                    x             = dp.x or 0,
                    y             = dp.y or 0,
                    z             = dp.z or 0,
                    hintText      = dp.hintText or "Delivery Point",
                    range         = dp.range or 3,
                    maxPlayers    = dp.maxPlayers or -1,
                    maxPerPlayer  = dp.maxPerPlayer or -1,
                    requiredItems = dp.requiredItems or {},
                    rewardItems   = dp.rewardItems or {},
                    matchMode     = dp.matchMode or "all",
                    costMode      = dp.costMode or "all",
                    branches      = dp.branches or {},
                    cooldown      = EventTrigger.makeCooldown(dp.cooldown or dp),
                    playerDeliveries = dp.playerDeliveries or {},
                    playerCooldowns  = dp.playerCooldowns or {},
                    enabled       = dp.enabled ~= false,
                    creator       = dp.creator or "unknown",
                    createdAt     = dp.createdAt or os.time(),
                    triggerCount  = dp.triggerCount or 0,
                    triggeredBy   = dp.triggeredBy or {},
                    _dlvPrompted   = {},
                }
                EventTrigger.deliveryPoints[#EventTrigger.deliveryPoints + 1] = restored
            end
        end
    end

    if #EventTrigger.triggers == 0 then
        local legacy = saved or {}
        if #legacy > 0 then
            dbg("Load: migrating", #legacy, "triggers from legacy ModData to squares")
            for _, t in ipairs(legacy) do
                if t.x and t.y then
                    local sqData = {
                        message = t.message or "Trigger activated!",
                        delay = t.delay or 3,
                        range = t.range or 2,
                        outputType = t.outputType or EventTrigger.OutputType.HALO,
                        outputName = t.outputName or "",
                        maxTriggers = t.maxTriggers or -1,
                        creator = t.creator or "unknown",
                    }
                    EventTrigger.WriteToSquare(t.x, t.y, t.z or 0, sqData)
                end
            end
            data.triggers = {}
            EventTrigger.RebuildList()
        end
    end
    dbg("Load: loaded", #EventTrigger.triggers, "triggers")
end

-- 向服务器请求触发器同步（仅联机）
function EventTrigger.RequestSync(all)
    if EventTrigger.IsMultiplayer() then
        dbg("RequestSync: sending requestSync to server, all=", tostring(all))
        sendClientCommand("EventTrigger", "requestSync", { all = all })
    else
        dbg("RequestSync: single player, no sync needed")
    end
end

-- 获取玩家可读名称（优先 Steam 用户名，回退到角色名）
local function GetPlayerName(player)
    if not player then return "Player" end
    local name = player:getUsername()
    if name and #name > 0 then return name end
    local desc = player:getDescriptor()
    if desc then
        name = desc:getForename()
        if name and #name > 0 then
            local sur = desc:getSurname()
            if sur and #sur > 0 then return name .. " " .. sur end
            return name
        end
    end
    return "Player"
end

-- 将输出类型数字转换为可读名称（UI 显示用）
local function OutputTypeToName(ot)
    return OutputTypeNames[ot] or "Above Head"
end

-- ============================================================
-- MongooseChat 集成：懒加载 MC_ChatPanel + 动态注册 system 频道
-- 使用 pcall require 安全加载，未安装 MongooseChat 时避免崩溃
-- ============================================================
local _mcChatPanel = nil
GetMongooseChatPanel = function()
    if _mcChatPanel ~= nil then return _mcChatPanel end
    local ok1, MC_ChatPanel = pcall(require, "MC_ChatPanel")
    if not ok1 or not MC_ChatPanel then
        _mcChatPanel = false
        dbg("MongooseChat integration: MC_ChatPanel module not available")
        return _mcChatPanel
    end
    -- 获取正在运行的面板实例（由 MongooseChat 在 init 时创建）
    local instance = MC_ChatPanel.instance
    if not instance or not instance.addMessage then
        _mcChatPanel = false
        dbg("MongooseChat integration: MC_ChatPanel.instance not ready")
        return _mcChatPanel
    end
    -- 动态注册 system 频道（EventTrigger 系统消息）
    local ok2, MC_Config = pcall(require, "MC_Config")
    if ok2 and MC_Config then
        if not MC_Config.ChannelColors["system"] then
            MC_Config.ChannelColors["system"] = {000, 191, 255}  -- 蓝色
        end
        if not MC_Config.ChannelTags["system"] then
            MC_Config.ChannelTags["system"] = "[System]"
        end
    end
    _mcChatPanel = instance
    dbg("MongooseChat integration: ready (MC_ChatPanel.instance acquired)")
    return _mcChatPanel
end

-- 懒加载 MC_Bubble 模块，创建对话气泡（用于 say/do 频道）
local _mcBubble = nil
local function ShowMCBubble(bubbleType, player, msg)
    if not player then return end
    if _mcBubble == nil then
        local ok, MB = pcall(require, "MC_Bubble")
        if ok and MB then
            _mcBubble = MB
        else
            _mcBubble = false
            return
        end
    end
    if not _mcBubble then return end

    local bubble
    if bubbleType == "say" or bubbleType == "low" or bubbleType == "yell" then
        bubble = _mcBubble:new(player, msg, bubbleType)
    elseif bubbleType == "do" then
        bubble = _mcBubble:newDo(msg, player)
    end
    if bubble then
        bubble:initialise()
        bubble:addToUIManager()
        bubble:setVisible(true)
    end
end

-- 创建聊天消息对象（满足 ISChat.addLineInChat 接口）
local function CreateChatMessage(text, author)
    local msg = { text = text, author = author }
    function msg:getTextWithPrefix()
        if self.author and #self.author > 0 then
            return self.author .. ": " .. self.text
            -- return "[" .. self.author .. "]: " .. self.text
        end
        return self.text
    end
    function msg:getAuthor() return self.author end
    function msg:isShowAuthor() return self.author and #self.author > 0 end
    function msg:getText() return self.text end
    function msg:setText(t) self.text = t end
    return msg
end

-- 显示触发器消息
-- NAMED / HALO：仅本地显示；BROADCAST：服务器广播；语音频道：MongooseChat 服务器管线
local function ShowChatMessage(msg, triggerPlayer, outputType, outputName)
    local player = triggerPlayer or getPlayer()
    if not player then return end
    local ot = outputType or EventTrigger.OutputType.HALO
    local cfg = EventTrigger.GetConfig()

    -- HALO：头顶漂浮文字（仅本地显示）
    if ot == EventTrigger.OutputType.HALO then
        HaloTextHelper.addGoodText(player, msg)
        return
    end

    -- NAMED：具名系统频道（仅本地显示）
    if ot == EventTrigger.OutputType.NAMED then
        local author = outputName
        if not author or #author == 0 then author = cfg.outputName end
        local mcPanel = GetMongooseChatPanel()
        if mcPanel then
            mcPanel.addMessage({
                channel = "system",
                message = msg,
                timestamp = os.time(),
                characterName = author,
                username = "EventTrigger",
            })
        elseif ISChat.instance then
            local chatMsg = CreateChatMessage(msg, author)
            if chatMsg then ISChat.addLineInChat(chatMsg, 0) end
        else
            HaloTextHelper.addGoodText(player, msg)
        end
        return
    end

    -- BROADCAST：服务器广播（全服可见，可具名）
    if ot == EventTrigger.OutputType.BROADCAST then
        sendClientCommand("EventTrigger", "namedMessage", {
            message = msg,
            outputName = outputName,
        })
        return
    end

    local CHANNEL_MAP = {
        [EventTrigger.OutputType.SAY]   = { mc = "say",    bubble = true  },
        [EventTrigger.OutputType.DO]    = { mc = "do",     bubble = false },
        [EventTrigger.OutputType.LOW]   = { mc = "low",    bubble = true  },
        [EventTrigger.OutputType.YELL]  = { mc = "yell",   bubble = true  },
        [EventTrigger.OutputType.OOC]   = { mc = "ooc",    bubble = false },
    }

    local ch = CHANNEL_MAP[ot]
    if not ch then return end

    -- ================================================================
    -- 联机路径：语音频道走 MongooseChat 服务器管线（范围内所有玩家可见）
    -- ================================================================
    if EventTrigger.IsMultiplayer() then
        -- SAY/LOW/YELL/DO/OOC：伪装成玩家聊天，由 MC 服务器负责范围计算与广播
        -- 所有范围内客户端会自动收到面板 + 气泡（通过 MC_Client.onChatMessage）
        sendClientCommand("MongooseChat", "ChatMessage", {
            channel = ch.mc,
            message = msg,
            radioEmitters = {},
        })
        return
    end

    -- ================================================================
    -- 单机路径：直接调用 MC_ChatPanel + MC_Bubble（无服务器）
    -- ================================================================
    local mcPanel = GetMongooseChatPanel()
    if mcPanel then
        local mcData = { message = msg, timestamp = os.time(), channel = ch.mc }
        local desc = triggerPlayer and triggerPlayer:getDescriptor()
        local charName = "Player"
        if desc then
            local f = desc:getForename()
            local s = desc:getSurname()
            if f and #f > 0 then
                charName = f
                if s and #s > 0 then charName = charName .. " " .. s end
            end
        end
        mcData.characterName = charName
        mcData.username = GetPlayerIdentifier(triggerPlayer) or charName
        mcPanel.addMessage(mcData)
        if ch.bubble then
            ShowMCBubble(ch.mc, triggerPlayer, mcData.message)
        end
        return
    end

    -- === 回退方案（原生 ISChat / HALO） ===
    if not ISChat.instance then
        HaloTextHelper.addGoodText(player, msg)
        return
    end

    local ok, err = pcall(function()
        local chatMsg = CreateChatMessage(msg, GetPlayerName(triggerPlayer))
        if chatMsg then
            ISChat.addLineInChat(chatMsg, 0)
        end
    end)
    if not ok then
        dbg("ShowChatMessage error:", err, "- falling back to HALO")
        HaloTextHelper.addGoodText(player, msg)
    end
end

-- 调度延迟消息：delayFrames = 秒数 * 60（60fps），在 OnTick 中检查
function EventTrigger.ScheduleMessage(delayFrames, message, player, outputType, outputName)
    EventTrigger.timerIdCounter = EventTrigger.timerIdCounter + 1
    local timerId = "timer_" .. tostring(EventTrigger.tickCounter) .. "_" .. tostring(EventTrigger.timerIdCounter)
    EventTrigger.timers[timerId] = {
        endTick = EventTrigger.tickCounter + delayFrames,
        message = message,
        player = player,
        outputType = outputType,
        outputName = outputName,
    }
end

EventTrigger._scanCounter = 0

-- 每帧执行：周期扫描（约 5 秒一次）、玩家距离检测、定时器到期处理
function EventTrigger.OnTick()
    if not EventTrigger.IsMultiplayer() then return end
    EventTrigger.tickCounter = EventTrigger.tickCounter + 1

    EventTrigger._scanCounter = EventTrigger._scanCounter + 1
    if EventTrigger._scanCounter >= 300 then
        EventTrigger._scanCounter = 0
        EventTrigger.RebuildList()
    end

    local idx = 0
    while true do
        local player = getSpecificPlayer(idx)
        if not player then break end
        local px, py, pz = player:getX(), player:getY(), player:getZ()
        local playerKey = GetPlayerIdentifier(player)
        for i, trigger in ipairs(EventTrigger.triggers) do
            local dx, dy = px - trigger.x, py - trigger.y
            local dist = math.sqrt(dx*dx + dy*dy)
            local inRange = (pz == trigger.z) and (dist < (trigger.range or 2))
            if inRange and trigger.enabled ~= false then
                if not trigger.inRangePlayers[playerKey] then
                    local exhausted = trigger.maxTriggers > 0 and (trigger.triggerCount or 0) >= trigger.maxTriggers
                    local cooldownReady = EventTrigger.isTriggerCooldownReady(trigger)
                    if not exhausted and cooldownReady then
                        trigger.inRangePlayers[playerKey] = true
                        local ts, tsStr = EventTrigger.GetTimestamp()
                        EventTrigger.SendCommand("recordTrigger", {
                            index = i,
                            id = trigger.id,
                            playerId = playerKey,
                            timestamp = ts,
                            timeStr = tsStr,
                        })
                        EventTrigger.ScheduleMessage(
                            (trigger.delay or 3) * 60,
                            trigger.message,
                            player,
                            trigger.outputType,
                            trigger.outputName)
                    end
                end
            else
                trigger.inRangePlayers[playerKey] = nil
            end
        end

        -- 交付点检测（委派给 EventTriggerDelivery 模块；即使被占位桩替代也安全）
        EventTrigger.Delivery.CheckPlayerInRange(player)
        idx = idx + 1
    end

    for id, timer in pairs(EventTrigger.timers) do
        if EventTrigger.tickCounter >= timer.endTick then
            ShowChatMessage(timer.message, timer.player, timer.outputType, timer.outputName)
            EventTrigger.timers[id] = nil
        end
    end
end

-- 打开主管理 UI（防止重复打开）
function EventTrigger.OpenUI()
    if EventTrigger._ui then
        EventTrigger._ui:close()
    end
    EventTrigger._ui = EventTriggerUI:new()
    EventTrigger._ui:initialise()
    EventTrigger._ui:addToUIManager()
end

-- 右键世界物体菜单：仅管理员可见的条目（放置触发器 + 交付点 + 管理器）
function EventTrigger.OnFillWorldObjectContextMenu(playerIndex, context, worldObjects, test)
    if test then return end
    if not EventTrigger.IsMultiplayer() then return end
    local player = getSpecificPlayer(playerIndex)
    if not player then return end

    -- 仅管理员（或单机主机）可以使用管理器 / 放置点位。
    local isAdmin = player:getAccessLevel() == "admin"
    if not isAdmin then return end

    local square = worldObjects[1] and worldObjects[1]:getSquare()
    if square then
        local x, y, z = square:getX(), square:getY(), square:getZ()
        local txt = string.format("%s (%d,%d,%d)", getText("UI_ET_Ctx_PlaceTrigger"), x, y, z)
        context:addOption(txt, nil, function()
            EventTrigger.PromptDelayRange(x, y, z)
        end)
        -- 仅在交付模块确实可用时才提供交付点放置入口。
        if EventTrigger.DeliveryLoaded then
            local dlvTxt = string.format("%s (%d,%d,%d)", getText("UI_ET_Ctx_SetDelivery"), x, y, z)
            context:addOption(dlvTxt, nil, function()
                EventTrigger.Delivery.StartSetup(x, y, z)
            end)
        end
    end

    context:addOption(getText("UI_ET_Ctx_Manager"), nil, EventTrigger.OpenUI)
end

-- ============================================================
-- EventTriggerTextPrompt — 统一文本输入对话框
-- 替代 ISTextBox 用于向导步骤：正确的多行提示处理
-- 以及宽敞的布局，使提示永不与输入框/按钮重叠。
-- ============================================================
EventTriggerTextPrompt = ISPanel:derive("EventTriggerTextPrompt")

function EventTriggerTextPrompt:new(title, prompt, defaultText, onOk, onCancel, onBack)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()

    local lines = {}
    if prompt then
        for line in (prompt .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end
    end
    if #lines == 0 then lines[1] = "" end

    local s = EventTrigger.US
    local titleH = 28
    local lineH = math.floor(20 * s)
    local padX = math.floor(24 * s)
    local entryH = math.floor(30 * s)
    local btnH = math.floor(34 * s)

    local w = EventTrigger.fitW(560)
    local promptTop = titleH + math.floor(18 * s)
    local promptH = #lines * lineH
    local entryY = promptTop + promptH + math.floor(14 * s)
    local btnY = entryY + entryH + math.floor(22 * s)
    local h = btnY + btnH + math.floor(18 * s)
    if h < 240 then h = 240 end

    local x = (sw - w) / 2
    local y = (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.92 }
    o.width = w
    o.height = h
    o.title = title
    o.lines = lines
    o.s = s
    o.lineH = lineH
    o.padX = padX
    o.entryH = entryH
    o.btnH = btnH
    o.promptTop = promptTop
    o.entryY = entryY
    o.btnY = btnY
    o.defaultText = defaultText or ""
    o.onOkCallback = onOk
    o.onCancelCallback = onCancel
    o.onBackCallback = onBack
    o.dragging = false
    return o
end

function EventTriggerTextPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerTextPrompt:create()
    self:setAlwaysOnTop(true)

    local padX = self.padX
    local entryH = self.entryH
    local btnH = self.btnH
    local gap = 20

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerTextPrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self.entry = ISTextEntryBox:new(self.defaultText, padX, self.entryY, self.width - padX * 2, entryH)
    self.entry:initialise()
    self.entry:instantiate()
    self:addChild(self.entry)

    local okLabel = getText("UI_ET_Btn_OK")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local okW = EventTrigger.btnW(okLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)

    if self.onBackCallback then
        local backLabel = getText("UI_ET_Btn_Back")
        local backW = EventTrigger.btnW(backLabel)
        local total = backW + gap + okW + gap + cancelW
        local startX = (self.width - total) / 2

        self.backBtn = ISButton:new(startX, self.btnY, backW, btnH, backLabel, self, EventTriggerTextPrompt.onBack)
        self.backBtn:initialise()
        self:addChild(self.backBtn)

        local okX = startX + backW + gap
        self.okBtn = ISButton:new(okX, self.btnY, okW, btnH, okLabel, self, EventTriggerTextPrompt.onOk)
        self.okBtn:initialise()
        self:addChild(self.okBtn)

        self.cancelBtn = ISButton:new(okX + okW + gap, self.btnY, cancelW, btnH, cancelLabel, self, EventTriggerTextPrompt.onCancel)
        self.cancelBtn:initialise()
        self:addChild(self.cancelBtn)
    else
        local okX = (self.width - (okW + gap + cancelW)) / 2
        self.okBtn = ISButton:new(okX, self.btnY, okW, btnH, okLabel, self, EventTriggerTextPrompt.onOk)
        self.okBtn:initialise()
        self:addChild(self.okBtn)

        self.cancelBtn = ISButton:new(okX + okW + gap, self.btnY, cancelW, btnH, cancelLabel, self, EventTriggerTextPrompt.onCancel)
        self.cancelBtn:initialise()
        self:addChild(self.cancelBtn)
    end
end

function EventTriggerTextPrompt:onOk()
    local text = self.entry and self.entry:getText() or ""
    self:close()
    if self.onOkCallback then self.onOkCallback(text) end
end

function EventTriggerTextPrompt:onCancel()
    self:close()
    if self.onCancelCallback then self.onCancelCallback() end
end

function EventTriggerTextPrompt:onBack()
    self:close()
    if self.onBackCallback then self.onBackCallback() end
end

function EventTriggerTextPrompt:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerTextPrompt:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerTextPrompt:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerTextPrompt:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerTextPrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 0.35, 0.35, 0.35)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre(self.title or "", self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local y = self.promptTop
    for _, line in ipairs(self.lines) do
        if line and #line > 0 then
            self:drawText(line, self.padX, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
        end
        y = y + self.lineH
    end
end

-- ============================================================
-- 模态对话框共享的拖动处理函数
-- ============================================================
local function promptMouseDown(self, x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

local function promptMouseMove(self, x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

local function promptMouseUp(self, x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

local function readIntEntry(entry)
    local v = tonumber(entry and entry:getText() or "")
    if not v then return 0 end
    v = math.floor(v)
    if v < 0 then return 0 end
    return v
end

-- ============================================================
-- EventTriggerChoicePrompt — 基于按钮的单选对话框
-- ============================================================
EventTriggerChoicePrompt = ISPanel:derive("EventTriggerChoicePrompt")
EventTriggerChoicePrompt.onMouseDown = promptMouseDown
EventTriggerChoicePrompt.onMouseMove = promptMouseMove
EventTriggerChoicePrompt.onMouseUp = promptMouseUp

function EventTriggerChoicePrompt:new(title, prompt, choices, selectedValue, onChoose, onCancel, onBack)
    local s = EventTrigger.US
    local w = EventTrigger.fitW(520)
    local btnH = math.floor(38 * s)
    local gap = math.floor(10 * s)
    local pad = math.floor(20 * s)
    local titleH = 28
    local promptY = titleH + math.floor(16 * s)
    local listTop = promptY + math.floor(24 * s)
    local bottomH = btnH + math.floor(24 * s)
    local h = listTop + #choices * (btnH + gap) + bottomH

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.92 }
    o.width = w
    o.height = h
    o.title = title
    o.prompt = prompt
    o.choices = choices
    o.selectedValue = selectedValue
    o.onChooseCallback = onChoose
    o.onCancelCallback = onCancel
    o.onBackCallback = onBack
    o.btnH = btnH
    o.gap = gap
    o.pad = pad
    o.promptY = promptY
    o.listTop = listTop
    o.dragging = false
    return o
end

function EventTriggerChoicePrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerChoicePrompt:create()
    self:setAlwaysOnTop(true)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerChoicePrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    local cy = self.listTop
    for _, choice in ipairs(self.choices) do
        local c = choice
        local label = c.label
        if c.value == self.selectedValue then label = "> " .. label end
        local btn = ISButton:new(self.pad, cy, self.width - self.pad * 2, self.btnH, label, self, function()
            self:onChoose(c.value)
        end)
        btn:initialise()
        self:addChild(btn)
        cy = cy + self.btnH + self.gap
    end

    -- 底部按钮
    local btnY = self.height - self.btnH - math.floor(12 * EventTrigger.US)
    local bx = self.pad
    local function place(title, handler)
        local bw = EventTrigger.btnW(title)
        local b = ISButton:new(bx, btnY, bw, self.btnH, title, self, handler)
        b:initialise()
        self:addChild(b)
        bx = bx + bw + 10
        return b
    end
    if self.onBackCallback then place(getText("UI_ET_Btn_Back"), EventTriggerChoicePrompt.onBack) end
    place(getText("UI_ET_Btn_Cancel"), EventTriggerChoicePrompt.onCancel)
end

function EventTriggerChoicePrompt:onChoose(value)
    self:close()
    if self.onChooseCallback then self.onChooseCallback(value) end
end

function EventTriggerChoicePrompt:onCancel()
    self:close()
    if self.onCancelCallback then self.onCancelCallback() end
end

function EventTriggerChoicePrompt:onBack()
    self:close()
    if self.onBackCallback then self.onBackCallback() end
end

function EventTriggerChoicePrompt:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerChoicePrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 0.35, 0.35, 0.35)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre(self.title or "", self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)
    if self.prompt and #self.prompt > 0 then
        self:drawText(self.prompt, self.pad, self.promptY, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end
end

-- ============================================================
-- EventTriggerNumberPrompt — 带校验/范围钳制的数值输入框
-- ============================================================
EventTriggerNumberPrompt = ISPanel:derive("EventTriggerNumberPrompt")
EventTriggerNumberPrompt.onMouseDown = promptMouseDown
EventTriggerNumberPrompt.onMouseMove = promptMouseMove
EventTriggerNumberPrompt.onMouseUp = promptMouseUp

function EventTriggerNumberPrompt:new(title, prompt, defaultText, onOk, onCancel, onBack, opts)
    local s = EventTrigger.US
    local w = EventTrigger.fitW(480)
    local titleH = 28
    local promptY = titleH + math.floor(18 * s)
    local entryH = math.floor(30 * s)
    local entryY = promptY + math.floor(24 * s)
    local btnH = math.floor(34 * s)
    local btnY = entryY + entryH + math.floor(22 * s)
    local h = btnY + btnH + math.floor(18 * s)
    local pad = math.floor(24 * s)

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.92 }
    o.width = w
    o.height = h
    o.title = title
    o.prompt = prompt
    o.defaultText = tostring(defaultText or "")
    o.opts = opts or {}
    o.onOkCallback = onOk
    o.onCancelCallback = onCancel
    o.onBackCallback = onBack
    o.promptY = promptY
    o.entryY = entryY
    o.entryH = entryH
    o.btnY = btnY
    o.btnH = btnH
    o.pad = pad
    o.dragging = false
    return o
end

function EventTriggerNumberPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerNumberPrompt:create()
    self:setAlwaysOnTop(true)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerNumberPrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self.entry = ISTextEntryBox:new(self.defaultText, self.pad, self.entryY, self.width - self.pad * 2, self.entryH)
    self.entry:initialise()
    self.entry:instantiate()
    -- 仅当字段不允许负数（如 -1 = 无限制）时才限制为纯数字。
    if self.opts.integer and (self.opts.min == nil or self.opts.min >= 0) then
        self.entry:setOnlyNumbers(true)
    end
    self:addChild(self.entry)

    local okLabel = getText("UI_ET_Btn_OK")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local backLabel = getText("UI_ET_Btn_Back")
    local okW = EventTrigger.btnW(okLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)
    local backW = self.onBackCallback and EventTrigger.btnW(backLabel) or 0
    local gap = 16
    local total = okW + gap + cancelW + (backW > 0 and (gap + backW) or 0)
    local startX = (self.width - total) / 2

    local bx = startX
    if backW > 0 then
        self.backBtn = ISButton:new(bx, self.btnY, backW, self.btnH, backLabel, self, EventTriggerNumberPrompt.onBack)
        self.backBtn:initialise()
        self:addChild(self.backBtn)
        bx = bx + backW + gap
    end
    self.okBtn = ISButton:new(bx, self.btnY, okW, self.btnH, okLabel, self, EventTriggerNumberPrompt.onOk)
    self.okBtn:initialise()
    self:addChild(self.okBtn)
    bx = bx + okW + gap
    self.cancelBtn = ISButton:new(bx, self.btnY, cancelW, self.btnH, cancelLabel, self, EventTriggerNumberPrompt.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)
end

function EventTriggerNumberPrompt:onOk()
    local raw = self.entry and self.entry:getText() or ""
    local num = tonumber(raw)
    if num == nil then num = tonumber(self.defaultText) end
    if num == nil then num = 0 end
    if self.opts.integer then num = math.floor(num) end
    if self.opts.min and num < self.opts.min then num = self.opts.min end
    if self.opts.max and num > self.opts.max then num = self.opts.max end
    self:close()
    if self.onOkCallback then self.onOkCallback(num) end
end

function EventTriggerNumberPrompt:onCancel()
    self:close()
    if self.onCancelCallback then self.onCancelCallback() end
end

function EventTriggerNumberPrompt:onBack()
    self:close()
    if self.onBackCallback then self.onBackCallback() end
end

function EventTriggerNumberPrompt:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerNumberPrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 0.35, 0.35, 0.35)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre(self.title or "", self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)
    if self.prompt and #self.prompt > 0 then
        self:drawText(self.prompt, self.pad, self.promptY, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end
end

-- ============================================================
-- EventTriggerCooldownPrompt — 模式按钮 + 年/月/日/时/分输入
-- ============================================================
EventTriggerCooldownPrompt = ISPanel:derive("EventTriggerCooldownPrompt")
EventTriggerCooldownPrompt.onMouseDown = promptMouseDown
EventTriggerCooldownPrompt.onMouseMove = promptMouseMove
EventTriggerCooldownPrompt.onMouseUp = promptMouseUp

local COOLDOWN_FIELDS = {
    { key = "years",   label = getText("UI_ET_Cd_Years") },
    { key = "months",  label = getText("UI_ET_Cd_Months") },
    { key = "days",    label = getText("UI_ET_Cd_Days") },
    { key = "hours",   label = getText("UI_ET_Cd_Hours") },
    { key = "minutes", label = getText("UI_ET_Cd_Minutes") },
}

function EventTriggerCooldownPrompt:new(cooldown, onOk, onCancel, onBack)
    cooldown = EventTrigger.makeCooldown(cooldown or {})
    local s = EventTrigger.US
    local w = EventTrigger.fitW(680)
    local titleH = 28
    local modeY = titleH + math.floor(16 * s)
    local modeBtnH = math.floor(34 * s)
    local fieldLabelY = modeY + modeBtnH + math.floor(22 * s)
    local fieldEntryY = fieldLabelY + math.floor(18 * s)
    local fieldEntryH = math.floor(28 * s)
    local btnH = math.floor(34 * s)
    local btnY = fieldEntryY + fieldEntryH + math.floor(22 * s)
    local h = btnY + btnH + math.floor(18 * s)
    local pad = math.floor(20 * s)

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.92 }
    o.width = w
    o.height = h
    o.cooldown = cooldown
    o.mode = cooldown.mode
    o.onOkCallback = onOk
    o.onCancelCallback = onCancel
    o.onBackCallback = onBack
    o.modeY = modeY
    o.modeBtnH = modeBtnH
    o.fieldLabelY = fieldLabelY
    o.fieldEntryY = fieldEntryY
    o.fieldEntryH = fieldEntryH
    o.btnY = btnY
    o.btnH = btnH
    o.pad = pad
    o.entries = {}
    o.dragging = false
    return o
end

function EventTriggerCooldownPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerCooldownPrompt:create()
    self:setAlwaysOnTop(true)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerCooldownPrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    -- 模式按钮（固定宽度，避免选中前缀 "> " 导致溢出）
    local modeDefs = {
        { EventTrigger.COOLDOWN_NONE, getText("UI_ET_Cd_None") },
        { EventTrigger.COOLDOWN_WALL, getText("UI_ET_Cd_Wall") },
        { EventTrigger.COOLDOWN_GAME, getText("UI_ET_Cd_Game") },
    }
    local modeW = EventTrigger.btnW(getText("UI_ET_Cd_Wall")) + 24
    local gap = math.floor(12 * EventTrigger.US)
    local totalW = modeW * 3 + gap * 2
    local mx = (self.width - totalW) / 2
    self.modeButtons = {}
    for i, md in ipairs(modeDefs) do
        local m = md[1]
        local label = md[2]
        local btn = ISButton:new(mx + (i - 1) * (modeW + gap), self.modeY, modeW, self.modeBtnH, label, self, function()
            self:setMode(m)
        end)
        btn:initialise()
        self:addChild(btn)
        self.modeButtons[m] = btn
    end

    -- 五个时长字段
    local fieldW = math.floor(90 * EventTrigger.US)
    local fgap = math.floor(12 * EventTrigger.US)
    local fTotal = fieldW * 5 + fgap * 4
    local fx = (self.width - fTotal) / 2
    for i, fd in ipairs(COOLDOWN_FIELDS) do
        local cx = fx + (i - 1) * (fieldW + fgap)
        local lbl = ISLabel:new(cx, self.fieldLabelY, 16, fd.label, 0.7, 0.8, 0.9, 1, UIFont.Small, true)
        lbl:initialise()
        self:addChild(lbl)

        local entry = ISTextEntryBox:new(tostring(self.cooldown[fd.key] or 0), cx, self.fieldEntryY, fieldW, self.fieldEntryH)
        entry:initialise()
        entry:instantiate()
        entry:setOnlyNumbers(true)
        self:addChild(entry)
        self.entries[fd.key] = entry
    end

    -- 底部按钮
    local okLabel = getText("UI_ET_Btn_OK")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local backLabel = getText("UI_ET_Btn_Back")
    local okW = EventTrigger.btnW(okLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)
    local backW = self.onBackCallback and EventTrigger.btnW(backLabel) or 0
    local bgap = 16
    local btotal = okW + bgap + cancelW + (backW > 0 and (bgap + backW) or 0)
    local bx = (self.width - btotal) / 2
    if backW > 0 then
        self.backBtn = ISButton:new(bx, self.btnY, backW, self.btnH, backLabel, self, EventTriggerCooldownPrompt.onBack)
        self.backBtn:initialise()
        self:addChild(self.backBtn)
        bx = bx + backW + bgap
    end
    self.okBtn = ISButton:new(bx, self.btnY, okW, self.btnH, okLabel, self, EventTriggerCooldownPrompt.onOk)
    self.okBtn:initialise()
    self:addChild(self.okBtn)
    bx = bx + okW + bgap
    self.cancelBtn = ISButton:new(bx, self.btnY, cancelW, self.btnH, cancelLabel, self, EventTriggerCooldownPrompt.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self:refreshModeButtons()
    self:updateFieldEnable()
end

function EventTriggerCooldownPrompt:setMode(mode)
    self.mode = mode
    self:refreshModeButtons()
    self:updateFieldEnable()
end

function EventTriggerCooldownPrompt:refreshModeButtons()
    local labels = {
        [EventTrigger.COOLDOWN_NONE] = getText("UI_ET_Cd_None"),
        [EventTrigger.COOLDOWN_WALL] = getText("UI_ET_Cd_Wall"),
        [EventTrigger.COOLDOWN_GAME] = getText("UI_ET_Cd_Game"),
    }
    for mode, btn in pairs(self.modeButtons) do
        local prefix = (mode == self.mode) and "> " or "   "
        btn:setTitle(prefix .. labels[mode])
    end
end

function EventTriggerCooldownPrompt:updateFieldEnable()
    local enabled = (self.mode ~= EventTrigger.COOLDOWN_NONE)
    for _, fd in ipairs(COOLDOWN_FIELDS) do
        local entry = self.entries[fd.key]
        if entry then entry:setEditable(enabled) end
    end
end

function EventTriggerCooldownPrompt:onOk()
    local cd
    if self.mode == EventTrigger.COOLDOWN_NONE then
        cd = EventTrigger.makeCooldown({ mode = EventTrigger.COOLDOWN_NONE })
    else
        cd = {
            mode    = self.mode,
            years   = readIntEntry(self.entries.years),
            months  = readIntEntry(self.entries.months),
            days    = readIntEntry(self.entries.days),
            hours   = readIntEntry(self.entries.hours),
            minutes = readIntEntry(self.entries.minutes),
        }
    end
    self:close()
    if self.onOkCallback then self.onOkCallback(cd) end
end

function EventTriggerCooldownPrompt:onCancel()
    self:close()
    if self.onCancelCallback then self.onCancelCallback() end
end

function EventTriggerCooldownPrompt:onBack()
    self:close()
    if self.onBackCallback then self.onBackCallback() end
end

function EventTriggerCooldownPrompt:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerCooldownPrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 0.35, 0.35, 0.35)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre(getText("UI_ET_Cd_Title"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)
end

-- ============================================================
-- 放置向导（多步输入）
-- 第 1 步：输入延迟（秒）、范围、最大触发次数
-- ============================================================
-- 输出模式选项（放置向导与编辑向导共用）
EventTrigger.OUTPUT_CHOICES = {
    { label = getText("UI_ET_Out_Named_Desc"), value = EventTrigger.OutputType.NAMED },
    { label = getText("UI_ET_Out_Say_Desc"),   value = EventTrigger.OutputType.SAY },
    { label = getText("UI_ET_Out_Do_Desc"),    value = EventTrigger.OutputType.DO },
    { label = getText("UI_ET_Out_Low_Desc"),   value = EventTrigger.OutputType.LOW },
    { label = getText("UI_ET_Out_Yell_Desc"), value = EventTrigger.OutputType.YELL },
    { label = getText("UI_ET_Out_Ooc_Desc"),  value = EventTrigger.OutputType.OOC },
    { label = getText("UI_ET_Out_Halo_Desc"), value = EventTrigger.OutputType.HALO },
    { label = getText("UI_ET_Out_Broadcast_Desc"), value = EventTrigger.OutputType.BROADCAST },
}

function EventTrigger.PromptDelayRange(x, y, z)
    local cfg = EventTrigger.GetConfig()
    local prev = EventTrigger._pending
    EventTrigger._pending = {
        x = x, y = y, z = z,
        delay       = (prev and prev.delay) or 3,
        range       = (prev and prev.range) or cfg.defaultRange,
        maxTriggers = (prev and prev.maxTriggers) or -1,
        msg         = prev and prev.msg,
        outputType  = (prev and prev.outputType) or EventTrigger.OutputType.SAY,
        outputName  = prev and prev.outputName,
        cooldown    = prev and prev.cooldown,
    }
    EventTrigger.PromptDelay()
end

function EventTrigger.PromptDelay()
    local p = EventTrigger._pending
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Wiz_Delay"),
        getText("UI_ET_Wiz_DelayHint"),
        tostring(p.delay or 3),
        function(num)
            p.delay = num
            EventTrigger.PromptRange()
        end,
        function() EventTrigger._pending = nil end,
        nil,
        { integer = true, min = 0, max = 3600 })
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.PromptRange()
    local p = EventTrigger._pending
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Wiz_Range"),
        getText("UI_ET_Wiz_RangeHint"),
        tostring(p.range or 2),
        function(num)
            p.range = num
            EventTrigger.PromptMaxTriggers()
        end,
        function() EventTrigger._pending = nil end,
        function() EventTrigger.PromptDelay() end,
        { min = 0.5 })
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.PromptMaxTriggers()
    local p = EventTrigger._pending
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Wiz_MaxTriggers"),
        getText("UI_ET_Wiz_MaxTriggersHint"),
        tostring(p.maxTriggers or -1),
        function(num)
            if num == 0 then num = -1 end
            p.maxTriggers = num
            EventTrigger.PromptMessage2()
        end,
        function() EventTrigger._pending = nil end,
        function() EventTrigger.PromptRange() end,
        { integer = true, min = -1 })
    modal:initialise()
    modal:addToUIManager()
end

-- 第 4 步：输入触发器消息文本
function EventTrigger.PromptMessage2()
    local p = EventTrigger._pending
    local defaultText = (p.msg and #p.msg > 0) and p.msg or "Trigger activated!"
    local modal = EventTriggerTextPrompt:new(
        getText("UI_ET_Wiz_Message"),
        getText("UI_ET_Wiz_MessageHint"),
        defaultText,
        function(text)
            p.msg = text
            if not p.msg or #p.msg == 0 then p.msg = "Trigger activated!" end
            EventTrigger.PromptOutput2()
        end,
        function() EventTrigger._pending = nil end,
        function() EventTrigger.PromptMaxTriggers() end)
    modal:initialise()
    modal:addToUIManager()
end

-- 第 5 步：选择输出模式（基于按钮）
function EventTrigger.PromptOutput2()
    local p = EventTrigger._pending
    local modal = EventTriggerChoicePrompt:new(
        getText("UI_ET_Wiz_Output"),
        getText("UI_ET_Wiz_OutputHint"),
        EventTrigger.OUTPUT_CHOICES,
        p.outputType or EventTrigger.OutputType.SAY,
        function(value)
            p.outputType = value
            if value == EventTrigger.OutputType.NAMED or value == EventTrigger.OutputType.BROADCAST then
                EventTrigger.PromptOutputName2()
            else
                EventTrigger.PromptCooldown2()
            end
        end,
        function() EventTrigger._pending = nil end,
        function() EventTrigger.PromptMessage2() end)
    modal:initialise()
    modal:addToUIManager()
end

-- 第 5b 步（仅具名模式）：输入显示名称
function EventTrigger.PromptOutputName2()
    local p = EventTrigger._pending
    local cfg = EventTrigger.GetConfig()
    local current = p.outputName
    if not current or #current == 0 then current = cfg.outputName end
    local modal = EventTriggerTextPrompt:new(
        getText("UI_ET_Wiz_Named"),
        getText("UI_ET_Wiz_NamedHint"),
        current,
        function(text)
            p.outputName = text or ""
            EventTrigger.PromptCooldown2()
        end,
        function() EventTrigger._pending = nil end,
        function() EventTrigger.PromptOutput2() end)
    modal:initialise()
    modal:addToUIManager()
end

-- 第 6 步：冷却（无 / 真实时钟 / 游戏时钟 + 时长）
function EventTrigger.PromptCooldown2()
    local p = EventTrigger._pending
    local modal = EventTriggerCooldownPrompt:new(
        p.cooldown or { mode = EventTrigger.COOLDOWN_NONE },
        function(cd)
            p.cooldown = cd
            EventTrigger.PlacePending()
        end,
        function() EventTrigger._pending = nil end,
        function()
            if p.outputType == EventTrigger.OutputType.NAMED or p.outputType == EventTrigger.OutputType.BROADCAST then
                EventTrigger.PromptOutputName2()
            else
                EventTrigger.PromptOutput2()
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- 完成放置：收集全部参数到 args 表，调用 SendCommand
function EventTrigger.PlacePending()
    local p = EventTrigger._pending
    if not p then
        dbg("PlacePending: no pending data, aborting")
        return
    end
    local args = {
        x = p.x, y = p.y, z = p.z,
        delay = p.delay, message = p.msg, range = p.range,
        outputType = p.outputType, maxTriggers = p.maxTriggers,
        outputName = p.outputName or "",
        cooldown = p.cooldown or { mode = EventTrigger.COOLDOWN_NONE },
        creator = EventTrigger.GetCurrentPlayerId(),
    }
    dbg("PlacePending: placing trigger at (", p.x, p.y, p.z, "), msg=", p.msg, "delay=", p.delay, "range=", p.range)
    EventTrigger.SendCommand("placeTrigger", args)
    EventTrigger._pending = nil
end

-- UI 快捷方式：删除指定索引的触发器
function EventTrigger.DeleteTrigger(index)
    local t = EventTrigger.triggers[index]
    EventTrigger.SendCommand("deleteTrigger", { index = index, id = t and t.id })
end

-- UI 快捷方式：重置指定索引触发器的触发计数
function EventTrigger.ResetTrigger(index)
    local t = EventTrigger.triggers[index]
    EventTrigger.SendCommand("resetTrigger", { index = index, id = t and t.id })
end

-- UI 快捷方式：删除全部触发器（all=true 删全部，否则仅删自己的）
function EventTrigger.DeleteAllTriggers(all)
    EventTrigger.SendCommand("deleteAllTriggers", { all = all })
end

-- UI 快捷方式：切换触发器的启用/禁用状态
function EventTrigger.ToggleTrigger(index)
    local t = EventTrigger.triggers[index]
    EventTrigger.SendCommand("toggleTrigger", {
        index = index,
        id = t and t.id,
        enabled = not (t.enabled ~= false),
    })
end

-- UI 快捷方式：禁用全部触发器 + 交付点
function EventTrigger.DisableAll()
    EventTrigger.SendCommand("disableAll", { all = true })
end

-- ============================================================
-- 编辑向导（ISTextBox 多步输入）
-- 第 1 步：编辑消息文本
-- ============================================================
function EventTrigger.PromptEditMessage(index)
    EventTrigger._editIndex = index
    local t = EventTrigger.triggers[index]
    if not t then return end
    local modal = EventTriggerTextPrompt:new(
        getText("UI_ET_Edit_Message"),
        getText("UI_ET_Wiz_MessageHint"),
        t.message,
        function(text)
            EventTrigger.SendCommand("editTriggerMessage", {
                index = EventTrigger._editIndex,
                id = t and t.id,
                message = text,
            })
            EventTrigger.PromptEditDelay()
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- 第 2 步：编辑延迟
function EventTrigger.PromptEditDelay()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Edit_Delay"),
        getText("UI_ET_Wiz_DelayHint"),
        tostring(t.delay or 3),
        function(num)
            EventTrigger.SendCommand("editTriggerParams", { index = idx, id = t.id, delay = num })
            EventTrigger.PromptEditRange()
        end,
        nil,
        function() EventTrigger.PromptEditMessage(idx) end,
        { integer = true, min = 0, max = 3600 })
    modal:initialise()
    modal:addToUIManager()
end

-- 第 3 步：编辑范围
function EventTrigger.PromptEditRange()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Edit_Range"),
        getText("UI_ET_Wiz_RangeHint"),
        tostring(t.range or 2),
        function(num)
            EventTrigger.SendCommand("editTriggerParams", { index = idx, id = t.id, range = num })
            EventTrigger.PromptEditMaxTriggers()
        end,
        nil,
        function() EventTrigger.PromptEditDelay() end,
        { min = 0.5 })
    modal:initialise()
    modal:addToUIManager()
end

-- 第 4 步：编辑最大触发次数
function EventTrigger.PromptEditMaxTriggers()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Edit_MaxTriggers"),
        getText("UI_ET_Wiz_MaxTriggersHint"),
        tostring(t.maxTriggers or -1),
        function(num)
            if num == 0 then num = -1 end
            EventTrigger.SendCommand("editTriggerParams", { index = idx, id = t.id, maxTriggers = num })
            EventTrigger.PromptEditOutput()
        end,
        nil,
        function() EventTrigger.PromptEditRange() end,
        { integer = true, min = -1 })
    modal:initialise()
    modal:addToUIManager()
end

-- 第 5 步：编辑输出模式（基于按钮）
function EventTrigger.PromptEditOutput()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local ot = t.outputType or EventTrigger.OutputType.HALO
    local modal = EventTriggerChoicePrompt:new(
        getText("UI_ET_Edit_Output"),
        getText("UI_ET_Wiz_OutputHint"),
        EventTrigger.OUTPUT_CHOICES,
        ot,
        function(value)
            EventTrigger.SendCommand("editTriggerOutput", { index = idx, id = t.id, outputType = value })
            if value == EventTrigger.OutputType.NAMED or value == EventTrigger.OutputType.BROADCAST then
                EventTrigger.PromptEditOutputName()
            else
                EventTrigger.PromptEditCooldown()
            end
        end,
        nil,
        function() EventTrigger.PromptEditMaxTriggers() end)
    modal:initialise()
    modal:addToUIManager()
end

-- 第 5b 步（仅具名模式）
function EventTrigger.PromptEditOutputName()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local cfg = EventTrigger.GetConfig()
    local current = t.outputName
    if not current or #current == 0 then current = cfg.outputName end
    local modal = EventTriggerTextPrompt:new(
        getText("UI_ET_Wiz_Named"),
        getText("UI_ET_Wiz_NamedHint"),
        current,
        function(text)
            EventTrigger.SendCommand("editTriggerOutput", {
                index = idx,
                id = t and t.id,
                outputName = (text and #text > 0) and text or "",
            })
            EventTrigger.PromptEditCooldown()
        end,
        nil,
        function() EventTrigger.PromptEditOutput() end)
    modal:initialise()
    modal:addToUIManager()
end

-- 第 6 步：编辑冷却
function EventTrigger.PromptEditCooldown()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local modal = EventTriggerCooldownPrompt:new(
        t.cooldown or { mode = EventTrigger.COOLDOWN_NONE },
        function(cd)
            EventTrigger.SendCommand("editTriggerParams", { index = idx, id = t.id, cooldown = cd })
            if EventTrigger._ui then EventTrigger._ui:refreshList() end
        end,
        nil,
        function()
            if t.outputType == EventTrigger.OutputType.NAMED or t.outputType == EventTrigger.OutputType.BROADCAST then
                EventTrigger.PromptEditOutputName()
            else
                EventTrigger.PromptEditOutput()
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- 打开触发器历史窗口
function EventTrigger.ShowHistory(index)
    if EventTrigger._hist then
        EventTrigger._hist:close()
    end
    EventTrigger._hist = EventTriggerHistoryUI:new(index)
    EventTrigger._hist:initialise()
    EventTrigger._hist:addToUIManager()
end

-- ============================================================
-- UI 布局系统：支持 XML 加载（media/ui/EventTriggerLayout.xml），
-- 加载失败时回退到硬编码布局
-- ============================================================

local LAYOUT = nil

-- 默认硬编码布局（XML 回退）
local function DefaultLayout()
    return {
        window = { x = 0, y = 0, w = 1020, h = 560 },
        titleBar = { height = 28 },
        close = { type = "button", x = 995, y = 4, w = 21, h = 21, text = "X" },
        title = { type = "label", x = 510, y = 7, w = 0, h = 0, text = "EventTrigger Manager", center = true },
        header = { y = 34, height = 18 },
        headerCols = {
            { name = "index",     x = 10,  w = 40,  text = "#" },
            { name = "position",  x = 54,  w = 150, text = "Position" },
            { name = "message",   x = 208, w = 250, text = "Message" },
            { name = "detail",    x = 462, w = 200, text = "Delay/Range/Output" },
            { name = "creator",   x = 666, w = 100, text = "Creator" },
            { name = "triggered", x = 770, w = 84,  text = "Triggered" },
            { name = "actions",   x = 858, w = 152, text = "Actions" },
        },
        list = { x = 10, y = 54, w = 1000, h = 440 },
        footer = { y = 505, height = 30 },
        add = { type = "button", x = 146, w = 110, h = 28, text = "Add Trigger" },
        addDelivery = { type = "button", x = 12, w = 126, h = 28, text = "Set Delivery Pt" },
        deleteAll = { type = "button", x = 264, w = 100, h = 28, text = "Delete All" },
        refresh = { type = "button", x = 372, w = 70, h = 28, text = "Refresh" },
        showAll = { type = "button", x = 450, w = 90, h = 28, text = "Show All" },
        row = { height = 30, buttonH = 22 },
        rowBtns = {
            edit = { w = 40, text = "Edit" },
            delete = { w = 24, text = "X" },
            reset = { w = 24, text = "R" },
            history = { w = 40, text = "Hist" },
        },
    }
end

-- 加载布局：DefaultLayout() 是唯一事实来源。
-- （XML 解析已移除，避免布局文件与代码不同步。）
local function LoadLayout()
    if LAYOUT then return LAYOUT end
    LAYOUT = DefaultLayout()
    return LAYOUT
end

-- ============================================================
-- EventTriggerUI — 主管理面板（派生自 ISPanel）
-- 展示触发器列表，支持分页、创建者筛选、编辑/删除/重置/历史操作
-- ============================================================
EventTriggerUI = ISPanel:derive("EventTriggerUI")

function EventTriggerUI:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerUI:create()
    local s = EventTrigger.US
    self:setAlwaysOnTop(true)

    if not EventTrigger.IsMultiplayer() then
        self.viewAll = true
    else
        self.viewAll = EventTrigger.IsAdmin()
    end

    self.rows = {}
    self.rowData = {}
    self.rowCount = 0
    self.altColors = { {0.15,0.15,0.15}, {0.11,0.11,0.11} }
    self.pageNum = 0

    -- 自适应布局（所有尺寸随 self.width/height 与 US 缩放）
    local titleH = 28
    self.headerY = titleH + 6
    self.listX = math.floor(10 * s)
    self.listY = self.headerY + math.floor(18 * s) + 6
    self.listW = self.width - self.listX * 2
    self.rowH = math.floor(30 * s)
    local btnH = math.floor(30 * s)
    self.footerY = self.height - btnH - 10
    self.listH = self.footerY - self.listY - 10
    self.cols = self:computeCols()

    -- 关闭按钮
    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self:refreshList()

    -- 底部按钮 — 使用每个按钮真实（自动扩展后）的宽度进行流式布局
    local gap = math.floor(10 * s)
    local fx = self.listX
    local function placeBtn(title, onclick)
        local btn = ISButton:new(fx, self.footerY, EventTrigger.btnW(title), btnH, title, self, onclick)
        btn:initialise()
        self:addChild(btn)
        fx = fx + btn.width + gap
        return btn
    end

    self.addDeliveryBtn = placeBtn(getText("UI_ET_Btn_SetDelivery"), EventTriggerUI.onAddDelivery)
    if not EventTrigger.DeliveryLoaded then
        self.addDeliveryBtn:setEnable(false)
        self.addDeliveryBtn:setTitle(getText("UI_ET_Btn_DeliveryUnavailable"))
    end
    self.addBtn = placeBtn(getText("UI_ET_Btn_AddTrigger"), EventTriggerUI.onAdd)
    self.disableAllBtn = placeBtn(getText("UI_ET_Btn_DisableAll"), EventTriggerUI.onDisableAll)
    self.delAllBtn = placeBtn(getText("UI_ET_Btn_DeleteAll"), EventTriggerUI.onDeleteAll)
    self.refreshBtn = placeBtn(getText("UI_ET_Btn_Refresh"), EventTriggerUI.onRefresh)
    self.showAllBtn = placeBtn(getText("UI_ET_Btn_ShowAll"), EventTriggerUI.onToggleView)
    self.showAllBtn:setVisible(EventTrigger.IsMultiplayer() and EventTrigger.IsAdmin())

    -- 分页按钮（底部右对齐，远离操作按钮）
    local pgX = self.width - 10 - 24 - 4 - 24
    self.prevPageBtn = ISButton:new(pgX, self.footerY, 24, btnH, "<", self, EventTriggerUI.onPrevPage)
    self.prevPageBtn:initialise()
    self:addChild(self.prevPageBtn)

    self.nextPageBtn = ISButton:new(pgX + 28, self.footerY, 24, btnH, ">", self, EventTriggerUI.onNextPage)
    self.nextPageBtn:initialise()
    self:addChild(self.nextPageBtn)

    self:updatePageButtons()
end

-- 列布局：按比例分配宽度，确保任意窗口尺寸下标题与行都对齐。
function EventTriggerUI:computeCols()
    local ratios = { 0.04, 0.15, 0.24, 0.20, 0.10, 0.08, 0.19 }
    local cols = {}
    local x = self.listX
    for i, r in ipairs(ratios) do
        local w = math.floor(self.listW * r)
        cols[i] = { x = x, w = w }
        x = x + w
    end
    return cols
end

-- 按创建者筛选触发器
-- 单机：显示全部；联机：根据 viewAll 标记决定显示全部或仅自己的
function EventTriggerUI:getFilteredTriggers()
    local all = EventTrigger.triggers
    local allDlv = EventTrigger.deliveryPoints or {}

    local function buildList()
        local list = {}
        -- 添加普通触发器
        for i, t in ipairs(all) do
            table.insert(list, { trigger = t, index = i })
        end
        -- 添加交付点（显示用索引在触发器之后偏移）
        for i, dp in ipairs(allDlv) do
            if dp and dp.type == "delivery" then
                table.insert(list, { trigger = dp, index = #all + i, _isDelivery = true, _dlvIndex = i })
            end
        end
        return list
    end

    -- 单机始终显示全部
    if not EventTrigger.IsMultiplayer() then
        return buildList()
    end

    -- 联机：显示全部或按创建者筛选
    if self.viewAll then
        return buildList()
    end

    local myId = EventTrigger.GetCurrentPlayerId()
    local filtered = {}
    for i, t in ipairs(all) do
        if t.creator == myId then
            table.insert(filtered, { trigger = t, index = i })
        end
    end
    for i, dp in ipairs(allDlv) do
        if dp and dp.type == "delivery" and dp.creator == myId then
            table.insert(filtered, { trigger = dp, index = #all + i, _isDelivery = true, _dlvIndex = i })
        end
    end
    return filtered
end

-- 计算每页行数
function EventTriggerUI:rowsPerPage()
    return math.max(1, math.floor(self.listH / self.rowH))
end

-- 计算总页数
function EventTriggerUI:totalPages()
    local list = self:getFilteredTriggers()
    return math.max(1, math.ceil(#list / self:rowsPerPage()))
end

-- 更新分页按钮的可见性和启用状态
function EventTriggerUI:updatePageButtons()
    if not self.prevPageBtn or not self.nextPageBtn then return end
    local list = self:getFilteredTriggers()
    local total = #list
    local rpp = self:rowsPerPage()
    local tp = self:totalPages()
    local hasPages = total > rpp
    self.prevPageBtn:setVisible(hasPages)
    self.nextPageBtn:setVisible(hasPages)
    self.prevPageBtn:setEnable(self.pageNum > 0)
    self.nextPageBtn:setEnable(self.pageNum < tp - 1)
end

-- 清除列表中的全部行控件
function EventTriggerUI:clearList()
    for _, child in ipairs(self.rows) do
        child:removeFromUIManager()
        if self.removeChild then self:removeChild(child) end
    end
    self.rows = {}
    self.rowData = {}
    self.rowCount = 0
end

-- 刷新列表内容（清空后重建当前页的行）
function EventTriggerUI:refreshList()
    self:clearList()

    local list = self:getFilteredTriggers()
    local total = #list
    local rpp = self:rowsPerPage()
    local tp = self:totalPages()
    if self.pageNum >= tp then self.pageNum = tp - 1 end

    local startIdx = self.pageNum * rpp + 1
    local endIdx = math.min(total, startIdx + rpp - 1)

    dbg("refreshList: filtered=", total, "visible=", (endIdx - startIdx + 1), "page=", self.pageNum + 1, "/", tp)

    for i = startIdx, endIdx do
        local entry = list[i]
        self:addRow(entry)
    end
    self:updatePageButtons()
end

-- 向列表添加一个触发器/交付点数据行（文本标签 + 操作按钮）
function EventTriggerUI:addRow(entry)
    local t = entry.trigger
    local index = entry.index
    local isDlv = entry._isDelivery
    local cols = self.cols or self:computeCols()
    local rowIdx = self.rowCount
    self.rowCount = self.rowCount + 1
    local y = self.listY + rowIdx * self.rowH

    local colIndex = cols[1]
    local colPos   = cols[2]
    local colMsg   = cols[3]
    local colDet   = cols[4]
    local colCreat = cols[5]
    local colTrig  = cols[6]
    local colActs  = cols[7]

    -- 行背景色：交付点使用独特的色调区分
    local bgColor = isDlv and {0.08, 0.06, 0.12} or {0.08, 0.08, 0.08}

    if isDlv then
        -- 交付点行
        local count = t.triggerCount or 0
        local completed = count > 0
        local reqCount = t.requiredItems and #t.requiredItems or 0
        local rewCount = t.rewardItems and #t.rewardItems or 0

        local F = UIFont.Small
        self.rowData[index] = {
            y = y,
            cols = {
                { x = colIndex.x + 4, w = colIndex.w,   text = "[D]" .. tostring(index) .. ".",  color = {0.8,0.5,1} },
                { x = colPos.x + 4,   w = colPos.w,    text = EventTrigger.fitText(string.format("(%d,%d,%d)", t.x, t.y, t.z), F, colPos.w - 12), color = {0.5,0.8,1} },
                { x = colMsg.x + 4,   w = colMsg.w,    text = EventTrigger.fitText(t.hintText or "DP", F, colMsg.w - 12), color = {0.8,0.8,1} },
                { x = colDet.x + 4,   w = colDet.w,    text = EventTrigger.fitText("R=" .. string.format("%.1f", t.range or 3) .. "  Req:" .. reqCount .. "  Rew:" .. rewCount, F, colDet.w - 12), color = {0.7,0.7,1} },
                { x = colCreat.x + 4, w = colCreat.w,  text = EventTrigger.fitText(t.creator or "?", F, colCreat.w - 12), color = {0.8,0.8,0.5} },
            },
            _isDelivery = true,
            _bgColor = bgColor,
        }

        local cntStr = completed and getText("UI_ET_Status_Done") or getText("UI_ET_Status_Ready")
        local cntColor = completed and {0.5,1,0.5} or {1,1,0.3}
        self.rowData[index].cols[#self.rowData[index].cols + 1] = {
            x = colTrig.x + 4, w = colTrig.w, text = EventTrigger.fitText(cntStr, F, colTrig.w - 12), color = cntColor,
        }
    else
        -- 普通触发器行
        local exhausted = t.maxTriggers > 0 and (t.triggerCount or 0) >= t.maxTriggers

        local F = UIFont.Small
        self.rowData[index] = {
            y = y,
            cols = {
                { x = colIndex.x + 4, w = colIndex.w,   text = tostring(index) .. ".",              color = {1,1,1} },
                { x = colPos.x + 4,   w = colPos.w,    text = EventTrigger.fitText(string.format("(%d,%d,%d)", t.x, t.y, t.z), F, colPos.w - 12), color = {0.5,0.8,1} },
                { x = colMsg.x + 4,   w = colMsg.w,    text = EventTrigger.fitText(t.message or "", F, colMsg.w - 12), color = {1,1,1} },
                { x = colDet.x + 4,   w = colDet.w,    text = EventTrigger.fitText(OutputTypeToName(t.outputType) .. "  D=" .. (t.delay or 3) .. " R=" .. string.format("%.1f", t.range or 2), F, colDet.w - 12), color = {0.7,0.7,1} },
                { x = colCreat.x + 4, w = colCreat.w,  text = EventTrigger.fitText(t.creator or "?", F, colCreat.w - 12), color = {0.8,0.8,0.5} },
            },
            _bgColor = bgColor,
        }
        local cntStr = "x" .. (t.triggerCount or 0)
        if exhausted then
            cntStr = cntStr .. " " .. getText("UI_ET_Status_Done")
        elseif t.maxTriggers > 0 then
            cntStr = cntStr .. "/" .. t.maxTriggers
        end
        local who = ""
        if t.triggeredBy and #t.triggeredBy > 0 then
            local last = t.triggeredBy[#t.triggeredBy]
            who = " " .. ((type(last) == "table") and (last.playerId or "") or tostring(last))
        end
        local cntColor = exhausted and {1,0.5,0.5} or {0.8,1,0.7}
        self.rowData[index].cols[#self.rowData[index].cols + 1] = {
            x = colTrig.x + 4, w = colTrig.w, text = EventTrigger.fitText(cntStr .. who, F, colTrig.w - 12), color = cntColor,
        }
    end

    -- 操作按钮 — 使用每个按钮真实（自动扩展后）的宽度进行流式布局
    local s = EventTrigger.US
    local btnH = math.floor(22 * s)
    local gap = math.floor(6 * s)
    local bx = colActs.x + 2
    local by = y + (self.rowH - btnH) / 2

    local function addActionBtn(title, handler)
        local btn = ISButton:new(bx, by, EventTrigger.btnW(title), btnH, title, self, handler)
        btn:initialise()
        btn.idx = index
        btn.entry = entry
        self:addChild(btn)
        table.insert(self.rows, btn)
        bx = bx + btn.width + gap
        return btn
    end

    local enabled = (t.enabled ~= false)
    addActionBtn(getText("UI_ET_Btn_Edit"), EventTriggerUI.onEditRow)
    addActionBtn("X", EventTriggerUI.onDeleteRow)
    addActionBtn(enabled and getText("UI_ET_Btn_Disable") or getText("UI_ET_Btn_Enable"), EventTriggerUI.onToggleRow)
    addActionBtn("R", EventTriggerUI.onResetRow)
    addActionBtn(getText("UI_ET_Btn_Hist"), EventTriggerUI.onHistoryRow)
end

-- 标题栏拖动：点击标题区域时开始拖动
function EventTriggerUI:onMouseDown(x, y)
    local titleH = 28
    if y >= 0 and y < titleH then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

-- 拖动移动窗口
function EventTriggerUI:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

-- 结束拖动
function EventTriggerUI:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

-- 按钮回调：编辑行触发器
function EventTriggerUI:onEditRow(btn)
    if btn.entry and btn.entry._isDelivery then
        -- 编辑交付点：在其坐标处重新打开设置向导
        local dp = btn.entry.trigger
        local dlvIdx = btn.entry._dlvIndex
        if dp and dlvIdx then
            EventTrigger.Delivery.EditDelivery(dlvIdx, dp)
        end
        return
    end
    local idx = btn.idx
    if not EventTrigger.triggers[idx] then return end
    EventTrigger.PromptEditMessage(idx)
end

-- 按钮回调：删除行触发器/交付点
function EventTriggerUI:onDeleteRow(btn)
    if btn.entry and btn.entry._isDelivery then
        local dp = btn.entry.trigger
        local dlvIdx = btn.entry._dlvIndex
        if dp and dlvIdx then
            EventTrigger.Delivery.DeleteDelivery(dlvIdx, dp)
        end
        return
    end
    EventTrigger.DeleteTrigger(btn.idx)
end

-- 按钮回调：重置行触发器的触发计数 / 交付点的完成状态
function EventTriggerUI:onResetRow(btn)
    if btn.entry and btn.entry._isDelivery then
        local dp = btn.entry.trigger
        local dlvIdx = btn.entry._dlvIndex
        if dp and dlvIdx then
            EventTrigger.Delivery.ResetDelivery(dlvIdx, dp)
        end
        return
    end
    EventTrigger.ResetTrigger(btn.idx)
end

-- 按钮回调：切换行触发器/交付点的启用状态
function EventTriggerUI:onToggleRow(btn)
    if btn.entry and btn.entry._isDelivery then
        local dp = btn.entry.trigger
        local dlvIdx = btn.entry._dlvIndex
        if dp and dlvIdx then
            EventTrigger.Delivery.ToggleDelivery(dlvIdx, dp)
        end
        return
    end
    EventTrigger.ToggleTrigger(btn.idx)
end

-- 按钮回调：查看行触发器历史 / 交付点详情
function EventTriggerUI:onHistoryRow(btn)
    if btn.entry and btn.entry._isDelivery then
        local dp = btn.entry.trigger
        if dp then
            EventTrigger.Delivery.ShowHistory(dp)
        end
        return
    end
    EventTrigger.ShowHistory(btn.idx)
end

-- 按钮回调：在当前位置添加新触发器（启动向导）
function EventTriggerUI:onAdd()
    local player = getPlayer()
    if not player then
        dbg("onAdd: no player, aborting")
        return
    end
    local x, y, z = player:getX(), player:getY(), player:getZ()
    dbg("onAdd: starting wizard at (", math.floor(x), math.floor(y), math.floor(z), ")")
    EventTrigger.PromptDelayRange(math.floor(x), math.floor(y), math.floor(z))
end

-- 按钮回调：删除全部触发器（admin+viewAll = 全部，否则仅自己的）
-- 需要输入 YES（大写）以确认此破坏性操作。
function EventTriggerUI:onDeleteAll()
    local modal = EventTriggerTextPrompt:new(
        getText("UI_ET_Btn_DeleteAll"),
        getText("UI_ET_DeleteAllConfirm"),
        "",
        function(text)
            if text == "YES" then
                EventTrigger.DeleteAllTriggers(EventTrigger.IsAdmin() and self.viewAll)
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- 按钮回调：禁用全部触发器 + 交付点
function EventTriggerUI:onDisableAll()
    EventTrigger.DisableAll()
end

-- 按钮回调：手动刷新列表
function EventTriggerUI:onRefresh()
    if EventTrigger.IsMultiplayer() then
        EventTrigger.RequestSync()
    else
        EventTrigger.RebuildList()
    end
    self:refreshList()
end

-- 按钮回调：切换"显示全部"/"显示我的"视图
function EventTriggerUI:onToggleView()
    self.viewAll = not self.viewAll
    self.showAllBtn:setTitle(self.viewAll and getText("UI_ET_Btn_ShowMine") or getText("UI_ET_Btn_ShowAll"))
    if EventTrigger.IsMultiplayer() then
        EventTrigger.RequestSync(true)
    end
    self.pageNum = 0
    self:refreshList()
end

-- 按钮回调：上一页
function EventTriggerUI:onPrevPage()
    if self.pageNum > 0 then
        self.pageNum = self.pageNum - 1
        self:refreshList()
    end
end

-- 按钮回调：下一页
function EventTriggerUI:onNextPage()
    if self.pageNum < self:totalPages() - 1 then
        self.pageNum = self.pageNum + 1
        self:refreshList()
    end
end

-- 关闭窗口回调
function EventTriggerUI:onClose()
    self:close()
end

-- 关闭窗口并从 UIManager 移除
function EventTriggerUI:close()
    if EventTrigger._ui == self then EventTrigger._ui = nil end
    self:setVisible(false)
    self:removeFromUIManager()
end

-- 每帧 UI 绘制（边框、标题、表头、背景、行数据、分页、模式指示）
function EventTriggerUI:prerender()
    ISPanel.prerender(self)

    local headerLabels = {
        getText("UI_ET_Col_Index"),
        getText("UI_ET_Col_Position"),
        getText("UI_ET_Col_Message"),
        getText("UI_ET_Col_Detail"),
        getText("UI_ET_Col_Creator"),
        getText("UI_ET_Col_Triggered"),
        getText("UI_ET_Col_Actions"),
    }
    local cols = self.cols or self:computeCols()

    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)

    self:drawTextCentre(getText("UI_ET_Mgr_Title"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    -- 表头分隔线
    local divY = self.listY - 4
    self:drawRect(self.listX, divY, self.listW, 1, 0.7, 0.4, 0.4, 0.4)

    for i, col in ipairs(cols) do
        local label = headerLabels[i] or ""
        self:drawText(EventTrigger.fitText(label, UIFont.Small, col.w - 4), col.x + 4, self.headerY + 1, 0.5, 0.5, 0.5, 1, UIFont.Small)
    end

    local list = self:getFilteredTriggers()
    local total = #list
    local rpp = self:rowsPerPage()
    local tp = self:totalPages()
    local startIdx = self.pageNum * rpp + 1
    local endIdx = math.min(total, startIdx + rpp - 1)
    local visRows = endIdx - startIdx + 1

    for r = 0, visRows - 1 do
        local rowY = self.listY + r * self.rowH
        local c = self.altColors[(r % 2) + 1]
        self:drawRect(self.listX, rowY, self.listW, self.rowH, 0.25, c[1], c[2], c[3])
    end

    for i = startIdx, endIdx do
        local entry = list[i]
        local rd = self.rowData[entry.index]
        if rd then
            local ty = rd.y + (self.rowH - 16) / 2
            for _, col in ipairs(rd.cols) do
                self:drawText(col.text, col.x, ty, col.color[1], col.color[2], col.color[3], 1, UIFont.Small)
            end
        end
    end

    -- 空列表提示
    if total == 0 then
        local txt = getText("UI_ET_EmptyList")
        self:drawTextCentre(txt, self.width / 2, self.listY + 20, 0.45, 0.45, 0.45, 1, UIFont.Small)
    end

    -- 分页指示（位于底部按钮上方）
    if total > rpp then
        local pgText = getText("UI_ET_Page", self.pageNum + 1, tp)
        self:drawText(pgText, self.width - 130, self.footerY + 8, 0.6, 0.6, 0.6, 1, UIFont.Small)
    end

    -- 标题栏模式指示（左侧，避开关闭按钮）
    local modeText = EventTrigger.IsMultiplayer() and getText("UI_ET_Mode_Server") or getText("UI_ET_Mode_Local")
    self:drawText(modeText, 12, 8, 0.5, 0.5, 0.5, 1, UIFont.Small)
end

-- EventTriggerUI 构造函数：创建居中的主管理面板
function EventTriggerUI:new()
    local w = EventTrigger.fitW(1020)
    local h = EventTrigger.fitH(560)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.85 }
    o.width = w
    o.height = h
    o.dragging = false
    return o
end

-- ============================================================
-- EventTriggerHistoryUI — 触发器历史查看器（派生自 ISPanel）
-- 展示触发器信息与全部触发记录（谁在何时触发）
-- ============================================================
EventTriggerHistoryUI = ISPanel:derive("EventTriggerHistoryUI")

function EventTriggerHistoryUI:initialise()
    ISPanel.initialise(self)
    self:create()
end

-- 构建历史 UI：触发器摘要 + 触发记录列表
function EventTriggerHistoryUI:create()
    self:setAlwaysOnTop(true)

    self.lines = {}
    local y = 40
    local F = UIFont.Small
    local maxW = self.width - 28

    -- 关闭按钮
    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerHistoryUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    -- 查找触发器，若不存在则显示错误
    local t = EventTrigger.triggers[self.triggerIndex]
    if not t then
        self.lines[#self.lines + 1] = { x = 14, y = y, text = getText("UI_ET_Hist_TriggerNotFound"), color = {1,0.5,0.5} }
        return
    end

    -- 触发器信息 — 拆分为多行，避免长消息重叠
    self.lines[#self.lines + 1] = { x = 14, y = y, text = EventTrigger.fitText(getText("UI_ET_Hist_Position", t.x, t.y, t.z), F, maxW), color = {0.5,0.8,1} }
    y = y + 24
    self.lines[#self.lines + 1] = { x = 14, y = y, text = getText("UI_ET_Hist_Message", EventTrigger.fitText(t.message or "", F, maxW - 90)), color = {1,1,1} }
    y = y + 24
    self.lines[#self.lines + 1] = { x = 14, y = y, text = getText("UI_ET_Hist_Creator", EventTrigger.fitText(t.creator or "?", F, maxW - 90)), color = {0.8,0.8,0.5} }
    y = y + 28

    -- 触发历史列表
    local triggeredBy = t.triggeredBy or {}
    self.lines[#self.lines + 1] = { x = 14, y = y, text = getText("UI_ET_Hist_TotalTriggers", #triggeredBy), color = {1,1,1} }
    y = y + 24

    if #triggeredBy == 0 then
        self.lines[#self.lines + 1] = { x = 14, y = y, text = getText("UI_ET_Hist_NoTriggers"), color = {0.5,0.5,0.5} }
    else
        -- 显示每条触发历史记录
        for i, entry in ipairs(triggeredBy) do
            local pId, tStr
            if type(entry) == "table" then
                pId = entry.playerId or "Unknown"
                tStr = entry.timeStr or ""
            else
                pId = tostring(entry)
                tStr = ""
            end
            local line = string.format("%d. %s", i, pId)
            if tStr and #tStr > 0 then
                line = line .. "  [" .. tStr .. "]"
            end
            self.lines[#self.lines + 1] = { x = 22, y = y, text = EventTrigger.fitText(line, F, maxW), color = {0.8,0.9,1} }
            y = y + 24
            if y > self.height - 30 then break end
        end
    end
end

-- 关闭历史窗口
function EventTriggerHistoryUI:onClose()
    self:close()
end

-- 从 UIManager 移除
function EventTriggerHistoryUI:close()
    if EventTrigger._hist == self then EventTrigger._hist = nil end
    self:setVisible(false)
    self:removeFromUIManager()
end

-- 标题栏拖动
function EventTriggerHistoryUI:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

-- 拖动移动
function EventTriggerHistoryUI:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

-- 结束拖动
function EventTriggerHistoryUI:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

-- 每帧历史窗口绘制（边框、标题栏、触发记录文本）
function EventTriggerHistoryUI:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)

    local titleStr = getText("UI_ET_Hist_TriggerTitle", self.triggerIndex)
    self:drawTextCentre(titleStr, self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    for _, line in ipairs(self.lines) do
        self:drawText(line.text, line.x, line.y, line.color[1], line.color[2], line.color[3], 1, UIFont.Small)
    end
end

-- EventTriggerHistoryUI 构造函数
function EventTriggerHistoryUI:new(index)
    local w = EventTrigger.fitW(560)
    local h = EventTrigger.fitH(460)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.width = w
    o.height = h
    o.triggerIndex = index
    o.dragging = false
    return o
end

-- ============================================================
-- EventTriggerUI 交付集成（委派给 EventTriggerDelivery）
-- ============================================================
function EventTriggerUI:onAddDelivery()
    if not EventTrigger.DeliveryLoaded then
        dbg("onAddDelivery: delivery module not loaded, ignoring")
        return
    end
    local player = getPlayer()
    if not player then return end
    local x, y, z = player:getX(), player:getY(), player:getZ()
    EventTrigger.Delivery.StartSetup(math.floor(x), math.floor(y), math.floor(z))
end

-- ============================================================
-- 事件注册：将核心函数绑定到 PZ 游戏事件
-- 加载顺序：OnGameStart → OnTick（每帧）→ 右键菜单 → 服务器指令
-- ============================================================
Events.OnTick.Add(EventTrigger.OnTick)
Events.OnFillWorldObjectContextMenu.Add(EventTrigger.OnFillWorldObjectContextMenu)
Events.OnServerCommand.Add(EventTrigger.OnServerCommand)

-- 首帧自动请求同步（BulletinBoard 模式，无 OnGameStart）
-- 在加入服务器和重连时触发
local _etFirstTickDone = false
local function onFirstTick()
    if _etFirstTickDone then return end
    _etFirstTickDone = true
    EventTrigger.Load()
    Events.OnTick.Remove(onFirstTick)
end
Events.OnTick.Add(onFirstTick)
