-- Windrunner: your route on the world map (M), on Blizzard's map and on OpenMap's stitched map.
--
-- Shows the current session's route while one runs (it grows as you walk), otherwise the session
-- picked with "Show on world map" in the Sessions window. /wr route turns it on or off; with OpenMap
-- there's also a "Windrunner route" switch in its menu.

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

local MAX_LINES = 900
local overlay, pool, lastDraw = nil, nil, 0
local picked                                   -- a saved session chosen in the Sessions window

local function enabled() return WindrunnerDB and WindrunnerDB.mapRoute ~= false end

local function routeRecord()
  local DB = WindrunnerDB
  if not DB then return nil end
  if DB.session and DB.session.paths then return DB.session, true end
  return picked, false
end

local function openMap() return OpenMapAPI and OpenMapAPI.IsStitched and OpenMapAPI.IsStitched() end

-- a point recorded on zone map `zone` (0..1) -> 0..1 on the canvas showing map `shown`
local rectCache = {}
local function projector(zone, shown)
  if openMap() then
    return function(x, y)
      local u, v = OpenMapAPI.WorldFromMap(zone, x, y)
      if not u then return nil end
      return OpenMapAPI.MapFromWorld(shown, u, v)
    end
  end
  if zone == shown then return function(x, y) return x, y end end
  if not (C_Map and C_Map.GetMapRectOnMap) then return nil end
  local key = zone .. ">" .. shown
  local r = rectCache[key]
  if r == nil then
    local minX, maxX, minY, maxY = call(C_Map.GetMapRectOnMap, zone, shown)
    r = (type(minX) == "number" and maxX and maxX > minX) and { minX, maxX, minY, maxY } or false
    rectCache[key] = r
  end
  if not r then return nil end
  return function(x, y) return r[1] + x * (r[2] - r[1]), r[3] + y * (r[4] - r[3]) end
end

local function draw()
  if not overlay then return end
  NS.hideRoute(pool)
  local map = WorldMapFrame
  if not enabled() or not map or not map:IsShown() then return end
  local rec = routeRecord()
  if not rec or not rec.mapOrder then return end
  local shown = call(map.GetMapID, map)
  local canvas = map.GetCanvas and map:GetCanvas() or (map.ScrollContainer and map.ScrollContainer.Child)
  if not shown or not canvas then return end
  local cw, ch = canvas:GetWidth(), canvas:GetHeight()
  if not cw or cw <= 0 then return end
  -- above OpenMap's art (its own level), and lines stay ~3 px thick on screen at any zoom
  local base = canvas:GetFrameLevel() + 1
  if openMap() and OpenMapAPI.ArtTopLevel then base = math.max(base, (OpenMapAPI.ArtTopLevel() or 0) + 1) end
  if overlay:GetFrameLevel() ~= base then overlay:SetFrameLevel(base) end
  local scale = canvas.GetEffectiveScale and canvas:GetEffectiveScale() or 1
  local thick = 3 * UIParent:GetEffectiveScale() / math.max(scale, 0.01)

  local all = {}
  for _, zone in ipairs(rec.mapOrder) do
    local proj = projector(zone, shown)
    if proj then
      local px = NS.routePixels(NS.segments(rec, zone), function(x, y)
        local cx, cy = proj(x, y)
        if not cx then return nil end
        return cx * cw, cy * ch
      end, MAX_LINES / #rec.mapOrder)
      for _, seg in ipairs(px) do all[#all + 1] = seg end
    end
  end
  NS.drawRoute(pool, canvas, all, thick)
  lastDraw = GetTime()
end
NS.drawWorldRoute = draw

local function setup()
  if overlay or not WorldMapFrame then return end
  local map = WorldMapFrame
  local canvas = map.GetCanvas and map:GetCanvas() or (map.ScrollContainer and map.ScrollContainer.Child)
  if not canvas then return end
  overlay = CreateFrame("Frame", nil, canvas)
  overlay:SetAllPoints(canvas)
  overlay:EnableMouse(false)
  pool = NS.routePool(overlay)
  map:HookScript("OnShow", draw)
  if map.OnMapChanged then hooksecurefunc(map, "OnMapChanged", draw) end
  if map.OnCanvasScaleChanged then hooksecurefunc(map, "OnCanvasScaleChanged", draw) end
  overlay:SetScript("OnUpdate", function()      -- the live route grows while the map is open
    local _, live = routeRecord()
    if live and GetTime() - lastDraw > 2 then draw() end
  end)
  -- OpenMap: redraw when its stitched view moves, and a switch in its menu
  if OpenMapAPI then
    if OpenMapAPI.RegisterCallback then
      local owner = {}
      OpenMapAPI.RegisterCallback(owner, "OpenMap_ViewChanged", function() draw() end)
      OpenMapAPI.RegisterCallback(owner, "OpenMap_StitchedChanged", function() wipe(rectCache); draw() end)
    end
    if OpenMapAPI.RegisterMenuToggle then
      pcall(OpenMapAPI.RegisterMenuToggle, "Windrunner", {
        id = "route", label = "Windrunner route",
        get = function() return enabled() end,
        set = function(v) WindrunnerDB.mapRoute = v and true or false; draw() end,
      })
    end
  end
end

-- the Sessions window's "Show on world map"
function NS.showOnWorldMap(rec, mapID)
  picked = rec
  if WindrunnerDB then WindrunnerDB.mapRoute = true end
  setup()
  if not WorldMapFrame then return end
  if OpenWorldMap and mapID then pcall(OpenWorldMap, mapID)
  else
    if not WorldMapFrame:IsShown() then if ShowUIPanel then ShowUIPanel(WorldMapFrame) else WorldMapFrame:Show() end end
    if mapID and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID) end
  end
  draw()
end

function NS.toggleWorldRoute()
  WindrunnerDB.mapRoute = not enabled()
  setup()
  draw()
  return enabled()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event, name)
  if event == "PLAYER_LOGIN" or name == "Blizzard_WorldMap" or name == "OpenMap" then
    if overlay and name == "OpenMap" then return end
    setup()
  end
end)
