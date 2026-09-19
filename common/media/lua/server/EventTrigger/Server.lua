-- ============================================================
-- EventTrigger/Server.lua — DS 服务器端（B42 回退路径）
-- ============================================================

EventTriggerServer_loaded = true
print("[EventTrigger-SERVER] loaded: common/media/lua/server/EventTrigger/Server.lua")

local Shared = require("EventTrigger/Shared")
local Persistence = require("EventTrigger/Persistence")
local Logger = require("ElyonLib/Core/Logger"):new("EventTrigger", "1.0")

local MODULE = Shared.MODULE
local Server = {}

-- ==================== 触发器存储（JSON 文件替代 ModData） ====================
Server.triggers = {}
Server.deliveryPoints = {}

-- 从 JSON 文件加载全部触发器
local function loadTriggers()
    Server.triggers = Persistence.loadTriggers()
    Logger:info("Loaded %d triggers from JSON files.", #Server.triggers)
end

-- 从 JSON 文件加载全部交付点
local function loadDeliveryPoints()
    Server.deliveryPoints = Persistence.loadDeliveryPoints()
    Logger:info("Loaded %d delivery points from JSON files.", #Server.deliveryPoints)
end

-- 将全部触发器保存到 JSON 文件（全量保存）
local function saveTriggers()
    Persistence.saveTriggers(Server.triggers)
    Logger:info("Saved %d triggers.", #Server.triggers)
end

-- 增量保存单个触发器
local function saveOneTrigger(trigger)
    Persistence.saveOneTrigger(trigger)
end

-- 删除单个触发器文件及其历史记录文件
local function deleteOneTriggerFile(triggerId)
    Persistence.deleteOneTrigger(triggerId)
    Persistence.deleteHistory(triggerId)
end

-- ==================== 工具函数 ====================

-- 判断玩家是否为管理员
local function isAdmin(player)
    return player and player:getAccessLevel() == "admin"
end

-- 获取玩家唯一标识（用户名）
local function getPlayerId(player)
    return player and player:getUsername() or "unknown"
end

-- 在服务器触发器列表中按 ID 查找索引
local function findById(id)
    for i, t in ipairs(Server.triggers) do
        if t.id == id then return i end
    end
    return nil
end

-- 判断玩家是否有权修改目标触发器（创建者或管理员）
local function canModify(player, trigger)
    return isAdmin(player) or trigger.creator == getPlayerId(player)
end

-- 在交付点列表中按 ID 查找索引
local function findDeliveryById(id)
    for i, dp in ipairs(Server.deliveryPoints) do
        if dp.id == id then return i end
    end
    return nil
end

-- ==================== 状态同步与广播 ====================

-- 构造可序列化的触发器副本（附带历史记录，剔除仅服务器端使用的字段）
local function makeSerializable(t)
    local copy = {}
    for k, v in pairs(t) do
        -- inRangePlayers 仅用于服务器内部距离判定，无需下发给客户端
        if k ~= "inRangePlayers" then
            copy[k] = v
        end
    end
    copy.triggeredBy = Persistence.loadHistory(t.id)
    return copy
end

-- 批量构造可序列化的触发器列表
local function makeSerializableList(triggers)
    local list = {}
    for _, t in ipairs(triggers) do
        list[#list + 1] = makeSerializable(t)
    end
    return list
end

-- 向指定玩家下发完整状态（触发器 + 历史 + 交付点）
local function sendState(player)
    local list = makeSerializableList(Server.triggers)
    local dlvList = {}
    for _, dp in ipairs(Server.deliveryPoints) do
        dlvList[#dlvList + 1] = dp
    end
    Logger:info("SendState: sending %d triggers + %d delivery points to %s", #list, #dlvList, getPlayerId(player))
    sendServerCommand(player, MODULE, Shared.COMMANDS.SYNC_STATE, { triggers = list, deliveryPoints = dlvList })
end

-- 向所有在线客户端广播完整状态
local function broadcastAll()
    local list = makeSerializableList(Server.triggers)
    local dlvList = {}
    for _, dp in ipairs(Server.deliveryPoints) do
        dlvList[#dlvList + 1] = dp
    end
    Logger:info("BroadcastAll: broadcasting %d triggers + %d delivery points to all clients", #list, #dlvList)
    sendServerCommand(MODULE, Shared.COMMANDS.SYNC_STATE, { triggers = list, deliveryPoints = dlvList })
end

-- ==================== 旧数据迁移 ====================

-- 将旧版 ModData 中的触发器一次性迁移到 JSON 文件
-- 迁移完成后清空 ModData，避免重复迁移
local function migrateFromModData()
    local data = ModData.getOrCreate("EventTrigger")
    if not data.triggers or #data.triggers == 0 then return end
    Logger:info("Migrating %d triggers from ModData to JSON files...", #data.triggers)
    local migrated = 0
    for _, t in ipairs(data.triggers) do
        if t.message and t.x then
            local trigger = Shared.makeTrigger({
                id = t.id,
                x = t.x, y = t.y, z = t.z or 0,
                message = t.message,
                delay = t.delay,
                range = t.range,
                outputType = t.outputType,
                outputName = t.outputName,
                maxTriggers = t.maxTriggers,
                triggerCount = t.triggerCount or 0,
                creator = t.creator or "unknown",
            })
            Server.triggers[#Server.triggers + 1] = trigger
            -- 历史记录单独存放到独立 JSON 文件
            if t.triggeredBy and #t.triggeredBy > 0 then
                Persistence.saveHistory(trigger.id, t.triggeredBy)
            end
            migrated = migrated + 1
        end
    end
    if migrated > 0 then
        saveTriggers()
        -- 清空 ModData，防止下次启动重复迁移
        data.triggers = {}
    end
    Logger:info("Migration complete: %d triggers migrated to JSON.", migrated)
end

-- ==================== 指令处理 ====================

Server.onClientCommand = function(module, command, player, args)
    if module ~= MODULE then return end

    local pid = getPlayerId(player)
    Logger:info("cmd=%s player=%s", command, pid)

    -- ---------- 请求同步 ----------
    if command == Shared.COMMANDS.REQUEST_SYNC then
        sendState(player)
        return
    end

    -- ---------- 创建触发器 ----------
    if command == Shared.COMMANDS.PLACE_TRIGGER then
        local trigger = Shared.makeTrigger({
            id          = args.id,
            x           = args.x,
            y           = args.y,
            z           = args.z,
            message     = args.message,
            delay       = args.delay,
            range       = args.range,
            outputType  = args.outputType,
            outputName  = args.outputName,
            maxTriggers = args.maxTriggers,
            cooldown    = args.cooldown,
            creator     = pid,
        })
        Server.triggers[#Server.triggers + 1] = trigger
        saveOneTrigger(trigger)
        Logger:info("Trigger created: id=%s pos=(%d,%d,%d)", trigger.id, trigger.x, trigger.y, trigger.z)
        broadcastAll()
        return
    end

    -- ---------- 删除触发器 ----------
    if command == Shared.COMMANDS.DELETE_TRIGGER then
        local idx = findById(args.id)
        -- 兼容旧版客户端：允许通过 index 定位
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            local t = Server.triggers[idx]
            deleteOneTriggerFile(t.id)
            table.remove(Server.triggers, idx)
            Logger:info("Trigger deleted: id=%s by %s", t.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 重置触发器计数 ----------
    if command == Shared.COMMANDS.RESET_TRIGGER then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            local t = Server.triggers[idx]
            t.triggerCount = 0
            t.lastTriggerAt = nil
            saveOneTrigger(t)
            -- 清空历史记录文件（写入空列表）
            Persistence.saveHistory(t.id, {})
            Logger:info("Trigger reset: id=%s by %s", t.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 删除全部触发器 ----------
    if command == Shared.COMMANDS.DELETE_ALL then
        if isAdmin(player) and args.all then
            -- 管理员全删
            for _, t in ipairs(Server.triggers) do
                deleteOneTriggerFile(t.id)
            end
            Server.triggers = {}
        else
            -- 普通玩家仅能删除自己创建的
            local new = {}
            for _, t in ipairs(Server.triggers) do
                if t.creator == pid then
                    deleteOneTriggerFile(t.id)
                else
                    new[#new + 1] = t
                end
            end
            Server.triggers = new
        end
        saveTriggers()
        Logger:info("DeleteAll by %s, remaining: %d", pid, #Server.triggers)
        broadcastAll()
        return
    end

    -- ---------- 编辑消息内容 ----------
    if command == Shared.COMMANDS.EDIT_MESSAGE then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            -- 长度上限 500 字符，防止过长消息影响网络传输与 UI
            Server.triggers[idx].message = tostring(args.message or ""):sub(1, 500)
            saveOneTrigger(Server.triggers[idx])
            Logger:info("Trigger message edited: id=%s by %s", Server.triggers[idx].id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 编辑参数（延迟 / 范围 / 最大触发次数 / 冷却） ----------
    if command == Shared.COMMANDS.EDIT_PARAMS then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            local t = Server.triggers[idx]
            -- 延迟：>= 0
            if args.delay ~= nil then t.delay = math.max(0, args.delay) end
            -- 范围：至少 0.5 格，避免产生空范围
            if args.range ~= nil then t.range = math.max(0.5, args.range) end
            if args.maxTriggers ~= nil then t.maxTriggers = args.maxTriggers end
            if args.cooldown ~= nil then t.cooldown = Shared.makeCooldown(args.cooldown) end
            saveOneTrigger(t)
            Logger:info("Trigger params edited: id=%s by %s", t.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 编辑输出类型 / 名称 ----------
    if command == Shared.COMMANDS.EDIT_OUTPUT then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            local t = Server.triggers[idx]
            if args.outputType ~= nil then t.outputType = args.outputType end
            -- 输出名称长度上限 100 字符
            if args.outputName ~= nil then t.outputName = tostring(args.outputName or ""):sub(1, 100) end
            saveOneTrigger(t)
            Logger:info("Trigger output edited: id=%s by %s", t.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 启用 / 禁用触发器 ----------
    if command == Shared.COMMANDS.TOGGLE_TRIGGER then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            local t = Server.triggers[idx]
            if args.enabled ~= nil then t.enabled = args.enabled and true or false end
            saveOneTrigger(t)
            Logger:info("Trigger toggled: id=%s enabled=%s by %s", t.id, tostring(t.enabled), pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 一键禁用全部触发器与交付点（仅管理员） ----------
    if command == Shared.COMMANDS.DISABLE_ALL then
        if isAdmin(player) then
            for _, t in ipairs(Server.triggers) do t.enabled = false end
            for _, dp in ipairs(Server.deliveryPoints) do dp.enabled = false end
            saveTriggers()
            Persistence.saveDeliveryPoints(Server.deliveryPoints)
            Logger:info("DisableAll by %s", pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 记录触发（客户端上报玩家进入范围） ----------
    if command == Shared.COMMANDS.RECORD_TRIGGER then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx then
            local t = Server.triggers[idx]
            -- 已达到最大触发次数上限则忽略
            if t.maxTriggers > 0 and t.triggerCount >= t.maxTriggers then
                return
            end
            -- 全局冷却检测（基于触发器自身）
            local cd = t.cooldown or {}
            if not Shared.isCooldownZero(cd) and t.lastTriggerAt then
                local now = Shared.cooldownNowSeconds(cd.mode)
                if (now - t.lastTriggerAt) < Shared.cooldownDurationSeconds(cd) then
                    return  -- 仍在冷却中
                end
            end
            t.triggerCount = (t.triggerCount or 0) + 1
            if not Shared.isCooldownZero(cd) then
                t.lastTriggerAt = Shared.cooldownNowSeconds(cd.mode)
            end
            saveOneTrigger(t)
            -- 追加一条历史记录到独立 JSON 文件
            local entry = Shared.makeHistoryEntry(
                args.playerId or pid,
                args.timestamp or os.time(),
                args.timeStr or ""
            )
            Persistence.appendHistory(t.id, entry)
            Logger:info("Trigger recorded: id=%s count=%d by %s", t.id, t.triggerCount, pid)
            -- 此处不广播，减少网络开销；下次同步时客户端会自动更新
        end
        return
    end

    -- ---------- NAMED 模式消息广播 ----------
    if command == Shared.COMMANDS.NAMED_MESSAGE then
        Logger:info("NamedMessage: broadcasting")
        sendServerCommand(MODULE, Shared.COMMANDS.NAMED_MESSAGE, {
            message    = args.message or "",
            outputName = args.outputName or "System",
        })
        return
    end

    -- ==================== 交付点指令 ====================

    -- ---------- 创建交付点 ----------
    if command == Shared.COMMANDS.PLACE_DELIVERY then
        local dp = Shared.makeDeliveryPoint({
            id            = args.id,
            x             = args.x,
            y             = args.y,
            z             = args.z,
            hintText      = args.hintText,
            range         = args.range,
            maxPlayers    = args.maxPlayers or -1,
            maxPerPlayer  = args.maxPerPlayer or -1,
            requiredItems = args.requiredItems or {},
            rewardItems   = args.rewardItems or {},
            matchMode     = args.matchMode or "all",
            branches      = args.branches or {},
            cooldown      = args.cooldown,
            playerDeliveries = {},   -- 每个玩家的累计交付次数
            playerCooldowns = {},    -- 每个玩家的冷却时间戳
            creator       = pid,
            triggerCount  = 0,
            triggeredBy   = {},
        })
        Server.deliveryPoints[#Server.deliveryPoints + 1] = dp
        Persistence.saveOneDeliveryPoint(dp)
        Logger:info("Delivery point created: id=%s pos=(%d,%d,%d) hint=%s", dp.id, dp.x, dp.y, dp.z, dp.hintText)
        broadcastAll()
        return
    end

    -- ---------- 删除交付点 ----------
    if command == Shared.COMMANDS.DELETE_DELIVERY then
        local idx = findDeliveryById(args.id)
        if idx and canModify(player, Server.deliveryPoints[idx]) then
            local dp = Server.deliveryPoints[idx]
            Persistence.deleteOneDeliveryPoint(dp.id)
            table.remove(Server.deliveryPoints, idx)
            Logger:info("Delivery point deleted: id=%s by %s", dp.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- 删除全部交付点 ----------
    if command == Shared.COMMANDS.DELETE_ALL_DELIVERY then
        if isAdmin(player) and args.all then
            -- 管理员全删
            for _, dp in ipairs(Server.deliveryPoints) do
                Persistence.deleteOneDeliveryPoint(dp.id)
            end
            Server.deliveryPoints = {}
        else
            -- 普通玩家仅能删除自己创建的
            local new = {}
            for _, dp in ipairs(Server.deliveryPoints) do
                if dp.creator == pid then
                    Persistence.deleteOneDeliveryPoint(dp.id)
                else
                    new[#new + 1] = dp
                end
            end
            Server.deliveryPoints = new
        end
        Persistence.saveDeliveryPoints(Server.deliveryPoints)
        Logger:info("DeleteAllDelivery by %s, remaining: %d", pid, #Server.deliveryPoints)
        broadcastAll()
        return
    end

    -- ---------- 编辑交付点 ----------
    if command == Shared.COMMANDS.EDIT_DELIVERY then
        local dpIdx = findDeliveryById(args.id)
        if dpIdx then
            local dp = Server.deliveryPoints[dpIdx]
            if canModify(player, dp) then
                -- 提示文本长度上限 500 字符
                if args.hintText ~= nil then dp.hintText = tostring(args.hintText):sub(1, 500) end
                -- 范围至少 0.5 格
                if args.range ~= nil then dp.range = math.max(0.5, args.range) end
                -- -1 表示无限制
                if args.maxPlayers ~= nil then dp.maxPlayers = math.max(-1, args.maxPlayers) end
                if args.maxPerPlayer ~= nil then dp.maxPerPlayer = math.max(-1, args.maxPerPlayer) end
                if args.requiredItems ~= nil then dp.requiredItems = args.requiredItems end
                if args.rewardItems ~= nil then dp.rewardItems = args.rewardItems end
                if args.branches ~= nil then dp.branches = args.branches end
                if args.matchMode ~= nil then dp.matchMode = args.matchMode end
                if args.cooldown ~= nil then dp.cooldown = Shared.makeCooldown(args.cooldown) end
                Persistence.saveOneDeliveryPoint(dp)
                Logger:info("Delivery edited: id=%s by %s", dp.id, pid)
                broadcastAll()
            end
        end
        return
    end

    -- ---------- 重置交付点 ----------
    if command == Shared.COMMANDS.RESET_DELIVERY then
        local dpIdx = findDeliveryById(args.id)
        if dpIdx then
            local dp = Server.deliveryPoints[dpIdx]
            if canModify(player, dp) then
                dp.triggerCount = 0
                dp.triggeredBy = {}
                dp.playerDeliveries = {}
                dp.playerCooldowns = {}
                Persistence.saveOneDeliveryPoint(dp)
                Logger:info("Delivery reset: id=%s by %s", dp.id, pid)
                broadcastAll()
            end
        end
        return
    end

    -- ---------- 启用 / 禁用交付点 ----------
    if command == Shared.COMMANDS.TOGGLE_DELIVERY then
        local dpIdx = findDeliveryById(args.id)
        if dpIdx then
            local dp = Server.deliveryPoints[dpIdx]
            if canModify(player, dp) then
                if args.enabled ~= nil then dp.enabled = args.enabled and true or false end
                Persistence.saveOneDeliveryPoint(dp)
                Logger:info("Delivery toggled: id=%s enabled=%s by %s", dp.id, tostring(dp.enabled), pid)
                broadcastAll()
            end
        end
        return
    end

    -- ---------- 请求交付信息（客户端已预先校验背包） ----------
    if command == Shared.COMMANDS.REQUEST_DELIVERY then
        local dpIdx = findDeliveryById(args.id)
        if not dpIdx then
            Logger:info("RequestDelivery: delivery point %s not found", tostring(args.id))
            return
        end
        local dp = Server.deliveryPoints[dpIdx]
        -- 将交付详情回传客户端用于 UI 展示
        Logger:info("RequestDelivery: id=%s player=%s", dp.id, pid)
        sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
            action    = "showConfirm",
            dpId      = dp.id,
            hintText  = dp.hintText,
            requiredItems = dp.requiredItems,
            rewardItems   = dp.rewardItems,
        })
        return
    end

    -- ---------- 确认交付（支持批量、原子化处理） ----------
    if command == Shared.COMMANDS.CONFIRM_DELIVERY then
        local dpIdx = findDeliveryById(args.id)
        if not dpIdx then
            sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                action = "failed", reason = "Delivery point not found.",
            })
            return
        end
        local dp = Server.deliveryPoints[dpIdx]
        local inv = player:getInventory()
        if not inv then
            sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                action = "failed", reason = "Inventory not available.",
            })
            return
        end

        local pid = getPlayerId(player)
        local cooldown = dp.cooldown or {}
        local selectedORIndex = args.selectedORIndex

        -- 解析有效的兑换方案（资格门槛 + 消耗 + 奖励）
        local qualifyItems, costs, rewards, branchErr = Shared.resolveExchange(dp, args.branchId, args.costOptionIndex)
        if branchErr then
            sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                action = "failed", reason = branchErr,
            })
            return
        end
        -- 兼容旧版 ANY 模式：仅保留玩家选中的那一项消耗
        if #(dp.branches or {}) == 0 and (dp.matchMode or "all") == "any" then
            local targetIdx = selectedORIndex or 1
            costs = {}
            local idx = 0
            for _, req in ipairs(dp.requiredItems or {}) do
                idx = idx + 1
                if idx == targetIdx and req.collect ~= false then
                    costs[1] = { fullType = req.fullType, displayName = req.displayName, count = req.count }
                    break
                end
            end
        end

        -- 批量次数 N：正整数，默认 1，上限 1000 防刷
        local batchCount = tonumber(args.batchCount) or 1
        batchCount = math.floor(batchCount)
        if batchCount < 1 then batchCount = 1 end
        if batchCount > 1000 then batchCount = 1000 end

        -- 冷却校验（在触碰背包之前先判断，避免误扣物品）
        if not Shared.isCooldownZero(cooldown) then
            dp.playerCooldowns = dp.playerCooldowns or {}
            local lastDelivery = dp.playerCooldowns[pid]
            if lastDelivery then
                local now = Shared.cooldownNowSeconds(cooldown.mode)
                local total = Shared.cooldownDurationSeconds(cooldown)
                if (now - lastDelivery) < total then
                    sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                        action = "failed", reason = "Cooldown active! " .. Shared.formatCooldown(cooldown),
                    })
                    return
                end
            end
        end

        -- 上限校验：batch 一并计入单玩家 / 全局限制
        if not dp.playerDeliveries then dp.playerDeliveries = {} end
        local myCount = dp.playerDeliveries[pid] or 0
        local maxPP = dp.maxPerPlayer or -1
        if maxPP ~= -1 and myCount + batchCount > maxPP then
            sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                action = "failed", reason = "Exchange limit reached.",
            })
            return
        end
        local maxP = dp.maxPlayers or -1
        -- 只有玩家首次兑换时才需要检查全局唯一玩家数
        if maxP ~= -1 and myCount == 0 then
            local uniquePlayers = 0
            for _ in pairs(dp.playerDeliveries) do uniquePlayers = uniquePlayers + 1 end
            if uniquePlayers >= maxP then
                sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                    action = "failed", reason = "Exchange limit reached.",
                })
                return
            end
        end

        local items = inv:getItems()
        -- 判断背包物品是否匹配目标消耗项
        local function matchesCost(it, cost)
            if not it then return false end
            return it:getFullType() == cost.fullType
        end
        -- 统计背包中匹配指定消耗项的物品数量
        local function countOwned(cost)
            local n = 0
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                if it and inv:contains(it) and matchesCost(it, cost) then
                    n = n + 1
                end
            end
            return n
        end

        -- 资格门槛校验：requiredItems 未满足则拒绝兑换
        if #qualifyItems > 0 then
            local matchMode = dp.matchMode or "all"
            if matchMode == "any" then
                -- ANY 模式：任一资格物品满足即可
                local hasQualify = false
                for _, q in ipairs(qualifyItems) do
                    -- collect=false 表示不消耗，仅作为资格门槛
                    local need = q.collect and (q.count * batchCount) or q.count
                    if countOwned(q) >= need then
                        hasQualify = true
                        break
                    end
                end
                if not hasQualify then
                    sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                        action = "failed", reason = "Missing required items in backpack!",
                    })
                    return
                end
            else
                -- ALL 模式：所有资格物品均需满足
                for _, q in ipairs(qualifyItems) do
                    local need = q.collect and (q.count * batchCount) or q.count
                    if countOwned(q) < need then
                        sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                            action = "failed", reason = "Missing required items in backpack!",
                        })
                        return
                    end
                end
            end
        end

        -- 原子预检：确保整批兑换的消耗项数量均充足
        for _, cost in ipairs(costs) do
            if countOwned(cost) < cost.count * batchCount then
                sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                    action = "failed", reason = "Missing required items in backpack!",
                })
                return
            end
        end

        -- 扣除消耗物品（记录以便失败时回滚）
        local removedItems = {}
        for _, cost in ipairs(costs) do
            local toRemove = cost.count * batchCount
            for i = items:size() - 1, 0, -1 do
                if toRemove <= 0 then break end
                local it = items:get(i)
                if it and inv:contains(it) and matchesCost(it, cost) then
                    inv:Remove(it)
                    sendRemoveItemFromContainer(inv, it)
                    removedItems[#removedItems + 1] = it
                    toRemove = toRemove - 1
                end
            end
        end

        -- 发放奖励（N 倍），若任意一件添加失败则整体回滚
        local grantedItems = {}
        local rewardFailed = false
        for _, reward in ipairs(rewards) do
            for _ = 1, reward.count * batchCount do
                local newItem = inv:AddItem(reward.fullType)
                if newItem then
                    if reward.displayName and #reward.displayName > 0 then
                        newItem:setName(reward.displayName)
                    end
                    sendAddItemToContainer(inv, newItem)
                    grantedItems[#grantedItems + 1] = newItem
                else
                    rewardFailed = true
                    break
                end
            end
            if rewardFailed then break end
        end

        if rewardFailed then
            -- 回滚已发放的奖励
            for _, g in ipairs(grantedItems) do
                inv:Remove(g)
            end
            -- 回滚已扣除的消耗物品
            for _, r in ipairs(removedItems) do
                local back = inv:AddItem(r:getFullType())
                if back then
                    local dn = r:getDisplayName()
                    if dn and #dn > 0 then back:setName(dn) end
                    sendAddItemToContainer(inv, back)
                end
            end
            sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                action = "failed", reason = "Not enough backpack space!",
            })
            return
        end

        -- 计数与持久化（batch 一并计入各类上限）
        dp.triggerCount = (dp.triggerCount or 0) + batchCount
        if not dp.triggeredBy then dp.triggeredBy = {} end
        dp.playerDeliveries[pid] = myCount + batchCount
        table.insert(dp.triggeredBy, {
            playerId = pid, timestamp = os.time(),
            timeStr = os.date("!%Y-%m-%d %H:%M:%S"),  -- UTC 时间字符串
        })

        -- 更新玩家冷却时间戳
        if not Shared.isCooldownZero(cooldown) then
            dp.playerCooldowns = dp.playerCooldowns or {}
            dp.playerCooldowns[pid] = Shared.cooldownNowSeconds(cooldown.mode)
        end

        Persistence.saveOneDeliveryPoint(dp)
        Logger:info("ConfirmDelivery: dp=%s player=%s count=%d batch=%d", dp.id, pid, dp.triggerCount, batchCount)

        sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
            action = "completed", message = "Delivery completed!",
        })
        broadcastAll()
        return
    end
end

-- ==================== 事件钩子 ====================

-- 玩家登录时同步一次完整状态
local function onPlayerLogin(player)
    local pid = player and player:getUsername() or "?"
    Logger:info("Player logged in: %s, sending state...", pid)
    sendState(player)
end

-- 立即注册（而非等到 OnServerStarted），确保首位连接的玩家也能收到状态
Events.OnClientCommand.Add(Server.onClientCommand)
if Events.OnPlayerLogin then
    Events.OnPlayerLogin.Add(onPlayerLogin)
end

-- ==================== 初始化 ====================

Server.init = function()
    loadTriggers()
    loadDeliveryPoints()
    migrateFromModData()
    print("[EventTrigger-SERVER] init: " .. #Server.triggers .. " triggers, " .. #Server.deliveryPoints .. " delivery points loaded from JSON")
    Logger:info("Server ready with %d triggers, %d delivery points.", #Server.triggers, #Server.deliveryPoints)
end

Events.OnServerStarted.Add(Server.init)

return Server
