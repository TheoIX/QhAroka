-- QhAroka (Shaman) – Turtle WoW 1.12
-- Minimal healer macro logic mirrored from the working Paladin script style
-- Usage: make a macro with just: /aroka
-- Logic:
--   • If 3+ friendlies (including you) are below 85% HP → cast Chain Heal on the lowest-HP unit in range.
--   • Else if you (player) have Fever Dream → cast Healing Wave on the lowest-HP unit in range.
--   • Else cast Lesser Healing Wave on the lowest-HP unit in range (fallback).

local BOOKTYPE_SPELL = "spell"

-- === Helpers mirrored in style with UnitBuff + string.find checks ===
local function HasBuff(unit, partial)
    for i = 1, 40 do
        local buff = UnitBuff(unit, i)
        if not buff then break end
        if string.find(buff, partial) then
            return true
        end
    end
    return false
end

local function IsSpellReady(spellName)
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if spellName == name or (rank and spellName == name .. "(" .. rank .. ")") then
            local start, duration, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
            return enabled == 1 and (start == 0 or duration == 0), start, duration
        end
    end
    return false, 0, 0
end

-- Deduped friendly scan list (self, mouseover, target, party, raid), like our Paladin script style
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

-- Count how many friendlies are below a given HP fraction (includes player)
local function Aroka_CountInjured(threshold)
    local count = 0
    local function consider(u)
        if UnitExists(u) and UnitIsFriend("player", u) and not UnitIsDeadOrGhost(u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 then
                if (hp / mhp) < threshold then count = count + 1 end
            end
        end
    end
    consider("player")
    for i=1,4  do consider("party"..i) end
    for i=1,40 do consider("raid"..i)  end
    return count
end

-- Pick lowest-HP friendly that is in range for the given spell
local function Aroka_GetLowestInRange(spellName)
    local units = Aroka_BuildScanList()
    local bestU, bestFrac
    for _, u in ipairs(units) do
        if IsSpellInRange and (IsSpellInRange(spellName, u) == 1) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 then
                local f = hp / mhp
                if not bestFrac or f < bestFrac then bestFrac, bestU = f, u end
            end
        end
    end
    return bestU
end

-- Safe cast on a unit without breaking hostile target locks
local function Aroka_SafeCastOnUnit(spellName, unit)
    local had = UnitExists("target")
    local hostile = had and UnitCanAttack("player","target")
    if hostile then ClearTarget() end

    CastSpellByName(spellName)
    if SpellIsTargeting() then SpellTargetUnit(unit) end

    if hostile and had then TargetLastTarget() end
end

-- === Core decision ===
function Aroka_Run()
    -- 1) Raid-wide damage check → Chain Heal if 3+ <85%
    local injured = Aroka_CountInjured(0.85)
    if injured >= 3 then
        local ready = IsSpellReady("Chain Heal")
        if ready then
            local tgt = Aroka_GetLowestInRange("Chain Heal")
            if tgt then Aroka_SafeCastOnUnit("Chain Heal", tgt); return end
        end
        -- If Chain Heal not ready or no one in range, continue to single-target logic below
    end

    -- 2) Fever Dream on player → Healing Wave
    local hasFever = HasBuff("player", "Fever Dream")
    if hasFever then
        local ready = IsSpellReady("Healing Wave")
        if ready then
            local tgt = Aroka_GetLowestInRange("Healing Wave")
            if tgt then Aroka_SafeCastOnUnit("Healing Wave", tgt); return end
        end
        -- fall through to LHW if HW not ready or no target in range
    end

    -- 3) Fallback → Lesser Healing Wave
    do
        local ready = IsSpellReady("Lesser Healing Wave")
        if ready then
            local tgt = Aroka_GetLowestInRange("Lesser Healing Wave") or "player"
            Aroka_SafeCastOnUnit("Lesser Healing Wave", tgt)
            return
        end
    end

    -- 4) Absolute last resorts if earlier picks failed (e.g., range/ready issues)
    do
        local tgt
        if IsSpellReady("Healing Wave") then
            tgt = Aroka_GetLowestInRange("Healing Wave") or "player"
            Aroka_SafeCastOnUnit("Healing Wave", tgt); return
        end
        if IsSpellReady("Chain Heal") then
            tgt = Aroka_GetLowestInRange("Chain Heal") or "player"
            Aroka_SafeCastOnUnit("Chain Heal", tgt); return
        end
    end
end

function Aroka_Command()
    Aroka_Run()
end

local function InitAroka()
    SLASH_AROKA1 = "/aroka"
    SlashCmdList["AROKA"] = Aroka_Command
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", InitAroka)
