-- Title screen: stamp old-game-version saves' "Files" buttons with "OLD!!".
--@module = true
--[[
fort/old-saves

DF's save headers carry no game version, so the title screen lists saves an
older game wrote as equals and you only find out after loading. The version
IS in the save though: the FIRST INT32 of world.sav (world.dat for a freshly
generated, never-played world) is the save_version of the exe that last wrote
it -- verified across 28 real folders spanning a game update, a clean split
with zero exceptions. This overlay reads it (mtime-cached) for every save the
title screen lists, and every save written by an OLDER exe than the running
one gets its "Files" button repainted as a red "OLD!!" ("Files" and "OLD!!"
are the same 5 cells). Same-version and newer-than-us saves are left alone.
An empty staging folder (save/current during play) has no world file and is
skipped.

Which button belongs to which save is decided by TEXT, not list order: DF can
sort the lists (cur_sort), so rendered rows are matched instead. Every "Files"
on the text grid is correlated with the save whose FOLDER name appears in the
5 screen lines around it (folder names are unique); failing that, fort/world
names decide, and a row that stays ambiguous is stamped only if every save it
could be is old-version -- it never stamps a current save. Grid scans run
only on scroll/mode/list change or a 2s fallback, never per frame, and are
skipped while a delete-confirmation dialog is up.

Run the command bare at the title screen to print every save and its
version. Overlay `fort/old-saves.stamp`, enabled by default.
]]

local overlay = require('plugins.overlay')

local function find_title_vs()
    local vs = dfhack.gui.getCurViewscreen(true)
    while vs do
        if df.viewscreen_titlest:is_instance(vs) then return vs end
        vs = vs.parent
    end
end

-- ---- per-save game version --------------------------------------------------

-- save folder -> {mtime, version}; world.sav is rewritten on save, so mtime
-- catches a re-saved world without re-reading the header every update
local cache = {}

local function save_version(dir)
    -- played saves have world.sav; a freshly generated world only world.dat
    local sav = dir .. '/world.sav'
    -- on this build mtime returns a raw (negative) file_time number; it is
    -- only a change token here, so any number is fine and only nil = missing
    local mtime = dfhack.filesystem.mtime(sav)
    if not mtime then
        sav = dir .. '/world.dat'
        mtime = dfhack.filesystem.mtime(sav)
    end
    if not mtime then return nil end
    local c = cache[dir]
    if c and c.mtime == mtime then return c.version end
    local f = io.open(sav, 'rb')
    if not f then return nil end
    local bytes = f:read(4)
    f:close()
    if not bytes or #bytes < 4 then return nil end
    local version = ('<i4'):unpack(bytes)
    cache[dir] = {mtime = mtime, version = version}
    return version
end

-- every save the title screen knows, deduped by folder:
-- {folder, keys, version, old}. old = written by an older exe than ours.
local function list_saves(vs)
    local seen, out = {}, {}
    local function visit(header)
        local dir = tostring(header.full_path)
        if seen[dir] then return end
        seen[dir] = true
        local entry = {folder = '', keys = {}, version = save_version(dir)}
        entry.old = entry.version ~= nil and entry.version < df.global.version
        local function add_key(s)
            if type(s) == 'string' and #s >= 2 then
                entry.keys[#entry.keys + 1] = s
            end
        end
        pcall(function() entry.folder = header.filename_noext end)
        for _, f in ipairs{'fort_name', 'world_name', 'display_name', 'name'} do
            local ok, v = pcall(function() return header[f] end)
            if ok then add_key(v) end
        end
        add_key(entry.folder)
        out[#out + 1] = entry
    end
    for _, vec in pairs{vs.savegame_header, vs.savegame_header_world,
                        vs.savegame_header_game, vs.region_choice} do
        for _, header in ipairs(vec) do visit(header) end
    end
    return out
end

-- ---- "Files" button stamping ------------------------------------------------

local FILES_TEXT = 'Files'
local OLD_TEXT = 'OLD!!'          -- same width as "Files": a clean cell-for-cell swap
local OLD_PEN = {fg = COLOR_LIGHTRED, bg = COLOR_BLACK}
local FILES_RESCAN_MS = 2000      -- fallback grid-scan cadence; scroll/mode changes force one

-- read one full text row of the rendered grid
local function grid_line(y)
    local gps = df.global.gps
    if y < 0 or y >= gps.dimy then return '' end
    local row = {}
    for x = 0, gps.dimx - 1 do
        local t = dfhack.screen.readTile(x, y)
        local ch = t and t.ch or 0
        row[x + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(row)
end

-- does `key` appear in this row block? Screen rows may truncate long names,
-- so a long key also matches by its first 12 characters.
local function key_in(block, key)
    if block:find(key, 1, true) then return true end
    return #key > 12 and block:find(key:sub(1, 12), 1, true) ~= nil
end

-- every "Files" on the grid with its verdict {x, y, old}. Folder names are
-- unique, so a folder match settles the row outright; otherwise any-name
-- matches decide, and an ambiguous row is stamped only when every save it
-- could be is old -- never a newest one.
local function scan_files_buttons(saves)
    local hits = {}
    local gps = df.global.gps
    local lines = {}
    local function line(y)
        if not lines[y] then lines[y] = grid_line(y) end
        return lines[y]
    end
    for y = 0, gps.dimy - 1 do
        local l = line(y)
        local init = 1
        while true do
            local i = l:find(FILES_TEXT, init, true)
            if not i then break end
            init = i + #FILES_TEXT
            -- the save's name is printed within a couple of rows of its button
            local block = table.concat({line(y - 2), line(y - 1), l,
                                        line(y + 1), line(y + 2)}, '\n')
            local folder_hit, matched_old, matched_new = nil, false, false
            for _, s in ipairs(saves) do
                if #s.folder >= 2 and key_in(block, s.folder) then
                    -- longest folder match wins ("region1" inside "region12")
                    if not folder_hit or #s.folder > #folder_hit.folder then
                        folder_hit = s
                    end
                end
                for _, key in ipairs(s.keys) do
                    if key_in(block, key) then
                        if s.old then matched_old = true else matched_new = true end
                        break
                    end
                end
            end
            local verdict
            if folder_hit then
                verdict = folder_hit.old
            else
                verdict = matched_old and not matched_new
            end
            hits[#hits + 1] = {x = i - 1, y = y, old = verdict}
        end
    end
    return hits
end

-- a delete-confirmation dialog covers the lists; don't stamp through it
local function delete_dialog_up(vs)
    for _, f in ipairs{'deleting_region', 'deleting_region_header',
                       'deleting_savegame_game', 'deleting_savegame_header',
                       'deleting_savegame_world'} do
        local ok, v = pcall(function() return vs[f] end)
        if ok and v and v ~= false then return true end
    end
    return false
end

-- cheap change token: any scroll, mode or list-size change forces a rescan
local function files_signature(vs, nsaves)
    local sig = tostring(vs.mode) .. ':' .. nsaves
    for _, f in ipairs{'scroll_position_game_choice', 'scroll_position_world_choice',
                       'scroll_position_region_choice'} do
        local ok, v = pcall(function() return vs[f] end)
        sig = sig .. ':' .. (ok and tostring(v) or '?')
    end
    return sig
end

-- ---- overlay ----------------------------------------------------------------

local LIST_MODES = {
    [df.title_mode_type.CONTINUE_INACTIVE] = true,
    [df.title_mode_type.CONTINUE_ACTIVE_WORLD] = true,
    [df.title_mode_type.CONTINUE_ACTIVE] = true,
}

OldSaves = defclass(OldSaves, overlay.OverlayWidget)
OldSaves.ATTRS{
    desc = 'Stamps "OLD!!" on the Files button of saves written by an older game version.',
    default_pos = {x = 2, y = 2},
    default_enabled = true,
    viewscreens = 'title',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 2,
}

function OldSaves:init()
    self.saves = {}
    self.files_hits = {}
    self.files_sig = nil
    self.files_next = 0
end

function OldSaves:overlay_onupdate()
    pcall(function()
        local vs = find_title_vs()
        self.saves = vs and list_saves(vs) or {}
    end)
end

function OldSaves:onRenderBody(dc)
    pcall(function()
        local vs = find_title_vs()
        if not vs or not LIST_MODES[vs.mode] then return end
        if #self.saves == 0 or delete_dialog_up(vs) then return end
        local now = dfhack.getTickCount()
        local sig = files_signature(vs, #self.saves)
        if sig ~= self.files_sig or now >= self.files_next then
            self.files_sig = sig
            self.files_next = now + FILES_RESCAN_MS
            self.files_hits = scan_files_buttons(self.saves)
        end
        for _, hit in ipairs(self.files_hits) do
            if hit.old then
                dfhack.screen.paintString(OLD_PEN, hit.x, hit.y, OLD_TEXT)
            end
        end
    end)
end

OVERLAY_WIDGETS = {stamp = OldSaves}

if dfhack_flags and dfhack_flags.module then return end

overlay.rescan()
local vs = find_title_vs()
if not vs then
    print('fort/old-saves: overlay active on the title screen '
        .. '(run this command there for a listing of saves grouped by world).')
    return
end
local saves = list_saves(vs)
table.sort(saves, function(a, b) return a.folder < b.folder end)
print(('%-32s %s'):format('save', 'version (yours: v' .. df.global.version .. ')'))
for _, s in ipairs(saves) do
    local mark = ''
    if not s.version then
        mark = '(no world file)'
    elseif s.old then
        mark = 'OLD'
    elseif s.version > df.global.version then
        mark = '(NEWER than this game!)'
    end
    print(('%-32s %-6s %s'):format(s.folder,
        s.version and ('v' .. s.version) or '-', mark))
end
