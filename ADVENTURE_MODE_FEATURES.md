# Adventure mode

## Adventure mode features

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

### **`adv/auto-save`** 
Save adventure mode automatically: `adv/auto-save` saves right now by
  driving DF's own escape-menu flow; `enable [min]` repeats it every N minutes
  (default 20). A save only fires once BOTH clocks agree — N wall-clock minutes
  AND two in-game hours since the last save — so an idle game is never saved over
  and over, and only from a quiet screen (no menus, no conversation), so it never
  fights a menu stack you are in the middle of.

![adv/auto-save demo](demos/adv-auto-save.png)

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
The Background tab of adventurer creation shows a world map that names nothing. This hovers
the same site card `adv/read-the-map` draws on the travel map — race-led headline, owner and
population, nobles, legends, lair dwellers, camp crews — so you can see what you are starting
next to before you commit.
