-- ============================================================
-- EventTriggerClient — client main logic (SP/MP shared)
-- Manages trigger CRUD, player detection, message scheduling, and UI
-- ============================================================

-- ============================================================
-- Bootstrap order (IMPORTANT):
--   1) Ensure EventTrigger / EventTrigger.Delivery globals exist BEFORE require,
--      so EventTriggerDelivery.lua can safely attach to them.
--   2) require dependencies.
--   3) Install stubs for any missing Delivery methods, so that ANY caller
--      (OnTick, context menu, UI buttons, server commands) never crashes
--      when the delivery module is unavailable.
-- ============================================================
EventTrigger = EventTrigger or {}
EventTrigger.Delivery = EventTrigger.Delivery or {}

require "ISUI/ISTextBox"
require "EventTriggerDelivery"

do
    -- Methods that should exist on EventTrigger.Delivery when the module loaded.
    local expectedMethods = {
        "CheckPlayerInRange", "StartSetup", "EditDelivery", "DeleteDelivery",
        "ResetDelivery", "ShowHistory", "OnDeliveryResult",
        "CloseAllUIs", "Validate", "Execute", "MatchItem", "CountItems",
    }

    -- Stub return values so callers that expect (ok, msg) don't crash on nil.
    local stubFactories = {
        Validate   = function() return false, "Delivery module not loaded" end,
        Execute    = function() return false, "Delivery module not loaded" end,
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

    -- State tables consumed across the module.
    EventTrigger.Delivery._activePrompt = EventTrigger.Delivery._activePrompt or {}
    EventTrigger.Delivery._pendingDpId  = EventTrigger.Delivery._pendingDpId  or {}

    -- Single, prominent warning if the module did not load.
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

-- Debug output function, controlled by EventTrigger.DEBUG flag
local function dbg(...)
    if EventTrigger.DEBUG then
        print("[EventTrigger-CLIENT]", ...)
    end
end

-- Trigger message output mode enum (corresponds to MongooseChat channels)
EventTrigger.OutputType = {
    NAMED = 1,  -- Named + system channel (blue)
    SAY   = 2,  -- /say  triggerer identity + bubble
    DO    = 3,  -- /do   environment narration
    LOW   = 4,  -- /low  whisper + bubble
    YELL  = 5,  -- /yell shout + bubble
    OOC   = 6,  -- /ooc  global OOC
    HALO  = 7,  -- Floating text above head (no chat log)
}

-- Output type name lookup (for UI display)
local OutputTypeNames = {
    [1] = "Named",
    [2] = "/say",
    [3] = "/do",
    [4] = "/low",
    [5] = "/yell",
    [6] = "/ooc",
    [7] = "Above Head",
}

-- Get stable player identifier (prefer Steam username, fallback "unknown")
local function GetPlayerIdentifier(player)
    if not player then return "unknown" end
    return player:getUsername() or "unknown"
end

-- Check if current player is admin
function EventTrigger.IsAdmin()
    local player = getPlayer()
    return player and player:getAccessLevel() == "admin"
end

-- Get current player ID
function EventTrigger.GetCurrentPlayerId()
    return GetPlayerIdentifier(getPlayer())
end

-- Get user config (Global ModData storage, per-player)
function EventTrigger.GetConfig()
    local data = ModData.getOrCreate("EventTrigger")
    local cfg = data.config or {}
    return {
        outputName = cfg.outputName or "System",
        defaultRange = cfg.defaultRange or 2,
    }
end

-- Set user config key (e.g. outputName, defaultRange)
function EventTrigger.SetConfig(key, value)
    local data = ModData.getOrCreate("EventTrigger")
    if not data.config then data.config = {} end
    data.config[key] = value
end

-- Detect multiplayer mode (world:getGameMode(), more reliable than isClient())
function EventTrigger.IsMultiplayer()
    local world = getWorld()
    if world then
        return world:getGameMode() == "Multiplayer"
    end
    return false
end

-- Get square at given coordinates
function EventTrigger.GetSquare(x, y, z)
    local cell = getCell()
    if not cell then return nil end
    return cell:getGridSquare(x, y, z)
end

-- Auto-increment ID counter (generate unique trigger IDs, collision-free across clients)
EventTrigger._idCounter = EventTrigger._idCounter or 0

-- Generate unique trigger ID (prefix "trig_" + Unix timestamp + auto-increment)
function EventTrigger._generateId()
    EventTrigger._idCounter = EventTrigger._idCounter + 1
    return "trig_" .. tostring(os.time()) .. "_" .. tostring(EventTrigger._idCounter)
end

-- Write trigger data to square ModData (SP only)
-- In MP, server JSON files are authoritative, skip square writes
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

-- Read all trigger data from a square
function EventTrigger.ReadFromSquare(x, y, z)
    local sq = EventTrigger.GetSquare(x, y, z)
    if not sq then return nil end
    return sq:getModData().EventTrigger
end

-- Update specific trigger fields on a square by ID (SP only)
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

-- Remove trigger from square by ID (SP only)
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

-- Clear all trigger data from a square (SP only)
function EventTrigger.ClearFromSquare(x, y, z)
    if EventTrigger.IsMultiplayer() then return true end
    local sq = EventTrigger.GetSquare(x, y, z)
    if not sq then return false end
    local md = sq:getModData()
    md.EventTrigger = nil
    sq:transmitModdata()
    return true
end

-- Scan 30-cell radius around player, collect trigger data
-- Returns trigger list with coordinate info (compatible with legacy single-object format)
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

-- Generate unique key string from coordinates (for coordinate matching)
function EventTrigger._makeKey(x, y, z)
    return tostring(math.floor(x or 0)) .. "_" .. tostring(math.floor(y or 0)) .. "_" .. tostring(math.floor(z or 0))
end

-- Find trigger index by ID in runtime list
function EventTrigger._findIndexById(id)
    for i, t in ipairs(EventTrigger.triggers) do
        if t.id == id then return i end
    end
    return nil
end

-- Rebuild runtime trigger list from nearby squares (SP only)
-- In MP, server JSON files are authoritative; syncAll provides full list
function EventTrigger.RebuildList()
    if EventTrigger.IsMultiplayer() then
        dbg("RebuildList: MP mode, skipped (server is authoritative)")
        return
    end
    local scanned = EventTrigger.ScanNearbySquares()
    local changed = false

    -- Build set of scanned IDs to detect triggers removed from squares
    local scannedIds = {}
    for _, td in ipairs(scanned) do
        if td.id then scannedIds[td.id] = true end
    end

    for _, td in ipairs(scanned) do
        local idx = EventTrigger._findIndexById(td.id)
        if idx then
            local t = EventTrigger.triggers[idx]
            -- Use max triggerCount if square has a newer value
            if td.triggerCount and td.triggerCount > (t.triggerCount or 0) then
                t.triggerCount = td.triggerCount
            end
            -- Restore triggeredBy from square if local has none
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
            -- Update coordinates (retain compatibility)
            t.x = td.x
            t.y = td.y
            t.z = td.z
        else
            -- Restore persisted triggerCount + triggeredBy from square ModData
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
                inRangePlayers = {},
                creator = td.creator or "unknown",
            })
            changed = true
            if restoredCount > 0 then
                dbg("RebuildList: restored triggerCount=" .. restoredCount .. " for id=" .. (td.id or "?"))
            end
        end
    end

    -- Clean entries in local list that are within scan range but no longer on squares
    -- Second line of defense against "multiplayer delete desync":
    -- Even if _removeMissingFromServer doesn't fire, RebuildList detects and removes them
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
                -- Keep if outside scan range (may be in another area), remove if in range but absent from square
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

-- Dual-mode execution: local update first (optimistic UI), then send to server for authoritative persistence in MP
-- Server syncAll provides final reconciliation
-- Uses sendClientCommand (same as BulletinBoard), received by server OnClientCommand
function EventTrigger.SendCommand(command, args)
    args = args or {}
    dbg("SendCommand:", command, "multiplayer=", tostring(EventTrigger.IsMultiplayer()))
    -- Always execute locally first for immediate UI feedback
    EventTrigger.ExecuteLocal(command, args)
    if EventTrigger.IsMultiplayer() then
        sendClientCommand("EventTrigger", command, args)
        dbg("SendCommand: also sent to server, command=", command)
    end
end

-- Execute command locally (SP/MP shared): update ModData, then refresh list and UI
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
            creator = args.creator or GetPlayerIdentifier(getPlayer()),
        }
        if not EventTrigger.WriteToSquare(x, y, z, sqData) then
            dbg("placeTrigger FAILED: square not loaded at", x, y, z)
        end
        -- MP: insert directly into local list (WriteToSquare and RebuildList skip squares in MP)
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
            -- Sync zero out count and history in square ModData
            EventTrigger.UpdateSquareTrigger(t.id, t.x, t.y, t.z, { triggerCount = 0, triggeredBy = {} })
            EventTrigger._saveToModData()
            if EventTrigger._ui then EventTrigger._ui:refreshList() end
        end

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
            local partial = {}
            if args.delay ~= nil then partial.delay = t.delay end
            if args.range ~= nil then partial.range = t.range end
            if args.maxTriggers ~= nil then partial.maxTriggers = t.maxTriggers end
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

    -- Also write triggerCount to square ModData for persistence (SP only)
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
            -- Critical: sync write to square ModData (SP only)
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

-- Remove triggers in local list that don't exist on server (server is authoritative)
-- Solves MP delete desync: RebuildList() only adds, never removes,
-- so we need the server list to clean stale local entries
-- Also cleans square ModData to prevent RebuildList from re-scanning them back
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
            -- Also remove from square ModData to prevent RebuildList from re-scanning them
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

-- Server command callback: syncAll → full list replacement (server JSON is authoritative)
-- namedMessage → NAMED broadcast
function EventTrigger.OnServerCommand(module, command, args)
    if module ~= "EventTrigger" then
        return
    end
    dbg("OnServerCommand: received command=", command)
    if command == "syncAll" then
        -- MP: server JSON files are authoritative, fully replace local list
        if EventTrigger.IsMultiplayer() and args and args.triggers then
            -- Preserve local runtime state (inRangePlayers), rebuild from server data
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
                    inRangePlayers = oldInRange[src.id] or {},
                    creator     = src.creator or "unknown",
                }
                newList[#newList + 1] = trigger
            end
            EventTrigger.triggers = newList
            dbg("OnServerCommand: replaced trigger list from server, count=", #newList)

            -- Process delivery points from server sync (preserve _dlvPrompted per-object, like trigger inRangePlayers)
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
                        cooldownType  = src.cooldownType or 0,
                        cooldownValue = src.cooldownValue or 0,
                        playerDeliveries = src.playerDeliveries or {},
                        playerCooldowns  = src.playerCooldowns or {},
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
            -- SP fallback: rebuild from square ModData scan
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
        -- NAMED mode server broadcast: show panel message on all clients
        local mcPanel = GetMongooseChatPanel()
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
        -- Delivery stub guarantees OnDeliveryResult exists, so no guard needed here.
        local player = getPlayer()
        if args and player then
            local success = (args.action == "completed")
            local msg = args.message or args.reason or ""
            EventTrigger.Delivery.OnDeliveryResult(player, success, msg, args.rewardItems)
        end
    end
end

-- Get current in-game timestamp (numeric time + formatted "Day X HH:MM")
function EventTrigger.GetTimestamp()
    local gt = getGameTime()
    if not gt then return 0, "" end
    local day = gt:getDay()
    local hour = gt:getHour()
    local min = gt:getMinutes()
    return gt:getTimeOfDay(),
        string.format("Day %d %02d:%02d", (day or 0) + 1, hour or 0, min or 0)
end

-- Persist runtime stats to Global ModData (SP only)
function EventTrigger._saveToModData()
    if EventTrigger.IsMultiplayer() then return end
    local data = ModData.getOrCreate("EventTrigger")
    data.triggers = EventTrigger.triggers
    data.deliveryPoints = EventTrigger.deliveryPoints
end

-- Merge source history into runtime list (match by ID, merge history fields only)
-- SP only; in MP, history is served via server syncAll
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
                    -- Also write back to square ModData for square persistence
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

-- Game startup load entry
-- SP: scan from square ModData, migrate from legacy Global if empty
-- MP: request sync from server (server JSON files are authoritative)
function EventTrigger.Load()
    if EventTrigger.IsMultiplayer() then
        dbg("Load: MP mode, requesting sync from server...")
        EventTrigger.RequestSync()
        return
    end
    -- SP path: load from square ModData / Global ModData
    local data = ModData.getOrCreate("EventTrigger")
    local saved = data.triggers
    local hasSaved = (saved and type(saved) == "table" and #saved > 0)
    dbg("Load: Global ModData has " .. (hasSaved and #saved or 0) .. " saved triggers")

    EventTrigger.RebuildList()

    if hasSaved then
        EventTrigger._mergeHistory(saved)
    end

    -- SP: Load delivery points from Global ModData
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
                    cooldownType  = dp.cooldownType or 0,
                    cooldownValue = dp.cooldownValue or 0,
                    playerDeliveries = dp.playerDeliveries or {},
                    playerCooldowns  = dp.playerCooldowns or {},
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

-- Request trigger sync from server (MP only)
function EventTrigger.RequestSync(all)
    if EventTrigger.IsMultiplayer() then
        dbg("RequestSync: sending requestSync to server, all=", tostring(all))
        sendClientCommand("EventTrigger", "requestSync", { all = all })
    else
        dbg("RequestSync: single player, no sync needed")
    end
end

-- Check if player has EventTriggerTool in inventory or hands
local function HasTool(player)
    if not player then return false end
    local inv = player:getInventory()
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        if items:get(i):getType() == "EventTriggerTool" then return true end
    end
    local primary = player:getPrimaryHandItem()
    if primary and primary:getType() == "EventTriggerTool" then return true end
    local secondary = player:getSecondaryHandItem()
    if secondary and secondary:getType() == "EventTriggerTool" then return true end
    return false
end

-- Get player's readable name (prefer Steam username, fallback to character name)
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

-- Convert output type number to readable name (UI display)
local function OutputTypeToName(ot)
    return OutputTypeNames[ot] or "Above Head"
end

-- ============================================================
-- MongooseChat integration: lazy-load MC_ChatPanel + dynamically register system channel
-- Use pcall require for safe loading, avoid crash if MongooseChat is not installed
-- ============================================================
local _mcChatPanel = nil
local function GetMongooseChatPanel()
    if _mcChatPanel ~= nil then return _mcChatPanel end
    local ok1, MC_ChatPanel = pcall(require, "MC_ChatPanel")
    if not ok1 or not MC_ChatPanel then
        _mcChatPanel = false
        dbg("MongooseChat integration: MC_ChatPanel module not available")
        return _mcChatPanel
    end
    -- Get running panel instance (created by MongooseChat on init)
    local instance = MC_ChatPanel.instance
    if not instance or not instance.addMessage then
        _mcChatPanel = false
        dbg("MongooseChat integration: MC_ChatPanel.instance not ready")
        return _mcChatPanel
    end
    -- Dynamically register system channel (EventTrigger system messages)
    local ok2, MC_Config = pcall(require, "MC_Config")
    if ok2 and MC_Config then
        if not MC_Config.ChannelColors["system"] then
            MC_Config.ChannelColors["system"] = {000, 191, 255}  -- Blue
        end
        if not MC_Config.ChannelTags["system"] then
            MC_Config.ChannelTags["system"] = "[System]"
        end
    end
    _mcChatPanel = instance
    dbg("MongooseChat integration: ready (MC_ChatPanel.instance acquired)")
    return _mcChatPanel
end

-- Lazy-load MC_Bubble module, create speech bubbles (for say/do channels)
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

-- Create chat message object (satisfies ISChat.addLineInChat interface)
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

-- Show trigger message
-- MP: voice channels via MongooseChat server pipeline, NAMED via EventTrigger server broadcast
-- SP: direct MC_ChatPanel + MC_Bubble calls
local function ShowChatMessage(msg, triggerPlayer, outputType, outputName)
    local player = triggerPlayer or getPlayer()
    if not player then return end
    local ot = outputType or EventTrigger.OutputType.HALO

    if ot == EventTrigger.OutputType.HALO then
        HaloTextHelper.addGoodText(player, msg)
        return
    end

    local CHANNEL_MAP = {
        [EventTrigger.OutputType.NAMED] = { mc = "system", bubble = false },
        [EventTrigger.OutputType.SAY]   = { mc = "say",    bubble = true  },
        [EventTrigger.OutputType.DO]    = { mc = "do",     bubble = false },
        [EventTrigger.OutputType.LOW]   = { mc = "low",    bubble = true  },
        [EventTrigger.OutputType.YELL]  = { mc = "yell",   bubble = true  },
        [EventTrigger.OutputType.OOC]   = { mc = "ooc",    bubble = false },
    }

    local ch = CHANNEL_MAP[ot]
    if not ch then return end

    -- ================================================================
    -- MP path: server pipeline, visible to all players in range
    -- ================================================================
    if EventTrigger.IsMultiplayer() then
        if ot == EventTrigger.OutputType.NAMED then
            -- NAMED: show locally immediately + EventTrigger server broadcast to all clients
            local mcPanel = GetMongooseChatPanel()
            if mcPanel then
                local cfg = EventTrigger.GetConfig()
                local author = outputName
                if not author or #author == 0 then author = cfg.outputName end
                mcPanel.addMessage({
                    channel = "system",
                    message = msg,
                    timestamp = os.time(),
                    characterName = author,
                    username = "EventTrigger",
                })
            end
            sendClientCommand("EventTrigger", "namedMessage", {
                message = msg,
                outputName = outputName,
            })
        else
            -- SAY/LOW/YELL/DO/OOC: masquerade as player chat, MC server handles range calc + broadcast
            -- All in-range clients automatically receive panel + bubble (via MC_Client.onChatMessage)
            sendClientCommand("MongooseChat", "ChatMessage", {
                channel = ch.mc,
                message = msg,
                radioEmitters = {},
            })
        end
        return
    end

    -- ================================================================
    -- SP path: direct MC_ChatPanel + MC_Bubble calls (no server)
    -- ================================================================
    local mcPanel = GetMongooseChatPanel()
    if mcPanel then
        local mcData = { message = msg, timestamp = os.time(), channel = ch.mc }
        if ot == EventTrigger.OutputType.NAMED then
            local cfg = EventTrigger.GetConfig()
            local author = outputName
            if not author or #author == 0 then author = cfg.outputName end
            mcData.characterName = author
            mcData.username = "EventTrigger"
        else
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
        end
        mcPanel.addMessage(mcData)
        if ch.bubble then
            ShowMCBubble(ch.mc, triggerPlayer, mcData.message)
        end
        return
    end

    -- === Fallback (native ISChat / HALO) ===
    if not ISChat.instance then
        HaloTextHelper.addGoodText(player, msg)
        return
    end

    local ok, err = pcall(function()
        local chatMsg
        if ot == EventTrigger.OutputType.NAMED then
            local cfg = EventTrigger.GetConfig()
            local author = outputName
            if not author or #author == 0 then author = cfg.outputName end
            chatMsg = CreateChatMessage(msg, author)
        else
            chatMsg = CreateChatMessage(msg, GetPlayerName(triggerPlayer))
        end
        if chatMsg then
            ISChat.addLineInChat(chatMsg, 0)
        end
    end)
    if not ok then
        dbg("ShowChatMessage error:", err, "- falling back to HALO")
        HaloTextHelper.addGoodText(player, msg)
    end
end

-- Schedule delayed message: delayFrames = seconds * 60 (60fps), checked on OnTick
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

-- Per-frame execution: periodic scan (~5s), player distance check, timer expiry handling
function EventTrigger.OnTick()
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
            if inRange then
                    if not trigger.inRangePlayers[playerKey] then
                    local exhausted = trigger.maxTriggers > 0 and (trigger.triggerCount or 0) >= trigger.maxTriggers
                    if not exhausted then
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

        -- Delivery point detection (delegated to EventTriggerDelivery module; safe even if stubbed)
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

-- Open main manager UI (prevent duplicates)
function EventTrigger.OpenUI()
    if EventTrigger._ui then
        EventTrigger._ui:close()
    end
    EventTrigger._ui = EventTriggerUI:new()
    EventTrigger._ui:initialise()
    EventTrigger._ui:addToUIManager()
end

-- Right-click world object menu: place trigger + delivery point + manager entry (return early on test)
function EventTrigger.OnFillWorldObjectContextMenu(playerIndex, context, worldObjects, test)
    if test then return end
    local player = getSpecificPlayer(playerIndex)
    if not player then return end
    local hasTool = HasTool(player)

    local square = worldObjects[1] and worldObjects[1]:getSquare()
    if square and hasTool then
        local x, y, z = square:getX(), square:getY(), square:getZ()
        local txt = string.format("Place Trigger (%d,%d,%d)", x, y, z)
        context:addOption(txt, nil, function()
            EventTrigger.PromptDelayRange(x, y, z)
        end)
        -- Only offer delivery placement when the delivery module is actually available.
        if EventTrigger.DeliveryLoaded then
            local dlvTxt = string.format("Set Delivery Point (%d,%d,%d)", x, y, z)
            context:addOption(dlvTxt, nil, function()
                EventTrigger.Delivery.StartSetup(x, y, z)
            end)
        end
    end

    if hasTool then
        context:addOption("EventTrigger Manager", nil, EventTrigger.OpenUI)
    end
end

-- ============================================================
-- EventTriggerTextPrompt — unified text input dialog
-- Replaces ISTextBox for wizard steps: proper multi-line prompt handling
-- and a spacious layout so the prompt never overlaps the input/buttons.
-- ============================================================
EventTriggerTextPrompt = ISPanel:derive("EventTriggerTextPrompt")

function EventTriggerTextPrompt:new(title, prompt, defaultText, onOk, onCancel)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()

    local lines = {}
    if prompt then
        for line in (prompt .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end
    end
    if #lines == 0 then lines[1] = "" end

    local titleH = 28
    local lineH = 20
    local padX = 24
    local entryH = 30
    local btnH = 34
    local gap = 16

    local w = 560
    local promptTop = titleH + 18
    local promptH = #lines * lineH
    local entryY = promptTop + promptH + 14
    local btnY = entryY + entryH + 22
    local h = btnY + btnH + 18
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
    o.defaultText = defaultText or ""
    o.onOk = onOk
    o.onCancel = onCancel
    o.dragging = false
    return o
end

function EventTriggerTextPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerTextPrompt:create()
    self:setAlwaysOnTop(true)

    local titleH = 28
    local lineH = 20
    local padX = 24
    local entryH = 30
    local btnH = 34

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerTextPrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    local promptTop = titleH + 18
    local promptH = #self.lines * lineH
    local entryY = promptTop + promptH + 14
    local btnY = entryY + entryH + 22

    self.entry = ISTextEntryBox:new(self.defaultText, padX, entryY, self.width - padX * 2, entryH)
    self.entry:initialise()
    self.entry:instantiate()
    self:addChild(self.entry)

    local btnW = 120
    local okX = (self.width - (btnW * 2 + 20)) / 2
    local cancelX = okX + btnW + 20

    self.okBtn = ISButton:new(okX, btnY, btnW, btnH, "OK", self, EventTriggerTextPrompt.onOk)
    self.okBtn:initialise()
    self:addChild(self.okBtn)

    self.cancelBtn = ISButton:new(cancelX, btnY, btnW, btnH, "Cancel", self, EventTriggerTextPrompt.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)
end

function EventTriggerTextPrompt:onOk()
    local text = self.entry and self.entry:getText() or ""
    self:close()
    if self.onOk then self.onOk(text) end
end

function EventTriggerTextPrompt:onCancel()
    self:close()
    if self.onCancel then self.onCancel() end
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

    local y = 28 + 18
    for _, line in ipairs(self.lines) do
        if line and #line > 0 then
            self:drawText(line, 24, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
        end
        y = y + 20
    end
end

-- ============================================================
-- Placement wizard (multi-step input)
-- Step 1: Enter delay(seconds), range, max triggers
-- ============================================================
function EventTrigger.PromptDelayRange(x, y, z)
    local cfg = EventTrigger.GetConfig()
    EventTrigger._pending = { x = x, y = y, z = z }
    local defaultText = string.format("%d, %.1f, -1", 3, cfg.defaultRange)
    local modal = EventTriggerTextPrompt:new(
        "New Trigger",
        "Delay(s), Range, MaxTriggers (-1=unlimited)",
        defaultText,
        function(text)
            local p = EventTrigger._pending
            p.delay, p.range, p.maxTriggers = 3, cfg.defaultRange, -1
            local parts = luautils.split(text, ",")
            if #parts >= 1 then p.delay = tonumber(parts[1]) or 3 end
            if #parts >= 2 then p.range = tonumber(parts[2]) or cfg.defaultRange end
            if #parts >= 3 then p.maxTriggers = tonumber(parts[3]) or -1 end
            if p.delay < 0 then p.delay = 0 end
            if p.range < 0.5 then p.range = 0.5 end
            if p.maxTriggers == 0 then p.maxTriggers = -1 end
            EventTrigger.PromptMessage2()
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Step 2: Enter trigger message text
function EventTrigger.PromptMessage2()
    local p = EventTrigger._pending
    local modal = EventTriggerTextPrompt:new(
        "Trigger Message",
        "Trigger Message (OK to continue)",
        "Trigger activated!",
        function(text)
            p.msg = text
            if not p.msg or #p.msg == 0 then p.msg = "Trigger activated!" end
            EventTrigger.PromptOutput2()
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Step 3: Select output mode
function EventTrigger.PromptOutput2()
    local p = EventTrigger._pending
    local modal = EventTriggerTextPrompt:new(
        "Output Mode",
        "Output: 1=Named 2=/say 3=/do 4=/low 5=/yell 6=/ooc 7=Above Head",
        "2",
        function(text)
            p.outputType = tonumber(text) or 2
            if p.outputType < 1 or p.outputType > 7 then p.outputType = 2 end
            if p.outputType == EventTrigger.OutputType.NAMED then
                EventTrigger.PromptOutputName2()
            else
                EventTrigger.PlacePending()
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Step 3b (Named mode only): enter display name
function EventTrigger.PromptOutputName2()
    local p = EventTrigger._pending
    local cfg = EventTrigger.GetConfig()
    local modal = EventTriggerTextPrompt:new(
        "Named Mode",
        "Display Name for Named mode (OK to place)",
        cfg.outputName,
        function(text)
            p.outputName = text or ""
            EventTrigger.PlacePending()
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Finalize placement: collect all params into args table, call SendCommand
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
        creator = EventTrigger.GetCurrentPlayerId(),
    }
    dbg("PlacePending: placing trigger at (", p.x, p.y, p.z, "), msg=", p.msg, "delay=", p.delay, "range=", p.range)
    EventTrigger.SendCommand("placeTrigger", args)
    EventTrigger._pending = nil
end

-- UI shortcut: delete trigger at index
function EventTrigger.DeleteTrigger(index)
    local t = EventTrigger.triggers[index]
    EventTrigger.SendCommand("deleteTrigger", { index = index, id = t and t.id })
end

-- UI shortcut: reset trigger count at index
function EventTrigger.ResetTrigger(index)
    local t = EventTrigger.triggers[index]
    EventTrigger.SendCommand("resetTrigger", { index = index, id = t and t.id })
end

-- UI shortcut: delete all triggers (all=true all, otherwise only own)
function EventTrigger.DeleteAllTriggers(all)
    EventTrigger.SendCommand("deleteAllTriggers", { all = all })
end

-- ============================================================
-- Edit wizard (ISTextBox multi-step input)
-- Step 1: Edit message text
-- ============================================================
function EventTrigger.PromptEditMessage(index)
    EventTrigger._editIndex = index
    local t = EventTrigger.triggers[index]
    if not t then return end
    local modal = EventTriggerTextPrompt:new(
        "Edit Message",
        "Message (OK to continue)",
        t.message,
        function(text)
            EventTrigger.SendCommand("editTriggerMessage", {
                index = EventTrigger._editIndex,
                id = t and t.id,
                message = text,
            })
            EventTrigger.PromptEditDelayRange()
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Step 2: Edit delay, range, max triggers
function EventTrigger.PromptEditDelayRange()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local defaultText = string.format("%d, %.1f, %d", t.delay or 3, t.range or 2, t.maxTriggers or -1)
    local modal = EventTriggerTextPrompt:new(
        "Edit Params",
        "Delay(s), Range, MaxTriggers (-1=unlim, OK to continue)",
        defaultText,
        function(text)
            local parts = luautils.split(text, ",")
            local delay, range, maxTriggers
            if #parts >= 1 then delay = tonumber(parts[1]) end
            if #parts >= 2 then
                range = tonumber(parts[2])
                if range and range < 0.5 then range = 0.5 end
            end
            if #parts >= 3 then
                maxTriggers = tonumber(parts[3])
                if maxTriggers == 0 then maxTriggers = -1 end
            end
            EventTrigger.SendCommand("editTriggerParams", {
                index = idx,
                id = t and t.id,
                delay = delay,
                range = range,
                maxTriggers = maxTriggers,
            })
            EventTrigger.PromptEditOutput()
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Step 3: Edit output mode
function EventTrigger.PromptEditOutput()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local ot = t.outputType or EventTrigger.OutputType.HALO
    local modal = EventTriggerTextPrompt:new(
        "Edit Output",
        "Output: 1=Named 2=/say 3=/do 4=/low 5=/yell 6=/ooc 7=Above Head (current: " .. OutputTypeToName(ot) .. ")",
        tostring(ot),
        function(text)
            local val = tonumber(text)
            if val and val >= 1 and val <= 7 then
                EventTrigger.SendCommand("editTriggerOutput", {
                    index = idx,
                    id = t and t.id,
                    outputType = val,
                })
            end
            if val == EventTrigger.OutputType.NAMED then
                EventTrigger.PromptEditOutputName()
            else
                if EventTrigger._ui then EventTrigger._ui:refreshList() end
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Step 3b (Named mode only)
function EventTrigger.PromptEditOutputName()
    local idx = EventTrigger._editIndex
    local t = EventTrigger.triggers[idx]
    if not t then return end
    local cfg = EventTrigger.GetConfig()
    local current = t.outputName
    if not current or #current == 0 then current = cfg.outputName end
    local modal = EventTriggerTextPrompt:new(
        "Named Mode",
        "Display Name for Named mode",
        current,
        function(text)
            EventTrigger.SendCommand("editTriggerOutput", {
                index = idx,
                id = t and t.id,
                outputName = (text and #text > 0) and text or "",
            })
            if EventTrigger._ui then EventTrigger._ui:refreshList() end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Open trigger history window
function EventTrigger.ShowHistory(index)
    if EventTrigger._hist then
        EventTrigger._hist:close()
    end
    EventTrigger._hist = EventTriggerHistoryUI:new(index)
    EventTrigger._hist:initialise()
    EventTrigger._hist:addToUIManager()
end

-- ============================================================
-- UI layout system: supports XML loading (media/ui/EventTriggerLayout.xml),
-- falls back to hardcoded layout on failure
-- ============================================================

local LAYOUT = nil

-- Default hardcoded layout (XML fallback)
local function DefaultLayout()
    return {
        window = { x = 0, y = 0, w = 960, h = 520 },
        titleBar = { height = 28 },
        close = { type = "button", x = 935, y = 4, w = 21, h = 21, text = "X" },
        title = { type = "label", x = 480, y = 7, w = 0, h = 0, text = "EventTrigger Manager", center = true },
        header = { y = 32, height = 18 },
        headerCols = {
            { name = "index",     x = 8,   w = 24,  text = "#" },
            { name = "position",  x = 36,  w = 110, text = "Position" },
            { name = "message",   x = 150, w = 210, text = "Message" },
            { name = "detail",    x = 364, w = 160, text = "Delay/Range/Output" },
            { name = "creator",   x = 578, w = 100, text = "Creator" },
            { name = "triggered", x = 682, w = 90,  text = "Triggered" },
            { name = "actions",   x = 786, w = 138, text = "Actions" },
        },
        list = { x = 8, y = 52, w = 944, h = 396 },
        footer = { y = 485, height = 24 },
        add = { type = "button", x = 280, w = 130, h = 24, text = "Add Trigger" },
        addDelivery = { type = "button", x = 146, w = 126, h = 24, text = "Set Delivery Pt" },
        deleteAll = { type = "button", x = 418, w = 130, h = 24, text = "Delete All" },
        refresh = { type = "button", x = 556, w = 80, h = 24, text = "Refresh" },
        showAll = { type = "button", x = 644, w = 100, h = 24, text = "Show All" },
        row = { height = 28, buttonH = 20 },
        rowBtns = {
            edit = { w = 46, text = "Edit" },
            delete = { w = 22, text = "X" },
            reset = { w = 22, text = "R" },
            history = { w = 46, text = "Hist" },
        },
    }
end

-- Load XML layout file (wrapped in pcall, won't crash on malformed XML)
local function LoadLayout()
    if LAYOUT then return LAYOUT end

    local ok, xml = pcall(getXML, "media/ui/EventTriggerLayout.xml")
    if not ok or not xml then
        LAYOUT = DefaultLayout()
        return LAYOUT
    end

    local ok2, root = pcall(function() return xml:getDocumentElement() end)
    if not ok2 or not root then
        LAYOUT = DefaultLayout()
        return LAYOUT
    end

    LAYOUT = {}

    -- Safely read XML attribute (returns specified type or default)
    local function ga(e, attr, def)
        local ok3, v = pcall(function() return e:getAttribute(attr) end)
        if not ok3 or not v or #v == 0 then return def end
        local n = tonumber(v)
        if n then return n end
        return v
    end

    local ok4, cc = pcall(function() return root:getChildCount() end)
    if not ok4 then
        LAYOUT = DefaultLayout()
        return LAYOUT
    end

    -- Parse XML nodes: window / titleBar / header / list / footer / row
    for i = 0, cc - 1 do
        local ok5, child = pcall(function() return root:getChildByIndex(i) end)
        if not ok5 or not child then break end
        local ok6, tag = pcall(function() return child:getTagName() end)
        if not ok6 then break end

        if tag == "window" then
            LAYOUT.window = {
                x = ga(child, "x", 0), y = ga(child, "y", 0),
                w = ga(child, "w", 960), h = ga(child, "h", 520),
            }
        elseif tag == "titleBar" then
            LAYOUT.titleBar = { height = ga(child, "height", 28) }
            local ok7, tcc = pcall(function() return child:getChildCount() end)
            if ok7 then
                for j = 0, tcc - 1 do
                    local ok8, sub = pcall(function() return child:getChildByIndex(j) end)
                    if not ok8 or not sub then break end
                    local ok9, st = pcall(function() return sub:getTagName() end)
                    if not ok9 then break end
                    local name = ga(sub, "name", "")
                    if st == "button" then
                        LAYOUT[name] = {
                            type = "button",
                            x = ga(sub, "x", 0), y = ga(sub, "y", 0),
                            w = ga(sub, "w", 0), h = ga(sub, "h", 0),
                            text = ga(sub, "text", ""),
                        }
                    elseif st == "label" then
                        LAYOUT[name] = {
                            type = "label",
                            x = ga(sub, "x", 0), y = ga(sub, "y", 0),
                            w = ga(sub, "w", 0), h = ga(sub, "h", 0),
                            text = ga(sub, "text", ""),
                            center = ga(sub, "center", "false") == "true",
                        }
                    end
                end
            end
        elseif tag == "header" then
            LAYOUT.header = { y = ga(child, "y", 32), height = ga(child, "height", 18) }
            LAYOUT.headerCols = {}
            local ok10, hcc = pcall(function() return child:getChildCount() end)
            if ok10 then
                for j = 0, hcc - 1 do
                    local ok11, sub = pcall(function() return child:getChildByIndex(j) end)
                    if not ok11 or not sub then break end
                    local ok12, stag = pcall(function() return sub:getTagName() end)
                    if not ok12 then break end
                    if stag == "col" then
                        table.insert(LAYOUT.headerCols, {
                            name = ga(sub, "name", ""),
                            x = ga(sub, "x", 0),
                            w = ga(sub, "w", 0),
                            text = ga(sub, "text", ""),
                        })
                    end
                end
            end
        elseif tag == "list" then
            LAYOUT.list = {
                x = ga(child, "x", 8), y = ga(child, "y", 52),
                w = ga(child, "w", 944), h = ga(child, "h", 396),
            }
        elseif tag == "footer" then
            LAYOUT.footer = { y = ga(child, "y", 485), height = ga(child, "height", 24) }
            local ok13, fcc = pcall(function() return child:getChildCount() end)
            if ok13 then
                for j = 0, fcc - 1 do
                    local ok14, sub = pcall(function() return child:getChildByIndex(j) end)
                    if not ok14 or not sub then break end
                    local ok15, stag = pcall(function() return sub:getTagName() end)
                    if not ok15 then break end
                    if stag == "button" then
                        local name = ga(sub, "name", "")
                        LAYOUT[name] = {
                            type = "button",
                            x = ga(sub, "x", 0), y = LAYOUT.footer.y,
                            w = ga(sub, "w", 0), h = ga(sub, "h", 0),
                            text = ga(sub, "text", ""),
                        }
                    end
                end
            end
        elseif tag == "row" then
            LAYOUT.row = { height = ga(child, "height", 28), buttonH = ga(child, "buttonH", 20) }
            LAYOUT.rowBtns = {}
            local ok16, rcc = pcall(function() return child:getChildCount() end)
            if ok16 then
                for j = 0, rcc - 1 do
                    local ok17, sub = pcall(function() return child:getChildByIndex(j) end)
                    if not ok17 or not sub then break end
                    local ok18, stag = pcall(function() return sub:getTagName() end)
                    if not ok18 then break end
                    if stag == "button" then
                        local name = ga(sub, "name", "")
                        LAYOUT.rowBtns[name] = {
                            w = ga(sub, "w", 36),
                            text = ga(sub, "text", ""),
                        }
                    end
                end
            end
        end
    end
    return LAYOUT
end

-- ============================================================
-- EventTriggerUI — main manager panel (ISPanel-derived)
-- Shows trigger list with pagination, creator filtering, edit/delete/reset/history actions
-- ============================================================
EventTriggerUI = ISPanel:derive("EventTriggerUI")

function EventTriggerUI:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerUI:create()
    local layout = LoadLayout()
    local win = layout.window or { x = 0, y = 0, w = 960, h = 520 }
    local header = layout.header or { y = 32, height = 18 }
    local listArea = layout.list or { x = 8, y = 52, w = 944, h = 396 }
    local footer = layout.footer or { y = 485, height = 24 }
    local rowDef = layout.row or { height = 28, buttonH = 20 }

    self:setAlwaysOnTop(true)

    self.layout = layout
    self.headerY = header.y
    self.listX = listArea.x
    self.listY = listArea.y
    self.listW = listArea.w
    self.listH = listArea.h
    self.rowH = rowDef.height
    self.pageNum = 0

    -- SP: view all by default; MP: admin sees all, regular players see only own
    if not EventTrigger.IsMultiplayer() then
        self.viewAll = true
    else
        self.viewAll = EventTrigger.IsAdmin()
    end

    self.rows = {}
    self.rowData = {}
    self.rowCount = 0
    -- Alternating row background colors (improves readability)
    self.altColors = { {0.15,0.15,0.15}, {0.11,0.11,0.11} }

    -- Close button
    self.closeBtn = ISButton:new(
        (layout.close and layout.close.x) or 935,
        (layout.close and layout.close.y) or 4,
        (layout.close and layout.close.w) or 21,
        (layout.close and layout.close.h) or 21,
        (layout.close and layout.close.text) or "X",
        self, EventTriggerUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self:refreshList()

    -- Footer buttons
    local addDef = layout.add or { x = 246, w = 120, h = 24 }
    self.addBtn = ISButton:new(
        addDef.x, footer.y, addDef.w, addDef.h,
        addDef.text or "Add Trigger", self, EventTriggerUI.onAdd)
    self.addBtn:initialise()
    self:addChild(self.addBtn)

    -- "Set Delivery Point" button — disabled when delivery module failed to load.
    local dlvDef = layout.addDelivery or { x = 140, w = 100, h = 24 }
    self.addDeliveryBtn = ISButton:new(
        dlvDef.x, footer.y, dlvDef.w, dlvDef.h,
        dlvDef.text or "Set Delivery Pt", self, EventTriggerUI.onAddDelivery)
    self.addDeliveryBtn:initialise()
    if not EventTrigger.DeliveryLoaded then
        self.addDeliveryBtn:setEnable(false)
        self.addDeliveryBtn:setTitle("Delivery (unavailable)")
    end
    self:addChild(self.addDeliveryBtn)

    local delDef = layout.deleteAll or { x = 374, w = 130, h = 24 }
    self.delAllBtn = ISButton:new(
        delDef.x, footer.y, delDef.w, delDef.h,
        delDef.text or "Delete All", self, EventTriggerUI.onDeleteAll)
    self.delAllBtn:initialise()
    self:addChild(self.delAllBtn)

    local refDef = layout.refresh or { x = 512, w = 80, h = 24 }
    self.refreshBtn = ISButton:new(
        refDef.x, footer.y, refDef.w, refDef.h,
        refDef.text or "Refresh", self, EventTriggerUI.onRefresh)
    self.refreshBtn:initialise()
    self:addChild(self.refreshBtn)

    -- "Show All" button, visible in MP for admins, toggles view all/own triggers
    local showDef = layout.showAll or { x = 644, w = 100, h = 24 }
    self.showAllBtn = ISButton:new(
        showDef.x, footer.y, showDef.w, showDef.h,
        "Show All", self, EventTriggerUI.onToggleView)
    self.showAllBtn:initialise()
    -- Hidden in SP, admin-only in MP
    self.showAllBtn:setVisible(EventTrigger.IsMultiplayer() and EventTrigger.IsAdmin())
    self:addChild(self.showAllBtn)

    -- Pagination buttons
    local pgX = self:getWidth() - 120
    self.prevPageBtn = ISButton:new(pgX, footer.y, 24, 24, "<", self, EventTriggerUI.onPrevPage)
    self.prevPageBtn:initialise()
    self:addChild(self.prevPageBtn)

    self.nextPageBtn = ISButton:new(pgX + 28, footer.y, 24, 24, ">", self, EventTriggerUI.onNextPage)
    self.nextPageBtn:initialise()
    self:addChild(self.nextPageBtn)

    self:updatePageButtons()
end

-- Get filtered triggers by creator
-- SP: show all; MP: show all or own based on viewAll flag
function EventTriggerUI:getFilteredTriggers()
    local all = EventTrigger.triggers
    local allDlv = EventTrigger.deliveryPoints or {}

    local function buildList()
        local list = {}
        -- Add regular triggers
        for i, t in ipairs(all) do
            table.insert(list, { trigger = t, index = i })
        end
        -- Add delivery points (offset index for display, starting after triggers)
        for i, dp in ipairs(allDlv) do
            if dp and dp.type == "delivery" then
                table.insert(list, { trigger = dp, index = #all + i, _isDelivery = true, _dlvIndex = i })
            end
        end
        return list
    end

    -- SP always shows all
    if not EventTrigger.IsMultiplayer() then
        return buildList()
    end

    -- MP: show all or filter by creator
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

-- Calculate rows per page
function EventTriggerUI:rowsPerPage()
    return math.max(1, math.floor(self.listH / self.rowH))
end

-- Calculate total pages
function EventTriggerUI:totalPages()
    local list = self:getFilteredTriggers()
    return math.max(1, math.ceil(#list / self:rowsPerPage()))
end

-- Update pagination button visibility and enabled state
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

-- Clear all row controls from list
function EventTriggerUI:clearList()
    for _, child in ipairs(self.rows) do
        child:removeFromUIManager()
        if self.removeChild then self:removeChild(child) end
    end
    self.rows = {}
    self.rowData = {}
    self.rowCount = 0
end

-- Refresh list content (clear then rebuild rows for current page)
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

-- Add a trigger/delivery data row to list (text labels + action buttons)
function EventTriggerUI:addRow(entry)
    local t = entry.trigger
    local index = entry.index
    local isDlv = entry._isDelivery
    local layout = self.layout
    local rowDef = layout.row or { height = 28, buttonH = 20 }
    local rowBtns = layout.rowBtns or {}
    local headerCols = layout.headerCols or {}
    local rowIdx = self.rowCount
    self.rowCount = self.rowCount + 1
    local y = self.listY + rowIdx * rowDef.height

    local colIndex = headerCols[1] or { x = 8, w = 24 }
    local colPos   = headerCols[2] or { x = 36, w = 110 }
    local colMsg   = headerCols[3] or { x = 150, w = 210 }
    local colDet   = headerCols[4] or { x = 364, w = 160 }
    local colCreat = headerCols[5] or { x = 528, w = 100 }
    local colTrig  = headerCols[6] or { x = 632, w = 90 }
    local colActs  = headerCols[7] or { x = 726, w = 138 }

    -- Row background color: delivery points get a distinct tint
    local bgColor = isDlv and {0.08, 0.06, 0.12} or {0.08, 0.08, 0.08}

    if isDlv then
        -- Delivery point row
        local count = t.triggerCount or 0
        local completed = count > 0
        local exhausted = completed  -- delivery is one-time if completed
        local reqCount = t.requiredItems and #t.requiredItems or 0
        local rewCount = t.rewardItems and #t.rewardItems or 0

        self.rowData[index] = {
            y = y,
            cols = {
                { x = colIndex.x,     w = colIndex.w,   text = "[D]" .. tostring(index) .. ".",  color = {0.8,0.5,1} },
                { x = colPos.x + 4,   w = colPos.w,    text = string.format("(%d,%d,%d)", t.x, t.y, t.z), color = {0.5,0.8,1} },
                { x = colMsg.x + 4,   w = colMsg.w,    text = (#(t.hintText or "") > 28) and (t.hintText:sub(1,25) .. "...") or (t.hintText or "DP"), color = {0.8,0.8,1} },
                { x = colDet.x + 4,   w = colDet.w,    text = "R=" .. string.format("%.1f", t.range or 3) .. "  Req:" .. reqCount .. "  Rew:" .. rewCount, color = {0.7,0.7,1} },
                { x = colCreat.x + 4, w = colCreat.w,  text = t.creator or "?", color = {0.8,0.8,0.5} },
            },
            _isDelivery = true,
            _bgColor = bgColor,
        }

        local cntStr = completed and "DONE" or "READY"
        local cntColor = completed and {0.5,1,0.5} or {1,1,0.3}
        self.rowData[index].cols[#self.rowData[index].cols + 1] = {
            x = colTrig.x + 4, w = colTrig.w, text = cntStr, color = cntColor,
        }
    else
        -- Regular trigger row
        local exhausted = t.maxTriggers > 0 and (t.triggerCount or 0) >= t.maxTriggers

        self.rowData[index] = {
            y = y,
            cols = {
                { x = colIndex.x,     w = colIndex.w,   text = tostring(index) .. ".",              color = {1,1,1} },
                { x = colPos.x + 4,   w = colPos.w,    text = string.format("(%d,%d,%d)", t.x, t.y, t.z), color = {0.5,0.8,1} },
                { x = colMsg.x + 4,   w = colMsg.w,    text = (#(t.message or "") > 30) and (t.message:sub(1,27) .. "...") or (t.message or ""), color = {1,1,1} },
                { x = colDet.x + 4,   w = colDet.w,    text = OutputTypeToName(t.outputType) .. "  D=" .. (t.delay or 3) .. " R=" .. string.format("%.1f", t.range or 2), color = {0.7,0.7,1} },
                { x = colCreat.x + 4, w = colCreat.w,  text = t.creator or "?", color = {0.8,0.8,0.5} },
            },
            _bgColor = bgColor,
        }
        local cntStr = "x" .. (t.triggerCount or 0)
        if exhausted then
            cntStr = cntStr .. " DONE"
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
            x = colTrig.x + 4, w = colTrig.w, text = cntStr .. who, color = cntColor,
        }
    end

    local bx = colActs.x + 20

    local editDef = rowBtns.edit or { w = 36 }
    local editBtn = ISButton:new(bx, y + 4, editDef.w, rowDef.buttonH,
        editDef.text or "Edit", self, EventTriggerUI.onEditRow)
    editBtn:initialise()
    editBtn.idx = index
    editBtn.entry = entry
    self:addChild(editBtn)
    table.insert(self.rows, editBtn)
    bx = bx + editDef.w + 2

    local delDef = rowBtns.delete or { w = 22 }
    local delBtn = ISButton:new(bx, y + 4, delDef.w, rowDef.buttonH,
        delDef.text or "X", self, EventTriggerUI.onDeleteRow)
    delBtn:initialise()
    delBtn.idx = index
    delBtn.entry = entry
    self:addChild(delBtn)
    table.insert(self.rows, delBtn)
    bx = bx + delDef.w + 2

    local rstDef = rowBtns.reset or { w = 22 }
    local rstBtn = ISButton:new(bx, y + 4, rstDef.w, rowDef.buttonH,
        rstDef.text or "R", self, EventTriggerUI.onResetRow)
    rstBtn:initialise()
    rstBtn.idx = index
    rstBtn.entry = entry
    self:addChild(rstBtn)
    table.insert(self.rows, rstBtn)
    bx = bx + rstDef.w + 2

    local histDef = rowBtns.history or { w = 46 }
    local histBtn = ISButton:new(bx, y + 4, histDef.w, rowDef.buttonH,
        histDef.text or "Hist", self, EventTriggerUI.onHistoryRow)
    histBtn:initialise()
    histBtn.idx = index
    histBtn.entry = entry
    self:addChild(histBtn)
    table.insert(self.rows, histBtn)
end

-- Title bar drag: start drag when clicking title area
function EventTriggerUI:onMouseDown(x, y)
    local titleH = (self.layout.titleBar and self.layout.titleBar.height) or 28
    if y >= 0 and y < titleH then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

-- Drag move window
function EventTriggerUI:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

-- End drag
function EventTriggerUI:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

-- Button callback: edit row trigger
function EventTriggerUI:onEditRow(btn)
    if btn.entry and btn.entry._isDelivery then
        -- Edit delivery point: re-open setup wizard at its position
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

-- Button callback: delete row trigger/delivery
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

-- Button callback: reset row trigger count / delivery completion
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

-- Button callback: view row trigger history / delivery details
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

-- Button callback: add new trigger at current position (start wizard)
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

-- Button callback: delete all triggers (admin+viewAll = all, otherwise own only)
function EventTriggerUI:onDeleteAll()
    EventTrigger.DeleteAllTriggers(EventTrigger.IsAdmin() and self.viewAll)
end

-- Button callback: manual refresh list
function EventTriggerUI:onRefresh()
    if EventTrigger.IsMultiplayer() then
        EventTrigger.RequestSync()
    else
        EventTrigger.RebuildList()
    end
    self:refreshList()
end

-- Button callback: toggle "Show All"/"Show Mine" view
function EventTriggerUI:onToggleView()
    self.viewAll = not self.viewAll
    self.showAllBtn:setTitle(self.viewAll and "Show Mine" or "Show All")
    if EventTrigger.IsMultiplayer() then
        EventTrigger.RequestSync(true)
    end
    self.pageNum = 0
    self:refreshList()
end

-- Button callback: previous page
function EventTriggerUI:onPrevPage()
    if self.pageNum > 0 then
        self.pageNum = self.pageNum - 1
        self:refreshList()
    end
end

-- Button callback: next page
function EventTriggerUI:onNextPage()
    if self.pageNum < self:totalPages() - 1 then
        self.pageNum = self.pageNum + 1
        self:refreshList()
    end
end

-- Close window callback
function EventTriggerUI:onClose()
    self:close()
end

-- Close window and remove from UIManager
function EventTriggerUI:close()
    if EventTrigger._ui == self then EventTrigger._ui = nil end
    self:setVisible(false)
    self:removeFromUIManager()
end

-- Per-frame UI draw (border, title, header, background, row data, pagination, mode indicator)
function EventTriggerUI:prerender()
    ISPanel.prerender(self)

    local layout = self.layout
    local win = layout.window or { w = 960, h = 520 }
    local header = layout.header or { y = 32, height = 18 }
    local headerCols = layout.headerCols or {}
    local listArea = layout.list or { x = 8, y = 52, w = 944, h = 396 }

    self:drawRectBorder(0, 0, self.width, win.h, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)

    local tt = (layout.title and layout.title.text) or "EventTrigger Manager"
    self:drawTextCentre(tt, self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local divY = header.y + header.height + 2
    self:drawRect(8, divY, self:getWidth() - 30, 1, 0.7, 0.4, 0.4, 0.4)

    for _, col in ipairs(headerCols) do
        self:drawText(col.text, col.x + 4, header.y + 1, 0.5, 0.5, 0.5, 1, UIFont.Small)
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
            for _, col in ipairs(rd.cols) do
                self:drawText(col.text, col.x, rd.y + 5, col.color[1], col.color[2], col.color[3], 1, UIFont.Small)
            end
        end
    end

    -- Empty list hint
    if total == 0 then
        local txt = "No triggers yet. Right-click ground with EventTriggerTool to place one."
        self:drawTextCentre(txt, self.width / 2, self.listY + 20, 0.45, 0.45, 0.45, 1, UIFont.Small)
    end

    -- Pagination indicator (only when content spans multiple pages)
    if total > rpp then
        local pgText = string.format("Page %d/%d", self.pageNum + 1, tp)
        self:drawTextRight(pgText, self:getWidth() - 130, 452, 0.6, 0.6, 0.6, 1, UIFont.Small)
    end

    -- Top-right mode indicator (Server/Local)
    local modeText = EventTrigger.IsMultiplayer() and "Server" or "Local"
    self:drawTextRight("Mode: " .. modeText, self:getWidth() - 10, 8, 0.4, 0.4, 0.4, 1, UIFont.Small)
end

-- EventTriggerUI constructor: create centered main management panel
function EventTriggerUI:new()
    local layout = LoadLayout()
    local win = layout.window or { x = 0, y = 0, w = 960, h = 520 }
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x, y = (sw - win.w) / 2, (sh - win.h) / 2

    local o = ISPanel:new(x, y, win.w, win.h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.85 }
    o.width = win.w
    o.height = win.h
    o.dragging = false
    return o
end

-- ============================================================
-- EventTriggerHistoryUI — trigger history viewer (ISPanel-derived)
-- Shows trigger info and all trigger records (who triggered it and when)
-- ============================================================
EventTriggerHistoryUI = ISPanel:derive("EventTriggerHistoryUI")

function EventTriggerHistoryUI:initialise()
    ISPanel.initialise(self)
    self:create()
end

-- Build history UI: trigger summary + trigger record list
function EventTriggerHistoryUI:create()
    self:setAlwaysOnTop(true)

    self.lines = {}
    local y = 40

    -- Close button
    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerHistoryUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    -- Find trigger, show error if not found
    local t = EventTrigger.triggers[self.triggerIndex]
    if not t then
        self.lines[#self.lines + 1] = { x = 10, y = y, text = "Trigger not found.", color = {1,0.5,0.5} }
        return
    end

    -- Trigger info summary line
    self.lines[#self.lines + 1] = {
        x = 10, y = y, text = string.format("Position: (%d,%d,%d)  Message: %s  Creator: %s", t.x, t.y, t.z, t.message or "", t.creator or "?"),
        color = {0.7,0.8,1},
    }
    y = y + 24

    -- Trigger history list
    local triggeredBy = t.triggeredBy or {}
    if #triggeredBy == 0 then
        self.lines[#self.lines + 1] = { x = 10, y = y, text = "No triggers recorded yet.", color = {0.5,0.5,0.5} }
    else
        self.lines[#self.lines + 1] = {
            x = 10, y = y, text = "Total: " .. #triggeredBy .. " trigger(s)", color = {1,1,1},
        }
        y = y + 22

        -- Display each trigger history entry
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
            self.lines[#self.lines + 1] = { x = 20, y = y, text = line, color = {0.8,0.9,1} }
            y = y + 20
            if y > self.height - 30 then break end
        end
    end
end

-- Close history window
function EventTriggerHistoryUI:onClose()
    self:close()
end

-- Remove from UIManager
function EventTriggerHistoryUI:close()
    if EventTrigger._hist == self then EventTrigger._hist = nil end
    self:setVisible(false)
    self:removeFromUIManager()
end

-- Title bar drag
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

-- Drag move
function EventTriggerHistoryUI:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

-- End drag
function EventTriggerHistoryUI:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

-- Per-frame history window draw (border, title bar, trigger record text)
function EventTriggerHistoryUI:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)

    local titleStr = string.format("Trigger #%d - History", self.triggerIndex)
    self:drawTextCentre(titleStr, self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    for _, line in ipairs(self.lines) do
        self:drawText(line.text, line.x, line.y, line.color[1], line.color[2], line.color[3], 1, UIFont.Small)
    end
end

-- EventTriggerHistoryUI constructor
function EventTriggerHistoryUI:new(index)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w, h = 500, 350
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
-- EventTriggerUI delivery integration (delegated to EventTriggerDelivery)
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
-- Event registration: bind core functions to PZ game events
-- Load order: OnGameStart → OnTick (per-frame) → context menu → server commands
-- ============================================================
Events.OnTick.Add(EventTrigger.OnTick)
Events.OnFillWorldObjectContextMenu.Add(EventTrigger.OnFillWorldObjectContextMenu)
Events.OnServerCommand.Add(EventTrigger.OnServerCommand)

-- First tick auto-request sync (BulletinBoard pattern, no OnGameStart)
-- Fires on server join and reconnect
local _etFirstTickDone = false
local function onFirstTick()
    if _etFirstTickDone then return end
    _etFirstTickDone = true
    EventTrigger.Load()
    Events.OnTick.Remove(onFirstTick)
end
Events.OnTick.Add(onFirstTick)
