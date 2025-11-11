-- QhAroka (Shaman) – Turtle WoW 1.12
-- Downranking + smart targeting + AS→HW gate + LOS blacklist + Healing Way preference
-- + NEW: /arokach toggle (default OFF) to force Chain Heal to highest known rank on /aroka only
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
    local s, _ = string.find(string.lower(hay), string.lower(needle), 1, true)
    return s ~= nil
end

-- safe UnitName
local function UnitNameSafe(unit)
    if not unit then return nil end
    local n = UnitName(unit)
    if n and n ~= "" then return n end
    return nil
end

-- percentage HP (0..100) fallbacks
local function UnitHealthPct(unit)
    local mh = UnitHealthMax(unit) or 0
    if mh <= 0 then return 100 end
    local ch = UnitHealth(unit) or mh
    local pct = math.floor((ch * 100) / mh)
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    return pct
end

-- NEW: guaranteed-cast on unit by briefly targeting then restoring.
local function Aroka_TargetSwapCast(unit, spellNameWithOptionalRank)
  local hadTarget = UnitExists("target")
  local alreadyOnUnit = (hadTarget and UnitIsUnit("target", unit))

  if not alreadyOnUnit then TargetUnit(unit) end
  CastSpellByName(spellNameWithOptionalRank)
  if not alreadyOnUnit then
    if hadTarget then TargetLastTarget() else ClearTarget() end
  end
  return true
end

-- Cast throttle (affects all spells except Ancestral Swiftness)
local AROKA_CAST_THROTTLE = 0
local Aroka_NextCastAt = 0
local function Aroka_CanCastNow(spellName)
    if spellName and string.find(spellName, "Ancestral Swiftness", 1, true) then return true end
    local now = GetTime and GetTime() or 0
    return now >= (Aroka_NextCastAt or 0)
end
local function Aroka_ArmCastThrottle(spellName)
    if spellName and string.find(spellName, "Ancestral Swiftness", 1, true) then return end
    local now = GetTime and GetTime() or 0
    Aroka_NextCastAt = now + AROKA_CAST_THROTTLE
end

-- Scan throttle: limits how often the /aroka logic can run to reduce frame spikes
local AROKA_SCAN_THROTTLE = 0.20  -- ~5 checks/sec; tweak 0.15–0.30 to taste
local Aroka_NextScanAt = 0

local function Aroka_CanScanNow()
    local now = GetTime and GetTime() or 0
    return now >= (Aroka_NextScanAt or 0)
end

local function Aroka_ArmScanThrottle()
    local now = GetTime and GetTime() or 0
    Aroka_NextScanAt = now + AROKA_SCAN_THROTTLE
end

------------------------------------------------------------
-- LOS + range temporary blacklist keyed by *player name* (intended target)
------------------------------------------------------------
local Aroka_Blacklist = {}

local function Aroka_IsBlacklisted(name)
    local until_t = Aroka_Blacklist[name]
    if not until_t then return false end
    local now = GetTime and GetTime() or 0
    if now < until_t then return true end
    Aroka_Blacklist[name] = nil
    return false
end

------------------------------------------------------------
-- Range detection – pfUI aware, then spell APIs
------------------------------------------------------------
-- Defensive extractor for pfUI unit from a frame (handles pfUI variants safely)
local function _pfui_frame_unit(fr)
    -- pfUI frames vary: sometimes .unit / .unitstr; some builds put a *string* in .label,
    -- and others use .label as a subtable with .unit in it. Guard all shapes.
    if type(fr) ~= "table" then return nil end

    if type(fr.unit) == "string" then return fr.unit end
    if type(fr.unitstr) == "string" then return fr.unitstr end

    local lbl = rawget(fr, "label")
    if type(lbl) == "string" then
        -- Some pfUI forks set frame.label = "raid12" etc.
        return lbl
    elseif type(lbl) == "table" and type(lbl.unit) == "string" then
        return lbl.unit
    end

    return nil
end

local function Aroka_pfUI_IsInRange(unit)
    if not pfUI then return nil end
    if pfUI.api and pfUI.api.UnitInRange then
        local ok = pfUI.api.UnitInRange(unit)
        if ok ~= nil then return ok and true or false end
    end
    -- Heuristic via frame alpha if UnitInRange isn’t available
    local containers = {}
    if string.sub(unit,1,4) == "raid" then
        if pfUI.uf and pfUI.uf.raid then table.insert(containers, pfUI.uf.raid) end
    elseif string.sub(unit,1,5) == "party" then
        if pfUI.uf and pfUI.uf.group then table.insert(containers, pfUI.uf.group) end
    elseif unit == "player" then
        if pfUI.uf and pfUI.uf.player then table.insert(containers, { pfUI.uf.player }) end
    end
    for _, cont in pairs(containers) do
        if type(cont) == "table" then
            for _, fr in pairs(cont) do
                local u = _pfui_frame_unit(fr)
                if u == unit and type(fr) == "table" and fr.GetAlpha then
                    local a = fr:GetAlpha()
                    if a ~= nil then
                        -- pfUI makes out-of-range frames semi-transparent (~0.5)
                        return (a > 0.75)
                    end
                end
            end
        end
    end
    return nil
end

local function IsUnitInRange(unit)
    -- Try pfUI first
    local p = Aroka_pfUI_IsInRange(unit)
    if p ~= nil then return p end

    -- Fall back to spell range checks (these APIs exist in 1.12)
    -- Use small heals to probe range subtly
    if SpellIsTargeting and SpellStopTargeting then
        if SpellIsTargeting() then SpellStopTargeting() end
    end
    local spells = { "Lesser Healing Wave", "Healing Wave", "Chain Heal" }
    for i = 1, table.getn(spells) do
        local s = spells[i]
        local inRange = IsSpellInRange(s, unit)
        if inRange == 1 then return true end
    end
    return false
end

------------------------------------------------------------
-- Pure cast-through helper (never retargets): Cast → SpellTargetUnit → clear stuck cursor
------------------------------------------------------------
local Aroka_LastCastTargetName = nil
local function Aroka_CastThrough(unit, spellNameWithOptionalRank)
    -- Remember last intended target for error blacklisting
    Aroka_LastCastTargetName = UnitNameSafe(unit)

    -- If cursor is stuck from a previous action, clear it
    if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end

    -- Start the cast (this may raise the targeting cursor if current target isn't appropriate)
    CastSpellByName(spellNameWithOptionalRank)

    -- Feed the intended unit to the spell cursor without changing target
    if SpellIsTargeting and SpellIsTargeting() then
        SpellTargetUnit(unit)
        -- If still targeting, cancel to avoid contaminating next click
        if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end
    end
    return true
end

--------------------------------------------------------
-- REPLACE the function body:
local function Aroka_SafeCastOnUnitByName(spellNameWithOptionalRank, unit)
  if not Aroka_CanCastNow(spellNameWithOptionalRank) then return false end
  Aroka_ArmCastThrottle(spellNameWithOptionalRank)

  -- If we already have the right unit targeted, just cast.
  if UnitExists("target") and UnitIsUnit("target", unit) then
    CastSpellByName(spellNameWithOptionalRank)
    return true
  end

  -- Otherwise, do a brief target swap and restore.
  return Aroka_TargetSwapCast(unit, spellNameWithOptionalRank)
end


------------------------------------------------------------
-- Ranks / base values / downrank picker
------------------------------------------------------------
local function Aroka_GetKnownRanks(spellName)
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

-- NEW: Return the highest known rank as an explicit "Name(Rank X)" string (fallback to base name)
local function Aroka_MaxRankName(spellName)
    local ranks = Aroka_GetKnownRanks(spellName)
    if tlen(ranks) == 0 then return spellName end
    local maxr = ranks[tlen(ranks)]
    return string.format("%s(Rank %d)", spellName, maxr)
end

local BASE_HEAL = {
    ["Healing Wave"] = {
        [1]=34,[2]=64,[3]=129,[4]=268,[5]=376,[6]=506,[7]=678,[8]=879,[9]=1115,[10]=1367,[11]=1620,[12]=1900
    },
    ["Lesser Healing Wave"] = {
        [1]=53,[2]=78,[3]=112,[4]=151,[5]=204,[6]=274,[7]=364
    },
    ["Chain Heal"] = {
        [1]=320,[2]=405,[3]=551
    },
}

local function Aroka_PickRank(spellName, unit)
    local hp = UnitHealthPct(unit)
    local ranks = Aroka_GetKnownRanks(spellName)
    if tlen(ranks) == 0 then return spellName end -- no rank info → cast base

    local base = BASE_HEAL[spellName] or {}

    -- Simple %HP → rank curve. Tweak to taste.
    local n = tlen(ranks)
    local idx
    if hp <= 25 then
        idx = n
    elseif hp <= 40 then
        idx = math.max(1, n - 1)
    elseif hp <= 60 then
        idx = math.max(1, n - 2)
    elseif hp <= 80 then
        idx = math.max(1, n - 3)
    else
        idx = math.max(1, n - 4)
    end

    local pick = ranks[idx] or ranks[1]
    return string.format("%s(Rank %d)", spellName, pick)
end

------------------------------------------------------------
-- Buff checking (Ancestral Swiftness / Fever Dream / Healing Way bias)
------------------------------------------------------------

-- tooltip scan for *name substring* on arbitrary unit (Vanilla: GameTooltip:SetUnitBuff only in 2.0+)
local function UnitHasBuffByNameSub(unit, nameSubstr)
    -- Best effort for non-player units (1.12 lacks SetUnitBuff)
    if unit ~= "player" then
        -- try Luna / pfUI / other tooltip backdoors (rare on 1.12); if not available, fall back to player-only
        -- As a safe default, we won’t crash – just return false for non-player if APIs aren’t present
        if GameTooltip and GameTooltip.SetUnitBuff then
            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            GameTooltip:ClearLines()
            GameTooltip:SetUnitBuff(unit, 1) -- probe to attach tooltip to unit; not reliable on 1.12
            local t = getglobal("GameTooltipTextLeft1")
            local label = t and t:GetText()
            if label and _plain_find(label, nameSubstr) then return true end
        end
    else
        -- Player path (Vanilla friendly): iterate GetPlayerBuff indices
        if GetPlayerBuff and GameTooltip and GameTooltip.SetPlayerBuff then
            for idx = 0, 31 do
                if idx < 0 then break end
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:ClearLines()
                GameTooltip:SetPlayerBuff(idx)
                local t = getglobal("GameTooltipTextLeft1")
                local label = t and t:GetText()
                if label and _plain_find(label, nameSubstr) then return true end
            end
        end
    end

    return false
end

local function HasBuff(unit, name)
    -- Fast path for exact name on player using GetPlayerBuffName if available
    if unit == "player" and GetPlayerBuff and GetPlayerBuffName then
        for i = 0, 31 do
            local b = GetPlayerBuff(i, "HELPFUL|HARMFUL")
            if b and b ~= -1 then
                local bn = GetPlayerBuffName(b)
                if bn and _plain_find(bn, name) then return true end
            end
        end
    end
    -- Fallback: tooltip substring scan
    return UnitHasBuffByNameSub(unit, name)
end

-- === Fever Dream PROC-only detector (Turtle/1.12) ===
-- We treat Fever Dream as active only if its remaining time is short (≤ 30s).
local _fdTT = CreateFrame("GameTooltip", "QhArokaFDTT", UIParent, "GameTooltipTemplate")
_fdTT:SetOwner(UIParent, "ANCHOR_NONE")

local function _GetPlayerBuffName(buffIndex)
  _fdTT:ClearLines()
  _fdTT:SetPlayerBuff(buffIndex)
  local fs = getglobal("QhArokaFDTTTextLeft1")
  return fs and fs:GetText() or nil
end

local function HasFeverDreamProc()
  for i = 0, 31 do
    local b = GetPlayerBuff(i, "HELPFUL")
    if b == -1 then break end -- no more buffs
    if b and b >= 0 then
      local name = _GetPlayerBuffName(b)
      if name and string.find(name, "Fever Dream", 1, true) then
        local tl = GetPlayerBuffTimeLeft(b) or 0
        if tl > 0 and tl <= 30 then
          return true  -- this is the timed blue-orb proc
        end
      end
    end
  end
  return false
end

------------------------------------------------------------
-- Target scan & prioritization
------------------------------------------------------------

local function IsHealable(unit)
    if not UnitExists(unit) then return false end
    if UnitIsDeadOrGhost(unit) then return false end
    if not UnitIsFriend("player", unit) then return false end
    return true
end

local function Aroka_FindBestHealTarget()
    local units = {}
    -- Fill units list with player, party, then raid in 1..40 order
    tinsert(units, "player")
    for i = 1, 4 do tinsert(units, "party"..i) end
    for i = 1, 40 do tinsert(units, "raid"..i) end

    local best, bestScore = nil, 101       -- score = realPct with Healing Way bias
    local minRealPct = 101                 -- actual (unbiased) lowest health in the raid

    for _, u in pairs(units) do
        if IsHealable(u) then
            local name = UnitNameSafe(u)
            if name and not Aroka_IsBlacklisted(name) then
                local realPct = UnitHealthPct(u)
                if realPct < minRealPct then minRealPct = realPct end

                local score = realPct
                if HasBuff(u, "Healing Way") then score = score - 5 end -- bias for tie‑breaking only

                if score < bestScore then best, bestScore = u, score end
            end
        end
    end

    -- If the *actual* health of everyone is 100%, do nothing
    if minRealPct >= 100 then return nil end

    return best
end

local function Aroka_CountBelow(threshold)
    local c = 0
    for i = 1, 40 do if IsHealable("raid"..i) and UnitHealthPct("raid"..i) < threshold then c = c + 1 end end
    for i = 1, 4 do if IsHealable("party"..i) and UnitHealthPct("party"..i) < threshold then c = c + 1 end end
    if IsHealable("player") and UnitHealthPct("player") < threshold then c = c + 1 end
    return c
end

------------------------------------------------------------
-- NEW: Chain Heal max‑rank toggle state (default OFF)
------------------------------------------------------------
local Aroka_CHForceMax = false

------------------------------------------------------------
-- Main runner
------------------------------------------------------------
local function Aroka_Run(useMax)
    if not Aroka_CanScanNow() then return end
    Aroka_ArmScanThrottle()
    local target = Aroka_FindBestHealTarget()
    if not target then return end

    local targetPct     = UnitHealthPct(target)
    local feverProc     = HasFeverDreamProc()
    local aswift        = HasBuff("player", "Ancestral Swiftness")
    local chainEligible = (Aroka_CountBelow(85) >= 3)

    -- EMERGENCY: if our chosen heal target is <=50% HP, pop Ancestral Swiftness first (if ready & not up),
    -- then use Healing Wave. This mirrors the intended behavior without touching your current target.
    -- EMERGENCY only if CH is NOT eligible
    if (not chainEligible) and (targetPct <= 50) then
        -- Emergency rule: only cast Healing Wave if AS is active or Fever Dream is up.
        -- Otherwise, prefer LHW. If AS is ready and not active, pop it first and return.
        if (not aswift) and IsSpellReadyByName("Ancestral Swiftness") then
            CastSpellByName("Ancestral Swiftness")
            return
        end

        local spell
        if aswift or feverProc then
            if not useMax then
                spell = Aroka_PickRank("Healing Wave", target)
            else
                spell = "Healing Wave"
            end
        else
            if not useMax then
                spell = Aroka_PickRank("Lesser Healing Wave", target)
            else
                spell = "Lesser Healing Wave"
            end
        end

        local inRange = IsUnitInRange(target)
        if inRange == false then
            local n = UnitNameSafe(target)
            if n then Aroka_Blacklist[n] = (GetTime() or 0) + 5.0 end
            if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("qh aroka: "..(n or "target").." out of range — 5s blacklist", 1, 0.5, 0) end
            return
        end
        Aroka_SafeCastOnUnitByName(spell, target)
        return
    end

    -- Normal priority
    local spell
    if chainEligible then
        spell = "Chain Heal"
    elseif feverProc then
        spell = "Healing Wave"
    else
        spell = "Lesser Healing Wave"
    end

    -- Rank selection
    if not useMax then
        if Aroka_CHForceMax and string.find(spell, "Chain Heal", 1, true) then
            -- Force highest known CH rank on /aroka when toggle is ON
            spell = Aroka_MaxRankName("Chain Heal")
        else
            spell = Aroka_PickRank(spell, target)
        end
    end

    -- If AS is active, prefer Healing Wave, but never override Chain Heal
    if aswift and not string.find(spell, "Chain Heal", 1, true) then
        if not useMax then
            spell = Aroka_PickRank("Healing Wave", target)
        else
            spell = "Healing Wave"
        end
    end

    -- Range protection: blacklist and bail if not in range
    local inRange = IsUnitInRange(target)
    if inRange == false then
        local n = UnitNameSafe(target)
        if n then Aroka_Blacklist[n] = (GetTime() or 0) + 5.0 end
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("qh aroka: "..(n or "target").." out of range — 5s blacklist", 1, 0.5, 0) end
        return
    end

    Aroka_SafeCastOnUnitByName(spell, target)
end

------------------------------------------------------------
-- Castable? (coarse)
------------------------------------------------------------
function IsSpellReadyByName(spellName)
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == spellName then
            local start, duration = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if not start or start == 0 or (duration and duration == 0) then return true end
            if start and duration then
                local now = GetTime and GetTime() or 0
                if now >= (start + duration) then return true end
            end
            return false
        end
    end
    return false
end

------------------------------------------------------------
-- Load prints
------------------------------------------------------------
local aroka_loadf = CreateFrame("Frame")
aroka_loadf:RegisterEvent("ADDON_LOADED")
aroka_loadf:SetScript("OnEvent", function()
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka loaded (Shaman) — /aroka, /arokamax, /arokach", 0, 1, 0) end
end)

------------------------------------------------------------
-- Error listener → soft blacklist (Vanilla globals arg1)
------------------------------------------------------------
local aroka_errf = CreateFrame("Frame")
aroka_errf:RegisterEvent("UI_ERROR_MESSAGE")
aroka_errf:SetScript("OnEvent", function()
    local msg = arg1
    if not msg then return end
    local lower = string.lower(msg)
    local name = Aroka_LastCastTargetName

    -- LoS → short blacklist
    if string.find(lower, "line of sight") or string.find(lower, "line of site") or string.find(lower, "los") then
        if name then
            Aroka_Blacklist[name] = (GetTime() or 0) + 2.0
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(string.format('qh aroka: blacklisted "%s" for 2.0s (LoS)', name), 1, 0.5, 0)
            end
        end
        return
    end

    -- Range → slightly longer blacklist
    if string.find(lower, "out of range") or string.find(lower, "too far away") or string.find(lower, "range") then
        if name then
            Aroka_Blacklist[name] = (GetTime() or 0) + 5.0
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(string.format('qh aroka: blacklisted "%s" for 5.0s (range)', name), 1, 0.5, 0)
            end
        end
        return
    end

    -- Generic failure → tiny cooldown to prevent thrashing
    if string.find(lower, "another action") or string.find(lower, "can’t do that") or string.find(lower, "can't do that") then
        if name then
            Aroka_Blacklist[name] = (GetTime() or 0) + 0.7
        end
        return
    end
end)

-- If a cast fails/gets interrupted, don't hold the full 1.3s; release quickly.
local aroka_castf = CreateFrame("Frame")
aroka_castf:RegisterEvent("SPELLCAST_FAILED")
aroka_castf:RegisterEvent("SPELLCAST_INTERRUPTED")
aroka_castf:SetScript("OnEvent", function()
    local now = GetTime and GetTime() or 0
    -- If we still have a chunky lock, trim it to a short grace so spamming feels snappy
    if (Aroka_NextCastAt or 0) - now > 0.5 then
        Aroka_NextCastAt = now + 0.20
    end
end)

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------
if not SlashCmdList then SlashCmdList = {} end

SLASH_QHAROKA1 = "/aroka"
SlashCmdList["QHAROKA"] = function(msg) Aroka_Run(false) end

SLASH_QHAROKAMAX1 = "/arokamax"
SlashCmdList["QHAROKAMAX"] = function(msg) Aroka_Run(true) end

-- NEW: /arokach toggle: forces Chain Heal to max rank when using /aroka (downrank path). /arokamax unaffected.
SLASH_QHAROKACH1 = "/arokach"
SlashCmdList["QHAROKACH"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "on" or msg == "1" or msg == "enable" or msg == "enabled" then
        Aroka_CHForceMax = true
    elseif msg == "off" or msg == "0" or msg == "disable" or msg == "disabled" then
        Aroka_CHForceMax = false
    else
        Aroka_CHForceMax = not Aroka_CHForceMax
    end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("QhAroka: Chain Heal max-rank on /aroka %s", Aroka_CHForceMax and "|cff00ff00ENABLED|r" or "|cffff2020DISABLED|r"), 0.4, 0.8, 1)
    end
end

SLASH_QHAROKAPING1 = "/arokaping"
SlashCmdList["QHAROKAPING"] = function(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka: OK (redundant)", 0, 1, 0) end
end

local aroka_loadf2 = CreateFrame("Frame")
aroka_loadf2:RegisterEvent("VARIABLES_LOADED")
aroka_loadf2:SetScript("OnEvent", function()
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka ready — type /aroka", 0.2, 1, 0.2) end
end)
