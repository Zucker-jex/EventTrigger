-- ============================================================
-- EventTrigger/Server.lua — DS server (B42 main path)
-- ============================================================

EventTriggerServer_loaded = true
print("[EventTrigger-SERVER] loaded: 42/media/lua/server/EventTrigger/Server.lua")

local Shared = require("EventTrigger/Shared")
local Persistence = require("EventTrigger/Persistence")
local Logger = require("ElyonLib/Core/Logger"):new("EventTrigger", "1.0")

local MODULE = Shared.MODULE
local Server = {}

-- ==================== Trigger storage (JSON files replace ModData) ====================
Server.triggers = {}
Server.deliveryPoints = {}

-- Load all triggers from JSON files
local function loadTriggers()
    Server.triggers = Persistence.loadTriggers()
    Logger:info("Loaded %d triggers from JSON files.", #Server.triggers)
end

-- Load all delivery points from JSON files
local function loadDeliveryPoints()
    Server.deliveryPoints = Persistence.loadDeliveryPoints()
    Logger:info("Loaded %d delivery points from JSON files.", #Server.deliveryPoints)
end

-- Save all triggers to JSON files
local function saveTriggers()
    Persistence.saveTriggers(Server.triggers)
    Logger:info("Saved %d triggers.", #Server.triggers)
end

-- Save single trigger (incremental update)
local function saveOneTrigger(trigger)
    Persistence.saveOneTrigger(trigger)
end

-- Delete single trigger file
local function deleteOneTriggerFile(triggerId)
    Persistence.deleteOneTrigger(triggerId)
    Persistence.deleteHistory(triggerId)
end

-- ==================== Utility functions ====================

-- Check if player is admin
local function isAdmin(player)
    return player and player:getAccessLevel() == "admin"
end

-- Get player ID
local function getPlayerId(player)
    return player and player:getUsername() or "unknown"
end

-- Find trigger index by ID in server list
local function findById(id)
    for i, t in ipairs(Server.triggers) do
        if t.id == id then return i end
    end
    return nil
end

-- Can player modify trigger (creator or admin)
local function canModify(player, trigger)
    return isAdmin(player) or trigger.creator == getPlayerId(player)
end

-- Find delivery point by ID
local function findDeliveryById(id)
    for i, dp in ipairs(Server.deliveryPoints) do
        if dp.id == id then return i end
    end
    return nil
end

-- ==================== Sync and Broadcast ====================

-- Build serializable trigger copy for network (with history)
local function makeSerializable(t)
    local copy = {}
    for k, v in pairs(t) do
        if k ~= "inRangePlayers" then
            copy[k] = v
        end
    end
    copy.triggeredBy = Persistence.loadHistory(t.id)
    return copy
end

local function makeSerializableList(triggers)
    local list = {}
    for _, t in ipairs(triggers) do
        list[#list + 1] = makeSerializable(t)
    end
    return list
end

-- Send full trigger list to a specific player (with history + delivery points)
local function sendState(player)
    local list = makeSerializableList(Server.triggers)
    local dlvList = {}
    for _, dp in ipairs(Server.deliveryPoints) do
        dlvList[#dlvList + 1] = dp
    end
    Logger:info("SendState: sending %d triggers + %d delivery points to %s", #list, #dlvList, getPlayerId(player))
    sendServerCommand(player, MODULE, Shared.COMMANDS.SYNC_STATE, { triggers = list, deliveryPoints = dlvList })
end

-- Broadcast trigger list to all online clients (with history + delivery points)
local function broadcastAll()
    local list = makeSerializableList(Server.triggers)
    local dlvList = {}
    for _, dp in ipairs(Server.deliveryPoints) do
        dlvList[#dlvList + 1] = dp
    end
    Logger:info("BroadcastAll: broadcasting %d triggers + %d delivery points to all clients", #list, #dlvList)
    sendServerCommand(MODULE, Shared.COMMANDS.SYNC_STATE, { triggers = list, deliveryPoints = dlvList })
end

-- ==================== Legacy data migration ====================

-- Migrate existing triggers from ModData to JSON files (runs once on first load)
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
            -- Migrate history to separate JSON file
            if t.triggeredBy and #t.triggeredBy > 0 then
                Persistence.saveHistory(trigger.id, t.triggeredBy)
            end
            migrated = migrated + 1
        end
    end
    if migrated > 0 then
        saveTriggers()
        -- Clear ModData to prevent duplicate migration
        data.triggers = {}
    end
    Logger:info("Migration complete: %d triggers migrated to JSON.", migrated)
end

-- ==================== Command handling ====================

Server.onClientCommand = function(module, command, player, args)
    if module ~= MODULE then return end

    local pid = getPlayerId(player)
    Logger:info("cmd=%s player=%s", command, pid)

    -- ---------- Sync request ----------
    if command == Shared.COMMANDS.REQUEST_SYNC then
        sendState(player)
        return
    end

    -- ---------- Place trigger ----------
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

    -- ---------- Delete trigger ----------
    if command == Shared.COMMANDS.DELETE_TRIGGER then
        local idx = findById(args.id)
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

    -- ---------- Reset trigger count ----------
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
            -- Clear history file, write empty list
            Persistence.saveHistory(t.id, {})
            Logger:info("Trigger reset: id=%s by %s", t.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- Delete all triggers ----------
    if command == Shared.COMMANDS.DELETE_ALL then
        if isAdmin(player) and args.all then
            for _, t in ipairs(Server.triggers) do
                deleteOneTriggerFile(t.id)
            end
            Server.triggers = {}
        else
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

    -- ---------- Edit message ----------
    if command == Shared.COMMANDS.EDIT_MESSAGE then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            Server.triggers[idx].message = tostring(args.message or ""):sub(1, 500)
            saveOneTrigger(Server.triggers[idx])
            Logger:info("Trigger message edited: id=%s by %s", Server.triggers[idx].id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- Edit params (delay/range/max triggers) ----------
    if command == Shared.COMMANDS.EDIT_PARAMS then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            local t = Server.triggers[idx]
            if args.delay ~= nil then t.delay = math.max(0, args.delay) end
            if args.range ~= nil then t.range = math.max(0.5, args.range) end
            if args.maxTriggers ~= nil then t.maxTriggers = args.maxTriggers end
            if args.cooldown ~= nil then t.cooldown = Shared.makeCooldown(args.cooldown) end
            saveOneTrigger(t)
            Logger:info("Trigger params edited: id=%s by %s", t.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- Edit output type/name ----------
    if command == Shared.COMMANDS.EDIT_OUTPUT then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx and canModify(player, Server.triggers[idx]) then
            local t = Server.triggers[idx]
            if args.outputType ~= nil then t.outputType = args.outputType end
            if args.outputName ~= nil then t.outputName = tostring(args.outputName or ""):sub(1, 100) end
            saveOneTrigger(t)
            Logger:info("Trigger output edited: id=%s by %s", t.id, pid)
            broadcastAll()
        end
        return
    end

    -- ---------- Toggle trigger enabled/disabled ----------
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

    -- ---------- Disable all triggers + delivery points ----------
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

    -- ---------- Record trigger (client reports player entered range) ----------
    if command == Shared.COMMANDS.RECORD_TRIGGER then
        local idx = findById(args.id)
        if not idx and args.index then
            idx = (args.index >= 1 and args.index <= #Server.triggers) and args.index or nil
        end
        if idx then
            local t = Server.triggers[idx]
            -- Check max trigger count limit
            if t.maxTriggers > 0 and t.triggerCount >= t.maxTriggers then
                return
            end
            -- Check trigger cooldown (global per-trigger)
            local cd = t.cooldown or {}
            if not Shared.isCooldownZero(cd) and t.lastTriggerAt then
                local now = Shared.cooldownNowSeconds(cd.mode)
                if (now - t.lastTriggerAt) < Shared.cooldownDurationSeconds(cd) then
                    return  -- still cooling down
                end
            end
            t.triggerCount = (t.triggerCount or 0) + 1
            if not Shared.isCooldownZero(cd) then
                t.lastTriggerAt = Shared.cooldownNowSeconds(cd.mode)
            end
            saveOneTrigger(t)
            -- Append history entry to separate JSON file
            local entry = Shared.makeHistoryEntry(
                args.playerId or pid,
                args.timestamp or os.time(),
                args.timeStr or ""
            )
            Persistence.appendHistory(t.id, entry)
            Logger:info("Trigger recorded: id=%s count=%d by %s", t.id, t.triggerCount, pid)
            -- Don't broadcast (reduce network overhead), just persist; next sync will update client
        end
        return
    end

    -- ---------- NAMED mode message broadcast ----------
    if command == Shared.COMMANDS.NAMED_MESSAGE then
        Logger:info("NamedMessage: broadcasting")
        sendServerCommand(MODULE, Shared.COMMANDS.NAMED_MESSAGE, {
            message    = args.message or "",
            outputName = args.outputName or "System",
        })
        return
    end

    -- ==================== Delivery Point Commands ====================

    -- ---------- Place delivery point ----------
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
            playerDeliveries = {},
            playerCooldowns = {},
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

    -- ---------- Delete delivery point ----------
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

    -- ---------- Delete all delivery points ----------
    if command == Shared.COMMANDS.DELETE_ALL_DELIVERY then
        if isAdmin(player) and args.all then
            for _, dp in ipairs(Server.deliveryPoints) do
                Persistence.deleteOneDeliveryPoint(dp.id)
            end
            Server.deliveryPoints = {}
        else
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

    -- ---------- Edit delivery point ----------
    if command == Shared.COMMANDS.EDIT_DELIVERY then
        local dpIdx = findDeliveryById(args.id)
        if dpIdx then
            local dp = Server.deliveryPoints[dpIdx]
            if canModify(player, dp) then
                if args.hintText ~= nil then dp.hintText = tostring(args.hintText):sub(1, 500) end
                if args.range ~= nil then dp.range = math.max(0.5, args.range) end
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

    -- ---------- Reset delivery point ----------
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

    -- ---------- Toggle delivery point enabled/disabled ----------
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

    -- ---------- Request delivery (client checks inventory before sending) ----------
    if command == Shared.COMMANDS.REQUEST_DELIVERY then
        local dpIdx = findDeliveryById(args.id)
        if not dpIdx then
            Logger:info("RequestDelivery: delivery point %s not found", tostring(args.id))
            return
        end
        local dp = Server.deliveryPoints[dpIdx]
        -- Send delivery details back to the requesting client for UI display
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

    -- ---------- Confirm delivery (batch-aware, atomic) ----------
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

        -- Resolve the effective exchange plan (qualify gate + cost + reward)
        local qualifyItems, costs, rewards, branchErr = Shared.resolveExchange(dp, args.branchId, args.costOptionIndex)
        if branchErr then
            sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                action = "failed", reason = branchErr,
            })
            return
        end
        -- Legacy ANY mode: narrow cost to the selected option
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

        -- Batch count (N): positive integer, default 1, capped for safety
        local batchCount = tonumber(args.batchCount) or 1
        batchCount = math.floor(batchCount)
        if batchCount < 1 then batchCount = 1 end
        if batchCount > 1000 then batchCount = 1000 end

        -- Check cooldown (before touching inventory)
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

        -- Caps: batch counts toward per-player / global limits
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
        local function matchesCost(it, cost)
            if not it then return false end
            return it:getFullType() == cost.fullType
        end
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

        -- 资格门槛检查：需求物品 requiredItems（缺失则拒绝交换）
        if #qualifyItems > 0 then
            local matchMode = dp.matchMode or "all"
            if matchMode == "any" then
                local hasQualify = false
                for _, q in ipairs(qualifyItems) do
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

        -- Atomic pre-check: ensure enough stock for the whole batch
        for _, cost in ipairs(costs) do
            if countOwned(cost) < cost.count * batchCount then
                sendServerCommand(player, MODULE, Shared.COMMANDS.DELIVERY_RESULT, {
                    action = "failed", reason = "Missing required items in backpack!",
                })
                return
            end
        end

        -- Deduct cost items (record for rollback)
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

        -- Grant rewards (N x), rollback everything if any AddItem fails
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
            -- Rollback granted rewards
            for _, g in ipairs(grantedItems) do
                inv:Remove(g)
            end
            -- Rollback removed cost items
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

        -- Track + persist (batch counts toward limits)
        dp.triggerCount = (dp.triggerCount or 0) + batchCount
        if not dp.triggeredBy then dp.triggeredBy = {} end
        dp.playerDeliveries[pid] = myCount + batchCount
        table.insert(dp.triggeredBy, {
            playerId = pid, timestamp = os.time(),
            timeStr = os.date("!%Y-%m-%d %H:%M:%S"),
        })

        -- Update cooldown timestamp
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

-- ==================== Event hooks ====================

-- Sync trigger list when player logs in
local function onPlayerLogin(player)
    local pid = player and player:getUsername() or "?"
    Logger:info("Player logged in: %s, sending state...", pid)
    sendState(player)
end

-- Register immediately (not in OnServerStarted) so first connecting player gets state too
Events.OnClientCommand.Add(Server.onClientCommand)
if Events.OnPlayerLogin then
    Events.OnPlayerLogin.Add(onPlayerLogin)
end

-- ==================== Initialization ====================

Server.init = function()
    loadTriggers()
    loadDeliveryPoints()
    migrateFromModData()
    print("[EventTrigger-SERVER] init: " .. #Server.triggers .. " triggers, " .. #Server.deliveryPoints .. " delivery points loaded from JSON")
    Logger:info("Server ready with %d triggers, %d delivery points.", #Server.triggers, #Server.deliveryPoints)
end

Events.OnServerStarted.Add(Server.init)

return Server
