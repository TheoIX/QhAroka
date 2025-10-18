-- QhAroka (Shaman) – Turtle WoW 1.12
-- Downranking edition + strict targeting rules (Turtle 1.12 / Lua 5.0 safe)
--   • If no one is under 100% HP → do NOT cast
--   • Only prioritize self if player < 50% HP
--   • If player ≥ 50% HP, do NOT heal self unless everyone else is full HP (and self is injured)
-- Usage:
--   /aroka      → downranked smart heal (Chain Heal if 3+ <85%; else HW if Fever Dream; else LHW)
--   /arokamax   → same logic but FORCE max rank for the chosen spell
--   /arokaping  → print a quick "Aroka OK" to verify slash registration

local BOOKTYPE_SPELL = "spell"

-- Lua 5.0 helpers (avoid '#', 'ipairs')
local function tlen(t)
    return table.getn(t)
end

-- ===== Helpers =====
local function HasBuff(unit, partial)
    for i = 1, 40 do
        local buff = UnitBuff(unit, i)
        if not buff then break end
        if string.find(buff, partial) then return true end
    end
    return false
end

-- 1.12: GetSpellCooldown returns start, duration
local function IsSpellReady(spellName)
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if spellName == name or (rank and spellName == (name .. "(" .. rank .. ")")) then
            local start, duration = GetSpellCooldown(i, BOOKTYPE_SPELL)
            start = start or 0; duration = duration or 0
            return (start == 0 and duration == 0), start, duration
        end
    end
    return false, 0, 0
end

local function Aroka_BuildScanList()
    local units, seen = {}, {}
    local function push(u)
        if u and not seen[u] and UnitExists(u) and UnitIsFriend("player", u) and not UnitIsDeadOrGhost(u) then
            table.insert(units, u); seen[u] = true
        end
    end
    push("player")
    if UnitExists("mouseover") and UnitIsFriend("player","mouseover") and not UnitIsDeadOrGhost("mouseover") then push("mouseover") end
    if UnitExists("target")   and UnitIsFriend("player","target")   and not UnitIsDeadOrGhost("target")   then push("target")   end
    for i=1,4  do push("party"..i) end
    for i=1,40 do push("raid"..i)  end
    return units
end

local function Aroka_CountInjured(threshold)
    local count = 0
    local function consider(u)
        if UnitExists(u) and UnitIsFriend("player", u) and not UnitIsDeadOrGhost(u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and (hp / mhp) < threshold then count = count + 1 end
        end
    end
    consider("player")
    for i=1,4  do consider("party"..i) end
    for i=1,40 do consider("raid"..i)  end
    return count
end

local function Aroka_AnyoneInjured()
    local units = Aroka_BuildScanList()
    for i=1,tlen(units) do
        local u = units[i]
        local hp, mhp = UnitHealth(u), UnitHealthMax(u)
        if mhp and mhp > 0 and hp < mhp then return true end
    end
    return false
end

local function Aroka_AnyoneElseInjured()
    local units = Aroka_BuildScanList()
    for i=1,tlen(units) do
        local u = units[i]
        if u ~= "player" then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp < mhp then return true end
        end
    end
    return false
end

-- Keep hostile target lock intact
local function Aroka_SafeCastOnUnitByName(spellNameWithOptionalRank, unit)
    local had = UnitExists("target")
    local hostile = had and UnitCanAttack("player","target")
    if hostile then ClearTarget() end

    CastSpellByName(spellNameWithOptionalRank)
    if SpellIsTargeting() then SpellTargetUnit(unit) end

    if hostile and had then TargetLastTarget() end
end

-- ===== Rank discovery =====
local function Aroka_GetKnownRanks(spellName) -- ascending numeric ranks {1,2,...}
    local ranks = {}
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == spellName and rank then
            local _, _, n = string.find(rank, "(%d+)$") -- Lua 5.0 capture
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

-- Optional +Healing bonus (BonusScanner if present). Super-simple coefficients.
local function Aroka_EffectiveBase(spellName, rank)
    local base
    if spellName == "Lesser Healing Wave" then base = LHW_BASE[rank]
    elseif spellName == "Healing Wave"     then base = HW_BASE[rank]
    elseif spellName == "Chain Heal"       then base = CH_BASE[rank]
    end
    if not base then return nil end

    if BonusScanner and BonusScanner.GetBonus then
        local bonus = tonumber(BonusScanner:GetBonus("HEAL")) or 0
        local coeff = (spellName == "Lesser Healing Wave") and (1.5/3.5)
                    or (spellName == "Healing Wave")       and (3.0/3.5)
                    or (2.5/3.5)
        base = base + bonus * coeff
    end
    return base
end

local function Aroka_InCombat(u)
    if UnitAffectingCombat then return UnitAffectingCombat(u) == 1 end
    return false
end

local function Aroka_PickRank(spellName, unit)
    local ranks = Aroka_GetKnownRanks(spellName)
    if tlen(ranks) == 0 then return nil end

    local maxhp = UnitHealthMax(unit) or 0
    local curhp = UnitHealth(unit) or 0
    local deficit = math.max(0, maxhp - curhp)

    -- small combat cushion: assume the target will lose some HP during cast
    local inCombat = Aroka_InCombat("player") or Aroka_InCombat(unit)
    local k = inCombat and 0.90 or 1.00

    -- choose the smallest rank whose effective heal >= deficit * k
    local chosen = ranks[tlen(ranks)]
    for i=1,tlen(ranks) do
        local r = ranks[i]
        local eff = Aroka_EffectiveBase(spellName, r)
        if eff and eff >= deficit * k then chosen = r; break end
    end
    return chosen
end

local function Aroka_CastBestRank(spellName, unit, forceMax)
    if forceMax then
        local ranks = Aroka_GetKnownRanks(spellName)
        local r = ranks[tlen(ranks)]
        if r then
            Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", spellName, r), unit)
        else
            Aroka_SafeCastOnUnitByName(spellName, unit)
        end
        return
    end

    local r = Aroka_PickRank(spellName, unit)
    if r then
        Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", spellName, r), unit)
    else
        Aroka_SafeCastOnUnitByName(spellName, unit)
    end
end

-- ===== Target selection with new rules =====
local function Aroka_GetBestTarget(spellName)
    -- Hard stop if absolutely no one is injured
    if not Aroka_AnyoneInjured() then return nil end

    local units = Aroka_BuildScanList()
    local playerHP, playerMax = UnitHealth("player") or 0, UnitHealthMax("player") or 0
    local playerFrac = (playerMax > 0) and (playerHP / playerMax) or 1

    -- First: if player < 50% and in range, PRIORITIZE self
    if playerFrac < 0.50 and (not IsSpellInRange or IsSpellInRange(spellName, "player") == 1) and playerHP < playerMax then
        return "player"
    end

    -- Otherwise, try to heal others first
    local bestU, bestFrac
    for i=1,tlen(units) do
        local u = units[i]
        if u ~= "player" and IsSpellInRange and (IsSpellInRange(spellName, u) == 1) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp < mhp then
                local f = hp / mhp
                if not bestFrac or f < bestFrac then bestFrac, bestU = f, u end
            end
        end
    end

    if bestU then return bestU end

    -- If no other injured ally is both injured and in range:
    -- Only allow healing self when EVERYONE ELSE is full HP
    if not Aroka_AnyoneElseInjured() then
        if (playerMax > 0) and (playerHP < playerMax) and (not IsSpellInRange or IsSpellInRange(spellName, "player") == 1) then
            return "player"
        end
    end

    return nil
end

-- ===== Core decision (ranked & rule‑aware) =====
local function Aroka_Run(forceMax)
    -- Global stop: nobody hurt → do nothing
    if not Aroka_AnyoneInjured() then return end

    -- 1) Raid-wide damage check → Chain Heal if 3+ <85%
    local injured = Aroka_CountInjured(0.85)
    if injured >= 3 and IsSpellReady("Chain Heal") then
        local tgt = Aroka_GetBestTarget("Chain Heal")
        if tgt then Aroka_CastBestRank("Chain Heal", tgt, forceMax); return end
        -- fall through if no valid target (range/rules)
    end

    -- 2) Fever Dream on player → Healing Wave (respect targeting rules)
    if HasBuff("player", "Fever Dream") and IsSpellReady("Healing Wave") then
        local tgt = Aroka_GetBestTarget("Healing Wave")
        if tgt then Aroka_CastBestRank("Healing Wave", tgt, forceMax); return end
        -- fall through to LHW
    end

    -- 3) Fallback → Lesser Healing Wave (respect targeting rules)
    if IsSpellReady("Lesser Healing Wave") then
        local tgt = Aroka_GetBestTarget("Lesser Healing Wave")
        if tgt then Aroka_CastBestRank("Lesser Healing Wave", tgt, forceMax); return end
    end

    -- 4) Absolute last resorts (no target earlier)
    if IsSpellReady("Healing Wave") then
        local tgt = Aroka_GetBestTarget("Healing Wave")
        if tgt then Aroka_CastBestRank("Healing Wave", tgt, forceMax); return end
    end
    if IsSpellReady("Chain Heal") then
        local tgt = Aroka_GetBestTarget("Chain Heal")
        if tgt then Aroka_CastBestRank("Chain Heal", tgt, forceMax); return end
    end
end

-- ===== Slash commands (register at LOAD to avoid event issues) =====
SLASH_AROKA1 = "/aroka"
SlashCmdList["AROKA"] = function(msg) Aroka_Run(false) end

SLASH_AROKAMAX1 = "/arokamax"
SlashCmdList["AROKAMAX"] = function(msg) Aroka_Run(true) end

SLASH_AROKAPING1 = "/arokaping"
SlashCmdList["AROKAPING"] = function()
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka: OK (slash registered)", 0, 1, 0) end
end

-- Also register on PLAYER_LOGIN for safety (dup OK)
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    SLASH_AROKA1 = "/aroka";      SlashCmdList["AROKA"] = function(msg) Aroka_Run(false) end
    SLASH_AROKAMAX1 = "/arokamax"; SlashCmdList["AROKAMAX"] = function(msg) Aroka_Run(true) end
    SLASH_AROKAPING1 = "/arokaping"; SlashCmdList["AROKAPING"] = function() if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka: OK (login)", 0, 1, 0) end end
end)


local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", InitAroka)
