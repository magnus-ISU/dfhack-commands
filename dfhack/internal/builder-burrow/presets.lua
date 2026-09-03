-- Stamps, districts and presets shipped with fort/builder-burrow.
--
-- A stamp is a grid of rows of quickfort codes; names give the INTERIOR size.
--   ' ' blank (not footprint)  '.' floor  d door  b bed  t table  c chair
--   f cabinet  h chest  r weapon rack  a armor stand  s statue  x coffin
--   P pedestal  A altar  B bookcase  i stair  F farm plot  # built wall (surface)
-- A stamp may be {floors = {ground, first, ...}} for a multi-z blueprint.
--
-- A stamp may declare `zone`, the activity zone the finished room carries, written as
-- the quickfort zone code the blueprint will use: 'b' bedroom, 'o' office, 'h' dining
-- hall, 'T' tomb, 'm' meeting area, 'D' dormitory, 'B' barracks. A stamp with no `zone`
-- gets none -- which is what a catacomb or a family tomb wants, since a DF tomb belongs
-- to one dwarf and those rooms hold many coffins (fort/auto-tomb zones each coffin).
--
-- A district is a group of stamps with a packing rule: `set` = a suite whose
-- first slot is the hub with the only road door and whose other slots attach
-- wall to wall; otherwise stamps repeat along the road. `margin` is extra rock
-- between neighbouring rooms, `maxLen` the road length one district may take,
-- `depth` how far a suite may grow from the road, `shared` (surface) lets built
-- walls overlap the neighbour's. Hallway pieces (road stamps) belong to presets.
--@module = true

local G = {
    hovel     = {'d', 'b', 'f', 'h'},
    house2    = {'d ', '.f', 'bh'},
    house3    = {' d ', '...', 'fbh', '...'},
    luxury3   = {' d ', 'f.h', 'rbs', 'a.A'},
    nbed      = {' d ', 'f.h', '.b.', '...'},
    nbed4     = {'  d ', 'f..h', '..b.', '....', '....'},
    nbed35    = {' d ', 'f.h', '...', '.b.', '...', '...'},
    noffice   = {' d ', '...', 'tc.', 'f.h'},
    noffice4  = {'  d ', '....', 'tc..', 'c...', 'f..h'},
    ndining   = {'  d  ', '.....', '.ttt.', '.ccc.', 'f...h'},
    ndining7  = {'   d   ', '.......', '..ttt..', '..ccc..', '.......', 'f.....h'},
    ndining3  = {' d ', '...', 'tc.', 'f.h'},
    dhall73   = {'   d   ', 'f.....h', '.ttttt.', '.ccccc.'},
    ntomb     = {' d ', '...', '.x.', 'f.h'},
    ntomb5    = {'  d  ', 's...s', '..x..', 'f...h'},
    ngarden3  = {' d ', 's.s', '...', 's.s'},
    ngarden5  = {'  d  ', 's...s', '.....', '..s..', 's...s'},
    nthrone   = {'  d  ', '.....', '.....', '..c..', 'f.s.h'},
    nlibrary  = {'  d  ', 'B...B', '.tc..', 'B...B', 'f...h'},
    plaza7    = {'.......', '.s...s.', '.......', '...s...', '.......', '.s...s.', '.......'},
    seg13     = {'s.....s.....s', '.............', 's.....s.....s'},
    catacomb  = {'   d   ', 'x.....x', 'x.....x', 'x..s..x', 'x.....x', 'x.....x', 'x..s..x', 'x.....x', 'x.....x'},
    memorial  = {'  d  ', '.....', '.s.s.', '..x..', '.....'},
    family    = {' d ', 'x.x', '...', 'x.x', '...'},
    coffinrow = {'x.....x.....x', '.............', 'x.....x.....x'},
    shrine5   = {'.....', '.x.x.', '..s..', '.x.x.', '.....'},
    forge     = {'  d  ', 'a...a', 'r.P.r', '..A..', 's...s'},
    sea       = {'  d  ', 's...s', '.....', '..P..', '.....', '..A..', 's...s'},
    dead      = {'  d  ', 'x...x', '..P..', 'x.A.x', 'x...x'},
    grove     = {'   d   ', 's.....s', '.......', '..s.s..', '...P...', '..s.s..', '...A...', 's.....s'},
    sanctum   = {'   d   ', '.......', '.P...P.', '...A...', '.P...P.', '.......', 's.....s'},
    vestry    = {' d ', 'f.h', '..P', '...'},
    cloister  = {'  d  ', 's...s', '.....', '..P..', 's...s'},
    crypt     = {' d ', 'x.x', '...', 'x.x', '.P.'},
    nave      = {'    d    ', '.........', '.cc...cc.', '.cc...cc.', '.cc...cc.', '....P....', '..s.A.s..', '.........'},
    chapel    = {' d ', '...', '.A.', 'P..'},
    masons    = {'   d   ', 's.....s', '.tt.tt.', '.cc.cc.', '...P...', 'f.....h'},
    smiths    = {'   d   ', 'r.....r', '.tt.tt.', '.cc.cc.', 'a..P..a', 'f.....h'},
    scholars  = {'   d   ', 'B.....B', '.tt.tt.', '.cc.cc.', 'B..P..B', 'f.....h'},
    brewers   = {'  d  ', 'h...h', '.t.t.', '.c.c.', '..P..', 'h...h'},
    merchants = {'   d   ', '.......', '.ttttt.', '.ccccc.', '...P...', 'f.s.s.h'},
    counting  = {' d ', 'tc.', '...', 'f.h'},
    vault     = {' d ', 'hhh', '...', 'hPh'},
    warriors  = {'   d   ', 'r.....r', '.ttttt.', '.ccccc.', 'a..P..a', 's.....s'},
    armory    = {'  d  ', 'r.r.r', '.....', 'a.a.a'},
    barracks  = {'  d  ', 'b.b.b', '.....', 'h.f.h'},
}
STAMPS = G

local ROW = {name = 'statue row 13x3', grid = G.seg13}
local GARDEN = {name = 'statue garden 7x7', grid = G.plaza7}
local COFFIN = {name = 'coffin row 13x3', grid = G.coffinrow}
local SHRINE = {name = 'shrine 5x5', grid = G.shrine5}

DISTRICTS = {
    ['hovels']       = {margin = 0, maxLen = 16, stamps = {{name = 'hovel 1x4', grid = G.hovel, zone = 'b'}}},
    ['houses 2x2']   = {margin = 0, maxLen = 16, stamps = {{name = 'house 2x2', grid = G.house2, zone = 'b'}}},
    ['houses 3x3']   = {margin = 0, maxLen = 16, stamps = {{name = 'house 3x3', grid = G.house3, zone = 'b'}}},
    ['luxury 3x3']   = {margin = 1, maxLen = 16, stamps = {{name = 'luxury house 3x3', grid = G.luxury3, zone = 'b'}}},
    ['dining halls'] = {margin = 1, maxLen = 10, stamps = {{name = 'dining hall 7x3', grid = G.dhall73, max = 1, zone = 'h'}}},
    ['noble'] = {margin = 1, set = true, depth = 16,
        stamps = {
            {name = 'dining (hub)', zone = 'h', alts = {{grid = G.ndining, weight = 2, name = 'dining 5x4'}, {grid = G.ndining7, name = 'dining 7x5'}}},
            {name = 'bedroom', zone = 'b', alts = {{grid = G.nbed, weight = 2, name = 'bedroom 3x3'}, {grid = G.nbed4, name = 'bedroom 4x4'}, {grid = G.nbed35, name = 'bedroom 3x5'}}},
            {name = 'office', zone = 'o', alts = {{grid = G.noffice, weight = 2, name = 'office 3x3'}, {grid = G.noffice4, name = 'office 4x4'}}},
            {name = 'tomb', zone = 'T', alts = {{grid = G.ntomb, weight = 2, name = 'tomb 3x3'}, {grid = G.ntomb5, name = 'tomb 5x3'}}},
        },
        optional = {
            {name = 'sculpture garden', max = 2, alts = {{grid = G.ngarden3, name = 'garden 3x3'}, {grid = G.ngarden5, name = 'garden 5x5'}}},
            {name = 'throne room / library', max = 1, alts = {{grid = G.nthrone, name = 'throne room 5x5', zone = 'o'}, {grid = G.nlibrary, name = 'library 5x5'}}},
        }},
    ['minor noble'] = {margin = 1, set = true, depth = 12,
        stamps = {{name = 'bedroom 3x3 (hub)', zone = 'b', alts = {{grid = G.nbed}}}},
        optional = {
            {name = 'dining 3x3', max = 1, zone = 'h', alts = {{grid = G.ndining3}}},
            {name = 'office 3x3', max = 1, zone = 'o', alts = {{grid = G.noffice}}},
            {name = 'tomb 3x3', max = 1, zone = 'T', alts = {{grid = G.ntomb}}},
        }},
    ['catacombs']    = {margin = 0, maxLen = 12, stamps = {{name = 'catacomb 7x9', grid = G.catacomb, max = 1}}},
    ['memorials']    = {margin = 1, maxLen = 8, stamps = {{name = 'memorial 5x5', grid = G.memorial, max = 1, zone = 'T'}}},
    ['family tombs'] = {margin = 0, maxLen = 12, stamps = {{name = 'family tomb 3x5', grid = G.family}}},
    ['forge shrines'] = {margin = 1, maxLen = 10, stamps = {{name = 'shrine of the forge 5x5', grid = G.forge, max = 1}}},
    ['sea shrines']   = {margin = 1, maxLen = 10, stamps = {{name = 'shrine of the sea 5x7', grid = G.sea, max = 1}}},
    ['chapels of the dead'] = {margin = 1, maxLen = 10, stamps = {{name = 'chapel of the dead 5x5', grid = G.dead, max = 1}}},
    ['groves']       = {margin = 1, maxLen = 12, stamps = {{name = 'grove of nature 7x8', grid = G.grove, max = 1}}},
    ['temple complex'] = {margin = 1, set = true, depth = 20,
        stamps = {{name = 'sanctum 7x7 (hub)', alts = {{grid = G.sanctum}}}, {name = 'vestry 3x4', alts = {{grid = G.vestry}}}, {name = 'cloister 5x5', alts = {{grid = G.cloister}}}},
        optional = {{name = 'crypt 3x5', max = 1, alts = {{grid = G.crypt}}}, {name = 'library 5x5', max = 1, alts = {{grid = G.nlibrary}}}}},
    ['great temple'] = {margin = 1, set = true, depth = 20,
        stamps = {{name = 'nave 9x8 (hub)', alts = {{grid = G.nave}}}, {name = 'side chapel 3x4', alts = {{grid = G.chapel}}}, {name = 'second chapel 3x4', alts = {{grid = G.chapel}}}, {name = 'vestry 3x4', alts = {{grid = G.vestry}}}},
        optional = {{name = 'crypt 3x5', max = 2, alts = {{grid = G.crypt}}}}},
    ["masons' guild"]   = {margin = 1, maxLen = 10, stamps = {{name = "masons' hall 7x6", grid = G.masons, max = 1}}},
    ["smiths' guild"]   = {margin = 1, maxLen = 10, stamps = {{name = "smiths' hall 7x6", grid = G.smiths, max = 1}}},
    ["scholars' guild"] = {margin = 1, maxLen = 10, stamps = {{name = "scholars' hall 7x6", grid = G.scholars, max = 1}}},
    ["brewers' guild"]  = {margin = 1, maxLen = 8, stamps = {{name = "brewers' hall 5x6", grid = G.brewers, max = 1}}},
    ["merchants' guild"] = {margin = 1, set = true, depth = 18,
        stamps = {{name = "merchants' hall 7x6 (hub)", alts = {{grid = G.merchants}}}, {name = 'counting room 3x3', zone = 'o', alts = {{grid = G.counting}}}, {name = 'vault 3x3', alts = {{grid = G.vault}}}},
        optional = {{name = 'second vault 3x3', max = 1, alts = {{grid = G.vault}}}}},
    ["warriors' guild"] = {margin = 1, set = true, depth = 18,
        stamps = {{name = "warriors' hall 7x6 (hub)", alts = {{grid = G.warriors}}}, {name = 'armory 5x3', alts = {{grid = G.armory}}}, {name = 'barracks 5x3', alts = {{grid = G.barracks}}}},
        optional = {{name = 'second barracks 5x3', max = 1, alts = {{grid = G.barracks}}}}},
}

-- ordered so the picker lists them in a sensible order
PRESET_ORDER = {'hovels', 'housing 2x2', 'housing 3x3', 'luxury housing', 'varied housing',
                'noble quarters', 'tombs', 'temples', 'guildhalls'}
PRESETS = {
    ['hovels']         = {main = 1, side = 1, districts = {{name = 'hovels'}}},
    ['housing 2x2']    = {main = 2, side = 2, districts = {{name = 'houses 2x2'}}},
    ['housing 3x3']    = {main = 1, side = 1, districts = {{name = 'houses 3x3'}}},
    ['luxury housing'] = {main = 3, side = 3, road = {ROW}, districts = {{name = 'luxury 3x3'}},
                          second = {{name = 'luxury 3x3', weight = 3}, {name = 'dining halls', weight = 1}}},
    ['varied housing'] = {main = 3, side = 1, road = {ROW},
                          districts = {{name = 'hovels', weight = 1}, {name = 'houses 2x2', weight = 2}, {name = 'houses 3x3', weight = 2}, {name = 'luxury 3x3', weight = 1}}},
    ['noble quarters'] = {main = 3, side = 3, road = {ROW, GARDEN}, districts = {{name = 'noble'}},
                          second = {{name = 'noble', weight = 1}, {name = 'minor noble', weight = 2}}},
    ['tombs']          = {main = 3, side = 3, road = {COFFIN, SHRINE, ROW},
                          districts = {{name = 'catacombs', weight = 2}, {name = 'memorials', weight = 1}, {name = 'family tombs', weight = 2}}},
    ['temples']        = {main = 3, side = 3, road = {ROW, GARDEN, COFFIN},
                          districts = {{name = 'forge shrines', weight = 2}, {name = 'sea shrines', weight = 2}, {name = 'chapels of the dead', weight = 2}, {name = 'groves', weight = 1}, {name = 'temple complex', weight = 2}, {name = 'great temple', weight = 1}}},
    ['guildhalls']     = {main = 3, side = 3, road = {ROW},
                          districts = {{name = "masons' guild", weight = 2}, {name = "smiths' guild", weight = 2}, {name = "scholars' guild", weight = 1}, {name = "brewers' guild", weight = 2}, {name = "merchants' guild", weight = 1}, {name = "warriors' guild", weight = 1}}},
}

return {STAMPS = STAMPS, DISTRICTS = DISTRICTS, PRESETS = PRESETS, PRESET_ORDER = PRESET_ORDER}
