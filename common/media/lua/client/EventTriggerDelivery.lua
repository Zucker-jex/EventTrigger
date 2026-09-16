-- ============================================================
-- EventTriggerDelivery.lua — Delivery Point System
-- Inventory item selection UI, dual-match execution, flow UIs
-- Reference: bak\EventTrigger_new UI/interaction design
-- ============================================================

require "ISUI/ISTextBox"

EventTrigger = EventTrigger or {}
EventTrigger.Delivery = EventTrigger.Delivery or {}

local dbg = function(...)
    if EventTrigger.DEBUG then
        print("[EventTrigger-DELIVERY]", ...)
    end
end

-- ============================================================
-- Section 1: Dual Matching Algorithm (FullType + DisplayName)
-- ============================================================
function EventTrigger.Delivery.MatchItem(item, fullType, displayName)
    if not item then return false end
    return item:getFullType() == fullType and item:getDisplayName() == displayName
end

-- ============================================================
-- Count matching items in player inventory (FullType + DisplayName)
-- ============================================================
function EventTrigger.Delivery.CountItems(inventory, requiredItems)
    local counts = {}
    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            for _, req in ipairs(requiredItems) do
                if item:getFullType() == req.fullType and item:getDisplayName() == req.displayName then
                    local key = req.fullType .. "|" .. req.displayName
                    counts[key] = (counts[key] or 0) + 1
                end
            end
        end
    end
    return counts
end

-- ============================================================
-- Remove items from inventory (collect first, then remove — safe for MP ArrayList)
-- Only removes items where req.collect ~= false
-- matchMode: "all" = remove all matching items, "any" = remove only selected matching item
-- selectedORIndex: index of selected required item in OR mode (1-based)
-- ============================================================
function EventTrigger.Delivery.RemoveItems(inventory, requiredItems, matchMode, selectedORIndex)
    local removedData = {}
    local items = inventory:getItems()
    matchMode = matchMode or "all"

    -- Phase 1: collect item references (no ArrayList modification during iteration)
    local toRemoveList = {}
    
    if matchMode == "any" then
        -- OR mode: only remove from the selected required item
        local targetIdx = selectedORIndex or 1
        for idx, req in ipairs(requiredItems) do
            if req.collect ~= false and idx == targetIdx then
                local remaining = req.count
                for i = items:size() - 1, 0, -1 do
                    if remaining <= 0 then break end
                    local item = items:get(i)
                    if item and item:getFullType() == req.fullType and item:getDisplayName() == req.displayName then
                        toRemoveList[#toRemoveList + 1] = item
                        remaining = remaining - 1
                    end
                end
                break
            end
        end
    else
        -- AND mode: collect from all required items
        for _, req in ipairs(requiredItems) do
            if req.collect ~= false then
                local remaining = req.count
                for i = items:size() - 1, 0, -1 do
                    if remaining <= 0 then break end
                    local item = items:get(i)
                    if item and item:getFullType() == req.fullType and item:getDisplayName() == req.displayName then
                        toRemoveList[#toRemoveList + 1] = item
                        remaining = remaining - 1
                    end
                end
            end
        end
    end

    -- Phase 2: safe removal (collected references, no iteration conflict)
    for _, item in ipairs(toRemoveList) do
        table.insert(removedData, {
            fullType = item:getFullType(),
            displayName = item:getDisplayName(),
        })
        inventory:Remove(item)
    end

    return removedData
end

-- ============================================================
-- Grant reward items, return success. On failure, rollback all.
-- Uses inventory:AddItem(fullTypeString) pattern from bak.
-- ============================================================
function EventTrigger.Delivery.GrantRewards(inventory, rewardItems)
    local created = {}
    for _, reward in ipairs(rewardItems) do
        for _ = 1, reward.count do
            local instance = inventory:AddItem(reward.fullType)
            if instance then
                if reward.displayName and #reward.displayName > 0 then
                    instance:setName(reward.displayName)
                end
                table.insert(created, instance)
            else
                dbg("GrantRewards: AddItem returned nil for " .. reward.fullType .. " - rolling back " .. #created .. " items")
                for _, c in ipairs(created) do
                    inventory:Remove(c)
                end
                return false
            end
        end
    end
    return true
end

-- ============================================================
-- Full atomic delivery execution
-- ============================================================
function EventTrigger.Delivery.Execute(player, deliveryData)
    if not player or not deliveryData then return false, "Invalid data" end
    local inventory = player:getInventory()
    local requiredItems = deliveryData.requiredItems or {}
    local rewardItems = deliveryData.rewardItems or {}
    local matchMode = deliveryData.matchMode or "all"
    local selectedORIndex = deliveryData._selectedORItemIndex

    -- Pre-check counts (FullType + DisplayName dual-match)
    local counts = EventTrigger.Delivery.CountItems(inventory, requiredItems)
    
    if matchMode == "any" then
        -- OR logic: player needs at least ONE of the required items
        local hasAny = false
        for _, req in ipairs(requiredItems) do
            local key = req.fullType .. "|" .. req.displayName
            if (counts[key] or 0) >= req.count then
                hasAny = true
                break
            end
        end
        if not hasAny then
            return false, "Missing required items in backpack!"
        end
    else
        -- AND logic (default): player needs ALL required items
        for _, req in ipairs(requiredItems) do
            local key = req.fullType .. "|" .. req.displayName
            if (counts[key] or 0) < req.count then
                return false, "Missing required items in backpack!"
            end
        end
    end

    -- Check cooldown
    local cooldownOk, cooldownMsg = EventTrigger.Delivery.CheckCooldown(player, deliveryData)
    if not cooldownOk then
        return false, cooldownMsg
    end

    -- Remove required items (only for items that match in OR mode, or all in AND mode)
    local removedData = EventTrigger.Delivery.RemoveItems(inventory, requiredItems, matchMode, selectedORIndex)

    -- Grant rewards (with rollback on failure)
    local granted = EventTrigger.Delivery.GrantRewards(inventory, rewardItems)
    if not granted then
        -- Rollback removed items
        for _, data in ipairs(removedData) do
            local instance = inventory:AddItem(data.fullType)
            if instance and data.displayName and #data.displayName > 0 then
                instance:setName(data.displayName)
            end
        end
        return false, "Not enough backpack space!"
    end

    return true, "Delivery completed successfully!"
end

-- ============================================================
-- Client-side dual-match validation (no inventory changes)
-- ============================================================
function EventTrigger.Delivery.Validate(player, deliveryData)
    if not player or not deliveryData then return false, "Invalid data" end
    local inventory = player:getInventory()
    local requiredItems = deliveryData.requiredItems or {}
    local matchMode = deliveryData.matchMode or "all"
    local counts = EventTrigger.Delivery.CountItems(inventory, requiredItems)
    
    if matchMode == "any" then
        -- OR logic: player needs at least ONE of the required items
        local hasAny = false
        for _, req in ipairs(requiredItems) do
            local key = req.fullType .. "|" .. req.displayName
            if (counts[key] or 0) >= req.count then
                hasAny = true
                break
            end
        end
        if not hasAny then
            return false, "Missing required items in backpack!"
        end
    else
        -- AND logic (default): player needs ALL required items
        for _, req in ipairs(requiredItems) do
            local key = req.fullType .. "|" .. req.displayName
            if (counts[key] or 0) < req.count then
                return false, "Missing required items in backpack!"
            end
        end
    end
    
    -- Check cooldown
    local cooldownOk, cooldownMsg = EventTrigger.Delivery.CheckCooldown(player, deliveryData)
    if not cooldownOk then
        return false, cooldownMsg
    end
    
    return true, ""
end

-- ============================================================
-- Check cooldown for delivery
-- ============================================================
function EventTrigger.Delivery.CheckCooldown(player, deliveryData)
    local cooldownType = deliveryData.cooldownType or 0
    local cooldownValue = deliveryData.cooldownValue or 0
    if cooldownType == 0 or cooldownValue <= 0 then
        return true, ""
    end
    
    local playerKey = player:getUsername() or tostring(player:getOnlineID())
    local playerCooldowns = deliveryData.playerCooldowns or {}
    local lastDelivery = playerCooldowns[playerKey]
    if not lastDelivery then
        return true, ""
    end
    
    local now
    if cooldownType == 1 then
        -- Game time (in minutes)
        now = getGameTime():getWorldAgeHours() * 60
    else
        -- Real time (in minutes)
        now = os.time() / 60
    end
    
    local elapsed = now - lastDelivery
    if elapsed < cooldownValue then
        local remaining = math.ceil(cooldownValue - elapsed)
        return false, string.format("Cooldown active! Wait %d more minutes.", remaining)
    end
    
    return true, ""
end

-- ============================================================
-- Delivery Point Detection (trigger-point method: state on dp object)
-- ============================================================
EventTrigger.Delivery._activePrompt = {}   -- playerKey -> dpId (only one UI at a time, player-global)
EventTrigger.Delivery._pendingDpId = {}    -- playerKey -> dpId (which dp is in delivery flow)

function EventTrigger.Delivery.ResetPrompt(playerKey)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
end

function EventTrigger.Delivery.CheckPlayerInRange(player)
    if not player then return end
    local playerKey = player:getUsername() or tostring(player:getOnlineID())
    if not playerKey or #playerKey == 0 then return end

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    if not px then return end

    for _, dp in ipairs(EventTrigger.deliveryPoints or {}) do
        if dp and dp.type == "delivery" then

            local dx, dy = px - (dp.x or 0), py - (dp.y or 0)
            local dist = math.sqrt(dx*dx + dy*dy)
            local inRange = (pz == (dp.z or 0)) and (dist < (dp.range or 3.0))

            -- Ensure _dlvPrompted table exists on dp (syncAll may have reset it; PlacePending sets it)
            if not dp._dlvPrompted then dp._dlvPrompted = {} end

            if inRange then
                if not dp._dlvPrompted[playerKey] and not EventTrigger.Delivery._activePrompt[playerKey] then
                    local maxP = dp.maxPlayers or -1
                    local maxPP = dp.maxPerPlayer or -1
                    local canTrigger = true
                    local pdl = dp.playerDeliveries or {}
                    local myCount = pdl[playerKey] or 0
                    if maxPP ~= -1 and myCount >= maxPP then
                        canTrigger = false
                    end
                    if canTrigger and maxP ~= -1 then
                        local uniquePlayers = 0
                        for _, _ in pairs(pdl) do
                            uniquePlayers = uniquePlayers + 1
                        end
                        if uniquePlayers >= maxP and not pdl[playerKey] then
                            canTrigger = false
                        end
                    end
                    if canTrigger then
                        dp._dlvPrompted[playerKey] = true
                        EventTrigger.Delivery._activePrompt[playerKey] = dp.id
                        EventTrigger.Delivery._pendingDpId[playerKey] = dp.id
                        HaloTextHelper.addGoodText(player, dp.hintText or "Delivery Point")
                        EventTrigger.Delivery.ShowDeliveryPrompt(dp)
                    end
                end
            else
                -- Player left range: clear this dp's prompt state
                dp._dlvPrompted[playerKey] = nil
                if EventTrigger.Delivery._activePrompt[playerKey] == dp.id then
                    EventTrigger.Delivery._activePrompt[playerKey] = nil
                end
            end

        end
    end
end

-- ============================================================
-- Delivery Prompt UI (Yes/No modal)
-- ============================================================
function EventTrigger.Delivery.ShowDeliveryPrompt(dp)
    if EventTrigger.Delivery._promptUI then
        EventTrigger.Delivery._promptUI:close()
    end
    local ui = EventTriggerDeliveryPrompt:new(dp)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._promptUI = ui
end

EventTriggerDeliveryPrompt = ISPanel:derive("EventTriggerDeliveryPrompt")

function EventTriggerDeliveryPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerDeliveryPrompt:create()
    self:setAlwaysOnTop(true)

    local bw, bh = 100, 30
    local gap = 20
    local totalW = bw * 2 + gap
    local btnY = self.height - 60
    local yesX = (self.width - totalW) / 2
    local noX = yesX + bw + gap

    self.yesBtn = ISButton:new(yesX, btnY, bw, bh, "Yes", self, EventTriggerDeliveryPrompt.onYes)
    self.yesBtn:initialise()
    self:addChild(self.yesBtn)

    self.noBtn = ISButton:new(noX, btnY, bw, bh, "No", self, EventTriggerDeliveryPrompt.onNo)
    self.noBtn:initialise()
    self:addChild(self.noBtn)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryPrompt.onNo)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
end

function EventTriggerDeliveryPrompt:onYes()
    self:close()
    local player = getPlayer()
    local playerKey = player and (player:getUsername() or "")
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
    end
    if player and self.dp then
        EventTrigger.Delivery.ShowDeliveryConfirm(player, self.dp)
    end
end

function EventTriggerDeliveryPrompt:onNo()
    local player = getPlayer()
    local playerKey = player and (player:getUsername() or "")
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    self:close()
end

function EventTriggerDeliveryPrompt:close()
    if EventTrigger.Delivery._promptUI == self then
        EventTrigger.Delivery._promptUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerDeliveryPrompt:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerDeliveryPrompt:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerDeliveryPrompt:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerDeliveryPrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre("Delivery Prompt", self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local hint = self.dp and self.dp.hintText or "Delivery Point"
    local promptText = "Delivery point detected:\n\"" .. hint .. "\"\n\nProceed with delivery?"
    local y = 45
    for line in (promptText .. "\n"):gmatch("([^\n]*)\n") do
        if line and #line > 0 then
            self:drawTextCentre(line, self.width / 2, y, 1, 1, 1, 1, UIFont.Small)
        end
        y = y + 22
    end
end

function EventTriggerDeliveryPrompt:new(dp)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w, h = 400, 200
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.width = w
    o.height = h
    o.dp = dp
    o.dragging = false
    return o
end

-- ============================================================
-- Delivery Confirm UI (shows required & reward items, Confirm/Cancel)
-- ============================================================
function EventTrigger.Delivery.ShowDeliveryConfirm(player, delivery)
    if EventTrigger.Delivery._confirmUI then
        EventTrigger.Delivery._confirmUI:close()
    end
    if EventTrigger.Delivery._itemSelectUI then
        EventTrigger.Delivery._itemSelectUI:close()
    end
    
    local matchMode = delivery.matchMode or "all"
    if matchMode == "any" then
        -- Check if there are multiple matching items with collect=true
        local collectCount = 0
        for _, req in ipairs(delivery.requiredItems or {}) do
            if req.collect ~= false then
                collectCount = collectCount + 1
            end
        end
        if collectCount > 1 then
            -- Show item selection UI for OR mode
            EventTrigger.Delivery.ShowItemSelectForOR(player, delivery)
            return
        end
    end
    
    local ui = EventTriggerDeliveryConfirm:new(player, delivery)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._confirmUI = ui
end

EventTriggerDeliveryConfirm = ISPanel:derive("EventTriggerDeliveryConfirm")

function EventTriggerDeliveryConfirm:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerDeliveryConfirm:create()
    self:setAlwaysOnTop(true)

    local bw, bh = 120, 30
    local gap = 20
    local totalW = bw * 2 + gap
    local btnY = self.height - 50
    local confX = (self.width - totalW) / 2
    local cancX = confX + bw + gap

    self.confirmBtn = ISButton:new(confX, btnY, bw, bh, "Confirm", self, EventTriggerDeliveryConfirm.onConfirm)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)

    self.cancelBtn = ISButton:new(cancX, btnY, bw, bh, "Cancel", self, EventTriggerDeliveryConfirm.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryConfirm.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self.itemY = 36
end

function EventTriggerDeliveryConfirm:onConfirm()
    local player = getPlayer()
    local delivery = self.delivery
    if not player or not delivery then
        dbg("onConfirm: missing player or delivery, abort")
        self:close()
        return
    end

    local playerKey = player:getUsername() or ""
    EventTrigger.Delivery._activePrompt[playerKey] = nil
    EventTrigger.Delivery._pendingDpId[playerKey] = nil
    self:close()

    -- Determine selectedORIndex for OR mode
    local matchMode = delivery.matchMode or "all"
    local selectedORIndex = nil
    if matchMode == "any" then
        local collectCount = 0
        local targetIdx = nil
        for idx, req in ipairs(delivery.requiredItems or {}) do
            if req.collect ~= false then
                collectCount = collectCount + 1
                targetIdx = idx
            end
        end
        if collectCount == 1 then
            selectedORIndex = targetIdx
        end
    end

    if EventTrigger.IsMultiplayer() then
        -- Client validates (dual-match), server executes all inventory (PZ Marketplace pattern)
        local ok, msg = EventTrigger.Delivery.Validate(player, delivery)
        if not ok then
            HaloTextHelper.addBadText(player, msg)
            return
        end
        local args = { id = delivery.id }
        if selectedORIndex then
            args.selectedORIndex = selectedORIndex
        end
        sendClientCommand("EventTrigger", "confirmDelivery", args)
    else
        if selectedORIndex then
            delivery._selectedORItemIndex = selectedORIndex
        end
        local ok, msg = EventTrigger.Delivery.Execute(player, delivery)
        if ok then
            HaloTextHelper.addGoodText(player, msg)
            delivery.triggerCount = (delivery.triggerCount or 0) + 1
            if not delivery.triggeredBy then delivery.triggeredBy = {} end
            if not delivery.playerDeliveries then delivery.playerDeliveries = {} end
            delivery.playerDeliveries[playerKey] = (delivery.playerDeliveries[playerKey] or 0) + 1
            local ts, tsStr = EventTrigger.GetTimestamp()
            table.insert(delivery.triggeredBy, { playerId = playerKey, timestamp = ts, timeStr = tsStr })
            EventTrigger._saveToModData()
        else
            HaloTextHelper.addBadText(player, msg)
        end
    end
end

function EventTriggerDeliveryConfirm:onCancel()
    local player = getPlayer()
    local playerKey = player and (player:getUsername() or "")
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    self:close()
end

function EventTriggerDeliveryConfirm:close()
    if EventTrigger.Delivery._confirmUI == self then
        EventTrigger.Delivery._confirmUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerDeliveryConfirm:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerDeliveryConfirm:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerDeliveryConfirm:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerDeliveryConfirm:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre("Delivery Confirmation", self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local delivery = self.delivery
    if not delivery then return end

    local midX = self.width / 2
    local leftX = 10
    local rightX = midX + 10
    local y = self.itemY

    -- Show match mode and cooldown info
    local modeText = "Match Mode: " .. (delivery.matchMode == "any" and "ANY (OR logic)" or "ALL (AND logic)")
    self:drawText(modeText, leftX, y, 0.9, 0.9, 0.3, 1, UIFont.Small)
    y = y + 20
    
    if delivery.cooldownType and delivery.cooldownType > 0 and delivery.cooldownValue > 0 then
        local cdText = "Cooldown: " .. (delivery.cooldownType == 1 and "Game Time" or "Real Time") .. " " .. delivery.cooldownValue .. " min"
        self:drawText(cdText, leftX, y, 0.7, 0.9, 0.7, 1, UIFont.Small)
        y = y + 20
    end

    -- Left: Required Items
    self:drawText("--- Required Items ---", leftX, y, 0.9, 0.7, 0.3, 1, UIFont.Small)
    y = y + 20
    local reqItems = delivery.requiredItems or {}
    if #reqItems == 0 then
        self:drawText("(none)", leftX + 8, y, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for _, req in ipairs(reqItems) do
            local collectStr = (req.collect ~= false) and " (collect)" or " (check only)"
            local txt = req.displayName .. "  x" .. tostring(req.count) .. collectStr
            local color = (req.collect ~= false) and {1, 1, 1} or {0.7, 0.9, 0.7}
            self:drawText(txt, leftX + 8, y, color[1], color[2], color[3], 1, UIFont.Small)
            y = y + 18
            if y > self.height - 60 then break end
        end
    end

    -- Right: Reward Items
    y = self.itemY
    self:drawText("--- Reward Items ---", rightX, y, 0.3, 0.9, 0.5, 1, UIFont.Small)
    y = y + 20
    local rewItems = delivery.rewardItems or {}
    if #rewItems == 0 then
        self:drawText("(none)", rightX + 8, y, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for _, rew in ipairs(rewItems) do
            local txt = rew.displayName .. "  x" .. tostring(rew.count)
            self:drawText(txt, rightX + 8, y, 1, 1, 1, 1, UIFont.Small)
            y = y + 18
            if y > self.height - 60 then break end
        end
    end

    -- Vertical divider
    self:drawRect(midX, self.itemY, 1, self.height - self.itemY - 60, 0.4, 0.4, 0.4, 0.4)
end

function EventTriggerDeliveryConfirm:new(player, delivery)
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
    o.player = player
    o.delivery = delivery
    o.dragging = false
    return o
end

-- ============================================================
-- Item Selection UI for OR mode (choose which item to use)
-- ============================================================
EventTrigger.Delivery._itemSelectUI = nil

function EventTrigger.Delivery.ShowItemSelectForOR(player, delivery)
    if EventTrigger.Delivery._itemSelectUI then
        EventTrigger.Delivery._itemSelectUI:close()
    end
    local ui = EventTriggerDeliveryItemSelectOR:new(player, delivery)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._itemSelectUI = ui
end

EventTriggerDeliveryItemSelectOR = ISPanel:derive("EventTriggerDeliveryItemSelectOR")

function EventTriggerDeliveryItemSelectOR:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerDeliveryItemSelectOR:create()
    self:setAlwaysOnTop(true)

    local bw, bh = 120, 30
    local gap = 20
    local totalW = bw * 2 + gap
    local btnY = self.height - 50
    local confX = (self.width - totalW) / 2
    local cancX = confX + bw + gap

    self.confirmBtn = ISButton:new(confX, btnY, bw, bh, "Confirm", self, EventTriggerDeliveryItemSelectOR.onConfirm)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)

    self.cancelBtn = ISButton:new(cancX, btnY, bw, bh, "Cancel", self, EventTriggerDeliveryItemSelectOR.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryItemSelectOR.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self.itemY = 36
    self.selectedItemIndex = nil

    -- Find matching items in player inventory
    self:findMatchingItems()
end

function EventTriggerDeliveryItemSelectOR:findMatchingItems()
    self.matchingItems = {}
    local player = getPlayer()
    if not player then return end
    local inv = player:getInventory()
    if not inv then return end
    local items = inv:getItems()
    
    for _, req in ipairs(self.delivery.requiredItems or {}) do
        if req.collect ~= false then
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                if item and item:getFullType() == req.fullType and item:getDisplayName() == req.displayName then
                    table.insert(self.matchingItems, {
                        req = req,
                        item = item,
                        fullType = item:getFullType(),
                        displayName = item:getDisplayName(),
                    })
                end
            end
        end
    end
end

function EventTriggerDeliveryItemSelectOR:onConfirm()
    if not self.selectedItemIndex then
        HaloTextHelper.addBadText(getPlayer(), "Please select an item to use!")
        return
    end
    
    local player = getPlayer()
    local playerKey = player and (player:getUsername() or "")
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    self:close()
    
    -- Store selected item index for Execute
    self.delivery._selectedORItemIndex = self.selectedItemIndex
    
    if EventTrigger.IsMultiplayer() then
        local ok, msg = EventTrigger.Delivery.Validate(player, self.delivery)
        if not ok then
            HaloTextHelper.addBadText(player, msg)
            return
        end
        sendClientCommand("EventTrigger", "confirmDelivery", { id = self.delivery.id, selectedORIndex = self.selectedItemIndex })
    else
        local ok, msg = EventTrigger.Delivery.Execute(player, self.delivery)
        if ok then
            HaloTextHelper.addGoodText(player, msg)
            self.delivery.triggerCount = (self.delivery.triggerCount or 0) + 1
            if not self.delivery.triggeredBy then self.delivery.triggeredBy = {} end
            if not self.delivery.playerDeliveries then self.delivery.playerDeliveries = {} end
            self.delivery.playerDeliveries[playerKey] = (self.delivery.playerDeliveries[playerKey] or 0) + 1
            local ts, tsStr = EventTrigger.GetTimestamp()
            table.insert(self.delivery.triggeredBy, { playerId = playerKey, timestamp = ts, timeStr = tsStr })
            EventTrigger._saveToModData()
        else
            HaloTextHelper.addBadText(player, msg)
        end
    end
end

function EventTriggerDeliveryItemSelectOR:onCancel()
    local player = getPlayer()
    local playerKey = player and (player:getUsername() or "")
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    self:close()
end

function EventTriggerDeliveryItemSelectOR:close()
    if EventTrigger.Delivery._itemSelectUI == self then
        EventTrigger.Delivery._itemSelectUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerDeliveryItemSelectOR:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerDeliveryItemSelectOR:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerDeliveryItemSelectOR:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerDeliveryItemSelectOR:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre("Select Item for Delivery", self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local delivery = self.delivery
    if not delivery then return end

    local midX = self.width / 2
    local leftX = 10
    local y = self.itemY

    -- Show match mode info
    local modeText = "Match Mode: " .. (delivery.matchMode == "any" and "ANY (OR logic)" or "ALL (AND logic)")
    self:drawText(modeText, leftX, y, 0.9, 0.9, 0.3, 1, UIFont.Small)
    y = y + 22
    
    if delivery.cooldownType and delivery.cooldownType > 0 and delivery.cooldownValue > 0 then
        local cdText = "Cooldown: " .. (delivery.cooldownType == 1 and "Game Time" or "Real Time") .. " " .. delivery.cooldownValue .. " min"
        self:drawText(cdText, leftX, y, 0.7, 0.9, 0.7, 1, UIFont.Small)
        y = y + 22
    end

    -- Required items (with checkboxes for selection)
    self:drawText("--- Required Items (select one) ---", leftX, y, 0.9, 0.7, 0.3, 1, UIFont.Small)
    y = y + 20
    local reqItems = delivery.requiredItems or {}
    
    if #reqItems == 0 then
        self:drawText("(none)", leftX + 8, y, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for idx, req in ipairs(reqItems) do
            -- Check if player has this item
            local hasItem = false
            for _, mi in ipairs(self.matchingItems or {}) do
                if mi.req == req then
                    hasItem = true
                    break
                end
            end
            
            local collectStr = (req.collect ~= false) and " (collect)" or " (check only)"
            local txt = req.displayName .. "  x" .. tostring(req.count) .. collectStr .. (hasItem and " [AVAILABLE]" or " [MISSING]")
            local color = hasItem and {1, 1, 1} or {0.7, 0.3, 0.3}
            
            -- Draw selection indicator
            if idx == self.selectedItemIndex then
                self:drawRect(leftX + 4, y + 2, 16, 16, 0.8, 0.2, 0.8, 0.2)
                self:drawRectBorder(leftX + 4, y + 2, 16, 16, 1, 1, 0.5, 0.5)
            else
                self:drawRectBorder(leftX + 4, y + 2, 16, 16, 0.5, 0.5, 0.5, 0.5)
            end
            
            self:drawText(txt, leftX + 24, y, color[1], color[2], color[3], 1, UIFont.Small)
            y = y + 22
            if y > self.height - 70 then break end
        end
    end

    -- Right: Reward Items
    y = self.itemY
    local rightX = midX + 10
    self:drawText("--- Reward Items ---", rightX, y, 0.3, 0.9, 0.5, 1, UIFont.Small)
    y = y + 20
    local rewItems = delivery.rewardItems or {}
    if #rewItems == 0 then
        self:drawText("(none)", rightX + 8, y, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for _, rew in ipairs(rewItems) do
            local txt = rew.displayName .. "  x" .. tostring(rew.count)
            self:drawText(txt, rightX + 8, y, 1, 1, 1, 1, UIFont.Small)
            y = y + 18
            if y > self.height - 70 then break end
        end
    end

    -- Vertical divider
    self:drawRect(midX, self.itemY, 1, self.height - self.itemY - 60, 0.4, 0.4, 0.4, 0.4)
end

function EventTriggerDeliveryItemSelectOR:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    
    -- Check for item selection clicks (start Y must match prerender layout)
    local leftX = 10
    local startY = self.itemY + 42
    if self.delivery.cooldownType and self.delivery.cooldownType > 0 and self.delivery.cooldownValue > 0 then
        startY = startY + 22
    end
    local reqItems = self.delivery.requiredItems or {}

    for idx, req in ipairs(reqItems) do
        local itemY = startY + (idx - 1) * 22
        if y >= itemY and y <= itemY + 20 and x >= leftX and x <= leftX + 20 then
            self.selectedItemIndex = idx
            return true
        end
    end
    
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerDeliveryItemSelectOR:new(player, delivery)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w, h = 500, 400
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.width = w
    o.height = h
    o.player = player
    o.delivery = delivery
    o.dragging = false
    return o
end

-- ============================================================
-- Delivery Point Setup Wizard (Section 3)
-- ============================================================
EventTrigger.Delivery._setupPending = nil

function EventTrigger.Delivery.StartSetup(x, y, z)
    EventTrigger.Delivery._setupPending = { x = x, y = y, z = z, requiredItems = {}, rewardItems = {}, maxPlayers = -1, maxPerPlayer = -1, matchMode = "all", cooldownType = 0, cooldownValue = 0 }
    EventTrigger.Delivery.PromptHintText()
end

function EventTrigger.Delivery.PromptHintText()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local modal = ISTextBox:new(0, 0, 420, 200,
        "Delivery hint text (shown above player head)", "Delivery Point", nil,
        function(target, button)
            if button.internal == "OK" then
                local text = button.parent.entry:getText()
                p.hintText = (text and #text > 0) and text or "Delivery Point"
                EventTrigger.Delivery.PromptRadius()
            else
                EventTrigger.Delivery._setupPending = nil
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptRadius()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local defaultText = "3.0"
    local modal = ISTextBox:new(0, 0, 400, 200,
        "Trigger radius (tiles, must be > 0)", defaultText, nil,
        function(target, button)
            if button.internal == "OK" then
                local radius = tonumber(button.parent.entry:getText()) or 3.0
                if radius <= 0 then radius = 3.0 end
                p.radius = radius
                EventTrigger.Delivery.PromptDeliveryLimits()
            else
                EventTrigger.Delivery._setupPending = nil
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptDeliveryLimits()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local defaultText = (p.maxPlayers or -1) .. ", " .. (p.maxPerPlayer or -1)
    if p._editing then
        defaultText = string.format("%d, %d", p.maxPlayers or -1, p.maxPerPlayer or -1)
    else
        defaultText = "-1, -1"
    end
    local modal = ISTextBox:new(0, 0, 420, 240,
        "Max Players, Max Per Player (-1=unlimited)\nFormat: N, M\nExample: 5, 1 = first 5 players, once each",
        defaultText, nil,
        function(target, button)
            if button.internal == "OK" then
                local text = button.parent.entry:getText()
                local parts = luautils.split(text, ",")
                local maxPlayers = tonumber(parts[1]) or -1
                local maxPerPlayer = tonumber(parts[2])
                if not maxPerPlayer then maxPerPlayer = -1 end
                if maxPlayers < -1 then maxPlayers = -1 end
                if maxPerPlayer < -1 then maxPerPlayer = -1 end
                p.maxPlayers = maxPlayers
                p.maxPerPlayer = maxPerPlayer
                EventTrigger.Delivery.PromptMatchMode()
            else
                EventTrigger.Delivery._setupPending = nil
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptMatchMode()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local defaultMode = p.matchMode or "all"
    if not p._editing then defaultMode = "all" end
    local modal = ISTextBox:new(0, 0, 420, 240,
        "Match Mode:\n- all = require ALL items (AND logic)\n- any = require ANY one item (OR logic)\n\nEnter 'all' or 'any'",
        defaultMode, nil,
        function(target, button)
            if button.internal == "OK" then
                local mode = string.lower(string.trim(button.parent.entry:getText() or ""))
                if mode ~= "all" and mode ~= "any" then mode = "all" end
                p.matchMode = mode
                EventTrigger.Delivery.PromptCooldown()
            else
                EventTrigger.Delivery._setupPending = nil
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptCooldown()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local defaultType = p.cooldownType or 0
    local defaultValue = p.cooldownValue or 0
    if not p._editing then defaultType = 0; defaultValue = 0 end
    local modal = ISTextBox:new(0, 0, 420, 280,
        "Cooldown Settings:\nType: 0=none, 1=game time (minutes), 2=real time (minutes)\nValue: cooldown minutes (0 = no cooldown)\n\nFormat: Type, Value\nExample: 1, 30 = 30 minutes game time cooldown",
        string.format("%d, %d", defaultType, defaultValue), nil,
        function(target, button)
            if button.internal == "OK" then
                local text = button.parent.entry:getText()
                local parts = luautils.split(text, ",")
                local cooldownType = tonumber(parts[1]) or 0
                local cooldownValue = tonumber(parts[2]) or 0
                if cooldownType < 0 or cooldownType > 2 then cooldownType = 0 end
                if cooldownValue < 0 then cooldownValue = 0 end
                p.cooldownType = cooldownType
                p.cooldownValue = cooldownValue
                EventTrigger.Delivery.PromptRequiredItems()
            else
                EventTrigger.Delivery._setupPending = nil
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptRequiredItems()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    p.requiredItems = p.requiredItems or {}
    EventTrigger.Delivery.ShowItemSelection("required")
end

function EventTrigger.Delivery.PromptRewardItems()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    EventTrigger.Delivery.ShowItemSelection("reward")
end

-- ============================================================
-- Item Selection UI for Setup Wizard (paginated inventory browser)
-- ============================================================
EventTrigger.Delivery._selectionUI = nil
EventTrigger.Delivery._selectionMode = nil

function EventTrigger.Delivery.ShowItemSelection(mode)
    if EventTrigger.Delivery._selectionUI then
        EventTrigger.Delivery._selectionUI:close()
    end
    local ui = EventTriggerDeliveryItemSelect:new(mode)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._selectionUI = ui
    EventTrigger.Delivery._selectionMode = mode
end

EventTriggerDeliveryItemSelect = ISPanel:derive("EventTriggerDeliveryItemSelect")

function EventTriggerDeliveryItemSelect:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerDeliveryItemSelect:create()
    self:setAlwaysOnTop(true)

    -- Close button
    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryItemSelect.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    -- Done / Next button
    self.doneBtn = ISButton:new(self.width - 140, self.height - 42, 128, 32, "Done / Next", self, EventTriggerDeliveryItemSelect.onDone)
    self.doneBtn:initialise()
    self:addChild(self.doneBtn)

    -- Cancel button
    self.backBtn = ISButton:new(14, self.height - 42, 90, 32, "Cancel", self, EventTriggerDeliveryItemSelect.onBack)
    self.backBtn:initialise()
    self:addChild(self.backBtn)

    -- Layout params (two-column: left=list, right=selected)
    self.contentY = 36
    self.contentH = self.height - 82
    self.midX = math.floor(self.width / 2)
    self.leftW = self.midX - 20
    self.rightW = self.width - self.midX - 14
    self.rowH = 36
    self.rowsPerPage = 8

    self.leftPage = 0
    self.rightPage = 0

    self:buildItemData()
    self:updateLeftPanel()
    self:updateRightPanel()
end

-- Clear all row-related children
function EventTriggerDeliveryItemSelect:clearRows()
    for _, child in ipairs(self.rowChildren or {}) do
        child:removeFromUIManager()
        if self.removeChild then self:removeChild(child) end
    end
    self.rowChildren = {}
end

-- Clear all selected-related children
function EventTriggerDeliveryItemSelect:clearSelected()
    for _, child in ipairs(self.selectedChildren or {}) do
        child:removeFromUIManager()
        if self.removeChild then self:removeChild(child) end
    end
    self.selectedChildren = {}
end

-- Collect inventory data (de-duplicate by FullType+DisplayName)
function EventTriggerDeliveryItemSelect:buildItemData()
    self.inventoryData = {}
    local player = getPlayer()
    if not player then return end
    local inv = player:getInventory()
    local items = inv:getItems()

    local seen = {}
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local key = (item:getFullType() or "") .. "|" .. (item:getDisplayName() or "")
        if not seen[key] then
            seen[key] = true
            table.insert(self.inventoryData, {
                fullType = item:getFullType(),
                displayName = item:getDisplayName(),
            })
        end
    end

    self.totalPages = math.max(1, math.ceil(#self.inventoryData / self.rowsPerPage))
end

-- ============ LEFT PANEL: Inventory Browser ============
function EventTriggerDeliveryItemSelect:updateLeftPanel()
    self:clearRows()

    if self.leftPage >= self.totalPages then self.leftPage = self.totalPages - 1 end
    if self.leftPage < 0 then self.leftPage = 0 end

    local p = EventTrigger.Delivery._setupPending
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = (p and mode == "required") and p.requiredItems or ((p and mode == "reward") and p.rewardItems or {})

    local x = 10
    local w = self.leftW
    local startY = self.contentY + 4
    local colX = x

    -- Heading
    local titleStr = "Inventory (Pg " .. (self.leftPage + 1) .. "/" .. self.totalPages .. ")"
    local heading = ISLabel:new(x, startY, 20, titleStr, 0.55, 0.8, 1, 1, UIFont.Small, true)
    heading:initialise()
    self:addChild(heading)
    table.insert(self.rowChildren, heading)

    -- Page buttons
    if self.totalPages > 1 then
        local prevBtn = ISButton:new(x + w - 46, startY - 1, 18, 18, "<", self, EventTriggerDeliveryItemSelect.onLeftPrev)
        prevBtn:initialise()
        self:addChild(prevBtn)
        table.insert(self.rowChildren, prevBtn)

        local nextBtn = ISButton:new(x + w - 26, startY - 1, 18, 18, ">", self, EventTriggerDeliveryItemSelect.onLeftNext)
        nextBtn:initialise()
        self:addChild(nextBtn)
        table.insert(self.rowChildren, nextBtn)
    end

    local rowStartY = startY + 24
    local startIdx = self.leftPage * self.rowsPerPage
    local endIdx = math.min(#self.inventoryData - 1, startIdx + self.rowsPerPage - 1)

    for i = startIdx, endIdx do
        if i < 0 then break end
        local data = self.inventoryData[i + 1]
        if not data then break end

        local r = i - startIdx
        local y = rowStartY + r * self.rowH

        local found = false
        if itemList then
            for _, si in ipairs(itemList) do
                if si.fullType == data.fullType then found = true; break end
            end
        end

        -- Row background
        local bg = found and {0.1, 0.12, 0.06} or {0.07, 0.07, 0.07}
        self:drawRect(x, y, w, self.rowH - 2, 0.2, bg[1], bg[2], bg[3])

        -- DisplayName
        local name = data.displayName or "?"
        if #name > 18 then name = name:sub(1, 15) .. ".." end
        local lbl = ISLabel:new(x + 4, y + 2, 18, name, 1, 1, 1, 1, UIFont.Small, true)
        lbl:initialise()
        self:addChild(lbl)
        table.insert(self.rowChildren, lbl)

        -- FullType (dimmer, below name)
        local ft = data.fullType or "?"
        if #ft > 22 then ft = ft:sub(1, 19) .. ".." end
        local ftLbl = ISLabel:new(x + 4, y + 20, 18, "[" .. ft .. "]", 0.4, 0.45, 0.6, 1, UIFont.Small, true)
        ftLbl:initialise()
        self:addChild(ftLbl)
        table.insert(self.rowChildren, ftLbl)

        -- Action button (right-aligned in left column)
        local btnX = x + w - 60
        local btnY = y + 8

        if found then
            local qtyBtn = ISButton:new(btnX, btnY, 26, 20, "Q", self, EventTriggerDeliveryItemSelect.onQtyItem)
            qtyBtn:initialise()
            qtyBtn.itemFullType = data.fullType
            self:addChild(qtyBtn)
            table.insert(self.rowChildren, qtyBtn)

            local remBtn = ISButton:new(btnX + 30, btnY, 26, 20, "X", self, EventTriggerDeliveryItemSelect.onRemoveItem)
            remBtn:initialise()
            remBtn.itemFullType = data.fullType
            self:addChild(remBtn)
            table.insert(self.rowChildren, remBtn)
        else
            local addBtn = ISButton:new(btnX, btnY, 56, 20, "Add", self, EventTriggerDeliveryItemSelect.onAddItem)
            addBtn:initialise()
            addBtn.itemFullType = data.fullType
            addBtn.itemDisplayName = data.displayName
            self:addChild(addBtn)
            table.insert(self.rowChildren, addBtn)
        end
    end

    if #self.inventoryData == 0 then
        local emptyLbl = ISLabel:new(x + 4, startY + 28, 18, "(inventory empty)", 0.5, 0.5, 0.5, 1, UIFont.Small, true)
        emptyLbl:initialise()
        self:addChild(emptyLbl)
        table.insert(self.rowChildren, emptyLbl)
    end
end

function EventTriggerDeliveryItemSelect:onLeftPrev()
    if self.leftPage > 0 then self.leftPage = self.leftPage - 1; self:updateLeftPanel() end
end

function EventTriggerDeliveryItemSelect:onLeftNext()
    if self.leftPage < self.totalPages - 1 then self.leftPage = self.leftPage + 1; self:updateLeftPanel() end
end

-- Mouse wheel on left side
function EventTriggerDeliveryItemSelect:onMouseWheel(del)
    local mx = getMouseX() - self:getAbsoluteX()
    if mx < self.midX then
        if del > 0 and self.leftPage > 0 then self.leftPage = self.leftPage - 1; self:updateLeftPanel()
        elseif del < 0 and self.leftPage < self.totalPages - 1 then self.leftPage = self.leftPage + 1; self:updateLeftPanel() end
    else
        -- right side: selected items pagination
        local p = EventTrigger.Delivery._setupPending
        if not p then return end
        local mode = EventTrigger.Delivery._selectionMode or "required"
        local itemList = (mode == "required") and p.requiredItems or p.rewardItems
        local selTotal = math.max(1, math.ceil(#itemList / self.rowsPerPage))
        if del > 0 and self.rightPage > 0 then self.rightPage = self.rightPage - 1; self:updateRightPanel()
        elseif del < 0 and self.rightPage < selTotal - 1 then self.rightPage = self.rightPage + 1; self:updateRightPanel() end
    end
end

-- ============ RIGHT PANEL: Selected Items ============
function EventTriggerDeliveryItemSelect:updateRightPanel()
    self:clearSelected()

    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = (mode == "required") and p.requiredItems or p.rewardItems
    local selTotal = math.max(1, math.ceil(#itemList / self.rowsPerPage))

    if self.rightPage >= selTotal then self.rightPage = selTotal - 1 end
    if self.rightPage < 0 then self.rightPage = 0 end

    local x = self.midX + 8
    local startY = self.contentY + 4

    -- Heading
    local titleStr = "Selected (Pg " .. (self.rightPage + 1) .. "/" .. selTotal .. ")"
    local heading = ISLabel:new(x, startY, 20, titleStr, 0.85, 0.85, 0.5, 1, UIFont.Small, true)
    heading:initialise()
    self:addChild(heading)
    table.insert(self.selectedChildren, heading)

    -- Page buttons
    if selTotal > 1 then
        local prevBtn = ISButton:new(x + self.rightW - 46, startY - 1, 18, 18, "<", self, EventTriggerDeliveryItemSelect.onRightPrev)
        prevBtn:initialise()
        self:addChild(prevBtn)
        table.insert(self.selectedChildren, prevBtn)

        local nextBtn = ISButton:new(x + self.rightW - 26, startY - 1, 18, 18, ">", self, EventTriggerDeliveryItemSelect.onRightNext)
        nextBtn:initialise()
        self:addChild(nextBtn)
        table.insert(self.selectedChildren, nextBtn)
    end

    if #itemList == 0 then
        local noneLbl = ISLabel:new(x + 4, startY + 28, 18, "(none selected)", 0.45, 0.45, 0.45, 1, UIFont.Small, true)
        noneLbl:initialise()
        self:addChild(noneLbl)
        table.insert(self.selectedChildren, noneLbl)
        return
    end

    local rowStartY = startY + 24
    local startIdx = self.rightPage * self.rowsPerPage
    local endIdx = math.min(#itemList - 1, startIdx + self.rowsPerPage - 1)

    for i = startIdx, endIdx do
        if i < 0 then break end
        local si = itemList[i + 1]
        if not si then break end

        local r = i - startIdx
        local y = rowStartY + r * self.rowH

        -- Row background
        self:drawRect(x, y, self.rightW, self.rowH - 2, 0.2, 0.08, 0.06, 0.04)

        -- Item name + count
        local txt = (si.displayName or "?") .. "  x" .. tostring(si.count)
        if #txt > 20 then txt = txt:sub(1, 17) .. ".." end
        local lbl = ISLabel:new(x + 4, y + 2, 18, txt, 1, 1, 0.85, 1, UIFont.Small, true)
        lbl:initialise()
        self:addChild(lbl)
        table.insert(self.selectedChildren, lbl)

        -- FullType (dimmer line)
        local ft = si.fullType or "?"
        if #ft > 22 then ft = ft:sub(1, 19) .. ".." end
        local ftLbl = ISLabel:new(x + 4, y + 20, 18, "[" .. ft .. "]", 0.4, 0.45, 0.6, 1, UIFont.Small, true)
        ftLbl:initialise()
        self:addChild(ftLbl)
        table.insert(self.selectedChildren, ftLbl)

        -- Collect checkbox (only for required items)
        if mode == "required" then
            local collect = si.collect ~= false
            local cbX = x + 4
            local cbY = y + 8
            local collectLbl = ISLabel:new(cbX + 20, cbY, 18, "Collect", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
            collectLbl:initialise()
            self:addChild(collectLbl)
            table.insert(self.selectedChildren, collectLbl)

            local collectCB = ISTickBox:new(cbX, cbY, 18, 18, "", self, EventTriggerDeliveryItemSelect.onToggleCollect)
            collectCB:initialise()
            collectCB:addOption("")
            collectCB.selected[1] = collect
            collectCB.itemIndex = i + 1
            self:addChild(collectCB)
            table.insert(self.selectedChildren, collectCB)
        end

        -- Buttons on right — Qty and X with gap
        local btnX = x + self.rightW - 62
        local btnY = y + 8

        local qtyBtn = ISButton:new(btnX, btnY, 26, 20, "Q", self, EventTriggerDeliveryItemSelect.onEditQty)
        qtyBtn:initialise()
        qtyBtn.itemIndex = i + 1
        self:addChild(qtyBtn)
        table.insert(self.selectedChildren, qtyBtn)

        local delBtn = ISButton:new(btnX + 32, btnY, 26, 20, "X", self, EventTriggerDeliveryItemSelect.onDelItem)
        delBtn:initialise()
        delBtn.itemIndex = i + 1
        self:addChild(delBtn)
        table.insert(self.selectedChildren, delBtn)
    end
end

function EventTriggerDeliveryItemSelect:onRightPrev()
    if self.rightPage > 0 then self.rightPage = self.rightPage - 1; self:updateRightPanel() end
end

function EventTriggerDeliveryItemSelect:onRightNext()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = (mode == "required") and p.requiredItems or p.rewardItems
    local selTotal = math.max(1, math.ceil(#itemList / self.rowsPerPage))
    if self.rightPage < selTotal - 1 then self.rightPage = self.rightPage + 1; self:updateRightPanel() end
end

function EventTriggerDeliveryItemSelect:refreshUI()
    self:updateLeftPanel()
    self:updateRightPanel()
end

-- Add item from inventory list
function EventTriggerDeliveryItemSelect:onAddItem(btn)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = (mode == "required") and p.requiredItems or p.rewardItems

    table.insert(itemList, {
        fullType = btn.itemFullType,
        displayName = btn.itemDisplayName,
        count = 1,
        collect = true,
    })

    self:refreshUI()
    EventTrigger.Delivery.PromptItemQuantity(#itemList, mode, self)
end

-- Change quantity of selected item from inventory list
function EventTriggerDeliveryItemSelect:onQtyItem(btn)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = (mode == "required") and p.requiredItems or p.rewardItems

    for idx, si in ipairs(itemList) do
        if si.fullType == btn.itemFullType then
            EventTrigger.Delivery.PromptItemQuantity(idx, mode, self)
            return
        end
    end
end

-- Remove item from selected list (via inventory list button)
function EventTriggerDeliveryItemSelect:onRemoveItem(btn)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = (mode == "required") and p.requiredItems or p.rewardItems

    for idx = #itemList, 1, -1 do
        if itemList[idx].fullType == btn.itemFullType then
            table.remove(itemList, idx)
            break
        end
    end
    self:refreshUI()
end

-- Edit quantity from selected panel
function EventTriggerDeliveryItemSelect:onEditQty(btn)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    EventTrigger.Delivery.PromptItemQuantity(btn.itemIndex, mode, self)
end

-- Delete from selected panel
function EventTriggerDeliveryItemSelect:onDelItem(btn)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = (mode == "required") and p.requiredItems or p.rewardItems

    if btn.itemIndex >= 1 and btn.itemIndex <= #itemList then
        table.remove(itemList, btn.itemIndex)
    end
    self:refreshUI()
end

-- Toggle collect checkbox for required items
function EventTriggerDeliveryItemSelect:onToggleCollect(tickbox)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    if mode ~= "required" then return end

    local itemList = p.requiredItems
    local idx = tickbox.itemIndex
    if idx >= 1 and idx <= #itemList then
        itemList[idx].collect = tickbox.selected[1] == true
        self:refreshUI()
    end
end

function EventTriggerDeliveryItemSelect:onDone()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    self:close()

    if mode == "required" then
        EventTrigger.Delivery.PromptRewardItems()
    else
        -- reward mode done -> place the delivery point
        EventTrigger.Delivery.PlacePending()
    end
end

function EventTriggerDeliveryItemSelect:onBack()
    -- Back not supported in delivery wizard (items must be set)
    -- Just close and cancel
    self:onCancel()
end

function EventTriggerDeliveryItemSelect:onCancel()
    EventTrigger.Delivery._setupPending = nil
    self:close()
end

function EventTriggerDeliveryItemSelect:close()
    if EventTrigger.Delivery._selectionUI == self then
        EventTrigger.Delivery._selectionUI = nil
        EventTrigger.Delivery._selectionMode = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerDeliveryItemSelect:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)

    local mode = EventTrigger.Delivery._selectionMode or "required"
    local titleStr = (mode == "required") and "Set Required Items" or "Set Reward Items"
    self:drawTextCentre(titleStr, self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    -- Left panel background (inventory list)
    self:drawRect(8, self.contentY, self.leftW, self.contentH, 0.12, 0.04, 0.04, 0.04)

    -- Right panel background (selected)
    local rx = self.midX + 6
    self:drawRect(rx, self.contentY, self.rightW, self.contentH, 0.08, 0.06, 0.04, 0.04)

    -- Vertical divider
    self:drawRect(self.midX, self.contentY, 2, self.contentH, 0.35, 0.55, 0.55, 0.55)
end

function EventTriggerDeliveryItemSelect:new(mode)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w, h = 710, 500
    local x, y = (sw - w) / 2, (sh - h) / 2

    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.width = w
    o.height = h
    o.rowChildren = {}
    o.selectedChildren = {}
    return o
end

-- ============================================================
-- Quantity input prompt (ISTextBox)
-- ============================================================
function EventTrigger.Delivery.PromptItemQuantity(idx, mode, parentUI)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local itemList = (mode == "required") and p.requiredItems or p.rewardItems
    if not itemList or idx < 1 or idx > #itemList then return end

    local item = itemList[idx]
    local defaultText = tostring(item.count or 1)
    local hintText = "Enter quantity (" .. (item.displayName or "?") .. ")\nPositive integer, minimum 1"

    local modal = ISTextBox:new(0, 0, 350, 200,
        hintText, defaultText, nil,
        function(target, button)
            if button.internal == "OK" then
                local count = tonumber(button.parent.entry:getText()) or 1
                if count < 1 then count = 1 end
                item.count = count
                if parentUI and parentUI.refreshUI then
                    parentUI:refreshUI()
                end
            end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- ============================================================
-- Finalize delivery point placement
-- ============================================================
function EventTrigger.Delivery.PlacePending()
    local p = EventTrigger.Delivery._setupPending
    if not p then
        dbg("PlacePending: no pending data, abort")
        return
    end

    local isEditing = p._editing

    local args = {
        x = p.x, y = p.y, z = p.z,
        hintText = p.hintText or "Delivery Point",
        range = p.radius or 3.0,
        maxPlayers = p.maxPlayers or -1,
        maxPerPlayer = p.maxPerPlayer or -1,
        matchMode = p.matchMode or "all",
        cooldownType = p.cooldownType or 0,
        cooldownValue = p.cooldownValue or 0,
        requiredItems = p.requiredItems or {},
        rewardItems = p.rewardItems or {},
        creator = EventTrigger.GetCurrentPlayerId(),
    }

    dbg("PlacePending: placing delivery at (", p.x, p.y, p.z, "), hint=", p.hintText,
        " reqItems=", #args.requiredItems, " rewardItems=", #args.rewardItems,
        " matchMode=", args.matchMode, " cooldownType=", args.cooldownType, " cooldownValue=", args.cooldownValue,
        " editing=", tostring(isEditing))

    if isEditing then
        -- Edit mode: update existing delivery point
        local dlvIdx = p._editDlvIdx
        local dp = EventTrigger.deliveryPoints[dlvIdx]
        if dp then
            dp.hintText = p.hintText or "Delivery Point"
            dp.range = p.radius or 3.0
            dp.maxPlayers = p.maxPlayers or -1
            dp.maxPerPlayer = p.maxPerPlayer or -1
            dp.matchMode = p.matchMode or "all"
            dp.cooldownType = p.cooldownType or 0
            dp.cooldownValue = p.cooldownValue or 0
            dp.requiredItems = p.requiredItems or {}
            dp.rewardItems = p.rewardItems or {}
            if EventTrigger.IsMultiplayer() then
                args.id = dp.id
                args.triggerCount = dp.triggerCount or 0
                sendClientCommand("EventTrigger", "editDelivery", args)
            else
                EventTrigger._saveToModData()
            end
        end
        EventTrigger.Delivery._setupPending = nil
        if EventTrigger._ui then EventTrigger._ui:refreshList() end
        return
    end

    if EventTrigger.IsMultiplayer() then
        -- Add locally for immediate feedback, server persists + broadcasts syncAll for confirmation
        local dp = {
            id = "dlv_" .. tostring(os.time()) .. "_" .. tostring(ZombRand(10000, 99999)),
            type = "delivery",
            x = p.x, y = p.y, z = p.z,
            hintText = p.hintText or "Delivery Point",
            range = p.radius or 3.0,
            maxPlayers = p.maxPlayers or -1,
            maxPerPlayer = p.maxPerPlayer or -1,
            matchMode = p.matchMode or "all",
            cooldownType = p.cooldownType or 0,
            cooldownValue = p.cooldownValue or 0,
            requiredItems = p.requiredItems or {},
            rewardItems = p.rewardItems or {},
            playerDeliveries = {},
            playerCooldowns = {},
            creator = EventTrigger.GetCurrentPlayerId(),
            createdAt = os.time(),
            triggerCount = 0,
            triggeredBy = {},
        }
        EventTrigger.deliveryPoints[#EventTrigger.deliveryPoints + 1] = dp
        args.id = dp.id
        sendClientCommand("EventTrigger", "placeDeliveryPoint", args)
        if EventTrigger._ui then EventTrigger._ui:refreshList() end
    else
        -- SP: add directly
        local dp = {
            id = "dlv_" .. tostring(os.time()) .. "_" .. tostring(ZombRand(10000, 99999)),
            type = "delivery",
            x = p.x, y = p.y, z = p.z,
            hintText = p.hintText or "Delivery Point",
            range = p.radius or 3.0,
            maxPlayers = p.maxPlayers or -1,
            maxPerPlayer = p.maxPerPlayer or -1,
            matchMode = p.matchMode or "all",
            cooldownType = p.cooldownType or 0,
            cooldownValue = p.cooldownValue or 0,
            requiredItems = p.requiredItems or {},
            rewardItems = p.rewardItems or {},
            playerDeliveries = {},
            playerCooldowns = {},
            creator = EventTrigger.GetCurrentPlayerId(),
            createdAt = os.time(),
            triggerCount = 0,
            triggeredBy = {},
            _dlvPrompted = {},
        }
        EventTrigger.deliveryPoints[#EventTrigger.deliveryPoints + 1] = dp
        EventTrigger._saveToModData()
    end

    EventTrigger.Delivery._setupPending = nil
end

-- ============================================================
-- Handle server delivery result (add rewards on success)
-- ============================================================
function EventTrigger.Delivery.OnDeliveryResult(player, success, message, rewardItems)
    local playerKey = player and (player:getUsername() or "")
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    if success then
        HaloTextHelper.addGoodText(player, message)
    else
        HaloTextHelper.addBadText(player, message)
    end
end

-- ============================================================
-- Clean up all delivery UIs
-- ============================================================
function EventTrigger.Delivery.CloseAllUIs()
    if EventTrigger.Delivery._promptUI then
        EventTrigger.Delivery._promptUI:close()
    end
    if EventTrigger.Delivery._confirmUI then
        EventTrigger.Delivery._confirmUI:close()
    end
    if EventTrigger.Delivery._selectionUI then
        EventTrigger.Delivery._selectionUI:close()
    end
end

-- ============================================================
-- UI Management: Edit / Delete / Reset / History for EventTriggerUI
-- ============================================================

-- Delete a delivery point
function EventTrigger.Delivery.DeleteDelivery(dlvIdx, dp)
    if not dp or not dp.id then return end
    if EventTrigger.IsMultiplayer() then
        sendClientCommand("EventTrigger", "deleteDeliveryPoint", { id = dp.id })
    else
        table.remove(EventTrigger.deliveryPoints, dlvIdx)
        EventTrigger._saveToModData()
    end
    -- Refresh UI after a short delay to allow server sync
    if EventTrigger._ui then EventTrigger._ui:refreshList() end
end

-- Reset delivery completion status
function EventTrigger.Delivery.ResetDelivery(dlvIdx, dp)
    if not dp or not dp.id then return end
    dp.triggerCount = 0
    dp.triggeredBy = {}
    dp.playerDeliveries = {}
    -- MP: inform server
    if EventTrigger.IsMultiplayer() then
        sendClientCommand("EventTrigger", "resetDelivery", { id = dp.id })
    else
        EventTrigger._saveToModData()
    end
    if EventTrigger._ui then EventTrigger._ui:refreshList() end
end

-- Edit delivery point: re-open the setup wizard with existing values
function EventTrigger.Delivery.EditDelivery(dlvIdx, dp)
    if not dp then return end
    -- Close any existing selection UI
    EventTrigger.Delivery.CloseAllUIs()
    -- Start edit wizard at delivery point position, pre-populated
    EventTrigger.Delivery._setupPending = {
        x = dp.x, y = dp.y, z = dp.z,
        hintText = dp.hintText,
        radius = dp.range,
        maxPlayers = dp.maxPlayers or -1,
        maxPerPlayer = dp.maxPerPlayer or -1,
        matchMode = dp.matchMode or "all",
        cooldownType = dp.cooldownType or 0,
        cooldownValue = dp.cooldownValue or 0,
        requiredItems = EventTrigger.Delivery._cloneItems(dp.requiredItems or {}),
        rewardItems = EventTrigger.Delivery._cloneItems(dp.rewardItems or {}),
        _editing = true,
        _editId = dp.id,
        _editDlvIdx = dlvIdx,
    }
    EventTrigger.Delivery.PromptHintText()
end

-- Show delivery history/details
function EventTrigger.Delivery.ShowHistory(dp)
    if not dp then return end
    if EventTrigger.Delivery._histUI then
        EventTrigger.Delivery._histUI:close()
    end
    local ui = EventTriggerDeliveryHistUI:new(dp)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._histUI = ui
end

-- Helper: clone items table (deep copy for edit mode)
function EventTrigger.Delivery._cloneItems(items)
    local out = {}
    for _, item in ipairs(items or {}) do
        out[#out + 1] = {
            fullType = item.fullType,
            displayName = item.displayName,
            count = item.count,
        }
    end
    return out
end

-- ============================================================
-- Delivery History UI
-- ============================================================
EventTriggerDeliveryHistUI = ISPanel:derive("EventTriggerDeliveryHistUI")

function EventTriggerDeliveryHistUI:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerDeliveryHistUI:create()
    self:setAlwaysOnTop(true)
    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryHistUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self.lines = {}
    local dp = self.dp
    local y = 40

    if not dp then
        self.lines[#self.lines + 1] = { x = 10, y = y, text = "Delivery point not found.", color = {1,0.5,0.5} }
        return
    end

    self.lines[#self.lines + 1] = {
        x = 10, y = y, text = string.format("Position: (%d,%d,%d)  Hint: %s  Creator: %s", dp.x, dp.y, dp.z, dp.hintText or "", dp.creator or "?"),
        color = {0.7,0.8,1},
    }
    y = y + 22
    self.lines[#self.lines + 1] = {
        x = 10, y = y, text = string.format("Range: %.1f  Status: %s", dp.range or 3, (dp.triggerCount or 0) > 0 and "Completed" or "Ready"),
        color = {1,1,1},
    }
    y = y + 22
    
    -- Match mode and cooldown
    local modeText = "Match Mode: " .. (dp.matchMode == "any" and "ANY (OR logic)" or "ALL (AND logic)")
    self.lines[#self.lines + 1] = { x = 10, y = y, text = modeText, color = {0.9,0.9,0.3} }
    y = y + 18
    
    if dp.cooldownType and dp.cooldownType > 0 and dp.cooldownValue > 0 then
        local cdText = "Cooldown: " .. (dp.cooldownType == 1 and "Game Time" or "Real Time") .. " " .. dp.cooldownValue .. " min"
        self.lines[#self.lines + 1] = { x = 10, y = y, text = cdText, color = {0.7,0.9,0.7} }
        y = y + 18
    end
    
    if dp.maxPlayers and dp.maxPlayers > 0 then
        self.lines[#self.lines + 1] = { x = 10, y = y, text = "Max Players: " .. dp.maxPlayers, color = {0.8,0.8,1} }
        y = y + 18
    end
    if dp.maxPerPlayer and dp.maxPerPlayer > 0 then
        self.lines[#self.lines + 1] = { x = 10, y = y, text = "Max Per Player: " .. dp.maxPerPlayer, color = {0.8,0.8,1} }
        y = y + 18
    end
    
    y = y + 6

    -- Required items
    self.lines[#self.lines + 1] = { x = 10, y = y, text = "--- Required Items ---", color = {0.9,0.7,0.3} }
    y = y + 20
    local reqItems = dp.requiredItems or {}
    if #reqItems == 0 then
        self.lines[#self.lines + 1] = { x = 20, y = y, text = "(none)", color = {0.5,0.5,0.5} }
        y = y + 20
    else
        for _, item in ipairs(reqItems) do
            local collectStr = (item.collect ~= false) and " (collect)" or " (check only)"
            local txt = item.displayName .. " x" .. tostring(item.count) .. collectStr .. "  [" .. item.fullType .. "]"
            self.lines[#self.lines + 1] = { x = 20, y = y, text = txt, color = {1,1,1} }
            y = y + 18
        end
    end

    y = y + 6
    self.lines[#self.lines + 1] = { x = 10, y = y, text = "--- Reward Items ---", color = {0.3,0.9,0.5} }
    y = y + 20
    local rewItems = dp.rewardItems or {}
    if #rewItems == 0 then
        self.lines[#self.lines + 1] = { x = 20, y = y, text = "(none)", color = {0.5,0.5,0.5} }
        y = y + 20
    else
        for _, item in ipairs(rewItems) do
            local txt = item.displayName .. " x" .. tostring(item.count) .. "  [" .. item.fullType .. "]"
            self.lines[#self.lines + 1] = { x = 20, y = y, text = txt, color = {1,1,1} }
            y = y + 18
        end
    end

    -- Trigger history
    y = y + 6
    local trigBy = dp.triggeredBy or {}
    self.lines[#self.lines + 1] = { x = 10, y = y, text = "Total deliveries: " .. #trigBy, color = {1,1,1} }
    y = y + 22
    for i, entry in ipairs(trigBy) do
        local pId, tStr
        if type(entry) == "table" then
            pId = entry.playerId or "?"
            tStr = entry.timeStr or ""
        else
            pId = tostring(entry)
            tStr = ""
        end
        local line = i .. ". " .. pId
        if #tStr > 0 then line = line .. "  [" .. tStr .. "]" end
        self.lines[#self.lines + 1] = { x = 20, y = y, text = line, color = {0.8,0.9,1} }
        y = y + 18
        if y > self.height - 30 then break end
    end
end

function EventTriggerDeliveryHistUI:onClose()
    self:close()
end

function EventTriggerDeliveryHistUI:close()
    if EventTrigger.Delivery._histUI == self then
        EventTrigger.Delivery._histUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerDeliveryHistUI:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerDeliveryHistUI:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerDeliveryHistUI:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerDeliveryHistUI:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre("Delivery Point Details", self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)
    for _, line in ipairs(self.lines) do
        self:drawText(line.text, line.x, line.y, line.color[1], line.color[2], line.color[3], 1, UIFont.Small)
    end
end

function EventTriggerDeliveryHistUI:new(dp)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w, h = 500, 380
    local x, y = (sw - w) / 2, (sh - h) / 2
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.width = w
    o.height = h
    o.dp = dp
    o.dragging = false
    return o
end
