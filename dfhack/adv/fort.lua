-- adv/fort: overlay-based rework of gui/advfort for adventure mode
--@module = true

--[====[

adv/fort
========
Do fort jobs in adventure mode. Self-contained successor to ``adv/advfort``
(whose job logic -- choosers, predicates, item matching, workshop handling --
is carried inside this file; advfort itself is retired).

* **Overlay, not a modal screen.** The menu is an overlay on the live adventure
  screen: nothing is intercepted except what you click on it, so right-clicks,
  the toolbar and every native interaction work directly -- the window never
  dismisses/reopens itself. Right-clicking the menu collapses it to a one-glyph
  icon on the left edge; clicking that reopens it.
* **One menu + at most ONE auxiliary panel.** The job menu sits on the left
  border; any auxiliary UI (build picker, workshop job menu, job materials)
  opens as a single panel directly to its right, replacing whatever panel was
  open. Panels never overlap. The build picker has its MATERIALS section built
  into its bottom; picking a specific item for a slot opens a MODAL picker that
  takes complete focus until something is chosen or it is canceled (Esc or
  right-click).
* **Job engine.** One state machine owns every job the tool creates: it pumps
  work automatically (jobs can no longer start and silently stall), watches
  your position (walking away cancels the job instead of orphaning it),
  auto-resumes interrupted-but-valid jobs, cleans up completed husks, and
  sweeps stuck leftovers when the tool opens.
* **Click routing.** A mouse job click must target your own z-level -- clicking
  the exposed floor one level down through a channel WALKS there instead of
  channeling it (other z-levels via the look cursor). Standing inside a planned
  building's footprint is fine: the job anchors at your own tile and the engine
  steps you off the finished building if it would seal you in. Use Workshop
  never captures a click (or opens its menu) unless you stand within 1 tile of
  the building's CENTER -- from farther away its jobs silently fail, so the
  click walks you there instead. Jobs also trigger on CAREFUL MOVE.
* **Keyboard.** Panels are searchable (type to filter, Enter picks the best
  match, Esc clears then closes) like fort/dig-building. On the map, Enter
  does the selected action at the look cursor -- and opens look mode first if
  it is not up, so Enter/Enter-and-pick chooses where to act. Shift+R/T cycle
  jobs; Ctrl+F minimizes/maximizes the window.
  Every other key passes to the game untouched.

Usage::

    adv/fort [flags]        show the overlay (also: adv/fort show)
    adv/fort hide           hide it (jobs in progress keep running)
    adv/fort toggle         toggle
    adv/fort [flags] JOB    also select JOB (an entry name, e.g. Dig)

Flags (advfort's): ``-c``/``--cheat`` relax item requirements, ``-q``/``--quick``
quick item select, ``-u``/``--unsafe`` ignore pain etc while waiting,
``-s``/``--safe`` only work on sites, ``-i``/``--inventory`` check inventory for
job items, ``-a``/``--nodfassign`` manual item assignment, ``-e [NAME]``
recipe entity override (default: your civ + the site owner's).

.. warning::
    digging/construction changes only persist at player forts, caves, camps,
    lairs/monster shrines and important locations (buildings save everywhere);
    the menu shows a centered "won't persist" on its bottom edge anywhere else.

]====]

local gui = require('gui')
local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')
local dialog = require('gui.dialogs')
local buildings = require('dfhack.buildings')
local workshopJobs = require('dfhack.workshops')
local utils = require('utils')
local gscript = require('gui.script')

local advfort_items = reqscript('internal/advfort/advfort_items')

local tile_attrs = df.tiletype.attrs

-- building filters
local build_filter={
    forbid_all=false, --this forbits all except the "allow"
    allow={"MetalSmithsForge"}, --ignored if forbit_all=false
    forbid={} --ignored if forbit_all==true
}
build_filter.HUMANish={
    forbid_all=true,
    allow={"Masons"},
    forbid={}
}

--economic stone fix: just disable all of them
--[[ FIXME: maybe let player select which to disable?]]
for k,v in ipairs(df.global.plotinfo.economic_stone) do df.global.plotinfo.economic_stone[k]=0 end

-- ---- persistent state + small helpers --------------------------------------
if shown == nil then shown = false end
if collapsed == nil then collapsed = false end
MODE_IDX = MODE_IDX or 0
WIDGET = WIDGET or nil


local MENU_W = 26
local AUX_L = MENU_W + 1
local COL_W = 32
local ITEM_COL_W = 40

-- ---- small helpers ----------------------------------------------------------

local function ctx_ok()
    return dfhack.world.isAdventureMode() and dfhack.world.getAdventurer() ~= nil
end

local function feed(key)
    gui.simulateInput(dfhack.gui.getCurViewscreen(true), key)
end

local function draw_box(dc, l, t, w, h, title, title_pen)
    local BG = {fg=COLOR_GREY, bg=COLOR_BLACK}
    for r = 0, h-1 do dc:seek(l, t+r):pen(BG):string(string.rep(' ', w)) end
    local hbar = string.rep(string.char(196), w-2)
    dc:seek(l, t):pen(BG):string(string.char(218)..hbar..string.char(191))
    dc:seek(l, t+h-1):pen(BG):string(string.char(192)..hbar..string.char(217))
    for r = 1, h-2 do
        dc:seek(l, t+r):pen(BG):string(string.char(179))
        dc:seek(l+w-1, t+r):pen(BG):string(string.char(179))
    end
    if title then
        dc:seek(l+2, t):pen(title_pen or COLOR_WHITE)
            :string((' '..title..' '):sub(1, math.max(0, w-4)))
    end
end

-- fuzzy subsequence match + ranking (fort/dig-building's)
local function fuzzy(needle, hay)
    if needle == '' then return true end
    local j = 1
    for i = 1, #hay do
        if hay:byte(i) == needle:byte(j) then
            j = j+1
            if j > #needle then return true end
        end
    end
    return false
end
local function rank(label, needle)
    local t = label:lower()
    if t == needle then return 0 end
    if t:sub(1, #needle) == needle then return 1 end
    if t:find(needle, 1, true) then return 2 end
    if fuzzy(needle, t) then return 3 end
end
local function list_matches(a)
    local set, best, best_rank = {}, nil, nil
    if a.search ~= '' then
        local needle = a.search:lower()
        for i, e in ipairs(a.entries) do
            local r = rank(e.label, needle)
            if r then
                set[i] = true
                if not best_rank or r < best_rank then best, best_rank = i, r end
            end
        end
    end
    return set, best
end
local function aux_max_scroll(a, cols, rows)
    return math.max(0, math.ceil(#a.entries/cols) - rows)
end

local function slot_row_text(i, s)
    local it = s.cands[s.pick]
    local tag = (' [%d/%d]'):format(#s.cands, s.qty)
    local txt, pen
    if it then
        txt = ('%d) %s'):format(i, item_label(it))
        pen = (#s.cands < s.qty) and COLOR_LIGHTRED or COLOR_WHITE
    else
        txt = ('%d) needs %s'):format(i, s.what or 'an item')
        pen = COLOR_LIGHTRED
    end
    return txt:sub(1, 999-#tag), tag, pen
end

local function tile_standable(p)
    local tt = dfhack.maps.getTileType(p)
    if not tt then return false end
    local sh = tile_attrs[tt].shape
    if not (sh == df.tiletype_shape.FLOOR or sh == df.tiletype_shape.RAMP
        or sh == df.tiletype_shape.STAIR_UP or sh == df.tiletype_shape.STAIR_DOWN
        or sh == df.tiletype_shape.STAIR_UPDOWN) then return false end
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return false end
    local bo = blk.occupancy[p.x%16][p.y%16].building
    return bo ~= df.tile_building_occ.Impassable and bo ~= df.tile_building_occ.Obstacle
end

-- literal text search over the rendered grid (the too-long prompt has no struct)
local function find_screen_text(needle)
    local gps = df.global.gps
    local readTile, char = dfhack.screen.readTile, string.char
    local dimx, dimy = gps.dimx, gps.dimy
    local fx, fy, flen
    pcall(function()
        for y = 0, dimy-1 do
            local row = {}
            for x = 0, dimx-1 do
                local pen = readTile(x, y)
                local c = pen and pen.ch or 0
                row[#row+1] = (c >= 32 and c < 127) and char(c) or ' '
            end
            local st = table.concat(row):find(needle, 1, true)
            if st then fx, fy, flen = st-1, y, #needle break end
        end
    end)
    return fx, fy, flen
end


-- ==== job library (from adv/advfort) =========================================
-- job settings (command-line flags adjust these)
settings={build_by_items=false,use_worn=false,check_inv=true,teleport_items=true,df_assign=false,gui_item_select=true,only_in_sites=false,set_civ=nil}

function hasValue(tbl,val)
    for k,v in pairs(tbl) do
        if v==val then
            return true
        end
    end
    return false
end
function reverseRaceLookup(id)
    return df.global.world.raws.creatures.all[id].creature_id
end
function deon_filter(name,type_id,subtype_id,custom_id, parent)
    --print(name)
    local adv=dfhack.world.getAdventurer()
    local race_filter=build_filter[reverseRaceLookup(adv.race)]
    if race_filter then
        if race_filter.forbid_all then
            return hasValue(race_filter.allow,name)
        else
            return not hasValue(race_filter.forbid,name)
        end
    else
        if build_filter.forbid_all then
            return hasValue(build_filter.allow,name)
        else
            return not hasValue(build_filter.forbid,name)
        end
    end
end
local mode_name
local args={...}
function parse_args(  )
    cli_cmd=nil     -- a global: stale values from a prior invocation must not linger
    --NOTE(warmist): this duplicates most of stuff in utils, but i don't want to change some functionality
    local i=1
    while i<=#args do
        local v=args[i]
        if v=="-c" or v=="--cheat" then
            settings.build_by_items=true
            settings.df_assign=false
        elseif v=="-q" or v=="--quick" then
            settings.quick=true
        elseif v=="-u" or v=="--unsafe" then --ignore pain and etc
            settings.unsafe=true
        elseif v=="-s" or v=="--safe" then
            settings.safe=true
        elseif v=="-i" or v=="--inventory" then
            settings.check_inv=true
            settings.df_assign=false
        elseif v=="-a" or v=="--nodfassign" then
            settings.df_assign=false
        elseif v=="-e" or v=="--entity" then
            if #args>i and not args[i+1]:startswith("-") then
                settings.set_civ=args[i+1]
                print(settings.set_civ)
                i=i+1
            else
                settings.set_civ=true
            end
        elseif v=="-h" or v=="--help" then
            settings.help=true
        elseif v=="--clear_jobs" then
            settings.clear_jobs=true
        elseif v=="show" or v=="hide" or v=="toggle" or v=="toggle-window" then
            cli_cmd=v
        else
            mode_name=v
        end
        i=i+1
    end
end
parse_args()

last_building=last_building or {}
build_sel=build_sel or nil    -- {label=..., picks={item ids}} from the picker's materials pane

if settings.help then
    print('adv/fort: do fort jobs in adventure mode -- see the script header for')
    print('full documentation. Flags: -c cheat, -q quick, -u unsafe, -s safe,')
    print('-i inventory, -a no-df-assign, -e [ENTITY]; commands: show|hide|toggle.')
    return
end

--[[    Util functions ]]--
function advGlobalPos()
    local map=df.global.world.map
    local wd=df.global.world.world_data
    local adv=dfhack.world.getAdventurer()
    --wd.midmap_data.adv_region_x*16+wd.midmap_data.adv_emb_x,wd.midmap_data.adv_region_y*16+wd.midmap_data.adv_emb_y
    --return wd.midmap_data.adv_region_x*16+wd.midmap_data.adv_emb_x,wd.midmap_data.adv_region_y*16+wd.midmap_data.adv_emb_y
    --return wd.midmap_data.adv_region_x*16+wd.midmap_data.adv_emb_x+adv.pos.x/16,wd.midmap_data.adv_region_y*16+wd.midmap_data.adv_emb_y+adv.pos.y/16
    --print(map.region_x,map.region_y,adv.pos.x,adv.pos.y)
    --print(map.region_x+adv.pos.x/48, map.region_y+adv.pos.y/48,wd.midmap_data.adv_region_x*16+wd.midmap_data.adv_emb_x,wd.midmap_data.adv_region_y*16+wd.midmap_data.adv_emb_y)
    return math.floor(map.region_x+adv.pos.x/48), math.floor(map.region_y+adv.pos.y/48)
end
function inSite()

    local tx,ty=advGlobalPos()

    for k,v in pairs(df.global.world.world_data.sites) do
        local tp={v.pos.x,v.pos.y}
        if tx>=tp[1]*16+v.rgn_min_x and tx<=tp[1]*16+v.rgn_max_x and
            ty>=tp[2]*16+v.rgn_min_y and ty<=tp[2]*16+v.rgn_max_y then
            return v
        end
    end
end
--[[    low level job management    ]]--
function findAction(unit,ltype)
    ltype=ltype or df.unit_action_type.None
    for i,v in ipairs(unit.actions) do
        if v.type==ltype then
            return v
        end
    end
end
function add_action(unit,action_data)
    local action=findAction(unit) --find empty action
    if action then
        action:assign(action_data)
        action.id=unit.next_action_id
        unit.next_action_id=unit.next_action_id+1
    else
        local tbl=copyall(action_data)
        tbl.new=true
        tbl.id=unit.next_action_id
        unit.actions:insert("#",tbl)
        unit.next_action_id=unit.next_action_id+1
    end
end
function addJobAction(job,unit) --what about job2?
    if job==nil then
        error("invalid job")
    end
    if findAction(unit,df.unit_action_type.Job) or findAction(unit,df.unit_action_type.JobRecover) then
        print("Already has job action")
        return
    end
    local action=findAction(unit)
    local pos=copyall(unit.pos)
    --local pos=copyall(job.pos)
    unit.path.dest:assign(pos)
    --job
    local data={type=df.unit_action_type.Job,data={job={x=pos.x,y=pos.y,z=pos.z,timer=10}}}
    --job2:
    --local data={type=df.unit_action_type.JobRecover,data={job2={timer=10}}}
    add_action(unit,data)
    --add_action(unit,{type=df.unit_action_type.Unsteady,data={unsteady={timer=5}}})
end

function make_native_job(args)
    if args.job == nil then
        local newJob=df.job:new()
        newJob.id=df.global.job_next_id
        df.global.job_next_id=df.global.job_next_id+1
        newJob.flags.special=true
        newJob.job_type=args.job_type
        newJob.completion_timer=-1

        newJob.pos:assign(args.pos)
        --newJob.pos:assign(args.unit.pos)
        args.job=newJob
        args.unlinked=true
    end
end
function job_name(j)
    local ok,nm=pcall(function() return dfhack.job.getName(j) end)
    if ok and nm and #nm>0 then return nm end
    local a=df.job_type.attrs[j.job_type]
    return (a and a.caption) or df.job_type[j.job_type] or '?'
end
function smart_job_delete( job )
    local gref_types=df.general_ref_type
    --TODO: unmark items as in job
    for i,v in ipairs(job.general_refs) do
        if v:getType()==gref_types.BUILDING_HOLDER then
            local b=v:getBuilding()
            if b then
                --remove from building
                for i,v in ipairs(b.jobs) do
                    if v==job then
                        b.jobs:erase(i)
                        break
                    end
                end
            else
                print("Warning: building holder ref was invalid while deleting job")
            end
        elseif v:getType()==gref_types.UNIT_WORKER then
            local u=v:getUnit()
            if u then
                u.job.current_job =nil
            else
                print("Warning: unit worker ref was invalid while deleting job")
            end
        else
            print("Warning: failed to remove link from job with type:",gref_types[v:getType()])
        end
    end
    --unlink job
    local link=job.list_link
    if link.prev then
        link.prev.next=link.next
    end
    if link.next then
        link.next.prev=link.prev
    end
    link:delete()
    --finally delete the job
    job:delete()
end
--TODO: this logic might be better with other --starting logic--
if settings.clear_jobs then
    print("Clearing job list!")
    local counter=0
    local job_link=df.global.world.jobs.list.next
    while job_link and job_link.item do
        local job=job_link.item
        job_link=job_link.next
        smart_job_delete(job)
        counter=counter+1
    end
    print("Deleted: "..counter.." jobs")
    return
end
--luacheck: in={_type:table,job:df.job,job_type:df.job_type,pos:df.coord,from_pos:df.coord,unit:df.unit,no_job_delete:bool,screen:AdvFort,pre_actions:'{_type:function,_node:{_type:tuple,_tuple:[bool,string]},_anyfunc:true}[]',post_actions:'{_type:function,_node:{_type:tuple,_tuple:[bool,string]},_anyfunc:true}[]'}
function makeJob(args)
    gscript.start(function ()
        make_native_job(args)
        local failed
        for k,v in ipairs(args.pre_actions or {}) do
            -- pcall: a lua ERROR in an action must surface on the status line,
            -- not die silently inside the coroutine (console-only)
            local okc,ok,msg=pcall(v,args)
            if not okc then ok,msg=false,'error: '..tostring(ok):match('[^\n]+') end
            if not ok then
                failed=msg or 'failed'
                break
            end
        end
        if failed==nil then
            AssignUnitToJob(args.job,args.unit,args.from_pos)
            for k,v in ipairs(args.post_actions or {}) do
                local okc,ok,msg=pcall(v,args)
                if not okc then ok,msg=false,'error: '..tostring(ok):match('[^\n]+') end
                if not ok then
                    failed=msg or 'failed'
                    break
                end
            end
            if failed then
                UnassignJob(args.job,args.unit)
            end
        end
        if failed==nil then
            if args.unlinked then
                dfhack.job.linkIntoWorld(args.job,true)
                args.unlinked=false
            end
            addJobAction(args.job,args.unit)
            args.screen:wait_tick()
            args.screen:wait_long_start()
        else
            if args.on_fail then
                pcall(args.on_fail,args)      -- fresh-construction rollback (shell + job)
            elseif not args.no_job_delete then
                smart_job_delete(args.job)
            end
            if args.screen and args.screen.set_status then
                pcall(function() args.screen:set_status(failed) end)
            end
            dfhack.gui.showAnnouncement("Job failed:"..failed,5,1)
        end
    end)
end

function UnassignJob(job,unit,unit_pos)
    unit.job.current_job=nil
end
function AssignUnitToJob(job,unit,unit_pos)
    job.general_refs:insert("#",{new=df.general_ref_unit_workerst,unit_id=unit.id})
    unit.job.current_job=job
    unit_pos=unit_pos or copyall(job.pos)
    unit.path.dest:assign(unit_pos)
    return true
end
function SetCreatureRef(args)
    local job=args.job
    local pos=args.pos
    for k,v in pairs(df.global.world.units.active) do
        if same_xyz(v.pos, pos) then
            job.general_refs:insert("#",{new=df.general_ref_unit_cageest,unit_id=v.id})
            return
        end
    end
end

function SetWebRef(args)
    local pos=args.pos
    for k,v in pairs(df.global.world.items.other.ANY_WEBS) do
        if same_xyz(v.pos, pos) then
            args.job.general_refs:insert("#",{new=df.general_ref_item,item_id=v.id})
            return
        end
    end
end
function SetPatientRef(args)
    local job=args.job
    local pos=args.pos
    for k,v in pairs(df.global.world.units.active) do
        if same_xyz(v.pos, pos) then
            job.general_refs:insert("#",{new=df.general_ref_unit_patientst,unit_id=v.id})
            return
        end
    end
end
function SetCarveDir(args)
    local job=args.job
    local pos=args.pos
    local from_pos=args.from_pos
    if pos.x>from_pos.x then
        job.specflag.carve_track_flags.carve_track_east=true
    elseif pos.x<from_pos.x then
        job.specflag.carve_track_flags.carve_track_west=true
    elseif pos.y>from_pos.y then
        job.specflag.carve_track_flags.carve_track_south=true
    elseif pos.y<from_pos.y then
        job.specflag.carve_track_flags.carve_track_north=true
    end
end
function is_grasping_item( item_bp,unit )
    local bplan=unit.body.body_plan
    local bpart=bplan.body_parts[item_bp]

    return bpart.flags.GRASP
end
function MakePredicateWieldsItem(item_skill)
    -- only two tools are ever demanded (pick for the dig family, axe for felling).
    -- "Wields" is generous: a tool STRAPPED to the body (inventory mode 10) or
    -- carried inside a bag/backpack/quiver counts too -- an adventurer with the
    -- pick on their back should not have to juggle hands to dig. Held-in-grasp
    -- is still checked first (cheapest, and the common case).
    local tool_msg={[df.job_skill.MINING]="Carry a pick (held, strapped or bagged)",
                    [df.job_skill.AXE]="Carry an axe (held, strapped or bagged)"}
    local msg=tool_msg[item_skill] or "Carry the right tool"
    local function is_the_tool(item)
        return item:getMeleeSkill()==item_skill
    end
    local pred=function(args)
        for k,v in pairs(args.unit.inventory) do
            if v.mode==1 and is_the_tool(v.item) and is_grasping_item(v.body_part_id,args.unit) then
                return true
            end
        end
        for k,v in pairs(args.unit.inventory) do
            if v.mode==10 and is_the_tool(v.item) then   -- strapped to the body
                return true
            end
            -- inside a carried container (bag, backpack, quiver)
            local ok,contained=pcall(dfhack.items.getContainedItems,v.item)
            if ok and contained then
                for _,it in ipairs(contained) do
                    if is_the_tool(it) then return true end
                end
            end
        end
        return false,msg
    end
    return pred
end

-- Ensure the needed tool sits in a grasp before a DF-pumped job starts: DF's
-- own work handler refuses to progress the dig family without a WIELDED pick
-- (the relaxed carry-check alone left digs frozen at their first pulse). If
-- the tool is strapped or bagged, wield it -- through a free hand, or by
-- temporarily strapping one held item to make room -- and record the exact
-- moves on the screen (tool_swap) so everything goes back once the job ends.
function MakeEnsureToolWielded(item_skill)
    return function(args)
        local unit=args.unit
        for _,v in ipairs(unit.inventory) do
            if v.mode==1 and v.item:getMeleeSkill()==item_skill
                and is_grasping_item(v.body_part_id,unit) then
                return true                      -- already in hand
            end
        end
        local tool,tool_old
        for _,v in ipairs(unit.inventory) do
            if v.mode==10 and v.item:getMeleeSkill()==item_skill then
                tool,tool_old=v.item,{mode=v.mode,bp=v.body_part_id}
            else
                local ok,c=pcall(dfhack.items.getContainedItems,v.item)
                if ok and c then
                    for _,it in ipairs(c) do
                        if it:getMeleeSkill()==item_skill then tool=it end
                    end
                end
            end
            if tool then break end
        end
        if not tool then return false,"Carry the right tool" end
        -- find a grasp for it: a free hand, else displace one held item
        local held_by_bp={}
        for _,v in ipairs(unit.inventory) do
            if v.mode==1 then held_by_bp[v.body_part_id]=v.item end
        end
        local parts=unit.body.body_plan.body_parts
        local target,displaced
        for i=0,#parts-1 do
            if parts[i].flags.GRASP and not held_by_bp[i] then target=i break end
        end
        if not target then
            for i=0,#parts-1 do
                if parts[i].flags.GRASP and held_by_bp[i] then
                    target,displaced=i,held_by_bp[i]
                    break
                end
            end
        end
        if not target then return false,"No grasp to hold the tool" end
        if displaced and not dfhack.items.moveToInventory(displaced,unit,10,0) then
            return false,"No free hand for the tool"
        end
        if not dfhack.items.moveToInventory(tool,unit,1,target) then
            if displaced then pcall(dfhack.items.moveToInventory,displaced,unit,1,target) end
            return false,"Could not ready the tool"
        end
        if args.screen then
            args.screen.tool_swap={tool_id=tool.id,old=tool_old,
                displaced_id=displaced and displaced.id or nil,grasp=target}
        end
        dfhack.gui.showAnnouncement(
            "You ready your "..dfhack.items.getDescription(tool,0)..".",7,1)
        return true
    end
end

function makeset(args)
    local tbl={}
    for k,v in pairs(args) do
        tbl[v]=true
    end
    return tbl
end
function NotConstruct(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if tile_attrs[tt].material~=df.tiletype_material.CONSTRUCTION and dfhack.buildings.findAtTile(args.pos)==nil then
        return true
    else
        return false, "Can only do it on non constructions"
    end
end
function NoConstructedBuilding(args)
    local bld=dfhack.buildings.findAtTile(args.pos)
    if bld and bld.construction_stage==3 then
        return false, "Can only do it on clear area or non-finished buildings"
    end
    return true
end
function IsBuilding(args)
    if dfhack.buildings.findAtTile(args.pos) then
        return true
    end
    return false, "Can only do it on buildings"
end
function IsConstruct(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if tile_attrs[tt].material==df.tiletype_material.CONSTRUCTION then
        return true
    else
        return false, "Can only do it on constructions"
    end
end
function SameSquare(args)
    local pos1=args.pos
    local pos2=args.from_pos
    if same_xyz(pos1, pos2) then
       return true
    else
        return false, "Can only do it on same square"
    end
end
function IsHardMaterial(args)
    local tt=dfhack.maps.getTileType(args.pos)
    local mat=tile_attrs[tt].material
    local hard_materials=makeset{df.tiletype_material.STONE,df.tiletype_material.FEATURE,
        df.tiletype_material.LAVA_STONE,df.tiletype_material.MINERAL,df.tiletype_material.FROZEN_LIQUID,}
    if hard_materials[mat] then
        return true
    else
        return false, "Can only do it on hard materials"
    end
end
function IsStairs(args)
    local tt=dfhack.maps.getTileType(args.pos)
    local shape=tile_attrs[tt].shape
    if shape==df.tiletype_shape.STAIR_UP or shape==df.tiletype_shape.STAIR_DOWN or shape==df.tiletype_shape.STAIR_UPDOWN or shape==df.tiletype_shape.RAMP then
        return true
    else
        return false,"Can only do it on stairs/ramps"
    end
end
function IsFloor(args)
    local tt=dfhack.maps.getTileType(args.pos)
    local shape=tile_attrs[tt].shape
    if shape==df.tiletype_shape.FLOOR or shape==df.tiletype_shape.BOULDER or shape==df.tiletype_shape.PEBBLES then
        return true
    else
        return false,"Can only do it on floors"
    end
end
function IsWall(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if tile_attrs[tt].shape==df.tiletype_shape.WALL then
        return true
    else
        return false, "Can only do it on walls"
    end
end
function IsTree(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if tile_attrs[tt].material==df.tiletype_material.TREE then
        return true
    else
        return false, "Can only do it on trees"
    end
end
function IsPlant(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if tile_attrs[tt].shape==df.tiletype_shape.SHRUB then
        return true
    else
        return false, "Can only do it on plants"
    end
end
function IsWater(args)
    return true
end

function IsUnit(args)
    local pos=args.pos
    for k,v in pairs(df.global.world.units.active) do
        if same_xyz(v.pos, pos) then
            return true
        end
    end
    return false,"Unit must be present"
end
function itemsAtPos(pos,tbl)
    local ret=tbl or {}
    for k,v in pairs(df.global.world.items.other.IN_PLAY) do
        if v.flags.on_ground and same_xyz(v.pos, pos) then
            table.insert(ret,v)
        end
    end
    return ret
end
function AssignBuildingRef(args)
    local bld=args.building or dfhack.buildings.findAtTile(args.pos)
    args.job.general_refs:insert("#",{new=df.general_ref_building_holderst,building_id=bld.id})
    bld.jobs:insert("#",args.job)
    args.building=args.building or bld
    return true
end
function chooseBuildingWidthHeightDir(args) --TODO nicer selection dialog
    local btype=df.building_type
    local area=makeset{"w","h"}
    local all=makeset{"w","h","d"}
    local needs={[btype.FarmPlot]=area,[btype.Bridge]=all,
        [btype.RoadDirt]=area,[btype.RoadPaved]=area,[btype.ScrewPump]=makeset{"d"},
        [btype.AxleHorizontal]=all,[btype.WaterWheel]=makeset{"d"},[btype.Rollers]=makeset{"d"}}
    local myneeds=needs[args.type]
    if myneeds==nil then return end
    if args.width==nil and myneeds.w then
        --args.width=3
        dialog.showInputPrompt("Building size:", "Input building width:", nil, "1",
            function(txt) args.width=tonumber(txt);BuildingChosen(args) end)
        return true
    end
    if args.height==nil and myneeds.h then
        --args.height=4
        dialog.showInputPrompt("Building size:", "Input building height:", nil, "1",
            function(txt) args.height=tonumber(txt);BuildingChosen(args) end)
        return true
    end
    if args.direction==nil and myneeds.d then
        --args.direction=0--?
        dialog.showInputPrompt("Building size:", "Input building direction:", nil, "0",
            function(txt) args.direction=tonumber(txt);BuildingChosen(args) end)
        return true
    end
    return false
    --width = ..., height = ..., direction = ...
end
function BuildingChosen(inp_args,type_id,subtype_id,custom_id)
    local args=inp_args or {}

    args.type=type_id or args.type
    args.subtype=subtype_id or args.subtype
    args.custom=custom_id or args.custom_id
    if inp_args then
        args.pos=inp_args.pos or args.pos
    end
    last_building.type=args.type
    last_building.subtype=args.subtype
    last_building.custom=args.custom

    if chooseBuildingWidthHeightDir(args) then
        return
    end
    --if settings.build_by_items then
    --    args.items=itemsAtPos(inp_args.from_pos)
    --end
    -- constructBuilding treats pos as the TOP-LEFT corner. Center multi-tile
    -- buildings on the clicked tile. Standing inside the footprint is FINE:
    -- the job anchors at the worker's own tile and the engine steps you off
    -- the finished building if it would seal you in.
    local okz,rot,w,h,cx,cy=pcall(dfhack.buildings.getCorrectSize,
        args.width,args.height,args.type,args.subtype,args.custom,args.direction or 0)
    if okz and w and (w>1 or (h or 1)>1) then
        args.pos={x=args.pos.x-(cx or 0),y=args.pos.y-(cy or 0),z=args.pos.z}
    end
    local ok,bld=pcall(buildings.constructBuilding,args)
    if not ok or not bld then
        dfhack.gui.showAnnouncement("Cannot place that there.",COLOR_LIGHTRED,true)
        if args.screen and args.screen.set_status then
            pcall(function() args.screen:set_status("Cannot place that there") end)
        end
        return
    end
    args.building=bld
    -- If the materials never make it in, ROLL THE FRESH SHELL BACK. Leaving it
    -- (the old behavior: no_job_delete kept the job AND the planned building)
    -- planted an invisible shell that the next build click silently RESUMED --
    -- i.e. "a failed build built some other random building".
    args.on_fail=function(a)
        pcall(smart_job_delete,a.job)
        pcall(dfhack.buildings.deconstruct,a.building)
    end
    CheckAndFinishBuilding(args,bld)
end


-- Remove Building -- flow VERIFIED live on a partially-built 3x3 workshop:
-- * dfhack.buildings.deconstruct returns TRUE only when the building went away
--   instantly (bare planned shells); on anything with built work it QUEUES a
--   DestroyBuilding job and returns false -- the old no-error pcall check read
--   that as success, announced "Building removed." and did nothing.
-- * the destroy job must anchor at the building tile nearest the WORKER: DF
--   only works a job within 1 tile of job.pos, and a 3x3's CENTER is out of
--   reach from beside its far edge (this stalled removal on workshops).
-- * demolition works the build stages back to 0 and the job ends, leaving a
--   bare shell -- the engine's destroy_bld follow-through finishes it off.
function RemoveBuilding(args)
    local bld=dfhack.buildings.findAtTile(args.pos)
    if bld==nil then return false,"No building to remove" end
    local u=args.unit
    local function find_destroy_job()
        for _,v in ipairs(bld.jobs) do
            if v.job_type==df.job_type.DestroyBuilding then return v end
        end
    end
    local function anchor_assign(v)
        v.pos:assign(xyz2pos(math.max(bld.x1,math.min(u.pos.x,bld.x2)),
                             math.max(bld.y1,math.min(u.pos.y,bld.y2)),bld.z))
        AssignUnitToJob(v,u,args.from_pos)
        addJobAction(v,u)
        if args.screen then
            args.screen.destroy_bld=bld.id
            if args.screen.wait_tick then args.screen:wait_tick() end
        end
        return true
    end
    local cj=u.job.current_job
    if cj and cj.job_type~=df.job_type.DestroyBuilding then
        return false,("Busy: %s (click the status line to cancel)"):format(job_name(cj))
    end
    local dj=find_destroy_job()
    if dj then                     -- resume already-queued demolition
        if cj==dj then return false,"Already removing it" end
        if cj then CancelJob(u) end
        return anchor_assign(dj)
    end
    -- an UNFINISHED building may be instantly removable (planned shell, no
    -- built work); finished buildings always go the demolition-job route
    local ok,unbuilt=pcall(function() return bld:getBuildStage()<bld:getMaxBuildStage() end)
    if ok and unbuilt then
        local okd,gone=pcall(dfhack.buildings.deconstruct,bld)
        if okd and gone then
            dfhack.gui.showAnnouncement("Building removed.",7,1)
            return true
        end
        dj=find_destroy_job()      -- deconstruct queued the work instead
    end
    if not dj then
        bld:queueDestroy()
        dj=find_destroy_job()
    end
    if dj then
        if cj and cj.job_type==df.job_type.DestroyBuilding then CancelJob(u) end
        return anchor_assign(dj)
    end
    return false,"Building removal job failed to be created"
end

-- cooking-slot gates (flags1.cookable), matching the suite's eating rules
-- (adv/always-be-satiated): whole corpses are never ingredients, and
-- sapient-sourced food obeys the adventurer's civ ethics -- DF's kitchen
-- reaches the same verdicts through code advfort's lua matcher lacks, which
-- is how "prepare lavish meal" offered a mutilated corpse and illithid brain.
local ER=df.ethic_response
local function ethic_permits(v)
    return (v>=ER.ACCEPTABLE and v<=ER.ONLY_IF_SANCTIONED) or v==ER.REQUIRED
end
local function may_eat_sapients()
    local u=dfhack.world.getAdventurer()
    local civ_id=u and u.civ_id or -1
    if civ_id<0 then
        local nem=df.nemesis_record.find(df.global.adventure.player_id)
        civ_id=nem and nem.figure and nem.figure.civ_id or -1
    end
    local civ=civ_id>=0 and df.historical_entity.find(civ_id) or nil
    local raw=civ and civ.entity_raw
    if not raw then return false end
    return ethic_permits(raw.ethic[df.ethic_type.EAT_SAPIENT_OTHER])
        or ethic_permits(raw.ethic[df.ethic_type.EAT_SAPIENT_KILL])
end
local function sapient_source(mi)
    local cr=mi and mi.creature
    if not cr then return false end
    for _,c in ipairs(cr.caste) do
        if c.flags.CAN_LEARN or c.flags.CAN_SPEAK then return true end
    end
    return false
end

function isSuitableItem(job_item,item)
    --todo butcher test
    if job_item.item_type~=-1 then
        if item:getType()~= job_item.item_type then
            return false, "type"
        elseif job_item.item_subtype~=-1 then
            if item:getSubtype()~=job_item.item_subtype then
                return false,"subtype"
            end
        end
    end

    if job_item.mat_type~=-1 then
        if item:getActualMaterial()~= job_item.mat_type then --unless we would want to make hist-fig specific reactions
            return false, "material"
        elseif job_item.mat_index~=-1 then
            if item:getActualMaterialIndex()~=job_item.mat_index then
                return false,"material index"
            end
        end
    end
    if job_item.flags1.sand_bearing and not item:isSandBearing() then
        return false,"not sand bearing"
    end
    if job_item.flags1.butcherable and not (item:getType()== df.item_type.CORPSE or item:getType()==df.item_type.CORPSEPIECE) then
        return false,"not butcherable"
    end
    local matinfo=dfhack.matinfo.decode(item)
    --print(matinfo:getCraftClass())
    --print("Matching ",item," vs ",job_item)
    if job_item.flags1.cookable then
        local ty=item:getType()
        if ty==df.item_type.FOOD then
            return false,"already cooked"
        end
        if ty==df.item_type.CORPSE or ty==df.item_type.CORPSEPIECE
            or ty==df.item_type.REMAINS then
            return false,"not an ingredient"
        end
        if sapient_source(matinfo) and not may_eat_sapients() then
            return false,"sapient (your ethics forbid it)"
        end
    end

    if type(job_item) ~= "table" and not matinfo:matches(job_item) then
        --[[
        local true_flags={}
        for k,v in pairs(job_item.flags1) do
            if v then
                table.insert(true_flags,k)
            end
        end
        for k,v in pairs(job_item.flags2) do
            if v then
                table.insert(true_flags,k)
            end
        end
        for k,v in pairs(job_item.flags3) do
            if v then
                table.insert(true_flags,k)
            end
        end
        for k,v in pairs(true_flags) do
            print(v)
        end
        --]]

        return false,"matinfo"
    end
    -- some bonus checks:
    if job_item.flags2.building_material and not item:isBuildMat() then
        return false,"non-build mat"
    end
    -- *****************
    --print("--Matched")
    --reagen_index?? reaction_id??
    if job_item.metal_ore~=-1 and not item:isMetalOre(job_item.metal_ore) then
        return false,"metal ore"
    end
    if job_item.min_dimension~=-1 then
    end
    -- if #job_item.contains~=0 then
    -- end
    if job_item.has_tool_use~=-1 then
        if not item:hasToolUse(job_item.has_tool_use) then
            return false,"tool use"
        end
    end
    if job_item.has_material_reaction_product~="" then
        local ok=false
        for k,v in pairs(matinfo.material.reaction_product.id) do
            if v.value==job_item.has_material_reaction_product then
                ok=true
                break
            end
        end
        if not ok then
            return false, "no material reaction product"
        end
    end
    if job_item.reaction_class~="" then
        local ok=false
        for k,v in pairs(matinfo.material.reaction_class) do
            if v.value==job_item.reaction_class then
                ok=true
                break
            end
        end
        if not ok then
            return false, "no material reaction class"
        end
    end
    return true
end
-- An item counts as collected at the JOB ANCHOR or anywhere inside the
-- BUILDING: putItemsInBuilding drops materials at the building, while job.pos
-- may sit on the footprint tile nearest the worker (AnchorJobAtWorker) -- an
-- anchor-only comparison read every teleported material as uncollected and
-- flagged the job fetching, which an adventurer can never satisfy: starting a
-- workshop froze until a lucky second click re-aligned the anchor.
function getItemsUncollected(job,building)
    local ret={}
    for id,jitem in pairs(job.items) do
        local x,y,z=dfhack.items.getPosition(jitem.item)
        local collected=(x==job.pos.x and y==job.pos.y and z==job.pos.z)
        if not collected and building then
            collected=z==building.z and x>=building.x1 and x<=building.x2
                and y>=building.y1 and y<=building.y2
        end
        if not collected then table.insert(ret,jitem) end
    end
    return ret
end
function AddItem(tbl,item,recurse,skip_add)
    if not skip_add then
        table.insert(tbl,item)
    end
    if recurse then
        local subitems=dfhack.items.getContainedItems(item)
        if subitems~=nil then
            for k,v in pairs(subitems) do
                AddItem(tbl,v,recurse)
            end
        end
    end
end
function EnumItems(args)
    local ret=args.table or {}
    if args.all then
        for k,v in pairs(df.global.world.items.other.IN_PLAY) do
            if v.flags.on_ground then
                AddItem(ret,v,args.deep)
            end
        end
    elseif args.pos~=nil then
        for k,v in pairs(df.global.world.items.other.IN_PLAY) do
            if v.flags.on_ground and same_xyz(v.pos, args.pos) then
                AddItem(ret,v,args.deep)
            end
        end
    end
    if args.unit~=nil then
        for k,v in pairs(args.unit.inventory) do
            if args.inv[v.mode] then
                AddItem(ret,v.item,args.deep)
            elseif args.deep then
                AddItem(ret,v.item,args.deep,true)
            end
        end
    end
    return ret
end
function putItemsInBuilding(building,job_item_refs)
    for k,v in ipairs(job_item_refs) do
        --local pos=dfhack.items.getPosition(v)
        if not dfhack.items.moveToBuilding(v.item,building,0) then
            print("Could not put item:",k,v.item)
        else
            -- moveToBuilding leaves this flag off, and DF's adv construct
            -- handler treats a contained-but-not-in_building material as
            -- missing (measured live: setting it revived a frozen build)
            v.item.flags.in_building=true
        end
        v.flags.is_fetching=false
    end
end
function putItemsInHauling(unit,job_item_refs)
    for k,v in ipairs(job_item_refs) do
        --local pos=dfhack.items.getPosition(v)
        print("moving:",tostring(v),tostring(v.item))
        printall(v)
        if not dfhack.items.moveToInventory(v.item,unit,0,0) then
            print("Could not put item:",k,v.item)
        end
        v.flags.is_fetching=false
    end
end
function finish_item_assign(args)
    local job=args.job
    local item_modes={
        [df.job_type.PlantSeeds]="haul",
        [df.job_type.Eat]="haul",
    }
    local item_mode=item_modes[job.job_type] or "teleport"
    if settings.teleport_items and item_mode=="teleport" then
        putItemsInBuilding(args.building,job.items)
    end

    local uncollected = getItemsUncollected(job,args.building)
    if #uncollected > 0 and settings.teleport_items and item_mode=="teleport" then
        -- a straggler the building-move could not take (e.g. an item chosen out
        -- of a distant container): teleporting is this mode's whole contract,
        -- and "fetching" is a death sentence for a worker who never hauls --
        -- put it on the job tile directly
        for _,jitem in ipairs(uncollected) do
            pcall(dfhack.items.moveToGround,jitem.item,
                xyz2pos(job.pos.x,job.pos.y,job.pos.z))
        end
        uncollected = getItemsUncollected(job,args.building)
    end
    if #uncollected == 0 then
        job.flags.working=true
        if item_mode=="haul" then
            putItemsInHauling(args.unit,job.items)
        end
    else
        job.flags.fetching=true
        uncollected[1].flags.is_fetching=true
    end
end
-- Items on offer for any job: hauled inventory + the CONTENTS of worn containers
-- (deep recursion; the worn backpack itself is never consumed unless -u), the
-- ground underfoot, and every ground item within GATHER_RADIUS tiles. The old
-- enumeration covered only the exact from_pos tile (all inventory mode flags
-- defaulted false), which is why the item picker kept coming up empty.
local GATHER_RADIUS=8
function EnumItems_with_settings( args )
    local ret=EnumItems{pos=args.from_pos,unit=args.unit,
            inv={[df.inv_item_role_type.Hauled]=true,
                 [df.inv_item_role_type.Worn]=settings.use_worn,
                 [df.inv_item_role_type.Weapon]=settings.use_worn,},deep=true}
    local upos=(args.unit and args.unit.pos) or args.from_pos
    if upos then
        for _,v in ipairs(df.global.world.items.other.IN_PLAY) do
            if v.flags.on_ground and v.pos.z==upos.z
                and math.abs(v.pos.x-upos.x)<=GATHER_RADIUS
                and math.abs(v.pos.y-upos.y)<=GATHER_RADIUS
                and not same_xyz(v.pos,args.from_pos) then
                AddItem(ret,v,true)
            end
        end
    end
    return ret
end
function find_suitable_items(job,items,job_items)
    job_items=job_items or job.job_items.elements

    local item_counts={}
    for job_id, trg_job_item in ipairs(job_items) do
        item_counts[job_id]=trg_job_item.quantity
    end

    local item_suitability={}
    local used_item_id={}
    for job_id, trg_job_item in ipairs(job_items) do
        item_suitability[job_id]={}

        for _,cur_item in pairs(items) do
            if not used_item_id[cur_item.id] then
                local item_suitable,msg=isSuitableItem(trg_job_item,cur_item)
                if item_suitable or settings.build_by_items then
                    table.insert(item_suitability[job_id],cur_item)
                end
                --[[
                if msg then
                    print(cur_item,msg)
                else
                    print(cur_item,"ok")
                end
                --]]
                if not settings.gui_item_select then
                    if (item_counts[job_id]>0 and item_suitable) or settings.build_by_items then
                        --cur_item.flags.in_job=true
                        job.items:insert("#",{new=true,item=cur_item,role=df.job_role_type.Reagent,job_item_idx=job_id})
                        item_counts[job_id]=item_counts[job_id]-cur_item:getTotalDimension()
                        --print(string.format("item added, job_item_id=%d, item %s, quantity left=%d",job_id,tostring(cur_item),item_counts[job_id]))
                        used_item_id[cur_item.id]=true
                    end
                end
            end
        end
    end

    return item_suitability,item_counts
end
function AssignJobItems(args)
    if settings.df_assign then --use df default logic and hope that it would work
        return true
    end
    -- first find items that you want to use for the job
    local job=args.job
    local its=EnumItems_with_settings(args)

    -- ConstructBuilding jobs: materials were already chosen in the build picker's
    -- materials pane (or default to first-suitable), so NO item dialog here --
    -- auto-fill the job, preferring the picked item ids.
    if job.job_type==df.job_type.ConstructBuilding then
        -- RESUMING a shell that already collected its materials (an earlier
        -- attempt attached them and moved them into the building): those items
        -- are invisible to the ground/inventory scan, so re-running the search
        -- failed with "not enough materials" and left working=false forever --
        -- the job never progressed. Count attached items as filled.
        local covered=#job.job_items.elements>0
        for job_id,trg in ipairs(job.job_items.elements) do
            local need=trg.quantity
            for _,ji in ipairs(job.items) do
                if ji.job_item_idx==job_id then
                    need=need-ji.item:getTotalDimension()
                end
            end
            if need>0 then covered=false break end
        end
        if covered then
            finish_item_assign(args)     -- sets job.flags.working
            return true
        end
        if build_sel and build_sel.picks and #build_sel.picks>0 then
            local order,seen={},{}
            for _,id in ipairs(build_sel.picks) do
                for _,it in ipairs(its) do
                    if it.id==id and not seen[id] then order[#order+1]=it seen[id]=true end
                end
            end
            for _,it in ipairs(its) do
                if not seen[it.id] then order[#order+1]=it seen[it.id]=true end
            end
            its=order
        end
        local saved=settings.gui_item_select
        settings.gui_item_select=false          -- find_suitable_items auto-inserts in order
        local ok,suit,counts=pcall(find_suitable_items,job,its)
        settings.gui_item_select=saved
        if not ok then return false,"Item scan failed" end
        if not settings.build_by_items then
            for job_id in ipairs(job.job_items.elements) do
                if counts[job_id]>0 then
                    return false,"Not enough materials nearby"
                end
            end
        end
        finish_item_assign(args)
        return true
    end

    local item_suitability,item_counts=find_suitable_items(job,its)
    --[[while(#job.items>0) do --clear old job items
        job.items[#job.items-1]:delete()
        job.items:erase(#job.items-1)
    end]]

    if settings.gui_item_select and #job.job_items.elements>0 then
        if settings.quick then --TODO not so nice hack. instead of rewriting logic for job item filling i'm using one in gui dialog...
            local item_editor=advfort_items.jobitemEditor{
                job = job,
                items = item_suitability,
            }
            if item_editor:jobValid() then
                item_editor:commit()
                finish_item_assign(args)
                return true
            else
                return false, "Quick select items"
            end
        else
            local ret=advfort_items.showItemEditor(job,item_suitability)
            if ret then
                finish_item_assign(args)
                return true
            else
                print("Failed job, i'm confused...")
            end
            --end)
            return false,"Selecting items"
        end
    else
        if not settings.build_by_items then
            for job_id, trg_job_item in ipairs(job.job_items.elements) do
                if item_counts[job_id]>0 then
                    print("Not enough items for this job")
                    return false, "Not enough items for this job"
                end
            end
        end
        finish_item_assign(args)
        return true
    end

end

-- Anchor a fresh construction job at the building tile NEAREST the worker.
-- A multi-tile placement click targets the CENTER (that is where the footprint
-- anchors), so the new job's pos could sit 2 tiles from the adjacent player --
-- and DF only works within 1 of job.pos: starting a 3x3 workshop got one pulse
-- and froze until a second click re-attached the job anchored at the clicked
-- edge tile. Clamping the anchor into the footprint toward the player makes
-- the first click work from any side.
function AnchorJobAtWorker(args)
    local bld=args.building or (args.pos and dfhack.buildings.findAtTile(args.pos))
    local j,u=args.job,args.unit
    if bld and j and u then
        j.pos.x=math.max(bld.x1,math.min(u.pos.x,bld.x2))
        j.pos.y=math.max(bld.y1,math.min(u.pos.y,bld.y2))
        j.pos.z=bld.z
    end
    return true
end

-- Stray on-ground items inside a construction footprint make DF REFUSE every
-- work pulse in adventure mode -- the job timer freezes while the game spins,
-- ending in endless too-long prompts (advfort's ancient "items blocking
-- construction stuck the game"; measured live twice: sweeping the items
-- completed the build instantly). Move them to the nearest open tile just
-- outside the footprint; the job's own materials are left alone.
function ClearFootprintItems(args)
    local bld=args.building
    if not bld or bld.x1==nil then return true end
    local keep={}
    for _,ji in ipairs((args.job and args.job.items) or {}) do keep[ji.item.id]=true end
    local ta=df.tiletype.attrs
    local function drop_ok(p)
        local tt=dfhack.maps.getTileType(p)
        if not tt then return false end
        local sh=ta[tt].shape
        if sh~=df.tiletype_shape.FLOOR and sh~=df.tiletype_shape.RAMP then return false end
        local ob=dfhack.buildings.findAtTile(p)
        if ob and ob:getBuildStage()<ob:getMaxBuildStage() then return false end
        return true
    end
    for _,v in ipairs(df.global.world.items.other.IN_PLAY) do
        if v.flags.on_ground and v.pos.z==bld.z
            and v.pos.x>=bld.x1 and v.pos.x<=bld.x2
            and v.pos.y>=bld.y1 and v.pos.y<=bld.y2
            and not keep[v.id] then
            local best,bestd
            for x=bld.x1-1,bld.x2+1 do
                for y=bld.y1-1,bld.y2+1 do
                    if (x<bld.x1 or x>bld.x2 or y<bld.y1 or y>bld.y2)
                        and drop_ok({x=x,y=y,z=bld.z}) then
                        local d=math.max(math.abs(x-v.pos.x),math.abs(y-v.pos.y))
                        if not bestd or d<bestd then best,bestd={x=x,y=y,z=bld.z},d end
                    end
                end
            end
            if best then pcall(dfhack.items.moveToGround,v,best) end
        end
    end
    return true
end

function CheckAndFinishBuilding(args,bld)
    args.building=args.building or bld
    for idx,job in pairs(bld.jobs) do
        if job.job_type==df.job_type.ConstructBuilding then
            args.job=job
            args.no_job_delete=true
            -- Re-anchor the job at the tile that was CLICKED. The attached job
            -- keeps the pos it was created with (the placement click -- usually
            -- the center), and DF only works a job while the adventurer is
            -- within 1 tile of job.pos: continuing a 3x3 workshop from beside a
            -- side tile got exactly one work pulse (the initial action) and then
            -- froze. The clicked tile is part of this building and the player
            -- stands next to it, so it is always a valid anchor.
            if args.pos then
                local u=args.unit
                if u then
                    -- footprint tile nearest the WORKER: after an auto
                    -- step-aside the clicked center can be out of reach
                    job.pos:assign({x=math.max(bld.x1,math.min(u.pos.x,bld.x2)),
                                    y=math.max(bld.y1,math.min(u.pos.y,bld.y2)),
                                    z=bld.z})
                else
                    job.pos:assign(args.pos)
                end
            end
            break
        end
    end

    if args.job~=nil then
        args.pre_actions={AssignJobItems,ClearFootprintItems}
    else
        local t={items=buildings.getFiltersByType({},bld:getType(),bld:getSubtype(),bld:getCustomType())}
        args.pre_actions={dfhack.curry(setFiltersUp,t),AssignBuildingRef,AnchorJobAtWorker,ClearFootprintItems}
    end
    args.no_job_delete=true
    makeJob(args)
end
-- The entities whose recipes (workshop jobs, permitted custom workshops) are on
-- offer. Default (no -e): the adventurer's civ PLUS the civ owning the site you
-- stand in (deduped); ``-e`` alone = adventurer's civ only; ``-e NAME`` = that
-- entity. Outsider at no site falls back to the old MOUNTAIN default.
function recipe_entities()
    local ents={}
    if type(settings.set_civ)=="string" then
        local e=find_entity_civ(settings.set_civ)
        if e then table.insert(ents,e) end
        return ents
    end
    local adv=dfhack.world.getAdventurer()
    local civ=df.historical_entity.find(adv.civ_id)
    if civ then table.insert(ents,civ) end
    if settings.set_civ==nil then
        local site=inSite()
        if site then
            local owner=df.historical_entity.find(site.civ_id)
            if owner and (not civ or owner.id~=civ.id) then table.insert(ents,owner) end
        end
    end
    if #ents==0 then
        local m=find_entity_civ("MOUNTAIN")
        if m then table.insert(ents,m) end
    end
    return ents
end

-- ---- flat build picker -------------------------------------------------------
-- ONE searchable list of everything buildable, with friendly names, replacing the
-- stock nested BuildingDialog (categories of raw enum names -- near-impossible to
-- discover "wall" under constructions>Wall). Type to filter, click/Enter to pick.
-- Unknown enum names are skipped, not errors, so this survives struct renames.
local function prettify(name)   -- "NestBox" -> "Nest box", "RoadPaved" -> "Road paved"
    local s=name:gsub('(%l)(%u)','%1 %2')
    return (s:sub(1,1):upper()..s:sub(2):lower())
end
function build_picker_entries()
    local entries={}
    -- entry: label shown, filter name (deon_filter's allow/forbid lists match THESE,
    -- the same enum-name strings the stock dialog passed), type/subtype/custom ids
    local function add(label,fname,t,st,cid)
        table.insert(entries,{label=label,fname=fname,type=t,subtype=st or -1,custom=cid or -1})
    end
    local NICE={MetalsmithsForge="Metalsmith's forge",MagmaForge="Magma forge",
        Craftsdwarfs="Craftsdwarf's workshop",Masons="Mason's workshop",
        Carpenters="Carpenter's workshop",Jewelers="Jeweler's workshop",
        Bowyers="Bowyer's workshop",Mechanics="Mechanic's workshop",
        Butchers="Butcher's shop",Leatherworks="Leather works",Tanners="Tanner's shop",
        Clothiers="Clothier's shop",Dyers="Dyer's shop",Farmers="Farmer's workshop",
        Siege="Siege workshop",Kennels="Kennels",StoneFallTrap="Stone-fall trap",
        UpStair="Up stair",DownStair="Down stair",UpDownStair="Up/down stair",
        RoadDirt="Dirt road",RoadPaved="Paved road",WindowGlass="Glass window",
        WindowGem="Gem window",GrateWall="Wall grate",GrateFloor="Floor grate",
        BarsVertical="Vertical bars",BarsFloor="Floor bars",Chain="Rope/chain",
        Box="Chest/box",TractionBench="Traction bench",DisplayFurniture="Display case",
        OfferingPlace="Offering place",AxleHorizontal="Horizontal axle",
        AxleVertical="Vertical axle",GearAssembly="Gear assembly",ScrewPump="Screw pump",
        WaterWheel="Water wheel",TradeDepot="Trade depot",FarmPlot="Farm plot"}
    for i=0,df.workshop_type._last_item do
        local n=df.workshop_type[i]
        if n and n~='Custom' and n~='Tool' then
            add(NICE[n] or prettify(n),n,df.building_type.Workshop,i)
        end
    end
    for i=0,df.furnace_type._last_item do
        local n=df.furnace_type[i]
        if n and n~='Custom' then
            add(NICE[n] or prettify(n),n,df.building_type.Furnace,i)
        end
    end
    for _,n in ipairs({'Wall','Floor','Ramp','UpStair','DownStair','UpDownStair','Fortification'}) do
        local i=df.construction_type[n]
        if i then add(NICE[n] or prettify(n),n,df.building_type.Construction,i) end
    end
    for i=0,df.trap_type._last_item do
        local n=df.trap_type[i]
        if n then add(NICE[n] or prettify(n),n,df.building_type.Trap,i) end
    end
    for i=0,df.siegeengine_type._last_item do
        local n=df.siegeengine_type[i]
        if n then add(NICE[n] or prettify(n),n,df.building_type.SiegeEngine,i) end
    end
    -- plain buildings (the useful subset of building_type, with sane names)
    for _,n in ipairs({'Bed','Chair','Table','Door','Floodgate','Hatch','Box','Cabinet',
        'Coffin','Statue','Slab','Weaponrack','Armorstand','Cage','Chain','AnimalTrap',
        'NestBox','Hive','Bookcase','DisplayFurniture','OfferingPlace','TractionBench',
        'ArcheryTarget','WindowGlass','WindowGem','GrateWall','GrateFloor','BarsVertical',
        'BarsFloor','Support','Well','Bridge','RoadDirt','RoadPaved','FarmPlot',
        'TradeDepot','ScrewPump','WaterWheel','Windmill','GearAssembly','AxleHorizontal',
        'AxleVertical','Rollers','Instrument'}) do
        local i=df.building_type[n]
        if i then add(NICE[n] or prettify(n),n,i) end
    end
    -- Custom workshops: only the ones OUR recipe civs have PERMITTED_BUILDING for
    -- (cheat mode -c shows all). When exactly one civ definition knows the plan,
    -- tag it with that civ's creature -- "Shaping Tree  (high elf)" -- instead of
    -- the generic "(custom)".
    local owners={}
    for _,er in ipairs(df.global.world.raws.entities.all) do
        for _,bid in ipairs(er.workshops.permitted_building_id) do
            owners[bid]=owners[bid] or {}
            table.insert(owners[bid],er)
        end
    end
    local myperm={}
    for _,ent in ipairs(recipe_entities()) do
        for _,bid in ipairs(ent.entity_raw.workshops.permitted_building_id) do
            myperm[bid]=true
        end
    end
    for _,v in ipairs(df.global.world.raws.buildings.all) do
        if myperm[v.id] or settings.build_by_items then
            local tag='custom'
            local own=owners[v.id]
            if own and #own==1 and #own[1].creature_ids>0 then
                local cr=df.global.world.raws.creatures.all[own[1].creature_ids[0]]
                if cr then tag=cr.name[0] end
            end
            add(tag~='custom' and (v.name..'  ('..tag..')') or v.name,v.name,df.building_type.Workshop,df.workshop_type.Custom,v.id)
        end
    end
    table.sort(entries,function(a,b) return a.label:lower()<b.label:lower() end)
    return entries
end
-- getFiltersByType returns SPARSE tables (often just {flags2=...}); isSuitableItem
-- expects job_item-struct semantics where absent means -1/''. The job path never
-- notices (inserting into job.job_items fills struct defaults) -- direct table use
-- must normalize first or every item fails the very first `item_type~=-1` check.
local filter_defaults={item_type=-1,item_subtype=-1,mat_type=-1,mat_index=-1,
    flags1={},flags2={},flags3={},reaction_class='',has_material_reaction_product='',
    metal_ore=-1,min_dimension=-1,has_tool_use=-1,quantity=1}
local function normalize_filter(f)
    local out=copyall(filter_defaults)
    for k,v in pairs(f) do if k~='new' then out[k]=v end end
    return out
end

-- the materials each slot of this building can take, gathered from inventory +
-- nearby ground (the same enumeration jobs use)
function compute_slots(e)
    local slots={}
    local adv=dfhack.world.getAdventurer()
    if not adv then return slots end
    local ok,filters=pcall(buildings.getFiltersByType,{},e.type,e.subtype,e.custom)
    if not ok or not filters then return slots end
    local its=EnumItems_with_settings{unit=adv,from_pos=adv.pos}
    for _,f in ipairs(filters) do
        local nf=normalize_filter(f)
        local cands,seen={},{}
        for _,it in pairs(its) do
            if not seen[it.id] then
                seen[it.id]=true
                local ok2,suit=pcall(isSuitableItem,nf,it)
                if ok2 and (suit or settings.build_by_items) then cands[#cands+1]=it end
            end
        end
        slots[#slots+1]={cands=cands,pick=(#cands>0) and 1 or 0,qty=f.quantity or 1,
                         what=filter_desc(nf)}
    end
    return slots
end

-- "what does this slot want" in words, for slots with no matching item around:
-- material constraint + item type/subtype, plus the meaningful filter extras
function filter_desc(f)
    local parts={}
    pcall(function()
        if f.mat_type and f.mat_type~=-1 then
            local mi=dfhack.matinfo.decode(f.mat_type,f.mat_index or -1)
            if mi then parts[#parts+1]=mi:toString() end
        end
        if f.item_type and f.item_type~=-1 then
            local nm
            if f.item_subtype and f.item_subtype~=-1 then
                local ok,d=pcall(dfhack.items.getSubtypeDef,f.item_type,f.item_subtype)
                if ok and d then nm=d.name end
            end
            nm=nm or (df.item_type[f.item_type] or 'item'):lower():gsub('_',' ')
            parts[#parts+1]=nm
        end
        local fl2=f.flags2
        if fl2 and (type(fl2)=='table' and fl2.building_material
                or type(fl2)~='table' and fl2.building_material) then
            parts[#parts+1]='(building material)'
        end
        if f.reaction_class and f.reaction_class~='' then
            parts[#parts+1]='('..f.reaction_class..')'
        end
    end)
    if #parts==0 then return 'any item' end
    return table.concat(parts,' ')
end

function item_label(it)
    local ok,desc=pcall(dfhack.items.getDescription,it,0)
    return ok and desc or '?'
end

-- fill args.job's items from confirmed slots (picked item first, then the other
-- candidates until each slot's quantity is covered), then hand the items over
function fill_job_from_slots(args,slots)
    local job=args.job
    local used={}
    for job_id,trg in ipairs(job.job_items.elements) do
        local s=slots[job_id+1]           -- ipairs on df vectors is 0-based
        local need=trg.quantity
        if s then
            local order={}
            if s.cands[s.pick] then order[1]=s.cands[s.pick] end
            for _,it in ipairs(s.cands) do
                if it~=s.cands[s.pick] then order[#order+1]=it end
            end
            for _,it in ipairs(order) do
                if need<=0 then break end
                if not used[it.id] and df.item.find(it.id) then
                    used[it.id]=true
                    job.items:insert("#",{new=true,item=it,role=df.job_role_type.Reagent,job_item_idx=job_id})
                    need=need-it:getTotalDimension()
                end
            end
        end
        if need>0 and not settings.build_by_items then
            return false,"Not enough materials"
        end
    end
    finish_item_assign(args)
    return true
end

-- our picker screens must never STACK: a second open buries the first, which
-- keeps consuming clicks over its old area -- entries of the buried menu look
-- "unclickable". Close any picker already up before showing a new one.
-- Build: clicking a tile builds WHAT THE WINDOW SHOWS (the current selection,
-- which defaults to the last one picked); with nothing selected yet it opens the
-- picker instead. Clicking the "Build" row in the job window also opens the
-- picker (see the window click handler).
function AssignJobToBuild(args)
    local bld=args.building or dfhack.buildings.findAtTile(args.pos)
    args.building=bld
    args.job_type=df.job_type.ConstructBuilding
    local sel=last_building
    if bld~=nil then
        -- a planned shell already sits here. If it matches the current selection,
        -- resume it; if it is a LEFTOVER of something else (e.g. from an old failed
        -- attempt), clear it and build what the window shows instead of silently
        -- resuming the wrong building.
        local same=sel and sel.type==bld:getType()
            and (sel.subtype or -1)==bld:getSubtype()
            and (sel.custom or -1)==bld:getCustomType()
        local ok,unbuilt=pcall(function() return bld:getBuildStage()<bld:getMaxBuildStage() end)
        if not same and sel and sel.type and ok and unbuilt
            and select(1,pcall(dfhack.buildings.deconstruct,bld)) then
            dfhack.gui.showAnnouncement("Cleared a leftover planned building.",7,1)
            args.building=nil
            BuildingChosen(args,sel.type,sel.subtype,sel.custom)
        else
            CheckAndFinishBuilding(args,bld)
        end
    elseif sel and sel.type then
        BuildingChosen(args,sel.type,sel.subtype,sel.custom)
    else
        showBuildPicker()
        return false,"Pick what to build first"
    end
    return true
end
function CancelJob(unit)
    local c_job=unit.job.current_job
    if c_job then
        unit.job.current_job =nil --todo add real cancelation
        for k,v in pairs(c_job.general_refs) do
            if df.general_ref_unit_workerst:is_instance(v) then
                v:delete()
                c_job.general_refs:erase(k)
                return
            end
        end
    end
end
function ContinueJob(unit)
    local c_job=unit.job.current_job
    --no job to continue
    if not c_job then return end
    --reset suspends...
    c_job.flags.suspend=false
    for k,v in pairs(c_job.items) do --try fetching missing items
        if v.flags.is_fetching then
            unit.path.dest:assign(v.item.pos)
            return
        end
    end

    --unit.path.dest:assign(c_job.pos) -- FIXME: job pos is not always the target pos!!
    addJobAction(c_job,unit)
end
--TODO: in far far future maybe add real linking?
-- function assign_link_refs(args )
--     local job=args.job
--     --job.general_refs:insert("#",{new=df.general_ref_building_holderst,building_id=args.building.id})
--     job.general_refs:insert("#",{new=df.general_ref_building_triggertargetst,building_id=args.triggertarget.id})
--     printall(job)
-- end
-- function assign_link_roles( args )
--     if #args.job.items~=2 then
--         print("AAA FAILED!")
--         return false
--     end
--     args.job.items[0].role=df.job_role_type.LinkToTarget
--     args.job.items[1].role=df.job_role_type.LinkToTrigger
-- end
function fake_linking(lever,building,slots)
    local item1=slots[1].items[1]
    local item2=slots[2].items[1]
    if not dfhack.items.moveToBuilding(item1,lever,2) then
        qerror("failed to move item to building")
    end
    if not dfhack.items.moveToBuilding(item2,building,2) then
        qerror("failed to move item2 to building")
    end
    item2.general_refs:insert("#",{new=df.general_ref_building_triggerst,building_id=lever.id})
    item1.general_refs:insert("#",{new=df.general_ref_building_triggertargetst,building_id=building.id})

    lever.linked_mechanisms:insert("#",item2)
    pcall(function() -- if building.door_flags then
        -- Just hatches and doors
        building.door_flags.operated_by_mechanisms=true
    end)

    dfhack.gui.showAnnouncement("Linked!",COLOR_YELLOW,true)
end
function LinkBuilding(args)
    local bld=args.building or dfhack.buildings.findAtTile(args.pos)
    args.building=bld

    local lever_bld
    if lever_id then --intentionally global!
        lever_bld=df.building.find(lever_id)
        if lever_bld==nil then
            lever_id=nil
        end
    end
    if lever_bld==nil then
        if bld:getType()==df.building_type.Trap and (bld:getSubtype()==df.trap_type.Lever or bld:getSubtype()==df.trap_type.PressurePlate) then
            lever_id=bld.id
            dfhack.gui.showAnnouncement("Selected trigger for linking",COLOR_YELLOW,true)
            return
        else
            dfhack.gui.showAnnouncement("You first need a trigger",COLOR_RED,true)
        end
    else
        if lever_bld==bld then --todo more invalid targets
            dfhack.gui.showAnnouncement("Deselected trigger",COLOR_RED,true)
            lever_id = nil
            return
        end
        -- args.job_type=df.job_type.LinkBuildingToTrigger
        -- args.building=lever_bld
        -- args.triggertarget=bld
        -- args.pre_actions={
        --     dfhack.curry(setFiltersUp,{items={{quantity=1,item_type=df.item_type.TRAPPARTS},{quantity=1,item_type=df.item_type.TRAPPARTS}}}),
        --     AssignJobItems,
        --     assign_link_refs,}
        -- args.post_actions={AssignBuildingRef,assign_link_roles}
        -- makeJob(args)
        local input_filter_defaults = { --stolen from buildings lua to better customize...
            item_type = df.item_type.TRAPPARTS,
            item_subtype = -1,
            mat_type = -1,
            mat_index = -1,
            flags1 = {},
            flags2 = { allow_artifact = true },
            flags3 = {},
            flags4 = 0,
            flags5 = 0,
            reaction_class = '',
            has_material_reaction_product = '',
            metal_ore = -1,
            min_dimension = -1,
            has_tool_use = -1,
            quantity = 1
        }
        local job_items={copyall(input_filter_defaults),copyall(input_filter_defaults)}
        local its=EnumItems_with_settings(args)
        local suitability=find_suitable_items(nil,its,job_items)
        advfort_items.jobitemEditor{items=suitability,job_items=job_items,on_okay=dfhack.curry(fake_linking,lever_bld,bld)}:show()
        lever_id=nil
    end
    --one item as LinkToTrigger role
    --one item as LinkToTarget
    --genref for holder(lever)
    --genref for triggertarget

end
--[[ Plant gathering attemped fix No. 35]] --[=[ still did not work!]=]
function get_design_block_ev(blk)
    for i,v in ipairs(blk.block_events) do
        if v:getType()==df.block_square_event_type.designation_priority then
            return v
        end
    end
end
function PlantGatherFix(args)
    local pos=args.pos
    --[[args.job.flags[17]=false --??


    local block=dfhack.maps.getTileBlock(pos)
    local ev=get_design_block_ev(block)
    if ev==nil then
        block.block_events:insert("#",{new=df.block_square_event_designation_priorityst})
        ev=block.block_events[#block.block_events-1]
    end
    ev.priority[pos.x % 16][pos.y % 16]=bit32.bor(ev.priority[pos.x % 16][pos.y % 16],4000)

    args.job.item_category:assign{furniture=true,corpses=true,ammo=true} --this is actually required in fort mode
    ]]
    local path=args.unit.path
    path.dest=pos
    path.goal=df.unit_path_goal.GatherPlant
    path.path.x:insert("#",pos.x)
    path.path.y:insert("#",pos.y)
    path.path.z:insert("#",pos.z)
    printall(path)
end
-- FIX(detail-designation): DF applies Smooth/Detail results through the tile's smooth
-- DESIGNATION; without one the job runs its timer to 0 and changes nothing. Designate at job
-- creation: 1 (smooth me) on rough stone, 2 (engrave me) when the tile is already smooth.
-- And even WITH the designation DF's adv-mode completion has been seen consuming it without
-- transforming the tile -- smooth_variant + the pending_detail fallback in onIdle cover that.
function smooth_variant(tt)
    local cur=df.tiletype.attrs[tt]
    if cur.special==df.tiletype_special.SMOOTH then return nil end
    for i=df.tiletype._first_item,df.tiletype._last_item do
        local a=df.tiletype.attrs[i]
        if a.material==cur.material and a.shape==cur.shape and a.special==df.tiletype_special.SMOOTH then
            return i
        end
    end
end
-- the plain floor tiletype for a tile's material (fortification removal digs to FLOOR, but
-- DF's adv-mode Dig completion turns the fortification into a WALL instead -- measured live)
function floor_variant(tt)
    local cur=df.tiletype.attrs[tt]
    if cur.shape==df.tiletype_shape.FLOOR then return nil end
    local best
    for i=df.tiletype._first_item,df.tiletype._last_item do
        local a=df.tiletype.attrs[i]
        if a.material==cur.material and a.shape==df.tiletype_shape.FLOOR
            and a.special==df.tiletype_special.NORMAL then
            best=best or i
            if a.variant==df.tiletype_variant.VAR_1 then return i end
        end
    end
    return best
end
local function DesignateDetail(args)
    local pos=args.pos
    local block=dfhack.maps.getTileBlock(pos)
    if not block then return false,"No map block for detail designation" end
    local des=block.designation[pos.x%16][pos.y%16]
    local tt=dfhack.maps.getTileType(pos)
    local already_smooth=tt and df.tiletype.attrs[tt].special==df.tiletype_special.SMOOTH
    des.smooth=already_smooth and 2 or 1
    block.flags.designated=true
    return true
end
-- Combined Smooth / Engrave actions: one list entry each, the wall-vs-floor job type chosen
-- from the tile actually targeted. Floors keep the old stand-on-it rule; engraving demands the
-- tile is already smooth (DF's Detail jobs silently no-op on rough stone), smoothing demands
-- it is not.
local function IsSmoothableTarget(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if not tt then return false,"No tile there" end
    local shape=tile_attrs[tt].shape
    if shape==df.tiletype_shape.WALL then return true end
    local okf=IsFloor(args)
    if not okf then return false,"Only walls and floors" end
    return SameSquare(args)   -- floors: stand on the tile you work
end
local function IsRough(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if tt and tile_attrs[tt].special==df.tiletype_special.SMOOTH then
        return false,"Already smooth"
    end
    return true
end
local function IsSmoothed(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if tt and tile_attrs[tt].special==df.tiletype_special.SMOOTH then return true end
    return false,"Smooth it first"
end
-- a carved fortification digs out like rock (needs a pick); a CONSTRUCTED one must go
-- through RemoveConstruction instead, so point there rather than making a doomed Dig job
local function IsFortification(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if not tt or tile_attrs[tt].shape~=df.tiletype_shape.FORTIFICATION then
        return false,"Only fortifications"
    end
    if tile_attrs[tt].material==df.tiletype_material.CONSTRUCTION then
        return false,"Use RemoveConstruction"
    end
    return true
end
local function SmoothChooser(args)
    local tt=dfhack.maps.getTileType(args.pos)
    local wall=tt and tile_attrs[tt].shape==df.tiletype_shape.WALL
    args.job_type=wall and df.job_type.SmoothWall or df.job_type.SmoothFloor
    makeJob(args)
    return true
end
local function MarkFortRemoval(args)
    args.screen.fort_pos=copyall(args.pos)
    return true
end
-- Engrave and CarveFortification require SMOOTH stone (as fort mode does) -- but instead of
-- refusing on rough stone, they enqueue the smoothing first and remember the real job; the
-- chain continues in onIdle the moment the smooth job completes.
-- One "Dig" action for everything a pick removes: natural walls dig, constructions
-- deconstruct, fortifications dig to floor (with the tiletype fallback), stairs/ramps
-- get RemoveStairs -- chosen from the targeted tile.
local function IsDiggableTarget(args)
    local tt=dfhack.maps.getTileType(args.pos)
    if not tt then return false,"No tile there" end
    local a=tile_attrs[tt]
    if a.material==df.tiletype_material.CONSTRUCTION then return true end
    local sh=a.shape
    if sh==df.tiletype_shape.WALL or sh==df.tiletype_shape.FORTIFICATION
        or sh==df.tiletype_shape.STAIR_UP or sh==df.tiletype_shape.STAIR_DOWN
        or sh==df.tiletype_shape.STAIR_UPDOWN or sh==df.tiletype_shape.RAMP then
        return true
    end
    return false,"Nothing to dig there"
end
local function DigChooser(args)
    local tt=dfhack.maps.getTileType(args.pos)
    local a=tile_attrs[tt]
    if a.material==df.tiletype_material.CONSTRUCTION then
        args.job_type=df.job_type.RemoveConstruction
    elseif a.shape==df.tiletype_shape.FORTIFICATION then
        args.job_type=df.job_type.Dig
        MarkFortRemoval(args)
    elseif a.shape==df.tiletype_shape.WALL then
        args.job_type=df.job_type.Dig
    else
        args.job_type=df.job_type.RemoveStairs
    end
    makeJob(args)
    return true
end
local function EngraveChooser(args)
    local tt=dfhack.maps.getTileType(args.pos)
    local wall=tt and tile_attrs[tt].shape==df.tiletype_shape.WALL
    local smooth=tt and tile_attrs[tt].special==df.tiletype_special.SMOOTH
    local detail_jt=wall and df.job_type.DetailWall or df.job_type.DetailFloor
    if smooth then
        args.job_type=detail_jt
    else
        args.job_type=wall and df.job_type.SmoothWall or df.job_type.SmoothFloor
        args.screen.queued_job={job_type=detail_jt,pos=copyall(args.pos),pre_actions={DesignateDetail}}
    end
    makeJob(args)
    return true
end
local function FortificationChooser(args)
    local tt=dfhack.maps.getTileType(args.pos)
    local smooth=tt and tile_attrs[tt].special==df.tiletype_special.SMOOTH
    if smooth then
        args.job_type=df.job_type.CarveFortification
    else
        args.job_type=df.job_type.SmoothWall
        args.pre_actions={DesignateDetail}     -- the smoothing step needs its designation
        args.screen.queued_job={job_type=df.job_type.CarveFortification,pos=copyall(args.pos)}
    end
    makeJob(args)
    return true
end
-- Gather Webs cannot go through the job system: CollectWebs is a LOOM job -- DF validates
-- the queued-by building and deletes a free-standing one on its first tick (measured live:
-- job gone after one wait, with or without item refs / in_job marking). A web on the map is
-- simply a thread item with flags.spider_web set; DF's own collection amounts to clearing
-- that flag and taking the thread -- so do exactly that, through the inventory API.
local function IsWebAt(args)
    for _,v in ipairs(df.global.world.items.other.ANY_WEBS) do
        if same_xyz(v.pos,args.pos) then return true end
    end
    return false,"No web there"
end
-- skill helpers: manual jobs (webs, tree felling) take work time scaled by the
-- relevant skill and award the standard ~30xp per completed job. DF's
-- advancement costs are 500+100*level per rating.
local function skill_rating(unit,skill)
    local soul=unit.status.current_soul
    if not soul then return 0 end
    for _,sk in ipairs(soul.skills) do
        if sk.id==skill then return sk.rating end
    end
    return 0
end
local function weaving_rating(unit) return skill_rating(unit,df.job_skill.WEAVING) end
function add_skill_exp(unit,skill,amount)
    local soul=unit.status.current_soul
    if not soul then return end
    local rating,exp
    for _,sk in ipairs(soul.skills) do
        if sk.id==skill then
            sk.experience=sk.experience+amount
            while sk.experience>=500+sk.rating*100 do
                sk.experience=sk.experience-(500+sk.rating*100)
                sk.rating=sk.rating+1
            end
            rating,exp=sk.rating,sk.experience
            break
        end
    end
    if not rating then
        -- INSERT SORTED by skill id: DF keeps these vectors ordered and finds
        -- entries by binary search -- an appended out-of-order entry works for
        -- everything that scans linearly but is INVISIBLE to the skill sheet's
        -- exp lookup (and DF may re-add its own copy, leaving duplicates)
        local at='#'
        for i,sk in ipairs(soul.skills) do
            if sk.id>skill then at=i break end
        end
        soul.skills:insert(at,{new=true,id=skill,rating=0,experience=amount})
        rating,exp=0,amount
    end
    -- Mirror into the historical figure's skill profile (points = CUMULATIVE
    -- lifetime exp: 500+100*level per rating climbed, plus current progress),
    -- sorted for the same reason.
    local hf=df.historical_figure.find(unit.hist_figure_id)
    local sp=hf and hf.info and hf.info.skills
    if sp then
        local total=500*rating+100*(rating*(rating-1))//2+exp
        local idx
        for i,sid in ipairs(sp.skills) do
            if sid==skill then idx=i break end
        end
        if idx then
            sp.points[idx]=math.max(sp.points[idx],total)
        else
            local at='#'
            for i,sid in ipairs(sp.skills) do
                if sid>skill then at=i break end
            end
            sp.skills:insert(at,skill)
            sp.points:insert(at,total)
        end
    end
end
-- Jobless work is counted in WORK PULSES on the same scale adv digs use (a dig
-- runs 5 whole work actions on this build, not ticks): webs take a dig's worth,
-- felling 5x that. Each pulse costs game ticks like a dig's work action (~10,
-- shortened by the relevant skill), so the wall-time matches too.
WEB_PULSES=5
FELL_PULSES=WEB_PULSES*5
local function GatherWebsChooser(args)
    local web
    for _,v in ipairs(df.global.world.items.other.ANY_WEBS) do
        if same_xyz(v.pos,args.pos) then web=v break end
    end
    if not web then return false,"No web there" end
    args.screen.web_work={
        web_id=web.id,
        pos=copyall(args.pos),
        left=WEB_PULSES,
        step_ticks=math.max(2,10-weaving_rating(args.unit)),
        last_tick=df.global.cur_year_tick_advmode,
    }
    return true
end

-- Tree felling cannot go through the job system: DF's adventure job pump has NO
-- FellTree handler -- the job survives creation, is consumed by the first work
-- action and vanishes with the tree untouched (measured live; a manual chop
-- designation changes nothing, and even DFHack's plant plugin says grown-tree
-- removal is unsupported). So fell by hand, on the Gather Webs model: timed work
-- scaled by AXE skill, then spawn the logs and remove the tree ourselves.
-- LAYOUT (df.veg.xml): tree_info.body = array[body_height] of POINTERS, each to
-- a dim_x*dim_y array of plant_tree_tile bitfields -- index layers with [z] and
-- tiles with :_displace(i). A flat body[i] scan dereferences garbage pointers
-- past body_height and CRASHES DF (measured the hard way).
local function tree_tile(ti,z,i)
    local ok,layer=pcall(function() return ti.body[z] end)
    if not ok or not layer then return nil end
    local ok2,t=pcall(function() return layer:_displace(i) end)
    return ok2 and t or nil
end
local function count_trunks(ti)
    local n,area=0,ti.dim_x*ti.dim_y
    for z=0,ti.body_height-1 do
        for i=0,area-1 do
            local t=tree_tile(ti,z,i)
            if t and t.trunk then n=n+1 end
        end
    end
    return n
end
local function spawn_logs(adv,plant,count)
    local raw=df.global.world.raws.plants.all[plant.material]
    if not raw then return 0 end
    local mi=dfhack.matinfo.find("PLANT_MAT:"..raw.id..":WOOD")
    if not mi then return 0 end
    local made=0
    for _=1,count do
        local ok,res=pcall(dfhack.items.createItem,adv,df.item_type.WOOD,-1,mi.type,mi.index)
        if ok and res then
            local items=(type(res)=="table") and res or {res}
            for _,it in ipairs(items) do
                if type(it)=="number" then it=df.item.find(it) end
                if it and pcall(dfhack.items.moveToGround,it,copyall(plant.pos)) then
                    made=made+1
                end
            end
        end
    end
    return made
end
function do_fell(adv,plant)
    local ti=plant.tree_info
    if not ti then return 0 end
    local logs=math.max(1,math.min(count_trunks(ti),12))
    local r_x,r_y=math.floor(ti.dim_x/2),math.floor(ti.dim_y/2)
    local base_z=plant.pos.z
    local attrs=df.tiletype.attrs
    -- the floor left under the removed trunk: copy a neighboring ground tile
    local floor_tt=df.tiletype.SoilFloor1
    for _,d in ipairs({{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}}) do
        local tt=dfhack.maps.getTileType({x=plant.pos.x+d[1],y=plant.pos.y+d[2],z=base_z})
        if tt and attrs[tt].shape==df.tiletype_shape.FLOOR
            and attrs[tt].material~=df.tiletype_material.TREE then
            floor_tt=tt
            break
        end
    end
    -- clear only THIS tree's map tiles (getPlantAtTile ownership check keeps
    -- overlapping neighbor trees intact)
    for z=base_z,base_z+ti.body_height-1 do
        for y=plant.pos.y-r_y,plant.pos.y+r_y do
            for x=plant.pos.x-r_x,plant.pos.x+r_x do
                local pos={x=x,y=y,z=z}
                local blk=dfhack.maps.getTileBlock(pos)
                if blk then
                    local tt=blk.tiletype[x%16][y%16]
                    if attrs[tt].material==df.tiletype_material.TREE
                        and dfhack.maps.getPlantAtTile(pos)==plant then
                        blk.tiletype[x%16][y%16]=(z==base_z) and floor_tt or df.tiletype.OpenSpace
                    end
                end
            end
        end
    end
    -- zero the tree body so nothing re-renders the removed tiles, and mark the
    -- plant dead (the object itself is left in place -- deleting it risks
    -- dangling pointers in the map's plant vectors)
    local area=ti.dim_x*ti.dim_y
    for z=0,ti.body_height-1 do
        for i=0,area-1 do
            local t=tree_tile(ti,z,i)
            if t then
                t.trunk=false t.branches=false t.leaves=false
                t.branch_w=false t.branch_n=false t.branch_e=false t.branch_s=false
                t.trunk_is_thick=false
            end
        end
    end
    pcall(function() plant.damage_flags.dead=true end)
    return spawn_logs(adv,plant,logs)
end
local function FellTreeChooser(args)
    local plant=dfhack.maps.getPlantAtTile(args.pos)
    if not plant or not plant.tree_info then return false,"No tree there" end
    args.screen.fell_work={
        ppos=copyall(plant.pos),
        pos=copyall(args.pos),
        left=FELL_PULSES,   -- felling takes 5x a web gather
        step_ticks=math.max(2,10-skill_rating(args.unit,df.job_skill.AXE)),
        last_tick=df.global.cur_year_tick_advmode,
    }
    return true
end

-- Use Workshop: click a FINISHED building to use it -- workshops/furnaces open
-- the job menu (the same one Tab opens while standing on the shop), and the
-- other usable buildings do their thing (beds rest, chairs eat, farm plots
-- plant/harvest, traps/siege engines their menus...).
function UseWorkshopChooser(args)
    local bld=dfhack.buildings.findAtTile(args.pos)
    if not bld then return false,"No building there" end
    if bld:getBuildStage()<bld:getMaxBuildStage() then return false,"Not finished yet" end
    local m=MODES[bld:getType()]
    if not m then return false,"Nothing to use there" end
    -- DF only works (and otherwise silently culls) building jobs within 1 tile
    -- of the building's CENTER: don't open a menu whose jobs can only fail
    local u=args.unit
    if u and math.max(math.abs(u.pos.x-bld.centerx),math.abs(u.pos.y-bld.centery),
                      math.abs(u.pos.z-bld.z))>1 then
        return false,"Stand on or beside its center"
    end
    m.input(args.screen,bld)
    return true
end

-- Predicates ABOUT THE CLICKED TILE, as opposed to readiness ones ("Equip a pick"). When a
-- tile predicate fails on a MOUSE click, the click clearly was not meant for the current job
-- (Dig on a floor, Smooth on a distant floor...) -- it passes through to the game untouched,
-- which usually means walking there. Readiness failures on a valid tile still show on the
-- status line. Keyboard job attempts keep showing every refusal.
TARGET_PREDS={
    [IsWall]=true,[IsFloor]=true,[IsTree]=true,[IsPlant]=true,[IsConstruct]=true,
    [IsStairs]=true,[IsBuilding]=true,[IsUnit]=true,[IsWater]=true,
    [NotConstruct]=true,[NoConstructedBuilding]=true,[SameSquare]=true,
    [IsHardMaterial]=true,[IsFortification]=true,[IsSmoothableTarget]=true,
    [IsRough]=true,[IsSmoothed]=true,[IsDiggableTarget]=true,[IsWebAt]=true,
}
actions={
    {"Dig"                ,DigChooser,{MakePredicateWieldsItem(df.job_skill.MINING),MakeEnsureToolWielded(df.job_skill.MINING),IsDiggableTarget}},
    {"Dig Ramp"           ,df.job_type.CarveRamp,{MakePredicateWieldsItem(df.job_skill.MINING),MakeEnsureToolWielded(df.job_skill.MINING),IsWall}},
    {"Dig Channel"        ,df.job_type.DigChannel,{MakePredicateWieldsItem(df.job_skill.MINING),MakeEnsureToolWielded(df.job_skill.MINING)}},
    {"Up Staircase"       ,df.job_type.CarveUpwardStaircase,{MakePredicateWieldsItem(df.job_skill.MINING),MakeEnsureToolWielded(df.job_skill.MINING),IsWall}},
    {"Down Staircase"     ,df.job_type.CarveDownwardStaircase,{MakePredicateWieldsItem(df.job_skill.MINING),MakeEnsureToolWielded(df.job_skill.MINING)}},
    {"Bi Staircase"       ,df.job_type.CarveUpDownStaircase,{MakePredicateWieldsItem(df.job_skill.MINING),MakeEnsureToolWielded(df.job_skill.MINING)}},
    {"Smooth"             ,SmoothChooser,{IsSmoothableTarget,IsHardMaterial,IsRough},nil,{DesignateDetail}},
    {"Engrave"            ,EngraveChooser,{IsSmoothableTarget,IsHardMaterial},nil,{DesignateDetail}},
    {"Carve Fortification",FortificationChooser,{IsWall,IsHardMaterial}},
    {"CarveTrack"         ,df.job_type.CarveTrack,{},{SetCarveDir}},
    {"Fell Tree"          ,FellTreeChooser,{MakePredicateWieldsItem(df.job_skill.AXE),IsTree}},
    {"Gather Plants"      ,df.job_type.GatherPlants,{IsPlant,SameSquare},{PlantGatherFix}},
    {"Gather Webs"        ,GatherWebsChooser,{IsWebAt}},
    {"Fish"               ,df.job_type.Fish,{IsWater}},
    {"Tame Animal"        ,df.job_type.TameAnimal,{IsUnit},{SetCreatureRef}},
    {"Clean"              ,df.job_type.Clean,{}},
    {"Build"              ,AssignJobToBuild,{NoConstructedBuilding}},
    {"Link Buildings"     ,LinkBuilding,{IsBuilding}},
    {"Remove Building"    ,RemoveBuilding,{IsBuilding}},
    {"Use Workshop"       ,UseWorkshopChooser,{IsBuilding}},
}

-- "pick what to build first" (AssignJobToBuild with no selection) opens the
-- overlay's build panel
function showBuildPicker()
    if WIDGET then WIDGET:open_build_panel() end
end

MOVEMENT_KEYS = {
    A_CARE_MOVE_N = { 0, -1, 0 }, A_CARE_MOVE_S = { 0, 1, 0 },
    A_CARE_MOVE_W = { -1, 0, 0 }, A_CARE_MOVE_E = { 1, 0, 0 },
    A_CARE_MOVE_NW = { -1, -1, 0 }, A_CARE_MOVE_NE = { 1, -1, 0 },
    A_CARE_MOVE_SW = { -1, 1, 0 }, A_CARE_MOVE_SE = { 1, 1, 0 },
    --[[A_MOVE_N = { 0, -1, 0 }, A_MOVE_S = { 0, 1, 0 },
    A_MOVE_W = { -1, 0, 0 }, A_MOVE_E = { 1, 0, 0 },
    A_MOVE_NW = { -1, -1, 0 }, A_MOVE_NE = { 1, -1, 0 },
    A_MOVE_SW = { -1, 1, 0 }, A_MOVE_SE = { 1, 1, 0 },--]]
    CUSTOM_CTRL_D = { 0, 0, -1 },
    CUSTOM_CTRL_E = { 0, 0, 1 },
    CURSOR_UP_Z_AUX = { 0, 0, 1 }, CURSOR_DOWN_Z_AUX = { 0, 0, -1 },
    A_MOVE_SAME_SQUARE={0,0,0},
    SELECT={0,0,0},
}
ALLOWED_KEYS={
    A_MOVE_N=true,A_MOVE_S=true,A_MOVE_W=true,A_MOVE_E=true,A_MOVE_NW=true,
    A_MOVE_NE=true,A_MOVE_SW=true,A_MOVE_SE=true,A_STANCE=true,SELECT=true,A_MOVE_DOWN_AUX=true,
    A_MOVE_UP_AUX=true,A_LOOK=true,CURSOR_DOWN=true,CURSOR_UP=true,CURSOR_LEFT=true,CURSOR_RIGHT=true,
    CURSOR_UPLEFT=true,CURSOR_UPRIGHT=true,CURSOR_DOWNLEFT=true,CURSOR_DOWNRIGHT=true,A_CLEAR_ANNOUNCEMENTS=true,
    CURSOR_UP_Z=true,CURSOR_DOWN_Z=true,
}
function moddedpos(pos,delta)
    return {x=pos.x+delta[1],y=pos.y+delta[2],z=pos.z+delta[3]}
end
-- ---- menu layout (indexes into actions) ----------------------------------

local function build_label()
    local lb = last_building
    if not (lb and lb.type) then return 'Build...' end
    local t = lb.type
    local name
    if t == df.building_type.Workshop then
        if lb.subtype == df.workshop_type.Custom then
            for _, v in ipairs(df.global.world.raws.buildings.all) do
                if v.id == lb.custom then name = v.name break end
            end
        else name = df.workshop_type[lb.subtype] end
    elseif t == df.building_type.Furnace then name = df.furnace_type[lb.subtype]
    elseif t == df.building_type.Trap then name = df.trap_type[lb.subtype]
    elseif t == df.building_type.Construction then name = df.construction_type[lb.subtype]
    end
    name = name or df.building_type[t] or '?'
    return 'Build: '..tostring(name):sub(1, 16)
end

local LAYOUT = {
    {{1,'Dig'},{2,' [Ramp]'},{3,' [Channel]'}},
    {{4,'[Up]'},{5,' [Down]'},{6,' [Bi]'},{label=' Staircase',click=6}},
    {},
    {{7}},
    {{8}},
    {{9}},
    {{10}},
    {},
    {{11}},
    {{12}},
    {{13}},
    {{14}},
    {{15}},
    {{16}},
    {},
    {{17,build_label}},
    {{18}},
    {{19}},
    {{20}},
}

-- ---- modal per-item material picker ------------------------------------------
-- Takes COMPLETE focus: nothing else can be interacted with until an item is
-- chosen or it is canceled with Esc or right-click. Outside clicks are consumed.

-- hotkeys for the first 36 material rows: letters, then numbers
local IP_HOTKEYS = 'abcdefghijklmnopqrstuvwxyz1234567890'

ItemPicker = defclass(ItemPicker, gui.Screen)
ItemPicker.focus_path = 'advfort2/item-picker'

function ItemPicker:init(iargs)
    self.spawn_ms = dfhack.getTickCount()   -- absorb the click that opened us
    self.title = iargs.title or 'Choose'
    self.entries = iargs.entries
    self.on_pick = iargs.on_pick
    self.scroll = 0
end

function ItemPicker:geom()
    local gps = df.global.gps
    local n = math.max(1, #self.entries)
    local top = 10
    local h = math.max(8, gps.dimy-20)   -- fill, minus 10 rows top and bottom
    local rows = h-2
    local max_cols = math.max(1, math.floor((gps.dimx-AUX_L-3)/ITEM_COL_W))
    local cols = math.min(max_cols, math.max(1, math.ceil(n/rows)))
    return AUX_L, top, cols*ITEM_COL_W+2, h, cols, rows
end

function ItemPicker:max_scroll(cols, rows)
    return math.max(0, math.ceil(#self.entries/cols)-rows)
end

function ItemPicker:onRenderBody(dc)
    self:renderParent()
    local l, t, w, h, cols, rows = self:geom()
    if self.scroll > self:max_scroll(cols, rows) then self.scroll = self:max_scroll(cols, rows) end
    draw_box(dc, l, t, w, h, self.title)
    local ms = self:max_scroll(cols, rows)
    if ms > 0 then
        dc:seek(l+w-10, t):pen(self.scroll > 0 and COLOR_LIGHTCYAN or COLOR_DARKGREY):string(' [-] ')
        dc:seek(l+w-5, t):pen(self.scroll < ms and COLOR_LIGHTCYAN or COLOR_DARKGREY):string('[+] ')
    end
    for r = 0, rows-1 do
        for c = 0, cols-1 do
            local idx = (self.scroll+r)*cols+c+1
            local e = self.entries[idx]
            if e then
                local hk = (idx <= #IP_HOTKEYS) and (IP_HOTKEYS:sub(idx, idx)..': ') or '   '
                local pen = e.current and COLOR_LIGHTGREEN or COLOR_WHITE
                dc:seek(l+1+c*ITEM_COL_W, t+1+r):pen(e.current and COLOR_LIGHTGREEN or COLOR_LIGHTCYAN)
                    :string(hk)
                dc:seek(l+1+c*ITEM_COL_W+#hk, t+1+r):pen(pen)
                    :string(e.label:sub(1, ITEM_COL_W-1-#hk))
            end
        end
    end
end

function ItemPicker:pick(idx)
    local e = self.entries[idx]
    if not e then return end
    -- act now, dismiss on the button RELEASE: dismissing on the press hands the
    -- still-held click to whatever sits beneath
    self.on_pick(e.data)
    local ok, held = pcall(function() return df.global.enabler.mouse_lbut end)
    if ok and held == 1 then self.done_pending = true else self:dismiss() end
end

function ItemPicker:onIdle()
    if self.done_pending then
        local ok, held = pcall(function() return df.global.enabler.mouse_lbut end)
        self.done_grace = (self.done_grace or 30)-1
        if (ok and held == 0) or self.done_grace <= 0 then self:dismiss() end
        return
    end
    if self.cancel_pending then
        local ok, held = pcall(function() return df.global.enabler.mouse_rbut end)
        self.cancel_grace = (self.cancel_grace or 30)-1
        if (ok and held == 0) or self.cancel_grace <= 0 then self:dismiss() end
    end
end

function ItemPicker:onInput(keys)
    if self.done_pending or self.cancel_pending then return end
    if keys.LEAVESCREEN then
        self:dismiss()
        return
    end
    if keys._MOUSE_R or keys._MOUSE_R_DOWN then
        self.cancel_pending = true
        return
    end
    -- the first 36 rows answer to their hotkey (letters, then numbers)
    if keys._STRING and keys._STRING >= 33 then
        local pos = IP_HOTKEYS:find(string.char(keys._STRING):lower(), 1, true)
        if pos and pos <= #self.entries then self:pick(pos) end
        return
    end
    local l, t, w, h, cols, rows = self:geom()
    if keys.SELECT then
        -- Enter keeps the current pick (or takes the first row)
        for i, e in ipairs(self.entries) do
            if e.current then self:pick(i) return end
        end
        self:pick(1)
        return
    end
    if keys.CONTEXT_SCROLL_UP then
        self.scroll = math.max(0, self.scroll-1)
        return
    elseif keys.CONTEXT_SCROLL_DOWN then
        self.scroll = math.min(self:max_scroll(cols, rows), self.scroll+1)
        return
    end
    if keys._MOUSE_L then
        if dfhack.getTickCount()-(self.spawn_ms or 0) < 250 then return end
        local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
        if mx >= l and mx < l+w and my >= t and my < t+h then
            if my == t and self:max_scroll(cols, rows) > 0 then
                if mx >= l+w-10 and mx <= l+w-6 then self.scroll = math.max(0, self.scroll-1)
                elseif mx >= l+w-5 and mx <= l+w-2 then
                    self.scroll = math.min(self:max_scroll(cols, rows), self.scroll+1)
                end
                return
            end
            local r, cx = my-t-1, mx-l-1
            if r >= 0 and r < rows and cx >= 0 and cx < cols*ITEM_COL_W then
                local idx = (self.scroll+r)*cols+(cx//ITEM_COL_W)+1
                if self.entries[idx] then self:pick(idx) end
            end
        end
        return   -- MODAL: outside clicks are consumed, not passed anywhere
    end
end

-- ---- the overlay -------------------------------------------------------------

AdvFort = defclass(AdvFort, overlay.OverlayWidget)
AdvFort.ATTRS{
    desc='adv/fort: job menu, panels and job engine for adventure mode',
    default_pos={x=1, y=2},
    default_enabled=true,
    viewscreens={'dungeonmode/Default', 'dungeonmode/Look'},
    frame={w=1, h=1},
    overlay_onupdate_max_freq_seconds=0,
}


-- ---- workshop/building actions (from adv/advfort, as AdvFort methods) ------
function setFiltersUp(specific,args)
    local job=args.job
    if specific.job_fields~=nil then
        job:assign(specific.job_fields)
    end
    --printall(specific)
    for _,v in ipairs(specific.items) do
        --printall(v)
        local filter=v
        filter.new=true
        job.job_items.elements:insert("#",filter)
    end
    return true
end
function onWorkShopJobChosen(args,idx,choice)
    args.pos=args.from_pos
    args.building=args.building or dfhack.buildings.findAtTile(args.pos)
    args.job_type=choice.job_id
    args.post_actions={AssignBuildingRef}
    args.pre_actions={dfhack.curry(setFiltersUp,choice.filter),AssignJobItems}
    makeJob(args)
end
function siegeWeaponActionChosen(args,actionid)
    local building=args.building
    if actionid==1 then --Turn
        building.facing=(args.building.facing+1)%4
        return
    elseif actionid==2 then --Load
        local action=df.job_type.LoadBallista
        if building:getSubtype()==df.siegeengine_type.Catapult then
            action=df.job_type.LoadCatapult
            args.pre_actions={dfhack.curry(setFiltersUp,{items={{quantity=1}}}),AssignJobItems} --TODO just boulders here
        else
            args.pre_actions={dfhack.curry(setFiltersUp,{items={{quantity=1,item_type=df.SIEGEAMMO}}}),AssignJobItems}
        end
        args.job_type=action
        args.unit=dfhack.world.getAdventurer()
        local from_pos=copyall(args.unit.pos)
        args.from_pos=from_pos
        args.pos=from_pos
    elseif actionid==3 then --Fire
        local action=df.job_type.FireBallista
        if building:getSubtype()==df.siegeengine_type.Catapult then
            action=df.job_type.FireCatapult
        end
        args.job_type=action
        args.unit=dfhack.world.getAdventurer()
        local from_pos=copyall(args.unit.pos)
        args.from_pos=from_pos
        args.pos=from_pos
    end
    args.post_actions={AssignBuildingRef}
    makeJob(args)
end
function putItemToBuilding(building,item)
    if building:getType()==df.building_type.Table then
        dfhack.items.moveToBuilding(item,building,0)
    else
        local container=building.contained_items[0].item --todo maybe iterate over all, add if usemode==2?
        dfhack.items.moveToContainer(item,container)
    end
end
function AdvFort:openPutWindow(building)
    local adv=dfhack.world.getAdventurer()
    local items=EnumItems{pos=adv.pos,unit=adv,
        inv={[df.inv_item_role_type.Hauled]=true,--[df.inv_item_role_type.Worn]=true,
             [df.inv_item_role_type.Weapon]=true,},deep=true}
    local choices={}
    for k,v in pairs(items) do
        table.insert(choices,{text=dfhack.items.getDescription(v,0),item=v})
    end
    dialog.showListPrompt("Item choice", "Choose item to put into:", COLOR_WHITE,choices,function (idx,choice) putItemToBuilding(building,choice.item) end)
end
function AdvFort:openSiegeWindow(building)
    local args={building=building,screen=self}
    dialog.showListPrompt("Engine job choice", "Choose what to do:",COLOR_WHITE,{"Turn","Load","Fire"},
        dfhack.curry(siegeWeaponActionChosen,args))
end
function AdvFort:onWorkShopButtonClicked(building,index,choice)
    local adv=dfhack.world.getAdventurer()
    local args={unit=adv,building=building}
    if choice.resume then
        local bj=choice.resume
        if adv.job.current_job then
            self:set_status(("Busy: %s"):format(job_name(adv.job.current_job)))
            return
        end
        local okf,found=pcall(df.job.find,bj.id)
        if not okf or not found then
            self:set_status("That job is gone")
            return
        end
        for ri=#bj.general_refs-1,0,-1 do
            local r=bj.general_refs[ri]
            if r:getType()==df.general_ref_type.UNIT_WORKER then
                r:delete()
                bj.general_refs:erase(ri)
            end
        end
        AssignUnitToJob(bj,adv,copyall(adv.pos))
        self:wait_long_start()
        return
    end
    -- ALWAYS re-resolve the button by its LABEL at press time. Stored pointers
    -- go stale whenever DF refills the sidebar between menu-open and click --
    -- pressing one then triggers whatever recipe now occupies that slot ("I
    -- clicked shield, it made a training sword"). A fill done RIGHT HERE yields
    -- pointers that are valid for the immediate press.
    self:setupFields(choice.entity or nil)
    building:fillSidebarMenu()
    choice.button=nil
    for _,btn in pairs(df.global.game.main_interface.building.button) do
        if utils.call_with_string(btn,"text")==choice.text then
            choice.button=btn
            break
        end
    end
    if not choice.button then
        self:set_status("That job is no longer offered")
        return
    end
    self.menu_entity=choice.entity   -- category browsing stays on this entity
    if df.interface_button_building_new_jobst:is_instance(choice.button) then
        -- one task at a time: silently replacing the current job ORPHANS it
        -- mid-progress, and the abandoned job then blocks the whole workshop
        if adv.job.current_job then
            self:set_status(("Busy: %s"):format(job_name(adv.job.current_job)))
            dfhack.gui.showAnnouncement("You are already working on something -- click the status line to cancel it.",COLOR_LIGHTRED,true)
            return
        end
        local before=#building.jobs
        choice.button:press()
        -- CUSTOM-REACTION recipes (display cases, altars, modded recipes...):
        -- press() silently creates NOTHING in adventure mode. Hand-build the
        -- CustomReaction job from the reaction raws instead -- the reaction
        -- code is the button's mstring verbatim.
        if #building.jobs==before
            and choice.button.jobtype==df.job_type.CustomReaction
            and choice.button.mstring~='' then
            local reaction
            for _,r in ipairs(df.global.world.raws.reactions.reactions) do
                if r.code==choice.button.mstring then reaction=r break end
            end
            if reaction then
                local nj=df.job:new()
                nj.id=df.global.job_next_id
                df.global.job_next_id=df.global.job_next_id+1
                nj.job_type=df.job_type.CustomReaction
                nj.reaction_name=reaction.code
                nj.completion_timer=-1
                nj.pos:assign({x=building.centerx,y=building.centery,z=building.z})
                dfhack.job.linkIntoWorld(nj,true)
                building.jobs:insert('#',nj)
                nj.general_refs:insert('#',{new=df.general_ref_building_holderst,building_id=building.id})
                for _,re in ipairs(reaction.reagents) do
                    local ok,f=pcall(function()
                        return {new=true,quantity=re.quantity or 1,
                            item_type=re.item_type,item_subtype=re.item_subtype,
                            mat_type=re.mat_type,mat_index=re.mat_index,
                            reaction_class=re.reaction_class,
                            has_material_reaction_product=re.has_material_reaction_product,
                            metal_ore=re.metal_ore}
                    end)
                    if ok then nj.job_items.elements:insert('#',f) end
                end
            end
        end
        if #building.jobs>before then
            local job=building.jobs[#building.jobs-1]
            args.job=job
            args.pos=adv.pos
            args.from_pos=adv.pos
            args.screen=self
            if settings.df_assign then
                makeJob(args)
            else
                self:openJobMaterials(args)   -- the shared materials picker
            end
        else
            self:set_status(("Cannot start: %s"):format(choice.text or 'that recipe'))
        end
    elseif df.interface_button_building_category_selectorst:is_instance(choice.button) or
        df.interface_button_building_material_selectorst:is_instance(choice.button) then
        choice.button:press()
        self:openShopWindowButtoned(building,true)
    end
end

function AdvFort:openShopWindow(building)
    local adv=dfhack.world.getAdventurer()

    local filter_pile=workshopJobs.getJobs(building:getType(),building:getSubtype(),building:getCustomType())
    if filter_pile then
        local state={unit=adv,from_pos=copyall(adv.pos),building=building,screen=self,bld=building}
        local choices={}
        for k,v in pairs(filter_pile) do
            table.insert(choices,{job_id=0,text=v.name:lower(),filter=v})
        end
        local building_name=utils.call_with_string(building,"getName") or "Workshop"
        dialog.showListPrompt(building_name.." job choice", "Choose what to make",COLOR_WHITE,choices,dfhack.curry(onWorkShopJobChosen,state)
            ,nil, nil,true)
    else
        qerror("No jobs for this workshop")
    end
end
function track_stop_configure(bld) --TODO: dedicated widget with nice interface and current setting display
    local dump_choices={
        {text="no dumping"},
        {text="N",x=0,y=-1},--{t="NE",x=1,y=-1},
        {text="E",x=1,y=0},--{t="SE",x=1,y=1},
        {text="S",x=0,y=1},--{t="SW",x=-1,y=1},
        {text="W",x=-1,y=0},--{t="NW",x=-1,y=-1}
    }
    local choices={"Friction","Dumping"}
    local function chosen(index,choice)
        if choice.text=="Friction" then
            dialog.showInputPrompt("Choose friction","Friction",nil,tostring(bld.track_stop_info.friction),function ( txt )
                local num=tonumber(txt) --TODO allow only vanilla friction settings
                if num then
                    bld.track_stop_info.friction=num
                end
            end)
        else
            dialog.showListPrompt("Dumping direction", "Choose dumping:",COLOR_WHITE,dump_choices,function ( index,choice)
                if choice.x then
                    bld.track_stop_info.track_flags.use_dump=true
                    bld.track_stop_info.dump_x_shift=choice.x
                    bld.track_stop_info.dump_y_shift=choice.y
                else
                    bld.track_stop_info.track_flags.use_dump=false
                end
            end)
        end
    end
    dialog.showListPrompt("Track stop configure", "Choose what to change:",COLOR_WHITE,choices,chosen)
end
function AdvFort:armCleanTrap(building)
    local adv=dfhack.world.getAdventurer()
    --[[
    Lever,
        PressurePlate,
        CageTrap,
        StoneFallTrap,
        WeaponTrap,
        TrackStop
    --]]
    if building.state==0 then
        --CleanTrap
        --[[        LoadCageTrap,
        LoadStoneTrap,
        LoadWeaponTrap,
        ]]
        if building.trap_type==df.trap_type.Lever then
            --link
            return
        end
        --building.trap_type==df.trap_type.PressurePlate then
        --settings/link
        local args={unit=adv,post_actions={AssignBuildingRef},pos=adv.pos,from_pos=adv.pos,
        building=building,job_type=df.job_type.CleanTrap}
        if building.trap_type==df.trap_type.CageTrap then
            args.job_type=df.job_type.LoadCageTrap
            local job_filter={items={{quantity=1,item_type=df.item_type.CAGE}} }
            args.pre_actions={dfhack.curry(setFiltersUp,job_filter),AssignJobItems}

        elseif building.trap_type==df.trap_type.StoneFallTrap then
            args.job_type=df.job_type.LoadStoneTrap
            local job_filter={items={{quantity=1,item_type=df.item_type.BOULDER}} }
            args.pre_actions={dfhack.curry(setFiltersUp,job_filter),AssignJobItems}
        elseif building.trap_type==df.trap_type.TrackStop then
            --set dump and friction
            track_stop_configure(building)
            return
        else
            print("TODO: trap type:"..df.trap_type[building.trap_type])
            return
        end
        args.screen=self
        makeJob(args)
    end
end
--luacheck: in=df.building_hivest out=none
function AdvFort:hiveActions(building)
    local adv=dfhack.world.getAdventurer()
    local args={unit=adv,post_actions={AssignBuildingRef},pos=adv.pos,
    from_pos=adv.pos,job_type=df.job_type.InstallColonyInHive,building=building,screen=self}
    local job_filter={items={{quantity=1,item_type=df.item_type.VERMIN}} }
            args.pre_actions={dfhack.curry(setFiltersUp,job_filter),AssignJobItems}
    makeJob(args)
    --InstallColonyInHive,
    --CollectHiveProducts,
end
function AdvFort:operatePump(building)
    --TODO: low priotity, but would be nice to have the job auto cleanup (i.e. one work would only pump and then you could press it again)
    local adv=dfhack.world.getAdventurer()
    local set_operate=function ( args )
        args.building.pump_manually=true
    end
    makeJob{unit=adv,building=building,post_actions={AssignBuildingRef,set_operate},pos=adv.pos,from_pos=adv.pos,job_type=df.job_type.OperatePump,screen=self}
end
function AdvFort:farmPlot(building)
    local adv=dfhack.world.getAdventurer()
    local do_harvest=false
    for id, con_item in pairs(building.contained_items) do
        if con_item.use_mode==2 and con_item.item:getType()==df.item_type.PLANT then
            if same_xyz(adv.pos,con_item.item.pos) then
                do_harvest=true
            end
        end
    end
    --check if there tile is without plantseeds,add job

    local args={unit=adv,pos=adv.pos,from_pos=adv.pos,screen=self}
    if do_harvest then
        args.job_type=df.job_type.HarvestPlants
        args.post_actions={AssignBuildingRef}
    else
        local seedjob={items={{quantity=1,item_type=df.item_type.SEEDS}}}
        args.job_type=df.job_type.PlantSeeds
        args.pre_actions={dfhack.curry(setFiltersUp,seedjob)}
        args.post_actions={AssignBuildingRef,AssignJobItems}
    end

    makeJob(args)
end
--luacheck: in=df.building_bedst out=none
function AdvFort:bedActions(building)
    local adv=dfhack.world.getAdventurer()
    local args={unit=adv,pos=adv.pos,from_pos=adv.pos,screen=self,building=building,
    job_type=df.job_type.Sleep,post_actions={AssignBuildingRef}}
    makeJob(args)
end
--luacheck: in=df.building_chairst out=none
function AdvFort:chairActions(building)
    local adv=dfhack.world.getAdventurer()
    local eatjob={items={{quantity=1,item_type=df.item_type.FOOD}}}
    local args={unit=adv,pos=adv.pos,from_pos=adv.pos,screen=self,job_type=df.job_type.Eat,building=building,
        pre_actions={dfhack.curry(setFiltersUp,eatjob),AssignJobItems},post_actions={AssignBuildingRef}}
    makeJob(args)
end
MODES={
    [df.building_type.Table]={ --todo filters...
        name="Put items",
        input=function(scr,bld) return scr:openPutWindow(bld) end,
    },
    [df.building_type.Coffin]={
        name="Put items",
        input=function(scr,bld) return scr:openPutWindow(bld) end,
    },
    [df.building_type.Box]={
        name="Put items",
        input=function(scr,bld) return scr:openPutWindow(bld) end,
    },
    [df.building_type.Weaponrack]={
        name="Put items",
        input=function(scr,bld) return scr:openPutWindow(bld) end,
    },
    [df.building_type.Armorstand]={
        name="Put items",
        input=function(scr,bld) return scr:openPutWindow(bld) end,
    },
    [df.building_type.Cabinet]={
        name="Put items",
        input=function(scr,bld) return scr:openPutWindow(bld) end,
    },
    [df.building_type.Workshop]={
        name="Workshop menu",
        input=function(scr,bld) return scr:openShopWindowButtoned(bld) end,
    },
    [df.building_type.Furnace]={
        name="Workshop menu",
        input=function(scr,bld) return scr:openShopWindowButtoned(bld) end,
    },
    [df.building_type.SiegeEngine]={
        name="Siege menu",
        input=function(scr,bld) return scr:openSiegeWindow(bld) end,
    },
    [df.building_type.FarmPlot]={
        name="Plant/Harvest",
        input=function(scr,bld) return scr:farmPlot(bld) end,
    },
    [df.building_type.ScrewPump]={
        name="Operate Pump",
        input=function(scr,bld) return scr:operatePump(bld) end,
    },
    [df.building_type.Trap]={
        name="Interact",
        input=function(scr,bld) return scr:armCleanTrap(bld) end,
    },
    [df.building_type.Hive]={
        name="Hive actions",
        input=function(scr,bld) return scr:hiveActions(bld) end,
    },
    [df.building_type.Bed]={
        name="Rest",
        input=function(scr,bld) return scr:bedActions(bld) end,
    },
    [df.building_type.Chair]={
        name="Eat",
        input=function(scr,bld) return scr:chairActions(bld) end,
    },
}
function find_entity_civ( raw_code )
    for i,v in ipairs(df.global.world.entities.all) do
        if v.type==df.historical_entity_type.Civilization and
            v.entity_raw.code==raw_code then
            return v
        end
    end
end
function AdvFort:menuEntities()
    return recipe_entities()
end
function AdvFort:setupFields(entity)
    local ui=df.global.plotinfo

    local adv=dfhack.world.getAdventurer()
    if entity then
        ui.civ_id=entity.id
        ui.race_id=entity.race
        ui.main.fortress_entity=entity
    elseif settings.set_civ==true or settings.set_civ==nil then
        -- adventurer's civ (the civ+site default resolves per-entity via the
        -- `entity` argument; this branch also covers -e with no name)
        local civ=df.historical_entity.find(adv.civ_id) or find_entity_civ("MOUNTAIN")
        ui.civ_id=civ and civ.id or adv.civ_id
        ui.race_id=civ and civ.race or adv.race
        ui.main.fortress_entity=civ
    else
        local civ_entity=find_entity_civ(settings.set_civ)
        ui.civ_id=civ_entity.id
        ui.race_id=civ_entity.race
        ui.main.fortress_entity=civ_entity
    end

    local nem=dfhack.units.getNemesis(adv)
    if nem then
        local links=nem.figure.entity_links
        for _,link in ipairs(links) do
            local hist_entity=df.historical_entity.find(link.entity_id)
            if hist_entity and hist_entity.type==df.historical_entity_type.SiteGovernment then
                ui.group_id=link.entity_id
                break
            end
        end
    end
    local site= inSite()
    if site then
        ui.site_id=site.id
    end
end
-- put a wielded-for-the-job tool (and whatever it displaced) back where it was
function AdvFort:restore_tool_swap()
    local sw=self.tool_swap
    if not sw then return end
    self.tool_swap=nil
    local unit=dfhack.world.getAdventurer()
    if not unit then return end
    local tool=df.item.find(sw.tool_id)
    if tool then
        if sw.old then
            pcall(dfhack.items.moveToInventory,tool,unit,sw.old.mode,sw.old.bp)
        else
            -- came out of a container: strapping it to the body is the safe,
            -- always-valid place (re-bagging can fail on a full container)
            pcall(dfhack.items.moveToInventory,tool,unit,10,0)
        end
    end
    local disp=sw.displaced_id and df.item.find(sw.displaced_id)
    if disp then pcall(dfhack.items.moveToInventory,disp,unit,1,sw.grasp) end
end
function AdvFort:ensure_dims(update_frame)
    local ir = gui.get_interface_rect()
    local w, h = ir.x2-ir.x1+1, ir.y2-ir.y1+1
    self.ir_x1, self.ir_y1, self.diw, self.dih = ir.x1, ir.y1, w, h
    if update_frame and (self.frame.w ~= w or self.frame.h ~= h
            or self.frame.l ~= 0 or self.frame.t ~= 0) then
        self.frame = {l=0, t=0, w=w, h=h}
        self:updateLayout(gui.ViewRect{rect=ir})
    end
end

function AdvFort:mouse_lxy()
    local gps = df.global.gps
    return gps.mouse_x-(self.ir_x1 or 0), gps.mouse_y-(self.ir_y1 or 0)
end

function AdvFort:icon_row()
    return math.floor(((self.dih or df.global.gps.dimy)-1)/2)
end

-- screen facade (what makeJob/choosers/MODES handlers expect of args.screen)
function AdvFort:set_status(msg) self.status_msg = msg end
function AdvFort:wait_tick() feed('A_SHORT_WAIT') end
function AdvFort:update_site() self.current_site = inSite() end
function AdvFort:wait_long_start()
    self.long_wait_timer = nil
    self.long_wait = true
    self.hold_resume = nil
    self.wait_started = dfhack.getTickCount()
end
function AdvFort:cancel_wait(hold)
    self.long_wait_timer = nil
    self.long_wait = false
    if hold then self.hold_resume = true end
end

-- ---- geometry + drawing ------------------------------------------------------

function AdvFort:menu_geom()
    local n = #LAYOUT
    local h = n+4    -- border, rows, separator, status, border
    local top = math.max(0, math.floor(((self.dih or df.global.gps.dimy)-h)/2))
    return 0, top, MENU_W, h, n
end

-- Where changes STICK (per Rumrusher's testing): buildings save everywhere,
-- constructions don't, and digging is undone anywhere but player forts, caves,
-- camps, lairs/monster shrines and important locations. The pre-gen civ sites
-- (elven retreats, fortresses, dark fortresses, towns...) and the open
-- wilderness all revert.
local PERSIST_SITE_TYPES = utils.invert{
    df.world_site_type.PlayerFortress,
    df.world_site_type.Cave,
    df.world_site_type.LairShrine,
    df.world_site_type.ImportantLocation,
    df.world_site_type.Camp,
}
function AdvFort:persists_here()
    local site = self.current_site
    return site ~= nil and PERSIST_SITE_TYPES[site.type] ~= nil
end

function AdvFort:draw_menu(dc)
    local l, t, w, h, n = self:menu_geom()
    local site = self.current_site
    local title = site and dfhack.translation.translateName(site.name) or nil
    draw_box(dc, l, t, w, h, title, COLOR_WHITE)
    dc:seek(l+w-5, t):pen(COLOR_LIGHTCYAN):string('[-]')
    for li, line in ipairs(LAYOUT) do
        local y = t+li
        local x = l+3
        local line_selected = false
        for _, seg in ipairs(line) do
            seg._x1, seg._x2 = nil, nil
            local txt, pen
            if seg.label then
                txt, pen = seg.label, COLOR_GREY
                if seg.click then seg._x1, seg._x2 = x, x+#txt-1 end
            elseif seg[1] then
                txt = seg[2] or actions[seg[1]][1]
                if type(txt) == 'function' then txt = txt() end
                local sel = (seg[1] == MODE_IDX+1)
                pen = sel and COLOR_LIGHTGREEN or COLOR_GREY
                if sel then line_selected = true end
                seg._x1, seg._x2 = x, x+#txt-1
            end
            if txt then
                dc:seek(x, y):pen(pen):string(txt:sub(1, math.max(0, l+w-1-x)))
                x = x+#txt
            end
        end
        if line_selected then
            dc:seek(l+1, y):pen(COLOR_LIGHTGREEN):string(string.char(26))
        end
    end
    dc:seek(l+1, t+n+1):pen{fg=COLOR_GREY, bg=COLOR_BLACK}
        :string(string.rep(string.char(196), w-2))
    local adv = dfhack.world.getAdventurer()
    local cj = adv and adv.job.current_job
    local stat, pen
    if cj then
        stat = ('%s (%d)'):format(job_name(cj), cj.completion_timer)
        pen = COLOR_YELLOW
    elseif self.web_work then
        stat, pen = ('Gather Webs working (%d)'):format(self.web_work.left), COLOR_YELLOW
    elseif self.fell_work then
        stat, pen = ('Fell Tree working (%d)'):format(self.fell_work.left), COLOR_YELLOW
    else
        stat, pen = self.status_msg or '', COLOR_LIGHTRED
    end
    if settings.quick then stat = stat..' *' end
    dc:seek(l+1, t+n+2):pen(pen):string(stat:sub(1, w-2))
    if not self:persists_here() then
        local msg = "won't persist"
        dc:seek(l+math.max(1, math.floor((w-#msg)/2)), t+h-1)
            :pen(COLOR_YELLOW):string(msg)
    end
end

-- every aux panel fills the screen vertically, minus the top and bottom 10 rows
local AUX_TOP = 10
function AdvFort:aux_geom()
    local a = self.aux
    local t = AUX_TOP
    local h = math.max(8, (self.dih or 25)-2*AUX_TOP)
    if a.kind == 'mats' then
        return AUX_L, t, 48, h, 1, #a.slots
    end
    local slots_h = 0
    if a.kind == 'build' then
        slots_h = math.max(a.slots and #a.slots or 0, 1)+2   -- separator+rows+hint
    end
    local n = math.max(1, #a.entries)
    local max_cols = math.max(1, math.floor(((self.diw or 80)-AUX_L-2)/COL_W))
    local rows = math.max(3, h-2-slots_h)
    local cols = math.min(max_cols, math.max(1, math.ceil(n/rows)))
    return AUX_L, t, cols*COL_W+2, h, cols, rows
end

function AdvFort:draw_aux(dc)
    local a = self.aux
    if not a then return end
    local l, t, w, h, cols, rows = self:aux_geom()
    if a.kind == 'mats' then
        draw_box(dc, l, t, w, h, a.title)
        if #a.slots == 0 then
            dc:seek(l+1, t+1):pen(COLOR_DARKGREY):string('no materials needed')
        end
        for i, s in ipairs(a.slots) do
            local txt, tag, pen = slot_row_text(i, s)
            txt = txt:sub(1, w-2-#tag)..tag
            dc:seek(l+1, t+i):pen(pen):string(txt:sub(1, w-2))
        end
        dc:seek(l+1, t+h-2):pen(COLOR_LIGHTGREEN):string('[ Start ]')
        dc:seek(l+11, t+h-2):pen(COLOR_DARKGREY)
            :string(('click a row: choose  Esc: cancel'):sub(1, math.max(0, w-12)))
        return
    end
    local msc = aux_max_scroll(a, cols, rows)
    if a.scroll > msc then a.scroll = msc end
    draw_box(dc, l, t, w, h, a.title)
    if msc > 0 then
        dc:seek(l+w-10, t):pen(a.scroll > 0 and COLOR_LIGHTCYAN or COLOR_DARKGREY):string(' [-] ')
        dc:seek(l+w-5, t):pen(a.scroll < msc and COLOR_LIGHTCYAN or COLOR_DARKGREY):string('[+] ')
    end
    local mset, mbest = list_matches(a)
    local fx1 = l+2+#a.title+3
    local fx2 = (msc > 0) and (l+w-11) or (l+w-2)
    if fx2 >= fx1 then
        local fw = fx2-fx1+1
        if a.search == '' then
            dc:seek(fx1, t):pen(COLOR_DARKGREY):string(('type to filter'):sub(1, fw))
        else
            dc:seek(fx1, t):pen(mbest and COLOR_GREEN or COLOR_LIGHTRED)
                :string((a.search..'_'):sub(1, fw))
        end
    end
    if #a.entries == 0 then
        dc:seek(l+1, t+1):pen(COLOR_DARKGREY):string('nothing on offer')
    end
    for r = 0, rows-1 do
        for c = 0, cols-1 do
            local idx = (a.scroll+r)*cols+c+1
            local e = a.entries[idx]
            if e then
                local pen
                if a.kind == 'build' and idx == a.sel_idx then pen = COLOR_LIGHTGREEN
                elseif a.search == '' then pen = COLOR_WHITE
                elseif idx == mbest then pen = COLOR_GREEN
                elseif mset[idx] then pen = COLOR_LIGHTGREEN
                else pen = COLOR_DARKGREY end
                dc:seek(l+1+c*COL_W, t+1+r):pen(pen):string(e.label:sub(1, COL_W-1))
            end
        end
    end
    if a.kind == 'build' then
        local sy = t+rows+1
        dc:seek(l+1, sy):pen{fg=COLOR_GREY, bg=COLOR_BLACK}
            :string(string.rep(string.char(196), w-2))
        local slots = a.slots or {}
        if not a.sel_idx then
            dc:seek(l+1, sy+1):pen(COLOR_DARKGREY):string('pick a building above')
        elseif #slots == 0 then
            dc:seek(l+1, sy+1):pen(COLOR_DARKGREY):string('no materials needed')
        end
        for i, s in ipairs(slots) do
            local txt, tag, pen = slot_row_text(i, s)
            txt = txt:sub(1, w-2-#tag)..tag
            dc:seek(l+1, sy+i):pen(pen):string(txt:sub(1, w-2))
        end
        dc:seek(l+1, t+h-2):pen(COLOR_DARKGREY)
            :string(('click a material row to choose; click an adjacent tile to build'):sub(1, w-2))
    end
end

-- ---- auxiliary panel management (one panel at a time) ------------------------

function AdvFort:close_aux(cancel)
    local a = self.aux
    self.aux = nil
    if a and a.kind == 'mats' and cancel and a.on_cancel then a.on_cancel() end
end

function AdvFort:open_list_panel(title, entries, on_pick)
    self.aux = {kind='list', title=title, entries=entries, search='', scroll=0,
                on_pick=on_pick, spawn_ms=dfhack.getTickCount()}
end

function AdvFort:open_mats_panel(title, slots, on_confirm, on_cancel)
    self.aux = {kind='mats', title=title, slots=slots, on_confirm=on_confirm,
                on_cancel=on_cancel, spawn_ms=dfhack.getTickCount()}
end

function AdvFort:open_build_panel()
    local entries = {}
    for _, e in ipairs(build_picker_entries()) do
        if deon_filter(e.fname, e.type, e.subtype, e.custom, nil) then
            entries[#entries+1] = e
        end
    end
    self.aux = {kind='build', title='Build what?', entries=entries, search='',
                scroll=0, spawn_ms=dfhack.getTickCount()}
    local lb = last_building
    if lb and lb.type then
        for i, e in ipairs(entries) do
            if e.type == lb.type and e.subtype == (lb.subtype or -1)
                and e.custom == (lb.custom or -1) then
                self:build_select(i)
                break
            end
        end
    end
end

function AdvFort:build_select(idx)
    local a = self.aux
    local e = a and a.entries[idx]
    if not e then return end
    a.sel_idx = idx
    last_building.type, last_building.subtype, last_building.custom =
        e.type, e.subtype, e.custom
    build_sel = {label=e.label, picks={}}
    a.slots = compute_slots(e)
    self:update_picks()
end

function AdvFort:update_picks()
    -- only the BUILD panel's slots feed build_sel; a mats panel must not
    if not (build_sel and self.aux and self.aux.kind == 'build') then return end
    build_sel.picks = {}
    for _, s in ipairs((self.aux and self.aux.slots) or {}) do
        local it = s.cands[s.pick]
        if it then table.insert(build_sel.picks, it.id) end
    end
end

function AdvFort:open_item_picker(slot, title, after)
    if #slot.cands < 1 then return end
    -- deduplicate: one row per distinct item description, with a count --
    -- "3x slade bars", "8x birch logs"; picking a row picks its first item
    local groups, order = {}, {}
    for i, it in ipairs(slot.cands) do
        local lab = item_label(it)
        local g = groups[lab]
        if not g then
            g = {first=i, count=0}
            groups[lab] = g
            order[#order+1] = lab
        end
        g.count = g.count+1
        if i == slot.pick then g.current = true end
    end
    local entries = {}
    for _, lab in ipairs(order) do
        local g = groups[lab]
        entries[#entries+1] = {label=('%dx %s'):format(g.count, lab),
                               data=g.first, current=g.current}
    end
    ItemPicker{title=title, entries=entries, on_pick=function(i)
        slot.pick = i
        if after then after() end
    end}:show()
end

function AdvFort:list_pick(idx)
    local a = self.aux
    local e = a and a.entries[idx]
    if not e then return end
    self.aux = nil          -- the handler may open the next panel
    if a.on_pick then a.on_pick(e.data) end
end

function AdvFort:mats_confirm()
    local a = self.aux
    self.aux = nil
    if a and a.on_confirm then a.on_confirm(a.slots) end
end

function AdvFort:aux_input(keys, mx, my)
    local a = self.aux
    if keys.LEAVESCREEN then
        if a.kind ~= 'mats' and a.search ~= '' then a.search = ''
        else self:close_aux(true) end
        return true
    end
    if keys._MOUSE_R or keys._MOUSE_R_DOWN then
        self:close_aux(true)
        return true
    end
    -- a DIGIT edits that slot's material (slots are numbered "1) ...") instead
    -- of going into the filter search
    if (a.kind == 'build' or a.kind == 'mats') and keys._STRING
        and keys._STRING >= 48 and keys._STRING <= 57 then
        local i = keys._STRING-48
        if i == 0 then i = 10 end
        local s = a.slots and a.slots[i]
        if s and #s.cands > 1 then
            local me = self
            self:open_item_picker(s, ('Slot %d: choose material'):format(i),
                function() me:update_picks() end)
        end
        return true
    end
    if a.kind ~= 'mats' then
        if keys._STRING == 0 then
            a.search = a.search:sub(1, -2)
            return true
        elseif keys._STRING and keys._STRING >= 33 then
            a.search = a.search..string.char(keys._STRING)
            return true
        end
    end
    if keys.SELECT then
        if a.kind == 'mats' then
            self:mats_confirm()
        elseif a.kind == 'build' then
            local _, best = list_matches(a)
            if a.search ~= '' and best and best ~= a.sel_idx then
                self:build_select(best)         -- first Enter: adopt the match
                a.search = ''
            elseif a.sel_idx then
                self:close_aux()                -- Enter again: done choosing --
                feed('A_LOOK')                  -- pick WHERE with the look cursor
            end
        else
            local _, best = list_matches(a)
            if best then self:list_pick(best) end
        end
        return true
    end
    local l, t, w, h, cols, rows = self:aux_geom()
    if a.kind ~= 'mats' then
        if keys.CONTEXT_SCROLL_UP then
            a.scroll = math.max(0, a.scroll-1)
            return true
        elseif keys.CONTEXT_SCROLL_DOWN then
            a.scroll = math.min(aux_max_scroll(a, cols, rows), a.scroll+1)
            return true
        end
    end
    if keys._MOUSE_L then
        if dfhack.getTickCount()-(a.spawn_ms or 0) < 250 then return true end
        local inside = mx >= l and mx < l+w and my >= t and my < t+h
        if not inside then
            -- outside the panel: close it; a click on the menu still lands there
            local ml, mt, mw, mh = self:menu_geom()
            self:close_aux(a.kind == 'mats')
            if mx >= ml and mx < ml+mw and my >= mt and my < mt+mh then
                self:menu_click(mx, my)
            end
            return true
        end
        if a.kind == 'mats' then
            local i = my-t
            if i == h-2 and mx <= l+10 then
                self:mats_confirm()
                return true
            end
            local s = a.slots[i]
            if s and #s.cands > 1 then
                self:open_item_picker(s, ('Slot %d: choose material'):format(i))
            end
            return true
        end
        if my == t and aux_max_scroll(a, cols, rows) > 0 then
            if mx >= l+w-10 and mx <= l+w-6 then a.scroll = math.max(0, a.scroll-1)
            elseif mx >= l+w-5 and mx <= l+w-2 then
                a.scroll = math.min(aux_max_scroll(a, cols, rows), a.scroll+1)
            end
            return true
        end
        if a.kind == 'build' then
            local sy = t+rows+1
            if my > sy and my <= sy+#(a.slots or {}) then
                local s = a.slots[my-sy]
                if s and #s.cands > 1 then
                    local me = self
                    self:open_item_picker(s, ('Slot %d: choose material'):format(my-sy),
                        function() me:update_picks() end)
                end
                return true
            end
        end
        local r, cx = my-t-1, mx-l-1
        if r >= 0 and r < rows and cx >= 0 and cx < cols*COL_W then
            local idx = (a.scroll+r)*cols+(cx//COL_W)+1
            if a.entries[idx] then
                if a.kind == 'build' then
                    if idx == a.sel_idx then
                        -- clicking the selected entry confirms and closes;
                        -- with the mouse you then just click a tile to build
                        self:close_aux()
                    else
                        self:build_select(idx)
                        a.search = ''
                    end
                else
                    self:list_pick(idx)
                end
            end
        end
        return true
    end
    return true   -- panels are keyboard-modal: typing filters, nothing leaks through
end

-- ---- workshop flow -----------------------------------------------------------

function AdvFort:openShopWindowButtoned(building, no_reset)
    local list = {}
    if no_reset then
        -- mid-category browsing: stay on the entity whose button was pressed
        self:setupFields(self.menu_entity or nil)
        building:fillSidebarMenu()
        for _, choice in pairs(df.global.game.main_interface.building.button) do
            table.insert(list, {text=utils.call_with_string(choice, 'text'),
                                button=choice, entity=self.menu_entity})
        end
    else
        -- workshop hygiene (advfort's): junk jobs deleted, orphans offered as Resume
        local function job_is_active(bj)
            for _, r in ipairs(bj.general_refs) do
                if r:getType() == df.general_ref_type.UNIT_WORKER then
                    local ok, u = pcall(function() return r:getUnit() end)
                    if ok and u and u.job.current_job == bj then return true end
                end
            end
            return false
        end
        local function job_seems_done(bj)
            if bj.completion_timer >= 0 then return false end
            if #bj.items == 0 then return false end
            local any_alive = false
            pcall(function()
                for _, ji in ipairs(bj.items) do
                    local it = ji.item
                    if it and df.item.find(it.id) == it then any_alive = true end
                end
            end)
            return not any_alive
        end
        self._resumables = {}
        for i = #building.jobs-1, 0, -1 do
            local bj = building.jobs[i]
            if not job_is_active(bj) then
                if (#bj.items == 0 and bj.completion_timer < 0) or job_seems_done(bj) then
                    pcall(smart_job_delete, bj)
                else
                    table.insert(self._resumables, bj)
                end
            end
        end
        -- union of every menu entity's offered jobs; button POINTERS survive only
        -- the LAST fill (earlier rows are re-resolved by label at press time)
        self.menu_entity = nil
        local ents = self:menuEntities()
        local seen = {}
        for i, ent in ipairs(ents) do
            self:setupFields(ent or nil)
            building:fillSidebarMenu()
            local last = (i == #ents)
            for _, choice in pairs(df.global.game.main_interface.building.button) do
                local label = utils.call_with_string(choice, 'text')
                if not seen[label] then
                    seen[label] = true
                    table.insert(list, {text=label, button=last and choice or nil, entity=ent})
                end
            end
        end
        if #ents > 1 then
            local fresh = {}
            for _, choice in pairs(df.global.game.main_interface.building.button) do
                fresh[utils.call_with_string(choice, 'text')] = choice
            end
            for _, row in ipairs(list) do
                if not row.button and fresh[row.text] then
                    row.button = fresh[row.text]
                    row.entity = ents[#ents]
                end
            end
        end
    end
    if #list == 0 and not no_reset then
        self:openShopWindow(building)
        return
    end
    local building_name = utils.call_with_string(building, 'getName') or 'Workshop'
    local entries = {}
    for _, bj in ipairs(self._resumables or {}) do
        table.insert(entries, {label=('Resume: %s'):format(job_name(bj)), data={resume=bj}})
    end
    self._resumables = nil
    for _, c in ipairs(list) do table.insert(entries, {label=c.text, data=c}) end
    local me = self
    self:open_list_panel(building_name, entries, function(data)
        -- advfort's press logic (resume / re-resolve by label / custom-reaction
        -- hand-build); it calls back into me for categories and materials
        me:onWorkShopButtonClicked(building, 0, data)
    end)
end

-- workshop-job materials: the aux mats panel; per-item choice is the MODAL picker
function AdvFort:openJobMaterials(jargs)
    local job = jargs.job
    local its = EnumItems_with_settings(jargs)
    local ok, suitability = pcall(find_suitable_items, job, its)
    if not ok then
        pcall(smart_job_delete, job)
        self:set_status('Item scan failed')
        return
    end
    local slots = {}
    -- NB: ipairs yields 0-based indices on df vectors; find_suitable_items keys
    -- its suitability table with the SAME indices, so use job_id directly
    for job_id, trg in ipairs(job.job_items.elements) do
        local cands, seen = {}, {}
        for _, it in pairs(suitability[job_id] or {}) do
            if not seen[it.id] then
                seen[it.id] = true
                cands[#cands+1] = it
            end
        end
        slots[#slots+1] = {cands=cands, pick=(#cands > 0) and 1 or 0,
                           qty=trg.quantity or 1, what=filter_desc(trg)}
    end
    if #slots == 0 then
        makeJob(jargs)
        return
    end
    local me = self
    local title = (utils.call_with_string(jargs.building, 'getName') or 'Job')..' materials'
    self:open_mats_panel(title, slots,
        function(slots2)
            jargs.pre_actions = {function(a) return fill_job_from_slots(a, slots2) end}
            makeJob(jargs)
        end,
        function()
            pcall(smart_job_delete, job)
            me:set_status('Job canceled')
        end)
end

function AdvFort:use_nearby_workshop()
    local adv = dfhack.world.getAdventurer()
    local function usable(p)
        local bld = dfhack.buildings.findAtTile(p)
        if bld and MODES[bld:getType()]
            and bld:getBuildStage() == bld:getMaxBuildStage()
            -- jobs only work within 1 of the CENTER; farther out the menu
            -- would only offer jobs that fail
            and math.max(math.abs(adv.pos.x-bld.centerx),
                         math.abs(adv.pos.y-bld.centery),
                         math.abs(adv.pos.z-bld.z)) <= 1 then
            return bld
        end
    end
    local bld = usable(adv.pos)
    if not bld then
        for _, d in ipairs({{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}}) do
            bld = usable({x=adv.pos.x+d[1], y=adv.pos.y+d[2], z=adv.pos.z})
            if bld then break end
        end
    end
    if not bld then
        self:set_status('You are not standing at a workshop')
        return
    end
    MODES[bld:getType()].input(self, bld)
end

-- ---- job attempts (clicks + careful moves) -----------------------------------

function AdvFort:try_job(state, cur_mode)
    self.status_msg = nil
    self.queued_job = nil
    if settings.safe and not self.current_site then
        self:set_status('You are not on site')
        return false
    end
    for _, p in pairs(cur_mode[3] or {}) do
        local ok2, msg2 = p(state)
        if not ok2 then
            self:set_status(msg2 or 'Cannot do that there')
            return false
        end
    end
    if type(cur_mode[2]) == 'function' then
        local _, msg3 = cur_mode[2](state)
        if msg3 then self:set_status(msg3) end
    else
        makeJob(state)
    end
    self:wait_long_start()
    return true
end

function AdvFort:map_click_job()
    local pos = dfhack.gui.getMousePos()
    if not pos then return false end
    local adv = dfhack.world.getAdventurer()
    -- Z RULE: a mouse job click must target the adventurer's own z-level. The
    -- tile seen through a channel is one z DOWN -- clicking it means WALK there,
    -- not "channel that spot" (the old Chebyshev-with-z reach test claimed it).
    if pos.z ~= adv.pos.z then return false end
    local cur_mode = actions[MODE_IDX+1]
    local reach = 1
    if cur_mode[1] == 'Build' and last_building and last_building.type then
        local okz, _, _, _, cx, cy = pcall(dfhack.buildings.getCorrectSize, nil, nil,
            last_building.type, last_building.subtype, last_building.custom, 0)
        if okz and cx then reach = 1+math.max(cx, cy or 0) end
    end
    if math.max(math.abs(pos.x-adv.pos.x), math.abs(pos.y-adv.pos.y)) > reach then
        return false
    end
    local probe = {unit=adv, pos={x=pos.x, y=pos.y, z=pos.z}, from_pos=copyall(adv.pos)}
    for _, pr in pairs(cur_mode[3] or {}) do
        if TARGET_PREDS[pr] and not pr(probe) then
            return false   -- tile can never suit this job: let the game have the click
        end
    end
    -- Use Workshop only works within 1 tile of the building's CENTER: standing
    -- farther out, never capture the click (walking there is what you want)
    if cur_mode[1] == 'Use Workshop' then
        local bld = dfhack.buildings.findAtTile(pos)
        if not bld or bld:getBuildStage() < bld:getMaxBuildStage()
            or not MODES[bld:getType()]
            or math.max(math.abs(adv.pos.x-bld.centerx),
                        math.abs(adv.pos.y-bld.centery),
                        math.abs(adv.pos.z-bld.z)) > 1 then
            return false
        end
    end
    if cur_mode[1] == 'Build' then
        if not (last_building and last_building.type) then
            self:open_build_panel()
            return true
        end
    end
    local state = {unit=adv, pos={x=pos.x, y=pos.y, z=pos.z}, dir={0,0,0},
        from_pos=copyall(adv.pos), post_actions=cur_mode[4],
        pre_actions=cur_mode[5], job_type=cur_mode[2], screen=self}
    self:try_job(state, cur_mode)
    return true
end

-- Enter is the ONLY job key on the map: with the look cursor up it does the
-- selected action there; without it, Build opens its picker, Use Workshop its
-- menu, and everything else opens look mode. Every other key -- movement,
-- careful move, the <> camera keys -- passes to the game untouched (the look
-- cursor's own <> reach other z-levels).
function AdvFort:enter_action(keys)
    if not keys.SELECT then return false end
    local adv = dfhack.world.getAdventurer()
    local cur_mode = actions[MODE_IDX+1]
    local cursor = guidm.getCursorPos()
    if not cursor then
        if cur_mode[1] == 'Build' then
            -- Enter on Build opens the picker; Enter IN the picker closes it
            -- and opens look mode to place the building
            self:open_build_panel()
        elseif cur_mode[1] == 'Use Workshop' then
            -- never via look mode: the workshop you stand at, or a message
            self:use_nearby_workshop()
        else
            feed('A_LOOK')   -- open look mode to choose where to act
        end
        return true
    end
    if cur_mode[1] == 'Build' and not (last_building and last_building.type) then
        self:open_build_panel()
        return true
    end
    local state = {unit=adv, pos={x=cursor.x, y=cursor.y, z=cursor.z}, dir={0,0,0},
        from_pos=copyall(adv.pos), post_actions=cur_mode[4],
        pre_actions=cur_mode[5], job_type=cur_mode[2], screen=self}
    if self:try_job(state, cur_mode) then
        feed('LEAVESCREEN')
    end
    return true
end

function AdvFort:cancel_current_job()
    local u = dfhack.world.getAdventurer()
    local cj = u and u.job.current_job
    if not cj then return end
    local nm = job_name(cj)
    CancelJob(u)
    pcall(smart_job_delete, cj)
    self:cancel_wait(true)
    self.queued_job = nil
    self:set_status(('Canceled: %s'):format(nm))
    dfhack.gui.showAnnouncement(('You stop working on the %s.'):format(nm), 7, 1)
end

function AdvFort:menu_click(mx, my)
    local l, t, w, _, n = self:menu_geom()
    local row = my-t
    if row == 0 then
        if mx >= l+w-5 and mx <= l+w-3 then collapsed = true end
        return
    end
    if row == n+2 then
        self:cancel_current_job()
        return
    end
    local line = row >= 1 and row <= n and LAYOUT[row]
    if line then
        for _, seg in ipairs(line) do
            if seg._x1 and mx >= seg._x1 and mx <= seg._x2 then
                local id = seg.click or seg[1]
                MODE_IDX = id-1
                self.status_msg = nil
                if actions[id][1] == 'Build' then self:open_build_panel()
                elseif actions[id][1] == 'Use Workshop' then self:use_nearby_workshop() end
                break
            end
        end
    end
end

-- ---- input -------------------------------------------------------------------

function AdvFort:onInput(keys)
    if not ctx_ok() then return false end
    -- Ctrl+F minimizes/maximizes the window (and arms the tool if it is
    -- hidden entirely)
    if keys.CUSTOM_CTRL_F then
        if not shown then
            shown = true
            collapsed = false
            on_enable()
        else
            collapsed = not collapsed
        end
        return true
    end
    if not shown then return false end
    -- engine-fed waits must ALWAYS reach the game -- an open panel would
    -- otherwise swallow them and freeze the job it is waiting on
    if keys.A_SHORT_WAIT then return false end
    WIDGET = self
    self:ensure_dims()
    local mx, my = self:mouse_lxy()
    if collapsed then
        if keys._MOUSE_L and mx == 0 and my == self:icon_row() then
            collapsed = false
            return true
        end
        return false
    end
    self:update_site()
    if self.aux then
        return self:aux_input(keys, mx, my)
    end
    local l, t, w, h = self:menu_geom()
    local over_menu = mx >= l and mx < l+w and my >= t and my < t+h
    if keys._MOUSE_R or keys._MOUSE_R_DOWN then
        if over_menu then
            collapsed = true
            return true
        end
        return false   -- native right-click stays native; the menu stays put
    end
    if keys._MOUSE_L then
        if over_menu then
            self:menu_click(mx, my)
            return true
        end
        if self:map_click_job() then return true end
        return false   -- plain map click: walk there
    end
    if keys.CUSTOM_SHIFT_T then
        MODE_IDX = (MODE_IDX+1)%#actions
        return true
    elseif keys.CUSTOM_SHIFT_R then
        MODE_IDX = (MODE_IDX-1)%#actions
        return true
    end
    return self:enter_action(keys)
end

-- ---- the job engine ----------------------------------------------------------

function AdvFort:dismiss_too_long_prompt()
    local now = dfhack.getTickCount()
    if now-(self.prompt_last_try or 0) < 100 then return end
    self.prompt_last_try = now
    local x, y, len = find_screen_text('Continue waiting')
    if not x then x, y, len = find_screen_text('Continue') end
    if not x then return end
    local gps = df.global.gps
    local cx = x+len//2
    gps.mouse_x, gps.mouse_y = cx, y
    gps.precise_mouse_x = cx*gps.tile_pixel_x+gps.tile_pixel_x//2
    gps.precise_mouse_y = y*gps.tile_pixel_y+gps.tile_pixel_y//2
    feed('_MOUSE_L')
end

function AdvFort:run_engine()
    local adv = dfhack.world.getAdventurer()
    if not adv then return end
    local job_ptr = adv.job.current_job
    local job_action = findAction(adv, df.unit_action_type.Job)

    -- the job the tool was wielded for is over: put the tool back
    if self.tool_swap and not job_ptr then
        self:restore_tool_swap()
    end

    -- post-completion unstick: a finished building sealing you in -> step off
    if self.unstick_until then
        if dfhack.getTickCount() > self.unstick_until then
            self.unstick_until = nil
        else
            local function blocked(p)
                local blk = dfhack.maps.getTileBlock(p)
                if not blk then return true end
                local bo = blk.occupancy[p.x%16][p.y%16].building
                return bo == df.tile_building_occ.Impassable
                    or bo == df.tile_building_occ.Obstacle
            end
            if blocked(adv.pos) then
                for _, dd in ipairs({{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}}) do
                    local p = {x=adv.pos.x+dd[1], y=adv.pos.y+dd[2], z=adv.pos.z}
                    if tile_standable(p) and pcall(dfhack.units.teleport, adv, copyall(p)) then
                        dfhack.gui.showAnnouncement('You step off the finished building.', 7, 1)
                        self.unstick_until = nil
                        break
                    end
                end
            end
        end
    end

    -- too-long prompt: freeze the deadlock countdown, click its button, resume
    if df.global.adventure.player_control_state ==
            df.adventure_game_loop_type.TAKING_TOO_LONG_INPUT then
        self.long_wait_timer = nil
        self:dismiss_too_long_prompt()
        return
    end

    -- detail-apply fallback: DF's adv completion can consume a smooth designation
    -- without transforming the tile (and digs a fortification to a WALL)
    if self.pending_detail and not job_ptr then
        local pd = self.pending_detail
        self.pending_detail = nil
        local block = dfhack.maps.getTileBlock(pd.pos)
        local tt = block and dfhack.maps.getTileType(pd.pos)
        if tt then
            local target, note
            if pd.want == 'floor' then
                target = floor_variant(tt)
                note = 'The fortification crumbles away.'
            else
                target = smooth_variant(tt)
                note = 'You finish smoothing the '..
                    (tile_attrs[tt].shape == df.tiletype_shape.FLOOR and 'floor.' or 'wall.')
            end
            if target then
                block.tiletype[pd.pos.x%16][pd.pos.y%16] = target
                dfhack.gui.showAnnouncement(note, 7, 1)
            end
        end
    end

    -- Remove Building follow-through: demolition works the building back to
    -- a bare stage-0 shell and the job ends -- finish with the instant
    -- removal that is now allowed
    if self.destroy_bld and not job_ptr then
        local b=df.building.find(self.destroy_bld)
        if not b then
            self.destroy_bld=nil
        else
            local has_dj=false
            for _,v in ipairs(b.jobs) do
                if v.job_type==df.job_type.DestroyBuilding then has_dj=true end
            end
            if not has_dj then
                self.destroy_bld=nil
                local okd,gone=pcall(dfhack.buildings.deconstruct,b)
                if okd and gone then
                    dfhack.gui.showAnnouncement('Building removed.',7,1)
                    self:set_status('Building removed')
                end
            end
        end
    end


    -- chained job (smooth -> engrave/carve): fires on the visible RESULT
    if self.queued_job and not job_ptr and not self.pending_detail then
        local q = self.queued_job
        local tt = dfhack.maps.getTileType(q.pos)
        local ready = tt and tile_attrs[tt].special == df.tiletype_special.SMOOTH
        self.queued_job = nil
        if ready then
            makeJob{unit=adv, pos=q.pos, from_pos=copyall(adv.pos),
                pre_actions=q.pre_actions, job_type=q.job_type, screen=self}
            self:wait_long_start()
            return
        end
    end

    -- unsafe conditions stop the wait (winded deliberately excluded: it is the
    -- routine post-exertion state and decays on its own)
    if self.long_wait and not settings.unsafe then
        local counters = adv.counters
        local checked = {pain=true, stunned=true, unconscious=true, webbed=true,
                         nausea=true, dizziness=true}
        for k in pairs(checked) do
            if counters[k] > 0 then
                dfhack.gui.showAnnouncement('Job: canceled waiting because unsafe -'..k, 5, 1)
                self:set_status('stopped waiting: '..k)
                self:cancel_wait(true)
                return
            end
        end
        if counters.suffocation > 50 then
            dfhack.gui.showAnnouncement('Job: canceled waiting because unsafe -suffocation', 5, 1)
            self:set_status('stopped waiting: suffocation')
            self:cancel_wait(true)
            return
        end
    end

    -- web gathering (jobless work loop)
    if self.web_work then
        local ww = self.web_work
        local web = df.item.find(ww.web_id)
        local d = math.max(math.abs(adv.pos.x-ww.pos.x),
                           math.abs(adv.pos.y-ww.pos.y),
                           math.abs(adv.pos.z-ww.pos.z))
        if not web or not web.flags.spider_web or not same_xyz(web.pos, ww.pos) then
            self:set_status('canceled: the web is gone')
            self.web_work = nil
        elseif d > 1 then
            dfhack.gui.showAnnouncement('Job canceled: you were moved away.', 5, 1)
            self:set_status('canceled: moved away')
            self.web_work = nil
        else
            local t = df.global.cur_year_tick_advmode
            if t < ww.last_tick then ww.last_tick = t end
            if t-ww.last_tick >= ww.step_ticks then
                ww.last_tick = t
                ww.left = ww.left-1
            end
            if ww.left <= 0 then
                self.web_work = nil
                web.flags.spider_web = false
                if dfhack.items.moveToInventory(web, adv, 0, 0) then
                    dfhack.gui.showAnnouncement('You gather the web.', 7, true)
                    add_skill_exp(adv, df.job_skill.WEAVING, 30)
                else
                    web.flags.spider_web = true
                    self:set_status('Could not take the web')
                end
            else
                feed('A_SHORT_WAIT')
            end
        end
        return
    end

    -- tree felling (jobless work loop)
    if self.fell_work then
        local fw = self.fell_work
        local plant = dfhack.maps.getPlantAtTile(fw.ppos)
        local d = math.max(math.abs(adv.pos.x-fw.pos.x),
                           math.abs(adv.pos.y-fw.pos.y),
                           math.abs(adv.pos.z-fw.pos.z))
        if not plant or not plant.tree_info then
            self:set_status('canceled: the tree is gone')
            self.fell_work = nil
        elseif d > 1 then
            dfhack.gui.showAnnouncement('Job canceled: you were moved away.', 5, 1)
            self:set_status('canceled: moved away')
            self.fell_work = nil
        else
            local t = df.global.cur_year_tick_advmode
            if t < fw.last_tick then fw.last_tick = t end
            if t-fw.last_tick >= fw.step_ticks then
                fw.last_tick = t
                fw.left = fw.left-1
            end
            if fw.left <= 0 then
                self.fell_work = nil
                local ok, logs = pcall(do_fell, adv, plant)
                if ok then
                    dfhack.gui.showAnnouncement(
                        ('The tree falls! You cut %d log%s.'):format(logs, logs == 1 and '' or 's'),
                        7, true)
                    add_skill_exp(adv, df.job_skill.WOODCUTTING, 30)
                else
                    self:set_status('felling failed')
                    print('adv/fort fell error:', logs)
                end
            else
                feed('A_SHORT_WAIT')
            end
        end
        return
    end

    -- position watchdog: carried/walked out of reach = cancel cleanly, never orphan
    if job_ptr and self.long_wait then
        if self.work_job ~= job_ptr.id then
            self.work_job = job_ptr.id
            self.work_pos = copyall(adv.pos)
            self.job_started = nil
        elseif not same_xyz(adv.pos, self.work_pos) then
            local d = math.max(math.abs(adv.pos.x-job_ptr.pos.x),
                               math.abs(adv.pos.y-job_ptr.pos.y),
                               math.abs(adv.pos.z-job_ptr.pos.z))
            local limit = job_ptr.job_type == df.job_type.ConstructBuilding and 3 or 1
            if d > limit then
                dfhack.gui.showAnnouncement('Job canceled: you were moved away.', 5, 1)
                self:set_status('canceled: moved away')
                local j = job_ptr
                CancelJob(adv)
                pcall(smart_job_delete, j)
                self:cancel_wait(true)
                self.work_job = nil
                self.queued_job = nil
                return
            else
                self.work_pos = copyall(adv.pos)
            end
        end
    elseif not job_ptr then
        self.work_job = nil
    end

    -- a live job must never sit unpumped: auto-resume unless deliberately held
    if job_ptr and not self.long_wait and not self.hold_resume then
        local t = job_ptr.completion_timer
        if t > 0 or (t == -1 and not self.job_started) then
            self:wait_long_start()
        end
    end

    -- waiting for a job that never materialized (a failed/canceled creation)
    if self.long_wait and not job_ptr then
        if dfhack.getTickCount()-(self.wait_started or 0) > 3000 then
            self.long_wait = false
        end
    end

    if self.long_wait and self.long_wait_timer == nil then
        self.long_wait_timer = 1000
    end

    -- Construct pulses being REFUSED -- the job timer frozen while the game
    -- keeps running -- is the items-blocking wedge appearing MID-job (something
    -- dropped onto the site): sweep the footprint and fix the material flags.
    if job_ptr and self.long_wait and job_ptr.job_type==df.job_type.ConstructBuilding then
        if self.pulse_job~=job_ptr.id or self.pulse_timer~=job_ptr.completion_timer then
            self.pulse_job,self.pulse_timer=job_ptr.id,job_ptr.completion_timer
            self.pulse_at=dfhack.getTickCount()
        elseif dfhack.getTickCount()-(self.pulse_at or 0)>3000 then
            self.pulse_at=dfhack.getTickCount()
            local bld
            for _,r in ipairs(job_ptr.general_refs) do
                if r:getType()==df.general_ref_type.BUILDING_HOLDER then
                    bld=df.building.find(r.building_id)
                end
            end
            if bld then
                ClearFootprintItems{job=job_ptr,building=bld}
                for _,ji in ipairs(job_ptr.items) do
                    pcall(function() ji.item.flags.in_building=true end)
                end
                dfhack.gui.showAnnouncement('You clear debris from the construction site.',7,1)
            end
        end
    end

    if job_ptr and self.long_wait and not job_action then
        -- building-anchored jobs only progress (and are otherwise silently
        -- CULLED) within 1 tile of job.pos / the building's center
        do
            local anchored = job_ptr.job_type == df.job_type.ConstructBuilding
            if not anchored then
                for _, r in ipairs(job_ptr.general_refs) do
                    if r:getType() == df.general_ref_type.BUILDING_HOLDER then anchored = true end
                end
            end
            if anchored then
                local ax, ay, az = job_ptr.pos.x, job_ptr.pos.y, job_ptr.pos.z
                if ax < 0 then
                    for _, r in ipairs(job_ptr.general_refs) do
                        if r:getType() == df.general_ref_type.BUILDING_HOLDER then
                            local b = df.building.find(r.building_id)
                            if b then ax, ay, az = b.centerx, b.centery, b.z end
                        end
                    end
                end
                local d = math.max(math.abs(adv.pos.x-ax),
                                   math.abs(adv.pos.y-ay),
                                   math.abs(adv.pos.z-az))
                if d > 1 then
                    self:set_status('Stand by the building to work')
                    return
                end
            end
        end

        if self.long_wait_timer <= 0 then
            self:cancel_wait(true)   -- deadlock: stop; A_WAIT or a new click resumes
            return
        else
            self.long_wait_timer = self.long_wait_timer-1
        end

        if job_ptr.completion_timer > 0 then
            self.job_started = true
        end
        -- -1 is both "finished" and "never started": only a job SEEN running is done
        if job_ptr.completion_timer == -1 and self.job_started then
            local jt = job_ptr.job_type
            local jpos = job_ptr.pos
            if jt == df.job_type.SmoothFloor or jt == df.job_type.SmoothWall then
                self.pending_detail = {pos=copyall(jpos), want='smooth'}
            elseif jt == df.job_type.Dig and self.fort_pos and same_xyz(jpos, self.fort_pos) then
                self.pending_detail = {pos=copyall(jpos), want='floor'}
                self.fort_pos = nil
            elseif jt == df.job_type.ConstructBuilding then
                self.unstick_until = dfhack.getTickCount()+3000
            end
            self.long_wait = false
            -- completed workshop-job husk left attached: unhook and delete it
            local cj2 = adv.job.current_job
            if cj2 and #cj2.items > 0 then
                local any_alive = false
                pcall(function()
                    for _, ji in ipairs(cj2.items) do
                        local it = ji.item
                        if it and df.item.find(it.id) == it then any_alive = true end
                    end
                end)
                if not any_alive then
                    local nm = job_name(cj2)
                    CancelJob(adv)
                    pcall(smart_job_delete, cj2)
                    self:set_status(('Finished: %s'):format(nm))
                    dfhack.gui.showAnnouncement(('Finished: %s.'):format(nm), 7, true)
                end
            end
        end
        ContinueJob(adv)
        feed('A_SHORT_WAIT')
    end

    -- A queued Job action only executes when the game advances, and adventure
    -- mode only advances on player input: while a pumped job's action is
    -- pending, keep feeding waits or the job freezes mid-timer (seen live
    -- after a hot-reload replaced the widget instance mid-job).
    if job_ptr and self.long_wait and job_action then
        -- Wedge guard: a WEDGED action (seen live: a construct job spinning on
        -- an inconsistent item state) ignores every fed wait and freezes the
        -- game's turn processing. The signature is the game CLOCK not moving --
        -- count only frames where the tick is frozen, and reset the budget
        -- whenever it advances. (Counting every pending-action frame canceled
        -- perfectly healthy long builds/demolitions after ~16 seconds.)
        local t = df.global.cur_year_tick_advmode
        if t ~= self.last_adv_tick then
            self.last_adv_tick = t
            self.wedge_timer = nil          -- game is advancing: not stuck
        else
            self.wedge_timer = (self.wedge_timer or 600)-1
        end
        if self.wedge_timer and self.wedge_timer <= 0 then
            self.wedge_timer = nil
            dfhack.gui.showAnnouncement('Job seems stuck -- canceled.', 5, 1)
            self:set_status('canceled: job was stuck')
            local j = job_ptr
            for _, a in ipairs(adv.actions) do
                if a.type == df.unit_action_type.Job then a.type = df.unit_action_type.None end
            end
            CancelJob(adv)
            pcall(smart_job_delete, j)
            self:cancel_wait(true)
            df.global.adventure.player_control_state = df.adventure_game_loop_type.TAKING_INPUT
            return
        end
        feed('A_SHORT_WAIT')
    end
end

function AdvFort:overlay_onupdate()
    if not ctx_ok() then return end
    WIDGET = self
    self:ensure_dims(true)
    self:run_engine()
end

function AdvFort:onRenderBody(dc)
    if not shown or not ctx_ok() then return end
    WIDGET = self
    self:ensure_dims()
    if collapsed then
        dc:seek(0, self:icon_row()):pen{fg=COLOR_YELLOW, bg=COLOR_BLACK}
            :string(string.char(207))
        return
    end
    self:update_site()
    self:draw_menu(dc)
    self:draw_aux(dc)
end

-- ---- startup sweep -----------------------------------------------------------

-- free-floating special jobs still claiming the adventurer can never run again
-- (only current_job is worked); building-held ones are left for the workshop
-- menu's Resume entries
local function sweep_orphans(adv)
    local n = 0
    local link = df.global.world.jobs.list.next
    while link do
        local j = link.item
        link = link.next
        if j and j.flags.special and j ~= adv.job.current_job then
            local worker, held
            for _, r in ipairs(j.general_refs) do
                local t = r:getType()
                if t == df.general_ref_type.UNIT_WORKER then
                    local ok, u = pcall(function() return r:getUnit() end)
                    worker = ok and u or nil
                elseif t == df.general_ref_type.BUILDING_HOLDER then
                    held = true
                end
            end
            if worker == adv and not held then
                pcall(smart_job_delete, j)
                n = n+1
            end
        end
    end
    if n > 0 then
        dfhack.gui.showAnnouncement(
            ('adv/fort: cleaned %d stuck job%s.'):format(n, n == 1 and '' or 's'), 7, 1)
    end
end

function on_enable()   -- global: the Ctrl+F arm path calls it by name
    local adv = dfhack.world.getAdventurer()
    if not adv then return end
    local labors = adv.status.labors
    for i in ipairs(labors) do labors[i] = true end
    sweep_orphans(adv)
end

OVERLAY_WIDGETS = {panel=AdvFort}

if dfhack_flags and dfhack_flags.module then return end

if not ctx_ok() then
    qerror('adv/fort requires adventure mode with a live adventurer')
end

if mode_name then
    for id, action in ipairs(actions) do
        if action[1] == mode_name then MODE_IDX = id-1 break end
    end
end
if cli_cmd == 'toggle-window' then
    if not shown then
        shown = true
        collapsed = false
        on_enable()
    else
        collapsed = not collapsed
        if collapsed and WIDGET then WIDGET.aux = nil end
    end
    return
end
if cli_cmd == 'hide' then
    shown = false
elseif cli_cmd == 'toggle' then
    shown = not shown
    collapsed = false
else                        -- default / 'show'
    shown = true
    collapsed = false
end
if shown then on_enable() end
print('adv/fort: '..(shown and 'shown' or 'hidden'))
