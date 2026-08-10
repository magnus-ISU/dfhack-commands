-- allows to do jobs in adv. mode. (community rework of stock gui/advfort, plus local fixes)
--@module = true

--[====[

adv/advfort
===========
Community rework of DFHack's paused ``gui/advfort`` (jobs trigger on CAREFUL move so plain
movement and the look cursor work natively; separate SmoothWall/SmoothFloor jobs -- in DF 50
Detail* means ENGRAVE and silently no-ops on rough stone), carrying two local fixes on top:

* The "You haven't been able to act for a while" prompt no longer wedges a long wait: the
  deadlock countdown freezes and the prompt's "Continue waiting" button is clicked on the
  parent screen (adv/im-sure cannot reach it while this screen is on top).
* Smooth/Detail jobs designate their tile at job creation and, if DF's adv-mode completion
  still leaves the tile untouched, the smooth tiletype is applied directly on completion.
* The job list shows in a vertically-centered clickable window (styled after
  fort/dig-building), titled with the current site's name: click a row to select a job,
  Shift+R/T still cycle, LEFT-CLICK AN ADJACENT TILE to do the current job there (farther
  clicks stay normal game input, i.e. walking), and refusals ("Correct tool not equiped")
  land on the window's bottom status line, which shows the work countdown while a job runs.
  Right-click the window to dismiss the tool back to completely normal play (the click is
  fully swallowed, not passed to the game); a pick-icon OVERLAY centered on the left screen
  edge -- one inert glyph on the base UI -- relaunches it.
* The window's Build line shows the CURRENT building selection (defaults to the last one
  picked); clicking a map tile builds exactly that, with no dialogs. Clicking the Build
  line opens the picker: ONE flat searchable list of everything buildable -- workshops,
  furnaces, furniture, constructions, machines, traps, siege engines, custom workshops --
  in a dig-building-style multi-column left-anchored panel, with a MATERIALS pane
  alongside it showing which items each slot will consume (click a row to swap between
  the suitable items in your inventory and on the nearby ground).
* Workshops are USABLE, not just buildable: click the window's "Use Workshop" action and
  the job menu for the finished building you stand on (or next to) opens immediately; you
  can also click any adjacent usable building with the action selected.
* Recipes default to YOUR CIVILIZATION plus the owner of the site you are standing in:
  workshop menus offer the union of both entities' known jobs (site-only recipes appear
  when you work at that site). Use ``-e`` to force a specific entity instead (the old
  default was always MOUNTAIN, i.e. dwarven recipes everywhere).

This script allows performing jobs in adventure mode. For more complete help
press :kbd:`?` while the script is running. It's most comfortable to use this as a
keybinding (see below for the default binding). Possible arguments:

* ``-a``, ``--nodfassign``:
    uses a different method to assign job items, instead of relying on DF.
* ``-i``, ``--inventory``:
    checks inventory for possible items to use in the job.
* ``-c``, ``--cheat``:
    relaxes item requirements for buildings (e.g. walls from bones). Implies -a
* ``-e [NAME]``, ``--entity [NAME]``:
    uses the given civ to determine available resources (specified as an entity raw ID,
    e.g. ``MOUNTAIN``). If the entity name is omitted, uses the adventurer's civ alone.
    Without ``-e`` at all, resources come from the adventurer's civ PLUS the civ owning
    the site you are standing in
* ``job``: selects the specified job (must be a valid ``job_type``, e.g. ``Dig`` or ``FellTree``)

.. warning::
    changes only persist in non-procedural sites, namely player forts, caves, and camps.

An example of a player digging in adventure mode:

.. image:: /docs/images/advfort.png

]====]

--[==[
    todo list:
        - document everything! Maybe somebody would understand what is happening then and help me :<
        - when building trap add to known traps (or known adventurers?) so that it does not trigger on adventurer
    bugs list:
        - items blocking construction stuck the game
        - burning charcoal crashed game
        - gem thingies probably broken
        - custom reactions semibroken
        - gathering plants still broken

--]==]

--keybinding, change to your hearts content. Only the key part.
local keybinds={
nextJob={key="CUSTOM_SHIFT_T",desc="Next job in the list"},
prevJob={key="CUSTOM_SHIFT_R",desc="Previous job in the list"},
continue={key="A_WAIT",desc="Continue job if available"},
down_alt1={key="CUSTOM_CTRL_D",desc="Use job down"},
down_alt2={key="CURSOR_DOWN_Z_AUX",desc="Use job down"},
up_alt1={key="CUSTOM_CTRL_E",desc="Use job up"},
up_alt2={key="CURSOR_UP_Z_AUX",desc="Use job up"},
use_same={key="A_MOVE_SAME_SQUARE",desc="Use job at the tile you are standing"},
quick={key="CUSTOM_Q",desc="Toggle quick item select"},
}
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

local gui = require('gui')
local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')
local wid = require('gui.widgets')
local dialog = require('gui.dialogs')
local buildings = require('dfhack.buildings')
local workshopJobs = require('dfhack.workshops')
local utils = require('utils')
local gscript = require('gui.script')

local advfort_items = reqscript('internal/advfort/advfort_items')

local tile_attrs = df.tiletype.attrs

-- set_civ: nil = adventurer's civ + the current site's owner (the default),
-- true = adventurer's civ only (-e with no name), "NAME" = that entity raw (-e NAME)
local settings={build_by_items=false,use_worn=false,check_inv=true,teleport_items=true,df_assign=false,gui_item_select=true,only_in_sites=false,set_civ=nil}

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
        else
            mode_name=v
        end
        i=i+1
    end
end
parse_args()

mode=mode or 0
last_building=last_building or {}
build_sel=build_sel or nil    -- {label=..., picks={item ids}} from the picker's materials pane

function Disclaimer(tlb)
    local dsc={"The Gathering Against ",{text="Goblin ",pen=dfhack.pen.parse{fg=COLOR_GREEN,bg=0}}, "Oppresion ",
        "(TGAGO) is not responsible for all ",NEWLINE,"the damage that this tool can (and will) cause to you and your loved worlds",NEWLINE,"and/or sanity.Please use with caution.",NEWLINE,{text="Magma not included.",pen=dfhack.pen.parse{fg=COLOR_LIGHTRED,bg=0}}}
    if tlb then
        for _,v in ipairs(dsc) do
            table.insert(tlb,v)
        end
    end
    return dsc
end
function showHelp()
    local helptext={
    "This tool allow you to perform jobs as a dwarf would in dwarf mode. When ",NEWLINE,
    "cursor is available you can press ",{key="SELECT", text="select",key_sep="()"},
    " to enqueue a job from",NEWLINE,"pointer location. If job is 'Build' and there is no planed construction",NEWLINE,
    "at cursor this tool show possible building choices.",NEWLINE,NEWLINE,{text="Keybindings:",pen=dfhack.pen.parse{fg=COLOR_CYAN,bg=0}},NEWLINE
    }
    for k,v in pairs(keybinds) do
        table.insert(helptext,{key=v.key,text=v.desc,key_sep=":"})
        table.insert(helptext,NEWLINE)
    end
    table.insert(helptext,{text="CAREFULL MOVE",pen=dfhack.pen.parse{fg=COLOR_LIGHTGREEN,bg=0}})
    table.insert(helptext,": use job in that direction")
    table.insert(helptext,NEWLINE)
    table.insert(helptext,NEWLINE)
    Disclaimer(helptext)
    dialog.showMessage("Help!?!",helptext)
end

if settings.help then
    showHelp()
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
--luacheck: in={_type:table,job:df.job,job_type:df.job_type,pos:df.coord,from_pos:df.coord,unit:df.unit,no_job_delete:bool,screen:usetool,pre_actions:'{_type:function,_node:{_type:tuple,_tuple:[bool,string]},_anyfunc:true}[]',post_actions:'{_type:function,_node:{_type:tuple,_tuple:[bool,string]},_anyfunc:true}[]'}
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
    -- only two tools are ever demanded (pick for the dig family, axe for felling)
    local tool_msg={[df.job_skill.MINING]="Equip a pick",[df.job_skill.AXE]="Equip an axe"}
    local msg=tool_msg[item_skill] or "Equip the right tool"
    local pred=function(args)
        local inv=args.unit.inventory
        for k,v in pairs(inv) do
            if v.mode==1 and v.item:getMeleeSkill()==item_skill and is_grasping_item(v.body_part_id,args.unit) then
                return true
            end
        end
        return false,msg
    end
    return pred
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
    -- buildings on the clicked tile instead, and refuse a footprint that covers
    -- the builder -- completing a workshop around yourself seals you inside it.
    local okz,rot,w,h,cx,cy=pcall(dfhack.buildings.getCorrectSize,
        args.width,args.height,args.type,args.subtype,args.custom,args.direction or 0)
    if okz and w and (w>1 or (h or 1)>1) then
        local px,py=args.pos.x-(cx or 0),args.pos.y-(cy or 0)
        local u=args.unit or dfhack.world.getAdventurer()
        if u and u.pos.z==args.pos.z
            and u.pos.x>=px and u.pos.x<px+w and u.pos.y>=py and u.pos.y<py+h then
            if args.screen and args.screen.set_status then
                pcall(function() args.screen:set_status("You are standing in the footprint") end)
            end
            dfhack.gui.showAnnouncement("You are standing in the footprint.",COLOR_LIGHTRED,true)
            return
        end
        args.pos={x=px,y=py,z=args.pos.z}
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


function RemoveBuilding(args)
    local bld=dfhack.buildings.findAtTile(args.pos)
    if bld==nil then return false,"No building to remove" end
    -- An UNFINISHED building (planned or failed placement) must not go the job route:
    -- queueDestroy happily creates a DestroyBuilding job for it, but DF's adv-mode job pump
    -- never works that job -- its completion_timer sits at -1, which the wait loop reads as
    -- "done", so it showed working(-1) for a tick and nothing happened. There is no work to
    -- undo on an unbuilt building anyway: drop any stale destroy job and remove it directly.
    local ok,unbuilt=pcall(function() return bld:getBuildStage()<bld:getMaxBuildStage() end)
    if ok and unbuilt then
        local cj=args.unit.job.current_job
        if cj and cj.job_type==df.job_type.DestroyBuilding then
            CancelJob(args.unit)               -- a stuck earlier attempt; unhook it first
        end
        if pcall(dfhack.buildings.deconstruct,bld) then
            dfhack.gui.showAnnouncement("Building removed.",7,1)
            return true
        end
    end
    bld:queueDestroy()
    for k,v in ipairs(bld.jobs) do
        if v.job_type==df.job_type.DestroyBuilding then
            AssignUnitToJob(v,args.unit,args.from_pos)
            -- start actually working it (what makeJob does): without the unit's Job
            -- ACTION, the wait pump reads the job's virgin completion_timer (-1) as
            -- "already done" -- and without one fed wait the queued action is never
            -- consumed, so the demolition never begins
            addJobAction(v,args.unit)
            if args.screen and args.screen.wait_tick then args.screen:wait_tick() end
            return true
        end
    end
    if pcall(dfhack.buildings.deconstruct,bld) then
        dfhack.gui.showAnnouncement("Building removed.",7,1)
        return true
    end
    return false,"Building removal job failed to be created"
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
    if job_item.flags1.cookable and item:getType()==df.item_type.FOOD then
        return false,"already cooked"
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
function getItemsUncollected(job)
    local ret={}
    for id,jitem in pairs(job.items) do
        local x,y,z=dfhack.items.getPosition(jitem.item)
        if x~=job.pos.x or y~=job.pos.y or z~=job.pos.z then
            table.insert(ret,jitem)
        end
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

    local uncollected = getItemsUncollected(job)
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

function CheckAndFinishBuilding(args,bld)
    args.building=args.building or bld
    for idx,job in pairs(bld.jobs) do
        if job.job_type==df.job_type.ConstructBuilding then
            args.job=job
            args.no_job_delete=true
            break
        end
    end

    if args.job~=nil then
        args.pre_actions={AssignJobItems}
    else
        local t={items=buildings.getFiltersByType({},bld:getType(),bld:getSubtype(),bld:getCustomType())}
        args.pre_actions={dfhack.curry(setFiltersUp,t),AssignBuildingRef}--,AssignJobItems
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
local function build_picker_entries()
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
-- The picker window itself is styled after fort/dig-building: a bordered panel
-- anchored at the LEFT of the screen, entries in multiple vertically-scrollable
-- columns, with a fuzzy type-to-filter search box on the title border. Click an
-- entry (or Enter for the best match) to pick; Esc clears the filter then
-- cancels; right-click cancels.
local BP_COL_W=32                       -- one column's cell width
local BP_LEFT=27                        -- right of the job window (JOBWIN_W+1) so they never overlap
local BP_PANE_W=40                      -- the materials pane docked to the picker's right
local BP_MIN_TOP,BP_MAX_TOP,BP_BOT=5,12,6
BuildPicker=defclass(BuildPicker,gui.Screen)
BuildPicker.focus_path='advfort/build-picker'

function BuildPicker:init(args)
    self.entries=args.entries
    self.search=''
    self.scroll=0
    -- show the current selection's materials pane right away
    if last_building and last_building.type then
        for i,e in ipairs(self.entries) do
            if e.type==last_building.type and e.subtype==(last_building.subtype or -1)
                and e.custom==(last_building.custom or -1) then
                self:select_entry(i)
                break
            end
        end
    end
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
local function compute_slots(e)
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

function BuildPicker:update_picks()
    build_sel.picks={}
    for _,s in ipairs(self.slots or {}) do
        local it=s.cands[s.pick]
        if it then table.insert(build_sel.picks,it.id) end
    end
end

-- selecting an entry = the picker's whole point: it becomes what Build builds
-- (the window's Build line shows it), and the materials pane fills in
function BuildPicker:select_entry(idx)
    local e=self.entries[idx]
    if not e then return end
    self.sel_idx=idx
    last_building.type,last_building.subtype,last_building.custom=e.type,e.subtype,e.custom
    build_sel={label=e.label,picks={}}
    self.slots=compute_slots(e)
    self:update_picks()
end

-- fuzzy subsequence match (dig-building's): every char of needle in order
local function bp_fuzzy(needle,hay)
    if needle=='' then return true end
    local j=1
    for i=1,#hay do
        if hay:byte(i)==needle:byte(j) then
            j=j+1
            if j>#needle then return true end
        end
    end
    return false
end
-- rank: 0 exact, 1 prefix, 2 substring, 3 fuzzy, nil no match (on the label)
local function bp_rank(label,needle)
    local t=label:lower()
    if t==needle then return 0 end
    if t:sub(1,#needle)==needle then return 1 end
    if t:find(needle,1,true) then return 2 end
    if bp_fuzzy(needle,t) then return 3 end
end

function BuildPicker:matches()
    local set,best,best_rank={},nil,nil
    if self.search~='' then
        local needle=self.search:lower()
        for i,e in ipairs(self.entries) do
            local r=bp_rank(e.label,needle)
            if r then
                set[i]=true
                if not best_rank or r<best_rank then best,best_rank=i,r end
            end
        end
    end
    return set,best
end

function BuildPicker:geom()
    local gps=df.global.gps
    local n=#self.entries
    -- keep room for the materials pane on the right
    local max_cols=math.max(1,math.floor((gps.dimx-BP_LEFT-BP_PANE_W-3)/BP_COL_W))
    local function cols_for(top)
        local ar=math.max(1,gps.dimy-top-BP_BOT-2)
        return math.min(max_cols,math.max(2,math.ceil(n/ar))),ar
    end
    local best_cols=cols_for(BP_MIN_TOP)
    local top=BP_MIN_TOP
    for t=BP_MAX_TOP,BP_MIN_TOP+1,-1 do
        if (cols_for(t))<=best_cols then top=t break end
    end
    local cols,avail=cols_for(top)
    local rows=math.min(math.ceil(n/cols),avail)
    return BP_LEFT,top,cols*BP_COL_W+2,rows+2,cols,rows
end

function BuildPicker:max_scroll(cols,rows)
    return math.max(0,math.ceil(#self.entries/cols)-rows)
end

function BuildPicker:onRenderBody(dc)
    self:renderParent()
    local l,t,w,h,cols,rows=self:geom()
    if self.scroll>self:max_scroll(cols,rows) then self.scroll=self:max_scroll(cols,rows) end
    local BG={fg=COLOR_GREY,bg=COLOR_BLACK}
    for r=0,h-1 do dc:seek(l,t+r):pen(BG):string(string.rep(' ',w)) end
    local hbar=string.rep(string.char(196),w-2)
    dc:seek(l,t):pen(BG):string(string.char(218)..hbar..string.char(191))
    dc:seek(l,t+h-1):pen(BG):string(string.char(192)..hbar..string.char(217))
    for r=1,h-2 do
        dc:seek(l,t+r):pen(BG):string(string.char(179))
        dc:seek(l+w-1,t+r):pen(BG):string(string.char(179))
    end
    dc:seek(l+2,t):pen(COLOR_WHITE):string(' Build what? ')
    local ms=self:max_scroll(cols,rows)
    if ms>0 then
        dc:seek(l+w-10,t):pen(self.scroll>0 and COLOR_LIGHTCYAN or COLOR_DARKGREY):string(' [-] ')
        dc:seek(l+w-5,t):pen(self.scroll<ms and COLOR_LIGHTCYAN or COLOR_DARKGREY):string('[+] ')
    end
    -- search box on the title border, dig-building style
    local mset,mbest=self:matches()
    local fx1,fx2=l+16,(ms>0) and (l+w-11) or (l+w-2)
    if fx2>=fx1 then
        local fw=fx2-fx1+1
        if self.search=='' then
            dc:seek(fx1,t):pen(COLOR_DARKGREY):string(('type to filter'):sub(1,fw))
        else
            local pen=mbest and COLOR_GREEN or COLOR_LIGHTRED
            dc:seek(fx1,t):pen(pen):string((self.search..'_'):sub(1,fw))
        end
    end
    for r=0,rows-1 do
        local line=self.scroll+r
        for c=0,cols-1 do
            local idx=line*cols+c+1
            local e=self.entries[idx]
            if e then
                local pen
                if idx==self.sel_idx then pen=COLOR_LIGHTGREEN
                elseif self.search=='' then pen=COLOR_WHITE
                elseif idx==mbest then pen=COLOR_GREEN
                elseif mset[idx] then pen=COLOR_LIGHTGREEN
                else pen=COLOR_DARKGREY end
                dc:seek(l+1+c*BP_COL_W,t+1+r):pen(pen):string(e.label:sub(1,BP_COL_W-1))
            end
        end
    end
    self:draw_materials_pane(dc,l+w+1,t)
end

-- the materials pane, shown NEXT TO the building columns: one row per required
-- item slot with the item that will be used; click a row to cycle through the
-- other suitable items in your inventory / on the nearby ground
function BuildPicker:draw_materials_pane(dc,pl,pt)
    self._pane=nil
    if not self.sel_idx then return end
    local slots=self.slots or {}
    local pw=40
    local ph=math.max(1,#slots)+3
    local BG={fg=COLOR_GREY,bg=COLOR_BLACK}
    for r=0,ph-1 do dc:seek(pl,pt+r):pen(BG):string(string.rep(' ',pw)) end
    local hbar=string.rep(string.char(196),pw-2)
    dc:seek(pl,pt):pen(BG):string(string.char(218)..hbar..string.char(191))
    dc:seek(pl,pt+ph-1):pen(BG):string(string.char(192)..hbar..string.char(217))
    for r=1,ph-2 do
        dc:seek(pl,pt+r):pen(BG):string(string.char(179))
        dc:seek(pl+pw-1,pt+r):pen(BG):string(string.char(179))
    end
    local e=self.entries[self.sel_idx]
    dc:seek(pl+2,pt):pen(COLOR_WHITE):string((' '..e.label..' '):sub(1,pw-4))
    if #slots==0 then
        dc:seek(pl+1,pt+1):pen(COLOR_DARKGREY):string('no materials needed')
    end
    for i,s in ipairs(slots) do
        local it=s.cands[s.pick]
        local txt,pen
        -- [available/required] for the slot; red when there is not enough
        local tag=(' [%d/%d]'):format(#s.cands,s.qty)
        if it then
            local ok,desc=pcall(dfhack.items.getDescription,it,0)
            txt=('%d) %s'):format(i,ok and desc or '?')
            pen=(#s.cands<s.qty) and COLOR_LIGHTRED or COLOR_WHITE
        else
            txt=('%d) needs %s'):format(i,s.what or 'an item')
            pen=COLOR_LIGHTRED
        end
        txt=txt:sub(1,pw-2-#tag)..tag
        dc:seek(pl+1,pt+i):pen(pen):string(txt:sub(1,pw-2))
    end
    dc:seek(pl+1,pt+ph-2):pen(COLOR_DARKGREY):string(('click a row to choose items'):sub(1,pw-2))
    self._pane={l=pl,t=pt,w=pw,h=ph,n=#slots}
end

-- Right-click dismisses like the job window does: the actual dismissal waits in
-- onIdle for the physical button RELEASE. Dismissing on the press event handed
-- the still-held button to the advfort screen beneath, which read it as its own
-- right-click (dismissing/minimizing the whole tool).
function BuildPicker:onIdle()
    if self.dismiss_pending then
        local ok,held=pcall(function() return df.global.enabler.mouse_rbut end)
        self.dismiss_grace=(self.dismiss_grace or 30)-1
        if (ok and held==0) or self.dismiss_grace<=0 then
            self:dismiss()
        end
    end
end

function BuildPicker:onInput(keys)
    if self.dismiss_pending then return end   -- swallow everything while draining
    local l,t,w,h,cols,rows=self:geom()
    if keys.LEAVESCREEN then
        if self.search~='' then self.search='' else self:dismiss() end
        return
    end
    if keys._MOUSE_R or keys._MOUSE_R_DOWN then
        self.dismiss_pending=true
        return
    end
    if keys._STRING==0 then
        self.search=self.search:sub(1,-2)
        return
    elseif keys._STRING and keys._STRING>=33 then
        self.search=self.search..string.char(keys._STRING)
        return
    end
    if keys.SELECT then
        local _,best=self:matches()
        if best then
            self:select_entry(best)
            self.search=''
        end
        return
    end
    if keys.CONTEXT_SCROLL_UP then
        self.scroll=math.max(0,self.scroll-1)
        return
    elseif keys.CONTEXT_SCROLL_DOWN then
        self.scroll=math.min(self:max_scroll(cols,rows),self.scroll+1)
        return
    end
    if keys._MOUSE_L then
        local mx,my=df.global.gps.mouse_x,df.global.gps.mouse_y
        -- the materials pane: click a slot row to see ALL suitable items and pick one
        local p=self._pane
        if p and mx>=p.l and mx<p.l+p.w and my>=p.t and my<p.t+p.h then
            local r=my-p.t
            local s=self.slots and self.slots[r]
            if s and #s.cands>1 then
                local me=self
                pick_slot_material(s,('Slot %d: choose material'):format(r),
                    function() me:update_picks() end)
            end
            return
        end
        if mx>=l and mx<l+w and my>=t and my<t+h then
            if my==t and self:max_scroll(cols,rows)>0 then   -- scroll controls
                if mx>=l+w-10 and mx<=l+w-6 then self.scroll=math.max(0,self.scroll-1)
                elseif mx>=l+w-5 and mx<=l+w-2 then
                    self.scroll=math.min(self:max_scroll(cols,rows),self.scroll+1)
                end
                return
            end
            local r,cx=my-t-1,mx-l-1
            if r>=0 and r<rows and cx>=0 and cx<cols*BP_COL_W then
                local idx=(self.scroll+r)*cols+(cx//BP_COL_W)+1
                if self.entries[idx] then
                    self:select_entry(idx)
                    self.search=''
                end
            end
            return                       -- consume clicks on the panel
        end
        -- click outside both panels: done choosing, back to the game
        self:dismiss()
        return
    end
end

-- Generic dig-building-style list picker (the Build panel's look and manners --
-- left-anchored columns, fuzzy type-to-filter, click/Enter picks, right-click's
-- dismissal drains the held button): used for the workshop job menu.
JobPicker=defclass(JobPicker,gui.Screen)
JobPicker.focus_path='advfort/job-picker'

function JobPicker:init(args)
    self.title=args.title or 'Choose'
    self.entries=args.entries      -- {{label=..., data=...},...}
    self.on_pick=args.on_pick      -- fn(data)
    self.search=''
    self.scroll=0
end

function JobPicker:matches()
    local set,best,best_rank={},nil,nil
    if self.search~='' then
        local needle=self.search:lower()
        for i,e in ipairs(self.entries) do
            local r=bp_rank(e.label,needle)
            if r then
                set[i]=true
                if not best_rank or r<best_rank then best,best_rank=i,r end
            end
        end
    end
    return set,best
end

function JobPicker:geom()
    local gps=df.global.gps
    local n=math.max(1,#self.entries)
    local max_cols=math.max(1,math.floor((gps.dimx-BP_LEFT-3)/BP_COL_W))
    local function cols_for(top)
        local ar=math.max(1,gps.dimy-top-BP_BOT-2)
        return math.min(max_cols,math.max(1,math.ceil(n/ar))),ar
    end
    local best_cols=cols_for(BP_MIN_TOP)
    local top=BP_MIN_TOP
    for t=BP_MAX_TOP,BP_MIN_TOP+1,-1 do
        if (cols_for(t))<=best_cols then top=t break end
    end
    local cols,avail=cols_for(top)
    local rows=math.min(math.ceil(n/cols),avail)
    return BP_LEFT,top,cols*BP_COL_W+2,rows+2,cols,rows
end

function JobPicker:max_scroll(cols,rows)
    return math.max(0,math.ceil(#self.entries/cols)-rows)
end

function JobPicker:onRenderBody(dc)
    self:renderParent()
    local l,t,w,h,cols,rows=self:geom()
    if self.scroll>self:max_scroll(cols,rows) then self.scroll=self:max_scroll(cols,rows) end
    local BG={fg=COLOR_GREY,bg=COLOR_BLACK}
    for r=0,h-1 do dc:seek(l,t+r):pen(BG):string(string.rep(' ',w)) end
    local hbar=string.rep(string.char(196),w-2)
    dc:seek(l,t):pen(BG):string(string.char(218)..hbar..string.char(191))
    dc:seek(l,t+h-1):pen(BG):string(string.char(192)..hbar..string.char(217))
    for r=1,h-2 do
        dc:seek(l,t+r):pen(BG):string(string.char(179))
        dc:seek(l+w-1,t+r):pen(BG):string(string.char(179))
    end
    local title=(' '..self.title..' '):sub(1,math.max(0,w-18))
    dc:seek(l+2,t):pen(COLOR_WHITE):string(title)
    local ms=self:max_scroll(cols,rows)
    if ms>0 then
        dc:seek(l+w-10,t):pen(self.scroll>0 and COLOR_LIGHTCYAN or COLOR_DARKGREY):string(' [-] ')
        dc:seek(l+w-5,t):pen(self.scroll<ms and COLOR_LIGHTCYAN or COLOR_DARKGREY):string('[+] ')
    end
    local mset,mbest=self:matches()
    local fx1,fx2=l+2+#title+1,(ms>0) and (l+w-11) or (l+w-2)
    if fx2>=fx1 then
        local fw=fx2-fx1+1
        if self.search=='' then
            dc:seek(fx1,t):pen(COLOR_DARKGREY):string(('type to filter'):sub(1,fw))
        else
            local pen=mbest and COLOR_GREEN or COLOR_LIGHTRED
            dc:seek(fx1,t):pen(pen):string((self.search..'_'):sub(1,fw))
        end
    end
    if #self.entries==0 then
        dc:seek(l+1,t+1):pen(COLOR_DARKGREY):string('nothing on offer')
    end
    for r=0,rows-1 do
        local line=self.scroll+r
        for c=0,cols-1 do
            local idx=line*cols+c+1
            local e=self.entries[idx]
            if e then
                local pen
                if self.search=='' then pen=COLOR_WHITE
                elseif idx==mbest then pen=COLOR_GREEN
                elseif mset[idx] then pen=COLOR_LIGHTGREEN
                else pen=COLOR_DARKGREY end
                dc:seek(l+1+c*BP_COL_W,t+1+r):pen(pen):string(e.label:sub(1,BP_COL_W-1))
            end
        end
    end
end

function JobPicker:pick(e)
    self:dismiss()
    self.on_pick(e.data)
end

function JobPicker:onIdle()
    if self.dismiss_pending then
        local ok,held=pcall(function() return df.global.enabler.mouse_rbut end)
        self.dismiss_grace=(self.dismiss_grace or 30)-1
        if (ok and held==0) or self.dismiss_grace<=0 then
            self:dismiss()
        end
    end
end

function JobPicker:onInput(keys)
    if self.dismiss_pending then return end
    local l,t,w,h,cols,rows=self:geom()
    if keys.LEAVESCREEN then
        if self.search~='' then self.search='' else self:dismiss() end
        return
    end
    if keys._MOUSE_R or keys._MOUSE_R_DOWN then
        self.dismiss_pending=true
        return
    end
    if keys._STRING==0 then
        self.search=self.search:sub(1,-2)
        return
    elseif keys._STRING and keys._STRING>=33 then
        self.search=self.search..string.char(keys._STRING)
        return
    end
    if keys.SELECT then
        local _,best=self:matches()
        if best then self:pick(self.entries[best]) end
        return
    end
    if keys.CONTEXT_SCROLL_UP then
        self.scroll=math.max(0,self.scroll-1)
        return
    elseif keys.CONTEXT_SCROLL_DOWN then
        self.scroll=math.min(self:max_scroll(cols,rows),self.scroll+1)
        return
    end
    if keys._MOUSE_L then
        local mx,my=df.global.gps.mouse_x,df.global.gps.mouse_y
        if mx>=l and mx<l+w and my>=t and my<t+h then
            if my==t and self:max_scroll(cols,rows)>0 then
                if mx>=l+w-10 and mx<=l+w-6 then self.scroll=math.max(0,self.scroll-1)
                elseif mx>=l+w-5 and mx<=l+w-2 then
                    self.scroll=math.min(self:max_scroll(cols,rows),self.scroll+1)
                end
                return
            end
            local r,cx=my-t-1,mx-l-1
            if r>=0 and r<rows and cx>=0 and cx<cols*BP_COL_W then
                local idx=(self.scroll+r)*cols+(cx//BP_COL_W)+1
                local e=self.entries[idx]
                if e then self:pick(e) end
            end
            return
        end
        self:dismiss()
        return
    end
end

-- ---- shared materials picker -------------------------------------------------
-- ONE materials UI for everything that consumes items: the Build flow's pane and
-- workshop jobs. A left-anchored panel with a row per required slot showing
-- available/required; CLICKING A ROW OPENS THE FULL OPTION LIST for that slot (a
-- JobPicker of every suitable item -- searchable, multi-column), click an option
-- to take it. Enter starts the job, Esc/right-click cancels.
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

-- open the full option list for one slot; on_done fires after a pick (or not at all)
function pick_slot_material(slot,title,on_done)
    if #slot.cands<1 then return end
    local entries={}
    for i,it in ipairs(slot.cands) do
        local lab=item_label(it)
        if i==slot.pick then lab=string.char(26)..' '..lab end   -- mark the current pick
        entries[#entries+1]={label=lab,data=i}
    end
    dfhack.timeout(2,'frames',function()
        JobPicker{
            title=title or 'Choose material',
            entries=entries,
            on_pick=function(i)
                slot.pick=i
                if on_done then on_done() end
            end,
        }:show()
    end)
end

MaterialsPicker=defclass(MaterialsPicker,gui.Screen)
MaterialsPicker.focus_path='advfort/materials'

function MaterialsPicker:init(args)
    self.title=args.title or 'Materials'
    self.slots=args.slots
    self.on_confirm=args.on_confirm
    self.on_cancel=args.on_cancel
end

function MaterialsPicker:geom()
    local w=46
    local h=math.max(1,#self.slots)+3
    local top=math.min(BP_MAX_TOP,math.max(0,df.global.gps.dimy-h-BP_BOT))
    return BP_LEFT,top,w,h
end

function MaterialsPicker:onRenderBody(dc)
    self:renderParent()
    local l,t,w,h=self:geom()
    local BG={fg=COLOR_GREY,bg=COLOR_BLACK}
    for r=0,h-1 do dc:seek(l,t+r):pen(BG):string(string.rep(' ',w)) end
    local hbar=string.rep(string.char(196),w-2)
    dc:seek(l,t):pen(BG):string(string.char(218)..hbar..string.char(191))
    dc:seek(l,t+h-1):pen(BG):string(string.char(192)..hbar..string.char(217))
    for r=1,h-2 do
        dc:seek(l,t+r):pen(BG):string(string.char(179))
        dc:seek(l+w-1,t+r):pen(BG):string(string.char(179))
    end
    dc:seek(l+2,t):pen(COLOR_WHITE):string((' '..self.title..' '):sub(1,w-4))
    if #self.slots==0 then
        dc:seek(l+1,t+1):pen(COLOR_DARKGREY):string('no materials needed')
    end
    for i,s in ipairs(self.slots) do
        local it=s.cands[s.pick]
        local tag=(' [%d/%d]'):format(#s.cands,s.qty)
        local txt,pen
        if it then
            txt=('%d) %s'):format(i,item_label(it))
            pen=(#s.cands<s.qty) and COLOR_LIGHTRED or COLOR_WHITE
        else
            txt=('%d) needs %s'):format(i,s.what or 'an item')
            pen=COLOR_LIGHTRED
        end
        txt=txt:sub(1,w-2-#tag)..tag
        dc:seek(l+1,t+i):pen(pen):string(txt:sub(1,w-2))
    end
    dc:seek(l+1,t+h-2):pen(COLOR_LIGHTGREEN):string('[ Start ]')
    dc:seek(l+11,t+h-2):pen(COLOR_DARKGREY)
        :string(('click a row: choose   Esc: cancel'):sub(1,w-12))
end

function MaterialsPicker:onIdle()
    if self.dismiss_pending then
        local ok,held=pcall(function() return df.global.enabler.mouse_rbut end)
        self.dismiss_grace=(self.dismiss_grace or 30)-1
        if (ok and held==0) or self.dismiss_grace<=0 then
            self:dismiss()
            if self.on_cancel then self.on_cancel() end
        end
    end
end

function MaterialsPicker:onInput(keys)
    if self.dismiss_pending then return end
    local l,t,w,h=self:geom()
    if keys.LEAVESCREEN then
        self:dismiss()
        if self.on_cancel then self.on_cancel() end
        return
    end
    if keys._MOUSE_R or keys._MOUSE_R_DOWN then
        self.dismiss_pending=true
        return
    end
    if keys.SELECT then
        self:dismiss()
        if self.on_confirm then self.on_confirm(self.slots) end
        return
    end
    if keys._MOUSE_L then
        local mx,my=df.global.gps.mouse_x,df.global.gps.mouse_y
        if mx>=l and mx<l+w and my>=t and my<t+h then
            local i=my-t
            if i==h-2 and mx<=l+10 then      -- the [ Start ] button
                self:dismiss()
                if self.on_confirm then self.on_confirm(self.slots) end
                return
            end
            local s=self.slots[i]
            if s then
                pick_slot_material(s,('Slot %d: choose material'):format(i))
            end
            return
        end
        return   -- modal while choosing materials
    end
end

-- fill args.job's items from confirmed slots (picked item first, then the other
-- candidates until each slot's quantity is covered), then hand the items over
local function fill_job_from_slots(args,slots)
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
function close_open_pickers()
    for _=1,6 do
        local vs=dfhack.gui.getCurViewscreen(true)
        local f=dfhack.gui.getFocusStrings(vs)[1] or ''
        if f:find('build%-picker') or f:find('job%-picker') or f:find('advfort/materials') then
            dfhack.screen.dismiss(vs)
        else
            break
        end
    end
end

function showBuildPicker()
    local entries={}
    for _,e in ipairs(build_picker_entries()) do
        if deon_filter(e.fname,e.type,e.subtype,e.custom,nil) then
            table.insert(entries,e)
        end
    end
    -- DEFERRED by 2 frames: the picker can be opened from inside a click's own
    -- input handling, and opening it in that same frame let the very click that
    -- opened it land on whatever entry sits under the cursor -- i.e. it silently
    -- "picked" a random building. Two frames later the press is history.
    dfhack.timeout(2,'frames',function()
        close_open_pickers()
        BuildPicker{entries=entries}:show()
    end)
end

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
local function smooth_variant(tt)
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
local function floor_variant(tt)
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
local function add_skill_exp(unit,skill,amount)
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
-- Web gathering takes AS LONG AS MINING and displays on the same scale: the job pump
-- records the peak completion_timer of every Dig it works (dig_peak -- measured 5 on this
-- build: adv digs count whole WORK ACTIONS, not ticks), and a web counts down from that
-- same small number. Each step costs game ticks like a dig's work action does (~10,
-- shortened by Weaving skill), so the wall-time matches too.
dig_peak=dig_peak or nil
local function GatherWebsChooser(args)
    local web
    for _,v in ipairs(df.global.world.items.other.ANY_WEBS) do
        if same_xyz(v.pos,args.pos) then web=v break end
    end
    if not web then return false,"No web there" end
    args.screen.web_work={
        web_id=web.id,
        pos=copyall(args.pos),
        left=dig_peak or 5,
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
local function do_fell(adv,plant)
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
        left=(dig_peak or 5)*2,   -- felling takes about twice a dig
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
    m.input(args.screen,bld)
    return true
end

-- Predicates ABOUT THE CLICKED TILE, as opposed to readiness ones ("Equip a pick"). When a
-- tile predicate fails on a MOUSE click, the click clearly was not meant for the current job
-- (Dig on a floor, Smooth on a distant floor...) -- it passes through to the game untouched,
-- which usually means walking there. Readiness failures on a valid tile still show on the
-- status line. Keyboard job attempts keep showing every refusal.
local TARGET_PREDS={
    [IsWall]=true,[IsFloor]=true,[IsTree]=true,[IsPlant]=true,[IsConstruct]=true,
    [IsStairs]=true,[IsBuilding]=true,[IsUnit]=true,[IsWater]=true,
    [NotConstruct]=true,[NoConstructedBuilding]=true,[SameSquare]=true,
    [IsHardMaterial]=true,[IsFortification]=true,[IsSmoothableTarget]=true,
    [IsRough]=true,[IsSmoothed]=true,[IsDiggableTarget]=true,[IsWebAt]=true,
}
local actions={
    {"Dig"                ,DigChooser,{MakePredicateWieldsItem(df.job_skill.MINING),IsDiggableTarget}},
    {"Dig Ramp"           ,df.job_type.CarveRamp,{MakePredicateWieldsItem(df.job_skill.MINING),IsWall}},
    {"Dig Channel"        ,df.job_type.DigChannel,{MakePredicateWieldsItem(df.job_skill.MINING)}},
    {"Up Staircase"       ,df.job_type.CarveUpwardStaircase,{MakePredicateWieldsItem(df.job_skill.MINING),IsWall}},
    {"Down Staircase"     ,df.job_type.CarveDownwardStaircase,{MakePredicateWieldsItem(df.job_skill.MINING)}},
    {"Bi Staircase"       ,df.job_type.CarveUpDownStaircase,{MakePredicateWieldsItem(df.job_skill.MINING)}},
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

-- The window layout: each entry is one LINE of segments. A segment {i} shows actions[i]'s
-- name; {i,'text'} overrides the shown text (the stair variants share lines);
-- {label='x'} is inert text. {} is a blank separator line. Segments record their
-- drawn x-range each render for click hit-testing. The Build line shows the
-- CURRENT building selection (what a map click will build); clicking it opens
-- the picker to change it.
local function build_label()
    if not (last_building and last_building.type) then return 'Build...' end
    local t=last_building.type
    local name
    if t==df.building_type.Workshop then
        if last_building.subtype==df.workshop_type.Custom then
            for _,v in ipairs(df.global.world.raws.buildings.all) do
                if v.id==last_building.custom then name=v.name break end
            end
        else name=df.workshop_type[last_building.subtype] end
    elseif t==df.building_type.Furnace then name=df.furnace_type[last_building.subtype]
    elseif t==df.building_type.Trap then name=df.trap_type[last_building.subtype]
    elseif t==df.building_type.Construction then name=df.construction_type[last_building.subtype]
    end
    name=name or df.building_type[t] or '?'
    return 'Build: '..tostring(name):sub(1,16)
end
local LAYOUT={
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

for id,action in pairs(actions) do
    if action[1]==mode_name then
        mode=id-1
        break
    end
end
--luacheck:defclass={mode:{_type:table,name:string,input:'anyfunc:none'},building:df.building_actual,site:df.world_site,in_shop:df.building_workshopst}
usetool=defclass(usetool,gui.Screen)
usetool.focus_path = 'advfort'
--luacheck: out=string
function usetool:getModeName()
    local adv=dfhack.world.getAdventurer()
    local ret
    if adv.job.current_job then
        ret= string.format("%s working(%d) ",(actions[(mode or 0)+1][1] or ""),adv.job.current_job.completion_timer)
    else
        ret= actions[(mode or 0)+1][1] or " "
    end
    if settings.quick then
        ret=ret.."*"
    end
    return ret
end

function usetool:update_site()
    self.current_site=inSite()
end

function usetool:init(args)
    local labors=dfhack.world.getAdventurer().status.labors
    for i,v in ipairs(labors) do
        labors[i]=true
    end
    self:update_site()
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
function usetool:onHelp()
    showHelp()
end
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
function usetool:openPutWindow(building)
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
function usetool:openSiegeWindow(building)
    local args={building=building,screen=self}
    dialog.showListPrompt("Engine job choice", "Choose what to do:",COLOR_WHITE,{"Turn","Load","Fire"},
        dfhack.curry(siegeWeaponActionChosen,args))
end
function usetool:onWorkShopButtonClicked(building,index,choice)
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

function usetool:openShopWindowButtoned(building,no_reset)
    local list={}
    if no_reset then
        -- mid-category browsing (a category/material selector was pressed): stay on
        -- the entity whose button was pressed; the sidebar state carries the category
        self:setupFields(self.menu_entity or nil)
        building:fillSidebarMenu()
        for id,choice in pairs(df.global.game.main_interface.building.button) do
            table.insert(list,{text=utils.call_with_string(choice,"text"),
                               button=choice,entity=self.menu_entity})
        end
    else
        -- WORKSHOP HYGIENE, one job at a time: junk jobs (no worker, no items,
        -- never started) are deleted silently; ORPHANED unfinished jobs (their
        -- worker wandered off or got reassigned) are offered at the TOP of the
        -- menu as explicit "Resume:" entries -- never auto-resumed, that made
        -- mystery jobs start with no visible cause.
        local function job_is_active(bj)
            for _,r in ipairs(bj.general_refs) do
                if r:getType()==df.general_ref_type.UNIT_WORKER then
                    local ok,u=pcall(function() return r:getUnit() end)
                    if ok and u and u.job.current_job==bj then return true end
                end
            end
            return false
        end
        -- COMPLETED leftovers: DF sometimes leaves the job object queued after
        -- the product was made. A finished job's INGREDIENTS were consumed, so
        -- "none of the attached items exist any more" = done, delete -- never
        -- offer a Resume on it. (timer alone cannot tell: -1 means both
        -- never-started and finished.)
        local function job_seems_done(bj)
            if bj.completion_timer>=0 then return false end
            if #bj.items==0 then return false end
            local any_alive=false
            pcall(function()
                for _,ji in ipairs(bj.items) do
                    local it=ji.item
                    if it and df.item.find(it.id)==it then any_alive=true end
                end
            end)
            return not any_alive
        end
        self._resumables={}
        for i=#building.jobs-1,0,-1 do
            local bj=building.jobs[i]
            if not job_is_active(bj) then
                if (#bj.items==0 and bj.completion_timer<0) or job_seems_done(bj) then
                    pcall(smart_job_delete,bj)
                else
                    table.insert(self._resumables,bj)
                end
            end
        end
        -- fresh open: the union of every menu entity's offered jobs (your civ first,
        -- then site-only recipes). Button POINTERS survive only the LAST fill --
        -- earlier entities' rows keep just their label + entity and are re-resolved
        -- by a fresh fill when clicked (see onWorkShopButtonClicked).
        self.menu_entity=nil
        local ents=self:menuEntities()
        local seen={}
        for i,ent in ipairs(ents) do
            self:setupFields(ent or nil)
            building:fillSidebarMenu()
            local last=(i==#ents)
            for id,choice in pairs(df.global.game.main_interface.building.button) do
                local label=utils.call_with_string(choice,"text")
                if not seen[label] then
                    seen[label]=true
                    table.insert(list,{text=label,button=last and choice or nil,entity=ent})
                end
            end
        end
        -- rows collected from earlier fills may alias labels the LAST fill also has;
        -- those can reuse the (fresh) last-fill pointers
        if #ents>1 then
            local fresh={}
            for id,choice in pairs(df.global.game.main_interface.building.button) do
                fresh[utils.call_with_string(choice,"text")]=choice
            end
            for _,row in ipairs(list) do
                if not row.button and fresh[row.text] then
                    row.button=fresh[row.text]
                    row.entity=ents[#ents]
                end
            end
        end
    end
    if #list ==0 and not no_reset then
        print("Fallback")
        self:openShopWindow(building)
        return
        --qerror("No jobs for this workshop")
    end
    local building_name=utils.call_with_string(building,"getName") or "Workshop"

    -- the job menu is a dig-building-style panel like the Build picker (fuzzy
    -- search, columns, left-anchored). Deferred 2 frames so the click that
    -- opened it can never also select an entry.
    local entries={}
    for _,bj in ipairs(self._resumables or {}) do
        table.insert(entries,{label=('Resume: %s'):format(job_name(bj)),data={resume=bj}})
    end
    self._resumables=nil
    for _,c in ipairs(list) do table.insert(entries,{label=c.text,data=c}) end
    dfhack.timeout(2,'frames',function()
        close_open_pickers()
        JobPicker{
            title=building_name,
            entries=entries,
            on_pick=function(choice) self:onWorkShopButtonClicked(building,0,choice) end,
        }:show()
    end)
end
function usetool:openShopWindow(building)
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
function usetool:armCleanTrap(building)
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
function usetool:hiveActions(building)
    local adv=dfhack.world.getAdventurer()
    local args={unit=adv,post_actions={AssignBuildingRef},pos=adv.pos,
    from_pos=adv.pos,job_type=df.job_type.InstallColonyInHive,building=building,screen=self}
    local job_filter={items={{quantity=1,item_type=df.item_type.VERMIN}} }
            args.pre_actions={dfhack.curry(setFiltersUp,job_filter),AssignJobItems}
    makeJob(args)
    --InstallColonyInHive,
    --CollectHiveProducts,
end
function usetool:operatePump(building)
    --TODO: low priotity, but would be nice to have the job auto cleanup (i.e. one work would only pump and then you could press it again)
    local adv=dfhack.world.getAdventurer()
    local set_operate=function ( args )
        args.building.pump_manually=true
    end
    makeJob{unit=adv,building=building,post_actions={AssignBuildingRef,set_operate},pos=adv.pos,from_pos=adv.pos,job_type=df.job_type.OperatePump,screen=self}
end
function usetool:farmPlot(building)
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
function usetool:bedActions(building)
    local adv=dfhack.world.getAdventurer()
    local args={unit=adv,pos=adv.pos,from_pos=adv.pos,screen=self,building=building,
    job_type=df.job_type.Sleep,post_actions={AssignBuildingRef}}
    makeJob(args)
end
--luacheck: in=df.building_chairst out=none
function usetool:chairActions(building)
    local adv=dfhack.world.getAdventurer()
    local eatjob={items={{quantity=1,item_type=df.item_type.FOOD}}}
    local args={unit=adv,pos=adv.pos,from_pos=adv.pos,screen=self,job_type=df.job_type.Eat,building=building,
        pre_actions={dfhack.curry(setFiltersUp,eatjob),AssignJobItems},post_actions={AssignBuildingRef}}
    makeJob(args)
end
MODES={
    [df.building_type.Table]={ --todo filters...
        name="Put items",
        input=usetool.openPutWindow,
    },
    [df.building_type.Coffin]={
        name="Put items",
        input=usetool.openPutWindow,
    },
    [df.building_type.Box]={
        name="Put items",
        input=usetool.openPutWindow,
    },
    [df.building_type.Weaponrack]={
        name="Put items",
        input=usetool.openPutWindow,
    },
    [df.building_type.Armorstand]={
        name="Put items",
        input=usetool.openPutWindow,
    },
    [df.building_type.Cabinet]={
        name="Put items",
        input=usetool.openPutWindow,
    },
    [df.building_type.Workshop]={
        name="Workshop menu",
        input=usetool.openShopWindowButtoned,
    },
    [df.building_type.Furnace]={
        name="Workshop menu",
        input=usetool.openShopWindowButtoned,
    },
    [df.building_type.SiegeEngine]={
        name="Siege menu",
        input=usetool.openSiegeWindow,
    },
    [df.building_type.FarmPlot]={
        name="Plant/Harvest",
        input=usetool.farmPlot,
    },
    [df.building_type.ScrewPump]={
        name="Operate Pump",
        input=usetool.operatePump,
    },
    [df.building_type.Trap]={
        name="Interact",
        input=usetool.armCleanTrap,
    },
    [df.building_type.Hive]={
        name="Hive actions",
        input=usetool.hiveActions,
    },
    [df.building_type.Bed]={
        name="Rest",
        input=usetool.bedActions,
    },
    [df.building_type.Chair]={
        name="Eat",
        input=usetool.chairActions,
    },
}
function usetool:wait_tick()
    self:sendInputToParent("A_SHORT_WAIT")
end
-- Workshop-job materials: the SHARED MaterialsPicker (same one the Build flow
-- uses), replacing the old jobitemEditor. Slots come from the freshly-created
-- job's item filters; confirming fills the job and starts it, cancelling
-- deletes the job again.
function usetool:openJobMaterials(args)
    local job=args.job
    local its=EnumItems_with_settings(args)
    local ok,suitability=pcall(find_suitable_items,job,its)
    if not ok then
        pcall(smart_job_delete,job)
        self:set_status("Item scan failed")
        return
    end
    local slots={}
    for job_id,trg in ipairs(job.job_items.elements) do
        local cands,seen={},{}
        for _,it in pairs(suitability[job_id] or {}) do
            if not seen[it.id] then
                seen[it.id]=true
                cands[#cands+1]=it
            end
        end
        slots[#slots+1]={cands=cands,pick=(#cands>0) and 1 or 0,qty=trg.quantity or 1,
                         what=filter_desc(trg)}
    end
    if #slots==0 then    -- no reagents at all: just run it
        makeJob(args)
        return
    end
    local scr=self
    local title=(utils.call_with_string(args.building,"getName") or 'Job')..' materials'
    dfhack.timeout(2,'frames',function()
        close_open_pickers()
        MaterialsPicker{
            title=title,
            slots=slots,
            on_confirm=function(slots2)
                args.pre_actions={function(a) return fill_job_from_slots(a,slots2) end}
                makeJob(args)
            end,
            on_cancel=function()
                pcall(smart_job_delete,job)
                scr:set_status("Job canceled")
            end,
        }:show()
    end)
end

-- clicking the window's Use Workshop row: use the finished building you stand on
-- (or the first one adjacent) immediately -- no tile click needed
function usetool:use_nearby_workshop()
    local adv=dfhack.world.getAdventurer()
    local function usable(p)
        local bld=dfhack.buildings.findAtTile(p)
        if bld and MODES[bld:getType()] and bld:getBuildStage()==bld:getMaxBuildStage() then
            return bld
        end
    end
    local bld=usable(adv.pos)
    if not bld then
        for _,d in ipairs({{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}}) do
            bld=usable({x=adv.pos.x+d[1],y=adv.pos.y+d[2],z=adv.pos.z})
            if bld then break end
        end
    end
    if not bld then
        self:set_status("No usable building nearby")
        return
    end
    MODES[bld:getType()].input(self,bld)
end
function find_entity_civ( raw_code )
    for i,v in ipairs(df.global.world.entities.all) do
        if v.type==df.historical_entity_type.Civilization and
            v.entity_raw.code==raw_code then
            return v
        end
    end
end
function usetool:menuEntities()
    return recipe_entities()
end
function usetool:setupFields(entity)
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
function usetool:siteCheck()
    if self.site ~= nil or not settings.safe then --TODO: add check if it's correct site (the persistant ones)
        return true
    end
    return false, "You are not on site"
end
-- ---- job list window (styled after fort/dig-building) -----------------------
-- Every job in a bordered, clickable window on the left instead of blind R/T cycling; the
-- current job is highlighted, Shift+R/T still seek through it (warmist's original binds --
-- kept because nearly every unshifted key is a DF adventure command). The bottom row is a
-- STATUS LINE: any reason a job cannot start ("Correct tool not equiped", "Can only do it on
-- walls"...) lands there instead of only flashing past as an announcement.
local JOBWIN_W=26
function usetool:job_win_geom()
    local n=#LAYOUT
    local h=n+4                 -- border+lines+separator+status+border
    local top=math.max(0,math.floor((df.global.gps.dimy-h)/2))   -- centered vertically
    return 0,top,JOBWIN_W,h,n
end
function usetool:set_status(msg)
    self.status_msg=msg
end
function usetool:draw_job_window(dc)
    local l,t,w,h,n=self:job_win_geom()
    local BG={fg=COLOR_GREY,bg=COLOR_BLACK}
    for r=0,h-1 do dc:seek(l,t+r):pen(BG):string(string.rep(' ',w)) end
    local hbar=string.rep(string.char(196),w-2)
    dc:seek(l,t):pen(BG):string(string.char(218)..hbar..string.char(191))
    dc:seek(l,t+h-1):pen(BG):string(string.char(192)..hbar..string.char(217))
    for r=1,h-2 do
        dc:seek(l,t+r):pen(BG):string(string.char(179))
        dc:seek(l+w-1,t+r):pen(BG):string(string.char(179))
    end
    local site=self.current_site
    local title
    if site then title=dfhack.translation.translateName(site.name)
    elseif settings.safe then title='<no site: disabled>'
    else title='<no site: won\'t persist>' end
    dc:seek(l+2,t):pen(site and COLOR_WHITE or COLOR_YELLOW):string((' '..title..' '):sub(1,w-4))
    for li,line in ipairs(LAYOUT) do
        local y=t+li
        local x=l+3
        local line_selected=false
        for _,seg in ipairs(line) do
            seg._x1,seg._x2=nil,nil
            local txt,pen
            if seg.label then
                txt,pen=seg.label,COLOR_GREY
                if seg.click then seg._x1,seg._x2=x,x+#txt-1 end
            elseif seg[1] and (not seg.avail or seg.avail()) then
                txt=seg[2] or actions[seg[1]][1]
                if type(txt)=='function' then txt=txt() end
                local sel=(seg[1]==(mode or 0)+1)
                pen=sel and COLOR_LIGHTGREEN or COLOR_GREY
                if sel then line_selected=true end
                seg._x1,seg._x2=x,x+#txt-1
            end
            if txt then
                dc:seek(x,y):pen(pen):string(txt:sub(1,math.max(0,l+w-1-x)))
                x=x+#txt
            end
        end
        if line_selected then
            dc:seek(l+1,y):pen(COLOR_LIGHTGREEN):string(string.char(26))
        end
    end
    dc:seek(l+1,t+n+1):pen(BG):string(string.rep(string.char(196),w-2))
    local msg,pen
    local cj=dfhack.world.getAdventurer().job.current_job
    -- PROGRESS OWNS THE STATUS LINE: while anything is being worked, the
    -- "(N)" counter always shows -- the job NAME truncates around it, and any
    -- pending status text waits until the work is over
    local function fit(name,left)
        local prog=(' (%d)'):format(left)
        return name:sub(1,math.max(1,w-2-#prog))..prog
    end
    if cj then
        msg,pen=fit(job_name(cj),math.max(0,cj.completion_timer)),COLOR_LIGHTGREEN
    elseif self.web_work then
        msg,pen=fit('gather webs',self.web_work.left),COLOR_LIGHTGREEN
    elseif self.fell_work then
        msg,pen=fit('fell tree',self.fell_work.left),COLOR_LIGHTGREEN
    elseif self.status_msg then
        msg,pen=self.status_msg,COLOR_LIGHTRED
    else
        msg,pen='Click to do jobs',COLOR_DARKGREY
    end
    dc:seek(l+1,t+n+2):pen(pen):string(msg:sub(1,w-2))
end

-- run the current job with full checks; every refusal message goes to the status line
function usetool:try_job(state,cur_mode)
    self.status_msg=nil
    self.queued_job,self.queued_go=nil,nil
    local ok,msg=self:siteCheck()
    if not ok then self:set_status(msg) return false end
    for _,p in pairs(cur_mode[3] or {}) do
        local ok2,msg2=p(state)
        if not ok2 then self:set_status(msg2 or 'Cannot do that there') return false end
    end
    if type(cur_mode[2])=="function" then
        local ok3,msg3=cur_mode[2](state)
        if msg3 then self:set_status(msg3) end
    else
        makeJob(state)
    end
    self:wait_long_start()
    return true
end

-- left-click on the map = do the current job AT THAT TILE (the old SELECT-at-cursor flow,
-- driven by the mouse); getMousePos() is nil over side UI, so those clicks fall through
function usetool:map_click_job()
    local pos=dfhack.gui.getMousePos()
    if not pos then return false end
    local adv=dfhack.world.getAdventurer()
    local cur_mode=actions[(mode or 0)+1]
    -- only adjacent (or own) tiles are job clicks; anything farther is normal game input
    -- (walk there). EXCEPT Build with a multi-tile selection: its CENTER goes on the
    -- clicked tile, so the click may be up to 1+center-offset away -- the footprint
    -- edge is what must touch you.
    local reach=1
    if cur_mode[1]=='Build' and last_building and last_building.type then
        local okz,rot,w,h,cx,cy=pcall(dfhack.buildings.getCorrectSize,nil,nil,
            last_building.type,last_building.subtype,last_building.custom,0)
        if okz and cx then reach=1+math.max(cx,cy or 0) end
    end
    if math.max(math.abs(pos.x-adv.pos.x),math.abs(pos.y-adv.pos.y),math.abs(pos.z-adv.pos.z))>reach then
        return false
    end
    local probe={unit=adv,pos={x=pos.x,y=pos.y,z=pos.z},from_pos=copyall(adv.pos)}
    for _,pr in pairs(cur_mode[3] or {}) do
        if TARGET_PREDS[pr] and not pr(probe) then
            return false   -- tile can never suit this job: not a job click, let the game have it
        end
    end
    local state={
        unit=adv,
        pos={x=pos.x,y=pos.y,z=pos.z},
        dir={0,0,0},
        from_pos=copyall(adv.pos),
        post_actions=cur_mode[4],
        pre_actions=cur_mode[5],
        job_type=cur_mode[2],
        screen=self}
    self:try_job(state,cur_mode)
    return true
end

--movement and co... Also passes on allowed keys
function usetool:fieldInput(keys)
    local adv=dfhack.world.getAdventurer()
    local cur_mode=actions[(mode or 0)+1]
    local failed=false
    for code,_ in pairs(keys) do
        --print(code)
        if MOVEMENT_KEYS[code] then

            local state={
                unit=adv,
                pos=moddedpos(adv.pos,MOVEMENT_KEYS[code]),
                dir=MOVEMENT_KEYS[code],
                from_pos=copyall(adv.pos),
                post_actions=cur_mode[4],
                pre_actions=cur_mode[5],
                job_type=cur_mode[2],
                screen=self}

            if code=="SELECT" then --do job in the distance, TODO: check if you can still cheat-mine (and co.) remotely
                local cursor=guidm.getCursorPos()
                if cursor then
                    state.pos=cursor
                else
                    break
                end
            end

            -- checks + refusal messages all live in try_job (they land on the status line)
            if self:try_job(state,cur_mode) then
                if code=="SELECT" then
                    self:sendInputToParent("LEAVESCREEN")
                end
            end
            return code
        end
        --[[if ALLOWED_KEYS[code] then
            self:sendInputToParent(code)
        end]]
    end
    --if we got to here, we haven't consumed the input i guess?
    self:sendInputToParent(keys)
    return
end

function usetool:onInput(keys)
    self:update_site()
    local adv=dfhack.world.getAdventurer()
    if self.dismiss_pending then return end   -- swallow everything while the dismissal drains
    if keys._MOUSE_R or keys._MOUSE_R_DOWN then
        -- right-click ON the window dismisses the whole tool back to normal play (the pick
        -- icon overlay on the left edge relaunches it). The actual dismiss waits in onIdle
        -- for the physical button RELEASE -- dismissing on the press event handed the still-
        -- held button straight to DF, which dispatched its own right-click action.
        local mx,my=df.global.gps.mouse_x,df.global.gps.mouse_y
        local l,t,w,h=self:job_win_geom()
        if mx>=l and mx<l+w and my>=t and my<t+h then
            self.dismiss_pending=true
            return
        end
        -- EVERY other right-click wants a native response -- DF's right-click actions only
        -- answer HARDWARE clicks; the fed _MOUSE_R this screen forwards is dead to them
        -- (measured repeatedly). So minimize INSTANTLY, unswallowed, wherever the click
        -- lands: the click's own release (or a repeat) reaches the native screen. The icon
        -- overlay AUTO-RESTORES the window once the interaction it triggered has finished.
        auto_restore={stage='start',at=dfhack.getTickCount()}
        icon_active=true
        self:dismiss()
        return
    end
    if keys._MOUSE_L then
        local mx,my=df.global.gps.mouse_x,df.global.gps.mouse_y
        local l,t,w,h,n=self:job_win_geom()
        if mx>=l and mx<l+w and my>=t and my<t+h then
            local row=my-t
            -- clicking the STATUS LINE cancels the current task
            if row==n+2 then
                local u=dfhack.world.getAdventurer()
                local cj2=u and u.job.current_job
                if cj2 then
                    local nm=job_name(cj2)
                    CancelJob(u)
                    pcall(smart_job_delete,cj2)
                    self:cancel_wait()
                    self:set_status(("Canceled: %s"):format(nm))
                    dfhack.gui.showAnnouncement(("You stop working on the %s."):format(nm),7,1)
                end
                return
            end
            local line=row>=1 and row<=n and LAYOUT[row]
            if line then
                for _,seg in ipairs(line) do   -- hit the segment actually clicked
                    if seg._x1 and mx>=seg._x1 and mx<=seg._x2 then
                        local id=seg.click or seg[1]
                        mode=id-1
                        self.status_msg=nil
                        -- clicking the Build row also opens the building picker,
                        -- and Use Workshop opens the menu for the building you
                        -- are standing on / next to right away
                        if actions[id][1]=='Build' then showBuildPicker()
                        elseif actions[id][1]=='Use Workshop' then self:use_nearby_workshop() end
                        break
                    end
                end
            end
            return                          -- consume every click on the window
        end
        if self:map_click_job() then return end
        -- Not the window, not an overlay, not a job click: if the click is not on the MAP
        -- VIEWPORT at all, it aims at native UI chrome (the inventory button and the rest of
        -- the toolbar) -- and those are hover-gated: DF does not even track current_hover
        -- while a Screen covers it (measured: hover=-1 with the mouse parked on the
        -- toolbar). Minimize unswallowed like the right-click path; the icon auto-restores.
        if not dfhack.gui.getMousePos() then
            auto_restore={stage='start',at=dfhack.getTickCount()}
            icon_active=true
            self:dismiss()
            return
        end
        -- a plain far-away map click: fall through so the parent walks there
    end
    if keys.LEAVESCREEN  then
        --get focus string of our parent (i.e. dungeonmode screen)
        local dm_screen=dfhack.gui.getCurViewscreen().parent
        local focus=dfhack.gui.getFocusStrings(dm_screen)
        if focus[1]~="dungeonmode/Default" then --if we are not default, e.g. look/inventory etc
            self:sendInputToParent("LEAVESCREEN") --exit
        else
            -- Escape MINIMIZES to the pick icon (same as right-click dismissal) instead of
            -- quitting outright: the job and its chain keep their state and the icon brings
            -- the window back. (The old full-quit also CancelJob'd, which threw away work.)
            icon_active=true
            self:dismiss()
        end
    elseif keys[keybinds.nextJob.key] then --next job with looping
        mode=(mode+1)%#actions
    elseif keys[keybinds.prevJob.key] then --prev job with looping
        mode=(mode-1)%#actions
    elseif keys["A_SHORT_WAIT"] then
        --ContinueJob(adv)
        df.global.adventure.player_control_state=1 --TODO: figure out what is "more correct here"
        self:sendInputToParent("A_SHORT_WAIT")
    elseif keys[keybinds.quick.key] then
        settings.quick=not settings.quick
    elseif keys[keybinds.continue.key] then
        self:wait_long_start()
    else
        self:fieldInput(keys)
    end

end
-- FIX(too-long prompt) helpers, adapted from adv/im-sure: find the literal button text by
-- reading the rendered screen (the prompt has NO dialog struct), then click it -- targeting
-- the PARENT viewscreen, because a click fed to this dfhack screen is swallowed by onInput.
local function find_screen_text(needle)
    local gps=df.global.gps
    local readTile,char=dfhack.screen.readTile,string.char
    local dimx,dimy=gps.dimx,gps.dimy
    local fx,fy,flen
    pcall(function()
        local row={}
        for y=0,dimy-1 do
            for x=0,dimx-1 do
                local t=readTile(x,y)
                local ch=t and t.ch or 0
                row[x+1]=(ch>=32 and ch<127) and char(ch) or ' '
            end
            local i=table.concat(row,'',1,dimx):find(needle,1,true)
            if i then fx,fy,flen=i-1,y,#needle return end
        end
    end)
    return fx,fy,flen
end

function usetool:dismiss_too_long_prompt()
    -- the ~10k-readTile scan only runs while the prompt state is set, at most every 100ms
    local now=dfhack.getTickCount()
    if now-(self.prompt_last_try or 0)<100 then return end
    self.prompt_last_try=now
    local x,y,len=find_screen_text('Continue waiting')
    if not x then x,y,len=find_screen_text('Continue') end
    if not x then return end
    local gps=df.global.gps
    local cx=x+len//2
    gps.mouse_x,gps.mouse_y=cx,y
    gps.precise_mouse_x=cx*gps.tile_pixel_x+gps.tile_pixel_x//2
    gps.precise_mouse_y=y*gps.tile_pixel_y+gps.tile_pixel_y//2
    require('gui').simulateInput(self._native.parent,'_MOUSE_L')
end

function usetool:wait_long_start(  )
    self.long_wait_timer=nil
    self.long_wait=true
end
function usetool:cancel_wait()
    self.long_wait_timer=nil
    self.long_wait=false
end
function usetool:onIdle()
    if self.dismiss_pending then
        local ok,held=pcall(function() return df.global.enabler.mouse_rbut end)
        self.dismiss_grace=(self.dismiss_grace or 30)-1     -- frame fallback if the read fails
        if (ok and held==0) or self.dismiss_grace<=0 then
            icon_active=true
            self:dismiss()                                   -- job (if any) stays; icon relaunches us
        end
        return
    end
    local adv=dfhack.world.getAdventurer()
    local job_ptr=adv.job.current_job
    local job_action=findAction(adv,df.unit_action_type.Job)

    -- post-completion unstick: a finished building whose impassable tile you are
    -- standing on would trap you -- step one tile to the nearest open spot
    if self.unstick_until then
        if dfhack.getTickCount()>self.unstick_until then
            self.unstick_until=nil
        else
            local function blocked(p)
                local blk=dfhack.maps.getTileBlock(p)
                if not blk then return true end
                local bo=blk.occupancy[p.x%16][p.y%16].building
                return bo==df.tile_building_occ.Impassable or bo==df.tile_building_occ.Obstacle
            end
            if blocked(adv.pos) then
                for _,dd in ipairs({{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}}) do
                    local p={x=adv.pos.x+dd[1],y=adv.pos.y+dd[2],z=adv.pos.z}
                    local tt=dfhack.maps.getTileType(p)
                    local sh=tt and tile_attrs[tt].shape
                    if (sh==df.tiletype_shape.FLOOR or sh==df.tiletype_shape.RAMP
                        or sh==df.tiletype_shape.STAIR_UP or sh==df.tiletype_shape.STAIR_DOWN
                        or sh==df.tiletype_shape.STAIR_UPDOWN) and not blocked(p)
                        and pcall(dfhack.units.teleport,adv,copyall(p)) then
                        dfhack.gui.showAnnouncement("You step off the finished building.",7,1)
                        self.unstick_until=nil
                        break
                    end
                end
            end
        end
    end

    -- FIX(too-long prompt): handle it FIRST, gated on nothing but the prompt state itself --
    -- when it fires mid-job the unit still has its queued Job action (measured live), so any
    -- job/action-based gate never passes. Freeze the deadlock countdown, click the button,
    -- resume waiting.
    if df.global.adventure.player_control_state==df.adventure_game_loop_type.TAKING_TOO_LONG_INPUT then
        self.long_wait_timer=nil               -- re-arms fresh once the prompt is gone
        self:dismiss_too_long_prompt()
        self._native.parent:logic()
        return
    end

    -- FIX(detail-apply): the remembered job target, applied after DF dropped the job --
    -- Smooth jobs get the smooth tiletype; a RemoveFortification dig gets the FLOOR its
    -- material digs to (DF's adv completion wrongly leaves a wall there)
    if self.pending_detail and not job_ptr then
        local pd=self.pending_detail
        self.pending_detail=nil
        local block=dfhack.maps.getTileBlock(pd.pos)
        local tt=block and dfhack.maps.getTileType(pd.pos)
        if tt then
            local target,note
            if pd.want=='floor' then
                target=floor_variant(tt)
                note="The fortification crumbles away."
            else
                target=smooth_variant(tt)
                note="You finish smoothing the "..
                    (df.tiletype.attrs[tt].shape==df.tiletype_shape.FLOOR and "floor." or "wall.")
            end
            if target then
                block.tiletype[pd.pos.x%16][pd.pos.y%16]=target
                dfhack.gui.showAnnouncement(note,7,1)
            end
        end
    end

    -- Chained job (smooth -> engrave/carve): fires when the smoothing job is GONE and its
    -- result is visible -- the target tile is actually smooth. Gating on observed completion
    -- frames does not work: the job can finish and vanish between two onIdle observations
    -- (that is exactly how the chain silently died in testing), while the tile state is
    -- always readable. A gone job with a still-rough tile means canceled/failed: drop.
    if self.queued_job and not job_ptr and not self.pending_detail then
        local q=self.queued_job
        local tt=dfhack.maps.getTileType(q.pos)
        local ready=tt and tile_attrs[tt].special==df.tiletype_special.SMOOTH
        self.queued_job,self.queued_go=nil,nil
        if ready then
            local u=dfhack.world.getAdventurer()
            makeJob{unit=u,pos=q.pos,from_pos=copyall(u.pos),pre_actions=q.pre_actions,
                    job_type=q.job_type,screen=self}
            self:wait_long_start()
            return
        end
    end

    --some heuristics for unsafe conditions
    if self.long_wait and not settings.unsafe then --check if player wants for canceling to happen
        local counters=adv.counters
        -- 'winded' is deliberately NOT here: it is the routine post-sprint/-fight
        -- state, decays on its own, and cancelling on it froze EVERY long job for
        -- an over-exerted adventurer ("stopped waiting: winded" forever). Small
        -- suffocation values tag along with winded, so only a genuinely rising
        -- can't-breathe count (drowning, strangling) cancels.
        local checked_counters={pain=true,stunned=true,unconscious=true,webbed=true,nausea=true,dizziness=true}
        for k,v in pairs(checked_counters) do
            if counters[k]>0 then
                dfhack.gui.showAnnouncement("Job: canceled waiting because unsafe -"..k,5,1)
                self:set_status("stopped waiting: "..k)
                self:cancel_wait()
                return
            end
        end
        if counters.suffocation>50 then
            dfhack.gui.showAnnouncement("Job: canceled waiting because unsafe -suffocation",5,1)
            self:set_status("stopped waiting: suffocation")
            self:cancel_wait()
            return
        end
    end

    -- web gathering work (jobless -- see GatherWebsChooser): pump the timer with waits,
    -- watch position like any job, then collect the thread and award Weaver exp
    if self.web_work then
        local ww=self.web_work
        local web=df.item.find(ww.web_id)
        local d=math.max(math.abs(adv.pos.x-ww.pos.x),
                         math.abs(adv.pos.y-ww.pos.y),
                         math.abs(adv.pos.z-ww.pos.z))
        if not web or not web.flags.spider_web or not same_xyz(web.pos,ww.pos) then
            self:set_status("canceled: the web is gone")
            self.web_work=nil
        elseif d>1 then
            dfhack.gui.showAnnouncement("Job canceled: you were moved away.",5,1)
            self:set_status("canceled: moved away")
            self.web_work=nil
        else
            -- one step per work-action's worth of game ticks, like a dig swing
            local t=df.global.cur_year_tick_advmode
            if t<ww.last_tick then ww.last_tick=t end          -- clock wrapped/loaded
            if t-ww.last_tick>=ww.step_ticks then
                ww.last_tick=t
                ww.left=ww.left-1
            end
            if ww.left<=0 then
                self.web_work=nil
                web.flags.spider_web=false
                if dfhack.items.moveToInventory(web,adv,0,0) then
                    dfhack.gui.showAnnouncement("You gather the web.",7,true)
                    add_skill_exp(adv,df.job_skill.WEAVING,30)
                else
                    web.flags.spider_web=true
                    self:set_status("Could not take the web")
                end
            else
                self:sendInputToParent("A_SHORT_WAIT")
            end
        end
        self._native.parent:logic()
        return
    end

    -- tree felling work (jobless -- see FellTreeChooser): pump the timer with
    -- waits like a dig, then fell the tree by hand and award Wood Cutter exp
    if self.fell_work then
        local fw=self.fell_work
        local plant=dfhack.maps.getPlantAtTile(fw.ppos)
        local d=math.max(math.abs(adv.pos.x-fw.pos.x),
                         math.abs(adv.pos.y-fw.pos.y),
                         math.abs(adv.pos.z-fw.pos.z))
        if not plant or not plant.tree_info then
            self:set_status("canceled: the tree is gone")
            self.fell_work=nil
        elseif d>1 then
            dfhack.gui.showAnnouncement("Job canceled: you were moved away.",5,1)
            self:set_status("canceled: moved away")
            self.fell_work=nil
        else
            local t=df.global.cur_year_tick_advmode
            if t<fw.last_tick then fw.last_tick=t end          -- clock wrapped/loaded
            if t-fw.last_tick>=fw.step_ticks then
                fw.last_tick=t
                fw.left=fw.left-1
            end
            if fw.left<=0 then
                self.fell_work=nil
                local ok,logs=pcall(do_fell,adv,plant)
                if ok then
                    dfhack.gui.showAnnouncement(
                        ('The tree falls! You cut %d log%s.'):format(logs,logs==1 and '' or 's'),7,true)
                    add_skill_exp(adv,df.job_skill.WOODCUTTING,30)
                else
                    self:set_status("felling failed")
                    print("advfort fell error:",logs)
                end
            else
                self:sendInputToParent("A_SHORT_WAIT")
            end
        end
        self._native.parent:logic()
        return
    end

    -- Position watchdog: working requires staying put, and the game can MOVE you mid-job
    -- (water currents, knockback). A worker carried out of reach leaves a job that can
    -- never finish -- the wait loop would just spin. Track where the current job started;
    -- a nudge that keeps you within 1 tile of the job re-anchors and keeps working, but
    -- ending up farther away cancels the job (and any queued chain) cleanly.
    if job_ptr and self.long_wait then
        if self.work_job~=job_ptr.id then
            self.work_job=job_ptr.id
            self.work_pos=copyall(adv.pos)
            self.job_started=nil
        elseif not same_xyz(adv.pos,self.work_pos) then
            local d=math.max(math.abs(adv.pos.x-job_ptr.pos.x),
                             math.abs(adv.pos.y-job_ptr.pos.y),
                             math.abs(adv.pos.z-job_ptr.pos.z))
            -- construct jobs anchor at the building CENTER and you legitimately
            -- walk around a multi-tile site (or toward it) mid-job -- only treat
            -- clearly leaving as "moved away"
            local limit=job_ptr.job_type==df.job_type.ConstructBuilding and 3 or 1
            if d>limit then
                dfhack.gui.showAnnouncement("Job canceled: you were moved away.",5,1)
                self:set_status("canceled: moved away")
                local j=job_ptr
                CancelJob(adv)
                pcall(smart_job_delete,j)
                self:cancel_wait()
                self.work_job=nil
                self.queued_job,self.queued_go=nil,nil
                return
            else
                self.work_pos=copyall(adv.pos)   -- nudged but still in reach: keep going
            end
        end
    elseif not job_ptr then
        self.work_job=nil
    end

    if self.long_wait and self.long_wait_timer==nil then
        self.long_wait_timer=1000 --TODO tweak this
    end

    if job_ptr and self.long_wait and not job_action then

        -- Building-anchored jobs (construction AND workshop tasks): DF only works
        -- them -- and otherwise silently CULLS them -- while you are within 1
        -- tile of the job anchor, the building's CENTER (measured live: a shield
        -- job from 2 tiles away vanished with no product; from 1 tile it
        -- completed). Pause with guidance instead of letting the job be eaten.
        do
            local anchored=job_ptr.job_type==df.job_type.ConstructBuilding
            if not anchored then
                for _,r in ipairs(job_ptr.general_refs) do
                    if r:getType()==df.general_ref_type.BUILDING_HOLDER then anchored=true end
                end
            end
            if anchored then
                local d=math.max(math.abs(adv.pos.x-job_ptr.pos.x),
                                 math.abs(adv.pos.y-job_ptr.pos.y),
                                 math.abs(adv.pos.z-job_ptr.pos.z))
                if d>1 then
                    self:set_status("Stand by the building's center to work")
                    self._native.parent:logic()
                    return
                end
            end
        end

        if self.long_wait_timer<=0 then --fix deadlocks with force-canceling of waiting
            self:cancel_wait()
            return
        else
            self.long_wait_timer=self.long_wait_timer-1
        end

        -- learn how long mining takes from the digs actually worked (web gathering copies it)
        if adv.job.current_job.completion_timer>0 then
            self.job_started=true          -- reset when work_job changes (watchdog)
        end
        if adv.job.current_job.job_type==df.job_type.Dig
                and adv.job.current_job.completion_timer>(dig_peak or 0) then
            dig_peak=adv.job.current_job.completion_timer
        end
        -- -1 is BOTH "finished" and "never started": a virgin workshop job sits
        -- at -1 until its first work action lands, and reading that as done
        -- stalled every workshop task one kick in. Only a job we have SEEN
        -- running (timer>0) is done at -1; a virgin one keeps getting kicked.
        if adv.job.current_job.completion_timer==-1 and self.job_started then
            local jt=adv.job.current_job.job_type
            local jpos=adv.job.current_job.pos
            if jt==df.job_type.SmoothFloor or jt==df.job_type.SmoothWall then
                self.pending_detail={pos=copyall(jpos),want='smooth'}
            elseif jt==df.job_type.Dig and self.fort_pos and same_xyz(jpos,self.fort_pos) then
                self.pending_detail={pos=copyall(jpos),want='floor'}
                self.fort_pos=nil
            elseif jt==df.job_type.ConstructBuilding then
                -- watch for a couple seconds after completion: if the finished
                -- building's impassable tiles seal the adventurer in, step off
                self.unstick_until=dfhack.getTickCount()+3000
            end
            self.long_wait=false
            -- Workshop tasks: DF leaves the COMPLETED job attached as your
            -- current job and queued at the shop -- the status line froze at
            -- "(0)" forever and the husk clogged the queue. Ingredients all
            -- consumed = truly done: announce, unhook, delete the husk.
            local cj2=adv.job.current_job
            if cj2 and #cj2.items>0 then
                local any_alive=false
                pcall(function()
                    for _,ji in ipairs(cj2.items) do
                        local it=ji.item
                        if it and df.item.find(it.id)==it then any_alive=true end
                    end
                end)
                if not any_alive then
                    local nm=job_name(cj2)
                    CancelJob(adv)
                    pcall(smart_job_delete,cj2)
                    self:set_status(("Finished: %s"):format(nm))
                    dfhack.gui.showAnnouncement(("Finished: %s."):format(nm),7,true)
                end
            end
        end
        ContinueJob(adv)
        self:sendInputToParent("A_SHORT_WAIT") --todo continue till finished
    end
    self._native.parent:logic()
end
function usetool:isOnBuilding()
    local adv=dfhack.world.getAdventurer()
    local bld=dfhack.buildings.findAtTile(adv.pos)
    if bld and MODES[bld:getType()]~=nil and bld:getBuildStage()==bld:getMaxBuildStage() then
        return true,MODES[bld:getType()],bld
    else
        return false
    end
end
function usetool:onRenderBody(dc)
    self:renderParent()
    self:draw_job_window(dc)
end
-- ---- base-game pick icon ----------------------------------------------------
-- Lives as a real OVERLAY on the dungeonmode screen, so while the advfort window is
-- dismissed the game plays completely normally -- the advfort Screen is gone, nothing
-- intercepts input -- except this one glyph, centered on the left edge, which relaunches
-- the tool. Invisible (and inert) unless a window was dismissed this session.
icon_active=icon_active or false   -- script env survives; the icon outlives the Screen

AdvfortIcon=defclass(AdvfortIcon,overlay.OverlayWidget)
AdvfortIcon.ATTRS{
    desc='Pick icon that reopens the dismissed adv/advfort window.',
    default_pos={x=1,y=30},
    default_enabled=true,
    viewscreens='dungeonmode/Default',
    frame={w=1,h=1},
    overlay_onupdate_max_freq_seconds=0,
}

function AdvfortIcon:relaunch()
    auto_restore=nil
    if dfhack.gui.matchFocusString('dungeonmode/Default')
            or dfhack.gui.matchFocusString('dungeonmode/Look') then
        icon_active=false
        pcall(function() usetool():show() end)
    end
end

function AdvfortIcon:overlay_onupdate()
    -- keep the icon completely centered on the left screen edge
    local ir=gui.get_interface_rect()
    local t=math.floor((df.global.gps.dimy-1)/2)-ir.y1
    if self.frame.t~=t or self.frame.l~=0 then
        self.frame={w=1,h=1,l=0,t=t}
        self:updateLayout(gui.ViewRect{rect=ir})
    end
    -- Auto-restore after a right-click passthrough minimize: wait for the interaction the
    -- click triggered (a menu opening / focus leaving Default) to START and then FINISH,
    -- and bring the window back. If nothing starts within 2s the click acted instantly
    -- (right-click-move walking, empty tile) -- restore anyway.
    if icon_active and auto_restore then
        local ol=df.global.game.main_interface.adventure.option_list
        local busy=ol.open or not dfhack.gui.matchFocusString('dungeonmode/Default')
        if auto_restore.stage=='start' then
            if busy then
                auto_restore.stage='end'
            elseif dfhack.getTickCount()-auto_restore.at>2000 then
                self:relaunch()
            end
        elseif not busy then
            self:relaunch()
        end
    end
end

function AdvfortIcon:onRenderBody(dc)
    if not icon_active or not dfhack.world.isAdventureMode() then return end
    dc:seek(0,0):pen{fg=COLOR_YELLOW,bg=COLOR_BLACK}:string(string.char(207))
end

function AdvfortIcon:onInput(keys)
    if not icon_active or not dfhack.world.isAdventureMode() then return false end
    if keys._MOUSE_L and self:getMousePos() then
        if dfhack.gui.matchFocusString('dungeonmode/Default')
                or dfhack.gui.matchFocusString('dungeonmode/Look') then
            icon_active=false
            pcall(function() usetool():show() end)
        end
        return true
    end
    return false
end

OVERLAY_WIDGETS={icon=AdvfortIcon}

if dfhack_flags and dfhack_flags.module then return end

if not (dfhack.gui.matchFocusString('dungeonmode/Look') or dfhack.gui.matchFocusString('dungeonmode/Default')) then
    qerror("This script requires an adventurer mode with (l)ook or default mode.")
end
usetool():show()
