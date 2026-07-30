# Driving Dwarf Fortress world generation from Claude Code

How to build a modded test world and pull census data out of it, written down after doing
it several times and getting it wrong in instructive ways. Read the "traps" section before
you start; most of the time lost on this task went to things in it.

## The short version

```bash
DFH=~/.local/share/Steam/steamapps/common/DFHack

# 1. is DF up?  (RPC listens on 5000 only while DF runs)
ss -ltn | grep :5000

# 2. set up world creation from the title screen, then generate
"$DFH/dfhack-run" gen-world civilizations=max sites=max history=2 mods=ha

# 3. poll until the year stops climbing
"$DFH/dfhack-run" lua 'print(df.global.cur_year)'

# 4. census straight out of memory -- do NOT save first, see "crashes"
"$DFH/dfhack-run" lua '<census script, see below>'
```

`dfhack/gen-world.lua` is the wrapper. `civilizations`/`sites`/`history`/`worldsize`/
`beasts`/`savagery`/`minerals` each take `max`, `min` or `0-4`; `mods=` takes `ha`
(everything installed bar upstream fork sources), `all`, or `none`.

History slider values: `0`=5 years, `1`=50, `2`=100, `3`=250, `4`=500.

## Talking to DF

DFHack exposes an RPC on `localhost:5000`. The Bash tool sandbox blocks it, so **every
`dfhack-run` call needs `dangerouslyDisableSandbox: true`**.

Two ways to drive the UI, and picking the right one matters:

**Write the data.** Wherever DF exposes state as fields, set them. `viewscreen_new_regionst`
keeps the available mods and the selected load order as parallel `vector<string>`s, and the
Basic screen's sliders as plain ints. Selecting every mod is a copy; maxing a slider is an
assignment. Nothing to mis-target, no timing to get wrong.

**Feed a click.** For buttons with no data equivalent: park DF's own cursor and feed a
mouse event.

```lua
df.global.gps.mouse_x, df.global.gps.mouse_y = cell_x, cell_y
require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
```

Find the cell by reading the text grid with `dfhack.screen.readTile(x, y)` and searching for
the button's label. This works on every screen tried: title menu, world creation, the world
load list, game-type choice, the civ picker, the embark map, and all the popups.

## Traps

**The first-run "Welcome to Dwarf Fortress" modal swallows all input.** While it is up
nothing else responds — not the sliders, not Create world. Detect it by searching the text
grid for `Welcome to Dwarf Fortress` and click its `Okay` first. It reappears per install,
sometimes per world-creation screen.

**Wait a beat after any screen transition.** The text grid you read is the last rendered
frame. Click a button and immediately search for the next screen's label and you will get
nothing, which looks exactly like "the click failed". A `sleep 2` between steps removes a
whole class of phantom bugs. Two separate "impossible" failures during this work were this.

**`io.write` never flushes over the RPC.** Only `print` output comes back. Silent empty
results are almost always this.

**xdotool cannot click DF.** On Wayland/XWayland it *can* move the pointer — DF polls the
cursor position, so `gps.mouse_x/y` follows — but no button or key event ever arrives.
`click`, `mousedown`/`mouseup` and `key` were all tested via XTEST and `--window`.
`/dev/uinput` is root-only. Use fed clicks instead; they work fine.

**`row and row:find(...)` truncates to one return value** in a multiple assignment, so the
end index comes back nil. Check the nil first, then call `find`.

**Some `world.raws.*` members are structs, not vectors.** `world.raws.entities` is a struct
whose list is `world.raws.entities.all`. Taking `#` of the struct returns 0 and will
convince you nothing is loaded.

**Elements of some string vectors are objects.** `vs.available_id[i]` needs `.value`;
`tostring` gives you `<string: 0x…>`.

## Crashes

DF crashed three times during this work, always around a large modded world:

- pressing the post-worldgen **"Play now"** shortcut
- **`export_region`** — i.e. "Keep world and return to main menu", saving the world
- read-only DFHack queries on a finished 177k-event world

So: **take your census immediately after generation finishes, from memory, before saving
or leaving the screen.** If you need a playable fort, generate, keep the world, then load
it from the title screen — the instant-embark shortcut is the one that crashed.

Check DF is really alive with `pgrep -x dwarfort`. Do **not** use
`pgrep -f "Dwarf Fortress/dwarfort"`: it matches your own shell command line and will
happily report a dead DF as running.

Restart with `setsid steam -applaunch 2346660` (that appid is DFHack, which launches DF).

## Census recipes

**Population over time.** DF stores no historical population, but every historical figure
has `born_year`/`died_year`, so "alive in year Y" is reconstructable. Exact for megabeasts
and rare castes, since those are all historical figures; a *sample* for bulk races (a few
hundred figures against a real population of thousands). Say which you are reporting.

```lua
local F = df.global.world.history.figures
for i = 0, #F - 1 do
  local h = F[i]
  if not (h.flags.deity or h.flags.force)          -- gods are not population
     and h.born_year <= Y and (h.died_year < 0 or h.died_year > Y) then
    -- h.race, h.caste
  end
end
```

**Real populations, current year only:** sum `total_pop` over `world.entities.all`, grouped
by `entity.entity_raw.code`. `entity.populations` is usually empty; don't trust it.

**Who killed what:** walk `world.history.events`, take type `HIST_FIGURE_DIED`, read
`victim_hf`, `slayer_hf`, `slayer_race`, `death_cause`, `year`. A `slayer_hf` of -1 means an
anonymous creature killed it and `slayer_race` is what you want.

**War dynamics:** event types `WAR_ATTACKED_SITE`, `WAR_DESTROYED_SITE`, `WAR_PLUNDERED_SITE`,
`WAR_SITE_TAKEN_OVER`, `WAR_SITE_NEW_LEADER`, `WAR_FIELD_BATTLE`, `ENTITY_DISSOLVED`. Read
`attacker_civ_id`/`defender_civ_id` and map through `historical_entity.find(id).entity_raw.code`.
Bucket by `event.year` for a time series.

`df.history_event_type` does **not** enumerate as a Lua table. Get names by indexing with the
numeric type from `event:getType()`.

## Interpreting results

**One world proves nothing.** Two worlds with identical settings had drow at 0 entities and
at 147. Illithids and succubi likewise. Before concluding a civ is broken, generate several
seeds — the between-world variance dwarfs most balance changes.

**A civ absent at year 100 may have died, not failed to spawn.** DF appears to prune the
historical figures of a civ that dies out early, so "never placed" and "wiped out" look
identical afterwards. Distinguish them by generating the same settings with a **5-year**
history: anything present there was placed, and anything missing at 100 died during history.
