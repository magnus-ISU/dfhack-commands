-- Adventure mode: eat and drink from your own pack the moment you get hungry or thirsty.
--@module = true
--@enable = true
--[[
adv/always-be-satiated

Adventuring is mostly bookkeeping: notice "Hungry" flashing, open the inventory, hunt for the
food, click it, do it again for the water. With always-be-satiated ENABLED your adventurer
feeds themself -- when they are hungry or thirsty, out of combat, and carrying something to
eat or drink, one item is consumed and you carry on.

    enable adv/always-be-satiated     feed myself automatically (this session)
    disable adv/always-be-satiated    stop
    adv/always-be-satiated            toggle
    adv/always-be-satiated status     thresholds, stomach room, what it can see to consume
    adv/always-be-satiated forget     wipe the refused/strike lists; everything retries
    Ctrl+E  (in adventure)            toggle on/off in-game

Default is OFF, so nothing happens until you enable it.

WHEN IT ACTS -- all of these have to hold:
  * ON THE PLAIN ADVENTURE SCREEN. Two separate checks, because they catch different things:
    the focus must be `dungeonmode/Default` (no panel, menu or dialog up) AND adventure.menu
    must be `Default`, which is what excludes FAST TRAVEL -- during travel the focus still
    reads like the normal map, and only the menu enum says otherwise.
  * HUNGRY or THIRSTY by DF's own numbers: hunger_timer >= 50000 is when DF starts flashing
    "Hungry" (starving at 75000), thirst_timer >= 25000 is "Thirsty" (dehydrated at 50000).
  * NOT IN COMBAT -- no living hostile (units.isDanger) within COMBAT_RADIUS tiles and 2
    z-levels, and no attack menu open. Eating burns a turn you would rather spend swinging.
  * STOMACH HAS ROOM -- see below.
  * Something edible is actually in the pack.

THE VOMIT LIMIT -- measured on a live adventurer, not guessed. One consumed item moves
counters2.stomach_content ("fullness") by ~50000 and takes exactly 50000 off the matching
hunger/thirst timer, so the stomach is read in whole items. Four items down is fine; the
FIFTH is what makes you throw up. An action therefore only STARTS from three items or below,
which lands at four in the worst case and never reaches the fifth. This matters most when you
are STARVING -- one item takes 50000 off a timer sitting at 200000, so without the ceiling the
script would cheerfully eat you into vomiting, and vomiting makes you retch on every meal
after, which is worse than the hunger was. When the stomach is too full it simply waits;
fullness drains on its own.

WHAT IT WILL NOT CONSUME:
  * MYTHICAL SUBSTANCES -- the healing loot of mysterious dungeons and palaces. These are
    procedurally named per world, <adjective> <noun> from a fixed pair of lists ("odd jelly",
    "peculiar broth", "unusual liquid"), so the names are checked -- but the reliable tell is
    that ALL of them carry an ingestion syndrome, and ordinary water/berries/booze carry none.
    Both tests are applied. You do not want your one limb-regrowing jug drunk off as a snack.
  * FLESH OF THE SAPIENT -- anything whose source creature can learn or speak: an illithid
    brain, elf meat, dwarf blood -- UNLESS your ethics allow it. Whether DF offers these
    is decided by the EATER's civ ethics, not the meat: a kobold (EAT_SAPIENT_*:
    ACCEPTABLE) is served the same brain a dwarf is refused. Both EAT_SAPIENT ethics are
    consulted and either permitting (ACCEPTABLE through ONLY_IF_SANCTIONED, or REQUIRED)
    puts sapients on the menu; condemnation (MISGUIDED through UNTHINKABLE) keeps the
    screen. OUTSIDERS have no civ and hence no ethics; DF refuses them sapient flesh
    (observed on this save), so no-civ keeps the screen too.
  * ANYTHING DF ITSELF DECLINED TWICE. An item this script picked that does not show up
    in DF's list -- or whose row is clicked and clicked and never consumed -- collects a
    STRIKE; a second strike on a separate attempt retires its item id to a REFUSED list,
    never to be tried again this session. TWO strikes, not one, because a single failure
    can be the player's own doing -- walking keys or an opened menu tear the panel down
    mid-job, which says nothing about the item (one session's water got blacklisted that
    way). A job whose panel is torn down under it therefore aborts with NO strike; only a
    panel that is verifiably up and serving rows can convict, and an item that is later
    consumed successfully has its old strikes forgiven (stacks keep one item id, so a
    stack must be able to clear its name). `status` shows both lists;
    `adv/always-be-satiated forget` wipes them for a fresh start.
  * ROTTEN food, which is itself a way to end up vomiting.
  * LIQUID_MISC that is not water, not creature blood and not raws-edible -- that item
    type also covers lye and ichor. Plain blood IS drunk (a skin of cheetah blood quenches
    thirst like water); NIGHT-CREATURE blood is not, because it carries a syndrome and the
    syndrome gate refuses it before the type is even looked at.
  * Anything not in the pack: DF's eat/drink list also offers the ground and your own gear
    ("Eat snow (NW)", "Eat snow coating (bronze helm)"). Those rows are the ones with a NIL
    getItem(), and they are skipped -- this feeds you from your inventory, nothing else.

HOW IT CONSUMES -- through DF's own input, the same way you would. It feeds A_INV_EATDRINK to
raise the eat/drink panel, finds the row whose getItem() is the item it picked, scrolls that
row to the top (scroll_position), and LEFT-CLICKS the rendered text. Clicking the text is the
only thing that works: the a/b/c hotkey letters shown beside each row are not real keypresses
and feeding them does nothing at all (verified in-game -- adv/fight found the same on the
attack menu). Rows render at a 3-row pitch under the "...eat or drink?" header, and only ~11
fit on screen, which is why the row is scrolled up before the click instead of being hunted
for wherever it happens to be. Consumption is judged by the STOMACH, not the panel:
counters2.stomach_content rising by about one item is the success signal. The panel merely
closing proves nothing -- the player's own input also closes it -- so a closed panel over
an unmoved stomach is an abort, not a meal.

IT ALWAYS HANDS BACK A CLEAN SCREEN. Consuming an item closes the panel by itself, but every
exit path -- including every giving-up path -- ends by escaping out of whatever is still open
until the focus is `dungeonmode/Default` again. You are never left parked in a menu the script
opened.

CONFLICT WITH adv/keep-inventory, and why this script mutes it. keep-inventory reopens the
inventory panel after any action that closes it -- and consuming an item is exactly that, so
it would reopen the panel the instant we ate, leaving you in a menu AND blocking the next
check (which requires the plain map). For the few hundred milliseconds one consumption takes,
keep-inventory is switched off and then switched straight back on. It is restored on every
exit path, including when this script is disabled mid-action.

Thirst is served before hunger: DF kills you at 75000 thirst, while hunger only starts
burning stored fat. One item per turn, then it re-checks -- so a starving adventurer eats,
looks again, and eats once more next turn until the stomach ceiling stops it.

Registered as overlay `always-be-satiated.watcher`.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

enabled = enabled or false
function isEnabled() return enabled end

-- Counters: they separate "it never fired" from "it fired and the click missed", which look
-- identical in game. `adv/always-be-satiated status` prints them.
ate = ate or 0                  -- food consumed
drank = drank or 0              -- drink consumed
held_full = held_full or 0      -- times the stomach ceiling blocked an action
held_combat = held_combat or 0  -- times a nearby hostile blocked an action
misses = misses or 0            -- times the row could not be clicked and we backed out

-- Items DF itself declined: picked by this script but never listed in the eat/drink
-- panel (sapient flesh slips every static test -- the raws say EDIBLE), or listed but
-- the clicks never consumed them. Keyed by item id; wanted() skips these forever after.
refused = refused or {}
-- ...but conviction takes TWO strikes on separate attempts. A single failure can be the
-- player's own input tearing the panel down mid-job, which says nothing about the item.
suspects = suspects or {}

local function strike(id)
    if not id then return end
    suspects[id] = (suspects[id] or 0) + 1
    if suspects[id] >= 2 then refused[id] = true end
end

-- ---- thresholds -------------------------------------------------------------

-- DF's own flashing-status numbers (dwarffortresswiki DF2014:Hunger / DF2014:Thirst)
local HUNGRY  = 50000     -- "Hungry"  (75000 = Starving)
local THIRSTY = 25000     -- "Thirsty" (50000 = Dehydrated)

-- One consumed item = this much stomach_content, and this much off the hunger/thirst timer.
-- Measured live: fullness 0 -> 49995 -> 99990 -> 149985 over three items; thirst 63822 ->
-- 13822 on one drink.
local UNIT = 50000
-- The FIFTH item in the stomach is the one that makes you vomit; four is fine. So never START
-- an action above three units -- the worst case then settles at four, still clear of it.
local STOMACH_CEILING = 3 * UNIT

local COMBAT_RADIUS = 10  -- tiles; a hostile this close counts as "in combat"
local SETTLE_MS = 120     -- let DF render the panel/scroll before reading the screen for it
local RETRY_MS = 4000     -- after a failed or pointless attempt, wait this long before retrying

-- ---- helpers ----------------------------------------------------------------

local function adv_unit()
    return dfhack.world.getAdventurer and dfhack.world.getAdventurer() or nil
end
local function inv() return df.global.game.main_interface.adventure.inventory end
local function feed(k) gui.simulateInput(dfhack.gui.getDFViewscreen(true), k) end
local function focus() return dfhack.gui.getCurFocus(true)[1] or '' end
local function on_map() return focus() == 'dungeonmode/Default' end
local function input_ready()
    return df.global.adventure.player_control_state == df.adventure_game_loop_type.TAKING_INPUT
end
-- NOT fast travelling (or travel-sleeping). The focus string cannot tell you this -- it still
-- looks like the ordinary map -- so the menu enum is the check that matters.
local function walking_around()
    return df.global.adventure.menu == df.ui_advmode_menu.Default
end
local function now() return dfhack.getTickCount() end
-- the eat/drink panel is genuinely up and serving rows. Checked at EVERY stage of a job:
-- the player's own input can close the panel at any moment, and a stage that read stale
-- state through that would hand out strikes the items never earned
local function eat_panel_up()
    local i = inv()
    return i.open and i.context == df.adventure_interface_inventory_context_type.EAT_DRINK
        and #i.option_current > 0
end

-- read one rendered screen row as a plain string (non-ASCII cells become spaces, which is why
-- every needle we search for is run through ascii_needle first)
local function screen_row(y)
    local gps = df.global.gps
    local chars = {}
    for x = 0, gps.dimx - 1 do
        local ok, t = pcall(dfhack.screen.readTile, x, y)
        local ch = ok and t and t.ch or 0
        chars[x] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(chars, '', 0, gps.dimx - 1)
end

-- longest printable-ASCII run in a string: procedural item names carry bytes the screen reader
-- cannot render, so matching the whole name would never hit
local function ascii_needle(s)
    local best, cur = '', {}
    local function flush()
        local run = table.concat(cur)
        if #run > #best then best = run end
        cur = {}
    end
    for i = 1, #s do
        local b = s:byte(i)
        if b >= 32 and b < 127 then cur[#cur + 1] = string.char(b) else flush() end
    end
    flush()
    return (best:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- click the middle of the first occurrence of `needle` at or below row `from_y`. Left-clicks on
-- rendered text are how these lists are driven (the hotkey letters are inert).
local function click_text(needle, from_y)
    local gps = df.global.gps
    for y = from_y or 0, gps.dimy - 1 do
        local line = screen_row(y)
        local i = line:find(needle, 1, true)
        if i then
            local cx = (i - 1) + #needle // 2
            gps.mouse_x, gps.mouse_y = cx, y
            gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
            gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
            feed('_MOUSE_L')
            return true
        end
    end
    return false
end

-- the panel's header row; the option rows start below it. Used to keep the click search off the
-- map area entirely, so a needle can never be matched against map tiles.
local function panel_header_y()
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        if screen_row(y):find('eat or drink', 1, true) then return y end
    end
    return nil
end

-- ---- adv/keep-inventory interlock -------------------------------------------
-- keep-inventory reopens the inventory panel after anything that closes it, and consuming an
-- item closes it -- so it would pop the panel straight back up over us. It is muted for the
-- duration of one consumption and restored on every exit path.

local function keep_inventory()
    local ok, mod = pcall(reqscript, 'adv/keep-inventory')
    return ok and mod or nil
end

-- ---- what may be consumed ---------------------------------------------------

local T = df.item_type
local DRINKABLE = {[T.DRINK] = true, [T.LIQUID_MISC] = true}
local EDIBLE = {
    [T.FOOD] = true, [T.MEAT] = true, [T.FISH] = true, [T.FISH_RAW] = true,
    [T.CHEESE] = true, [T.EGG] = true, [T.PLANT] = true, [T.PLANT_GROWTH] = true,
    [T.GLOB] = true,
}

-- Mythical substances -- the healing liquids and globs of mysterious dungeons/palaces -- are
-- generated per world as <adjective> <noun> from these two lists. Names alone are not enough
-- (a world could name something else similarly), so has_syndrome below is the real test; this
-- is the cheap belt-and-braces half.
local MYTH_ADJ = {curious = true, weird = true, odd = true, strange = true,
                  unusual = true, peculiar = true}
local MYTH_NOUN = {liquid = true, fluid = true, broth = true, juice = true, goo = true,
                   liquor = true, solution = true, jelly = true, pulp = true, wax = true,
                   jam = true, dough = true}

local function looks_mythical(desc)
    local prev
    for w in desc:lower():gmatch('%a+') do
        if prev and MYTH_ADJ[prev] and MYTH_NOUN[w] then return true end
        prev = w
    end
    return false
end

-- every mythical substance carries an ingestion syndrome; plain water, booze and berries carry
-- none. NB material.syndrome is a creature_interactionst COMPOUND, and the vector of syndromes
-- hangs off it -- `#mat.syndrome` is a type error, `#mat.syndrome.syndrome` is the count.
local function has_syndrome(it)
    local mi = dfhack.matinfo.decode(it)
    if not (mi and mi.material) then return false end
    local ok, n = pcall(function() return #mi.material.syndrome.syndrome end)
    return ok and n > 0
end

local function describe(it)
    local ok, d = pcall(dfhack.items.getDescription, it, 0, true)
    return ok and d or ''
end

-- the label DF renders for a list row. Taken from the option itself rather than from the item,
-- so the needle we click for is the very text on screen -- getName fills a string OUT-param.
local function option_name(opt)
    local buf = df.new('string')
    local ok = pcall(function() opt:getName(buf) end)
    local name = ok and buf.value or ''
    buf:delete()
    return name
end

-- true when the material comes from a creature that can learn or speak (an illithid, an
-- elf). DF's eat/drink list refuses their flesh, brains and blood on your civ's ethics --
-- even though the raws happily mark them EDIBLE_COOKED -- so they must be screened here.
local function sapient_source(mi)
    local cr = mi and mi.creature
    if not cr then return false end
    for _, c in ipairs(cr.caste) do
        if c.flags.CAN_LEARN or c.flags.CAN_SPEAK then return true end
    end
    return false
end

-- may the ADVENTURER eat sapients? Their civ's ethics decide -- the meat has no say.
-- Either EAT_SAPIENT ethic permitting is enough: we cannot know whether the player or
-- somebody else killed the source creature, and leaning permissive is safe because a
-- wrong guess costs one panel flap before the refused list retires the item, while a
-- wrong refusal would starve a legitimate kobold forever. NOT_APPLICABLE (the token is
-- absent) counts as forbidding, as does having no civ at all: DF refuses outsiders
-- sapient flesh (observed on this save -- outsider dwarf, illithid brain never listed).
local ER = df.ethic_response
local function ethic_permits(v)
    return (v >= ER.ACCEPTABLE and v <= ER.ONLY_IF_SANCTIONED) or v == ER.REQUIRED
end
local function may_eat_sapients()
    local u = adv_unit()
    local civ_id = u and u.civ_id or -1
    if civ_id < 0 then
        -- the unit is off-map during fast travel; the historical figure still knows
        local nem = df.nemesis_record.find(df.global.adventure.player_id)
        civ_id = nem and nem.figure and nem.figure.civ_id or -1
    end
    local civ = civ_id >= 0 and df.historical_entity.find(civ_id) or nil
    local raw = civ and civ.entity_raw
    if not raw then return false end
    return ethic_permits(raw.ethic[df.ethic_type.EAT_SAPIENT_OTHER])
        or ethic_permits(raw.ethic[df.ethic_type.EAT_SAPIENT_KILL])
end

-- 'food', 'drink', or nil for anything we will not put in our mouth
local function classify(it)
    local ty = it:getType()
    if not (DRINKABLE[ty] or EDIBLE[ty]) then return nil end
    if it.flags.rotten then return nil end          -- rotten food is its own vomit trigger
    if looks_mythical(describe(it)) or has_syndrome(it) then return nil end   -- healing loot
    local mi = dfhack.matinfo.decode(it)
    -- illithid brain, elf meat: refused for most eaters -- but a civ whose ethics
    -- permit devouring sapients (kobolds, illithids) gets them as ordinary food
    if sapient_source(mi) and not may_eat_sapients() then return nil end
    local flags = mi and mi.material and mi.material.flags
    local edible_raws = flags and (flags.EDIBLE_RAW or flags.EDIBLE_COOKED)
    if DRINKABLE[ty] then
        if ty == T.DRINK then return 'drink' end    -- booze: always a drink
        -- LIQUID_MISC is water and milk, but ALSO lye, blood and ichor. Water carries no
        -- edible flag at all (checked in game), so it is named explicitly. Creature BLOOD
        -- is named too: DF's own list offers it and it quenches thirst like water. Blood
        -- with a syndrome (a night creature's) never reaches here -- has_syndrome above
        -- already refused it.
        if (mi and mi:getToken()) == 'WATER' or edible_raws then return 'drink' end
        if mi and mi.mode == 'creature' and mi.material and mi.material.id == 'BLOOD' then
            return 'drink'
        end
        return nil
    end
    if ty == T.FOOD then return 'food' end          -- a prepared meal
    return edible_raws and 'food' or nil
end

-- everything consumable in the pack, by kind, container contents included (DF's own eat/drink
-- list shows contained items too, one level down)
local function pack_contents()
    local u = adv_unit()
    local out = {food = {}, drink = {}}
    if not u then return out end
    local function consider(it)
        local kind = classify(it)
        if kind then table.insert(out[kind], it) end
    end
    for _, entry in ipairs(u.inventory) do
        consider(entry.item)
        local ok, contents = pcall(dfhack.items.getContainedItems, entry.item)
        if ok and contents then
            for _, ci in ipairs(contents) do consider(ci) end
        end
    end
    return out
end

-- ---- gating -----------------------------------------------------------------

local function needs(u)
    local c = u.counters2
    return c.hunger_timer >= HUNGRY, c.thirst_timer >= THIRSTY
end

-- a living hostile close enough to be a fight. isDanger is the same judgement adv/fight uses
-- for "will actually attack me"; the cheap distance test runs first so the call is only made
-- for units already nearby.
local function in_combat(u)
    if df.global.game.main_interface.adventure.attack.open then return true end
    for _, other in ipairs(df.global.world.units.active) do
        if other.id ~= u.id and other.pos.x >= 0
            and math.abs(other.pos.x - u.pos.x) <= COMBAT_RADIUS
            and math.abs(other.pos.y - u.pos.y) <= COMBAT_RADIUS
            and math.abs(other.pos.z - u.pos.z) <= 2
            and not dfhack.units.isDead(other) and not other.flags1.inactive
            and not other.flags1.caged and not other.flags1.chained then
            local ok, danger = pcall(dfhack.units.isDanger, other)
            if ok and danger then return true end
        end
    end
    return false
end

-- what to consume next, in priority order: thirst before hunger (dehydration kills at 75000;
-- hunger only starts burning stored fat). Returns {id, kind} records rather than item pointers
-- -- the list is carried across frames, and an item consumed or dropped in between would leave
-- a dangling pointer to read; an id that no longer matches any row simply misses.
local function wanted()
    local u = adv_unit()
    if not u then return {} end
    local hungry, thirsty = needs(u)
    local pack = pack_contents()
    local list = {}
    if thirsty then
        for _, it in ipairs(pack.drink) do
            if not refused[it.id] then table.insert(list, {id = it.id, kind = 'drink'}) end
        end
    end
    if hungry then
        for _, it in ipairs(pack.food) do
            if not refused[it.id] then table.insert(list, {id = it.id, kind = 'food'}) end
        end
    end
    return list
end

-- ---- overlay ----------------------------------------------------------------

AlwaysSatiated = defclass(AlwaysSatiated, overlay.OverlayWidget)
AlwaysSatiated.ATTRS{
    desc = 'Adventure mode: eat and drink from your pack when hungry or thirsty.',
    default_pos = {x = 1, y = 3},
    default_enabled = true,
    viewscreens = 'dungeonmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function AlwaysSatiated:mute_keep_inventory()
    local ki = keep_inventory()
    self.ki_muted = false
    if ki and ki.isEnabled and ki.isEnabled() then
        ki.enabled = false
        self.ki_muted = true
    end
end

function AlwaysSatiated:restore_keep_inventory()
    if not self.ki_muted then return end
    self.ki_muted = false
    local ki = keep_inventory()
    if ki then ki.enabled = true end
end

function AlwaysSatiated:reset()
    self:restore_keep_inventory()     -- never leave keep-inventory switched off behind us
    self.job = nil
    self.hold_until = 0
end

function AlwaysSatiated:back_off(ms)
    self.job = nil
    self.hold_until = now() + (ms or RETRY_MS)
end

-- every exit path lands here: escape out of anything still open, then hand back the plain map
function AlwaysSatiated:begin_clear(ms)
    self.job = {stage = 'clear', tries = 0, at = 0, wait = ms or SETTLE_MS}
end

-- Drive one consumption across frames:
--   'open'   -> feed A_INV_EATDRINK and wait for the eat/drink panel to actually be up
--   'scroll' -> find the row for one of our items, put it at the top of the list
--   'click'  -> once DF has rendered that, left-click the row's text
--   'verify' -> panel gone = the item was consumed
--   'clear'  -> escape out of any leftover menu so we finish on the plain adventure screen
function AlwaysSatiated:drive()
    local job = self.job

    if job.stage == 'open' then
        if eat_panel_up() then
            job.stage = 'scroll'
            return
        end
        job.waited = job.waited + 1
        if job.waited == 1 then
            if not (on_map() and input_ready() and walking_around()) then
                self:back_off(); return
            end
            feed('A_INV_EATDRINK')
        elseif job.waited > 40 then
            self:begin_clear()                    -- panel never came up; do not spam the key
        end

    elseif job.stage == 'scroll' then
        -- torn down under us (the player's walking keys, a menu): abort, no verdicts
        if not eat_panel_up() then self:begin_clear(); return end
        -- match by item IDENTITY, not by name: the list also holds the ground and our own
        -- gear, and two rows can read alike. Rows with a nil getItem() are the "Eat snow"
        -- style options and can never match, which is exactly what we want.
        local rows = inv().option_current
        local listed = {}                         -- item id -> its row, for every real row
        for idx, opt in ipairs(rows) do
            local ok, it = pcall(function() return opt:getItem() end)
            if ok and it then listed[it.id] = {idx = idx, opt = opt} end
        end
        for _, want in ipairs(job.items) do
            local hit = listed[want.id]
            if hit then
                inv().scroll_position = hit.idx   -- bring it to the top; only ~11 rows fit
                job.needle = ascii_needle(option_name(hit.opt))
                job.kind = want.kind              -- credit the row we actually matched, which
                                                  -- need not be the first one we asked for
                job.target_id = want.id
                job.stage, job.at, job.tries = 'click', now() + SETTLE_MS, 0
                return
            end
            -- the panel is verifiably up and serving rows, and this item is not among
            -- them: likely DF refusing it (a legality every static test missed). One
            -- strike; a second failed attempt convicts it onto the refused list
            strike(want.id)
        end
        misses = misses + 1                       -- nothing we picked is listed: leave quietly
        self:begin_clear()

    elseif job.stage == 'click' then
        if now() < job.at then return end          -- let the scrolled list render first
        -- torn down between scroll and click: abort, no strike
        if not eat_panel_up() then self:begin_clear(); return end
        if job.needle == '' then self:begin_clear(); return end
        if click_text(job.needle, panel_header_y()) then
            job.stage, job.at = 'verify', now() + SETTLE_MS
        else
            job.tries = job.tries + 1
            if job.tries > 6 then
                misses = misses + 1
                strike(job.target_id)              -- panel up, row unfindable: strike one
                self:begin_clear()
            end
        end

    elseif job.stage == 'verify' then
        -- the STOMACH is the proof of consumption, not the panel: the player's own input
        -- also closes the panel, and that must be neither counted nor blamed on the item
        local u = adv_unit()
        if u and u.counters2.stomach_content >= (job.stomach0 or 0) + UNIT // 2 then
            if job.kind == 'drink' then drank = drank + 1 else ate = ate + 1 end
            suspects[job.target_id or -1] = nil    -- proved consumable: forgive old strikes
                                                   -- (stacks keep one id across servings)
            self:begin_clear()
            return
        end
        if not inv().open then                     -- closed over an unmoved stomach: the
            self:begin_clear()                     -- player tore it down mid-job. No strike.
            return
        end
        if now() < job.at then return end
        job.tries = job.tries + 1
        if job.tries > 6 then
            misses = misses + 1
            strike(job.target_id)                  -- panel up, clicks land, nothing consumed
            self:begin_clear()
        else
            job.stage = 'click'                    -- still open: try the click once more
        end

    elseif job.stage == 'clear' then
        -- hand back a clean screen. keep-inventory is still muted here, so DF's own close
        -- sticks instead of being undone the moment it happens.
        if on_map() then
            self:restore_keep_inventory()
            self:back_off(job.wait)
            return
        end
        if now() < job.at then return end
        job.tries = job.tries + 1
        if job.tries > 12 then                     -- something we did not open is up: leave it
            self:restore_keep_inventory()
            self:back_off()
            return
        end
        feed('LEAVESCREEN')
        job.at = now() + SETTLE_MS
    end
end

function AlwaysSatiated:overlay_onupdate()
    if not enabled then self:reset(); return end
    if not dfhack.world.isAdventureMode() then return end
    if self.job then self:drive(); return end
    if now() < (self.hold_until or 0) then return end
    -- the plain adventure screen only: focus rules out panels and dialogs, walking_around
    -- rules out fast travel (which the focus string looks identical to)
    if not (on_map() and input_ready() and walking_around()) then return end

    local u = adv_unit()
    if not u or dfhack.units.isDead(u) then return end
    local hungry, thirsty = needs(u)
    if not (hungry or thirsty) then return end

    -- the vomit ceiling, before anything expensive: the fifth item in the stomach is what
    -- makes you throw up, so an action may only START from three or below
    if u.counters2.stomach_content > STOMACH_CEILING then
        held_full = held_full + 1
        self:back_off()
        return
    end
    if in_combat(u) then
        held_combat = held_combat + 1
        self:back_off()
        return
    end

    local items = wanted()
    if #items == 0 then self:back_off(); return end   -- nothing to eat: stop looking for a while
    self:mute_keep_inventory()
    self.job = {stage = 'open', waited = 0, tries = 0, items = items, kind = items[1].kind,
                stomach0 = u.counters2.stomach_content}   -- verify measures against this
    self:drive()
end

-- Ctrl+E toggles in-game, so you can stop it without the console (it is the only adventure-mode
-- binding on E; the fortress needs-tomb overlay uses the same chord in the other game mode).
function AlwaysSatiated:onInput(keys)
    if keys.CUSTOM_CTRL_E then
        enabled = not enabled
        dfhack.gui.showAnnouncement('always-be-satiated ' .. (enabled and 'ON' or 'OFF'),
            enabled and COLOR_LIGHTGREEN or COLOR_YELLOW, true)
        return true
    end
    return false
end

OVERLAY_WIDGETS = {watcher = AlwaysSatiated}

-- ---- CLI --------------------------------------------------------------------

if dfhack_flags.module then return end

local arg = ({...})[1]

if arg == 'status' then
    print(('always-be-satiated: %s'):format(enabled and 'ON' or 'OFF'))
    local u = adv_unit()
    if not u then
        print('  (no adventurer -- adventure mode only)')
        return
    end
    local c = u.counters2
    local hungry, thirsty = needs(u)
    print(('  hunger %d/%d%s   thirst %d/%d%s')
        :format(c.hunger_timer, HUNGRY, hungry and '  HUNGRY' or '',
                c.thirst_timer, THIRSTY, thirsty and '  THIRSTY' or ''))
    print(('  stomach %d = %.1f items (the 5th makes you vomit; acts at or below %d = %d items)')
        :format(c.stomach_content, c.stomach_content / UNIT,
                STOMACH_CEILING, STOMACH_CEILING // UNIT))
    print(('  screen: focus=%s menu=%s%s'):format(focus(),
        tostring(df.ui_advmode_menu[df.global.adventure.menu]),
        walking_around() and '' or '  (FAST TRAVEL -- will not act)'))
    print(('  in combat: %s'):format(tostring(in_combat(u))))
    print(('  sapient flesh: %s'):format(may_eat_sapients()
        and 'ON THE MENU (civ ethics permit devouring sapients)'
        or 'refused (civ ethics forbid it, or no civ)'))
    local pack = pack_contents()
    print(('  drinkable (%d):'):format(#pack.drink))
    for _, it in ipairs(pack.drink) do print('    ' .. describe(it)) end
    print(('  edible (%d):'):format(#pack.food))
    for _, it in ipairs(pack.food) do print('    ' .. describe(it)) end
    local nref = 0
    for _ in pairs(refused) do nref = nref + 1 end
    if nref > 0 then
        print(('  refused by DF this session (%d) -- will not be tried again (`forget` resets):'):format(nref))
        for id in pairs(refused) do
            local it = df.item.find(id)
            print('    ' .. (it and describe(it) or ('item #%d (no longer around)'):format(id)))
        end
    end
    local nsus = 0
    for id in pairs(suspects) do if not refused[id] then nsus = nsus + 1 end end
    if nsus > 0 then
        print(('  one strike (%d) -- a second failed attempt retires them:'):format(nsus))
        for id in pairs(suspects) do
            if not refused[id] then
                local it = df.item.find(id)
                print('    ' .. (it and describe(it) or ('item #%d (no longer around)'):format(id)))
            end
        end
    end
    print(('  counters: ate=%d drank=%d held(full)=%d held(combat)=%d misses=%d')
        :format(ate, drank, held_full, held_combat, misses))
    return
end

if arg == 'forget' then
    local n = 0
    for _ in pairs(refused) do n = n + 1 end
    refused, suspects = {}, {}
    print(('always-be-satiated: refused/strike lists cleared -- %d retired item(s) get a fresh chance.')
        :format(n))
    return
end

if dfhack_flags.enable ~= nil then
    enabled = dfhack_flags.enable_state and true or false
else
    enabled = not enabled
end
require('plugins.overlay').rescan()
print('always-be-satiated: ' .. (enabled
    and 'ON -- eating and drinking from your pack when hungry or thirsty (Ctrl+E or '
        .. '`disable adv/always-be-satiated` to stop).'
    or 'OFF.'))
