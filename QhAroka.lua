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
    local esc = string.gsub(needle, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    return string.find(string.lower(hay), string.lower(esc)) ~= nil
end

-- name & blacklist
local function UnitNameSafe(unit)
    local n = UnitName(unit)
    if n then return n end
    return tostring(unit or "?")
end

local Aroka_Blacklist = {}      -- [name] = expireTime
local Aroka_LastCastTargetName = nil
local Aroka_CastBufferUntil = 0
local function Aroka_SetCastBuffer(sec)
    local now = GetTime and GetTime() or 0
    Aroka_CastBufferUntil = now + (sec or 1.3)
end

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

-- Alive helper: ignore dead/ghost units when scanning
local function Aroka_IsAlive(unit)
    if not UnitExists or not UnitExists(unit) then return false end
    if UnitIsDead and UnitIsDead(unit) then return false end
    if UnitIsGhost and UnitIsGhost(unit) then return false end
    local mhp = UnitHealthMax(unit)
    return mhp and mhp > 0
end

------------------------------------------------------------
-- Scan list (NO current target or partyXtarget bias)
------------------------------------------------------------
local function Aroka_BuildScanList()
    local units = { "player" }
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, 40 do tinsert(units, "raid"..i) end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        for i = 1, 4 do tinsert(units, "party"..i) end
    end
    return units
end

------------------------------------------------------------
-- Buff detection (tooltip scan)
-- Primary: GameTooltip:SetUnitBuff/SetUnitDebuff (if available)
-- Fallback (player only): GetPlayerBuff + GameTooltip:SetPlayerBuff
------------------------------------------------------------
local function HasBuff(unit, buffName)
    if GameTooltip and GameTooltip.SetUnitBuff then
        for i = 1, 40 do
            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            GameTooltip:ClearLines()
            GameTooltip:SetUnitBuff(unit, i)
            local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
            if text and _plain_find(text, buffName) then return true end
        end
        for i = 1, 40 do
            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            GameTooltip:ClearLines()
            GameTooltip:SetUnitDebuff(unit, i)
            local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
            if text and _plain_find(text, buffName) then return true end
        end
        return false
    end
    -- Vanilla-style player fallback
    if unit == "player" and GetPlayerBuff and GameTooltip and GameTooltip.SetPlayerBuff then
        for i = 0, 31 do
            local idx = GetPlayerBuff(i, "HELPFUL")
            if idx and idx >= 0 then
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:ClearLines()
                GameTooltip:SetPlayerBuff(idx)
                local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
                if text and _plain_find(text, buffName) then return true end
            end
        end
        for i = 0, 15 do
            local idx = GetPlayerBuff(i, "HARMFUL")
            if idx and idx >= 0 then
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:ClearLines()
                GameTooltip:SetPlayerBuff(idx)
                local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
                if text and _plain_find(text, buffName) then return true end
            end
        end
    end
    return false
end

------------------------------------------------------------
-- Range & cooldown helpers
------------------------------------------------------------
-- Prefer pfUI's range state when available; fallback to spell range API
local function Aroka_pfUI_IsInRange(unit)
    if not pfUI then return nil end
    -- 1) pfUI API, if exposed
    if pfUI.api and pfUI.api.UnitInRange then
        local ok, val = pcall(pfUI.api.UnitInRange, unit)
        if ok and val ~= nil then
            if val == true or val == 1 then return true end
            if val == false or val == 0 then return false end
        end
    end
    -- 2) Infer from unitframe alpha if we can find the frame
    if not pfUI.uf then return nil end
    local containers = {}
    if string.sub(unit,1,4) == "raid" then
        if pfUI.uf.raid then table.insert(containers, pfUI.uf.raid) end
    elseif string.sub(unit,1,5) == "party" then
        if pfUI.uf.group then table.insert(containers, pfUI.uf.group) end
    elseif unit == "player" then
        if pfUI.uf.player then table.insert(containers, { pfUI.uf.player }) end
    end
    for _, cont in pairs(containers) do
        if type(cont) == "table" then
            for _, fr in pairs(cont) do
                local u = fr and (fr.unit or (fr.label and fr.label.unit) or fr.unitstr)
                if u == unit and fr.GetAlpha then
                    local a = fr:GetAlpha()
                    if a ~= nil then
                        return a >= 0.8 -- treat dimmed (<0.8) as out-of-range
                    end
                end
            end
        end
    end
    return nil
end

local function Aroka_IsInRange(spellName, unit)
    -- Try pfUI first
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
            local start, dur = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if (not start) or dur == 0 or start == 0 then return true end
            local now = GetTime and GetTime() or 0
            return now >= (start + dur)
        end
    end
    return false
end

------------------------------------------------------------
-- Safe cast on intended unit with target restore
------------------------------------------------------------
local function Aroka_SafeCastOnUnitByName(spellNameWithOptionalRank, unit)
    local hadTarget = UnitExists and (UnitExists("target") == 1) or false
    local needTempTarget = true
    if hadTarget and (UnitNameSafe("target") == UnitNameSafe(unit)) then
        needTempTarget = false
    end

    Aroka_LastCastTargetName = UnitNameSafe(unit)

    if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end

    if needTempTarget and TargetUnit then
        TargetUnit(unit)
    end

    CastSpellByName(spellNameWithOptionalRank)
    if SpellIsTargeting and SpellIsTargeting() then
        SpellTargetUnit(unit)
    end

    -- Throttle new casts a bit (UI + latency headroom)
    Aroka_SetCastBuffer(1.3)

    if needTempTarget then
        if hadTarget and TargetLastTarget then
            TargetLastTarget()
        elseif ClearTarget then
            ClearTarget()
        end
    end
end

------------------------------------------------------------
-- Ranks / base values / downrank picker
------------------------------------------------------------
local function Aroka_GetKnownRanks(spellName) -- ascending {1,2,...}
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

local function Aroka_PickRank(spellName, unit)
    local hp, mhp = UnitHealth(unit), UnitHealthMax(unit)
    if not mhp or mhp <= 0 or not hp then return nil end
    local missing = mhp - hp

    local ranks = Aroka_GetKnownRanks(spellName)
    if tlen(ranks) == 0 then return nil end

    local best = ranks[tlen(ranks)] -- default to max
    for i = 1, tlen(ranks) do
        local r = ranks[i]
        local eff = Aroka_EffectiveBase(spellName, r)
        if eff and eff >= missing then best = r; break end
    end
    return best
end

------------------------------------------------------------
-- Group health helpers / selection
------------------------------------------------------------
local function Aroka_AnyoneInjured()
    local units = Aroka_BuildScanList()
    for i = 1, tlen(units) do
        local u = units[i]
        if Aroka_IsAlive(u) and UnitIsFriend("player", u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if hp and mhp and hp < mhp then return true end
        end
    end
    return false
end

local function Aroka_AllOthersFullHP()
    local units = Aroka_BuildScanList()
    for i = 1, tlen(units) do
        local u = units[i]
        if u ~= "player" and Aroka_IsAlive(u) and UnitIsFriend("player", u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if hp and mhp and (hp < mhp) then return false end
        end
    end
    return true
end

local function Aroka_CountInjured(thresholdFrac)
    local units = Aroka_BuildScanList()
    local c = 0
    for i = 1, tlen(units) do
        local u = units[i]
        if Aroka_IsAlive(u) and UnitIsFriend("player", u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if hp and mhp then
                local f = hp / mhp
                if f < thresholdFrac then c = c + 1 end
            end
        end
    end
    return c
end

local function Aroka_FindCriticalTarget(thresholdFrac)
    local units = Aroka_BuildScanList()
    local bestU, bestFrac
    for i = 1, tlen(units) do
        local u = units[i]
        if u ~= "player" and Aroka_IsAlive(u) and UnitIsFriend("player", u) and Aroka_IsInRange("Healing Wave", u) and (not Aroka_IsBlacklisted(u)) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp then
                local f = hp / mhp
                local fAdj = f
                if HasBuff(u, "Healing Way") then fAdj = fAdj - 0.05; if fAdj < 0 then fAdj = 0 end end
                if fAdj < thresholdFrac then
                    if not bestFrac or fAdj < bestFrac then bestFrac, bestU = fAdj, u end
                end
            end
        end
    end
    return bestU, bestFrac
end

local function Aroka_GetBestTarget(spellName)
    if not Aroka_AnyoneInjured() then return nil end

    local units = Aroka_BuildScanList()
    local playerHP, playerMax = UnitHealth("player") or 0, UnitHealthMax("player") or 0
    local playerFrac = (playerMax > 0) and (playerHP / playerMax) or 1

    -- Self under 50% → absolute priority (only if alive)
    if Aroka_IsAlive("player") and playerFrac < 0.50 and Aroka_IsInRange(spellName, "player") and playerHP < playerMax then
        return "player"
    end

    -- Lowest non-self, with Healing Way 5% buffer, ignoring blacklisted/OORange/dead
    local bestU, bestFrac
    for i = 1, tlen(units) do
        local u = units[i]
        if u ~= "player" and Aroka_IsAlive(u) and (not Aroka_IsBlacklisted(u)) and Aroka_IsInRange(spellName, u) and UnitIsFriend("player", u) then
            local hp, mhp = UnitHealth(u), UnitHealthMax(u)
            if mhp and mhp > 0 and hp and hp < mhp then
                local f = hp / mhp
                local fAdj = f
                if HasBuff(u, "Healing Way") then fAdj = fAdj - 0.05; if fAdj < 0 then fAdj = 0 end end
                if not bestFrac or fAdj < bestFrac then bestFrac, bestU = fAdj, u end
            end
        end
    end
    if bestU then return bestU end

    -- If no one else needs healing, allow self-heal only when all others are 100% and self ≥ 50%
    if Aroka_AllOthersFullHP() and playerFrac >= 0.50 and Aroka_IsAlive("player") then
        if (playerMax > 0) and (playerHP < playerMax) and Aroka_IsInRange(spellName, "player") then
            return "player"
        end
    end

    return nil
end

------------------------------------------------------------
-- Core decision
------------------------------------------------------------
local function HasFeverDream() return HasBuff("player", "Fever Dream") end

local function Aroka_Run(forceMax)
    local now = GetTime and GetTime() or 0
    if now < (Aroka_CastBufferUntil or 0) then return end
    if not Aroka_AnyoneInjured() then return end

    -- If Ancestral Swiftness buff is currently on the player, force exactly one Healing Wave
    if HasBuff("player", "Ancestral Swiftness") then
        local u = Aroka_GetBestTarget("Healing Wave")
        if u then
            if forceMax then
                Aroka_SafeCastOnUnitByName("Healing Wave", u)
            else
                local r = Aroka_PickRank("Healing Wave", u)
                if r then Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", "Healing Wave", r), u)
                else Aroka_SafeCastOnUnitByName("Healing Wave", u) end
            end
        end
        return
    end

    -- Emergency: Ancestral Swiftness + Healing Wave on ally <50%
    local u_crit = Aroka_FindCriticalTarget(0.50)
    if u_crit and IsSpellReady("Ancestral Swiftness") then
        CastSpellByName("Ancestral Swiftness")
        if HasBuff("player", "Ancestral Swiftness") then
            Aroka_SafeCastOnUnitByName("Healing Wave", u_crit)
            return
        end
        -- If buff didn't land, fall through
    end

    -- Raid-wide: 3+ allies <85% → Chain Heal
    local injured = Aroka_CountInjured(0.85)
    if injured >= 3 and IsSpellReady("Chain Heal") then
        local u = Aroka_GetBestTarget("Chain Heal")
        if u then
            if forceMax then
                Aroka_SafeCastOnUnitByName("Chain Heal", u)
            else
                local r = Aroka_PickRank("Chain Heal", u)
                if r then Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", "Chain Heal", r), u)
                else Aroka_SafeCastOnUnitByName("Chain Heal", u) end
            end
            return
        end
    end

    -- Fever Dream → prefer Chain Heal
    if HasFeverDream() and IsSpellReady("Chain Heal") then
        local u = Aroka_GetBestTarget("Chain Heal")
        if u then
            if forceMax then
                Aroka_SafeCastOnUnitByName("Chain Heal", u)
            else
                local r = Aroka_PickRank("Chain Heal", u)
                if r then Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", "Chain Heal", r), u)
                else Aroka_SafeCastOnUnitByName("Chain Heal", u) end
            end
            return
        end
    end

    -- Fallback → Lesser Healing Wave
    if IsSpellReady("Lesser Healing Wave") then
        local u = Aroka_GetBestTarget("Lesser Healing Wave")
        if u then
            if forceMax then
                Aroka_SafeCastOnUnitByName("Lesser Healing Wave", u)
            else
                local r = Aroka_PickRank("Lesser Healing Wave", u)
                if r then Aroka_SafeCastOnUnitByName(string.format("%s(Rank %d)", "Lesser Healing Wave", r), u)
                else Aroka_SafeCastOnUnitByName("Lesser Healing Wave", u) end
            end
        end
    end
end

------------------------------------------------------------
-- Slash commands / login wiring
------------------------------------------------------------
SLASH_AROKA1 = "/aroka"
SlashCmdList["AROKA"] = function(msg) Aroka_Run(false) end

SLASH_AROKAMAX1 = "/arokamax"
SlashCmdList["AROKAMAX"] = function(msg) Aroka_Run(true) end

SLASH_AROKAPING1 = "/arokaping"
SlashCmdList["AROKAPING"] = function(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka: OK", 0, 1, 0) end
end

local _loginf = CreateFrame("Frame")
_loginf:RegisterEvent("PLAYER_LOGIN")
_loginf:SetScript("OnEvent", function()
    SLASH_AROKA1 = "/aroka";      SlashCmdList["AROKA"] = function(msg) Aroka_Run(false) end
    SLASH_AROKAMAX1 = "/arokamax"; SlashCmdList["AROKAMAX"] = function(msg) Aroka_Run(true) end
    SLASH_AROKAPING1 = "/arokaping"; SlashCmdList["AROKAPING"] = function(msg)
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("QhAroka: OK (login)", 0, 1, 0) end
    end
end)

------------------------------------------------------------
-- LOS blacklist listener (Vanilla globals arg1)
------------------------------------------------------------
local aroka_errf = CreateFrame("Frame")
aroka_errf:RegisterEvent("UI_ERROR_MESSAGE")
aroka_errf:SetScript("OnEvent", function()
    local msg = arg1
    if not msg then return end
    local lower = string.lower(msg)
    if string.find(lower, "line of sight") then
        local name = Aroka_LastCastTargetName
        if name then
            Aroka_Blacklist[name] = (GetTime() or 0) + 2.0
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(string.format('qh aroka has blacklisted "%s" for 2.0 seconds', name), 1, 0.5, 0)
            end
        end
    end
end)
