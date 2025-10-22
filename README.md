QhAroka — Shaman Smart Healer (Turtle WoW / Vanilla 1.12)

QhAroka is a single-file Lua addon that chooses the right heal for the right ally—fast—while minimizing FPS dips when you spam the macro. It supports down-ranking, Chain Heal crowd checks, Ancestral Swiftness gating, and a proc-only detector for Fever Dream so trinket passives don’t hijack your logic.

Features

Smart target selection with basic safety checks (dead/ghost/friendly, simple pfUI range hints when available).

Chain Heal rule: if ≥ 3 allies are ≤ 85% HP, cast Chain Heal. This always takes priority over Fever Dream or Ancestral Swiftness.

Fever Dream (proc-only): distinguishes the passive “red dragon” aura from the timed “blue orb” proc and only treats Fever Dream as active when it has a finite timer (default ≤ 30s).

Ancestral Swiftness integration: prefers Healing Wave when AS is up, but never overrides a chosen Chain Heal.

Emergency logic (optional): when the current best target is ≤ 50% HP and Chain Heal is not eligible, prefer Healing Wave (AS/proc) or fall back to Lesser Healing Wave.

Down-ranking based on target HP and known ranks for HW/LHW/CH.

Range/LoS protection: brief blacklists to avoid re-spamming impossible casts (e.g., LoS errors).

Performance-friendly spam:

Scan throttle (~0.20s) limits full scan frequency when you mash /aroka.

Cast throttle (1.3s by default, AS bypasses) arms at cast start and relaxes quickly on failed/interrupt casts.

Requirements

Turtle WoW or a Vanilla 1.12 client.

Optional: pfUI for better range hints (falls back gracefully if not present).

Installation

Create a folder:
Interface/AddOns/QhAroka

Put your QhAroka.lua in that folder.

Add this minimal QhAroka.toc file next to it:

## Interface: 11200
## Title: QhAroka
## Notes: Shaman smart healer for Turtle/1.12
## Author: Theo
## Version: 1.0.0

QhAroka.lua


Restart the game. You’ll see a small “QhAroka ready” message on login.

Usage (Slash Commands)

/aroka — run once using down-ranked logic

/arokamax — run once forcing max ranks for the chosen spell

Bind either to a hotkey and spam freely—throttles protect your FPS.

Spell Choice (Quick Logic)

Find best heal target (ignores dead/hostile; slight self-bias if you’re critically low).

Chain Heal first: if ≥ 3 allies are ≤ 85% HP, cast Chain Heal (down-ranked unless /arokamax).

Otherwise:

If Ancestral Swiftness is active or Fever Dream proc is active → Healing Wave (down-ranked unless /arokamax).

Else → Lesser Healing Wave (down-ranked unless /arokamax).

Emergency rule: if the chosen target is ≤ 50% and Chain Heal is not eligible, prefer Healing Wave (AS/proc) or LHW.

Guards:

AS and Fever Dream never override Chain Heal once CH is selected.

A final guard also upgrades LHW→HW during Fever Dream proc but leaves CH untouched.

Configuration (Edit Constants In-File)

Scan throttle: AROKA_SCAN_THROTTLE (default 0.20).
Raise to 0.25–0.30 if you still see micro-stutter when spamming.

Cast throttle: AROKA_CAST_THROTTLE (default 1.3).
Starts at cast begin; failed/interrupt events shorten the lock to ~0.20s.

Chain threshold: the CH crowd check uses ≤ 85%.
If you want it stricter/looser, change the comparison or the value.

Fever Dream window: in HasFeverDreamProc() the timer check defaults to ≤ 30 seconds.
If your server uses a different duration, adjust that number.

Blacklist times: LoS/range blacklists are short (usually ~2s).
You can tweak those durations in their respective helpers.

Tips

If Chain Heal seems to “not trigger,” verify at least three allies are actually ≤ 85% by the time the scan runs. Integer rounding can make health look lower on frames than in API.

If you use pfUI, its range APIs give better “in range” hints. Without pfUI, the addon still works; it just avoids the extra hints.

If you wear Breath of Solnius, the passive Fever Dream aura will be present at all times. The addon only responds to the timed proc version.

Commands Recap
/aroka       -- run once (down-rank aware)
/arokamax    -- run once (max ranks)
/arokaping   -- ping
