-- Adventure mode: item values at broker precision + Appraiser skill training.
--@module = true
--[[
adv/appraiser

Shows what things are WORTH, and teaches you to judge it. Item values appear
directly below each item's weight in the inventory list and the pick-up menu
(painted by adv/inventory-display-weight, which asks this module for the
label), at the precision an equivalently skilled fortress broker would get:

    Appraiser rating 0      ?           (no appraiser, no numbers -- as a fort
                                         with no broker sees its depot)
    rating 1-5              ~300        (nearest 100)
    rating 6-10             ~340        (nearest 10)
    rating 11+              347         (exact -- a master broker's eye)

And it trains the skill the way an adventurer plausibly would:

    +200 xp  trading with an NPC you haven't traded with before (the barter
             screen opening on a new merchant/partner)
    +10 xp   acquiring a coin MINTING you haven't handled before (coins are
             keyed by their mint batch -- entity + year -- not per coin)

"New" is judged against rolling lists of the last 20 trade partners and the
last 20 coin mintings -- a ring, not a full history, so the check is O(20) and
ancient partners eventually count as new again. Both rings persist in the save
(dfhack.persistent).

    adv/appraiser            status: rating, xp, ring contents
    adv/appraiser stop       pause for this session
    adv/appraiser help       this text

DF's level curve is 500+100*rating xp per rating, so fresh-off-the-boat:
levels 1..5 cost 500,600,700,800,900 -- about 18 new trade partners (or a lot
of coin variety) to Adequate, then a new town's worth of partners per level.
]]

local overlay = require('plugins.overlay')

if running == nil then running = true end
xp_awarded = xp_awarded or 0
GLOBAL_KEY = 'appraiser'
RING_MAX = 20
local SCAN_MS = 1000
local COIN_XP, TRADE_XP = 10, 200
local VALUE_CH = string.char(15)   -- CP437 sun, DF's value glyph

-- ---- the rings ---------------------------------------------------------------
-- {npcs={id,...}, coins={key,...}} newest LAST; membership is a linear scan of
-- at most RING_MAX entries by design
local rings = nil

local function load_rings()
    if rings then return rings end
    rings = dfhack.persistent.getWorldData(GLOBAL_KEY, {npcs = {}, coins = {}})
    rings.npcs = rings.npcs or {}
    rings.coins = rings.coins or {}
    return rings
end

local function ring_has(list, key)
    for _, v in ipairs(list) do if v == key then return true end end
    return false
end

local function ring_push(list, key)
    list[#list + 1] = key
    while #list > RING_MAX do table.remove(list, 1) end
    dfhack.persistent.saveWorldData(GLOBAL_KEY, rings)
end

-- ---- the skill ----------------------------------------------------------------
local SKILL = df.job_skill.APPRAISAL

local function adv_soul()
    local u = dfhack.world.getAdventurer()
    return u and u.status.current_soul, u
end

local function skill_entry(soul, create)
    if not soul then return nil end
    for _, sk in ipairs(soul.skills) do
        if sk.id == SKILL then return sk end
    end
    if create then
        soul.skills:insert('#', {new = df.unit_skill, id = SKILL, rating = 0, experience = 0})
        return soul.skills[#soul.skills - 1]
    end
end

function rating()
    local soul = adv_soul()
    local sk = skill_entry(soul, false)
    return sk and sk.rating or 0
end

-- DF's curve: the next rating costs 500+100*rating xp
local function add_xp(n, why)
    local soul = adv_soul()
    local sk = skill_entry(soul, true)
    if not sk then return end
    sk.experience = sk.experience + n
    local leveled = false
    while sk.experience >= 500 + 100 * sk.rating do
        sk.experience = sk.experience - (500 + 100 * sk.rating)
        sk.rating = sk.rating + 1
        leveled = true
    end
    xp_awarded = xp_awarded + n
    local msg = ('%s (+%d Appraiser xp%s)'):format(why, n,
        leveled and (' -- now %s'):format(df.skill_rating[math.min(sk.rating, 19)] or sk.rating) or '')
    dfhack.gui.showAnnouncement(msg, COLOR_LIGHTCYAN, leveled)
end

-- ---- the label (exported: inventory-display-weight paints it) -----------------
-- value below the weight, at the precision a fort broker of this skill gets
function appraise_label(item)
    if not running then return nil end
    local ok, v = pcall(dfhack.items.getValue, item)
    if not ok or not v then return nil end
    local r = rating()
    if r == 0 then return '?' .. VALUE_CH end
    if r <= 5 then
        return ('~%d%s'):format(math.floor(v / 100 + 0.5) * 100, VALUE_CH)
    elseif r <= 10 then
        return ('~%d%s'):format(math.floor(v / 10 + 0.5) * 10, VALUE_CH)
    end
    return ('%d%s'):format(v, VALUE_CH)
end

-- ---- the trainers -------------------------------------------------------------
-- a stable identity for a trade partner: histfig when there is one, else unit id
local function partner_key(u)
    if u.hist_figure_id and u.hist_figure_id >= 0 then return 'hf' .. u.hist_figure_id end
    return 'u' .. u.id
end

local function check_barter()
    local b = df.global.game.main_interface.adventure.barter
    if not b.open then return end
    local m = b.merchant
    if not m then return end
    local key = partner_key(m)
    local r = load_rings()
    if ring_has(r.npcs, key) then return end
    ring_push(r.npcs, key)
    add_xp(TRADE_XP, ('You size up %s\'s goods.'):format(dfhack.units.getReadableName(m)))
end

-- every coin carried (containers included, one level -- pickups auto-stow),
-- keyed by MINT BATCH: same run of coinage = same key
local function check_coins()
    local u = dfhack.world.getAdventurer()
    if not u then return end
    local r = load_rings()
    local function coin_key(it)
        local ok, batch = pcall(function() return it.coin_batch end)
        if not ok or not batch then return nil end
        return 'b' .. batch
    end
    local function consider(it)
        if it:getType() ~= df.item_type.COIN then return end
        local key = coin_key(it)
        if not key or ring_has(r.coins, key) then return end
        ring_push(r.coins, key)
        add_xp(COIN_XP, 'You examine an unfamiliar coin.')
    end
    for _, iv in ipairs(u.inventory) do
        consider(iv.item)
        local ok, contained = pcall(dfhack.items.getContainedItems, iv.item)
        if ok and contained then
            for _, it in ipairs(contained) do consider(it) end
        end
    end
end

-- ---- overlay driver -----------------------------------------------------------
local next_scan = 0

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end
    local now = dfhack.getTickCount()
    if now < next_scan then return end
    next_scan = now + SCAN_MS
    pcall(check_barter)
    pcall(check_coins)
end

AppraiserWatch = defclass(AppraiserWatch, overlay.OverlayWidget)
AppraiserWatch.ATTRS{
    desc = 'Drives adv/appraiser: item values at broker precision, Appraiser training.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 1,
    frame = {w = 1, h = 1},
}

function AppraiserWatch:overlay_onupdate()
    pcall(step)
end

OVERLAY_WIDGETS = {watch = AppraiserWatch}

-- rings belong to the world they were built in
dfhack.onStateChange[_ENV] = function(sc)
    if sc == SC_WORLD_UNLOADED then rings = nil end
end

function stop()
    running = false
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/appraiser: paused for this session.')
elseif arg == 'help' then
    print(('adv/appraiser: values below weights at broker precision;'
        .. ' +%d xp per new trade partner, +%d per new coin minting.')
        :format(TRADE_XP, COIN_XP))
else
    running = true
    overlay.rescan()
    local r = load_rings()
    local soul = adv_soul()
    local sk = soul and skill_entry(soul, false)
    print(('adv/appraiser: %s | Appraiser %s (%d xp into the level) |'
        .. ' %d/%d partners, %d/%d coin mintings remembered | %d xp awarded')
        :format(running and 'WATCHING' or 'stopped',
            sk and (df.skill_rating[math.min(sk.rating, 19)] or sk.rating) or 'none',
            sk and sk.experience or 0,
            #r.npcs, RING_MAX, #r.coins, RING_MAX, xp_awarded))
end
