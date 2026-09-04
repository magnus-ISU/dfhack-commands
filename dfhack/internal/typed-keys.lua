-- Keys a focused text box must not let through to the map.
--@module = true
--[[
internal/typed-keys

An overlay with a search box lives on top of DF's own screen, and DF's own screen is covered in
single-letter hotkeys: `t` carves tracks, `b` opens building, `u` the unit list. Typing
"adamantine shield" into a box means pressing ten of them.

Normally that is harmless -- a printable keypress arrives with `_STRING` set as well as its
binding, the box consumes the whole event, and DF never sees it. But not always: under a heavy
frame the SAME keypress can arrive carrying only its binding, with no `_STRING` on it at all,
and a handler that keys off `_STRING` passes it straight to DF. Typing an item's name then
quietly switches the designation tool out from under you -- which is exactly what "adamantine
shield" did, on the `t`.

So a focused box swallows these outright, whether or not the event looks like typing:
designation tools, building hotkeys and the screen switchers. Everything else still passes --
map panning, the mouse, `<` and `>`, and the pause and step keys, which stay DF's even mid-word.
]]

local SWALLOW = nil
local KEEP = {D_PAUSE = true, D_ONESTEP = true}

local function build()
    SWALLOW = {}
    for i = 0, 2000 do
        local name = df.interface_key[i]
        if name and not KEEP[name]
            and (name:find('^DESIGNATE_') or name:find('^D_DESIGNATE')
                 or name:find('^HOTKEY_BUILDING') or name:find('^BUILDINGKEY')
                 or name:find('^D_%u'))
        then
            SWALLOW[name] = true
        end
    end
end

-- does this key event carry something that would act on the map behind the box?
function swallows(keys)
    if not SWALLOW then build() end
    for k in pairs(keys) do
        if SWALLOW[k] then return true end
    end
    return false
end
