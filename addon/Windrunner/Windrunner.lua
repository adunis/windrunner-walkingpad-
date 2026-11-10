-- Windrunner: treadmill walking for World of Warcraft
--
-- Manual mode (any treadmill): press Start, set the belt speed you walk at.
-- App mode (WalkingPad Control): the treadmill follows your character. Pressing W
--   starts the belt; idle / walking / running / mounted each have a belt speed you
--   set in-game. The app reads three tiny squares in the top-left corner.
--   The session starts by itself when your character starts moving.
--
-- Hardcore (Manual mode): you can only move while a session runs.
--   Never in combat (WoW doesn't allow addons to change keys then).
-- Warning (Manual mode): "Your character is walking but you are not!"
-- Combat Crawl (App mode): forces minimum belt speed during combat.
--
-- /wr           show or hide the window
-- /wr history   last sessions in chat
-- /wr miles     switch km / miles
-- /wr warn      toggle the warning      /wr hardcore   toggle Hardcore
-- /wr combat    toggle Combat Crawl (App mode only)
-- /wr sync      show or hide the sync squares (App mode needs them)
-- /wr lore      toggle lore subtitles   /wr every 0.5  lore every 0.5 km   /wr testlore  preview
-- /wr debug     treadmill link status
--
-- Treadmill link: WalkingPad Control sends the real belt speed once a second as 7 taps of
-- F11 (0) / F12 (1): km/h x10 in 6 bits + a parity bit. Windrunner uses F11/F12 for that.
-- "Pad drives the game": the app switches walk/run with numpad / (bound to Toggle Run/Walk here).

local YARD_KM = 0.0009144
local MILE_KM = 1.609344
local BASE_SPEED = BASE_MOVEMENT_SPEED or 7
local SETTINGS_VERSION = 3

local DEFAULTS = {
  tracker = true, bridge = true, mode = "manual", units = "km",
  warn = true, hardcore = true,
  speed = 3.0,                                     -- Manual mode belt speed (km/h)
  idle = 1.0, walk = 3.0, run = 5.0, mount = 6.0,  -- App mode belt speeds (km/h)
  expanded = false, runFrom = 4.5,     -- figure runs / distance counts as "run" from this belt speed
  lore = true, loreEvery = 0.5,        -- lore subtitles every this many km (or miles)
  combatCrawl = true,                  -- force crawl mode in combat
  session = nil, sessions = {},
}
local DB

---------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------
local function isSecret(v)
  return issecretvalue and issecretvalue(v) or false
end

-- Call an API safely: nil if missing, erroring, or hidden by addon restrictions
local function safe(fn, ...)
  if not fn then return nil end
  local ok, v = pcall(fn, ...)
  if not ok or isSecret(v) then return nil end
  return v
end

local eventMoving = false

local function charState()
  local speed, runSpeed
  local ok, cur, run = pcall(GetUnitSpeed, "player")
  if ok and cur ~= nil and not isSecret(cur) then
    speed = cur
    if run ~= nil and not isSecret(run) then runSpeed = run end
  end
  local known = speed ~= nil
  local moving
  if known then moving = speed > 0.1 else moving = eventMoving end
  if not known then speed = moving and BASE_SPEED or 0 end
  -- walking (not running): moving well below the character's run speed
  local walking = known and moving and runSpeed ~= nil and runSpeed > 0 and speed < 0.6 * runSpeed
  return {
    speed = speed, known = known, moving = moving, walking = walking and true or false,
    mounted = safe(IsMounted) and true or false,
    swimming = safe(IsSwimming) and true or false,
    taxi = safe(UnitOnTaxi, "player") and true or false,
    vehicle = safe(UnitInVehicle, "player") and true or false,
  }
end

local function onFoot(st) return not (st.mounted or st.taxi or st.vehicle) end

local function fmtTime(sec)
  sec = math.floor(sec)
  return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60)
end

local function fmtDist(km)
  if DB.units == "mi" then return string.format("%.2f mi", km / MILE_KM) end
  return string.format("%.2f km", km)
end

local function fmtSpeed(kmh)
  if DB.units == "mi" then return string.format("%.1f mph", kmh / MILE_KM) end
  return string.format("%.1f km/h", kmh)
end

local function say(msg)
  print("|cffe8590cWindrunner|r " .. msg)
end

---------------------------------------------------------------------------------
-- Sync squares (read by WalkingPad Control)
--   1: #123456 marker
--   2: R=A5  G=character speed yd/s x10  B=flags
--   3: R=5A  G=wanted belt km/h x10      B=flags (bit0 App mode, bit1 belt should run, bit2 session active, bit3 in combat)
---------------------------------------------------------------------------------
local BLOCK = 6              -- physical pixels; leave room to sample away from edges
local FLAG_VALID, FLAG_MOVING, FLAG_MOUNTED, FLAG_KNOWN = 0x80, 0x01, 0x02, 0x04
local FLAG_SWIM, FLAG_TAXI, FLAG_VEHICLE, FLAG_WALKING = 0x08, 0x10, 0x20, 0x40
local REQ_APPMODE, REQ_RUN, REQ_SESSION_ACTIVE, REQ_IN_COMBAT = 0x01, 0x02, 0x04, 0x08
local COUNTDOWN = 5          -- seconds the treadmill needs to start (3-2-1 + speed-up)

local bridge = CreateFrame("Frame", "WindrunnerBridgeFrame", UIParent)
bridge:SetIgnoreParentScale(true)
bridge:SetScale(1)
bridge:SetFrameStrata("TOOLTIP")
bridge:SetFrameLevel(9000)
bridge:EnableMouse(false)
local sq = {}
for i = 1, 3 do sq[i] = bridge:CreateTexture(nil, "OVERLAY") end
sq[1]:SetColorTexture(0x12 / 255, 0x34 / 255, 0x56 / 255, 1)
sq[2]:SetColorTexture(0xA5 / 255, 0, FLAG_VALID / 255, 1)
sq[3]:SetColorTexture(0x5A / 255, 0, FLAG_VALID / 255, 1)

local function layoutBridge()
  local _, ph = GetPhysicalScreenSize()
  if not ph or ph <= 0 then ph = 1080 end
  local s = BLOCK * 768 / ph / bridge:GetEffectiveScale()
  bridge:ClearAllPoints()
  bridge:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
  bridge:SetSize(s * 3, s)
  for i = 1, 3 do
    sq[i]:ClearAllPoints(); sq[i]:SetPoint("TOPLEFT", bridge, "TOPLEFT", s * (i - 1), 0); sq[i]:SetSize(s, s)
  end
end

local function showSquares(on)
  for i = 1, 3 do sq[i]:SetShown(on) end
end

-- Belt speed for the character's state (App mode)
local function wantedBelt(st)
  -- Combat crawl mode: force minimum speed in combat if enabled
  if DB.combatCrawl and safe(UnitAffectingCombat, "player") then
    return DB.idle, "combat (crawling)"
  end

  if not st.moving then return DB.idle, "idle" end
  if not onFoot(st) then return DB.mount, st.taxi and "flight path" or "mounted" end
  if st.known and st.speed <= 4.6 then return DB.walk, "walking" end
  return DB.run, "running"
end

-- App mode: the belt should run exactly while a session is running (not paused)
local function beltWanted()
  return DB.mode == "app" and DB.session ~= nil and not DB.session.paused
end

-- Real belt speed from WalkingPad Control (F11 = 0, F12 = 1, 7 taps once a second)
local beltReport = { kmh = 0, at = -100, frames = 0, bad = 0 }
local linkBits, lastBit = {}, -100
local function onBit(b)
  local now = GetTime()
  if now - lastBit > 0.3 then linkBits = {} end          -- a new burst
  lastBit = now
  linkBits[#linkBits + 1] = b
  if #linkBits == 7 then
    local v, ones = 0, 0
    for i = 1, 6 do v = v * 2 + linkBits[i]; ones = ones + linkBits[i] end
    if ones % 2 == linkBits[7] then
      beltReport.kmh, beltReport.at, beltReport.frames = v / 10, now, beltReport.frames + 1
    else
      beltReport.bad = beltReport.bad + 1
    end
    linkBits = {}
  end
end
local linkOwner = CreateFrame("Frame", "WindrunnerLinkOwner", UIParent)
local bit0 = CreateFrame("Button", "WindrunnerLinkBit0", UIParent)
local bit1 = CreateFrame("Button", "WindrunnerLinkBit1", UIParent)
bit0:SetScript("OnClick", function() onBit(0) end)
bit1:SetScript("OnClick", function() onBit(1) end)
local linkBound = false
local function bindLink()
  if linkBound or InCombatLockdown() then return end
  for _, k in ipairs({ "F11", "F12", "NUMPADDIVIDE" }) do
    local was = GetBindingAction and GetBindingAction(k)
    if was and was ~= "" and was ~= "TOGGLERUN" then
      say(string.format("note: your %s binding (%s) is replaced by the treadmill link while Windrunner is on.", k, was))
    end
  end
  SetOverrideBindingClick(linkOwner, true, "F11", "WindrunnerLinkBit0")
  SetOverrideBindingClick(linkOwner, true, "F12", "WindrunnerLinkBit1")
  -- numpad / = walk/run toggle (WoW's default), so the app can switch your gait whatever you rebound
  SetOverrideBinding(linkOwner, true, "NUMPADDIVIDE", "TOGGLERUN")
  linkBound = true
end
local function beltFresh() return GetTime() - beltReport.at < 3 end

local function updateSquares(st)
  local flags = FLAG_VALID
  if st.moving then flags = flags + FLAG_MOVING end
  if st.mounted then flags = flags + FLAG_MOUNTED end
  if st.known then flags = flags + FLAG_KNOWN end
  if st.swimming then flags = flags + FLAG_SWIM end
  if st.taxi then flags = flags + FLAG_TAXI end
  if st.vehicle then flags = flags + FLAG_VEHICLE end
  if st.walking then flags = flags + FLAG_WALKING end
  local g = st.known and math.min(250, math.floor(st.speed * 10 + 0.5)) or 0
  sq[2]:SetColorTexture(0xA5 / 255, g / 255, flags / 255, 1)

  local req = FLAG_VALID
  local sessionActive = DB.session ~= nil and not DB.session.paused
  local inCombat = safe(UnitAffectingCombat, "player") or false

  if DB.mode == "app" then
    req = req + REQ_APPMODE
    -- CRITICAL: Belt should ONLY run when session is active AND not paused
    if sessionActive then
      req = req + REQ_SESSION_ACTIVE
      if beltWanted() then req = req + REQ_RUN end
    end
    -- Add combat flag for app to know
    if inCombat then req = req + REQ_IN_COMBAT end
  end

  -- Send wanted belt speed (or 0 if session not active)
  local kmh = sessionActive and wantedBelt(st) or 0
  sq[3]:SetColorTexture(0x5A / 255, math.floor(kmh * 10 + 0.5) / 255, req / 255, 1)
end

---------------------------------------------------------------------------------
-- Lore subtitles: original lines in the spirit of Azeroth, shown every N km.
-- Class / race / faction lines live in Lore.lua; these are the general ones.
---------------------------------------------------------------------------------
local LORE = {
  walk = {
    { "The road does not care how fast you walk. Only that you do not stop.", "Farstrider saying" },
    { "Every great journey across Azeroth began with a single, unremarkable step.", "Explorers' League ledger" },
    { "Patience is a blade that never dulls.", "Old Kaldorei proverb" },
    { "The mountain does not hurry, yet it outlasts every empire built upon it.", "Ironforge stonecutters' saying" },
    { "Count the steps, not the leagues. The leagues will count themselves.", "Pandaren road wisdom" },
    { "The Light does not ask for haste. It asks for resolve.", "Teaching of the Silver Hand" },
    { "Roads remember the feet that wore them smooth.", "Tauren elder of Mulgore" },
    { "The tide returns to the shore a thousand times. So must you return to the path.", "Kul Tiran sailors' saying" },
    { "Strength is not the absence of weariness. It is the next step, taken in spite of it.", "Orcish grunt's creed" },
    { "The slowest caravan still crosses the Barrens, if it never turns back.", "Horde caravan master" },
    { "Earth beneath, sky above, and the long road between. That is enough.", "Shamanistic teaching" },
    { "A sentinel's watch is measured not in hours, but in steps unwavering.", "Oath of the Sentinels" },
    { "The forest grows one ring each year, and no one calls it slow.", "Cenarion Circle saying" },
    { "Walk with purpose, and the land itself will make way.", "Highmountain proverb" },
    { "A pilgrim's boots wear thin long before a pilgrim's faith.", "Chronicle of the Cathedral of Light" },
    { "The dead walk without rest. The living may at least choose their road.", "Forsaken deathguard" },
  },
  run = {
    { "Speed is a weapon. Wield it before the enemy knows you have drawn it.", "Ranger-General's maxim" },
    { "Run, and let the wind carry your name across the Eastern Kingdoms.", "Silvermoon courier's oath" },
    { "The wolf does not ask the plains for permission to run.", "Frostwolf proverb" },
    { "Fortune favours the swift. The grave favours the hesitant.", "Stormwind cavalry motto" },
    { "Faster. The darkness does not rest, and neither shall we.", "Argent Crusade field order" },
    { "Your heart is a war drum. Let it set the pace.", "Mag'har chant" },
    { "Outrun the storm, and you become the storm.", "Windrunner creed" },
    { "Breath of fire, legs of iron, will of stone.", "Dwarven runner's chant" },
    { "The hunt rewards those who arrive first.", "Huntress of Darnassus" },
    { "Let them try to follow.", "Ravenholdt saying" },
    { "Swift as the gryphon's shadow over the Wetlands.", "Wildhammer saying" },
    { "Every stride is a promise kept to those who fell behind.", "Saying of the Valarjar" },
    { "Run until the ground forgets you were ever standing still.", "Thunder Bluff trail runner" },
  },
  milestone = {
    { "Legends are not born. They are walked, one league at a time.", "Inscription in the Hall of Champions" },
    { "The banners still fly. The march goes on.", "Alliance war chronicle" },
    { "Even the ancients would take notice of such a journey.", "Keeper of the Grove" },
    { "Lok'tar! The road bows before you.", "Warsong war cry" },
    { "Your deeds will be sung in the halls of the Earthen Ring.", "Earthen Ring elder" },
  },
}

local sub = CreateFrame("Frame", "WindrunnerSubtitle", UIParent)
sub:SetSize(760, 90)
sub:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 170)
sub:SetFrameStrata("HIGH")
sub:EnableMouse(false)
sub:Hide()
local subShade = sub:CreateTexture(nil, "BACKGROUND")
subShade:SetPoint("CENTER", sub, "CENTER", 0, 4)
subShade:SetSize(620, 74)
subShade:SetColorTexture(0, 0, 0, 0.35)
if subShade.SetGradient and CreateColor then        -- soft edges where supported
  pcall(function() subShade:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.45)) end)
end
local SUBFONT = (GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()) or STANDARD_TEXT_FONT
  or "Fonts\\FRIZQT__.TTF"
local subQuote = sub:CreateFontString(nil, "OVERLAY")
subQuote:SetFont(SUBFONT, 17, "OUTLINE")
subQuote:SetPoint("TOP", sub, "TOP", 0, -6)
subQuote:SetWidth(720)
subQuote:SetJustifyH("CENTER")
subQuote:SetTextColor(0.96, 0.93, 0.85)
subQuote:SetShadowOffset(1, -1)
local subWho = sub:CreateFontString(nil, "OVERLAY")
subWho:SetFont(SUBFONT, 12, "OUTLINE")
subWho:SetPoint("TOP", subQuote, "BOTTOM", 0, -6)
subWho:SetTextColor(1, 0.82, 0.25)
local subStat = sub:CreateFontString(nil, "OVERLAY")
subStat:SetFont(SUBFONT, 11, "OUTLINE")
subStat:SetPoint("TOP", subWho, "BOTTOM", 0, -4)
subStat:SetTextColor(0.7, 0.7, 0.7)

local SUB_IN, SUB_HOLD, SUB_OUT = 0.8, 7.0, 1.6
local subT = 0
sub:SetScript("OnUpdate", function(self, dt)
  subT = subT + dt
  local a
  if subT < SUB_IN then a = subT / SUB_IN
  elseif subT < SUB_IN + SUB_HOLD then a = 1
  elseif subT < SUB_IN + SUB_HOLD + SUB_OUT then a = 1 - (subT - SUB_IN - SUB_HOLD) / SUB_OUT
  else self:Hide(); return end
  self:SetAlpha(a)
end)

-- Your character's own lines: their class + their race (walk / run); milestones by faction.
-- Falls back to the general lines above for anything not covered (e.g. a new race).
local function lorePool(kind)
  local WL = WindrunnerLore or {}
  local okc, _, cls = pcall(UnitClass, "player")
  local okr, _, race = pcall(UnitRace, "player")
  local okf, faction = pcall(UnitFactionGroup, "player")
  local pool, from = {}, {}
  local function add(list, label)
    if list and #list > 0 then
      for _, q in ipairs(list) do pool[#pool + 1] = q end
      from[#from + 1] = label
    end
  end
  if kind == "milestone" then
    add(okf and WL.faction and WL.faction[faction], faction)
    add(LORE.milestone, "milestones")
  else
    add(okc and cls and WL.class and WL.class[cls] and WL.class[cls][kind], cls)
    add(okr and race and WL.race and WL.race[race] and WL.race[race][kind], race)
    if #pool == 0 then add(LORE[kind], "general") end
  end
  return pool, table.concat(from, " + ")
end
Windrunner_LorePool = lorePool    -- for testing

local recentLore = {}
local function pickLore(kind)
  local pool = lorePool(kind)
  local choices = {}
  for _, q in ipairs(pool) do
    if not recentLore[q[1]] then choices[#choices + 1] = q end
  end
  if #choices == 0 then                      -- all used: new cycle, but never the line just shown
    for _, q in ipairs(pool) do
      recentLore[q[1]] = nil
      if q[1] ~= recentLore["__last" .. kind] then choices[#choices + 1] = q end
    end
  end
  local q = choices[math.random(#choices)]
  recentLore[q[1]] = true
  recentLore["__last" .. kind] = q[1]
  return q
end

local function showLore(kind, statLine)
  local q = pickLore(kind)
  subQuote:SetText("\"" .. q[1] .. "\"")
  subWho:SetText("— " .. q[2])
  subStat:SetText(statLine or "")
  subT = 0
  sub:SetAlpha(0)
  sub:Show()
  return q
end
Windrunner_ShowLore = showLore     -- for testing / previews

---------------------------------------------------------------------------------
-- Window: compact view (figure, time, "X km You / Y km Name"); right-click or + expands
---------------------------------------------------------------------------------
local ACCENT = { 1.0, 0.55, 0.15 }
local FONT = (GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()) or STANDARD_TEXT_FONT
  or "Fonts\\FRIZQT__.TTF"
local W, COMPACT_H = 250, 54

local ui = CreateFrame("Frame", "WindrunnerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
ui:SetSize(W, COMPACT_H)
ui:SetPoint("TOP", UIParent, "TOP", 0, -120)
ui:SetMovable(true)
ui:EnableMouse(true)
ui:RegisterForDrag("LeftButton")
ui:SetScript("OnDragStart", ui.StartMoving)
ui:SetScript("OnDragStop", ui.StopMovingOrSizing)
ui:SetClampedToScreen(true)
ui:SetFrameStrata("MEDIUM")
if ui.SetBackdrop then
  ui:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  ui:SetBackdropColor(0.05, 0.05, 0.06, 0.86)
  ui:SetBackdropBorderColor(0, 0, 0, 0.9)
end
local accentBar = ui:CreateTexture(nil, "ARTWORK")
accentBar:SetPoint("TOPLEFT", ui, "TOPLEFT", 1, -1)
accentBar:SetPoint("BOTTOMLEFT", ui, "TOPLEFT", 3, -COMPACT_H + 1)
accentBar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)

local function label(parent, size, flags)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(FONT, size, flags or "")
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function flat(parent, text, w, h, onClick)
  local b = CreateFrame("Button", nil, parent)
  b.wrButton = true
  b:SetSize(w, h or 18)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetColorTexture(1, 1, 1, 0.07)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.10)
  local fs = b:CreateFontString(nil, "OVERLAY")
  fs:SetFont(FONT, 11, "")
  fs:SetPoint("CENTER", 0, 0)
  fs:SetTextColor(0.92, 0.92, 0.9)
  b:SetFontString(fs)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  b:SetScript("OnDisable", function(self) self:GetFontString():SetAlpha(0.3) end)
  b:SetScript("OnEnable", function(self) self:GetFontString():SetAlpha(1) end)
  function b:SetOn(on)        -- highlighted (accent) state
    if on then self.bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.85)
    else self.bg:SetColorTexture(1, 1, 1, 0.07) end
  end
  return b
end

-- the little runner on a treadmill belt (compact view only)
local fig = CreateFrame("Frame", nil, ui)
fig:SetSize(44, COMPACT_H - 4)
fig:SetPoint("LEFT", ui, "LEFT", 6, 0)
fig:SetFrameLevel(ui:GetFrameLevel() + 1)  -- Above ui, but won't overlap expanded content
local OX, OY = 20, 7            -- hip x, belt height inside the figure box

local function makeLine(alpha, layerLevel)
  if not fig.CreateLine then return nil end
  local l = fig:CreateLine(nil, "ARTWORK", nil, layerLevel)
  l:SetThickness(2.2)
  l.alpha = alpha
  return l
end
local parts = {}
for _, n in ipairs({ "thigh2", "shin2", "upper2", "fore2" }) do parts[n] = makeLine(0.45, 1) end
for _, n in ipairs({ "torso", "thigh1", "shin1", "upper1", "fore1" }) do parts[n] = makeLine(1, 3) end
local head = fig:CreateTexture(nil, "ARTWORK", nil, 3)
head:SetSize(7.5, 7.5)
if fig.CreateMaskTexture and head.AddMaskTexture then
  local m = fig:CreateMaskTexture()
  m:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  m:SetAllPoints(head)
  head:AddMaskTexture(m)
end
local belt = fig:CreateTexture(nil, "BACKGROUND")
belt:SetColorTexture(0.45, 0.45, 0.45, 0.8)
belt:SetPoint("BOTTOMLEFT", fig, "BOTTOMLEFT", 2, OY - 2)
belt:SetSize(38, 1.5)
local dashes = {}
for i = 1, 4 do
  local d = fig:CreateTexture(nil, "BACKGROUND")
  d:SetColorTexture(0.6, 0.6, 0.6, 0.7)
  d:SetSize(4, 1)
  dashes[i] = d
end

-- Pose: side view facing right. Angles from straight down, positive = forward.
local THIGH, SHIN, TORSO, UPPER, FORE, HEAD_R = 8.5, 8.5, 11, 6, 5.5, 3.75
local function seg(x, y, a, len) return x + len * math.sin(a), y - len * math.cos(a) end
local function pose(kind, p)
  local lean = kind == "run" and 0.30 or kind == "walk" and 0.07 or 0.0
  local P = {}
  for side = 1, 2 do
    local q = p + (side == 1 and 0 or math.pi)
    local thigh, knee, upper, elbow
    if kind == "run" then
      thigh = 0.75 * math.sin(q) + 0.15
      knee = 0.25 + 1.35 * math.max(0, math.sin(q - 1.0))
      upper = -0.85 * math.sin(q) + 0.15
      elbow = 1.55
    elseif kind == "walk" then
      thigh = 0.42 * math.sin(q)
      knee = 0.08 + 0.6 * math.max(0, math.sin(q - 1.3))
      upper = -0.45 * math.sin(q)
      elbow = 0.35
    else
      thigh = side == 1 and 0.05 or -0.05
      knee = 0.03
      upper = side == 1 and 0.06 or -0.06
      elbow = 0.12
    end
    local kx, ky = seg(0, 0, thigh, THIGH)
    local fx, fy = seg(kx, ky, thigh - knee, SHIN)
    P["knee" .. side], P["foot" .. side] = { kx, ky }, { fx, fy }
    P["upperA" .. side], P["elbowA" .. side] = upper, elbow
  end
  local sx, sy = TORSO * 0.88 * math.sin(lean), TORSO * 0.88 * math.cos(lean)
  P.neck = { TORSO * math.sin(lean), TORSO * math.cos(lean) }
  P.head = { (TORSO + HEAD_R + 0.6) * math.sin(lean), (TORSO + HEAD_R + 0.6) * math.cos(lean) }
  for side = 1, 2 do
    local ex, ey = seg(sx, sy, P["upperA" .. side], UPPER)
    local hx, hy = seg(ex, ey, P["upperA" .. side] + P["elbowA" .. side], FORE)
    P["shoulder" .. side], P["elbow" .. side], P["hand" .. side] = { sx, sy }, { ex, ey }, { hx, hy }
  end
  P.hip = { 0, 0 }
  -- stand on the belt: the lowest foot touches it (this also makes the natural bob)
  local lift = -math.min(P.foot1[2], P.foot2[2])
  if kind == "run" then lift = lift + 1.2 * math.max(0, math.cos(2 * p)) end
  for _, v in pairs(P) do if type(v) == "table" then v[2] = v[2] + lift end end
  return P
end
Windrunner_Pose = pose          -- exposed for testing

local anim = { kind = "idle", kmh = 0, phase = 0, belt = 0 }
local function drawFigure()
  local P = pose(anim.kind, anim.phase)
  local c = anim.kind == "run" and ACCENT or anim.kind == "walk" and { 0.95, 0.93, 0.88 } or { 0.55, 0.55, 0.55 }
  local function L(name, a, b)
    local l = parts[name]
    if not l then return end
    l:SetStartPoint("BOTTOMLEFT", fig, OX + a[1], OY + a[2])
    l:SetEndPoint("BOTTOMLEFT", fig, OX + b[1], OY + b[2])
    l:SetColorTexture(c[1], c[2], c[3], l.alpha)
  end
  L("torso", P.hip, P.neck)
  for side = 1, 2 do
    L("thigh" .. side, P.hip, P["knee" .. side])
    L("shin" .. side, P["knee" .. side], P["foot" .. side])
    L("upper" .. side, P["shoulder" .. side], P["elbow" .. side])
    L("fore" .. side, P["elbow" .. side], P["hand" .. side])
  end
  head:ClearAllPoints()
  head:SetPoint("CENTER", fig, "BOTTOMLEFT", OX + P.head[1], OY + P.head[2])
  head:SetColorTexture(c[1], c[2], c[3], 1)
  for i, d in ipairs(dashes) do
    d:ClearAllPoints()
    d:SetPoint("BOTTOMLEFT", fig, "BOTTOMLEFT", 2 + ((i - 1) * 9.5 - anim.belt) % 38, OY - 4)
  end
end
fig:SetScript("OnUpdate", function(_, dt)
  if anim.kind ~= "idle" then
    local hz = anim.kind == "run" and (1.0 + 0.12 * anim.kmh) or (0.55 + 0.12 * anim.kmh)
    anim.phase = (anim.phase + dt * 2 * math.pi * hz) % (2 * math.pi)
    anim.belt = (anim.belt + dt * anim.kmh * 5) % 38
  end
  drawFigure()
end)

local timeFs = label(ui, 20, "")
timeFs:SetPoint("TOPLEFT", ui, "TOPLEFT", 54, -8)
local distFs = label(ui, 11, "")
distFs:SetPoint("TOPLEFT", ui, "TOPLEFT", 54, -33)
distFs:SetWidth(W - 60)
local lockFs = label(ui, 9, "")
lockFs:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -22, -7)
lockFs:SetJustifyH("RIGHT")

-- expanded part
local more = CreateFrame("Frame", nil, ui)
more:SetPoint("TOPLEFT", ui, "TOPLEFT", 0, -COMPACT_H)
more:SetPoint("TOPRIGHT", ui, "TOPRIGHT", 0, -COMPACT_H)
more:SetHeight(162)
local sep = more:CreateTexture(nil, "ARTWORK")
sep:SetColorTexture(1, 1, 1, 0.08)
sep:SetPoint("TOPLEFT", 8, 0); sep:SetPoint("TOPRIGHT", -8, 0); sep:SetHeight(1)

local refresh
local function setExpanded(on)
  DB.expanded = on and true or false
  refresh()
end
local expandBtn = CreateFrame("Button", nil, ui)
expandBtn:SetSize(14, 14)
expandBtn:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -5, -5)
expandBtn:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
expandBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
expandBtn:SetScript("OnClick", function() setExpanded(not DB.expanded) end)
ui:SetScript("OnMouseUp", function(_, btn) if btn == "RightButton" then setExpanded(not DB.expanded) end end)

local function walkingNow() return DB.session ~= nil and not DB.session.paused end

local function newSession(auto)
  DB.session = { active = true, paused = false, time = 0, real = 0, char = 0, foot = 0, started = time(),
                 walked = 0, ran = 0, nextLore = DB.loreEvery,
                 warmup = GetTime() + (DB.mode == "app" and COUNTDOWN or 0) }
  if auto then say("you started moving: session started, the treadmill is starting.") end
end

local function setPaused(paused, why)
  local s = DB.session
  if not s or s.paused == paused then return end
  s.paused = paused
  if not paused and DB.mode == "app" then s.warmup = GetTime() + COUNTDOWN end
  if why then say(why) end
end

local function endSession()
  local s = DB.session
  if not s then return end
  if s.time >= 30 then
    table.insert(DB.sessions, 1, {
      date = date("%Y-%m-%d %H:%M", s.started), time = s.time, real = s.real,
      char = s.char, foot = s.foot, mode = DB.mode, walked = s.walked or 0, ran = s.ran or 0,
    })
    while #DB.sessions > 200 do table.remove(DB.sessions) end
    say(string.format("session saved: %s, %s (%s walked, %s run). Your character travelled %s (%s on foot).",
      fmtTime(s.time), fmtDist(s.real), fmtDist(s.walked or 0), fmtDist(s.ran or 0), fmtDist(s.char), fmtDist(s.foot)))
  else
    say("session under 30 seconds, not saved.")
  end
  DB.session = nil
end

-- row 1: mode + belt
local manualBtn = flat(more, "Manual", 52, 18, function()
  if DB.mode ~= "manual" then DB.mode = "manual"; say("Manual mode: any treadmill, set your belt speed with - / +.") end
  refresh()
end)
manualBtn:SetPoint("TOPLEFT", more, "TOPLEFT", 8, -8)
local appBtn = flat(more, "App", 40, 18, function()
  if DB.mode ~= "app" then DB.mode = "app"; say("App mode: the treadmill follows your character (needs WalkingPad Control).") end
  refresh()
end)
appBtn:SetPoint("LEFT", manualBtn, "RIGHT", 2, 0)
local beltFs = label(more, 11, "")
beltFs:SetPoint("LEFT", appBtn, "RIGHT", 8, 0)
beltFs:SetWidth(W - 8 - 52 - 2 - 40 - 8 - 46)

local function step(v, d) return math.max(0.1, math.min(25, math.floor((v + d) * 10 + 0.5) / 10)) end
local plusBtn = flat(more, "+", 18, 18, function() DB.speed = step(DB.speed, 0.1); refresh() end)
plusBtn:SetPoint("TOPRIGHT", more, "TOPRIGHT", -8, -8)
local minusBtn = flat(more, "-", 18, 18, function() DB.speed = step(DB.speed, -0.1); refresh() end)
minusBtn:SetPoint("RIGHT", plusBtn, "LEFT", -2, 0)

-- row 2: Start / Pause / Stop
local BW = (W - 16 - 4) / 3
local startBtn = flat(more, "Start", BW, 20, function()
  newSession()
  say(DB.mode == "app" and "session started, the treadmill is starting."
    or "session started. Set the belt speed with - / + whenever you change it.")
  refresh()
end)
startBtn:SetPoint("TOPLEFT", more, "TOPLEFT", 8, -32)
local pauseBtn = flat(more, "Pause", BW, 20, function()
  local s = DB.session
  if not s then return end
  if s.paused then
    setPaused(false, DB.mode == "app" and "resumed, the treadmill is starting." or "resumed.")
  else
    setPaused(true, DB.mode == "app" and "paused, the treadmill stops. Start moving again (or Resume) to continue."
      or "paused.")
  end
  refresh()
end)
pauseBtn:SetPoint("LEFT", startBtn, "RIGHT", 2, 0)
local stopBtn = flat(more, "Stop", BW, 20, function()
  endSession()
  refresh()
end)
stopBtn:SetPoint("LEFT", pauseBtn, "RIGHT", 2, 0)

-- row 3 (Manual): options
local function checkbox(text, y, key, onChange)
  local cb = CreateFrame("CheckButton", nil, more, "UICheckButtonTemplate")
  cb:SetSize(20, 20)
  cb:SetPoint("TOPLEFT", more, "TOPLEFT", 5, y)
  local fs = label(more, 10, "")
  fs:SetPoint("LEFT", cb, "RIGHT", 1, 1)
  fs:SetText(text)
  fs:SetTextColor(0.85, 0.85, 0.82)
  cb.text = fs
  cb:SetScript("OnClick", function(self)
    DB[key] = self:GetChecked() and true or false
    if onChange then onChange() end
    refresh()
  end)
  return cb
end

local hardcoreHelp = function()
  return "in Manual mode you can only move while a walking session runs (press Start)."
end

local warnBox = checkbox("Warn when my character moves without me", -86, "warn")
local combatBox = checkbox("Combat Crawl: go slow in combat", -105, "combatCrawl", function()
  say(DB.combatCrawl and "Combat Crawl ON: treadmill will go to minimum speed during combat."
    or "Combat Crawl off: normal speeds in combat.")
end)
local hardBox = checkbox("Hardcore: can't move unless I walk", -105, "hardcore", function()
  say(DB.hardcore and ("|cffff3333Hardcore on|r: " .. hardcoreHelp() .. " In combat you can always move.")
    or "Hardcore off.")
end)
local loreBox = checkbox("Lore messages", -124, "lore", function()
  say(DB.lore and string.format("lore messages on: one every %s %s. Change with /wr every <number>.",
    DB.loreEvery, DB.units == "mi" and "mi" or "km") or "lore messages off.")
end)

-- row 3 (App): belt speeds for idle / walking / running / mounted
local speedRows, speedWidgets = {}, {}
local ROWS = { { "idle", "Idle" }, { "walk", "Walk" }, { "run", "Run" }, { "mount", "Mount" } }
for i, r in ipairs(ROWS) do
  local key, name = r[1], r[2]
  local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
  local x, y = 8 + col * ((W - 16) / 2 + 2), -60 - row * 20
  local n = label(more, 10, ""); n:SetPoint("TOPLEFT", more, "TOPLEFT", x, y - 3); n:SetText(name)
  n:SetTextColor(0.7, 0.7, 0.68)
  local v = label(more, 10, ""); v:SetPoint("TOPLEFT", more, "TOPLEFT", x + 34, y - 3)
  local mb = flat(more, "-", 16, 16, function() DB[key] = math.max(0.5, math.min(6, step(DB[key], -0.5))); refresh() end)
  mb:SetPoint("TOPLEFT", more, "TOPLEFT", x + 72, y)
  local pb = flat(more, "+", 16, 16, function() DB[key] = math.max(0.5, math.min(6, step(DB[key], 0.5))); refresh() end)
  pb:SetPoint("LEFT", mb, "RIGHT", 2, 0)
  speedRows[key] = v
  for _, w in ipairs({ n, v, mb, pb }) do table.insert(speedWidgets, w) end
end

-- hover: totals and hints
ui:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:AddLine("Windrunner", ACCENT[1], ACCENT[2], ACCENT[3])
  local total, tt = 0, 0
  for _, x in ipairs(DB.sessions) do total = total + x.real; tt = tt + x.time end
  if #DB.sessions > 0 then
    GameTooltip:AddLine(string.format("All time: %s in %s (%d session%s)", fmtDist(total), fmtTime(tt),
      #DB.sessions, #DB.sessions == 1 and "" or "s"), 1, 1, 1)
  end
  local s = DB.session
  if s and s.real > 0.01 then
    GameTooltip:AddLine(string.format("Your character went %.1fx as far as you", s.char / s.real), 0.8, 0.8, 0.8)
  end
  if s and s.real > 0.001 then
    GameTooltip:AddLine(string.format("This session: %s walked, %s run", fmtDist(s.walked or 0), fmtDist(s.ran or 0)), 1, 1, 1)
  end
  local tw, tr = 0, 0
  for _, x in ipairs(DB.sessions) do tw = tw + (x.walked or 0); tr = tr + (x.ran or 0) end
  if tw + tr > 0 then
    GameTooltip:AddLine(string.format("All time: %s walked, %s run", fmtDist(tw), fmtDist(tr)), 0.8, 0.8, 0.8)
  end
  GameTooltip:AddLine("Right-click or + for controls. Drag to move. /wr for commands.", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end)
ui:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------------
-- Warning and Hardcore
---------------------------------------------------------------------------------
local lastWarn = -100
local function warn(msg, every)
  if GetTime() - lastWarn < (every or 8) then return end
  lastWarn = GetTime()
  if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
    RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
  elseif UIErrorsFrame then
    UIErrorsFrame:AddMessage(msg, 1, 0.2, 0.2)
  end
  if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end


local MOVE_ACTIONS = { "MOVEFORWARD", "MOVEBACKWARD", "STRAFELEFT", "STRAFERIGHT", "TOGGLEAUTORUN", "MOVEANDSTEER" }
local blockOwner = CreateFrame("Frame", "WindrunnerHardcoreOwner", UIParent)
local blockBtn = CreateFrame("Button", "WindrunnerHardcoreBlock", UIParent)
blockBtn:SetScript("OnClick", function()
  if not ui:IsShown() then ui:Show(); DB.tracker = true; refresh() end
  warn("|cffff3333Hardcore:|r press Start in the Windrunner window to move!", 2)
end)
local blocked, blockedKeys = false, ""

local function movementKeys()
  local keys = {}
  for _, action in ipairs(MOVE_ACTIONS) do
    for _, key in ipairs({ GetBindingKey(action) }) do table.insert(keys, key) end
  end
  return keys
end

local function updateBlock(force)
  if not DB or InCombatLockdown() then return end
  local want = DB.hardcore and DB.mode == "manual" and not walkingNow()
  local keys = movementKeys()
  local sig = table.concat(keys, ",")
  if want == blocked and (not want or sig == blockedKeys) and not force then return end
  ClearOverrideBindings(blockOwner)
  if want then
    for _, key in ipairs(keys) do
      SetOverrideBindingClick(blockOwner, true, key, "WindrunnerHardcoreBlock")
    end
  end
  blocked, blockedKeys = want, sig
end

---------------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------------
local lastState = { speed = 0, moving = false, known = false }

local function playerName()
  local n = safe(UnitName, "player") or "Character"
  local hex = "ffd9b24a"
  local okc, _, class = pcall(UnitClass, "player")
  local colors = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)
  if okc and class and colors and colors[class] then
    local c = colors[class]
    hex = string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
  end
  return n, hex
end

refresh = function()
  local s = DB.session
  local app = DB.mode == "app"

  -- compact view
  timeFs:SetText(fmtTime(s and s.time or 0))
  if s and s.paused then timeFs:SetTextColor(1, 0.6, 0.2) elseif s then timeFs:SetTextColor(1, 1, 1)
  else timeFs:SetTextColor(0.6, 0.6, 0.6) end
  local name, hex = playerName()
  distFs:SetText(string.format("|cffffffff%s|r |cff999999You|r  |cff666666/|r  |c%s%s|r |cff999999%s|r",
    fmtDist(s and s.real or 0), hex, fmtDist(s and s.char or 0), name))
  lockFs:SetText(blocked and "|cffff4040LOCKED|r" or (s and s.paused and "|cffff9933PAUSED|r") or "")

  -- expanded view
  local open = DB.expanded
  more:SetShown(open)
  fig:SetShown(not open)  -- Hide walking figure when expanded to prevent overlap
  ui:SetHeight(COMPACT_H + (open and 164 or 0))
  expandBtn:SetNormalTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
  manualBtn:SetOn(not app)
  appBtn:SetOn(app)
  minusBtn:SetShown(not app)
  plusBtn:SetShown(not app)
  for _, w in ipairs(speedWidgets) do w:SetShown(app) end
  for key, fs in pairs(speedRows) do fs:SetText(fmtSpeed(DB[key])) end
  for _, cb in ipairs({ warnBox, hardBox }) do cb:SetShown(not app); cb.text:SetShown(not app) end
  combatBox:SetShown(app); combatBox.text:SetShown(app)  -- Combat Crawl only in App mode
  loreBox:SetChecked(DB.lore)
  loreBox.text:SetText(string.format("Lore messages every %s %s", DB.loreEvery, DB.units == "mi" and "mi" or "km"))

  if s then
    startBtn:Disable(); pauseBtn:Enable(); stopBtn:Enable()
    pauseBtn:SetText(s.paused and "Resume" or "Pause")
  else
    startBtn:Enable(); pauseBtn:Disable(); stopBtn:Disable()
    pauseBtn:SetText("Pause")
  end

  if app then
    local inCombat = safe(UnitAffectingCombat, "player") or false
    if s and s.paused then
      beltFs:SetText("|cffff9933Belt paused - App must NOT move belt|r")
    elseif not s then
      beltFs:SetText("|cff999999No session - App must NOT move belt|r")
    elseif inCombat and DB.combatCrawl then
      beltFs:SetText("|cffff6666Combat: Crawl mode|r")
    elseif beltFresh() then                       -- real speed from the treadmill
      if beltReport.kmh > 0 then
        beltFs:SetText(string.format("|cff66ee66%s|r treadmill", fmtSpeed(beltReport.kmh)))
      elseif beltWanted() then
        beltFs:SetText("|cffffee44Starting…|r")
      else
        beltFs:SetText("|cff999999Belt stopped|r")
      end
    elseif beltWanted() then                      -- no link: estimate from the character
      local kmh = wantedBelt(lastState)
      if GetTime() < (s.warmup or 0) then beltFs:SetText("|cffffee44Starting…|r")
      else beltFs:SetText(string.format("~%s |cff999999est.|r", fmtSpeed(kmh))) end
    else
      beltFs:SetText("|cff999999Move to start|r")
    end
  else
    beltFs:SetText("Belt " .. fmtSpeed(DB.speed))
  end

  warnBox:SetChecked(DB.warn)
  hardBox:SetChecked(DB.hardcore)
  combatBox:SetChecked(DB.combatCrawl)
  updateBlock()
end

---------------------------------------------------------------------------------
-- Ticking
---------------------------------------------------------------------------------
local acc, uiAcc, wasMoving = 0, 0, false
bridge:SetScript("OnUpdate", function(_, dt)
  acc = acc + dt
  if acc < 0.05 then return end
  local stepT = acc
  acc = 0
  if not DB then return end

  local st = charState()
  lastState = st
  updateSquares(st)
  local app = DB.mode == "app"

  -- App mode: STARTING to move starts the session (or resumes it) and so the treadmill.
  -- Only the start of a movement counts, so Pause sticks while you keep moving.
  local startedMoving = st.moving and not wasMoving
  wasMoving = st.moving
  if app and startedMoving and DB.bridge then
    if not DB.session then
      newSession(true)
    elseif DB.session.paused then
      setPaused(false, "you started moving: resumed, the treadmill is starting.")
    end
  end

  -- Warning (Manual mode): character walks on foot, you don't
  if not app and DB.warn and st.moving and onFoot(st) and not walkingNow() then
    warn("|cffff3333Your character is walking but you are not!|r")
  end

  local s = DB.session
  local kmh, counting = DB.speed, true
  if app and beltFresh() then                 -- real belt speed: count only while it moves
    kmh, counting = beltReport.kmh, beltReport.kmh > 0
  elseif app then                             -- estimate, after the countdown allowance
    kmh, counting = wantedBelt(st), GetTime() >= ((s and s.warmup) or 0)
  end
  if s and not s.paused and counting and kmh > 0 then
    anim.kind, anim.kmh = kmh >= (DB.runFrom or 4.5) and "run" or "walk", kmh
  else
    anim.kind, anim.kmh = "idle", 0
  end
  if s and not s.paused and counting then
    s.time = s.time + stepT
    local d = kmh * stepT / 3600
    s.real = s.real + d
    if kmh >= (DB.runFrom or 4.5) then s.ran = (s.ran or 0) + d else s.walked = (s.walked or 0) + d end
    -- lore subtitle every N km (or miles)
    local every = DB.loreEvery or 0.5
    local dist = DB.units == "mi" and s.real / MILE_KM or s.real
    s.nextLore = s.nextLore or every
    if dist >= s.nextLore then
      local mark = math.floor(dist / every + 1e-6) * every
      s.nextLore = mark + every
      if DB.lore and every > 0 then
        local major = math.floor(mark + 1e-6) % 5 == 0 and math.abs(mark - math.floor(mark + 0.5)) < 1e-6
        local kind = major and "milestone" or (kmh >= (DB.runFrom or 4.5) and "run" or "walk")
        showLore(kind, string.format("%s  ·  %s walked  ·  %s run", fmtDist(s.real), fmtDist(s.walked or 0), fmtDist(s.ran or 0)))
      end
    end
    local km = st.speed * stepT * YARD_KM
    s.char = s.char + km
    if onFoot(st) then s.foot = s.foot + km end
  end

  uiAcc = uiAcc + stepT
  if uiAcc >= 0.25 then
    uiAcc = 0
    if ui:IsShown() then refresh() else updateBlock() end
  end
end)

---------------------------------------------------------------------------------
-- Events & slash commands
---------------------------------------------------------------------------------
bridge:RegisterEvent("ADDON_LOADED")
bridge:RegisterEvent("PLAYER_STARTED_MOVING")
bridge:RegisterEvent("PLAYER_STOPPED_MOVING")
bridge:RegisterEvent("PLAYER_ENTERING_WORLD")
bridge:RegisterEvent("DISPLAY_SIZE_CHANGED")
bridge:RegisterEvent("UI_SCALE_CHANGED")
bridge:RegisterEvent("PLAYER_REGEN_DISABLED")
bridge:RegisterEvent("PLAYER_REGEN_ENABLED")
bridge:RegisterEvent("UPDATE_BINDINGS")
bridge:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_STARTED_MOVING" then
    eventMoving = true
  elseif event == "PLAYER_STOPPED_MOVING" then
    eventMoving = false
  elseif event == "PLAYER_REGEN_DISABLED" then
    ClearOverrideBindings(blockOwner)      -- always free movement in combat
    blocked = false
  elseif event == "PLAYER_REGEN_ENABLED" then
    bindLink()
    updateBlock(true)
  elseif event == "UPDATE_BINDINGS" then
    updateBlock()
  elseif event == "ADDON_LOADED" then
    if arg1 ~= "Windrunner" then return end
    WindrunnerDB = WindrunnerDB or {}
    DB = WindrunnerDB
    if (DB.version or 0) < SETTINGS_VERSION then          -- new default speeds
      DB.idle, DB.walk, DB.run, DB.mount = DEFAULTS.idle, DEFAULTS.walk, DEFAULTS.run, DEFAULTS.mount
      DB.version = SETTINGS_VERSION
    end
    for k, v in pairs(DEFAULTS) do
      if DB[k] == nil then DB[k] = type(v) == "table" and {} or v end
    end
    showSquares(DB.bridge)
    ui:SetShown(DB.tracker)
    refresh()
  elseif event == "PLAYER_ENTERING_WORLD" then
    layoutBridge()
    bindLink()
    if arg1 and DB and DB.mode == "app" and DB.session and not DB.session.paused then
      setPaused(true, "welcome back: your session is paused. Start moving to continue it.")
    end
    if arg1 and DB and DB.hardcore and DB.mode == "manual" then
      say("|cffff3333Hardcore is on|r: " .. hardcoreHelp() .. " Turn it off with the checkbox or /wr hardcore.")
    end
  else
    layoutBridge()
  end
end)
layoutBridge()

SLASH_WINDRUNNER1 = "/wr"
SLASH_WINDRUNNER2 = "/windrunner"
SlashCmdList.WINDRUNNER = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "history" then
    if #DB.sessions == 0 then say("no sessions yet.") return end
    say("last sessions:")
    for i = 1, math.min(10, #DB.sessions) do
      local x = DB.sessions[i]
      print(string.format("  %s  %s  you %s (%s walked, %s run) / character %s", x.date, fmtTime(x.time),
        fmtDist(x.real), fmtDist(x.walked or 0), fmtDist(x.ran or 0), fmtDist(x.char)))
    end
  elseif msg == "debug" then
    say("treadmill link:")
    local pw, ph = GetPhysicalScreenSize()
    print(string.format("  display: %dx%d, bridge scale: %.3f, squares: %d physical pixels each",
      pw, ph, bridge:GetEffectiveScale(), BLOCK))
    print("  mode: " .. DB.mode .. ", sync squares: " .. (DB.bridge and "shown" or "HIDDEN")
      .. ", F11/F12 link keys: " .. (linkBound and "set" or "not set yet"))
    if beltReport.at > 0 then
      print(string.format("  last belt speed from the app: %.1f km/h, %.0f s ago (%d received, %d garbled)",
        beltReport.kmh, GetTime() - beltReport.at, beltReport.frames, beltReport.bad))
    else
      print("  no belt speed received yet: is WalkingPad Control running, connected, and WoW in front?")
    end
  elseif msg == "sync" then
    DB.bridge = not DB.bridge
    showSquares(DB.bridge)
    say(DB.bridge and "sync squares shown." or "sync squares hidden (App mode won't work).")
  elseif msg == "hardcore" then
    DB.hardcore = not DB.hardcore
    say(DB.hardcore and ("|cffff3333Hardcore on|r: " .. hardcoreHelp()) or "Hardcore off.")
    refresh()
  elseif msg == "combat" or msg == "combatcrawl" then
    DB.combatCrawl = not DB.combatCrawl
    say(DB.combatCrawl and "Combat Crawl ON: treadmill will go to minimum speed during combat."
      or "Combat Crawl off: normal speeds in combat.")
    refresh()
  elseif msg == "lore" then
    DB.lore = not DB.lore
    say(DB.lore and "lore messages on." or "lore messages off.")
    refresh()
  elseif msg:match("^every") then
    local n = tonumber(msg:match("^every%s+([%d%.]+)"))
    if n and n >= 0.1 and n <= 50 then
      DB.loreEvery = n
      if DB.session then
        local dist = DB.units == "mi" and DB.session.real / MILE_KM or DB.session.real
        DB.session.nextLore = (math.floor(dist / n) + 1) * n
      end
      say(string.format("lore messages every %s %s.", n, DB.units == "mi" and "mi" or "km"))
      refresh()
    else
      say("usage: /wr every <distance>, e.g. /wr every 0.5")
    end
  elseif msg == "lore test" or msg == "testlore" then
    local wpool, wfrom = lorePool("walk")
    local rpool = lorePool("run")
    say(string.format("your lines: %s (%d walking, %d running).", wfrom, #wpool, #rpool))
    showLore("walk", "preview")
  elseif msg == "warn" then
    DB.warn = not DB.warn
    say(DB.warn and "movement warning on." or "movement warning off.")
    refresh()
  elseif msg == "miles" or msg == "km" or msg == "units" then
    DB.units = DB.units == "km" and "mi" or "km"
    say("units: " .. (DB.units == "km" and "kilometres" or "miles"))
    refresh()
  else
    DB.tracker = not ui:IsShown()
    ui:SetShown(DB.tracker)
    if DB.tracker then refresh() end
  end
end
