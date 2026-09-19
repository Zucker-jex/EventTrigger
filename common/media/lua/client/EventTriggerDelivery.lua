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

-- UTF-8 safe text fitting (defined in EventTriggerClient.lua; fall back to passthrough)
local function fitText(text, font, maxWidth)
    if EventTrigger.fitText then return EventTrigger.fitText(text, font, maxWidth) end
    return tostring(text or "")
end

-- Resolve the setup wizard's active item list for a selection mode.
-- "required" = ET qualification items; "cost" = 需求3 consume options;
-- "reward" / "reward_branch" = reward items.
local function setupItemList(p, mode)
    if not p then return {} end
    if mode == "required" then return p.requiredItems or {} end
    if mode == "cost" then return p.costOptions or {} end
    return p.rewardItems or {}
end

-- Unified player identity key (username preferred, fallback to online ID).
-- All delivery state (cooldown, limits, prompts) must use this same key,
-- otherwise cooldown/limit records can silently desync when username is empty.
local function playerKeyOf(player)
    if not player then return "" end
    local u = player:getUsername()
    if u and #u > 0 then return u end
    return tostring(player:getOnlineID()) or ""
end

-- Match key for dual matching (FullType + DisplayName). The displayName component
-- distinguishes items that the player renamed via setName(); it is compared exactly
-- on the CLIENT (strict pre-check). The server executes with FullType only (lenient
-- authority, immune to per-player translation differences).
local function itemKey(fullType, displayName)
    return tostring(fullType or "") .. "|" .. tostring(displayName or "")
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
                    local key = itemKey(req.fullType, req.displayName)
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
-- multiplier: batch count (each item deducted count * multiplier)
-- ============================================================
function EventTrigger.Delivery.RemoveItems(inventory, requiredItems, matchMode, selectedORIndex, multiplier)
    local removedData = {}
    local items = inventory:getItems()
    matchMode = matchMode or "all"
    multiplier = multiplier or 1

    -- Phase 1: collect item references (no ArrayList modification during iteration)
    local toRemoveList = {}
    
    if matchMode == "any" then
        -- OR mode: only remove from the selected required item
        local targetIdx = selectedORIndex or 1
        for idx, req in ipairs(requiredItems) do
            if req.collect ~= false and idx == targetIdx then
                local remaining = req.count * multiplier
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
                local remaining = req.count * multiplier
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
-- multiplier: batch count (each reward granted count * multiplier)
-- ============================================================
function EventTrigger.Delivery.GrantRewards(inventory, rewardItems, multiplier)
    multiplier = multiplier or 1
    local created = {}
    for _, reward in ipairs(rewardItems) do
        for _ = 1, reward.count * multiplier do
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
-- Client-side dual-match validation (no inventory changes)
-- ============================================================
function EventTrigger.Delivery.Validate(player, deliveryData)
    if not player or not deliveryData then return false, getText("UI_ET_Msg_InvalidData") end
    local inventory = player:getInventory()
    -- Branch-aware resolve: 需求物品门槛 + 消耗 + 奖励 + matchMode
    local qualifyItems, costItems, _, matchMode = EventTrigger.Delivery.resolveView(deliveryData)
    local batchCount = tonumber(deliveryData._batchCount) or 1
    if batchCount < 1 then batchCount = 1 end
    batchCount = math.floor(batchCount)

    -- 资格门槛检查（需求物品）：collect=true 按 batch 计，collect=false 只查持有
    if #qualifyItems > 0 then
        local qualCounts = EventTrigger.Delivery.CountItems(inventory, qualifyItems)
        if matchMode == "any" then
            local hasAny = false
            for _, q in ipairs(qualifyItems) do
                local need = q.collect and (q.count * batchCount) or q.count
                if (qualCounts[itemKey(q.fullType, q.displayName)] or 0) >= need then
                    hasAny = true
                    break
                end
            end
            if not hasAny then return false, getText("UI_ET_Msg_MissingItems") end
        else
            for _, q in ipairs(qualifyItems) do
                local need = q.collect and (q.count * batchCount) or q.count
                if (qualCounts[itemKey(q.fullType, q.displayName)] or 0) < need then
                    return false, getText("UI_ET_Msg_MissingItems")
                end
            end
        end
    end

    -- 消耗检查（实际扣款）
    if #costItems > 0 then
        local costCounts = EventTrigger.Delivery.CountItems(inventory, costItems)
        for _, c in ipairs(costItems) do
            if (costCounts[itemKey(c.fullType, c.displayName)] or 0) < c.count * batchCount then
                return false, getText("UI_ET_Msg_MissingItems")
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
-- Check cooldown for delivery (wall clock vs game clock)
-- ============================================================
function EventTrigger.Delivery.CheckCooldown(player, deliveryData)
    local cooldown = deliveryData.cooldown or {}
    if EventTrigger.isCooldownZero(cooldown) then
        return true, ""
    end

    local playerKey = playerKeyOf(player)
    local playerCooldowns = deliveryData.playerCooldowns or {}
    local lastDelivery = playerCooldowns[playerKey]
    if not lastDelivery then
        return true, ""
    end

    local now = EventTrigger.cooldownNowSeconds(cooldown.mode)
    local total = EventTrigger.cooldownDurationSeconds(cooldown)
    if (now - lastDelivery) < total then
        return false, getText("UI_ET_Msg_CooldownActive", EventTrigger.formatCooldown(cooldown))
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
    local playerKey = playerKeyOf(player)
    if not playerKey or #playerKey == 0 then return end

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    if not px then return end

    for _, dp in ipairs(EventTrigger.deliveryPoints or {}) do
        if dp and dp.type == "delivery" and dp.enabled ~= false then

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

    local bh = 34
    local gap = 24
    local yesLabel = getText("UI_ET_Btn_Yes")
    local noLabel = getText("UI_ET_Btn_No")
    local yesW = EventTrigger.btnW(yesLabel)
    local noW = EventTrigger.btnW(noLabel)
    local btnY = self.height - bh - 16
    local yesX = (self.width - (yesW + gap + noW)) / 2

    self.yesBtn = ISButton:new(yesX, btnY, yesW, bh, yesLabel, self, EventTriggerDeliveryPrompt.onYes)
    self.yesBtn:initialise()
    self:addChild(self.yesBtn)

    self.noBtn = ISButton:new(yesX + yesW + gap, btnY, noW, bh, noLabel, self, EventTriggerDeliveryPrompt.onNo)
    self.noBtn:initialise()
    self:addChild(self.noBtn)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryPrompt.onNo)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
end

function EventTriggerDeliveryPrompt:onYes()
    self:close()
    local player = getPlayer()
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
    end
    if player and self.dp then
        EventTrigger.Delivery.ClearSelection(self.dp)
        EventTrigger.Delivery.ShowDeliveryConfirm(player, self.dp)
    end
end

function EventTriggerDeliveryPrompt:onNo()
    local player = getPlayer()
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    EventTrigger.Delivery.ClearSelection(self.dp)
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
    self:drawTextCentre(getText("UI_ET_Dlv_PromptTitle"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local hint = self.dp and self.dp.hintText or getText("UI_ET_Dlv_Point")
    local promptText = getText("UI_ET_Dlv_Detected", hint)
    local y = 28 + math.floor(18 * EventTrigger.US)
    for line in (promptText .. "\n"):gmatch("([^\n]*)\n") do
        if line and #line > 0 then
            self:drawTextCentre(fitText(line, UIFont.Small, self.width - 40), self.width / 2, y, 1, 1, 1, 1, UIFont.Small)
        end
        y = y + math.floor(22 * EventTrigger.US)
    end

    -- 需求物品显示：配置了才显示；背包缺失时提示
    local reqItems = self.dp and (self.dp.requiredItems or {}) or {}
    if #reqItems > 0 then
        y = y + math.floor(4 * EventTrigger.US)
        self:drawText(getText("UI_ET_Dlv_RequiredItems"), 16, y, 0.9, 0.7, 0.3, 1, UIFont.Small)
        y = y + math.floor(20 * EventTrigger.US)

        local player = getPlayer()
        local inv = player and player:getInventory()
        local counts = inv and EventTrigger.Delivery.CountItems(inv, reqItems) or {}
        local matchMode = self.dp and (self.dp.matchMode or "all") or "all"
        local qualifyOk = true
        if matchMode == "any" then
            qualifyOk = false
            for _, req in ipairs(reqItems) do
                if (counts[itemKey(req.fullType, req.displayName)] or 0) >= (req.count or 1) then qualifyOk = true; break end
            end
        else
            for _, req in ipairs(reqItems) do
                if (counts[itemKey(req.fullType, req.displayName)] or 0) < (req.count or 1) then qualifyOk = false; break end
            end
        end
        for _, req in ipairs(reqItems) do
            local have = counts[itemKey(req.fullType, req.displayName)] or 0
            local suffix = (req.collect ~= false) and getText("UI_ET_Dlv_CollectSuffix") or getText("UI_ET_Dlv_CheckOnlySuffix")
            local txt = fitText((req.displayName or "?") .. "  x" .. tostring(req.count) .. suffix .. "  [" .. getText("UI_ET_Batch_Have") .. " " .. have .. "]", UIFont.Small, self.width - 48)
            self:drawText(txt, 24, y, 1, 1, 1, 1, UIFont.Small)
            y = y + math.floor(20 * EventTrigger.US)
        end
        if not qualifyOk then
            self:drawText(getText("UI_ET_Dlv_NoRequiredItems"), 24, y, 0.9, 0.5, 0.5, 1, UIFont.Small)
        end
    end
end

function EventTriggerDeliveryPrompt:new(dp)
    local w = EventTrigger.fitW(460)
    local s = EventTrigger.US
    local reqCount = dp and #(dp.requiredItems or {}) or 0
    local baseH = 230
    if reqCount > 0 then
        -- 标题行 + 每项一行 + 缺失提示一行
        baseH = baseH + math.floor(20 * s) * (reqCount + 2) + math.floor(26 * s)
    end
    local h = EventTrigger.fitH(baseH)
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
    o.dp = dp
    o.dragging = false
    return o
end

-- ============================================================
-- Delivery Confirm UI (shows required & reward items, Confirm/Cancel)
-- ============================================================

-- Resolve the display/execution plan for a delivery (branch-aware).
-- Returns qualifyItems (需求物品/资格门槛) + costItems (消耗) + rewardItems + effective matchMode.
--   qualifyItems: requiredItems — the qualification gate (collect=true also consumes in legacy).
--   costItems: items actually deducted (legacy = collect=true requiredItems; branch = selected cost option).
--   branch: single selected cost item + branch rewards + "all" (choice already made).
function EventTrigger.Delivery.resolveView(delivery)
    local branches = delivery.branches or {}

    -- 资格门槛：requiredItems（需求物品）
    local qualifyItems = {}
    for _, req in ipairs(delivery.requiredItems or {}) do
        qualifyItems[#qualifyItems + 1] = {
            fullType = req.fullType,
            displayName = req.displayName,
            count = req.count,
            collect = req.collect ~= false,
        }
    end

    -- Legacy path: 消耗 = requiredItems 中 collect=true 的
    if #branches == 0 then
        local costItems = {}
        for _, req in ipairs(delivery.requiredItems or {}) do
            if req.collect ~= false then
                costItems[#costItems + 1] = {
                    fullType = req.fullType,
                    displayName = req.displayName,
                    count = req.count,
                    collect = true,
                }
            end
        end
        return qualifyItems, costItems, (delivery.rewardItems or {}), (delivery.matchMode or "all")
    end

    -- Branch path
    local branch = branches[1]
    local bid = delivery._selectedBranchId
    if bid and branches[bid] and branches[bid].enabled ~= false then
        branch = branches[bid]
    end
    if not branch or branch.enabled == false then
        return qualifyItems, {}, {}, "all"
    end

    -- 消耗 = requiredItems 中 collect=true 的（"移除"型需求物品）
    local costItems = {}
    for _, req in ipairs(delivery.requiredItems or {}) do
        if req.collect ~= false then
            costItems[#costItems + 1] = {
                fullType = req.fullType,
                displayName = req.displayName,
                count = req.count,
                collect = true,
            }
        end
    end

    -- 额外消耗：branch 选中的 costOption（需求3，可选）
    local costOptions = branch.costOptions or {}
    local chosen
    local chosenIdx = delivery._selectedCostOptionIndex
    if chosenIdx and costOptions[chosenIdx] then
        chosen = costOptions[chosenIdx]
    elseif #costOptions > 0 then
        chosen = costOptions[1]
    end
    if chosen then
        costItems[#costItems + 1] = {
            fullType = chosen.fullType,
            displayName = chosen.displayName,
            count = chosen.count,
            collect = true,
        }
    end
    return qualifyItems, costItems, (branch.rewards or {}), "all"
end

-- Clear per-delivery transient selection state (branch / cost option / OR index).
-- These are runtime-only; leftover values would skip selection dialogs on the next
-- trigger and make player-facing behavior inconsistent.
function EventTrigger.Delivery.ClearSelection(delivery)
    if not delivery then return end
    delivery._selectedBranchId = nil
    delivery._selectedCostOptionIndex = nil
    delivery._selectedORItemIndex = nil
end

function EventTrigger.Delivery.ShowDeliveryConfirm(player, delivery)
    if EventTrigger.Delivery._confirmUI then
        EventTrigger.Delivery._confirmUI:close()
    end
    if EventTrigger.Delivery._itemSelectUI then
        EventTrigger.Delivery._itemSelectUI:close()
    end

    local branches = delivery.branches or {}

    -- 需求2: multiple reward branches → branch selection first.
    -- Skip if a branch has already been chosen (avoids re-showing the selector).
    if #branches >= 2 then
        local chosen = delivery._selectedBranchId
        if not chosen or not branches[chosen] or branches[chosen].enabled == false then
            EventTrigger.Delivery.ShowBranchSelect(player, delivery)
            return
        end
    end

    -- Single branch: preselect it
    if #branches == 1 then
        delivery._selectedBranchId = branches[1].id
    end

    -- 需求3: multiple cost options → cost option selection first.
    -- Skip if already chosen (avoids re-showing the selector).
    if #branches >= 1 then
        local branch = branches[delivery._selectedBranchId] or branches[1]
        local costOptions = branch and (branch.costOptions or {}) or {}
        if #costOptions > 1 then
            local chosenIdx = delivery._selectedCostOptionIndex
            if not chosenIdx or not costOptions[chosenIdx] then
                EventTrigger.Delivery.ShowCostOptionSelect(player, delivery)
                return
            end
        end
    end

    -- Legacy ANY mode with multiple collect items → item selection
    if #branches == 0 and (delivery.matchMode or "all") == "any" then
        local collectCount = 0
        for _, req in ipairs(delivery.requiredItems or {}) do
            if req.collect ~= false then collectCount = collectCount + 1 end
        end
        if collectCount > 1 then
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

    local bh = 34
    local gap = 16
    local confirmLabel = getText("UI_ET_Btn_Confirm")
    local batchLabel = getText("UI_ET_Btn_Batch")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local confirmW = EventTrigger.btnW(confirmLabel)
    local batchW = EventTrigger.btnW(batchLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)
    local btnY = self.height - bh - 16
    local totalW = confirmW + gap + batchW + gap + cancelW
    local bx = (self.width - totalW) / 2

    self.confirmBtn = ISButton:new(bx, btnY, confirmW, bh, confirmLabel, self, EventTriggerDeliveryConfirm.onConfirm)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)
    bx = bx + confirmW + gap

    self.batchBtn = ISButton:new(bx, btnY, batchW, bh, batchLabel, self, EventTriggerDeliveryConfirm.onBatch)
    self.batchBtn:initialise()
    self:addChild(self.batchBtn)
    bx = bx + batchW + gap

    self.cancelBtn = ISButton:new(bx, btnY, cancelW, bh, cancelLabel, self, EventTriggerDeliveryConfirm.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryConfirm.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    self.itemY = 28 + math.floor(18 * EventTrigger.US)
end

-- Finalize a delivery transaction (single or batch), shared by confirm + batch flows.
function EventTrigger.Delivery.FinalizeDelivery(player, delivery, batchCount)
    if not player or not delivery then return end
    batchCount = tonumber(batchCount) or 1
    if batchCount < 1 then batchCount = 1 end
    batchCount = math.floor(batchCount)

    local playerKey = playerKeyOf(player)
    EventTrigger.Delivery._activePrompt[playerKey] = nil
    EventTrigger.Delivery._pendingDpId[playerKey] = nil

    -- Determine selectedORIndex for legacy ANY mode ONLY.
    -- Branch mode resolves a single cost item inside resolveView(), so deriving
    -- an OR index here would desync from the 1-item cost list and could result
    -- in "no item deducted but reward granted".
    local branches = delivery.branches or {}
    local matchMode = delivery.matchMode or "all"
    local selectedORIndex = nil
    if #branches == 0 and matchMode == "any" then
        selectedORIndex = delivery._selectedORItemIndex
        if not selectedORIndex then
            for idx, req in ipairs(delivery.requiredItems or {}) do
                if req.collect ~= false then
                    selectedORIndex = idx
                    break
                end
            end
        end
    end

    delivery._batchCount = batchCount

    local ok, msg = EventTrigger.Delivery.Validate(player, delivery)
    if not ok then
        HaloTextHelper.addBadText(player, msg)
        return
    end
    local args = { id = delivery.id, batchCount = batchCount }
    if selectedORIndex then args.selectedORIndex = selectedORIndex end
    if delivery._selectedBranchId then args.branchId = delivery._selectedBranchId end
    if delivery._selectedCostOptionIndex then args.costOptionIndex = delivery._selectedCostOptionIndex end
    sendClientCommand("EventTrigger", "confirmDelivery", args)
end

function EventTriggerDeliveryConfirm:onConfirm()
    local player = getPlayer()
    local delivery = self.delivery
    self:close()
    EventTrigger.Delivery.FinalizeDelivery(player, delivery, 1)
end

function EventTriggerDeliveryConfirm:onBatch()
    local player = getPlayer()
    local delivery = self.delivery
    if not player or not delivery then
        self:close()
        return
    end
    self:close()
    EventTrigger.Delivery.ShowBatchPrompt(player, delivery)
end

function EventTriggerDeliveryConfirm:onCancel()
    local player = getPlayer()
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    EventTrigger.Delivery.ClearSelection(self.delivery)
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
    self:drawTextCentre(getText("UI_ET_Dlv_ConfirmTitle"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local delivery = self.delivery
    if not delivery then return end

    local s = EventTrigger.US
    local rowH = math.floor(20 * s)
    local y = self.itemY

    -- Top info: match mode (legacy only) + cooldown
    local branches = delivery.branches or {}
    if #branches == 0 then
        local modeStr = (delivery.matchMode == "any") and getText("UI_ET_Dlv_Any") or getText("UI_ET_Dlv_All")
        local modeText = getText("UI_ET_Dlv_MatchModeLabel", modeStr)
        self:drawText(modeText, 16, y, 0.9, 0.9, 0.3, 1, UIFont.Small)
        y = y + rowH
    end

    local cd = delivery.cooldown or {}
    if not EventTrigger.isCooldownZero(cd) then
        local cdText = getText("UI_ET_Dlv_CooldownLabel", EventTrigger.formatCooldown(cd))
        self:drawText(cdText, 16, y, 0.7, 0.9, 0.7, 1, UIFont.Small)
        y = y + rowH
    end

    -- Resolve the effective plan: 需求物品 / 消耗物品 / 奖励
    local qualifyItems, costItems, rewItems = EventTrigger.Delivery.resolveView(delivery)

    -- Assemble columns: 需求(若有) + 消耗(若有) + 奖励(始终)
    local columns = {}
    if #qualifyItems > 0 then
        columns[#columns + 1] = { title = getText("UI_ET_Dlv_RequiredItems"), items = qualifyItems, isQualify = true, color = {0.9, 0.7, 0.3} }
    end
    if #costItems > 0 then
        columns[#columns + 1] = { title = getText("UI_ET_Dlv_ConsumeItems"), items = costItems, isQualify = false, color = {0.9, 0.5, 0.5} }
    end
    columns[#columns + 1] = { title = getText("UI_ET_Dlv_RewardItems"), items = rewItems, isQualify = false, color = {0.3, 0.9, 0.5} }

    local n = #columns
    local margin = 16
    local gap = 12
    local colW = math.floor((self.width - margin * 2 - gap * (n - 1)) / n)
    if colW < 60 then colW = 60 end

    local headerY = y
    for ci, col in ipairs(columns) do
        local cx = margin + (ci - 1) * (colW + gap)
        local cy = headerY
        self:drawText(col.title, cx, cy, col.color[1], col.color[2], col.color[3], 1, UIFont.Small)
        cy = cy + rowH

        -- 列分隔线（非首列）
        if ci > 1 then
            self:drawRect(cx - gap / 2 - 1, headerY, 1, self.height - headerY - 70, 0.4, 0.4, 0.4, 0.4)
        end

        if #col.items == 0 then
            self:drawText(getText("UI_ET_Inv_None"), cx + 8, cy, 0.5, 0.5, 0.5, 1, UIFont.Small)
        else
            for _, it in ipairs(col.items) do
                local txt
                if col.isQualify then
                    local suffix = (it.collect ~= false) and getText("UI_ET_Dlv_CollectSuffix") or getText("UI_ET_Dlv_CheckOnlySuffix")
                    txt = fitText((it.displayName or "?") .. "  x" .. tostring(it.count) .. suffix, UIFont.Small, colW - 20)
                else
                    txt = fitText((it.displayName or "?") .. "  x" .. tostring(it.count), UIFont.Small, colW - 20)
                end
                self:drawText(txt, cx + 8, cy, 1, 1, 1, 1, UIFont.Small)
                cy = cy + rowH
                if cy > self.height - 70 then break end
            end
        end
    end
end

function EventTriggerDeliveryConfirm:new(player, delivery)
    local w = EventTrigger.fitW(640)
    local h = EventTrigger.fitH(420)
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
    o.player = player
    o.delivery = delivery
    o.dragging = false
    return o
end

-- ============================================================
-- Batch Count Prompt (choose N, preview totals, then finalize)
-- ============================================================
EventTrigger.Delivery._batchPromptUI = nil

function EventTrigger.Delivery.ShowBatchPrompt(player, delivery)
    if EventTrigger.Delivery._batchPromptUI then
        EventTrigger.Delivery._batchPromptUI:close()
    end
    local ui = EventTriggerBatchCountPrompt:new(player, delivery)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._batchPromptUI = ui
end

EventTriggerBatchCountPrompt = ISPanel:derive("EventTriggerBatchCountPrompt")

function EventTriggerBatchCountPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerBatchCountPrompt:computeCosts()
    self.costItems = {}
    self.maxN = nil
    local inv = self.player:getInventory()
    local _, costItems, rewardItems = EventTrigger.Delivery.resolveView(self.delivery)
    self.rewardItems = rewardItems
    local counts = EventTrigger.Delivery.CountItems(inv, costItems)
    for _, req in ipairs(costItems) do
        local have = counts[itemKey(req.fullType, req.displayName)] or 0
        local maxForThis = math.floor(have / (req.count or 1))
        if self.maxN == nil or maxForThis < self.maxN then
            self.maxN = maxForThis
        end
        self.costItems[#self.costItems + 1] = {
            fullType = req.fullType,
            displayName = req.displayName,
            count = req.count,
            have = have,
        }
    end
    if self.maxN == nil or self.maxN < 1 then self.maxN = 1 end
    self.entryValue = 1
end

function EventTriggerBatchCountPrompt:create()
    self:setAlwaysOnTop(true)
    self:computeCosts()

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerBatchCountPrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    local s = EventTrigger.US
    local rowH = math.floor(20 * s)
    local padX = 24
    local y = 28 + math.floor(18 * s)

    self.costHeaderY = y
    y = y + rowH + math.floor(2 * s)
    self.costItemsY = y
    y = y + #self.costItems * rowH + math.floor(8 * s)

    self.rewardHeaderY = y
    y = y + rowH + math.floor(2 * s)
    self.rewardItemsY = y
    y = y + #(self.rewardItems or {}) * rowH + math.floor(12 * s)

    self.entryY = y
    local entryH = math.floor(30 * s)
    y = y + entryH + math.floor(10 * s)
    self.previewY = y
    y = y + rowH * 2 + math.floor(14 * s)
    self.btnY = y

    self.rowH = rowH
    self.padX = padX
    self.entryH = entryH

    self.entry = ISTextEntryBox:new("1", padX, self.entryY, self.width - padX * 2, entryH)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry:setOnlyNumbers(true)
    self:addChild(self.entry)

    local bh = math.floor(34 * s)
    local gap = 16
    local confirmLabel = getText("UI_ET_Btn_Confirm")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local confirmW = EventTrigger.btnW(confirmLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)
    local totalW = confirmW + gap + cancelW
    local bx = (self.width - totalW) / 2

    self.confirmBtn = ISButton:new(bx, self.btnY, confirmW, bh, confirmLabel, self, EventTriggerBatchCountPrompt.onOk)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)
    bx = bx + confirmW + gap

    self.cancelBtn = ISButton:new(bx, self.btnY, cancelW, bh, cancelLabel, self, EventTriggerBatchCountPrompt.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)
end

function EventTriggerBatchCountPrompt:onOk()
    local raw = self.entry and self.entry:getText() or ""
    local n = tonumber(raw)
    if n == nil then n = 1 end
    n = math.floor(n)
    if n < 1 then n = 1 end
    if n > self.maxN then n = self.maxN end
    self:close()
    EventTrigger.Delivery.FinalizeDelivery(self.player, self.delivery, n)
end

function EventTriggerBatchCountPrompt:onCancel()
    local player = self.player
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    EventTrigger.Delivery.ClearSelection(self.delivery)
    self:close()
end

function EventTriggerBatchCountPrompt:close()
    if EventTrigger.Delivery._batchPromptUI == self then
        EventTrigger.Delivery._batchPromptUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerBatchCountPrompt:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerBatchCountPrompt:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerBatchCountPrompt:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerBatchCountPrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre(getText("UI_ET_Batch_Title"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local padX = self.padX
    local rowH = self.rowH

    -- Cost header
    self:drawText(getText("UI_ET_Batch_Cost"), padX, self.costHeaderY, 0.9, 0.7, 0.3, 1, UIFont.Small)
    local cy = self.costItemsY
    for _, c in ipairs(self.costItems) do
        local txt = fitText(string.format("%s  x%d  (%s %d)", c.displayName, c.count, getText("UI_ET_Batch_Have"), c.have), UIFont.Small, self.width - padX * 2)
        self:drawText(txt, padX + 8, cy, 1, 1, 1, 1, UIFont.Small)
        cy = cy + rowH
    end

    -- Reward header
    self:drawText(getText("UI_ET_Batch_Reward"), padX, self.rewardHeaderY, 0.3, 0.9, 0.5, 1, UIFont.Small)
    local ry = self.rewardItemsY
    for _, r in ipairs(self.rewardItems or {}) do
        local txt = fitText((r.displayName or "?") .. "  x" .. tostring(r.count), UIFont.Small, self.width - padX * 2)
        self:drawText(txt, padX + 8, ry, 1, 1, 1, 1, UIFont.Small)
        ry = ry + rowH
    end

    -- Input label
    self:drawText(getText("UI_ET_Batch_Count"), padX, self.entryY - rowH, 0.7, 0.8, 0.9, 1, UIFont.Small)

    -- Preview (read current entry value, clamp to maxN)
    local raw = self.entry and self.entry:getText() or ""
    local n = tonumber(raw) or 1
    n = math.floor(n)
    if n < 1 then n = 1 end
    if n > self.maxN then n = self.maxN end

    local costParts = {}
    for _, c in ipairs(self.costItems) do
        costParts[#costParts + 1] = (c.displayName or "?") .. " x" .. (c.count * n)
    end
    local rewardParts = {}
    for _, r in ipairs(self.rewardItems or {}) do
        rewardParts[#rewardParts + 1] = (r.displayName or "?") .. " x" .. (r.count * n)
    end
    self:drawText(getText("UI_ET_Batch_PreviewCost", table.concat(costParts, ", ")), padX, self.previewY, 0.9, 0.5, 0.3, 1, UIFont.Small)
    self:drawText(getText("UI_ET_Batch_PreviewReward", table.concat(rewardParts, ", ")), padX, self.previewY + rowH, 0.5, 0.9, 0.5, 1, UIFont.Small)
end

function EventTriggerBatchCountPrompt:new(player, delivery)
    local w = EventTrigger.fitW(560)
    local h = EventTrigger.fitH(560)
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
    o.player = player
    o.delivery = delivery
    o.dragging = false
    return o
end

-- ============================================================
-- Branch Selection UI (需求2: same consume, multiple reward branches)
-- ============================================================
EventTrigger.Delivery._branchSelectUI = nil

function EventTrigger.Delivery.ShowBranchSelect(player, delivery)
    if EventTrigger.Delivery._branchSelectUI then
        EventTrigger.Delivery._branchSelectUI:close()
    end
    local ui = EventTriggerBranchSelectPrompt:new(player, delivery)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._branchSelectUI = ui
end

EventTriggerBranchSelectPrompt = ISPanel:derive("EventTriggerBranchSelectPrompt")

function EventTriggerBranchSelectPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerBranchSelectPrompt:create()
    self:setAlwaysOnTop(true)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerBranchSelectPrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    local s = EventTrigger.US
    self.rowH = math.floor(30 * s)
    self.radioSize = 18
    self.selectedBranchIndex = nil
    self.branches = {}
    for _, b in ipairs(self.delivery.branches or {}) do
        if b.enabled ~= false then
            self.branches[#self.branches + 1] = b
        end
    end

    -- Shared cost options (same consume across all branches)
    self.costOptions = {}
    if #self.branches > 0 then
        for _, co in ipairs(self.branches[1].costOptions or {}) do
            self.costOptions[#self.costOptions + 1] = co
        end
    end
    if #self.costOptions == 0 then
        -- Fallback: legacy required items
        for _, req in ipairs(self.delivery.requiredItems or {}) do
            if req.collect ~= false then
                self.costOptions[#self.costOptions + 1] = req
            end
        end
    end

    self.costHeaderY = 28 + math.floor(18 * s)
    self.costItemsY = self.costHeaderY + self.rowH
    self.listStartY = self.costItemsY + #self.costOptions * self.rowH + math.floor(8 * s)

    local bh = math.floor(34 * s)
    local gap = 16
    self.btnY = self.height - bh - 16
    local confirmLabel = getText("UI_ET_Btn_Confirm")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local confirmW = EventTrigger.btnW(confirmLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)
    local totalW = confirmW + gap + cancelW
    local bx = (self.width - totalW) / 2

    self.confirmBtn = ISButton:new(bx, self.btnY, confirmW, bh, confirmLabel, self, EventTriggerBranchSelectPrompt.onOk)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)
    bx = bx + confirmW + gap

    self.cancelBtn = ISButton:new(bx, self.btnY, cancelW, bh, cancelLabel, self, EventTriggerBranchSelectPrompt.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self:updateConfirmState()
end

function EventTriggerBranchSelectPrompt:updateConfirmState()
    self.confirmBtn:setEnable(self.selectedBranchIndex ~= nil)
end

function EventTriggerBranchSelectPrompt:onOk()
    if not self.selectedBranchIndex then
        HaloTextHelper.addBadText(getPlayer(), getText("UI_ET_Msg_PleaseSelect"))
        return
    end
    local branch = self.branches[self.selectedBranchIndex]
    self.delivery._selectedBranchId = branch.id
    self:close()
    EventTrigger.Delivery.ShowDeliveryConfirm(self.player, self.delivery)
end

function EventTriggerBranchSelectPrompt:onCancel()
    local player = self.player
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    EventTrigger.Delivery.ClearSelection(self.delivery)
    self:close()
end

function EventTriggerBranchSelectPrompt:close()
    if EventTrigger.Delivery._branchSelectUI == self then
        EventTrigger.Delivery._branchSelectUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerBranchSelectPrompt:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    -- Click a branch row selects it
    for idx = 1, #self.branches do
        local iy = self.listStartY + (idx - 1) * self.rowH
        if y >= iy and y < iy + self.rowH then
            self.selectedBranchIndex = idx
            self:updateConfirmState()
            return true
        end
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerBranchSelectPrompt:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerBranchSelectPrompt:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerBranchSelectPrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre(getText("UI_ET_Branch_Title"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local leftX = 24

    -- Cost display: multiple costOptions are mutually-exclusive (choose one);
    -- a single costOption is a fixed requirement. Make the label match the semantics.
    local costLabel
    if #self.costOptions > 1 then
        costLabel = getText("UI_ET_Branch_CostAlt")
    else
        costLabel = getText("UI_ET_Branch_Cost")
    end
    self:drawText(costLabel, leftX, self.costHeaderY, 0.9, 0.7, 0.3, 1, UIFont.Small)
    local costY = self.costItemsY
    if #self.costOptions == 0 then
        self:drawText(getText("UI_ET_Inv_None"), leftX + 8, costY, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for _, co in ipairs(self.costOptions) do
            local txt = fitText(string.format("%s  x%s", co.displayName or "?", tostring(co.count or 1)), UIFont.Small, self.width - 120)
            self:drawText(txt, leftX + 8, costY, 1, 1, 1, 1, UIFont.Small)
            costY = costY + self.rowH
        end
    end

    -- Divider between cost and branch list
    self:drawRect(leftX, self.listStartY - 5, self.width - 48, 1, 0.4, 0.4, 0.4, 0.4)

    for idx, b in ipairs(self.branches) do
        local iy = self.listStartY + (idx - 1) * self.rowH
        local selected = (idx == self.selectedBranchIndex)
        if selected then
            self:drawRect(leftX, iy, self.width - 48, self.rowH - 2, 0.3, 0.25, 0.1, 0.3)
        end

        local cy = iy + (self.rowH - self.radioSize) / 2
        self:drawRectBorder(leftX, cy, self.radioSize, self.radioSize, 0.8, 0.8, 0.8, 0.8)
        if selected then
            self:drawRect(leftX + 4, cy + 4, self.radioSize - 8, self.radioSize - 8, 1, 0.3, 0.9, 0.3)
        end

        -- Rewards summary
        local rewardParts = {}
        for _, r in ipairs(b.rewards or {}) do
            rewardParts[#rewardParts + 1] = (r.displayName or "?") .. " x" .. tostring(r.count)
        end
        if #rewardParts == 0 then rewardParts[1] = getText("UI_ET_Inv_None") end
        local txt = fitText(string.format("%s: %s", getText("UI_ET_Branch_Option", idx), table.concat(rewardParts, ", ")), UIFont.Small, self.width - 120)
        self:drawText(txt, leftX + self.radioSize + 12, iy + 8, 1, 1, 1, 1, UIFont.Small)
    end
end

function EventTriggerBranchSelectPrompt:new(player, delivery)
    local w = EventTrigger.fitW(600)
    local h = EventTrigger.fitH(480)
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
    o.player = player
    o.delivery = delivery
    o.dragging = false
    return o
end

-- ============================================================
-- Cost Option Selection UI (需求3: same reward, multiple consume choices)
-- ============================================================
EventTrigger.Delivery._costOptionSelectUI = nil

function EventTrigger.Delivery.ShowCostOptionSelect(player, delivery)
    if EventTrigger.Delivery._costOptionSelectUI then
        EventTrigger.Delivery._costOptionSelectUI:close()
    end
    local ui = EventTriggerCostOptionSelectPrompt:new(player, delivery)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._costOptionSelectUI = ui
end

EventTriggerCostOptionSelectPrompt = ISPanel:derive("EventTriggerCostOptionSelectPrompt")

function EventTriggerCostOptionSelectPrompt:initialise()
    ISPanel.initialise(self)
    self:create()
end

function EventTriggerCostOptionSelectPrompt:create()
    self:setAlwaysOnTop(true)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerCostOptionSelectPrompt.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

    local s = EventTrigger.US
    self.rowH = math.floor(30 * s)
    self.radioSize = 18
    self.selectedIndex = nil

    -- Resolve the selected branch
    local branches = self.delivery.branches or {}
    self.branch = branches[self.delivery._selectedBranchId] or branches[1]

    -- Build available cost options (only those the player owns, filtered)
    self.costOptions = self.branch and (self.branch.costOptions or {}) or {}
    self.ownedOptions = {}
    local player = self.player
    local inv = player and player:getInventory()
    if inv then
        local counts = EventTrigger.Delivery.CountItems(inv, self.costOptions)
        for idx, co in ipairs(self.costOptions) do
            local have = counts[itemKey(co.fullType, co.displayName)] or 0
            if have > 0 then
                self.ownedOptions[#self.ownedOptions + 1] = {
                    idx = idx,
                    co = co,
                    have = have,
                }
            end
        end
    end

    self.costHeaderY = 28 + math.floor(18 * s)
    self.costItemsY = self.costHeaderY + self.rowH
    local rewItems = self.branch and (self.branch.rewards or {}) or {}
    self.rewCount = math.max(1, #rewItems)
    self.listStartY = self.costItemsY + self.rewCount * self.rowH + math.floor(8 * s)

    local bh = math.floor(34 * s)
    local gap = 16
    self.btnY = self.height - bh - 16
    local confirmLabel = getText("UI_ET_Btn_Confirm")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local confirmW = EventTrigger.btnW(confirmLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)
    local totalW = confirmW + gap + cancelW
    local bx = (self.width - totalW) / 2

    self.confirmBtn = ISButton:new(bx, self.btnY, confirmW, bh, confirmLabel, self, EventTriggerCostOptionSelectPrompt.onOk)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)
    bx = bx + confirmW + gap

    self.cancelBtn = ISButton:new(bx, self.btnY, cancelW, bh, cancelLabel, self, EventTriggerCostOptionSelectPrompt.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self:updateConfirmState()
end

function EventTriggerCostOptionSelectPrompt:updateConfirmState()
    self.confirmBtn:setEnable(self.selectedIndex ~= nil)
end

function EventTriggerCostOptionSelectPrompt:onOk()
    if not self.selectedIndex then
        HaloTextHelper.addBadText(self.player, getText("UI_ET_Msg_PleaseSelect"))
        return
    end
    local opt = self.ownedOptions[self.selectedIndex]
    self.delivery._selectedCostOptionIndex = opt.idx
    self:close()
    EventTrigger.Delivery.ShowDeliveryConfirm(self.player, self.delivery)
end

function EventTriggerCostOptionSelectPrompt:onCancel()
    local player = self.player
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    EventTrigger.Delivery.ClearSelection(self.delivery)
    self:close()
end

function EventTriggerCostOptionSelectPrompt:close()
    if EventTrigger.Delivery._costOptionSelectUI == self then
        EventTrigger.Delivery._costOptionSelectUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

function EventTriggerCostOptionSelectPrompt:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end
    for idx = 1, #self.ownedOptions do
        local iy = self.listStartY + (idx - 1) * self.rowH
        if y >= iy and y < iy + self.rowH then
            self.selectedIndex = idx
            self:updateConfirmState()
            return true
        end
    end
    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerCostOptionSelectPrompt:onMouseMove(x, y)
    if self.dragging then
        self:setX(getMouseX() - self.dragOfsX)
        self:setY(getMouseY() - self.dragOfsY)
        return true
    end
end

function EventTriggerCostOptionSelectPrompt:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
end

function EventTriggerCostOptionSelectPrompt:prerender()
    ISPanel.prerender(self)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.4, 0.4, 0.4)
    self:drawRect(0, 0, self.width, 28, 0.7, 0.15, 0.15, 0.15)
    self:drawTextCentre(getText("UI_ET_CostOption_Title"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local leftX = 24

    -- Reward (fixed) display
    self:drawText(getText("UI_ET_CostOption_Reward"), leftX, self.costHeaderY, 0.3, 0.9, 0.5, 1, UIFont.Small)
    local rwY = self.costItemsY
    local rewItems = self.branch and (self.branch.rewards or {}) or {}
    if #rewItems == 0 then
        self:drawText(getText("UI_ET_Inv_None"), leftX + 8, rwY, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for _, r in ipairs(rewItems) do
            local txt = fitText((r.displayName or "?") .. " x" .. tostring(r.count), UIFont.Small, self.width - 120)
            self:drawText(txt, leftX + 8, rwY, 1, 1, 1, 1, UIFont.Small)
            rwY = rwY + self.rowH
        end
    end

    -- Divider
    self:drawRect(leftX, self.listStartY - 5, self.width - 48, 1, 0.4, 0.4, 0.4, 0.4)

    -- Cost options (selectable, filtered by owned)
    if #self.ownedOptions == 0 then
        self:drawText(getText("UI_ET_CostOption_None"), leftX + 8, self.listStartY + 4, 0.9, 0.5, 0.5, 1, UIFont.Small)
    else
        for idx, opt in ipairs(self.ownedOptions) do
            local iy = self.listStartY + (idx - 1) * self.rowH
            local selected = (idx == self.selectedIndex)
            if selected then
                self:drawRect(leftX, iy, self.width - 48, self.rowH - 2, 0.3, 0.25, 0.1, 0.3)
            end

            local cy = iy + (self.rowH - self.radioSize) / 2
            self:drawRectBorder(leftX, cy, self.radioSize, self.radioSize, 0.8, 0.8, 0.8, 0.8)
            if selected then
                self:drawRect(leftX + 4, cy + 4, self.radioSize - 8, self.radioSize - 8, 1, 0.3, 0.9, 0.3)
            end

            local txt = fitText(string.format("%s  x%s  (%s %d)", opt.co.displayName or "?", tostring(opt.co.count or 1), getText("UI_ET_Batch_Have"), opt.have), UIFont.Small, self.width - 120)
            self:drawText(txt, leftX + self.radioSize + 12, iy + 8, 1, 1, 1, 1, UIFont.Small)
        end
    end
end

function EventTriggerCostOptionSelectPrompt:new(player, delivery)
    local w = EventTrigger.fitW(560)
    local h = EventTrigger.fitH(480)
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

    local titleH = 28
    self.infoY = titleH + 10
    local hasCooldown = not EventTrigger.isCooldownZero(self.delivery.cooldown)
    self.listStartY = self.infoY + (hasCooldown and 48 or 28)

    self.midX = math.floor(self.width / 2)
    self.leftX = 24
    self.rightX = self.midX + 20
    self.colW = self.midX - self.leftX - 20
    self.rightW = self.width - self.rightX - 24
    self.rowH = 34
    self.radioSize = 18
    self.selectedItemIndex = nil

    -- Bottom buttons (centered on TRUE widths so they never overlap)
    local bh = 34
    local gap = 24
    local btnY = self.height - bh - 18
    local confirmLabel = getText("UI_ET_Btn_Confirm")
    local cancelLabel = getText("UI_ET_Btn_Cancel")
    local confirmW = EventTrigger.btnW(confirmLabel)
    local cancelW = EventTrigger.btnW(cancelLabel)
    local confX = (self.width - (confirmW + gap + cancelW)) / 2

    self.confirmBtn = ISButton:new(confX, btnY, confirmW, bh, confirmLabel, self, EventTriggerDeliveryItemSelectOR.onConfirm)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)

    self.cancelBtn = ISButton:new(confX + confirmW + gap, btnY, cancelW, bh, cancelLabel, self, EventTriggerDeliveryItemSelectOR.onCancel)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self.closeBtn = ISButton:new(self.width - 25, 4, 21, 21, "X", self, EventTriggerDeliveryItemSelectOR.onCancel)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)

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
        HaloTextHelper.addBadText(getPlayer(), getText("UI_ET_Msg_PleaseSelect"))
        return
    end
    
    local player = getPlayer()
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    self:close()
    
    -- Store selected item index for Execute
    self.delivery._selectedORItemIndex = self.selectedItemIndex
    
    local ok, msg = EventTrigger.Delivery.Validate(player, self.delivery)
    if not ok then
        HaloTextHelper.addBadText(player, msg)
        return
    end
    sendClientCommand("EventTrigger", "confirmDelivery", { id = self.delivery.id, selectedORIndex = self.selectedItemIndex })
end

function EventTriggerDeliveryItemSelectOR:onCancel()
    local player = getPlayer()
    local playerKey = playerKeyOf(player)
    if playerKey then
        EventTrigger.Delivery._activePrompt[playerKey] = nil
        EventTrigger.Delivery._pendingDpId[playerKey] = nil
    end
    EventTrigger.Delivery.ClearSelection(self.delivery)
    self:close()
end

function EventTriggerDeliveryItemSelectOR:close()
    if EventTrigger.Delivery._itemSelectUI == self then
        EventTrigger.Delivery._itemSelectUI = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
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
    self:drawTextCentre(getText("UI_ET_Dlv_SelectTitle"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)

    local delivery = self.delivery
    if not delivery then return end

    -- Vertical divider between the two columns
    self:drawRect(self.midX, self.listStartY - 8, 1, self.height - self.listStartY - 70, 0.35, 0.35, 0.35, 0.35)

    -- ===== LEFT COLUMN: required items to choose from =====
    self:drawText(getText("UI_ET_Dlv_ChooseItem"), self.leftX, self.infoY, 0.8, 0.8, 0.8, 1, UIFont.Small)

    local cd = delivery.cooldown or {}
    if not EventTrigger.isCooldownZero(cd) then
        local cdText = getText("UI_ET_Dlv_CooldownLabel", EventTrigger.formatCooldown(cd))
        self:drawText(cdText, self.leftX, self.infoY + 20, 0.7, 0.9, 0.7, 1, UIFont.Small)
    end

    local reqItems = delivery.requiredItems or {}
    if #reqItems == 0 then
        self:drawText(getText("UI_ET_Inv_NoItems"), self.leftX, self.listStartY + 4, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for idx, req in ipairs(reqItems) do
            local iy = self.listStartY + (idx - 1) * self.rowH

            local hasItem = false
            for _, mi in ipairs(self.matchingItems or {}) do
                if mi.req == req then hasItem = true; break end
            end

            local selected = (idx == self.selectedItemIndex)
            if selected then
                self:drawRect(self.leftX, iy, self.colW, self.rowH - 2, 0.3, 0.25, 0.1, 0.3)
            end

            -- Radio circle (vertically centered within the row)
            local cy = iy + (self.rowH - self.radioSize) / 2
            self:drawRectBorder(self.leftX, cy, self.radioSize, self.radioSize, 0.8, 0.8, 0.8, 0.8)
            if selected then
                self:drawRect(self.leftX + 4, cy + 4, self.radioSize - 8, self.radioSize - 8, 1, 0.3, 0.9, 0.3)
            end

            -- Item name x count (fitted to stay clear of the tag)
            local txt = fitText((req.displayName or "?") .. "  x" .. tostring(req.count), UIFont.Small, self.colW - 86)
            local color = hasItem and {1, 1, 1} or {0.85, 0.4, 0.4}
            self:drawText(txt, self.leftX + self.radioSize + 12, iy + 8, color[1], color[2], color[3], 1, UIFont.Small)

            -- Availability tag, right-aligned within the column
            local tag = hasItem and "[OK]" or "[MISSING]"
            local tagColor = hasItem and {0.4, 0.9, 0.5} or {0.9, 0.4, 0.4}
            self:drawTextRight(tag, self.leftX + self.colW - 4, iy + 8, tagColor[1], tagColor[2], tagColor[3], 1, UIFont.Small)
        end
    end

    -- ===== RIGHT COLUMN: rewards (read-only list) =====
    self:drawText(getText("UI_ET_Dlv_Rewards"), self.rightX, self.infoY, 0.4, 0.9, 0.5, 1, UIFont.Small)

    local rewItems = delivery.rewardItems or {}
    local ry = self.listStartY
    if #rewItems == 0 then
        self:drawText(getText("UI_ET_Inv_None"), self.rightX + 4, ry + 4, 0.5, 0.5, 0.5, 1, UIFont.Small)
    else
        for _, rew in ipairs(rewItems) do
            local txt = fitText((rew.displayName or "?") .. "  x" .. tostring(rew.count), UIFont.Small, self.rightW - 8)
            self:drawText(txt, self.rightX + 4, ry + 8, 1, 1, 1, 1, UIFont.Small)
            ry = ry + self.rowH
        end
    end
end

function EventTriggerDeliveryItemSelectOR:onMouseDown(x, y)
    if y >= 0 and y < 28 then
        self.dragging = true
        self.dragOfsX = getMouseX() - self.x
        self.dragOfsY = getMouseY() - self.y
        self:setCapture(true)
        return true
    end

    -- Click a row in the LEFT column selects it (matches prerender row layout)
    local reqItems = self.delivery.requiredItems or {}
    for idx = 1, #reqItems do
        local iy = self.listStartY + (idx - 1) * self.rowH
        if x >= self.leftX and x <= self.leftX + self.colW and y >= iy and y < iy + self.rowH then
            self.selectedItemIndex = idx
            return true
        end
    end

    return ISPanel.onMouseDown(self, x, y)
end

function EventTriggerDeliveryItemSelectOR:new(player, delivery)
    local w = EventTrigger.fitW(620)
    local h = EventTrigger.fitH(480)
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
    EventTrigger.Delivery._setupPending = {
        x = x, y = y, z = z,
        requiredItems = {}, rewardItems = {},
        maxPlayers = -1, maxPerPlayer = -1,
        matchMode = "all",
        cooldown = { mode = EventTrigger.COOLDOWN_NONE },
        branchCount = 1,
        branchRewards = {},
        costOptions = {},
        _currentBranchIdx = 1,
    }
    EventTrigger.Delivery.PromptHintText()
end

function EventTrigger.Delivery.PromptHintText()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local modal = EventTriggerTextPrompt:new(
        getText("UI_ET_Dlv_Point"),
        getText("UI_ET_Dlv_Hint"),
        p.hintText or getText("UI_ET_Dlv_Point"),
        function(text)
            p.hintText = (text and #text > 0) and text or getText("UI_ET_Dlv_Point")
            EventTrigger.Delivery.PromptRadius()
        end,
        function()
            EventTrigger.Delivery._setupPending = nil
        end)
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptRadius()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Dlv_Radius"),
        getText("UI_ET_Dlv_RadiusHint"),
        tostring(p.radius or 3.0),
        function(num)
            p.radius = num
            EventTrigger.Delivery.PromptMaxPlayers()
        end,
        function() EventTrigger.Delivery._setupPending = nil end,
        function() EventTrigger.Delivery.PromptHintText() end,
        { min = 0.5 })
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptMaxPlayers()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Dlv_MaxPlayers"),
        getText("UI_ET_Dlv_MaxPlayersHint"),
        tostring(p.maxPlayers or -1),
        function(num)
            if num == 0 then num = -1 end
            p.maxPlayers = num
            EventTrigger.Delivery.PromptMaxPerPlayer()
        end,
        function() EventTrigger.Delivery._setupPending = nil end,
        function() EventTrigger.Delivery.PromptRadius() end,
        { integer = true, min = -1 })
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptMaxPerPlayer()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Dlv_MaxPerPlayer"),
        getText("UI_ET_Dlv_MaxPerPlayerHint"),
        tostring(p.maxPerPlayer or -1),
        function(num)
            if num == 0 then num = -1 end
            p.maxPerPlayer = num
            EventTrigger.Delivery.PromptMatchMode()
        end,
        function() EventTrigger.Delivery._setupPending = nil end,
        function() EventTrigger.Delivery.PromptMaxPlayers() end,
        { integer = true, min = -1 })
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptMatchMode()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local choices = {
        { label = getText("UI_ET_Dlv_MatchAll"), value = "all" },
        { label = getText("UI_ET_Dlv_MatchAny"), value = "any" },
    }
    local modal = EventTriggerChoicePrompt:new(
        getText("UI_ET_Dlv_MatchMode"),
        getText("UI_ET_Dlv_MatchModeHint"),
        choices,
        p.matchMode or "all",
        function(value)
            p.matchMode = value
            EventTrigger.Delivery.PromptCooldown()
        end,
        function() EventTrigger.Delivery._setupPending = nil end,
        function() EventTrigger.Delivery.PromptMaxPerPlayer() end)
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptCooldown()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local modal = EventTriggerCooldownPrompt:new(
        p.cooldown or { mode = EventTrigger.COOLDOWN_NONE },
        function(cd)
            p.cooldown = cd
            EventTrigger.Delivery.PromptBranchCount()
        end,
        function() EventTrigger.Delivery._setupPending = nil end,
        function() EventTrigger.Delivery.PromptMatchMode() end)
    modal:initialise()
    modal:addToUIManager()
end

-- 需求2: choose how many reward branches (same consume, multiple rewards)
function EventTrigger.Delivery.PromptBranchCount()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Cfg_BranchCount"),
        getText("UI_ET_Cfg_BranchCountHint"),
        tostring(p.branchCount or 1),
        function(num)
            if num < 1 then num = 1 end
            if num > 10 then num = 10 end
            p.branchCount = num
            p.branchRewards = {}
            p._currentBranchIdx = 1
            EventTrigger.Delivery.PromptRequiredItems()
        end,
        function() EventTrigger.Delivery._setupPending = nil end,
        function() EventTrigger.Delivery.PromptCooldown() end,
        { integer = true, min = 1, max = 10 })
    modal:initialise()
    modal:addToUIManager()
end

function EventTrigger.Delivery.PromptRequiredItems()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    p.requiredItems = p.requiredItems or {}
    EventTrigger.Delivery.ShowItemSelection("required")
end

-- 需求3: independent consume-option configuration (multiple optional consume items, same reward).
function EventTrigger.Delivery.PromptCostOptions()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    p.costOptions = p.costOptions or {}
    EventTrigger.Delivery.ShowItemSelection("cost")
end

function EventTrigger.Delivery.PromptRewardItems()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    if (p.branchCount or 1) <= 1 then
        -- Single branch: legacy reward flow
        EventTrigger.Delivery.ShowItemSelection("reward")
    else
        -- Multi-branch: configure branch 1 rewards
        p._currentBranchIdx = 1
        p.rewardItems = p.branchRewards[1] or {}
        EventTrigger.Delivery.ShowItemSelection("reward_branch")
    end
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
    -- Set the mode BEFORE initialise(), because initialise() -> create() renders
    -- the panels and reads _selectionMode. Previously it was set after, so the
    -- reward panel rendered with the stale "required" mode on first frame.
    EventTrigger.Delivery._selectionMode = mode
    local ui = EventTriggerDeliveryItemSelect:new(mode)
    ui:initialise()
    ui:addToUIManager()
    EventTrigger.Delivery._selectionUI = ui
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

    -- Done / Next button (right-aligned, true width)
    local doneLabel = getText("UI_ET_Btn_DoneNext")
    local doneW = EventTrigger.btnW(doneLabel)
    self.doneBtn = ISButton:new(self.width - doneW - 14, self.height - 42, doneW, 32, doneLabel, self, EventTriggerDeliveryItemSelect.onDone)
    self.doneBtn:initialise()
    self:addChild(self.doneBtn)

    -- Back / Cancel / Refresh buttons (left, flow layout with true widths)
    local btnY = self.height - 42
    local bx = 14
    local function placeLeft(title, handler)
        local bw = EventTrigger.btnW(title)
        local btn = ISButton:new(bx, btnY, bw, 32, title, self, handler)
        btn:initialise()
        self:addChild(btn)
        bx = bx + bw + 10
        return btn
    end
    self.backBtn = placeLeft(getText("UI_ET_Btn_Back"), EventTriggerDeliveryItemSelect.onBack)
    placeLeft(getText("UI_ET_Btn_Cancel"), EventTriggerDeliveryItemSelect.onCancel)
    self.refreshBtn = placeLeft(getText("UI_ET_Btn_Refresh"), EventTriggerDeliveryItemSelect.onRefresh)

    -- Layout params (two-column: left=list, right=selected)
    self.contentY = 36
    self.contentH = self.height - 82
    self.midX = math.floor(self.width / 2)
    self.leftW = self.midX - 20
    self.rightW = self.width - self.midX - 14
    self.rowH = 46
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
        local key = itemKey(item:getFullType(), item:getDisplayName())
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
    local itemList = setupItemList(p, mode)

    local x = 12
    local w = self.leftW
    local startY = self.contentY + 6
    local headingH = 22

    -- Heading
    local titleStr = getText("UI_ET_Inv_Title") .. "  (" .. getText("UI_ET_Inv_Page", self.leftPage + 1, self.totalPages) .. ")"
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

    local rowStartY = startY + headingH + 6
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
                if si.fullType == data.fullType and si.displayName == data.displayName then found = true; break end
            end
        end

        -- Text keeps clear of the right-side button strip (max ~150px)
        local textW = w - 156

        -- DisplayName (top)
        local name = fitText(data.displayName or "?", UIFont.Small, textW)
        local lbl = ISLabel:new(x + 4, y + 4, 18, name, 1, 1, 1, 1, UIFont.Small, true)
        lbl:initialise()
        self:addChild(lbl)
        table.insert(self.rowChildren, lbl)

        -- FullType (bottom, dimmer)
        local ft = fitText("[" .. (data.fullType or "?") .. "]", UIFont.Small, textW)
        local ftLbl = ISLabel:new(x + 4, y + 24, 18, ft, 0.45, 0.5, 0.65, 1, UIFont.Small, true)
        ftLbl:initialise()
        self:addChild(ftLbl)
        table.insert(self.rowChildren, ftLbl)

        -- Action buttons — placed right-to-left using TRUE (auto-expanded) widths
        local btnY = y + 10
        local gap = 6
        local rightEdge = x + w - 6
        local function makeRightBtn(title, handler, fullType, displayName, rightX)
            local bw = EventTrigger.btnW(title)
            local btn = ISButton:new(rightX - bw, btnY, bw, 24, title, self, handler)
            btn:initialise()
            btn.itemFullType = fullType
            btn.itemDisplayName = displayName
            self:addChild(btn)
            table.insert(self.rowChildren, btn)
            return btn
        end

        if found then
            local remBtn = makeRightBtn(getText("UI_ET_Inv_Remove"), EventTriggerDeliveryItemSelect.onRemoveItem, data.fullType, data.displayName, rightEdge)
            makeRightBtn(getText("UI_ET_Inv_Qty"), EventTriggerDeliveryItemSelect.onQtyItem, data.fullType, data.displayName, remBtn.x - gap)
        else
            makeRightBtn(getText("UI_ET_Inv_Add"), EventTriggerDeliveryItemSelect.onAddItem, data.fullType, data.displayName, rightEdge)
        end
    end

    if #self.inventoryData == 0 then
        local emptyLbl = ISLabel:new(x + 4, rowStartY + 8, 18, getText("UI_ET_Inv_Empty"), 0.5, 0.5, 0.5, 1, UIFont.Small, true)
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
        local itemList = setupItemList(p, mode)
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
    local itemList = setupItemList(p, mode)
    local selTotal = math.max(1, math.ceil(#itemList / self.rowsPerPage))

    if self.rightPage >= selTotal then self.rightPage = selTotal - 1 end
    if self.rightPage < 0 then self.rightPage = 0 end

    local x = self.midX + 8
    local startY = self.contentY + 6
    local headingH = 22

    -- Heading
    local titleStr = getText("UI_ET_Inv_Selected") .. "  (" .. getText("UI_ET_Inv_Page", self.rightPage + 1, selTotal) .. ")"
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
        local noneLbl = ISLabel:new(x + 4, startY + headingH + 8, 18, getText("UI_ET_Inv_NoneSelected"), 0.45, 0.45, 0.45, 1, UIFont.Small, true)
        noneLbl:initialise()
        self:addChild(noneLbl)
        table.insert(self.selectedChildren, noneLbl)
        return
    end

    local rowStartY = startY + headingH + 6
    local startIdx = self.rightPage * self.rowsPerPage
    local endIdx = math.min(#itemList - 1, startIdx + self.rowsPerPage - 1)

    for i = startIdx, endIdx do
        if i < 0 then break end
        local si = itemList[i + 1]
        if not si then break end

        local r = i - startIdx
        local y = rowStartY + r * self.rowH
        local itemIdx = i + 1
        local isRequired = (mode == "required")

        -- Top row: item name x count (left) + Qty/Remove buttons (right)
        local textW = self.rightW - 156
        local txt = fitText((si.displayName or "?") .. "  x" .. tostring(si.count), UIFont.Small, textW)
        local lbl = ISLabel:new(x + 4, y + 4, 18, txt, 1, 1, 0.85, 1, UIFont.Small, true)
        lbl:initialise()
        self:addChild(lbl)
        table.insert(self.selectedChildren, lbl)

        -- Action buttons — right-to-left using TRUE (auto-expanded) widths
        local gap = 6
        local rightEdge = x + self.rightW - 6
        local function makeRightBtn(title, handler, rightX)
            local bw = EventTrigger.btnW(title)
            local btn = ISButton:new(rightX - bw, y + 4, bw, 24, title, self, handler)
            btn:initialise()
            btn.itemIndex = itemIdx
            self:addChild(btn)
            table.insert(self.selectedChildren, btn)
            return btn
        end

        local delBtn = makeRightBtn(getText("UI_ET_Inv_Remove"), EventTriggerDeliveryItemSelect.onDelItem, rightEdge)
        makeRightBtn(getText("UI_ET_Inv_Qty"), EventTriggerDeliveryItemSelect.onEditQty, delBtn.x - gap)

        -- Bottom row: FullType (left) + Collect checkbox (right, required only)
        local ftW = isRequired and (self.rightW - 120) or (self.rightW - 20)
        local ft = fitText("[" .. (si.fullType or "?") .. "]", UIFont.Small, ftW)
        local ftLbl = ISLabel:new(x + 4, y + 24, 18, ft, 0.45, 0.5, 0.65, 1, UIFont.Small, true)
        ftLbl:initialise()
        self:addChild(ftLbl)
        table.insert(self.selectedChildren, ftLbl)

        if isRequired then
            local collect = si.collect ~= false
            local collectLabel = getText("UI_ET_Inv_Collect")
            local collectW = getTextManager():MeasureStringX(UIFont.Small, collectLabel)
            local cbX = x + self.rightW - collectW - 26
            local cbY = y + 26
            local collectCB = ISTickBox:new(cbX, cbY, 18, 18, "", self, function()
                EventTriggerDeliveryItemSelect.onToggleCollect(self, itemIdx)
            end)
            collectCB:initialise()
            collectCB:addOption("")
            collectCB.selected[1] = collect
            self:addChild(collectCB)
            table.insert(self.selectedChildren, collectCB)

            local collectLbl = ISLabel:new(cbX + 22, cbY, 18, collectLabel, 0.7, 0.9, 0.7, 1, UIFont.Small, true)
            collectLbl:initialise()
            self:addChild(collectLbl)
            table.insert(self.selectedChildren, collectLbl)
        end
    end
end

function EventTriggerDeliveryItemSelect:onRightPrev()
    if self.rightPage > 0 then self.rightPage = self.rightPage - 1; self:updateRightPanel() end
end

function EventTriggerDeliveryItemSelect:onRightNext()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = setupItemList(p, mode)
    local selTotal = math.max(1, math.ceil(#itemList / self.rowsPerPage))
    if self.rightPage < selTotal - 1 then self.rightPage = self.rightPage + 1; self:updateRightPanel() end
end

function EventTriggerDeliveryItemSelect:refreshUI()
    self:updateLeftPanel()
    self:updateRightPanel()
end

-- Manual refresh: re-scan player inventory and rebuild both panels.
-- Uses the same logic as create() (buildItemData + updateLeftPanel + updateRightPanel).
function EventTriggerDeliveryItemSelect:onRefresh()
    self.leftPage = 0
    self.rightPage = 0
    self:buildItemData()
    self:updateLeftPanel()
    self:updateRightPanel()
end

-- Add item from inventory list
function EventTriggerDeliveryItemSelect:onAddItem(btn)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    local itemList = setupItemList(p, mode)

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
    local itemList = setupItemList(p, mode)

    for idx, si in ipairs(itemList) do
        if si.fullType == btn.itemFullType and si.displayName == btn.itemDisplayName then
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
    local itemList = setupItemList(p, mode)

    for idx = #itemList, 1, -1 do
        if itemList[idx].fullType == btn.itemFullType and itemList[idx].displayName == btn.itemDisplayName then
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
    local itemList = setupItemList(p, mode)

    if btn.itemIndex >= 1 and btn.itemIndex <= #itemList then
        table.remove(itemList, btn.itemIndex)
    end
    self:refreshUI()
end

-- Toggle collect checkbox for required items
function EventTriggerDeliveryItemSelect:onToggleCollect(idx)
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    if mode ~= "required" then return end

    local itemList = p.requiredItems
    if idx and idx >= 1 and idx <= #itemList then
        itemList[idx].collect = not (itemList[idx].collect ~= false)
        self:refreshUI()
    end
end

function EventTriggerDeliveryItemSelect:onDone()
    local p = EventTrigger.Delivery._setupPending
    if not p then return end
    local mode = EventTrigger.Delivery._selectionMode or "required"
    self:close()

    if mode == "required" then
        EventTrigger.Delivery.PromptCostOptions()
    elseif mode == "cost" then
        EventTrigger.Delivery.PromptRewardItems()
    elseif mode == "reward_branch" then
        -- Save this branch's rewards, advance to next
        local idx = p._currentBranchIdx or 1
        p.branchRewards = p.branchRewards or {}
        p.branchRewards[idx] = p.rewardItems or {}
        if idx < (p.branchCount or 1) then
            p._currentBranchIdx = idx + 1
            p.rewardItems = p.branchRewards[idx + 1] or {}
            EventTrigger.Delivery.ShowItemSelection("reward_branch")
        else
            EventTrigger.Delivery.PlacePending()
        end
    else
        -- reward mode done -> place the delivery point
        EventTrigger.Delivery.PlacePending()
    end
end

function EventTriggerDeliveryItemSelect:onBack()
    local mode = self.mode or EventTrigger.Delivery._selectionMode or "required"
    self:close()
    if mode == "required" then
        -- required items -> back to branch count
        EventTrigger.Delivery.PromptBranchCount()
    elseif mode == "cost" then
        -- cost options -> back to required items
        EventTrigger.Delivery.PromptRequiredItems()
    elseif mode == "reward_branch" then
        local p = EventTrigger.Delivery._setupPending
        local idx = p and (p._currentBranchIdx or 1)
        if idx and idx > 1 then
            -- back to previous branch's rewards
            p._currentBranchIdx = idx - 1
            p.rewardItems = p.branchRewards[idx - 1] or {}
            EventTrigger.Delivery.ShowItemSelection("reward_branch")
        else
            -- back to cost options
            EventTrigger.Delivery.PromptCostOptions()
        end
    else
        -- reward items -> back to cost options
        EventTrigger.Delivery.PromptCostOptions()
    end
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
    local titleStr
    if mode == "required" then
        titleStr = getText("UI_ET_Cfg_RequiredTitle")
    elseif mode == "cost" then
        titleStr = getText("UI_ET_Cfg_CostTitle")
    elseif mode == "reward_branch" then
        local p = EventTrigger.Delivery._setupPending
        titleStr = getText("UI_ET_Cfg_BranchRewardTitle", p and (p._currentBranchIdx or 1) or 1)
    else
        titleStr = getText("UI_ET_Cfg_RewardTitle")
    end
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
    local w = EventTrigger.fitW(840)
    local h = EventTrigger.fitH(620)
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
    o.mode = mode
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
    local itemList = setupItemList(p, mode)
    if not itemList or idx < 1 or idx > #itemList then return end

    local item = itemList[idx]
    local defaultText = tostring(item.count or 1)
    local hintText = getText("UI_ET_Inv_Quantity", (item.displayName or "?"))

    local modal = EventTriggerNumberPrompt:new(
        getText("UI_ET_Inv_ItemQuantity"),
        hintText,
        defaultText,
        function(count)
            item.count = count
            if parentUI and parentUI.refreshUI then
                parentUI:refreshUI()
            end
        end,
        nil,
        nil,
        { integer = true, min = 1 })
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

    -- Build branches (需求2: multi-reward; 需求3: multi-consume).
    -- 需求3 consume options come from the independent "cost" step (p.costOptions),
    -- NOT from ET's native ANY/ALL qualification (requiredItems + matchMode).
    -- Branch model is used when: explicit cost options configured, OR multi-reward branches.
    local branchCount = p.branchCount or 1
    local hasExplicitCost = #(p.costOptions or {}) > 0
    local branches = {}

    if hasExplicitCost or branchCount > 1 then
        local costOptions = {}
        for _, c in ipairs(p.costOptions or {}) do
            costOptions[#costOptions + 1] = {
                fullType = c.fullType,
                displayName = c.displayName,
                count = c.count,
            }
        end
        if #costOptions == 0 then
            -- 需求2 fallback: shared consume derived from requiredItems (collect=true)
            for _, r in ipairs(p.requiredItems or {}) do
                if r.collect ~= false then
                    costOptions[#costOptions + 1] = {
                        fullType = r.fullType,
                        displayName = r.displayName,
                        count = r.count,
                    }
                end
            end
        end
        for i = 1, branchCount do
            local rewards
            if branchCount <= 1 then
                rewards = p.rewardItems or {}
            else
                rewards = p.branchRewards[i] or {}
            end
            branches[i] = {
                id = i,
                enabled = true,
                costOptions = costOptions,
                rewards = rewards,
            }
        end
    end

    local args = {
        x = p.x, y = p.y, z = p.z,
        hintText = p.hintText or "Delivery Point",
        range = p.radius or 3.0,
        maxPlayers = p.maxPlayers or -1,
        maxPerPlayer = p.maxPerPlayer or -1,
        matchMode = p.matchMode or "all",
        cooldown = p.cooldown or { mode = EventTrigger.COOLDOWN_NONE },
        requiredItems = p.requiredItems or {},
        rewardItems = p.rewardItems or {},
        branches = branches,
        creator = EventTrigger.GetCurrentPlayerId(),
    }

    dbg("PlacePending: placing delivery at (", p.x, p.y, p.z, "), hint=", p.hintText,
        " reqItems=", #args.requiredItems, " rewardItems=", #args.rewardItems,
        " branches=", #args.branches,
        " matchMode=", args.matchMode, " cooldown=", EventTrigger.formatCooldown(args.cooldown),
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
            dp.cooldown = EventTrigger.makeCooldown(p.cooldown or { mode = EventTrigger.COOLDOWN_NONE })
            dp.requiredItems = p.requiredItems or {}
            dp.rewardItems = p.rewardItems or {}
            dp.branches = branches
            args.id = dp.id
            args.triggerCount = dp.triggerCount or 0
            sendClientCommand("EventTrigger", "editDelivery", args)
        end
        EventTrigger.Delivery._setupPending = nil
        if EventTrigger._ui then EventTrigger._ui:refreshList() end
        return
    end

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
        cooldown = EventTrigger.makeCooldown(p.cooldown or { mode = EventTrigger.COOLDOWN_NONE }),
        requiredItems = p.requiredItems or {},
        rewardItems = p.rewardItems or {},
        branches = branches,
        playerDeliveries = {},
        playerCooldowns = {},
        enabled = true,
        creator = EventTrigger.GetCurrentPlayerId(),
        createdAt = os.time(),
        triggerCount = 0,
        triggeredBy = {},
    }
    EventTrigger.deliveryPoints[#EventTrigger.deliveryPoints + 1] = dp
    args.id = dp.id
    sendClientCommand("EventTrigger", "placeDeliveryPoint", args)
    if EventTrigger._ui then EventTrigger._ui:refreshList() end

    EventTrigger.Delivery._setupPending = nil
end

-- ============================================================
-- Handle server delivery result (add rewards on success)
-- ============================================================
function EventTrigger.Delivery.OnDeliveryResult(player, success, message, rewardItems)
    local playerKey = playerKeyOf(player)
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
    if EventTrigger.Delivery._promptUI then EventTrigger.Delivery._promptUI:close() end
    if EventTrigger.Delivery._confirmUI then EventTrigger.Delivery._confirmUI:close() end
    if EventTrigger.Delivery._selectionUI then EventTrigger.Delivery._selectionUI:close() end
    if EventTrigger.Delivery._batchPromptUI then EventTrigger.Delivery._batchPromptUI:close() end
    if EventTrigger.Delivery._branchSelectUI then EventTrigger.Delivery._branchSelectUI:close() end
    if EventTrigger.Delivery._costOptionSelectUI then EventTrigger.Delivery._costOptionSelectUI:close() end
    if EventTrigger.Delivery._itemSelectUI then EventTrigger.Delivery._itemSelectUI:close() end
    if EventTrigger.Delivery._histUI then EventTrigger.Delivery._histUI:close() end
end

-- ============================================================
-- UI Management: Edit / Delete / Reset / History for EventTriggerUI
-- ============================================================

-- Delete a delivery point
function EventTrigger.Delivery.DeleteDelivery(dlvIdx, dp)
    if not dp or not dp.id then return end
    sendClientCommand("EventTrigger", "deleteDeliveryPoint", { id = dp.id })
    if EventTrigger._ui then EventTrigger._ui:refreshList() end
end

-- Reset delivery completion status
function EventTrigger.Delivery.ResetDelivery(dlvIdx, dp)
    if not dp or not dp.id then return end
    dp.triggerCount = 0
    dp.triggeredBy = {}
    dp.playerDeliveries = {}
    dp.playerCooldowns = {}
    sendClientCommand("EventTrigger", "resetDelivery", { id = dp.id })
    if EventTrigger._ui then EventTrigger._ui:refreshList() end
end

-- Toggle delivery point enabled/disabled
function EventTrigger.Delivery.ToggleDelivery(dlvIdx, dp)
    if not dp or not dp.id then return end
    local enabled = not (dp.enabled ~= false)
    dp.enabled = enabled
    sendClientCommand("EventTrigger", "toggleDelivery", { id = dp.id, enabled = enabled })
    if EventTrigger._ui then EventTrigger._ui:refreshList() end
end

-- Edit delivery point: re-open the setup wizard with existing values
function EventTrigger.Delivery.EditDelivery(dlvIdx, dp)
    if not dp then return end
    -- Close any existing selection UI
    EventTrigger.Delivery.CloseAllUIs()

    -- Restore branch config when editing a multi-branch point
    local branches = dp.branches or {}
    local branchCount = #branches
    if branchCount < 1 then branchCount = 1 end
    local branchRewards = {}
    for i, b in ipairs(branches) do
        branchRewards[i] = EventTrigger.Delivery._cloneItems(b.rewards or {})
    end

    -- Restore cost options (需求3) from the first branch so editing does not drop them.
    local costOptions = {}
    if #branches > 0 then
        costOptions = EventTrigger.Delivery._cloneItems(branches[1].costOptions or {})
    end

    -- Start edit wizard at delivery point position, pre-populated
    EventTrigger.Delivery._setupPending = {
        x = dp.x, y = dp.y, z = dp.z,
        hintText = dp.hintText,
        radius = dp.range,
        maxPlayers = dp.maxPlayers or -1,
        maxPerPlayer = dp.maxPerPlayer or -1,
        matchMode = dp.matchMode or "all",
        cooldown = EventTrigger.makeCooldown(dp.cooldown or { mode = EventTrigger.COOLDOWN_NONE }),
        requiredItems = EventTrigger.Delivery._cloneItems(dp.requiredItems or {}),
        rewardItems = EventTrigger.Delivery._cloneItems(dp.rewardItems or {}),
        costOptions = costOptions,
        branchCount = branchCount,
        branchRewards = branchRewards,
        _currentBranchIdx = 1,
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
            collect = item.collect ~= false,
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
    local F = UIFont.Small
    local rowH = math.floor(22 * EventTrigger.US)
    local maxW = self.width - 28
    local x = 14
    local y = 28 + math.floor(18 * EventTrigger.US)

    if not dp then
        self.lines[#self.lines + 1] = { x = x, y = y, text = getText("UI_ET_Hist_DeliveryNotFound"), color = {1,0.5,0.5} }
        return
    end

    self.lines[#self.lines + 1] = { x = x, y = y, text = fitText(getText("UI_ET_Hist_Position", dp.x, dp.y, dp.z), F, maxW), color = {0.5,0.8,1} }
    y = y + rowH
    self.lines[#self.lines + 1] = { x = x, y = y, text = fitText(getText("UI_ET_Hist_Hint", (dp.hintText or "")), F, maxW - 60), color = {0.8,0.8,1} }
    y = y + rowH
    self.lines[#self.lines + 1] = { x = x, y = y, text = fitText(getText("UI_ET_Hist_Creator", (dp.creator or "?")), F, maxW - 80), color = {0.8,0.8,0.5} }
    y = y + rowH
    local statusStr = (dp.triggerCount or 0) > 0 and getText("UI_ET_Dlv_Completed") or getText("UI_ET_Dlv_Ready")
    self.lines[#self.lines + 1] = { x = x, y = y, text = getText("UI_ET_Hist_RangeStatus", (dp.range or 3), statusStr), color = {1,1,1} }
    y = y + rowH

    -- Match mode and cooldown
    local modeStr = (dp.matchMode == "any") and getText("UI_ET_Dlv_Any") or getText("UI_ET_Dlv_All")
    local modeText = getText("UI_ET_Dlv_MatchModeLabel", modeStr)
    self.lines[#self.lines + 1] = { x = x, y = y, text = modeText, color = {0.9,0.9,0.3} }
    y = y + rowH

    local cd = dp.cooldown or {}
    if not EventTrigger.isCooldownZero(cd) then
        local cdText = getText("UI_ET_Dlv_CooldownLabel", EventTrigger.formatCooldown(cd))
        self.lines[#self.lines + 1] = { x = x, y = y, text = cdText, color = {0.7,0.9,0.7} }
        y = y + rowH
    end

    if dp.maxPlayers and dp.maxPlayers > 0 then
        self.lines[#self.lines + 1] = { x = x, y = y, text = getText("UI_ET_Hist_MaxPlayers", dp.maxPlayers), color = {0.8,0.8,1} }
        y = y + rowH
    end
    if dp.maxPerPlayer and dp.maxPerPlayer > 0 then
        self.lines[#self.lines + 1] = { x = x, y = y, text = getText("UI_ET_Hist_MaxPerPlayer", dp.maxPerPlayer), color = {0.8,0.8,1} }
        y = y + rowH
    end

    y = y + 6

    -- Required items
    self.lines[#self.lines + 1] = { x = x, y = y, text = getText("UI_ET_Hist_RequiredItems"), color = {0.9,0.7,0.3} }
    y = y + rowH
    local reqItems = dp.requiredItems or {}
    if #reqItems == 0 then
        self.lines[#self.lines + 1] = { x = x + 8, y = y, text = getText("UI_ET_Inv_None"), color = {0.5,0.5,0.5} }
        y = y + rowH
    else
        for _, item in ipairs(reqItems) do
            local collectStr = (item.collect ~= false) and getText("UI_ET_Dlv_CollectSuffix") or getText("UI_ET_Dlv_CheckOnlySuffix")
            local txt = fitText(item.displayName .. " x" .. tostring(item.count) .. collectStr .. "  [" .. item.fullType .. "]", F, maxW - 20)
            self.lines[#self.lines + 1] = { x = x + 8, y = y, text = txt, color = {1,1,1} }
            y = y + rowH
        end
    end

    y = y + 6
    self.lines[#self.lines + 1] = { x = x, y = y, text = getText("UI_ET_Hist_RewardItems"), color = {0.3,0.9,0.5} }
    y = y + rowH
    local rewItems = dp.rewardItems or {}
    if #rewItems == 0 then
        self.lines[#self.lines + 1] = { x = x + 8, y = y, text = getText("UI_ET_Inv_None"), color = {0.5,0.5,0.5} }
        y = y + rowH
    else
        for _, item in ipairs(rewItems) do
            local txt = fitText(item.displayName .. " x" .. tostring(item.count) .. "  [" .. item.fullType .. "]", F, maxW - 20)
            self.lines[#self.lines + 1] = { x = x + 8, y = y, text = txt, color = {1,1,1} }
            y = y + rowH
        end
    end

    -- Trigger history
    y = y + 6
    local trigBy = dp.triggeredBy or {}
    self.lines[#self.lines + 1] = { x = x, y = y, text = getText("UI_ET_Hist_TotalDeliveries", #trigBy), color = {1,1,1} }
    y = y + rowH
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
        self.lines[#self.lines + 1] = { x = x + 8, y = y, text = fitText(line, F, maxW - 20), color = {0.8,0.9,1} }
        y = y + rowH
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
    self:drawTextCentre(getText("UI_ET_Hist_DeliveryDetails"), self.width / 2, 7, 1, 1, 1, 1, UIFont.Medium)
    for _, line in ipairs(self.lines) do
        self:drawText(line.text, line.x, line.y, line.color[1], line.color[2], line.color[3], 1, UIFont.Small)
    end
end

function EventTriggerDeliveryHistUI:new(dp)
    local w = EventTrigger.fitW(640)
    local h = EventTrigger.fitH(520)
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
    o.dp = dp
    o.dragging = false
    return o
end
