# Adventure mode

## Adventure mode features

### **`adv/auto-save`** 
Save adventurer mode automatically. `adv/auto-save enable 20` to save every
  20 minutes, which is default. 1 hour must pass in-game between autosaves.

![adv/auto-save demo](demos/adv-auto-save.png)

### **`adv/map-travel`** 
Allow clicking to travel more than 1 tile in fast travel, like in
  non-fast-travel.

![adv/map-travel demo](demos/adv-map-travel.gif)

### **`adv/reveal`** 
Adventure mode reveal only when not in combat. You can easily navigate around
  a castle, dark goblin pit, dwarven fortress, or find a lair, and then not get an advantage in
  combat. It automatically re-enables when you leave fast traveling.

![adv/reveal demo](demos/adv-reveal.gif)

### **`adv/always-be-satiated`** 
Automatically eat and drink (non healing potions) when not in
  combat.

![adv/always-be-satiated demo](demos/adv-always-be-satiated.gif)

### **`adv/keep-inventory`** 
Automatically reopen the inventory and scroll to the last position
  when you use it.

![adv/keep-inventory demo](demos/adv-keep-inventory.gif)

### **`adv/inventory-display-weight`** 
Show every item's weight in the inventory list and the pick-up menu.

![adv/inventory-display-weight demo](demos/adv-inventory-display-weight.png)

### **`adv/inventory-search`** 
Search the inventory list (Alt-S) by item description, material or type.
  Magic words: `heavy` sorts by weight, `equip`/`equipped` shows equipped items
  (hands always first, then strapped weapons/tools, containers last), `food` shows food and drink (drinks, food,
  healing drinks, healing food, then ethics-refused sapient flesh; containers
  excluded), `healing` shows food/drink with beneficial syndromes. The unsearched list
  displays in the equip order by default. keep-inventory reopens keep the filter.

![adv/inventory-search demo](demos/adv-search-inventory.png)
![adv/inventory-search sort demo](demos/adv-sort-inventory.png)

### **`adv/travelling-hunger`** 
Show how many meals, drinks and 8-hour sleeps you need on the fast-travel screen's top row.

### **`adv/heat-ice`** 
Sort "heat ice" / "heat snow" options to the top of interact menus.

![adv/heat-ice demo](demos/adv-sort-ice.png)

### **`adv/advfort`** 
Do fort jobs as an adventurer: community rework of DFHack's paused `gui/advfort`
  (jobs on CAREFUL move, so walking and the look cursor work; separate Smooth vs
  Detail/engrave jobs) plus local fixes: the "you haven't acted in a while" prompt
  no longer wedges a long wait, and Smooth jobs designate their tile and actually
  smooth it on completion. Fell Tree really fells trees (DF's adventure engine
  silently discards FellTree jobs, so advfort does the work itself: axe-skill-timed
  chopping, then the tree comes down — one log per trunk tile at the base, Wood
  Cutter experience awarded; neighboring trees are untouched). The window's Build
  line shows the current building
  selection and a map click builds exactly that, dialog-free; clicking the Build
  line opens the picker — one flat searchable list of everything buildable in a
  dig-building-style multi-column left-anchored panel, with a materials pane
  alongside showing which items each slot will consume (click to swap among
  suitable items from your inventory and the nearby ground). The workshop job
  menu uses the same panel style (fuzzy search, columns, right-click dismiss):
  click the window's "Use Workshop" action and the menu for the building you
  stand on or next to opens immediately (workshops and furnaces open their
  recipes; beds rest, chairs eat, farm plots plant/harvest, traps and siege
  engines their menus). Recipes default to
  your civilization's plus those of the site you are standing in (`-e` still
  forces a specific entity); custom workshops only appear if one of those civs
  can build them, tagged with the owning civ when unique — "Shaping Tree
  (high elf)", "Breeding Pit (orc)".

### **`adv/exhaustion-meter`** 
Combat-exertion bar with the native blood meter's manners and placement:
  invisible while you're fine, appearing in the blood meter's bottom-left
  corner once exertion matters, empty = you collapse. Tracks the counter built
  by attacking/sprinting/jumping that knocks you over mid-fight (DF shows no
  meter for it): yellow at Tired (2,000), red at Exhausted (4,000), empty at
  the ~6,000 falling-over point; decays when you stop exerting. Overlay
  `adv/exhaustion-meter.meter`, enabled by default (gui/overlay moves it).

### **`adv/posession`** 
[Regain your weapon] button on the "Who will you attack?" screen while you are
  struggling over possession of a weapon (grabbed from you, or stuck in someone
  pulling on it): one click selects whoever shares the weapon with you and
  initiates the native possession-struggle Wrestle attack. Dormant otherwise;
  overlay `adv/posession.regain`, enabled by default.

### **`adv/keep-talking`** 
Automatically reopen a conversation you are participating in.

![adv/keep-talking demo](demos/adv-keep-talking.gif)

### **`adv/read-the-map`** 
Allow hovering over sites to learn about them in fast travel.

![adv/read-the-map demo](demos/adv-read-the-map.png)

### **`adv/right-click-move`** 
Right clicking (if it gives no other options) automatically
  initiates movement, dismissing when the game annoyingly asks for two confirmations. Saves 3
  mouse clicks / key presses for a basic action.

![adv/right-click-move demo](demos/adv-right-click-move.gif)

### **`adv/watch-their-blade`** 
The attack screens show a combat summary under each name — every
  candidate on the "Who will you attack?" chooser, and your target on the attack
  screens after you pick: their wounds ("Faint, Heavy Bleeding"), worn armor
  ("iron greaves, iron breastplate") and what they are holding, by hand ("Left
  hand silver carving knife, right hand copper whip") — including sheathed
  weapons. Pick your target, and your fight, with open eyes.

![adv/watch-their-blade demo](demos/adv-watch-their-blade.png)

### **`smooth-movement`** 
Smooth camera panning in adventure mode, and smooth movement for
  creatures and the player in adventure mode. (A C++ plugin rather than a script — install it
  with `make install`.)

![smooth-movement demo](demos/adv-smooth-camera.gif)

### **`adv/im-sure`** 
Automatically dismiss "you haven't acted in a while" for long-running move
  commands.

![adv/im-sure demo](demos/adv-im-sure.gif)

## Adventure mode embark features

### **`embark/adventurer-values`** 
Modify adventurer needs easily when you create your adventurer
  — so you can make a barbarian who loves to fight or avoid the impossible-to-satisfy Intense Need
  For Family (without memorizing which values affect which needs, where they are in the list,
  etc).

![embark/adventurer-values demo](demos/embark-adventurer-values.png)

### **`embark/adventurer-default-items`** 
Automatically give you a decent starting gear loadout
  when creating an adventurer, and let you switch metals on your gear more easily.

![embark/adventurer-default-items demo](demos/embark-adventurer-default-items.png)

### **`embark/adventurer-map`**
Show information about sites on the world map during adventurer creation. Clicking on a
site changes your origin to there, if possible.

![embark/adventurer-map demo](demos/embark-adventurer-map.gif)
