-- Windrunner: the Sessions window.
--
-- Every session keeps:
--   places  distance walked in each zone, dungeon, raid, battleground... ("1.2 km inside The Deadmines")
--   paths   the character's route on each zone map (WoW hides your position inside instances,
--           so there only the distance is kept)
-- Open it with the Sessions button in the Windrunner window, or /wr sessions.

local _, NS = ...
if type(NS) ~= "table" then NS = _G.WindrunnerNS or {}; _G.WindrunnerNS = NS end

local function isSecret(v) return issecretvalue and issecretvalue(v) or false end
local function call(fn, ...)
  if not fn then return nil end
  local r = { pcall(fn, ...) }
  if not r[1] then return nil end
  for i = 2, #r do if isSecret(r[i]) then return nil end end
  return unpack(r, 2)
end

---------------------------------------------------------------------------------
-- Recording (called by Windrunner.lua while a session counts)
---------------------------------------------------------------------------------
local KIND = { party = "dungeon", raid = "raid", pvp = "battleground", arena = "arena", scenario = "scenario" }
local here = { at = -10 }

local function where()
  local now = GetTime()
  if now - here.at < 1 then return here end
  here.at = now
  local inInst, itype = call(IsInInstance)
  local mapID = C_Map and call(C_Map.GetBestMapForUnit, "player")
  if type(mapID) ~= "number" then mapID = nil end
  local info = mapID and C_Map.GetMapInfo and call(C_Map.GetMapInfo, mapID)
  local mapName = type(info) == "table" and type(info.name) == "string" and info.name or nil
  if inInst and itype and itype ~= "none" then
    local iname = call(GetInstanceInfo)
    here.name = type(iname) == "string" and iname ~= "" and iname or mapName or "Instance"
    here.kind = KIND[itype] or "instance"
    here.map = nil                                   -- no position inside instances
  else
    here.name = mapName or (GetZoneText and call(GetZoneText)) or "Unknown"
    if type(here.name) ~= "string" or here.name == "" then here.name = "Unknown" end
    here.kind = "zone"
    here.map, here.mapName = mapID, mapName
  end
  return here
end

local PATH_STEP = 0.012          -- km of character movement between path points (about 13 yards)
local MAX_POINTS = 6000          -- per session; after that the spacing doubles

function NS.track(s, st, dReal, kmChar, dt)
  local w = where()
  -- distance per place
  s.places = s.places or {}
  local key = w.kind .. ":" .. w.name
  local p = s.places[key]
  if not p then p = { name = w.name, kind = w.kind, real = 0, char = 0, time = 0 }; s.places[key] = p end
  p.real, p.char, p.time = p.real + dReal, p.char + kmChar, p.time + dt
  -- path on the zone map
  if not st.moving or not w.map then return end
  s.pathAcc = (s.pathAcc or PATH_STEP) + kmChar
  local step = (s.pathN or 0) > MAX_POINTS and PATH_STEP * 3 or PATH_STEP
  if s.pathAcc < step and s.pathMap == w.map then return end
  local pos = call(C_Map.GetPlayerMapPosition, w.map, "player")
  if not pos then return end
  local x, y = call(pos.GetXY, pos)
  if type(x) ~= "number" or type(y) ~= "number" or (x == 0 and y == 0) then return end
  s.pathAcc = 0
  local xi, yi = math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5)
  s.paths = s.paths or {}
  s.mapOrder = s.mapOrder or {}
  s.mapNames = s.mapNames or {}
  local segs = s.paths[w.map]
  if not segs then
    segs = {}; s.paths[w.map] = segs
    table.insert(s.mapOrder, w.map)
    s.mapNames[w.map] = w.mapName or w.name
  end
  local seg = segs[#segs]
  local now = GetTime()
  local newSeg = not seg or s.pathMap ~= w.map or now - (s.pathT or 0) > 30
  if seg and not newSeg then                       -- teleport / hearthstone / portal: start a new line
    local lx, ly = seg[#seg - 1], seg[#seg]
    if math.abs(xi - lx) + math.abs(yi - ly) > 600 then newSeg = true end
  end
  if newSeg then seg = {}; table.insert(segs, seg) end
  seg[#seg + 1], seg[#seg + 2] = xi, yi
  s.pathMap, s.pathT, s.pathN = w.map, now, (s.pathN or 0) + 1
end

-- paths as compact strings in saved sessions: 8 hex characters per point, segments split by " "
local function pack(paths)
  local out = {}
  for map, segs in pairs(paths or {}) do
    local parts = {}
    for _, seg in ipairs(segs) do
      if #seg >= 4 then
        local t = {}
        for i = 1, #seg, 2 do t[#t + 1] = string.format("%04x%04x", seg[i], seg[i + 1]) end
        parts[#parts + 1] = table.concat(t)
      end
    end
    if #parts > 0 then out[map] = table.concat(parts, " ") end
  end
  return out
end

local function segments(rec, map)
  local v = rec.paths and rec.paths[map]
  if type(v) == "table" then return v end
  if type(v) ~= "string" then return {} end
  local segs = {}
  for part in v:gmatch("%S+") do
    local seg = {}
    for i = 1, #part - 7, 8 do
      seg[#seg + 1] = tonumber(part:sub(i, i + 3), 16)
      seg[#seg + 1] = tonumber(part:sub(i + 4, i + 7), 16)
    end
    segs[#segs + 1] = seg
  end
  return segs
end
NS.segments = segments

local KEEP_PATHS = 60            -- older sessions keep their numbers and places, but drop the route

function NS.finish(s, rec)
  rec.places = s.places
  rec.paths = pack(s.paths)
  local order, names = {}, {}
  for _, m in ipairs(s.mapOrder or {}) do
    if rec.paths[m] then order[#order + 1] = m; names[m] = s.mapNames and s.mapNames[m] end
  end
  rec.mapOrder, rec.mapNames = order, names
  local name = call(UnitName, "player")
  local _, class = call(UnitClass, "player")
  rec.who, rec.class = type(name) == "string" and name or nil, type(class) == "string" and class or nil
end

function NS.prune(list)
  for i = KEEP_PATHS + 1, #list do list[i].paths, list[i].mapOrder = nil, nil end
end

---------------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------------
local win, rows, selected, page, mapIndex = nil, {}, 1, 1, 1
local ROWS_PER_PAGE, WW, WH = 10, 840, 500
local LIST_W, X0 = 240, 264
local MAP_W, MAP_H = 390, 260
local KIND_LABEL = { zone = "zone", dungeon = "dungeon", raid = "raid", battleground = "battleground",
                     arena = "arena", scenario = "scenario / delve", instance = "instance" }

local function classHex(class)
  local colors = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)
  local c = class and colors and colors[class]
  if not c then return "ffd9b24a" end
  return string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local function items()
  local DB = WindrunnerDB
  local list = { { all = true } }
  if DB.session then list[#list + 1] = { live = true } end
  for i, rec in ipairs(DB.sessions) do list[#list + 1] = { rec = rec, index = i } end
  return list
end

local function liveRecord()
  local s = WindrunnerDB.session
  if not s then return nil end
  local name = call(UnitName, "player")
  local _, class = call(UnitClass, "player")
  return { date = "now", time = s.time, real = s.real, char = s.char, foot = s.foot, walked = s.walked,
           ran = s.ran, mode = WindrunnerDB.mode, places = s.places, paths = s.paths, mapOrder = s.mapOrder,
           mapNames = s.mapNames, who = name, class = class, live = true }
end

local function sortedPlaces(places)
  local t = {}
  for _, p in pairs(places or {}) do t[#t + 1] = p end
  table.sort(t, function(a, b) if a.real ~= b.real then return a.real > b.real end return a.char > b.char end)
  return t
end

local function allTime()
  local DB = WindrunnerDB
  local tot = { n = 0, time = 0, real = 0, char = 0, foot = 0, walked = 0, ran = 0, places = {}, longest = 0 }
  for _, rec in ipairs(DB.sessions) do
    tot.n = tot.n + 1
    tot.time, tot.real, tot.char = tot.time + (rec.time or 0), tot.real + (rec.real or 0), tot.char + (rec.char or 0)
    tot.foot, tot.walked, tot.ran = tot.foot + (rec.foot or 0), tot.walked + (rec.walked or 0), tot.ran + (rec.ran or 0)
    tot.longest = math.max(tot.longest, rec.real or 0)
    for key, p in pairs(rec.places or {}) do
      local q = tot.places[key]
      if not q then q = { name = p.name, kind = p.kind, real = 0, char = 0, time = 0, visits = 0 }; tot.places[key] = q end
      q.real, q.char, q.time, q.visits = q.real + (p.real or 0), q.char + (p.char or 0), q.time + (p.time or 0), q.visits + 1
    end
  end
  return tot
end

local function topPlace(rec)
  local best
  for _, p in pairs(rec.places or {}) do if not best or p.real > best.real then best = p end end
  return best
end

local function build()
  local F = NS.FONT
  local fmtDist, fmtTime, flat, label, ACCENT = NS.fmtDist, NS.fmtTime, NS.flat, NS.label, NS.ACCENT
  win = CreateFrame("Frame", "WindrunnerSessionsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  win:SetSize(WW, WH)
  win:SetPoint("CENTER")
  win:SetFrameStrata("HIGH")
  win:SetMovable(true); win:EnableMouse(true); win:SetClampedToScreen(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", win.StopMovingOrSizing)
  if win.SetBackdrop then
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    win:SetBackdropColor(0.05, 0.05, 0.06, 0.95)
    win:SetBackdropBorderColor(0, 0, 0, 0.9)
  end
  if UISpecialFrames then table.insert(UISpecialFrames, "WindrunnerSessionsFrame") end   -- Esc closes it
  local bar = win:CreateTexture(nil, "ARTWORK")
  bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("TOPRIGHT", -1, -1); bar:SetHeight(2)
  bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)

  local title = label(win, 15)
  title:SetPoint("TOPLEFT", 14, -14)
  title:SetText("Sessions")
  local close = flat(win, "Close", 60, 20, function() win:Hide() end)
  close:SetPoint("TOPRIGHT", -10, -10)

  -- list
  for i = 1, ROWS_PER_PAGE do
    local r = flat(win, "", LIST_W, 36, function(self) selected = (page - 1) * ROWS_PER_PAGE + i; mapIndex = 1; NS.refreshSessions() end)
    r:SetPoint("TOPLEFT", 12, -44 - (i - 1) * 38)
    r:GetFontString():Hide()
    r.a = label(r, 11); r.a:SetPoint("TOPLEFT", 8, -5); r.a:SetWidth(LIST_W - 80)
    r.b = label(r, 11); r.b:SetPoint("TOPRIGHT", -8, -5); r.b:SetJustifyH("RIGHT")
    r.c = label(r, 10); r.c:SetPoint("TOPLEFT", 8, -20); r.c:SetWidth(LIST_W - 16); r.c:SetTextColor(0.6, 0.6, 0.57)
    r.mark = r:CreateTexture(nil, "ARTWORK")
    r.mark:SetPoint("TOPLEFT"); r.mark:SetPoint("BOTTOMLEFT"); r.mark:SetWidth(3)
    r.mark:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    function r:SetPicked(on)                        -- selected: a soft tint and an accent edge, text stays readable
      self.bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], on and 0.22 or 0)
      if not on then self.bg:SetColorTexture(1, 1, 1, 0.05) end
      self.mark:SetShown(on)
    end
    rows[i] = r
  end
  win.prev = flat(win, "<", 28, 20, function() page = page - 1; NS.refreshSessions() end)
  win.prev:SetPoint("TOPLEFT", 12, -44 - ROWS_PER_PAGE * 38 - 4)
  win.next = flat(win, ">", 28, 20, function() page = page + 1; NS.refreshSessions() end)
  win.next:SetPoint("TOPLEFT", 12 + LIST_W - 28, -44 - ROWS_PER_PAGE * 38 - 4)
  win.pageFs = label(win, 10)
  win.pageFs:SetPoint("TOP", win, "TOPLEFT", 12 + LIST_W / 2, -44 - ROWS_PER_PAGE * 38 - 8)
  win.pageFs:SetTextColor(0.6, 0.6, 0.57)

  -- detail
  win.head = label(win, 14)
  win.head:SetPoint("TOPLEFT", X0, -44)
  win.head:SetWidth(WW - X0 - 14)
  win.stats = label(win, 11)
  win.stats:SetPoint("TOPLEFT", X0, -64)
  win.stats:SetWidth(WW - X0 - 14)
  win.stats:SetWordWrap(true)
  win.stats:SetTextColor(0.85, 0.85, 0.82)

  -- map
  local box = CreateFrame("Frame", nil, win)
  box:SetSize(MAP_W, MAP_H)
  box:SetPoint("TOPLEFT", X0, -100)
  local bg = box:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.45)
  local clip = CreateFrame("Frame", nil, box)
  if clip.SetClipsChildren then clip:SetClipsChildren(true) end
  local canvas = CreateFrame("Frame", nil, clip)
  canvas:SetAllPoints(clip)
  local over = CreateFrame("Frame", nil, clip)      -- the route, above the map tiles
  over:SetAllPoints(clip)
  over:SetFrameLevel(canvas:GetFrameLevel() + 2)
  win.box, win.clip, win.canvas, win.over, win.tiles, win.lines = box, clip, canvas, over, {}, {}
  win.startDot = over:CreateTexture(nil, "OVERLAY", nil, 7)
  win.startDot:SetSize(7, 7); win.startDot:SetColorTexture(0.3, 0.95, 0.4, 1)
  win.endDot = over:CreateTexture(nil, "OVERLAY", nil, 7)
  win.endDot:SetSize(7, 7); win.endDot:SetColorTexture(1, 0.25, 0.2, 1)
  win.mapNote = label(box, 11)
  win.mapNote:SetPoint("CENTER")
  win.mapNote:SetWidth(MAP_W - 40)
  win.mapNote:SetWordWrap(true)
  win.mapNote:SetJustifyH("CENTER")
  win.mapNote:SetTextColor(0.65, 0.65, 0.62)
  win.mapPrev = flat(win, "<", 28, 20, function() mapIndex = mapIndex - 1; NS.refreshSessions() end)
  win.mapPrev:SetPoint("TOPLEFT", X0, -100 - MAP_H - 6)
  win.mapNext = flat(win, ">", 28, 20, function() mapIndex = mapIndex + 1; NS.refreshSessions() end)
  win.mapNext:SetPoint("TOPLEFT", X0 + MAP_W - 28, -100 - MAP_H - 6)
  win.mapName = label(win, 11)
  win.mapName:SetPoint("TOP", win, "TOPLEFT", X0 + MAP_W / 2, -100 - MAP_H - 10)
  win.worldBtn = flat(win, "Show on world map", 130, 20, function()
    if win.rec and NS.showOnWorldMap then NS.showOnWorldMap(win.rec, win.rec.mapOrder and win.rec.mapOrder[mapIndex]) end
  end)
  win.worldBtn:SetPoint("TOPLEFT", X0, -100 - MAP_H - 32)
  win.worldBtn:GetFontString():SetFont(F, 10, "")
  win.hint = label(win, 10)
  win.hint:SetPoint("TOPLEFT", X0, -100 - MAP_H - 58)
  win.hint:SetWidth(MAP_W)
  win.hint:SetWordWrap(true)
  win.hint:SetTextColor(0.55, 0.55, 0.52)
  win.hint:SetText("|cff4cf266●|r start  |cffff4033●|r end.  Inside dungeons, raids and battlegrounds WoW hides your "
    .. "position, so there Windrunner counts the distance only (see Places).")

  -- places
  win.placesHead = label(win, 12)
  win.placesHead:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
  win.places = {}
  for i = 1, 12 do
    local r = CreateFrame("Frame", nil, win)
    r:SetSize(164, 30)
    r.a = label(r, 11); r.a:SetPoint("TOPLEFT", 0, 0)
    r.b = label(r, 11); r.b:SetPoint("TOPRIGHT", 0, 0); r.b:SetJustifyH("RIGHT")
    r.c = label(r, 10); r.c:SetPoint("TOPLEFT", 0, -14); r.c:SetTextColor(0.6, 0.6, 0.57)
    r.d = label(r, 10); r.d:SetPoint("TOPRIGHT", 0, -14); r.d:SetJustifyH("RIGHT"); r.d:SetTextColor(0.6, 0.6, 0.57)
    win.places[i] = r
  end
  win.noPlaces = label(win, 10)
  win.noPlaces:SetWordWrap(true)
  win.noPlaces:SetTextColor(0.55, 0.55, 0.52)

  local acc = 0
  win:SetScript("OnUpdate", function(_, dt)          -- keeps the current session live
    acc = acc + dt
    if acc < 1 then return end
    acc = 0
    if win.liveShown then NS.refreshSessions() end
  end)
  win:Hide()
end

local function placeRows(list, x, width, allTimeView)
  local fmtDist = NS.fmtDist
  win.placesHead:ClearAllPoints()
  win.placesHead:SetPoint("TOPLEFT", win, "TOPLEFT", x, -100)
  win.placesHead:SetText(allTimeView and "Places, all sessions" or "Places")
  for i, r in ipairs(win.places) do
    local p = list[i]
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", win, "TOPLEFT", x, -122 - (i - 1) * 30)
    r:SetWidth(width)
    r.a:SetWidth(width - 60)
    r:SetShown(p ~= nil)
    if p then
      local inst = p.kind ~= "zone"
      r.a:SetText((inst and "|cffffd27f" or "|cffffffff") .. p.name .. "|r")
      r.b:SetText(fmtDist(p.real))
      local kind = KIND_LABEL[p.kind] or p.kind
      if allTimeView and p.visits then kind = kind .. string.format(" · %d session%s", p.visits, p.visits == 1 and "" or "s") end
      r.c:SetText(kind)
      r.d:SetText("char " .. fmtDist(p.char))
    end
  end
  win.noPlaces:ClearAllPoints()
  win.noPlaces:SetPoint("TOPLEFT", win, "TOPLEFT", x, -122)
  win.noPlaces:SetWidth(width)
  win.noPlaces:SetShown(#list == 0)
  win.noPlaces:SetText("No places recorded yet. Sessions from before Windrunner 3.3 have only their totals.")
end

local function line(i)
  local l = win.lines[i]
  if not l then
    if not win.over.CreateLine then return nil end
    l = win.over:CreateLine(nil, "OVERLAY")
    l:SetThickness(2)
    l:SetColorTexture(1, 0.78, 0.2, 0.95)
    win.lines[i] = l
  end
  return l
end

local function drawMap(rec)
  for _, t in ipairs(win.tiles) do t:Hide() end
  for _, l in ipairs(win.lines) do l:Hide() end
  win.startDot:Hide(); win.endDot:Hide()
  local order = rec and rec.mapOrder or {}
  local n = #order
  win.mapPrev:SetShown(n > 1); win.mapNext:SetShown(n > 1)
  if n == 0 then
    win.mapName:SetText("")
    win.mapNote:Show()
    win.mapNote:SetText(rec and rec.date ~= "now" and not rec.places
      and "No route for this session (recorded before Windrunner 3.3, or an older session whose route was trimmed)."
      or "No route yet. Routes are drawn for the open world; inside instances only the distance is kept.")
    return
  end
  mapIndex = ((mapIndex - 1) % n) + 1
  local map = order[mapIndex]
  local info = C_Map and C_Map.GetMapInfo and call(C_Map.GetMapInfo, map)
  local name = (type(info) == "table" and info.name) or (rec.mapNames and rec.mapNames[map]) or ("Map " .. map)
  win.mapName:SetText(n > 1 and string.format("%s  (%d/%d)", name, mapIndex, n) or name)
  win.mapNote:Hide()

  -- map art, scaled to fit the box
  local layers = C_Map and C_Map.GetMapArtLayers and call(C_Map.GetMapArtLayers, map)
  local L = type(layers) == "table" and layers[1]
  local lw, lh = L and L.layerWidth or 1002, L and L.layerHeight or 668
  local sc = math.min(MAP_W / lw, MAP_H / lh)
  local dw, dh = lw * sc, lh * sc
  win.clip:ClearAllPoints()
  win.clip:SetPoint("TOPLEFT", win.box, "TOPLEFT", (MAP_W - dw) / 2, -(MAP_H - dh) / 2)
  win.clip:SetSize(dw, dh)
  local texs = L and call(C_Map.GetMapArtLayerTextures, map, 1)
  if type(texs) == "table" and L.tileWidth and L.tileWidth > 0 then
    local cols = math.ceil(lw / L.tileWidth)
    for i, fid in ipairs(texs) do
      local t = win.tiles[i]
      if not t then t = win.canvas:CreateTexture(nil, "ARTWORK"); win.tiles[i] = t end
      t:SetTexture(fid)
      t:SetSize(L.tileWidth * sc, L.tileHeight * sc)
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", win.clip, "TOPLEFT", ((i - 1) % cols) * L.tileWidth * sc, -math.floor((i - 1) / cols) * L.tileHeight * sc)
      t:SetVertexColor(0.8, 0.8, 0.8)
      t:Show()
    end
  end

  -- the route
  local segs = segments(rec, map)
  local total = 0
  for _, seg in ipairs(segs) do total = total + #seg / 2 end
  local stride = math.max(1, math.floor(total / 900))          -- at most ~900 lines on screen
  local li, first, last = 0, nil, nil
  for _, seg in ipairs(segs) do
    local px, py
    local npts = #seg / 2
    for k = 1, npts do
      if k == 1 or k == npts or k % stride == 0 then
        local x, y = seg[2 * k - 1] / 10000 * dw, seg[2 * k] / 10000 * dh
        if px then
          li = li + 1
          local l = line(li)
          if l then
            l:SetStartPoint("TOPLEFT", win.clip, px, -py)
            l:SetEndPoint("TOPLEFT", win.clip, x, -y)
            l:Show()
          end
        end
        px, py = x, y
        first = first or { x, y }
        last = { x, y }
      end
    end
  end
  if first then
    win.startDot:ClearAllPoints(); win.startDot:SetPoint("CENTER", win.clip, "TOPLEFT", first[1], -first[2]); win.startDot:Show()
    win.endDot:ClearAllPoints(); win.endDot:SetPoint("CENTER", win.clip, "TOPLEFT", last[1], -last[2]); win.endDot:Show()
  end
end

function NS.refreshSessions()
  if not win or not win:IsShown() then return end
  local fmtDist, fmtTime = NS.fmtDist, NS.fmtTime
  local list = items()
  local pages = math.max(1, math.ceil(#list / ROWS_PER_PAGE))
  page = math.max(1, math.min(page, pages))
  selected = math.max(1, math.min(selected, #list))
  win.prev:SetEnabled(page > 1); win.next:SetEnabled(page < pages)
  win.pageFs:SetText(string.format("page %d of %d", page, pages))
  local tot = allTime()
  for i, r in ipairs(rows) do
    local idx = (page - 1) * ROWS_PER_PAGE + i
    local it = list[idx]
    r:SetShown(it ~= nil)
    if it then
      r:SetPicked(idx == selected)
      if it.all then
        r.a:SetText("|cffffffffAll sessions|r")
        r.b:SetText(fmtDist(tot.real))
        r.c:SetText(string.format("%d session%s · %s", tot.n, tot.n == 1 and "" or "s", fmtTime(tot.time)))
      else
        local rec = it.live and liveRecord() or it.rec
        local tp = topPlace(rec)
        r.a:SetText(it.live and "|cff4cf266Now|r  " .. fmtTime(rec.time) or (rec.date or "?"))
        r.b:SetText(fmtDist(rec.real or 0))
        local who = rec.who and string.format("|c%s%s|r ", classHex(rec.class), rec.who) or ""
        r.c:SetText(string.format("%s%s%s%s", it.live and "" or fmtTime(rec.time or 0) .. " · ", who,
          fmtDist(rec.char or 0), tp and (" · " .. tp.name) or ""))
      end
    end
  end

  local it = list[selected]
  win.liveShown = it and it.live or false
  if it.all then
    win.head:SetText("All sessions")
    win.stats:SetText(string.format("%d session%s · %s on the treadmill · you %s (%s walked, %s run) · characters %s "
      .. "(%s on foot) · longest session %s", tot.n, tot.n == 1 and "" or "s", fmtTime(tot.time), fmtDist(tot.real), fmtDist(tot.walked),
      fmtDist(tot.ran), fmtDist(tot.char), fmtDist(tot.foot), fmtDist(tot.longest)))
    win.box:Hide(); win.mapPrev:Hide(); win.mapNext:Hide(); win.mapName:Hide(); win.hint:Hide(); win.worldBtn:Hide()
    placeRows(sortedPlaces(tot.places), X0, WW - X0 - 14, true)
    return
  end
  local rec = it.live and liveRecord() or it.rec
  local who = rec.who and string.format("  ·  |c%s%s|r", classHex(rec.class), rec.who) or ""
  win.head:SetText((it.live and "Current session" or rec.date or "?") .. who)
  win.stats:SetText(string.format("%s · you %s (%s walked, %s run) · character %s (%s on foot) · %s mode",
    fmtTime(rec.time or 0), fmtDist(rec.real or 0), fmtDist(rec.walked or 0), fmtDist(rec.ran or 0),
    fmtDist(rec.char or 0), fmtDist(rec.foot or 0), rec.mode == "app" and "App" or "Manual"))
  win.box:Show(); win.mapName:Show(); win.hint:Show()
  win.rec = rec
  win.worldBtn:SetShown(rec.mapOrder ~= nil and #rec.mapOrder > 0)
  drawMap(rec)
  placeRows(sortedPlaces(rec.places), X0 + MAP_W + 18, WW - X0 - MAP_W - 32, false)
end

function NS.openSessions(toggle)
  if not win then build() end
  if toggle and win:IsShown() then win:Hide(); return end
  selected = WindrunnerDB.session and 2 or (#WindrunnerDB.sessions > 0 and 2 or 1)
  page, mapIndex = 1, 1
  win:Show()
  NS.refreshSessions()
end
