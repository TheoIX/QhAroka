-- Aroka.lua — Shaman raid healer (Turtle WoW 1.12)
-- /aroka     → run smart healer (downranks)
-- /arokamax  → run max-rank only
--
-- Priorities:
--  1) If ≥2 injured (≤85%) likely to chain within same subgroup/party → Chain Heal
--  2) Otherwise single-target heal:
--       • If player has Fever Dream → Healing Wave (downranked unless /arokamax)
--       • Else → Lesser Healing Wave (downranked unless /arokamax)
--  Always prefer targets with the "Healing Way" buff when choosing who to heal.
--
-- Notes:
--  • Cluster logic approximates Chain Heal jump likelihood using subgroup (party) membership.
--    Classic/Turtle APIs do not provide inter-unit distances, so we prefer clusters inside
--    the same party of the raid. We also require the initial target to be in Chain Heal range.
--  • Buff detection mirrors your working pattern (UnitBuff → string.find on texture/name).
--  • No saved variables. Pure, eventless on-demand logic like QuickTheo style.

local BOOKTYPE_SPELL = BOOKTYPE_SPELL or "spell"

-- =====================
-- Tunables
-- =====================
local INJURED_PCT               = 0.85   -- "injured" threshold for Chain Heal logic
local CHAIN_MIN_COUNT           = 2      -- cast Chain Heal if ≥ this many in a local cluster
local HEALINGWAY_PCT_FLOOR      = 0.97   -- targets with Healing Way are prioritized if below this
local MOUSEOVER_FIRST           = true   -- optional: heal mouseover if valid/injured before scan
local DEBUG                     = false

local function dprint(msg)
  if DEBUG and DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[Aroka]|r " .. tostring(msg)) end
end

-- =====================
-- Helpers: buffs & spellbook
-- =====================
local function QuickHeal_DetectBuff(unit, needle)
  for i = 1, 40 do
    local icon = UnitBuff(unit, i)
    if not icon then break end
    if string.find(icon, needle) then return true end
  end
  return false
end

local function HasFeverDream()
  return QuickHeal_DetectBuff("player", "Fever Dream")
end

local function HasHealingWay(unit)
  return QuickHeal_DetectBuff(unit, "Healing Way")
end

local function IsSpellKnown(spellName, rankStr) -- rankStr like "(Rank 5)" or nil for any
  for i = 1, 300 do
    local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == spellName then
      if (not rankStr) or (rank and ("("..rank..")" == rankStr or rank == string.gsub(rankStr, "[()]", ""))) then
        return true, i, (rank and ("("..rank..")"))
      end
    end
  end
  return false, nil, nil
end

local function GetKnownRanks(spellName) -- returns ascending numeric rank array {1,2,...}
  local ranks = {}
  for i = 1, 300 do
    local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == spellName and rank then
      local n = tonumber(string.match(rank, "(%d+)$"))
      if n then table.insert(ranks, n) end
    end
  end
  table.sort(ranks)
  return ranks
end

local function HighestRank(spellName)
  local r = GetKnownRanks(spellName)
  return r[#r]
end

local function CastOnUnit(spellNameWithRank, unit)
  local hadTarget = UnitExists("target")
  local wasHostile = hadTarget and UnitCanAttack("player", "target")

  if wasHostile then ClearTarget() end
  CastSpellByName(spellNameWithRank)
  if SpellIsTargeting() then SpellTargetUnit(unit) end
  if wasHostile and hadTarget then TargetLastTarget() end
end

-- =====================
-- Unit scanning
-- =====================
local function PushUnit(list, seen, u)
  if u and not seen[u] and UnitExists(u) and UnitIsFriend("player", u) and not UnitIsDeadOrGhost(u) then
    list[#list+1] = u; seen[u] = true
  end
end

local function BuildFriendlyList()
  local units, seen = {}, {}
  PushUnit(units, seen, "player")
  if UnitExists("mouseover") and UnitIsFriend("player","mouseover") then PushUnit(units, seen, "mouseover") end
  if UnitExists("target")   and UnitIsFriend("player","target")   then PushUnit(units, seen, "target")   end
  for i=1,4  do PushUnit(units, seen, "party"..i) end
  for i=1,40 do PushUnit(units, seen, "raid"..i)  end
  return units
end

local function UnitHealthFrac(u)
  local hp, mhp = UnitHealth(u), UnitHealthMax(u)
  if not mhp or mhp <= 0 then return 1 end
  return hp / mhp
end

-- raid subgroup lookup name→subgroup
local function BuildRaidSubgroups()
  local map = {}
  for i=1,40 do
    local name, rank, subgroup = GetRaidRosterInfo(i)
    if name and subgroup then map[name] = subgroup end
  end
  return map
end

local function InRaid()
  return (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
end

-- Count injured members in same subgroup/party as unit `u`
local function CountLocalInjured(u, thresh)
  thresh = thresh or INJURED_PCT
  local injured = 0
  if InRaid() then
    local name = UnitName(u)
    if not name then return 0 end
    local subgroupByName = BuildRaidSubgroups()
    local sg = subgroupByName[name]
    if not sg then return 0 end
    for i=1,40 do
      local ru = "raid"..i
      if UnitExists(ru) and UnitIsFriend("player", ru) and not UnitIsDeadOrGhost(ru) then
        local rn = UnitName(ru)
        if rn and subgroupByName[rn] == sg and UnitHealthFrac(ru) <= thresh then
          injured = injured + 1
        end
      end
    end
  else
    -- Not in raid → use party (includes player)
    local party = {"player","party1","party2","party3","party4"}
    for _,pu in ipairs(party) do
      if UnitExists(pu) and UnitIsFriend("player", pu) and not UnitIsDeadOrGhost(pu) then
        if UnitHealthFrac(pu) <= thresh then injured = injured + 1 end
      end
    end
  end
  return injured
end

-- =====================
-- Rank selection (simple, %HP based)
-- =====================
local function PickRankForPercent(spellName, pct)
  local ranks = GetKnownRanks(spellName)
  if #ranks == 0 then return nil end
  -- Coarse mapping by missing health: lower HP → higher rank
  local missing = 1 - pct
  local idx
  if missing >= 0.75 then
    idx = #ranks                 -- max when very low
  elseif missing >= 0.55 then
    idx = math.max(#ranks-1, 1)
  elseif missing >= 0.35 then
    idx = math.max(math.floor(#ranks*0.75), 1)
  elseif missing >= 0.20 then
    idx = math.max(math.floor(#ranks*0.5), 1)
  elseif missing >= 0.10 then
    idx = math.max(math.floor(#ranks*0.35), 1)
  else
    idx = 1                      -- tiny heal to top off
  end
  return ranks[idx]
end

local function CastBest(spellName, unit, maxOnly)
  if maxOnly then
    local hr = HighestRank(spellName)
    if hr then CastOnUnit(string.format("%s(Rank %d)", spellName, hr), unit); return true end
    return false
  else
    local pct = UnitHealthFrac(unit)
    local r = PickRankForPercent(spellName, pct)
    if r then CastOnUnit(string.format("%s(Rank %d)", spellName, r), unit); return true end
    return false
  end
end

-- =====================
-- Spell range helpers
-- =====================
local function InRange(spellName, unit)
  local ok = IsSpellInRange and IsSpellInRange(spellName, unit)
  return ok == 1
end

-- =====================
-- Target selection
-- =====================
local function FindBestChainHealTarget()
  local units = BuildFriendlyList()
  local bestUnit, bestFrac
  for _,u in ipairs(units) do
    local pct = UnitHealthFrac(u)
    if pct <= INJURED_PCT and InRange("Chain Heal", u) then
      local cluster = CountLocalInjured(u, INJURED_PCT)
      if cluster >= CHAIN_MIN_COUNT then
        -- prefer Healing Way carriers first, then lowest HP
        if HasHealingWay(u) then
          if not bestUnit or not HasHealingWay(bestUnit) or pct < bestFrac then
            bestUnit, bestFrac = u, pct
          end
        else
          if not bestUnit or (not HasHealingWay(bestUnit) and pct < bestFrac) then
            bestUnit, bestFrac = u, pct
          end
        end
      end
    end
  end
  return bestUnit, bestFrac
end

local function FindBestSingleTarget()
  local units = BuildFriendlyList()
  -- 1) look for Healing Way carriers
  local bestHW, bestHWFrac
  for _,u in ipairs(units) do
    if HasHealingWay(u) and UnitHealthFrac(u) < HEALINGWAY_PCT_FLOOR and (InRange("Healing Wave", u) or InRange("Lesser Healing Wave", u)) then
      local f = UnitHealthFrac(u)
      if not bestHW or f < bestHWFrac then bestHW, bestHWFrac = u, f end
    end
  end
  if bestHW then return bestHW, bestHWFrac end
  -- 2) lowest HP target in range
  local best, bestFrac
  for _,u in ipairs(units) do
    if (InRange("Healing Wave", u) or InRange("Lesser Healing Wave", u)) then
      local f = UnitHealthFrac(u)
      if not best or f < bestFrac then best, bestFrac = u, f end
    end
  end
  return best, bestFrac
end

-- =====================
-- Main logic
-- =====================
local function Aroka_Run(maxOnly)
  -- Optional: mouseover snipe first if badly injured
  if MOUSEOVER_FIRST and UnitExists("mouseover") and UnitIsFriend("player","mouseover") and not UnitIsDeadOrGhost("mouseover") then
    local mo = "mouseover"
    if UnitHealthFrac(mo) <= 0.60 then
      if HasFeverDream() then
        if InRange("Healing Wave", mo) and CastBest("Healing Wave", mo, maxOnly) then return end
      else
        if InRange("Lesser Healing Wave", mo) and CastBest("Lesser Healing Wave", mo, maxOnly) then return end
      end
    end
  end

  -- 1) Chain Heal cluster check (highest priority)
  local chu = FindBestChainHealTarget()
  if chu then
    -- pick a Chain Heal rank: heavier if very low or maxOnly; otherwise mid-high
    local ranks = GetKnownRanks("Chain Heal")
    if #ranks > 0 then
      local anyVeryLow = (UnitHealthFrac(chu) <= 0.55)
      local r
      if maxOnly or anyVeryLow then
        r = ranks[#ranks]
      elseif #ranks >= 3 then
        r = ranks[#ranks-1]
      else
        r = ranks[math.max(#ranks-1,1)]
      end
      CastOnUnit(string.format("%s(Rank %d)", "Chain Heal", r), chu)
      return
    end
  end

  -- 2) Single-target heal
  local target = FindBestSingleTarget()
  if not target then return end

  if HasFeverDream() then
    if InRange("Healing Wave", target) then CastBest("Healing Wave", target, maxOnly) end
  else
    if InRange("Lesser Healing Wave", target) then CastBest("Lesser Healing Wave", target, maxOnly) end
  end
end

-- =====================
-- Slash commands (bind at file load to avoid /help swallow)
-- =====================
SLASH_AROKA1 = "/aroka"
SlashCmdList["AROKA"] = function() Aroka_Run(false) end

SLASH_AROKAMAX1 = "/arokamax"
SlashCmdList["AROKAMAX"] = function() Aroka_Run(true) end

if DEFAULT_CHAT_FRAME then
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[Aroka]|r loaded: /aroka (smart/downrank), /arokamax (max rank)")
end
