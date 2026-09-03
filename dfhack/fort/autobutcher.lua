-- One-number livestock caps, with a click-driven GUI and per-race cull rules.
--@module = true
--@enable = true
--[[
fort/autobutcher

A replacement for the stock `autobutcher` plugin and `gui/autobutcher`. The plugin
wants four numbers per race (female kids, male kids, female adults, male adults) and
always culls to all four; this one wants ONE number -- how many ADULTS of that species
you want -- and only does anything once you are over it.

    | Elephants          [-10] [-]   12/25   [+] [+10]   [edit] |

Clicking `12/25` (or pressing Enter) edits the limit; the arrows nudge it. The first two
rows are `!! ALL RACES PLUS NEW` and `!! ONLY NEW RACES`, exactly as the stock GUI has
them: the first writes every listed race AND the default for races you have yet to meet,
the second writes only that default.

What the single number means:

    While a species' adult count is at or under its limit, NOTHING is butchered -- the
    herd's sex ratio is your business. Once it grows past the limit, the surplus is
    marked for slaughter: MALES first, but never below the male floor (4) while there
    are still females to cut, then females. A limit small enough to need it will cut
    into that last handful of males too.

    A small number is a different problem, so the small numbers behave differently:

    2 to 4    one male and the rest females -- a herd this size wants breeding stock,
              not a spare bull. The last fertile male and the last fertile female are
              never butchered, even where that leaves you one over the number.
    1         a single animal, and the [-10] [-] buttons become [m] [f]: which sex the
              survivor is (female by default). Everything else goes.
    0         no adults at all. The buttons become one [kids:...] toggle: `cull` marks
              juveniles the moment they are born, `grow` (the default) lets them grow
              up and takes them as they reach adulthood. Type a number into the count
              column to come back up from 0 or 1.

Everything else lives behind `[edit]`, per race, and is remembered per fort:

    Child limit        how many juveniles to keep. -1 (the default) means "the same as
                       the adult limit". Juveniles are always culled youngest-first, so
                       the ones nearest adulthood are the ones that get there.
    Keep males         the male floor above (default 4).
    Keep N oldest      protect the N oldest adults outright (default 0). This is what
                       makes "keep 40 dinosaurs ageing, butcher every new adult" a
                       setting rather than a chore: limit 40, keep 40 oldest.
    Infertile first    butcher animals that will not breed -- gay or gelded -- before
                       ones that will (default on).
    Oldest first       among equals, butcher the oldest adult first (default on). Off
                       culls the youngest adults instead.
    War trained excluded  war- and hunting-trained animals are not livestock: they
                       are neither counted against the limit nor ever butchered
                       (default on). Turn it off to let them be culled, and then
                       `War animals last` decides when.
    Chained excluded   the same for animals on a chain or rope -- a bait animal or
                       a guard beast is placed on purpose, and is not part of the
                       herd it happens to share a species with (default on).
    Caged in zoo excluded  a caged animal standing inside a zone is an exhibit, not
                       livestock (default on). This is the stock plugin's rule and
                       for the same reason: a zoo is a cage somebody drew a zone
                       over, and there is no separate zoo flag to read.
    War animals last   with the exclusion off, war- and hunting-trained animals are
                       culled only when nothing else is left (default on).
    Adult age          the age, in years, at which this species counts as an adult and
                       becomes butcherable. Blank (the default) uses the creature's own
                       natural adult age.
    Managed            off leaves the species entirely alone.

Never touched, whatever the numbers say: untamed animals, named or nicknamed ones,
and pregnant females. Those still COUNT towards the limit -- they are
mouths -- so a herd of named cows will not sail past its cap; only the two
exclusions above take an animal out of the reckoning altogether.

Usage:
    enable fort/autobutcher    run the daily cull in the background
    disable fort/autobutcher   stop it
    fort/autobutcher           open the GUI
    fort/autobutcher now       run one cull pass immediately
    fort/autobutcher list      print the current configuration

Marks are OWNED: a slaughter mark this tool made is taken back off again by itself if you
raise the limit, so nothing is left condemned by a setting you have since changed. Marks
you set by hand (or with `fort/butcher-shop`) are never removed.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local dlg = require('gui.dialogs')

local GLOBAL_KEY = 'autobutcher'
local CYCLE_DAYS = 1

local DEFAULT_LIMIT = 25
local DEFAULT_MALES = 4

-- ---------------------------------------------------------------------------
-- config, persisted with the fort
-- ---------------------------------------------------------------------------
--
-- Races are keyed by their raw creature id ("ELEPHANT"), not by the numeric race
-- index: the index is a position in this world's raw list and says nothing in the
-- next fort, and this config is worth carrying between them.

local function new_cfg()
    return {
        limit = DEFAULT_LIMIT,
        kids = -1,            -- -1: same as the adult limit
        males = DEFAULT_MALES,
        keep_oldest = 0,
        gay_first = true,
        oldest_first = true,
        war_last = true,
        war_exclude = true,   -- war/hunting animals are not livestock at all
        chain_exclude = true, -- ...nor are chained ones
        zoo_exclude = true,   -- ...nor is one caged inside a zone (a zoo)
        adult_age = -1,       -- -1: the creature's natural adult age
        managed = true,
        sex = 'female',       -- which one to keep when the limit is 1
        kids_now = false,     -- limit 0: butcher juveniles now, or let them grow up

    }
end

local function copy_cfg(c)
    local out = new_cfg()
    for k in pairs(out) do if c[k] ~= nil then out[k] = c[k] end end
    return out
end

state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY,
            {enabled = false, defaults = new_cfg(), races = {}, marked = {}})
        -- a config written by an older version is missing the newer fields;
        -- normalizing on load keeps every reader from having to guess
        state.defaults = copy_cfg(state.defaults or {})
        state.races = state.races or {}
        for id, c in pairs(state.races) do state.races[id] = copy_cfg(c) end
        state.marked = state.marked or {}
    end
    return state
end

local function save_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

-- exported under a shorter name for callers that have just edited a config table
function save() save_state() end

-- creature id -> race index, built once. The raws do not change while a world is
-- loaded, and this is walked on every GUI refresh.
local race_index = nil

function race_index_map()
    if not race_index then
        race_index = {}
        for i, cr in ipairs(df.global.world.raws.creatures.all) do
            race_index[cr.creature_id] = i
        end
    end
    return race_index
end

local function creature_id(race)
    local cr = df.creature_raw.find(race)
    return cr and cr.creature_id or nil
end

-- the config a race is actually run under: its own if it has one, the default otherwise
function cfg_for(race)
    load_state()
    local id = creature_id(race)
    return (id and state.races[id]) or state.defaults
end

-- give a race a config of its own, seeded from whatever it was running under
function own_cfg(race)
    load_state()
    local id = creature_id(race)
    if not id then return nil end
    if not state.races[id] then state.races[id] = copy_cfg(state.defaults) end
    return state.races[id]
end

local function has_own_cfg(race)
    load_state()
    local id = creature_id(race)
    return id ~= nil and state.races[id] ~= nil
end

-- ---------------------------------------------------------------------------
-- the livestock
-- ---------------------------------------------------------------------------

local function unit_age(u)
    local a = 0
    pcall(function() a = dfhack.units.getAge(u, true) end)
    return a
end

local function flag(u, get)
    local v = false
    pcall(function() v = get(u) and true or false end)
    return v
end

-- fort livestock: alive, tame, ours, and an animal. Merchant stock is somebody
-- else's property and is never counted or culled.
local function is_livestock(u)
    return dfhack.units.isFortControlled(u) and dfhack.units.isAnimal(u)
        and dfhack.units.isAlive(u) and dfhack.units.isTame(u)
        and not dfhack.units.isMerchant(u)
end

-- Trained for war or hunting. With `war_exclude` on these are not livestock at
-- all: they do not count towards the limit and are never marked, which is what
-- keeps a war-dog kennel from reading as a herd that needs thinning.
local function is_war(u)
    return flag(u, dfhack.units.isWar) or flag(u, dfhack.units.isHunter)
end

local function is_chained(u)
    return flag(u, function(x) return x.flags1.chained end)
end

-- A caged animal with a zone drawn over its cage: an exhibit. DF has no zoo flag
-- to read on this build -- there is no Zoo in `civzone_type` at all -- so the test
-- is the stock plugin's: caged, and standing in a zone of any kind.
local function is_in_zoo(u)
    if not flag(u, function(x) return x.flags1.caged end) then return false end
    local found = false
    pcall(function()
        local zones = dfhack.buildings.findCivzonesAt(xyz2pos(u.pos.x, u.pos.y, u.pos.z))
        found = zones ~= nil and #zones > 0
    end)
    return found
end

-- Not part of the herd at all: neither counted against the limit nor ever marked.
local function is_excluded(u, cfg)
    if cfg.war_exclude and is_war(u) then return true end
    if cfg.chain_exclude and is_chained(u) then return true end
    if cfg.zoo_exclude and is_in_zoo(u) then return true end
    return false
end

-- Off limits whatever the numbers say -- but still counted. Named animals are
-- somebody's, and a pregnant female is a herd you already have. A caged animal is
-- NOT protected here: a cage in a stockpile is storage, and the cage that means
-- something -- one in a zone -- is handled as an exclusion above.
local function is_protected(u)
    if flag(u, function(x) return x.name.has_name end) then return true end
    if flag(u, function(x) return x.name.nickname ~= '' end) then return true end
    if flag(u, function(x) return x.pregnancy_timer > 0 end) then return true end
    if flag(u, function(x) return x.pregnancy_genes ~= nil end) then return true end
    return false
end

local function is_adult(u, cfg)
    if cfg.adult_age and cfg.adult_age >= 0 then return unit_age(u) >= cfg.adult_age end
    local a = true
    pcall(function() a = dfhack.units.isAdult(u) end)
    return a
end

local function is_male(u)
    return flag(u, function(x) return dfhack.units.isMale(x) end)
end

-- every race we have livestock of, plus every race you have already configured,
-- as {race = <index>, name = <plural>, adults =, kids =, marked =}
function census()
    load_state()
    local by_race = {}
    local function bucket(race)
        local b = by_race[race]
        if not b then
            b = {race = race, adults = 0, kids = 0, marked = 0,
                 name = dfhack.units.getRaceNamePluralById(race) or ('race ' .. race)}
            by_race[race] = b
        end
        return b
    end
    for _, u in ipairs(df.global.world.units.active) do
        local cfg = cfg_for(u.race)
        if is_livestock(u) then
            local b = bucket(u.race)
            -- the count shown is the count the limit is measured against, so an
            -- excluded war dog or chained bait animal is left out of it (and shown
            -- as a `(+n)` beside the name) rather than making `9/8` of a herd that
            -- is doing exactly what it was told
            if is_excluded(u, cfg) then
                b.excluded = (b.excluded or 0) + 1
            elseif is_adult(u, cfg) then
                b.adults = b.adults + 1
            else
                b.kids = b.kids + 1
            end
            if flag(u, function(x) return x.flags2.slaughter end) then b.marked = b.marked + 1 end
        end
    end
    -- a configured race with nothing left alive still shows, so the setting you
    -- made for it is visible (and editable) rather than vanishing with the herd
    local by_id = race_index_map()
    for id in pairs(state.races) do
        if by_id[id] then bucket(by_id[id]) end
    end
    local out = {}
    for _, b in pairs(by_race) do out[#out + 1] = b end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ---------------------------------------------------------------------------
-- the cull
-- ---------------------------------------------------------------------------

-- Cull order within a pool, worst breeder first. The tiers are checked in the
-- order they matter: a war dog is kept over anything, then an animal that will
-- never breed goes before one that will, then a half-trained one before a fully
-- domesticated one, and age settles the rest.
local function cull_order(pool, cfg)
    local rank = {}
    for _, u in ipairs(pool) do
        rank[u.id] = {
            war = (cfg.war_last and is_war(u)) and 1 or 0,
            barren = cfg.gay_first
                and ((flag(u, dfhack.units.isGay) or flag(u, dfhack.units.isGelded)) and 0 or 1)
                or 0,
            tame = flag(u, dfhack.units.isDomesticated) and 1 or 0,
            age = unit_age(u),
        }
    end
    local order = {}
    for _, u in ipairs(pool) do order[#order + 1] = u end
    table.sort(order, function(a, b)
        local ra, rb = rank[a.id], rank[b.id]
        if ra.war ~= rb.war then return ra.war < rb.war end
        if ra.barren ~= rb.barren then return ra.barren < rb.barren end
        if ra.tame ~= rb.tame then return ra.tame < rb.tame end
        if ra.age ~= rb.age then
            if cfg.oldest_first then return ra.age > rb.age end
            return ra.age < rb.age
        end
        return a.id < b.id
    end)
    return order
end

local function is_fertile(u)
    return not (flag(u, dfhack.units.isGay) or flag(u, dfhack.units.isGelded))
end

-- How many males the herd is allowed to keep. Above 4 that is the configured floor
-- (one less than the limit at the very least, so there is always room for a female);
-- a herd of 2 to 4 gets exactly one male and spends the rest of the number on
-- females; a herd of 1 is whichever sex you picked; a herd of 0 is none.
local function male_floor(cfg)
    local limit = math.max(0, cfg.limit)
    if limit == 0 then return 0 end
    if limit == 1 then return cfg.sex == 'male' and 1 or 0 end
    if limit <= 4 then return 1 end
    return math.max(0, math.min(cfg.males or DEFAULT_MALES, limit - 1))
end

-- Who to cut, given the whole adult pool. The male floor is a floor on the HERD,
-- not a quota to cut down to: males are taken first only while more than the floor
-- of them remain, and the last of them are touched only once the females are gone
-- and the limit still is not met.
local function pick_adults(adults, surplus, cfg)
    local males, females = {}, {}
    for _, u in ipairs(adults) do
        if is_male(u) then males[#males + 1] = u else females[#females + 1] = u end
    end
    local floor = male_floor(cfg)
    local male_order = cull_order(males, cfg)
    local female_order = cull_order(females, cfg)
    -- The breeding pair, lifted out of the pool entirely: from a herd of 2 or more,
    -- the fertile male and fertile female that would have been culled LAST are not
    -- culled at all. Without this a run of bad luck -- an all-gay cohort, a war dog
    -- holding the floor -- can leave a herd that cannot breed itself back.
    if cfg.limit >= 2 then
        local function last_fertile(order)
            for i = #order, 1, -1 do
                if is_fertile(order[i]) then return order[i] end
            end
        end
        local keep = {}
        local km, kf = last_fertile(male_order), last_fertile(female_order)
        if km then keep[km.id] = true end
        if kf then keep[kf.id] = true end
        local function without(order)
            local out = {}
            for _, u in ipairs(order) do if not keep[u.id] then out[#out + 1] = u end end
            return out
        end
        male_order, female_order = without(male_order), without(female_order)
        males = male_order
    end
    local picked = {}
    local spare_males = math.max(0, #males - floor)
    for i = 1, math.min(surplus, spare_males) do picked[#picked + 1] = male_order[i] end
    local i = 1
    while #picked < surplus and i <= #female_order do
        picked[#picked + 1] = female_order[i]
        i = i + 1
    end
    -- still over: the floor cannot be honoured and the limit at the same time,
    -- and the limit is the thing the player actually asked for
    local j = spare_males + 1
    while #picked < surplus and j <= #male_order do
        picked[#picked + 1] = male_order[j]
        j = j + 1
    end
    return picked
end

-- Everything this tool would have marked right now, as a set of unit ids. The
-- cull is recomputed from scratch every pass rather than remembered, so raising a
-- limit takes marks back off (see `apply`) and lowering one adds to them.
local function wanted_marks()
    load_state()
    -- Two numbers per race, and they are not the same one: `n_adults` is the whole
    -- herd (a named cow is still a mouth, and still counts against the limit), while
    -- `adults` is only what may actually be marked.
    local pools = {}
    for _, u in ipairs(df.global.world.units.active) do
        local cfg = cfg_for(u.race)
        if is_livestock(u) and not is_excluded(u, cfg) then
            local p = pools[u.race]
            if not p then p = {adults = {}, kids = {}, n_adults = 0, n_kids = 0}; pools[u.race] = p end
            local adult = is_adult(u, cfg)
            if adult then p.n_adults = p.n_adults + 1 else p.n_kids = p.n_kids + 1 end
            if not is_protected(u) then
                if adult then p.adults[#p.adults + 1] = u else p.kids[#p.kids + 1] = u end
            end
        end
    end
    local want = {}
    for race, p in pairs(pools) do
        local cfg = cfg_for(race)
        if cfg.managed then
            -- the oldest few are lifted out of the pool entirely, so a herd kept
            -- for its age is culled from the young end however the rules are set
            local adults = p.adults
            if (cfg.keep_oldest or 0) > 0 then
                local by_age = {}
                for _, u in ipairs(adults) do by_age[#by_age + 1] = u end
                table.sort(by_age, function(a, b) return unit_age(a) > unit_age(b) end)
                local keep = {}
                for i = 1, math.min(cfg.keep_oldest, #by_age) do keep[by_age[i].id] = true end
                adults = {}
                for _, u in ipairs(p.adults) do if not keep[u.id] then adults[#adults + 1] = u end end
            end
            local surplus = p.n_adults - math.max(0, cfg.limit)
            if surplus > 0 then
                for _, u in ipairs(pick_adults(adults, surplus, cfg)) do want[u.id] = true end
            end
            -- at a limit of 0 the [kids] toggle IS the juvenile rule: `cull` takes
            -- them now, `grow` lets them reach adulthood and catches them there
            local kid_limit
            if cfg.limit <= 0 then
                kid_limit = cfg.kids_now and 0 or math.huge
            else
                kid_limit = (cfg.kids or -1) >= 0 and cfg.kids or math.max(0, cfg.limit)
            end
            local kid_surplus = p.n_kids - kid_limit
            if kid_surplus > 0 then
                -- juveniles are always taken youngest-first, whatever `oldest_first`
                -- says: the point of keeping a kid at all is that it grows up
                local kcfg = copy_cfg(cfg)
                kcfg.oldest_first = false
                local order = cull_order(p.kids, kcfg)
                for i = 1, math.min(kid_surplus, #order) do want[order[i].id] = true end
            end
        end
    end
    return want
end

-- One pass. Returns marked, unmarked.
function apply()
    load_state()
    if not dfhack.world.isFortressMode() then return 0, 0 end
    local want = wanted_marks()
    local marked, unmarked = 0, 0
    local mine = state.marked
    for _, u in ipairs(df.global.world.units.active) do
        if is_livestock(u) then
            local id = tostring(u.id)
            local is_marked = flag(u, function(x) return x.flags2.slaughter end)
            if want[u.id] then
                if not is_marked then
                    pcall(function() u.flags2.slaughter = true end)
                    marked = marked + 1
                end
                mine[id] = true
            elseif is_marked and mine[id] then
                -- ours and no longer wanted: take it back off. A mark somebody
                -- else made is left exactly where it is.
                pcall(function() u.flags2.slaughter = false end)
                mine[id] = nil
                unmarked = unmarked + 1
            end
        end
    end
    -- forget units that have since been slaughtered, so the list does not grow
    -- without bound over a fort's life
    for id in pairs(mine) do
        local u = df.unit.find(tonumber(id))
        if not u or not dfhack.units.isAlive(u) then mine[id] = nil end
    end
    save_state()
    return marked, unmarked
end

-- ---------------------------------------------------------------------------
-- background service
-- ---------------------------------------------------------------------------

enabled = enabled or false

function isEnabled()
    return enabled
end

-- Daily cycle driven off a per-frame heartbeat gated on the game calendar, not
-- repeat-util: on this build repeat-util's day timeouts count rendered frames and
-- fire only every few game-days. (Same reasoning as fort/auto-pasture.)
local DAY_TICKS = 1200 * CYCLE_DAYS
local last_run = nil
local hb_gen = 0

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        if dfhack.world.isFortressMode() then
            local now = df.global.cur_year * 403200 + df.global.cur_year_tick
            if not last_run or now - last_run >= DAY_TICKS then
                last_run = now
                apply()
            end
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

-- exported so magnus-scripts can drive it through reqscript (the `enable` command
-- goes through run_script, which on this build can serve a stale cached copy)
function set_enabled(on)
    load_state()
    if on then
        -- the stock plugin marks to its own four targets and would undo (or
        -- double up on) everything decided here, so only one of the two may run
        local ok, ab = pcall(require, 'plugins.autobutcher')
        if ok and ab.isEnabled and ab.isEnabled() then
            dfhack.run_command('disable', 'autobutcher')
            print('fort/autobutcher: disabled the stock autobutcher plugin (they cannot both run)')
        end
        start()
    else
        stop()
    end
    state.enabled = enabled
    save_state()
    return enabled
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        stop()
        state = nil
        race_index = nil
    elseif sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() then
            load_state()
            if state.enabled then start() end
        end
    end
end

-- ---------------------------------------------------------------------------
-- row layout
-- ---------------------------------------------------------------------------
--
-- Every row is the same width in every column, so the click ranges are computed
-- once from the segment widths rather than measured per row -- which is also what
-- keeps the arrows lined up under each other whatever the species is called.

local NAME_W = 26
local LEFT_W = 11        -- the [-10] [-] block, or whatever replaces it
local COUNT_W = 11

local function pad(s, w)
    if #s > w then return s:sub(1, w - 1) .. '.' end
    return s .. (' '):rep(w - #s)
end

local function centre(s, w)
    local left = math.floor((w - #s) / 2)
    return (' '):rep(math.max(0, left)) .. s .. (' '):rep(math.max(0, w - #s - left))
end

-- The block left of the number. It is always LEFT_W wide, whatever it holds, so
-- the count and the buttons right of it stay in one column down the whole list
-- even when the rows are running different limits.
--
--   2 and up   [-10] [-]        the ordinary nudges
--   1          [m] [f]          which sex the single survivor is; the chosen one
--                               is the capital. Mutually exclusive, so this is a
--                               pair of radio buttons rather than two toggles.
--   0          [kids:cull|grow] cull juveniles now, or let them grow up first
local function left_block(cfg)
    local limit = math.max(0, cfg.limit)
    if limit == 0 then
        return {{text = cfg.kids_now and '[kids:cull]' or '[kids:grow]', act = 'kids'}}
    end
    if limit == 1 then
        local male = cfg.sex == 'male'
        return {
            {text = '  '},
            {text = male and '[M]' or '[m]', act = 'set_male'},
            {text = ' '},
            {text = male and '[f]' or '[F]', act = 'set_female'},
            {text = '  '},
        }
    end
    return {
        {text = '[-10]', act = 'sub10'},
        {text = ' '},
        {text = '[-]', act = 'sub1'},
        {text = '  '},
    }
end

-- `count` is nil on the two heading rows, which have a limit but no herd of their
-- own. Returns the drawn text and the click ranges that go with it.
local function row_text(name, count, cfg, dim)
    local segs = {{text = pad(name, NAME_W)}, {text = '  '}}
    for _, seg in ipairs(left_block(cfg)) do segs[#segs + 1] = seg end
    segs[#segs + 1] = {
        text = centre(('%s/%d'):format(count and tostring(count) or '-', cfg.limit), COUNT_W),
        act = 'edit_limit',
    }
    for _, seg in ipairs{
        {text = '  '},
        {text = '[+]', act = 'add1'},
        {text = ' '},
        {text = '[+10]', act = 'add10'},
        {text = '   '},
        {text = '[edit]', act = 'extra'},
    } do segs[#segs + 1] = seg end

    local parts, ranges, x = {}, {}, 0
    for _, seg in ipairs(segs) do
        parts[#parts + 1] = seg.text
        if seg.act then ranges[#ranges + 1] = {x1 = x, x2 = x + #seg.text - 1, act = seg.act} end
        x = x + #seg.text
    end
    local text = table.concat(parts)
    if dim then text = {{text = text, pen = COLOR_GREY}} end
    return text, ranges
end

local ROW_W = NAME_W + 2 + LEFT_W + COUNT_W + 2 + 3 + 1 + 5 + 3 + 6

local function action_at(ranges, x)
    for _, r in ipairs(ranges) do
        if x >= r.x1 and x <= r.x2 then return r.act end
    end
end

-- ---------------------------------------------------------------------------
-- the [extra] dialog
-- ---------------------------------------------------------------------------

Extra = defclass(Extra, widgets.Window)
Extra.ATTRS{
    frame = {w = 62, h = 25},
    frame_title = 'Rules',
    resizable = false,
    cfg = DEFAULT_NIL,
    label = DEFAULT_NIL,
    on_apply = DEFAULT_NIL,
}

local function num_field(view_id, t, label, value, help)
    return widgets.Panel{
        frame = {t = t, l = 0, h = 1},
        subviews = {
            widgets.Label{frame = {t = 0, l = 0}, text = label},
            widgets.EditField{
                view_id = view_id,
                frame = {t = 0, l = 18, w = 8},
                text = tostring(value),
            },
            widgets.Label{frame = {t = 0, l = 28}, text = help, text_pen = COLOR_GREY},
        },
    }
end

function Extra:init()
    local c = self.cfg
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = {{text = self.label, pen = COLOR_LIGHTCYAN}}},
        num_field('kids', 2, 'Child limit:', c.kids, '-1 = same as adults'),
        num_field('males', 3, 'Keep males:', c.males, 'floor while culling'),
        num_field('keep_oldest', 4, 'Keep N oldest:', c.keep_oldest, 'never butchered'),
        num_field('adult_age', 5, 'Adult age:', c.adult_age, '-1 = natural (years)'),
        widgets.ToggleHotkeyLabel{
            view_id = 'gay_first', frame = {t = 7, l = 0}, key = 'CUSTOM_G',
            label = 'Infertile first:      ', initial_option = c.gay_first,
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'oldest_first', frame = {t = 8, l = 0}, key = 'CUSTOM_O',
            label = 'Oldest first:         ', initial_option = c.oldest_first,
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'war_exclude', frame = {t = 9, l = 0}, key = 'CUSTOM_T',
            label = 'War trained excluded: ', initial_option = c.war_exclude,
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'chain_exclude', frame = {t = 10, l = 0}, key = 'CUSTOM_C',
            label = 'Chained excluded:     ', initial_option = c.chain_exclude,
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'zoo_exclude', frame = {t = 11, l = 0}, key = 'CUSTOM_Z',
            label = 'Caged in zoo excluded:', initial_option = c.zoo_exclude,
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'war_last', frame = {t = 12, l = 0}, key = 'CUSTOM_W',
            label = 'War animals last:     ', initial_option = c.war_last,
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'managed', frame = {t = 13, l = 0}, key = 'CUSTOM_M',
            label = 'Managed:              ', initial_option = c.managed,
        },
        widgets.Label{
            frame = {t = 15, l = 0},
            text = {
                'Gay or gelded animals never breed, so they go',
                NEWLINE,
                'first; war and hunting animals go last, only once',
                NEWLINE,
                'nothing else is left. Juveniles are always culled',
                NEWLINE,
                'youngest-first, so the ones nearest adulthood are',
                NEWLINE,
                'the ones that get there. Esc closes without saving.',
            },
            text_pen = COLOR_GREY,
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 0}, key = 'CUSTOM_CTRL_A', label = '[apply]',
            on_activate = function() self:apply(false) end,
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 18}, key = 'CUSTOM_CTRL_L', label = '[apply to all races]',
            on_activate = function() self:apply(true) end,
        },
    }
end

function Extra:apply(to_all)
    local function num(id, fallback)
        local v = tonumber(self.subviews[id].text)
        if not v then return fallback end
        return math.floor(v)
    end
    local c = self.cfg
    c.kids = math.max(-1, num('kids', c.kids))
    c.males = math.max(0, num('males', c.males))
    c.keep_oldest = math.max(0, num('keep_oldest', c.keep_oldest))
    c.adult_age = math.max(-1, num('adult_age', c.adult_age))
    c.gay_first = self.subviews.gay_first:getOptionValue()
    c.oldest_first = self.subviews.oldest_first:getOptionValue()
    c.war_exclude = self.subviews.war_exclude:getOptionValue()
    c.chain_exclude = self.subviews.chain_exclude:getOptionValue()
    c.zoo_exclude = self.subviews.zoo_exclude:getOptionValue()
    c.war_last = self.subviews.war_last:getOptionValue()
    c.managed = self.subviews.managed:getOptionValue()
    self.on_apply(c, to_all)
    self.parent_view:dismiss()
end

ExtraScreen = defclass(ExtraScreen, gui.ZScreen)
ExtraScreen.ATTRS{
    focus_path = 'autobutcher/extra',
    cfg = DEFAULT_NIL,
    label = DEFAULT_NIL,
    on_apply = DEFAULT_NIL,
}
function ExtraScreen:init()
    self:addviews{Extra{cfg = self.cfg, label = self.label, on_apply = self.on_apply}}
end

-- ---------------------------------------------------------------------------
-- main window
-- ---------------------------------------------------------------------------

local ROW_ALL = 'all'      -- every listed race, and the default for new ones
local ROW_NEW = 'new'      -- the default for new races only

Butcher = defclass(Butcher, widgets.Window)
Butcher.ATTRS{
    frame_title = 'autobutcher',
    frame = {w = ROW_W + 6, h = 50},
    resizable = true,
    resize_min = {w = ROW_W + 6, h = 14},
}

function Butcher:init()
    self:addviews{
        widgets.ToggleHotkeyLabel{
            view_id = 'enabled',
            frame = {t = 0, l = 0, w = 40},
            key = 'CUSTOM_CTRL_E',
            label = 'Butcher automatically:',
            initial_option = isEnabled(),
            on_change = function(val) set_enabled(val) end,
        },
        widgets.Label{
            frame = {t = 1, l = 0},
            text = 'Adults to keep. Click the number to type one; [edit] for the rules.',
            text_pen = COLOR_GREY,
        },
        widgets.Label{
            frame = {t = 3, l = 0},
            text = pad('Species', NAME_W) .. '            now/keep',
            text_pen = COLOR_LIGHTCYAN,
        },
        widgets.List{
            view_id = 'list',
            frame = {t = 4, l = 0, b = 3},
            on_submit = function(_, choice) self:click(choice) end,
        },
        widgets.HotkeyLabel{
            frame = {b = 1, l = 0}, key = 'CUSTOM_CTRL_N', label = 'run a pass now',
            on_activate = function() self:run_now() end,
        },
        widgets.Label{
            view_id = 'status',
            frame = {b = 0, l = 0},
            text = 'Enter types a limit for the selected row; Ctrl-X opens its rules.',
            text_pen = COLOR_GREY,
        },
    }
    self:refresh()
end

function Butcher:refresh()
    load_state()
    local choices = {}
    local function add(name, count, cfg, dim, extra)
        local text, ranges = row_text(name, count, cfg, dim)
        local c = {text = text, ranges = ranges}
        for k, v in pairs(extra) do c[k] = v end
        choices[#choices + 1] = c
    end
    add('!! ALL RACES PLUS NEW', nil, state.defaults, false, {kind = ROW_ALL})
    add('!! ONLY NEW RACES', nil, state.defaults, false, {kind = ROW_NEW})
    for _, b in ipairs(census()) do
        -- a race still running on the default is greyed, so which rows you have
        -- actually decided about is visible at a glance
        local name = b.name
        if (b.excluded or 0) > 0 then name = ('%s (+%d)'):format(name, b.excluded) end
        add(name, b.adults, cfg_for(b.race), not has_own_cfg(b.race),
            {kind = 'race', race = b.race, name = b.name})
    end
    self.subviews.list:setChoices(choices, self.subviews.list:getSelected())
end

-- the config table(s) a row writes to
function Butcher:targets(choice)
    load_state()
    if choice.kind == ROW_NEW then return {state.defaults} end
    if choice.kind == ROW_ALL then
        local out = {state.defaults}
        for _, b in ipairs(census()) do out[#out + 1] = own_cfg(b.race) end
        return out
    end
    return {own_cfg(choice.race)}
end

function Butcher:nudge(choice, delta)
    for _, c in ipairs(self:targets(choice)) do
        c.limit = math.max(0, c.limit + delta)
    end
    save_state()
    self:refresh()
end

function Butcher:edit_limit(choice)
    local cur = choice.kind == 'race' and cfg_for(choice.race).limit or state.defaults.limit
    dlg.showInputPrompt(
        'Adults to keep',
        ('How many adult %s should the fort keep?'):format(
            choice.kind == 'race' and choice.name or 'animals of every species'),
        COLOR_WHITE,
        tostring(cur),
        function(text)
            local n = tonumber(text)
            if not n or n < 0 then return end
            for _, c in ipairs(self:targets(choice)) do c.limit = math.floor(n) end
            save_state()
            self:refresh()
        end)
end

function Butcher:extra(choice)
    local label = choice.kind == 'race' and choice.name
        or (choice.kind == ROW_ALL and 'all races plus new' or 'new races only')
    local base = choice.kind == 'race' and cfg_for(choice.race) or state.defaults
    ExtraScreen{
        cfg = copy_cfg(base),
        label = label,
        on_apply = function(c, to_all)
            local targets = to_all and self:targets({kind = ROW_ALL}) or self:targets(choice)
            for _, t in ipairs(targets) do
                for k, v in pairs(c) do
                    if k ~= 'limit' then t[k] = v end
                end
            end
            save_state()
            self:refresh()
        end,
    }:show()
end

-- keyboard use lands on the number, which is the one control every row has
function Butcher:click(choice)
    local x = self.subviews.list:getMousePos()
    local act = (x and action_at(choice.ranges, x)) or 'edit_limit'
    if act == 'sub10' then self:nudge(choice, -10)
    elseif act == 'sub1' then self:nudge(choice, -1)
    elseif act == 'add1' then self:nudge(choice, 1)
    elseif act == 'add10' then self:nudge(choice, 10)
    elseif act == 'extra' then self:extra(choice)
    elseif act == 'edit_limit' then self:edit_limit(choice)
    elseif act == 'set_male' then self:set(choice, {sex = 'male'})
    elseif act == 'set_female' then self:set(choice, {sex = 'female'})
    elseif act == 'kids' then
        local cur = choice.kind == 'race' and cfg_for(choice.race) or state.defaults
        self:set(choice, {kids_now = not cur.kids_now})
    end
end

function Butcher:set(choice, fields)
    for _, c in ipairs(self:targets(choice)) do
        for k, v in pairs(fields) do c[k] = v end
    end
    save_state()
    self:refresh()
end

function Butcher:run_now()
    local m, u = apply()
    self:refresh()
    self.subviews.status:setText(
        ('Marked %d for slaughter, un-marked %d.'):format(m, u))
end

function Butcher:onInput(keys)
    if keys.CUSTOM_CTRL_X then
        local _, choice = self.subviews.list:getSelected()
        if choice then self:extra(choice) end
        return true
    end
    return Butcher.super.onInput(self, keys)
end

ButcherScreen = defclass(ButcherScreen, gui.ZScreen)
ButcherScreen.ATTRS{focus_path = 'autobutcher'}
function ButcherScreen:init() self:addviews{Butcher{}} end
function ButcherScreen:onDismiss() view = nil end

view = view or nil

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

local function print_list()
    load_state()
    local d = state.defaults
    print(('autobutcher: %s'):format(enabled and 'enabled' or 'disabled'))
    print(('  default: keep %d adults, %s kids, %d males, %d oldest%s%s%s%s')
        :format(d.limit, d.kids < 0 and 'as many as adults' or tostring(d.kids), d.males, d.keep_oldest,
            d.gay_first and ', infertile first' or '',
            d.oldest_first and ', oldest first' or ', youngest first',
            d.war_last and ', war last' or '',
            d.managed and '' or ', UNMANAGED'))
    for _, b in ipairs(census()) do
        local c = cfg_for(b.race)
        print(('  %-24s %3d adults, %3d young -> keep %d%s')
            :format(b.name, b.adults, b.kids, c.limit, has_own_cfg(b.race) and '' or ' (default)'))
    end
end

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then
        qerror('fort/autobutcher can only be enabled in fortress mode')
    end
    set_enabled(dfhack_flags.enable_state)
    print('fort/autobutcher: ' .. (enabled and 'enabled (daily)' or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then
    qerror('fort/autobutcher only works in fortress mode')
end

local arg = ({...})[1]
if arg == 'now' then
    local m, u = apply()
    print(('fort/autobutcher: marked %d for slaughter, un-marked %d'):format(m, u))
elseif arg == 'list' then
    print_list()
elseif arg then
    qerror('unknown argument: ' .. arg .. ' (expected "now" or "list", or nothing for the GUI)')
else
    view = view or ButcherScreen{}:show()
end
