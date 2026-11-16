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

local MAX_LINES = 1500
local overlay, lines, dots, lastDraw = nil, {}, {}, 0
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

local function hideAll()
  for _, l in ipairs(lines) do l:Hide() end
  for _, d in ipairs(dots) do d:Hide() end
end

local function draw()
  if not overlay then return end
  hideAll()
  local map = WorldMapFrame
  if not enabled() or not map or not map:IsShown() then return end
  local rec = routeRecord()
  if not rec or not rec.mapOrder then return end
  local shown = call(map.GetMapID, map)
  local canvas = map.GetCanvas and map:GetCanvas() or (map.ScrollContainer and map.ScrollContainer.Child)
  if not shown or not canvas then return end
  local cw, ch = canvas:GetWidth(), canvas:GetHeight()
  if not cw or cw <= 0 then return end
  -- above OpenMap's art (its own level), and lines stay ~2.5 px thick at any zoom
  local base = canvas:GetFrameLevel() + 1
  if openMap() and OpenMapAPI.ArtTopLevel then base = math.max(base, (OpenMapAPI.ArtTopLevel() or 0) + 1) end
  if overlay:GetFrameLevel() ~= base then overlay:SetFrameLevel(base) end
  local scale = canvas.GetEffectiveScale and canvas:GetEffectiveScale() or 1
  local ui = UIParent:GetEffectiveScale()
  local thick = 2.5 * ui / math.max(scale, 0.01)

  local total = 0
  local work = {}
  for _, zone in ipairs(rec.mapOrder) do
    local proj = projector(zone, shown)
    if proj then
      local segs = NS.segments(rec, zone)
      for _, seg in ipairs(segs) do total = total + #seg / 2 end
      work[#work + 1] = { proj = proj, segs = segs }
    end
  end
  if total == 0 then return end
  local stride = math.max(1, math.floor(total / MAX_LINES))
  local n, first, last = 0, nil, nil
  for _, w in ipairs(work) do
    for _, seg in ipairs(w.segs) do
      local px, py
      local npts = #seg / 2
      for k = 1, npts do
        if k == 1 or k == npts or k % stride == 0 then
          local x, y = w.proj(seg[2 * k - 1] / 10000, seg[2 * k] / 10000)
          if x then
            x, y = x * cw, y * ch
            if px then
              n = n + 1
              local l = lines[n]
              if not l then
                l = overlay:CreateLine(nil, "OVERLAY")
                l:SetColorTexture(1, 0.78, 0.2, 0.95)
                lines[n] = l
              end
              l:SetThickness(thick)
              l:SetStartPoint("TOPLEFT", canvas, px, -py)
              l:SetEndPoint("TOPLEFT", canvas, x, -y)
              l:Show()
            end
            px, py = x, y
            first = first or { x, y }
            last = { x, y }
          else
            px = nil
          end
        end
      end
    end
  end
  if first then
    for i, p in ipairs({ { first, 0.3, 0.95, 0.4 }, { last, 1, 0.25, 0.2 } }) do
      local d = dots[i]
      if not d then d = overlay:CreateTexture(nil, "OVERLAY", nil, 7); dots[i] = d end
      d:SetColorTexture(p[2], p[3], p[4], 1)
      d:SetSize(thick * 3, thick * 3)
      d:ClearAllPoints()
      d:SetPoint("CENTER", canvas, "TOPLEFT", p[1][1], -p[1][2])
      d:Show()
    end
  end
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
