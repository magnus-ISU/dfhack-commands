-- Compose an engraving's image in a sentence, then engrave it wherever you designate.
--@module = true
--[[
fort/better-engraving

DF lets you choose what a planned engraving depicts, but only one tile at a time, through a
menu of nested lists reached by clicking each engraving after you designate it. This puts a
search box on the Engrave screen instead: describe the image once, in words, and every tile
you designate from then on carves it.

The box sits directly under "Engraving smoothed floors and walls" and takes focus as soon as
the Engrave tool is up -- always visible, so there is something to type into. The suggestions
and the image so far open up below it once you start. Type and it suggests; press Enter and
the line is added to the image.

    dragon                     adds a dragon
    Aubree                     adds that historical figure (all the Aubrees are listed)
    adamantine shield          adds the item
    dragon is burning shield   the dragon burns the shield
    dragon is triumphant pose  the dragon strikes a triumphant pose

A bare name adds an ELEMENT. A line with `is` or `are` in it adds a RELATION between elements
already in the image -- "<subject> is <verb> <object>" for the 48 verbs DF knows (burning,
raising, striking down, praying, massacring...), or "<subject> is <verb>" on its own. Subject
and object are matched against what you have already added, so they can be shortened:
"aubree is raising astod" is enough.

`<` and `>` are never typed: they are DF's z-level keys, and they also drop focus so the
plain movement keys reach the game again. Click the box to type again.

Leaving the Engrave tool cancels the image -- typing, elements, relations and all. Tiles you
already designated keep theirs: those are carvings already decided.

WHAT IT WRITES

An `art_image` is built from your elements and properties and registered in an image chunk of
this tool's own (`world.art_image_chunks.all`), and each tile you designate gets a
`location_detailst` naming it -- the same record DF's own menu writes, so DF carves it and
cleans the record up afterwards without knowing the difference.

Auto-discovered by `overlay rescan`; no enable needed.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local CHUNK_ID = 20000        -- ours: far above anything DF has generated in a fort
local MAX_SUGGEST = 24

-- ---------------------------------------------------------------------------
-- vocabulary
-- ---------------------------------------------------------------------------
--
-- Everything an image can be ABOUT, flattened into one searchable list. Each entry knows how
-- to build the art_image element it stands for, so the parser never has to care which kind of
-- thing it matched.
--
-- Built once and cached: a fort's history holds twelve thousand figures and translating every
-- name is not something to do per keystroke. It is dropped when the world is.

local vocab = nil

local function normalise(text)
    return (text:lower():gsub('[%-_,]', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
end

local function add(list, name, kind, make)
    if not name or name == '' then return end
    list[#list + 1] = {name = name, lname = normalise(name), kind = kind, make = make}
end

local function build_vocab()
    local v = {}
    local raws = df.global.world.raws

    -- Creatures, and their CASTES where a caste has a name of its own. This is not a detail:
    -- "three-headed ancient dragon" is not a creature, it is caste 4 of "ancient dragon", and
    -- 444 castes in this world are named that way -- every "X woman" to its "X man", every
    -- tiercel to its peregrine. Indexing only `creature.name` loses all of them, and DF's own
    -- image menu offers them, so the element carries the caste too.
    for i, cr in ipairs(raws.creatures.all) do
        local nm = cr.name[0]
        add(v, nm, 'creature', function()
            local e = df.art_image_element_creaturest:new()
            e.race, e.caste, e.count, e.histfig = i, 0, 1, -1
            return e
        end)
        for ci, ca in ipairs(cr.caste) do
            local cn = ca.caste_name[0]
            if cn and cn ~= '' and cn ~= nm then
                local race, caste = i, ci
                add(v, cn, 'caste', function()
                    local e = df.art_image_element_creaturest:new()
                    e.race, e.caste, e.count, e.histfig = race, caste, 1, -1
                    return e
                end)
            end
        end
    end

    -- BOTH name forms. `translateName(name, true)` is the English rendering -- "Gulffrightened
    -- the Willful Light" -- and `false` is the native one, "Astodshasar Udistam". DF shows the
    -- native form for artifacts, so indexing only the English one made them unsearchable by
    -- the name the player actually reads.
    local function both_names(name)
        local out = {}
        for _, english in ipairs{true, false} do
            local nm
            pcall(function() nm = dfhack.translation.translateName(name, english) end)
            if nm and nm ~= '' then
                local dup = false
                for _, seen in ipairs(out) do if seen == nm then dup = true end end
                if not dup then out[#out + 1] = nm end
            end
        end
        return out
    end

    -- historical figures: the named dead and living, as themselves
    for _, hf in ipairs(df.global.world.history.figures) do
        if hf.name and hf.name.has_name then
            local id, race = hf.id, hf.race
            for _, nm in ipairs(both_names(hf.name)) do
                add(v, nm, 'figure', function()
                    local e = df.art_image_element_creaturest:new()
                    e.race, e.caste, e.count, e.histfig = race, 0, 1, id
                    return e
                end)
            end
        end
    end

    for _, a in ipairs(df.global.world.artifacts.all) do
        local it = a.item
        if it then
            local item_id, item_type, subtype = it.id, it:getType(), it:getSubtype()
            local mt, mi = it:getMaterial(), it:getMaterialIndex()
            for _, nm in ipairs(both_names(a.name)) do
                add(v, nm, 'artifact', function()
                    local e = df.art_image_element_itemst:new()
                    e.item_type, e.item_subtype = item_type, subtype
                    e.mat_type, e.mat_index, e.count, e.item_id = mt, mi, 1, item_id
                    return e
                end)
            end
        end
    end

    -- item kinds, from the itemdefs the world has
    local DEFS = {
        {v = raws.itemdefs.weapons, t = df.item_type.WEAPON},
        {v = raws.itemdefs.armor,   t = df.item_type.ARMOR},
        {v = raws.itemdefs.helms,   t = df.item_type.HELM},
        {v = raws.itemdefs.shields, t = df.item_type.SHIELD},
        {v = raws.itemdefs.shoes,   t = df.item_type.SHOES},
        {v = raws.itemdefs.gloves,  t = df.item_type.GLOVES},
        {v = raws.itemdefs.pants,   t = df.item_type.PANTS},
        {v = raws.itemdefs.ammo,    t = df.item_type.AMMO},
        {v = raws.itemdefs.tools,   t = df.item_type.TOOL},
        {v = raws.itemdefs.instruments, t = df.item_type.INSTRUMENT},
        {v = raws.itemdefs.toys,    t = df.item_type.TOY},
        {v = raws.itemdefs.trapcomps, t = df.item_type.TRAPCOMP},
    }
    for _, d in ipairs(DEFS) do
        if d.v and d.t then
            for idx, def in ipairs(d.v) do
                local t, st = d.t, idx
                add(v, def.name, 'item', function()
                    local e = df.art_image_element_itemst:new()
                    e.item_type, e.item_subtype = t, st
                    e.mat_type, e.mat_index, e.count, e.item_id = -1, -1, 1, -1
                    return e
                end)
            end
        end
    end

    for i, pl in ipairs(raws.plants.all) do
        local tree = false
        pcall(function() tree = pl.flags.TREE end)
        local idx = i
        add(v, pl.name, tree and 'tree' or 'plant', function()
            local e = tree and df.art_image_element_treest:new() or df.art_image_element_plantst:new()
            e.plant_id, e.count = idx, 1
            return e
        end)
    end

    for i, sh in ipairs(raws.descriptors.shapes) do
        local idx = i
        add(v, sh.name, 'shape', function()
            local e = df.art_image_element_shapest:new()
            e.shape_id, e.shape_adj, e.count = idx, 0, 1
            return e
        end)
    end

    return v
end

-- Inorganic materials, so an item can be named the way you would say it: "adamantine shield",
-- "steel mace". Kept apart from the main vocabulary because a material is not a thing an image
-- can be ABOUT on its own -- it only ever qualifies an item.
local mats = nil

local function get_mats()
    if mats then return mats end
    mats = {}
    for i, m in ipairs(df.global.world.raws.inorganics.all) do
        local nm
        pcall(function() nm = m.material.state_name.Solid end)
        if not nm or nm == '' then nm = m.id:lower():gsub('_', ' ') end
        mats[#mats + 1] = {name = nm, lname = nm:lower(), index = i}
    end
    table.sort(mats, function(a, b) return #a.lname > #b.lname end)  -- longest first
    return mats
end

function get_vocab()
    if not vocab then vocab = build_vocab() end
    return vocab
end

dfhack.onStateChange.better_engraving_vocab = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_MAP_LOADED then vocab, mats, transitive = nil, nil, nil end
end

-- ---------------------------------------------------------------------------
-- verbs
-- ---------------------------------------------------------------------------
--
-- DF's verb names are CamelCase (StrikingDown, TriumphantPose); the words you would actually
-- type are those split apart and lowered. Matching takes the LONGEST verb that the text starts
-- with, so "striking down a dragon" reads as StrikingDown + "a dragon" and not Striking + ...

-- Which verbs take an object, learned from the images this world has already made rather than
-- from my own sense of English. A sample of the resident image chunks splits cleanly: eight
-- verbs only ever appear with an object (Admiring, Fighting, Raising, StrikingDown...), the
-- rest only ever without. A verb the sample has not seen gets no marking -- the parser accepts
-- it either way, and a guess would only mislead.
local transitive = nil

function takes_object(verb)
    if not transitive then
        transitive = {}
        for _, c in ipairs(df.global.world.art_image_chunks.all) do
            for i = 0, 499 do
                local img = c.images[i].art_image
                if img then
                    for _, pr in ipairs(img.properties) do
                        if df.art_image_property_transitive_verbst:is_instance(pr) then
                            transitive[pr.verb] = true
                        end
                    end
                end
            end
        end
    end
    return transitive[verb] or false
end

local VERBS = nil

local function get_verbs()
    if VERBS then return VERBS end
    VERBS = {}
    for i = 0, 63 do
        local n = df.art_image_property_verb[i]
        if n then
            local words = n:gsub('(%l)(%u)', '%1 %2'):lower()
            VERBS[#VERBS + 1] = {verb = i, name = n, text = words}
        end
    end
    table.sort(VERBS, function(a, b) return #a.text > #b.text end)   -- longest first
    return VERBS
end

-- ---------------------------------------------------------------------------
-- the image being composed
-- ---------------------------------------------------------------------------

image = image or nil          -- {elements = {{name, kind, make}}, props = {{subject, verb, object}}}

local function new_image()
    return {elements = {}, props = {}, rev = 0}
end

function get_image()
    if not image then image = new_image() end
    return image
end

-- an element already in the image, by loose name match -- "astod" finds "Astodshasar"
local function find_element(text)
    if not text or text == '' then return nil end
    -- normalised on BOTH sides. Element names are stored with hyphens flattened, so a raw
    -- lowercase compare failed on "three-headed ancient dragon" -- which is what turned a
    -- completed line straight into "no element here matches".
    text = normalise(text)
    local img = get_image()
    for i, el in ipairs(img.elements) do
        if el.lname:find(text, 1, true) then return i - 1, el end     -- 0-based for DF
    end
    for i, el in ipairs(img.elements) do
        if text:find(el.lname, 1, true) then return i - 1, el end
    end
end

-- ---------------------------------------------------------------------------
-- parsing a typed line
-- ---------------------------------------------------------------------------

-- Returns a plan describing what the line would do, WITHOUT doing it, so the same call can
-- drive the suggestion list and the Enter key.
function parse(line)
    line = (line or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if line == '' then return {kind = 'empty'} end

    -- "<subject> is <something>" and also a bare "<subject> is", which is how you ask what the
    -- subject could be doing. The trailing-word patterns are separate on purpose: a single
    -- `is%s*(.*)` would split "dragon island" into "dragon" + "land".
    local subject_text, rest
    for _, word in ipairs{'is', 'are'} do
        if not subject_text then
            subject_text, rest = line:match('^(.-)%s+' .. word .. '%s+(.+)$')
        end
        if not subject_text then
            subject_text = line:match('^(.-)%s+' .. word .. '%s*$')
            if subject_text then rest = '' end
        end
    end

    if subject_text then
        local si, sel = find_element(subject_text)
        if not si then
            return {kind = 'error', why = ('no element here matching "%s" -- add it first'):format(subject_text)}
        end
        local lower = normalise(rest)

        -- Nothing typed after "is" yet, or only part of a verb: offer the verbs. DF knows 48
        -- of them and no one remembers the list, so "dragon is" has to answer with what a
        -- dragon can be doing rather than with an error.
        local partial = {}
        for _, vb in ipairs(get_verbs()) do
            if lower == '' or vb.text:find(lower, 1, true) then partial[#partial + 1] = vb end
        end
        local exact = false
        for _, vb in ipairs(get_verbs()) do
            if lower:sub(1, #vb.text) == vb.text then exact = true end
        end
        if not exact and #partial > 0 then
            table.sort(partial, function(a, b)
                local ap, bp = a.text:sub(1, #lower) == lower, b.text:sub(1, #lower) == lower
                if ap ~= bp then return ap end
                return a.text < b.text
            end)
            return {kind = 'verb', subject = si, sname = sel.name,
                    subject_text = subject_text, verbs = partial}
        end

        for _, vb in ipairs(get_verbs()) do
            if lower:sub(1, #vb.text) == vb.text then
                local tail = lower:sub(#vb.text + 1):gsub('^%s+', ''):gsub('^an?%s+', '')
                if tail == '' then
                    return {kind = 'property', subject = si, sname = sel.name, verb = vb}
                end
                local oi, oel = find_element(tail)
                if not oi then
                    return {kind = 'error', why = ('no element here matching "%s"'):format(tail)}
                end
                return {kind = 'property', subject = si, sname = sel.name, verb = vb,
                        object = oi, oname = oel.name}
            end
        end
        return {kind = 'error', why = ('"%s" is not one of DF\'s verbs'):format(rest)}
    end

    -- A bare name: whatever it matches becomes an element.
    --
    -- Scored by WORDS, not by one substring. "ancient three headed dragon" describes a
    -- creature nobody has named exactly that, and demanding the whole phrase appear verbatim
    -- returns nothing at all -- which reads as "no such thing" when the truth is "not under
    -- that name". Each word you type that appears in a candidate counts for it, so the same
    -- query surfaces the ancient dragon, the cave dragon and the plain one, best first, and
    -- you pick. Hyphens are spaces on both sides, so "three-headed" and "three headed" agree.
    local hits = {}
    local q = normalise(line)
    local words = {}
    for w in q:gmatch('%S+') do words[#words + 1] = w end

    for _, entry in ipairs(get_vocab()) do
        local score = 0
        if entry.lname == q then
            score = 1000                                   -- an exact name always wins
        elseif entry.lname:find(q, 1, true) then
            score = 500 - math.min(#entry.lname, 100)       -- the whole phrase, shorter is better
        else
            for _, w in ipairs(words) do
                if #w > 1 and entry.lname:find(w, 1, true) then score = score + 10 end
            end
            if score > 0 then
                -- a name that is mostly what you typed beats one that merely contains a word
                score = score - math.min(#entry.lname, 60) / 10
            end
        end
        if score > 0 then
            hits[#hits + 1] = {entry = entry, score = score}
            if #hits > 600 then break end
        end
    end
    table.sort(hits, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if #a.entry.name ~= #b.entry.name then return #a.entry.name < #b.entry.name end
        return a.entry.name < b.entry.name
    end)
    for i, h in ipairs(hits) do hits[i] = h.entry end

    -- "<material> <item>": the material is stripped off the front and re-attached to the item
    -- element, so a shield can be an adamantine one rather than just a shield.
    --
    -- Matched on a shared PREFIX rather than exactly, because the name in your head is not
    -- always the name in the raws: "adamantium shield" should find adamantine, and it does not
    -- if the material has to be spelled DF's way. Six characters of agreement is enough to be
    -- sure and short enough to forgive the ending.
    local function head_is_material(text, mname)
        if text == mname then return true end
        local n = 0
        while n < #text and n < #mname and text:byte(n + 1) == mname:byte(n + 1) do n = n + 1 end
        return n >= 6
    end

    for _, mt in ipairs(get_mats()) do
        local head, rest = q:match('^(%S+)%s+(.+)$')
        if head and head_is_material(head, mt.lname) then
            local tail = rest
            for _, entry in ipairs(get_vocab()) do
                if entry.kind == 'item' and entry.lname:find(tail, 1, true) then
                    local base, mi, mname = entry, mt.index, mt.name
                    table.insert(hits, 1, {
                        name = ('%s %s'):format(mname, base.name),
                        lname = ('%s %s'):format(mt.lname, base.lname),
                        kind = 'item',
                        make = function()
                            local e = base.make()
                            e.mat_type, e.mat_index = 0, mi
                            return e
                        end,
                    })
                    break
                end
            end
            break
        end
    end
    return {kind = 'element', hits = hits}
end

-- ---------------------------------------------------------------------------
-- committing
-- ---------------------------------------------------------------------------

function add_element(entry)
    local img = get_image()
    img.elements[#img.elements + 1] = {name = entry.name, lname = entry.lname,
                                       kind = entry.kind, make = entry.make}
    img.rev = (img.rev or 0) + 1
end

function add_property(plan)
    local img = get_image()
    img.props[#img.props + 1] = {subject = plan.subject, verb = plan.verb.verb,
                                 object = plan.object, text = plan.text}
    img.rev = (img.rev or 0) + 1
end

-- a readable line for each property, for the preview
local function prop_text(img, p)
    local s = img.elements[p.subject + 1]
    local words = df.art_image_property_verb[p.verb]:gsub('(%l)(%u)', '%1 %2'):lower()
    if p.object then
        local o = img.elements[p.object + 1]
        return ('%s is %s %s'):format(s and s.name or '?', words, o and o.name or '?')
    end
    return ('%s is %s'):format(s and s.name or '?', words)
end

-- ---------------------------------------------------------------------------
-- registering it with DF
-- ---------------------------------------------------------------------------
--
-- A chunk of our own, appended to DF's list. DF pages its chunks in and out and does not mind
-- an extra one; an engraving carved from it comes out with our chunk id in `art_id`, exactly
-- as it does for DF's own images.

local function our_chunk()
    for _, c in ipairs(df.global.world.art_image_chunks.all) do
        if c.id == CHUNK_ID then return c end
    end
    local c = df.art_image_chunk:new()
    c.id = CHUNK_ID
    df.global.world.art_image_chunks.all:insert('#', c)
    return c
end

next_slot = next_slot or 0

-- Build the df.art_image and park it in our chunk. Returns chunk id and index.
function register(img)
    if #img.elements == 0 then return nil end
    local chunk = our_chunk()
    local slot = next_slot % 500
    next_slot = next_slot + 1

    local art = df.art_image:new()
    art.id, art.subid, art.quality = CHUNK_ID, slot, 0
    for _, el in ipairs(img.elements) do
        art.elements:insert('#', el.make())
    end
    for _, p in ipairs(img.props) do
        if p.object then
            local pr = df.art_image_property_transitive_verbst:new()
            pr.subject, pr.object, pr.verb = p.subject, p.object, p.verb
            art.properties:insert('#', pr)
        else
            local pr = df.art_image_property_intransitive_verbst:new()
            pr.subject, pr.verb = p.subject, p.verb
            art.properties:insert('#', pr)
        end
    end
    chunk.images[slot].art_image = art
    return CHUNK_ID, slot
end

-- ---------------------------------------------------------------------------
-- applying it to the tiles you designate
-- ---------------------------------------------------------------------------

-- {chunk, slot, rev} for the image currently being applied. There is no "arm" step: the
-- point of the tool is that you describe an image and then designate, so an image with parts
-- in it IS the image, and it is re-registered whenever you change it. Requiring a keypress
-- first meant a described image quietly applied to nothing.
armed = armed or nil

local function detail_at(pos)
    for _, e in ipairs(df.global.plotinfo.waypoints.location_detail) do
        if e.pos.x == pos.x and e.pos.y == pos.y and e.pos.z == pos.z then return e end
    end
end

local function claim_tile(x, y, z)
    local pos = xyz2pos(x, y, z)
    if detail_at(pos) then return false end
    local e = df.location_detailst:new()
    e.art_specifier = df.job_art_specifier_type.ArtImage
    e.art_spec_id1, e.art_spec_id2 = armed.chunk, armed.slot
    e.pos.x, e.pos.y, e.pos.z = x, y, z
    df.global.plotinfo.waypoints.location_detail:insert('#', e)
    return true
end

-- Tiles are claimed the moment they are created, from two signals, because a designation is
-- not one durable thing:
--
--   * the DESIGNATION itself -- `designation.smooth == 2` on a tile you have just marked. This
--     is the one that matters, and it is the one that has the image: it fires while the Engrave
--     tool is still up and the description is still on screen. It is also short-lived, because
--     the flag goes back to 0 the moment DF posts the job for that tile.
--   * the JOB -- eventful hands us DetailWall/DetailFloor as it is created, which catches the
--     tiles designated off-screen (a box drag that ran past the viewport edge) without polling
--     anything. It only claims while an image is armed, so a job posted days later, after you
--     have moved on, carves DF's own choice as it always did.
--
-- Only the blocks under the viewport are swept for designations: they are made where you are
-- looking, and sweeping a whole embark's blocks every tick would cost more than the feature is
-- worth -- DFHack lua runs on DF's own thread.

local function on_job_initiated(job)
    if not armed or not job then return end
    if job.job_type ~= df.job_type.DetailWall
        and job.job_type ~= df.job_type.DetailFloor then
        return
    end
    if job.pos.x < 0 then return end
    claim_tile(job.pos.x, job.pos.y, job.pos.z)
end

-- eventful stores the FUNCTION VALUE, so a reloaded script leaves it calling a dead copy of
-- itself: this is called at load and again on every tick, and re-registers when it is not the
-- current function that is installed.
function register_hooks()
    local ok, ev = pcall(require, 'plugins.eventful')
    if not ok then return end
    if ev.onJobInitiated.better_engraving == on_job_initiated then return end
    ev.onJobInitiated.better_engraving = on_job_initiated
    ev.onUnload.better_engraving = function()
        ev.onJobInitiated.better_engraving = nil
    end
end

function claim_designated()
    if not armed then return 0 end
    local z = df.global.window_z
    local x1, y1 = df.global.window_x, df.global.window_y
    local x2, y2 = x1 + (df.global.gps.dimx or 80), y1 + (df.global.gps.dimy or 60)
    local n = 0
    for bx = math.floor(x1 / 16) * 16, x2, 16 do
        for by = math.floor(y1 / 16) * 16, y2, 16 do
            local b = dfhack.maps.getTileBlock(xyz2pos(bx, by, z))
            if b then
                for lx = 0, 15 do
                    for ly = 0, 15 do
                        if b.designation[lx][ly].smooth == 2 then
                            if claim_tile(bx + lx, by + ly, z) then n = n + 1 end
                        end
                    end
                end
            end
        end
    end
    return n
end

-- Register the image if it has changed since last time, so newly designated tiles always get
-- the image as it stands now. Earlier tiles keep the version they were claimed with.
function arm()
    local img = get_image()
    if #img.elements == 0 then return false end
    if armed and armed.rev == img.rev then return true end
    local chunk, slot = register(img)
    if not chunk then return false end
    armed = {chunk = chunk, slot = slot, rev = img.rev}
    return true
end

function disarm()
    armed = nil
    image = new_image()
end

-- ---------------------------------------------------------------------------
-- the overlay
-- ---------------------------------------------------------------------------

-- The designation is called ENGRAVE, not SMOOTH_ENGRAVE. Naming it wrong compares against a
-- nil and the overlay simply never shows -- no error, nothing in the log, just absence.
-- `main_designation_selected` REMEMBERS the last designation tool you used -- it still reads
-- ENGRAVE while you are in the build menu or standing on the default screen, which put this
-- box on top of the build placer. The focus string is what actually says the tool is up.
local function engrave_active()
    return df.global.game.main_interface.main_designation_selected
            == df.main_designation_type.ENGRAVE
        and dfhack.gui.matchFocusString('dwarfmode/Designate')
end

BetterEngraving = defclass(BetterEngraving, overlay.OverlayWidget)
BetterEngraving.ATTRS{
    desc = 'Engrave screen: describe an image in words and carve it wherever you designate.',
    default_pos = {x = 9, y = 12},         -- just under "Engraving smoothed floors and walls"
    default_enabled = true,
    -- Broad 'dwarfmode', not 'dwarfmode/Designate/ENGRAVE'. A narrow match never instantiates
    -- on the designation screens -- fort/dig-building found the same thing and says so in its
    -- own comment. Visibility is gated on engrave_active() below, so it still only shows while
    -- the Engrave tool is up.
    viewscreens = 'dwarfmode',
    frame = {w = 60, h = 20},
    overlay_onupdate_max_freq_seconds = 0,
    version = 2,   -- moved: resets the saved position
}

function BetterEngraving:init()
    self.search = ''
    self.unfocused = false
    self.status = ''
    self:addviews{
        widgets.Panel{
            view_id = 'panel',
            frame = {t = 0, l = 0, r = 0, b = 0},
            frame_style = gui.FRAME_THIN,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.Label{view_id = 'query', frame = {t = 0, l = 0}, text = ''},
                widgets.List{view_id = 'hits', frame = {t = 2, l = 0, r = 0, b = 7},
                             on_submit = function(_, ch) self:take(ch) end},
                -- the image so far: one line per part, scrollable, at the bottom
                widgets.List{view_id = 'preview', frame = {b = 2, l = 0, r = 0, h = 5},
                             text_pen = COLOR_GREY},
                widgets.Label{view_id = 'status', frame = {b = 0, l = 0}, text = '',
                              text_pen = COLOR_GREY},
            },
        },
    }
end

-- One row per part of the image: every element on its own line, then every relation. Long
-- images scroll rather than spilling out of the panel.
function BetterEngraving:preview_rows()
    local img = get_image()
    if #img.elements == 0 then return {{text = 'nothing yet'}} end
    local rows = {}
    for i, el in ipairs(img.elements) do
        rows[#rows + 1] = {text = ('%d. %-30s %s'):format(i, el.name, el.kind)}
    end
    for _, p in ipairs(img.props) do
        rows[#rows + 1] = {text = {{text = '   ' .. prop_text(img, p), pen = COLOR_YELLOW}}}
    end
    return rows
end

function BetterEngraving:refresh()
    local plan = parse(self.search)
    self.subviews.query:setText({{text = 'image: ' .. self.search .. '_',
                                  pen = self.unfocused and COLOR_GREY or COLOR_WHITE}})
    local choices = {}
    if plan.kind == 'element' then
        for i, e in ipairs(plan.hits) do
            if i > MAX_SUGGEST then break end
            choices[#choices + 1] = {text = ('%-34s %s'):format(e.name, e.kind), entry = e}
        end
    elseif plan.kind == 'verb' then
        for _, vb in ipairs(plan.verbs) do
            -- a verb that takes an object says so, with a placeholder for it
            local needs = takes_object(vb.verb)
            choices[#choices + 1] = {
                text = ('%s is %s%s'):format(plan.sname, vb.text, needs and ' X' or ''),
                -- completes with the subject AS YOU TYPED IT: substituting the element's full
                -- name re-parses a longer string that may match a different element
                complete = ('%s is %s '):format(plan.subject_text, vb.text)}
        end
    elseif plan.kind == 'property' then
        local o = plan.oname and (' ' .. plan.oname) or ''
        choices[#choices + 1] = {text = ('%s is %s%s'):format(plan.sname, plan.verb.text, o),
                                 plan = plan}
    elseif plan.kind == 'error' then
        choices[#choices + 1] = {text = {{text = plan.why, pen = COLOR_LIGHTRED}}}
    end
    self.subviews.hits:setChoices(choices)
    self.subviews.preview:setChoices(self:preview_rows(), self.subviews.preview:getSelected())
    self.subviews.status:setText(self.status ~= '' and self.status
        or (armed and 'Live: tiles you designate now carve this image. Ctrl-X clears.'
                  or 'Enter adds a line. Ctrl-X clears.'))
    return plan
end

-- Take one row -- from a click, from Enter, from anywhere. `take` is the single path in, so
-- the mouse and the keyboard cannot drift apart.
function BetterEngraving:take(choice)
    if not choice then return end
    -- a verb row COMPLETES the line rather than committing it: you may still want an object,
    -- and pressing Enter on the completed line commits it on its own if you do not
    if choice.complete then
        self.search = choice.complete
        self.status = 'now name what it is done to, or press Enter'
        self:refresh()
        return
    end
    if choice.entry then
        add_element(choice.entry)
        self.status = ('added %s'):format(choice.entry.name)
    elseif choice.plan then
        add_property(choice.plan)
        self.status = 'added the relation'
    else
        return
    end
    self.search = ''
    self:refresh()
end

function BetterEngraving:commit()
    local _, choice = self.subviews.hits:getSelected()
    if not choice then self.status = 'nothing matches that'; return end
    self:take(choice)
end

function BetterEngraving:onInput(keys)
    -- NOT gated on self.visible: the box is hidden until you type, so the first keystroke has
    -- to be taken while it is still hidden or it could never appear at all.
    if not engrave_active() then return false end
    if keys._STRING == 60 or keys._STRING == 62 then      -- '<' and '>' are DF's z keys
        self.unfocused = true
        return false
    end
    if keys.CUSTOM_CTRL_A then
        self.status = arm() and 'armed -- designate away' or 'add something to the image first'
        self:refresh()
        return true
    end
    if keys.CUSTOM_CTRL_X then
        disarm()
        self.status = 'cleared'
        self:refresh()
        return true
    end
    -- The LIST sees input first, so its own scrolling works -- arrows, page keys, the mouse
    -- wheel, the scrollbar and clicking a row. Handling only up/down by hand meant everything
    -- else it knows how to do was swallowed by the text box below.
    local list = self.subviews.hits
    -- The wheel is handled explicitly and always consumed while the panel is up: passing it
    -- through let DF change z-level under the list, which is not scrolling the list.
    if keys._MOUSE_WHEEL_UP or keys._MOUSE_WHEEL_DOWN then
        local step = keys._MOUSE_WHEEL_UP and -1 or 1
        local target = (self.subviews.preview.visible and self.subviews.preview:getMousePos())
            and self.subviews.preview or list
        if target.visible then target:setSelected(target:getSelected() + step * 3) end
        return true
    end
    if list.visible and list:onInput(keys) then return true end
    if keys.SEC_CHANGETAB then list:setSelected(list:getSelected() - 1); return true end
    if keys.CHANGETAB then list:setSelected(list:getSelected() + 1); return true end
    if self.subviews.preview.visible and (keys._MOUSE_L or keys._MOUSE_WHEEL_UP or keys._MOUSE_WHEEL_DOWN) then
        if self.subviews.preview:onInput(keys) then return true end
    end
    if keys.SELECT then self:commit(); return true end
    if self.unfocused then return false end
    if keys._STRING == 0 then
        self.search = self.search:sub(1, -2); self:refresh(); return true
    elseif keys._STRING and keys._STRING >= 32 then
        self.search = self.search .. string.char(keys._STRING); self:refresh(); return true
    end
    return false
end

function BetterEngraving:overlay_onupdate()
    -- Leaving the Engrave tool CANCELS the image: the typing, the elements, the relations and
    -- the armed state all go. An image is a description of one carving, not a setting, and
    -- coming back to the tool later and silently still holding a half-built dragon would be
    -- worse than starting again. Tiles already claimed keep their own record -- those are
    -- decisions already made, and DF owns them from that point on.
    register_hooks()   -- re-checked every tick: eventful holds the function VALUE, so a
                       -- reloaded script leaves it calling a dead copy of itself
    if not engrave_active() then
        if self.search ~= '' or #get_image().elements > 0 or armed then
            self.search = ''
            disarm()
        end
        self.unfocused = false
        self.status = ''
        self.visible = false
        return
    end
    -- The BOX is always there while the Engrave tool is up -- you cannot type into something
    -- you cannot see, and a search box that only appears once you have typed is a box nobody
    -- finds. What comes and goes is everything BELOW it: the suggestions and the image so far
    -- appear once there is something to put in them, and the window shrinks back to the one
    -- line when there is not.
    self.visible = true
    local img = get_image()
    local active = self.search ~= '' or #img.elements > 0
    self.subviews.hits.visible = active
    self.subviews.preview.visible = active
    self.subviews.status.visible = active

    -- one line when idle; as tall as the screen allows once it has something to show, the way
    -- dig-building sizes its picker
    local _, sh = dfhack.screen.getWindowSize()
    local h = active and math.max(12, sh - (self.frame.t or 12) - 6) or 3
    -- Bottom-aligned and only as tall as it needs: an image of two parts should not reserve
    -- half the panel. Half is the ceiling, not the size.
    local rows = #get_image().elements + #get_image().props
    local ph = math.max(1, math.min(rows > 0 and rows or 1, math.floor(h / 2)))
    local changed = false
    if self.frame.h ~= h then self.frame.h = h; changed = true end
    if self.subviews.preview.frame.h ~= ph then
        self.subviews.preview.frame.h = ph
        self.subviews.hits.frame.b = ph + 3
        changed = true
    end
    if changed then self:updateLayout() end
    self:refresh()
    -- live as soon as it has parts: describe, then designate
    if #img.elements > 0 then
        arm()
        claim_designated()
    end
end

-- Registered here, at load, and not only from the overlay's tick: an overlay that has hidden
-- itself does not get updated, so the tick alone could never put the hook back.
register_hooks()

OVERLAY_WIDGETS = {compose = BetterEngraving}

if dfhack_flags and dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('better-engraving: overlay registered.')
print('  Open the Engrave tool and type a description; Ctrl-A arms it, then designate.')
