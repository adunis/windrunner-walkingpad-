-- Windrunner lore lines: original writing in the spirit of Azeroth (not quotes from the games).
-- Your character hears the lines of their class and of their race; milestones follow their faction.
-- Keys are WoW's class / race file names (UnitClass / UnitRace second return).

WindrunnerLore = WindrunnerLore or {}
local L = WindrunnerLore

L.class = {
  WARRIOR = {
    walk = {
      { "A soldier's march is won one hard step at a time.", "Warrior's creed" },
      { "The shield grows heavy. Carry it anyway.", "Arathi veteran" },
      { "Discipline outlasts rage. March on.", "Old soldier's saying" },
    },
    run = {
      { "Charge, and let doubt fall behind you.", "Battle-master's command" },
      { "The enemy line breaks for the one who reaches it first.", "Warrior's creed" },
      { "Blood in the legs, fury in the heart. Run.", "Arms master's teaching" },
    },
  },
  PALADIN = {
    walk = {
      { "The Light walks with those who walk in its service.", "Teaching of the Silver Hand" },
      { "Every step is a vow renewed.", "Oath of the Order" },
      { "Bear your burden as you bear your hammer: without complaint.", "Lordaeron chaplain" },
    },
    run = {
      { "Where the innocent cry out, the righteous do not walk.", "Silver Hand maxim" },
      { "Swift as judgment, bright as dawn.", "Crusader's prayer" },
      { "Let the Light carry you faster than fear.", "Paladin's blessing" },
    },
  },
  HUNTER = {
    walk = {
      { "Move as the stalker moves: patient, silent, certain.", "Hunter's lore" },
      { "The trail is long and the beast is patient. Be more patient.", "Tracker's proverb" },
      { "Your companion does not count the miles. Neither should you.", "Beastmaster's saying" },
    },
    run = {
      { "The prey is fast. Be faster.", "Hunter's lore" },
      { "Run with the pack, and the pack will run with you.", "Beastmaster's saying" },
      { "An arrow is only as swift as the one who carries the bow.", "Ranger's maxim" },
    },
  },
  ROGUE = {
    walk = {
      { "Walk softly. The shadows are listening.", "Ravenholdt saying" },
      { "Patience is a dagger held behind the back.", "SI:7 instruction" },
      { "No one remembers the stranger who simply kept walking.", "Cutthroat's wisdom" },
    },
    run = {
      { "Gone before the guards turn around.", "Ravenholdt saying" },
      { "Speed is the finest disguise.", "SI:7 instruction" },
      { "Run now. Explain later.", "Old thieves' rule" },
    },
  },
  PRIEST = {
    walk = {
      { "Faith is a road. You cannot see its end, yet you walk it.", "Teaching of the Light" },
      { "Each step offered in devotion is a prayer without words.", "Cathedral of Light homily" },
      { "Even the shadow follows those who walk toward the Light.", "Shadow priest's riddle" },
    },
    run = {
      { "Run, and let the Light mend the weariness behind you.", "Battle cleric's prayer" },
      { "The wounded will not wait. Neither will you.", "Field healer's oath" },
      { "The mind is swift when the spirit is willing.", "Teaching of Discipline" },
    },
  },
  DEATHKNIGHT = {
    walk = {
      { "The dead do not tire. Neither do you.", "Ebon Blade saying" },
      { "Every frozen step is a debt repaid to the living.", "Knight of Acherus" },
      { "The runeblade hungers. Keep moving.", "Ebon Blade saying" },
    },
    run = {
      { "Death waits for no one. You will not wait for death.", "Ebon Blade saying" },
      { "Run, and let the cold in your veins burn hot for once.", "Acherus instructor" },
      { "Suffer well, and run farther.", "Ebon Blade maxim" },
    },
  },
  SHAMAN = {
    walk = {
      { "Walk lightly. The earth feels every footstep.", "Earthen Ring teaching" },
      { "The elements do not hurry, yet nothing stands against them.", "Shamanistic teaching" },
      { "Listen. The wind tells you how far you have come.", "Farseer's wisdom" },
    },
    run = {
      { "Run as the storm runs: without asking leave.", "Farseer's wisdom" },
      { "Fire in the heart, wind at the heels.", "Shaman's chant" },
      { "The river does not stop for stones.", "Earthen Ring teaching" },
    },
  },
  MAGE = {
    walk = {
      { "Arcane mastery is the patient gathering of small things. So is distance.", "Kirin Tor lecture" },
      { "A wise mage walks. A foolish one spends mana on every errand.", "Dalaran apprentice's lesson" },
      { "Contemplation is best done in motion.", "Violet Citadel saying" },
    },
    run = {
      { "Even a blink is slower than conviction.", "Kirin Tor maxim" },
      { "Run now. The formulas can wait.", "Battle-mage's advice" },
      { "Speed is merely time, persuaded.", "Archmage's riddle" },
    },
  },
  WARLOCK = {
    walk = {
      { "Power is always paid for. Today you pay in steps.", "Warlock's maxim" },
      { "The fel whispers that you should rest. Ignore it.", "Black Harvest teaching" },
      { "Every bargain begins with a single step down a dark road.", "Forbidden tome" },
    },
    run = {
      { "Run, before the demon at your heels decides it is hungry.", "Black Harvest jest" },
      { "Chaos rewards the swift.", "Warlock's maxim" },
      { "Your soul shards rattle. Faster.", "Coven saying" },
    },
  },
  MONK = {
    walk = {
      { "The journey and the destination are the same road.", "Pandaren monk's teaching" },
      { "Breathe in with one step, out with the next.", "Shado-Pan discipline" },
      { "Balance is found in motion, not in stillness.", "Peak of Serenity lesson" },
    },
    run = {
      { "The tiger does not run to arrive. It runs because it is a tiger.", "Path of the Tiger" },
      { "Let the body be swift and the mind be still.", "Shado-Pan discipline" },
      { "Chi flows fastest through those who do not hold back.", "Master's lesson" },
    },
  },
  DRUID = {
    walk = {
      { "The forest is never in a hurry, and it is never late.", "Cenarion Circle saying" },
      { "Walk the path of the stag: noble, unhurried, unafraid.", "Stag's teaching" },
      { "Each step plants a seed. One day, a forest.", "Dreamweaver's saying" },
    },
    run = {
      { "Run as the cheetah runs, and let the world blur.", "Cenarion Circle saying" },
      { "The wild calls. Answer it at full stride.", "Druid of the Claw saying" },
      { "Antlers rise, hooves thunder. Go.", "Stag's teaching" },
    },
  },
  DEMONHUNTER = {
    walk = {
      { "We were never given the luxury of rest. Take a step instead.", "Illidari saying" },
      { "Every step is a step closer to the Legion's end.", "Illidari oath" },
      { "Blindness taught us to see the road within.", "Illidari teaching" },
    },
    run = {
      { "Glide if you must. Run if you can. Never stop.", "Illidari saying" },
      { "The hunt is endless. So is your stride.", "Illidari oath" },
      { "Speed is sacrifice made visible.", "Illidari teaching" },
    },
  },
  EVOKER = {
    walk = {
      { "The Dragon Isles were not raised in a day.", "Evoker's teaching" },
      { "Flight is a gift. Walking is a choice.", "Valdrakken elder" },
      { "Time is patient with those who honour it.", "Bronze dragonflight saying" },
    },
    run = {
      { "Wings folded, heart ablaze. Run.", "Obsidian warder's cry" },
      { "Even dragons must sometimes run.", "Valdrakken saying" },
      { "Essence surges in those who refuse to slow.", "Evoker's teaching" },
    },
  },
}

L.race = {
  Human = {
    walk = {
      { "The kingdom was built by those who kept walking when the road was hardest.", "Stormwind proverb" },
      { "From Northshire to Westfall, every road is a story.", "Elwynn farmer's saying" },
    },
    run = {
      { "Run for the Alliance, for the King, for those who cannot.", "Stormwind war cry" },
      { "Lordaeron fell to those who hesitated. Do not hesitate.", "Survivor of the Third War" },
    },
  },
  Orc = {
    walk = {
      { "Strength and honour carry us farther than any wolf.", "Orcish saying" },
      { "We crossed a dying world to reach this one. Keep walking.", "Elder of Orgrimmar" },
    },
    run = {
      { "Lok'tar! The plains will remember your footsteps.", "Orgrimmar grunt" },
      { "Run as the Horde runs: together, and without fear.", "Warchief's command" },
    },
  },
  Dwarf = {
    walk = {
      { "Stone is patient, and so are we.", "Ironforge saying" },
      { "There's no tunnel so long that a dwarf won't walk the end of it.", "Mountaineers' boast" },
    },
    run = {
      { "Run, and let the mountain thunder with ye!", "Ironforge war cry" },
      { "Fast as a ram down the slopes of Dun Morogh.", "Mountaineer's saying" },
    },
  },
  NightElf = {
    walk = {
      { "Ten thousand years of vigil were walked one night at a time.", "Sentinel saying" },
      { "Elune's light falls on every step.", "Priestess of the Moon" },
    },
    run = {
      { "Run as the Huntress runs, beneath the silver moon.", "Darnassian saying" },
      { "Swift as the nightsaber, silent as the stars.", "Sentinel saying" },
    },
  },
  Scourge = {
    walk = {
      { "We do not tire. We merely continue.", "Forsaken deathguard" },
      { "The grave could not hold us. The road will not either.", "Forsaken saying" },
    },
    run = {
      { "Run. Your heart may not beat, but your will does.", "Undercity apothecary" },
      { "The living run from fear. We run from nothing.", "Forsaken deathguard" },
    },
  },
  Tauren = {
    walk = {
      { "The Earth Mother feels every step you take upon her.", "Tauren elder" },
      { "Walk with the herd, and you will never walk alone.", "Mulgore saying" },
    },
    run = {
      { "Thunder across the plains, child of the Earth Mother.", "Bloodhoof saying" },
      { "The kodo does not stop for the storm.", "Tauren proverb" },
    },
  },
  Gnome = {
    walk = {
      { "Every great invention begins with a long walk to think it over.", "Tinker's saying" },
      { "Small steps, precisely measured, add up enormously.", "Gnomeregan engineer" },
    },
    run = {
      { "Faster! Recalibrate later!", "Gnomeregan engineer" },
      { "Short legs, long ambitions.", "Tinker's saying" },
    },
  },
  Troll = {
    walk = {
      { "Da Loa watch over da patient ones, mon.", "Darkspear saying" },
      { "Da road be long, but da spirit be longer.", "Echo Isles saying" },
    },
    run = {
      { "Run wit' da speed of da raptor, mon!", "Darkspear saying" },
      { "Bwonsamdi be waitin'. But not today.", "Echo Isles saying" },
    },
  },
  Goblin = {
    walk = {
      { "Every step's an investment. Let it compound.", "Bilgewater accountant" },
      { "The long way pays better, if you charge by the hour.", "Goblin trade wisdom" },
    },
    run = {
      { "Run fast, before somebody sends you the bill.", "Kezan saying" },
      { "Speed is profit.", "Bilgewater Cartel motto" },
    },
  },
  BloodElf = {
    walk = {
      { "Silvermoon was rebuilt one stone, one step, at a time.", "Silvermoon saying" },
      { "Grace is not given. It is practised, step by step.", "Magister's teaching" },
    },
    run = {
      { "Run, and let the Sunwell's light burn within you.", "Farstrider oath" },
      { "Swift as the rangers of Quel'Thalas, proud as its spires.", "Silvermoon saying" },
    },
  },
  Draenei = {
    walk = {
      { "We have walked from world to world. This road is not so long.", "Exodar elder" },
      { "The Naaru guide those who keep moving.", "Vindicator's teaching" },
    },
    run = {
      { "Once we ran from the Legion. Now we run toward victory.", "Exodar elder" },
      { "May the Light speed your hooves.", "Draenei blessing" },
    },
  },
  Worgen = {
    walk = {
      { "The beast within paces. Let it walk, and keep it calm.", "Gilnean saying" },
      { "Behind the Greymane Wall, we learned patience.", "Gilnean veteran" },
    },
    run = {
      { "Let the wolf run free. The worgen runs with it.", "Gilnean saying" },
      { "Gilneas endures, and Gilneas runs.", "Gilnean war cry" },
    },
  },
  Pandaren = {
    walk = {
      { "A long road is best walked with a full belly and a light heart.", "Pandaren road wisdom" },
      { "Wise feet know when to walk and when to nap.", "Wandering Isle saying" },
    },
    run = {
      { "Run as the river runs: gladly, and downhill.", "Wandering Isle saying" },
      { "The brew will wait. Probably.", "Pandaren brewmaster" },
    },
  },
  Nightborne = {
    walk = {
      { "Suramar endured ten thousand years beneath a shield. You can endure this mile.", "Shal'dorei saying" },
      { "Every step away from the well is a step toward freedom.", "Nightfallen rebel" },
    },
    run = {
      { "Run as the Nightfallen ran, toward the dawn.", "Suramar saying" },
      { "Swift as starlight over Suramar.", "Shal'dorei saying" },
    },
  },
  HighmountainTauren = {
    walk = {
      { "The mountain does not rush, yet it touches the sky.", "Highmountain proverb" },
      { "Walk the trails our ancestors walked.", "Highmountain elder" },
    },
    run = {
      { "Run like the river down the mountain!", "Riverbend saying" },
      { "The moose charges without hesitation. So must you.", "Highmountain hunter" },
    },
  },
  VoidElf = {
    walk = {
      { "The void whispers that you should stop. Walk anyway.", "Ren'dorei saying" },
      { "We stepped into the dark and came back. A road holds no fear.", "Ren'dorei saying" },
    },
    run = {
      { "Run, and leave the whispers behind.", "Ren'dorei ranger" },
      { "Shadow is fast. Be faster.", "Telogrus saying" },
    },
  },
  LightforgedDraenei = {
    walk = {
      { "The Light forged us in battle. It shapes us still, with every step.", "Lightforged vindicator" },
      { "Ten thousand years aboard the Vindicaar. This road is nothing.", "Lightforged saying" },
    },
    run = {
      { "Charge, as the Army of the Light charges!", "Lightforged battle cry" },
      { "The Light moves swiftly through the faithful.", "Lightforged vindicator" },
    },
  },
  ZandalariTroll = {
    walk = {
      { "Da empire was built by those who kept walkin'.", "Zandalari saying" },
      { "Walk wit' da dignity of Zuldazar.", "Dazar'alor saying" },
    },
    run = {
      { "Run, and let da Loa see your strength!", "Zandalari saying" },
      { "Swift as da pterrordax over Zuldazar.", "Zandalari saying" },
    },
  },
  KulTiran = {
    walk = {
      { "The sea taught us patience. The land teaches us endurance.", "Kul Tiran saying" },
      { "Tie the knots, mind the tide, and keep walking.", "Boralus sailor" },
    },
    run = {
      { "Run like the tide's coming in!", "Boralus saying" },
      { "For Kul Tiras, and for the Admiralty!", "Kul Tiran war cry" },
    },
  },
  DarkIronDwarf = {
    walk = {
      { "Forged in fire, we do not fear a long road.", "Shadowforge saying" },
      { "The forge is patient. So is the hammer.", "Dark Iron smith" },
    },
    run = {
      { "Run, and let the fire in your blood carry you!", "Shadowforge war cry" },
      { "Molten fury, iron legs.", "Dark Iron chant" },
    },
  },
  MagharOrc = {
    walk = {
      { "We are what the Horde was meant to be. Walk like it.", "Mag'har saying" },
      { "The roads of Draenor were long. These are longer. We endure.", "Mag'har elder" },
    },
    run = {
      { "Run as the clans ran, before the blood-curse.", "Mag'har saying" },
      { "Wolves and warriors, swift and unbroken.", "Mag'har chant" },
    },
  },
  Vulpera = {
    walk = {
      { "The caravan never stops, so neither do our paws.", "Vulpera saying" },
      { "Every dune crossed is a story for the campfire.", "Vulpera elder" },
    },
    run = {
      { "Run like the sandstorm's behind you. It usually is.", "Vol'dun saying" },
      { "Small paws, quick feet, no regrets.", "Vulpera saying" },
    },
  },
  Mechagnome = {
    walk = {
      { "Optimal efficiency: one step, then another.", "Mechagon directive" },
      { "Upgrade the body. Keep the will.", "Mechagnome saying" },
    },
    run = {
      { "Overclock the legs. Apologise to the gears later.", "Mechagon tinker" },
      { "Speed within acceptable parameters. Increase it.", "Mechagon directive" },
    },
  },
  Dracthyr = {
    walk = {
      { "We slept for ages. Now we walk.", "Dracthyr saying" },
      { "Every step on the Dragon Isles is a step reclaimed.", "Forbidden Reach saying" },
    },
    run = {
      { "Run, little dragon, and let the world feel your fire.", "Dracthyr saying" },
      { "Wings or feet, the dracthyr do not slow.", "Dracthyr saying" },
    },
  },
  EarthenDwarf = {
    walk = {
      { "We were shaped from stone to endure. Endure.", "Earthen saying" },
      { "The deep roads remember every footstep.", "Dornogal saying" },
    },
    run = {
      { "Run, and let the stone sing beneath you.", "Earthen saying" },
      { "Stone is slow. Stone that moves is unstoppable.", "Earthen saying" },
    },
  },
}

L.faction = {
  Alliance = {
    { "Banners high. Another league for the Alliance.", "Alliance herald" },
    { "Your march will be remembered in the halls of Stormwind.", "Alliance war chronicle" },
  },
  Horde = {
    { "Lok'tar! Another league conquered.", "Horde herald" },
    { "The drums of Orgrimmar beat for you tonight.", "Warsong war cry" },
  },
}
