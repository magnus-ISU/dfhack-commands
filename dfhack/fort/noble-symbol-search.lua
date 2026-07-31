-- Adds a search bar to the noble symbol-assignment list (Info > Nobles > Symbols), where you pick
-- an item to serve as a noble position's symbol -- a list that can run to tens of thousands of rows.
--@module = true
--[[
noble-symbol-search

On the noble Symbols screen (dwarfmode/Info/ADMINISTRATORS/Symbols), the game offers every eligible
fort item as a candidate symbol -- often 10,000+ entries. This overlay adds a Search field (Alt-S)
that filters that list live by the item's description, like DFHack's built-in list searches.

Unlike a plain single-list search, the symbol candidates are stored as four PARALLEL arrays
(cand_symbol + cand_symbol_new_ind / _is_symbol_of_ind / _value) that the game indexes by row, so we
filter all four together to keep them in sync, and restore the full arrays when you leave the screen.
Built on DFHack's sort/sortoverlay base. Auto-discovered by `overlay rescan` (magnus-scripts runs it).
]]

local sortoverlay = require('plugins.sort.sortoverlay')
local widgets = require('gui.widgets')
local utils = require('utils')

local function administrators()
    return df.global.game.main_interface.info.administrators
end

-- the four row-parallel arrays; erasing a row means erasing that index from every one of them
local SYM_PARALLEL = {'cand_symbol', 'cand_symbol_new_ind', 'cand_symbol_is_symbol_of_ind', 'cand_symbol_value'}

local function copy_to_lua_table(vec)
    local t = {}
    for k, v in ipairs(vec) do t[k + 1] = v end
    return t
end

-- searchable text for a candidate: the item's readable description ("«☼steel crown☼»")
local function item_key(it)
    if not it then return '' end
    local ok, d = pcall(dfhack.items.getReadableDescription, it)
    return ok and d or ''
end

local function symbol_search(data, text, incremental)
    local adm = administrators()
    if not data.saved then
        data.saved = {}
        for _, name in ipairs(SYM_PARALLEL) do data.saved[name] = copy_to_lua_table(adm[name]) end
        data.saved_size = #adm.cand_symbol
    elseif not incremental then
        for _, name in ipairs(SYM_PARALLEL) do
            adm[name]:assign(data.saved[name]); adm[name]:resize(data.saved_size)
        end
    end
    if text ~= '' then
        local tokens = text:split()
        for idx = #adm.cand_symbol - 1, 0, -1 do
            if not utils.search_text(item_key(adm.cand_symbol[idx]), tokens) then
                for _, name in ipairs(SYM_PARALLEL) do adm[name]:erase(idx) end
            end
        end
    end
end

-- restore the full arrays when the player leaves the symbol screen (so a later visit -- or any
-- other code reading these vectors -- sees the whole candidate list, not our filtered subset)
local function symbol_cleanup(data)
    if data.saved then
        local adm = administrators()
        for _, name in ipairs(SYM_PARALLEL) do
            pcall(function() adm[name]:assign(data.saved[name]); adm[name]:resize(data.saved_size) end)
        end
    end
    data.saved = nil
    data.saved_size = nil
end

NobleSymbolSearchOverlay = defclass(NobleSymbolSearchOverlay, sortoverlay.SortOverlay)
NobleSymbolSearchOverlay.ATTRS{
    desc = 'Adds a search bar to the noble symbol-assignment list.',
    default_pos = {x = 65, y = 12},
    viewscreens = 'dwarfmode/Info/ADMINISTRATORS',
    frame = {w = 34, h = 1},
}

function NobleSymbolSearchOverlay:init()
    local panel = widgets.Panel{visible = self:callback('get_key')}
    panel:addviews{
        widgets.BannerPanel{
            frame = {l = 0, t = 0, r = 0, h = 1},
            subviews = {
                widgets.EditField{
                    view_id = 'search',
                    frame = {l = 1, t = 0, r = 1},
                    label_text = 'Search: ',
                    key = 'CUSTOM_ALT_S',
                    on_change = function(text) self:do_search(text) end,
                },
            },
        },
    }
    self:addviews{panel}
    self:register_handler('SYMBOL',
        function() return administrators().cand_symbol end,
        function(_, data, text, incremental) symbol_search(data, text, incremental) end,
        symbol_cleanup)
end

-- active only while the symbol picker is open (assigning a symbol to a noble position)
function NobleSymbolSearchOverlay:get_key()
    if administrators().assigning_symbol then return 'SYMBOL' end
end

OVERLAY_WIDGETS = {search = NobleSymbolSearchOverlay}

if dfhack_flags and dfhack_flags.module then return end

print('noble-symbol-search: overlay registered.')
print('On the noble Symbols screen, press Alt-S to search the candidate items by description.')
