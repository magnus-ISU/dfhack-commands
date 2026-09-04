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

-- Does this key event carry something that would act on the map behind the box?
--
-- `except` is for a tool that DRIVES DF with those same keys. `gui.simulateInput`
-- goes through the overlay feed before it reaches DF, so a widget that swallows
-- `D_BUILDING` swallows its own keystroke and never opens the build menu -- which
-- is precisely how fort/dig-building stopped working at all. A tool that sends a
-- key must name it here.
-- What the last swallow ate, for when a tool stops responding and the question is
-- whether this is why.
last_swallowed = last_swallowed or nil

function swallows(keys, except)
    if not SWALLOW then build() end
    -- NEVER a mouse event. This guard exists for TYPED LETTERS reaching the map's
    -- hotkeys, and a mouse button is not a typed letter -- but DF hangs bindings
    -- off the mouse too (right-click carries the designation keys while a
    -- designation tool is up), so a name-only test ate right-clicks and left the
    -- player unable to back out of the tool at all.
    for k in pairs(keys) do
        if type(k) == 'string' and k:find('^_MOUSE') then return false end
    end
    for k in pairs(keys) do
        if SWALLOW[k] and not (except and except[k]) then
            last_swallowed = k
            return true
        end
    end
    return false
end
