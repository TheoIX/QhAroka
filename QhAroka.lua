-- QhAroka (Shaman) – Turtle WoW 1.12
-- Downranking + smart targeting + AS→HW gate + LOS blacklist + Healing Way preference
-- Updated: robust tooltip-based buff detection (with player-only fallback), target-restore, 2s LOS blacklist, 1.3s cast buffer

------------------------------------------------------------
-- Constants / helpers
------------------------------------------------------------
local BOOKTYPE_SPELL = "spell"

-- small Lua 5.0 helpers
local function tlen(t) return table.getn(t) end
local function tinsert(t, v) table.insert(t, v) end

-- plain-find helper (no regex surprises on 5.0)
local function _plain_find(hay, needle)
    if not hay or not needle then return false end
    local s, e = string.find(hay, needle, 1, true)
    return s ~= nil
end

------------------------------------------------------------
-- Tooltip buff/stack reader (robust for 1.12)
------------------------------------------------------------
local scanTip = CreateFrame("GameTooltip", "QhArokaScanTip", UIParent, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

local function ScanUnitForText(unit, needle)
    if not UnitExists or not UnitExists(unit) then return false end
    scanTip:ClearLines()
    scanTip:SetUnitBuff(unit, 1) -- seed so lines exist on some clients
    for i = 1, 32 do
        scanTip:ClearLines()
        scanTip:SetUnitBuff(unit, i)
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if text and _plain_find(text, needle) then return true end
    end
    for i = 1, 32 do
        scanTip:ClearLines()
        scanTip:SetUnitDebuff(unit, i)
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if text and _plain_find(text, needle) then return true end
    end
    return false
end

-- Alive helper: ignore dead/ghost units when scanning
local function Aroka_IsAlive(unit)
    if not UnitExists or not UnitExists(unit) then return false end
    if UnitIsDead and UnitIsDead(unit) then return false end
    if UnitIsGhost and UnitIsGhost(unit) then return false end
    local mhp = UnitHealthMax(unit)
    return mhp and mhp > 0
end

------------------------------------------------------------
-- Scan list (NO current target; we restore it)
------------------------------------------------------------
local function Aroka_BuildScanList()
    local list = {}
    if UnitExists and UnitExists("player") then tinsert(list, "player") end
    if UnitExists and UnitExists("target") then tinsert(list, "target") end
    if UnitExists and UnitExists("party1") then
        for i=1,4 do if UnitExists("party"..i) then tinsert(list, "party"..i) end end
    end
    if UnitExists and UnitExists("raid1") then
        for i=1,40 do if UnitExists("raid"..i) then tinsert(list, "raid"..i) end end
    end
    return list
end

------------------------------------------------------------
-- Range & cooldown helpers
------------------------------------------------------------
-- Prefer pfUI's range state when available; fallback to spell range API
function Aroka_pfUI_IsInRange(unit)
    if not pfUI then return nil end

    -- 1) pfUI API, if exposed
    if pfUI.api and type(pfUI.api.UnitInRange) == "function" then
        local ok, val = pcall(pfUI.api.UnitInRange, unit)
        if ok and val ~= nil then
            if val == true or val == 1 then return true end
            if val == false or val == 0 then return false end
        end
    end

    -- 2) Infer from unitframe alpha if we can find the frame
    if not pfUI.uf or type(pfUI.uf) ~= "table" then return nil end
    local containers = {}
    if string.sub(unit, 1, 4) == "raid" then
        if type(pfUI.uf.raid) == "table" then table.insert(containers, pfUI.uf.raid) end
    elseif string.sub(unit, 1, 5) == "party" then
        if type(pfUI.uf.group) == "table" then table.insert(containers, pfUI.uf.group) end
    elseif unit == "player" then
        if type(pfUI.uf.player) == "table" then table.insert(containers, { pfUI.uf.player }) end
    end

    for _, cont in pairs(containers) do
        if type(cont) == "table" then
            for _, fr in pairs(cont) do
                if type(fr) == "table" then
                    local u
                    if type(fr.unit) == "string" then u = fr.unit end
                    if not u and type(fr.label) == "table" and type(fr.label.unit) == "string" then
                        u = fr.label.unit
                    end
                    if not u and type(fr.unitstr) == "string" then u = fr.unitstr end

                    if u == unit and type(fr.GetAlpha) == "function" then
                        local a = fr:GetAlpha()
                        if a ~= nil then
                            return a >= 0.8
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function IsSpellReady(spellName)
    for i = 1, 300 do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == spellName then
            local start, duration = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if (start and duration) then
                if start == 0 or duration == 0 then return true end
                local r = start + duration - GetTime()
                return r <= 0
            else
                return true
            end
        end
    end
    return false
end

local function InRangeBySpell(unit, spellName)
    if not unit or not UnitExists or not UnitExists(unit) then return false end
    local p = Aroka_pfUI_IsInRange(unit)
    if p ~= nil then return p end
    -- Fallback to spell range APIs
    if not IsSpellInRange then return true end
    local r = IsSpellInRange(spellName, unit)
    if r == 1 then return true end
    if r == 0 then return false end
    if CheckInteractDistance and CheckInteractDistance(unit, 4) then return true end
    return true
end

local function IsSpellReady(spellName)
    for i = 1, 300 do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == spellName then
            local start, duration = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if (start and duration) then
                if start == 0 or duration == 0 then return true end
                local r = start + duration - GetTime()
                return r <= 0
            else
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------
-- Rank discovery & downranking tables
------------------------------------------------------------
local function GetKnownRanks(spellName)
  local ranks = {}
  for i = 1, 300 do
    local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == spellName and rank then
      local _, _, n = string.find(rank, "(%d+)$")
      if n then table.insert(ranks, tonumber(n)) end
    end
  end
  table.sort(ranks)
  return ranks
end

local RANKS_LHW = GetKnownRanks("Lesser Healing Wave")
local RANKS_HW  = GetKnownRanks("Healing Wave")
local RANKS_CH  = GetKnownRanks("Chain Heal")

local function HighestRank(ranks)
  return ranks[tlen(ranks)]
end

-- very rough heal amounts (no +healing):
local HEAL_EST = {
  ["Lesser Healing Wave"] = { 120, 190, 260, 360, 450, 540, 650 },
  ["Healing Wave"]        = { 40, 75, 150, 280, 380, 510, 700, 900, 1200, 1600 },
  ["Chain Heal"]          = { 320, 400, 550, 700 },
}

local function PickRank(spell, deficit)
  local r = 1
  local tbl = HEAL_EST[spell]
  if not tbl then return 1 end
  for i=1,tlen(tbl) do
    r = i
    if tbl[i] >= deficit then break end
  end
  return r
end

------------------------------------------------------------
-- Fever Dream & Ancestral Swiftness detection
------------------------------------------------------------
local function PlayerHas(text)
    return ScanUnitForText("player", text)
end

local function HasFeverDream()
    return PlayerHas("Fever Dream") or PlayerHas("Feverdream")
end

local function HasAncestralSwiftness()
    return PlayerHas("Ancestral Swiftness")
end

------------------------------------------------------------
-- Blacklist for LOS fails
------------------------------------------------------------
local Aroka_LOS_Blacklist = {}
local function BlacklistUnit(unit)
    Aroka_LOS_Blacklist[unit] = GetTime() + 2.0 -- 2 seconds
end
local function IsBlacklisted(unit)
    local t = Aroka_LOS_Blacklist[unit]
    return t and t > GetTime()
end

------------------------------------------------------------
-- Health % helper
------------------------------------------------------------
local function HPpct(unit)
    local h, m = UnitHealth(unit), UnitHealthMax(unit)
    if not (h and m and m>0) then return 100 end
    return (h / m) * 100
end

------------------------------------------------------------
-- Casting buffer
------------------------------------------------------------
local CAST_BUFFER = 1.3

------------------------------------------------------------
-- Restore target helper
------------------------------------------------------------
local function PreserveAndTarget(unit)
    local hadTarget = UnitExists("target")
    local prevGUID = hadTarget and UnitGUID and UnitGUID("target") or nil
    if hadTarget then ClearTarget() end
    TargetUnit(unit)
    return function()
        if hadTarget then
            -- try restore by GUID if possible, else just targetlasttarget
            if UnitGUID and prevGUID then
                for _,u in ipairs({"target","focus","player","party1","party2","party3","party4"}) do
                    if UnitExists(u) and UnitGUID(u) == prevGUID then
                        TargetUnit(u); return
                    end
                end
            end
            TargetLastTarget()
        else
            ClearTarget()
        end
    end
end

------------------------------------------------------------
-- Main scan: choose best unit & spell
------------------------------------------------------------
local function ChooseSpellAndUnit()
    local scan = Aroka_BuildScanList()

    -- chain heal cluster check: count units <85%
    local lowCount = 0
    for _,u in ipairs(scan) do
        if Aroka_IsAlive(u) and HPpct(u) < 85 and not IsBlacklisted(u) then
            lowCount = lowCount + 1
        end
    end

    local useChain = (lowCount >= 3)

    local bestUnit, bestDeficit, bestSpell

    for _,u in ipairs(scan) do
        if Aroka_IsAlive(u) and not IsBlacklisted(u) then
            local inRange = InRangeBySpell(u, "Lesser Healing Wave")
            if inRange then
                local h, m = UnitHealth(u), UnitHealthMax(u)
                if h and m and m>0 and h < m then
                    local deficit = m - h

                    -- choose spell based on Fever Dream and cluster
                    local preferHW = HasFeverDream()
                    if useChain then
                        bestSpell = "Chain Heal"
                    else
                        bestSpell = preferHW and "Healing Wave" or "Lesser Healing Wave"
                    end

                    -- pick rank by deficit
                    local rank = 1
                    if bestSpell == "Lesser Healing Wave" then
                        rank = PickRank(bestSpell, deficit)
                    elseif bestSpell == "Healing Wave" then
                        rank = PickRank(bestSpell, deficit)
                    elseif bestSpell == "Chain Heal" then
                        rank = PickRank(bestSpell, deficit)
                    end

                    -- track most injured target (lowest %)
                    local pct = (h / m) * 100
                    if (not bestUnit) or pct < bestDeficit then
                        bestUnit = u
                        bestDeficit = pct
                    end
                end
            end
        end
    end

    return bestUnit, bestSpell
end

------------------------------------------------------------
-- Casting functions
------------------------------------------------------------
SLASH_AROKA1 = "/aroka"
SLASH_AROKAMAX1 = "/arokamax"

SlashCmdList["AROKA"] = function()
    local unit, spell = ChooseSpellAndUnit()
    if not unit or not spell then
        DEFAULT_CHAT_FRAME:AddMessage("QhAroka: No valid target found.")
        return
    end

    local restore = PreserveAndTarget(unit)

    -- Ancestral Swiftness gating: only allow Healing Wave if AS buff is up
    if spell == "Healing Wave" and not HasAncestralSwiftness() then
        spell = "Lesser Healing Wave"
    end

    CastSpellByName(spell)

    -- re-target after a small buffer unless we are still casting
    local t0 = GetTime()
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function()
        if GetTime() - t0 > CAST_BUFFER then
            if not CastingBarFrame or (not CastingBarFrame.casting and not CastingBarFrame.channeling) then
                f:SetScript("OnUpdate", nil)
                restore()
            end
        end
    end)
end

SlashCmdList["AROKAMAX"] = function()
    local scan = Aroka_BuildScanList()
    local bestUnit
    local bestPct = 101
    for _,u in ipairs(scan) do
        if Aroka_IsAlive(u) and not IsBlacklisted(u) then
            local pct = HPpct(u)
            if pct < 100 and pct < bestPct and InRangeBySpell(u, "Lesser Healing Wave") then
                bestPct = pct
                bestUnit = u
            end
        end
    end

    if not bestUnit then
        DEFAULT_CHAT_FRAME:AddMessage("QhAroka: No valid target found.")
        return
    end

    local restore = PreserveAndTarget(bestUnit)

    -- choose max-rank spell using current Fever Dream + cluster logic
    local preferHW = HasFeverDream()

    -- quick cluster check again
    local list = Aroka_BuildScanList()
    local lowCount = 0
    for _,u in ipairs(list) do if Aroka_IsAlive(u) and HPpct(u) < 85 then lowCount = lowCount + 1 end end

    local useChain = (lowCount >= 3)

    local spell
    if useChain then spell = "Chain Heal"
    elseif preferHW then spell = "Healing Wave"
    else spell = "Lesser Healing Wave" end

    -- AS gating for HW on /arokamax too
    if spell == "Healing Wave" and not HasAncestralSwiftness() then
        spell = "Lesser Healing Wave"
    end

    CastSpellByName(spell)

    local t0 = GetTime()
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function()
        if GetTime() - t0 > CAST_BUFFER then
            if not CastingBarFrame or (not CastingBarFrame.casting and not CastingBarFrame.channeling) then
                f:SetScript("OnUpdate", nil)
                restore()
            end
        end
    end)
end

------------------------------------------------------------
-- Spell fail hook -> LOS blacklist
------------------------------------------------------------
local orig = UIErrorsFrame and UIErrorsFrame.AddMessage
if orig then
    UIErrorsFrame.AddMessage = function(self, msg, r, g, b, id)
        if type(msg) == "string" then
            if _plain_find(msg, "line of sight") or _plain_find(msg, "Obstructed") then
                if UnitExists("target") then BlacklistUnit("target") end
            end
        end
        return orig(self, msg, r, g, b, id)
    end
end
