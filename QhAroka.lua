-- QhAroka (Shaman) – Turtle WoW 1.12
-- Downranking + smart targeting + emergency Ancestral Swiftness + LOS blacklist + Healing Way priority
-- Rules:
--   • Do nothing if nobody is injured (<100%).
--   • Self is TOP PRIORITY only if self < 50% HP.
--   • If self ≥ 50% HP, only heal self when EVERYONE ELSE is exactly 100% HP.
--   • AoE: If 3+ allies are <85% HP ⇒ Chain Heal.
--   • Fever Dream buff ⇒ prefer Chain Heal (even if fewer than 3 injured).
--   • Emergency: If any ally < 50% and Ancestral Swiftness is ready ⇒ cast AS, and only if you gain the AS buff, immediately cast Healing Wave on that ally.
--   • LOS failures → 0.2s blacklist by name with a chat notice.
--   • Healing Way buff on a unit gives them a 5% HP priority buffer (treated as 5% lower HP).
--   • /aroka uses downrank; /arokamax forces max rank.

local BOOKTYPE_SPELL = "spell"

-- ===== Small Lua 5.0 helpers =====
local function tlen(t) return table.getn(t) end
local function tinsert(t, v) table.insert(t, v) end

-- ===== Unit name helper & LOS blacklist =====
local function UnitNameSafe(unit)
    local n = UnitName(unit)
    if n then return n end
    return tostring(unit or "?")
end

local Aroka_Blacklist = {}      -- [name] = expireTime
local Aroka_LastCastTargetName = nil

local function Aroka_IsBlacklisted(unit)
    local name = UnitNameSafe(unit)
    local now = GetTime and GetTime() or 0
    local exp = Aroka_Blacklist[name]
    if exp and now < exp then
        return true
    end
    if exp and now >= exp then
        Aroka_Blacklist[name] = nil
    end
    return false
end

-- ===== Scan list =====
local function Aroka_BuildScanList()
    local units = { "player", "target" }
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, 40 do tinsert(units, "raid"..i) end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        for i = 1, 4 do tinsert(units, "party"..i) end
        for i = 1, 4 do tinsert(units, "party"..i.."target") end
    end
    return units
end

-- ===== Simple buff partial match =====
local function HasBuff(unit, partial)
    for i = 1, 40 do
        local buff = UnitBuff(unit, i)
        if not buff then break end
        if string.find(buff, partial) then return true end
    end
    return false
end

-- ===== Range helper (some spells return nil range on 1.12) =====
local function Aroka_IsInRange(spellName, unit)
    if not IsSpellInRange then return true end
    local r = IsSpellInRange(spellName, unit)
    if r == 1 then return true end
    if r == 0 then return false end
    -- r == nil → unknown range; use a soft proxy and be optimistic
    if CheckInteractDistance and CheckInteractDistance(unit, 4) then return true end
    return true
end

-- ===== Cooldown/ready check =====
local function IsSpellReady(spellName)
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == spellName then
            local start, dur = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if (not start) or dur == 0 or start == 0 then return true end
            local now = GetTime()
            return now >= (start + dur)
        end
    end
    return false
end

-- ===== Safe cast on unit by name (preserve hostile target) =====
local function Aroka_SafeCastOnUnitByName(spellNameWithOptionalRank, unit)
    local had, hostile = false, false
    if UnitExists("target") then
        had = true
        hostile = (UnitCanAttack("player", "target") == 1)
    end

    -- Remember last attempted target for LOS handling
    Aroka_LastCastTargetName = UnitNameSafe(unit)

    -- Clear any pending target cursor
    if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end

    CastSpellByName(spellNameWithOptionalRank)
    if SpellIsTargeting and SpellIsTargeting() then SpellTargetUnit(unit) end

    if hostile and had then TargetLastTarget() end
end

-- ===== Rank discovery =====
local function Aroka_GetKnownRanks(spellName) -- ascending numeric ranks {1,2,...}
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

-- ===== Approximate base heals per rank (non-crit, pre-bonus) =====
local LHW_BASE = { [1]=174, [2]=264, [3]=359, [4]=486, [5]=668, [6]=880 }
local HW_BASE  = { [1]=39,  [2]=71,  [3]=142, [4]=292, [5]=408, [6]=579, [7]=797, [8]=1092, [9]=1464, [10]=1735 }
local CH_BASE  = { [1]=356, [2]=449, [3]=607 }

local function Aroka_EffectiveBase(spellName, rank)
    local base
    if spellName == "Lesser Healing Wave" then base = LHW_BASE[rank]
    elseif spellName == "Healing Wave" then base = HW_BASE[rank]
    elseif spellName == "Chain Heal" then base = CH_BASE[rank] end
    if not base then return nil end

    local bonus = 0
    if BonusScanner and BonusScanner.GetBonus then
        local b = BonusScanner:GetBonus("HEAL")
        if b and tonumber(b) then bonus = bonus + tonumber(b) end
    end

    local coeff = 0.43 -- LHW
    if spellName == "Healing Wave" then coeff = 0.86 end
    if spellName == "Chain Heal" then coeff = 0.71 end
    return base + (bonus * coeff)
end

-- ===== Downrank picker =====
local function Aroka_PickRank(spellName, unit)
    local hp, mhp = UnitHealth(unit), UnitHealthMax(unit)
    if not mhp or mhp <= 0 or not hp then return nil end
    local missing = mhp - hp

    local ranks = Aroka_GetKnownRanks(spellName)
    if tlen(ranks) == 0 then return nil end

    local best = ranks[tlen(ranks)] -- default to max
    for i=1,tlen(ranks) do
        local r = ranks[i]
        local eff = Aroka_EffectiveBase(spellName, r)
        if eff and eff >= missing then best = r; break end
    end
    return best
end

-- ===== Buff flags =====
local function HasFeverDream() return HasBuff("player", "Fever Dream") end

-- ===== Group health helpers =====
local function Aroka_AnyoneInjured()
    local units = Aroka_BuildScanList()
    for i=1,tlen(units) do
        local u = units[i]
        local hp, mhp = UnitHealth(u), UnitHealthMax(u)
        if mhp and mhp > 0 and hp and hp < mhp and UnitIsFriend("player", u) then
            return true
        end
    end
    return false
end

local function Aroka_AnyoneElseInjured()
    local units = Aroka_BuildScanList()
    for i=1,tlen(units) do
        local u = units[i]
        if u ~= "player" then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp and hp < mhp and UnitIsFriend("player", u) then
                return true
            end
        end
    end
    return false
end

local function Aroka_AllOthersFullHP()
    local units = Aroka_BuildScanList()
    for i=1,tlen(units) do
        local u = units[i]
        if u ~= "player" and UnitIsFriend("player", u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp and (hp < mhp) then
                return false
            end
        end
    end
    return true
end

local function Aroka_CountInjured(thresholdFrac)
    local units = Aroka_BuildScanList()
    local c = 0
    for i=1,tlen(units) do
        local u = units[i]
        local hp, mhp = UnitHealth(u), UnitHealthMax(u)
        if mhp and mhp > 0 and hp and UnitIsFriend("player", u) then
            local f = hp / mhp
            if f < thresholdFrac then c = c + 1 end
        end
    end
    return c
end

-- ===== Emergency target: lowest ally below threshold (not self), with Healing Way buffer =====
local function Aroka_FindCriticalTarget(thresholdFrac)
    local units = Aroka_BuildScanList()
    local bestU, bestFrac
    for i=1,tlen(units) do
        local u = units[i]
        if u ~= "player" and UnitIsFriend("player", u) and Aroka_IsInRange("Healing Wave", u) and (not Aroka_IsBlacklisted(u)) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp then
                local f = hp / mhp
                local fAdj = f
                if HasBuff(u, "Healing Way") then
                    fAdj = fAdj - 0.05; if fAdj < 0 then fAdj = 0 end
                end
                if fAdj < thresholdFrac then
                    if not bestFrac or fAdj < bestFrac then bestFrac, bestU = fAdj, u end
                end
            end
        end
    end
    return bestU, bestFrac
end

-- ===== Target selection =====
local function Aroka_GetBestTarget(spellName)
    if not Aroka_AnyoneInjured() then return nil end

    local units = Aroka_BuildScanList()
    local playerHP, playerMax = UnitHealth("player") or 0, UnitHealthMax("player") or 0
    local playerFrac = (playerMax > 0) and (playerHP / playerMax) or 1

    -- Self under 50% → absolute priority
    if playerFrac < 0.50 and Aroka_IsInRange(spellName, "player") and playerHP < playerMax then
        return "player"
    end

    -- Otherwise pick lowest non-self in range (Healing Way gets a 5% priority buffer)
    local bestU, bestFrac
    for i=1,tlen(units) do
        local u = units[i]
        if u ~= "player" and (not Aroka_IsBlacklisted(u)) and Aroka_IsInRange(spellName, u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp and hp < mhp then
                local f = hp / mhp
                local fAdj = f
                if HasBuff(u, "Healing Way") then
                    fAdj = fAdj - 0.05; if fAdj < 0 then fAdj = 0 end
                end
                if not bestFrac or fAdj < bestFrac then bestFrac, bestU = fAdj, u end
            end
        end
    end
    if bestU then return bestU end

    -- If no one else needs healing, allow self-heal only when all others are 100% and self ≥ 50%
    if Aroka_AllOthersFullHP() and playerFrac >= 0.50 then
        if (playerMax > 0) and (playerHP < playerMax) and Aroka_IsInRange(spellName, "player") then
            return "player"
        end
    end

    return nil
end

-- ===== Core decision =====
local function Aroka_Run(forceMax)
    if not Aroka_AnyoneInjured() then return end

    -- 0) Emergency: Ancestral Swiftness + Healing Wave on ally <50%
    local u_crit = Aroka_FindCriticalTarget(0.50)
    if u_crit and IsSpellReady("Ancestral Swiftness") then
        CastSpellByName("Ancestral Swiftness")
        if HasBuff("player", "Ancestral Swiftness") then
            Aroka_SafeCastOnUnitByName("Healing Wave", u_crit)
            return
        end
        -- If buff didn't land, fall through
    end

    -- 1) Raid-wide: 3+ allies <85% → Chain Heal
    local injured = Aroka_CountInjured(0.85)
    if injured >= 3 and IsSpellReady("Chain Heal") then
        local u = Aroka_GetBestTarget("Chain Heal")
        if u then
            if forceMax then
                Aroka_SafeCastOnUnitByName("Chain Heal", u)
            else
                local r = Aroka_PickRank("Chain Heal", u)
                if r then
                    Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", "Chain Heal", r), u)
                else
                    Aroka_SafeCastOnUnitByName("Chain Heal", u)
                end
            end
            return
        end
    end

    -- 2) Fever Dream buff → prefer Chain Heal
    if HasFeverDream() and IsSpellReady("Chain Heal") then
        local u = Aroka_GetBestTarget("Chain Heal")
        if u then
            if forceMax then
                Aroka_SafeCastOnUnitByName("Chain Heal", u)
            else
                local r = Aroka_PickRank("Chain Heal", u)
                if r then
                    Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", "Chain Heal", r), u)
                else
                    Aroka_SafeCastOnUnitByName("Chain Heal", u)
                end
            end
            return
        end
    end

    -- 3) Fallback → Lesser Healing Wave
    if IsSpellReady("Lesser Healing Wave") then
        local u = Aroka_GetBestTarget("Lesser Healing Wave")
        if u then
            if forceMax then
                Aroka_SafeCastOnUnitByName("Lesser Healing Wave", u)
            else
                local r = Aroka_PickRank("Lesser Healing Wave", u)
                if r then
                    Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", "Lesser Healing Wave", r), u)
                else
                    Aroka_SafeCastOnUnitByName("Lesser Healing Wave", u)
                end
            end
        end
    end
end

-- ===== Slash commands =====
SLASH_AROKA1 = "/aroka"
SlashCmdList["AROKA"] = function(msg) Aroka_Run(false) end

SLASH_AROKAMAX1 = "/arokamax"
SlashCmdList["AROKAMAX"] = function(msg) Aroka_Run(true) end

SLASH_AROKAPING1 = "/arokaping"
SlashCmdList["AROKAPING"] = function(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka: OK", 0, 1, 0) end
end

-- Safety: also wire up on login
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    SLASH_AROKA1 = "/aroka";      SlashCmdList["AROKA"] = function(msg) Aroka_Run(false) end
    SLASH_AROKAMAX1 = "/arokamax"; SlashCmdList["AROKAMAX"] = function(msg) Aroka_Run(true) end
    SLASH_AROKAPING1 = "/arokaping"; SlashCmdList["AROKAPING"] = function(msg)
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka: OK (login)", 0, 1, 0) end
    end
end)

-- LOS blacklist listener (Vanilla uses arg1 globals)
local aroka_errf = CreateFrame("Frame")
aroka_errf:RegisterEvent("UI_ERROR_MESSAGE")
aroka_errf:SetScript("OnEvent", function()
    local msg = arg1
    if not msg then return end
    local lower = string.lower(msg)
    if string.find(lower, "line of sight") then
        local name = Aroka_LastCastTargetName
        if name then
            Aroka_Blacklist[name] = (GetTime() or 0) + 0.2
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(string.format('qh aroka has blacklisted "%s" for 0.2 seconds', name), 1, 0.5, 0)
            end
        end
    end
end)

