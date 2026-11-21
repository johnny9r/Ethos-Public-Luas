-- Gas Flight Dash widget for FrSky Ethos
-- Copy this folder to the radio SD card as /scripts/gasflightdash/main.lua
--
-- Same as Electric Flight Dash, but the flight battery dial is replaced by
-- an image (there is no flight pack on a gas model).
--
-- Designed for a full-screen widget (one widget filling the whole screen).
--
-- Layout:
--   +----------------------+  |  ( 07:42 )   [  ENGINE  ]
--   |                      |  |  ( TIMER )   [ DISARMED ]
--   |        IMAGE         |  |-------------------------------
--   |                      |  |  RECEIVER       2S  4.00V/cell
--   +----------------------+  |        .-~~~~~~~-.
--   RATES [LOW][MED][HIGH]    |      /    8.0V     \
--
-- Image:          either the model's own image, or a picture chosen with the
--                 Ethos file picker from /bitmaps/models (the same folder
--                 the standard Bitmap widget uses). Scaled to fit the left
--                 panel, keeping its proportions.
-- Timer:          any Ethos timer, shown as MM:SS. Ring and digits turn red
--                 in the last minute and when the timer runs past zero.
-- Engine:         green ARMED / red DISARMED from a logical or physical switch.
-- Receiver:       half dial from a telemetry voltage, with configurable
--                 battery type and cell count.
-- Rates:          LOW / MED / HIGH from a 3-position switch. Each rate gets
--                 its own switch-position setting (e.g. SA-up / SA-mid /
--                 SA-down), so Ethos reports the active position directly.
--
-- Demo mode (for bench testing): pick a pot or slider as "Demo source".
--   * The receiver battery voltage always follows the pot.
--   * Timer, engine switch and rates switch use the real ones if they are
--     set; any that are not set are simulated from the pot as well.
--   * A pot or slider picked directly as "Receiver voltage" drives the
--     receiver dial the same way.
--   A red DEMO tag is shown whenever any of this is active.
--
-- Performance: Ethos limits how many Lua instructions one callback may run.
-- Dial geometry is therefore computed once per widget size and cached, each
-- dial is drawn in a single pass, and the image is loaded only when its
-- path changes.

------------------------------------------------------------------------
-- Settings you may want to tweak
------------------------------------------------------------------------
local TIMER_WARN = 60        -- seconds left when the timer turns red

-- Folder the picture picker browses (same as the standard Bitmap widget).
local IMAGE_DIR = "/bitmaps/models"

-- Image setting
local IMG_MODEL = 0          -- use the model's own image
local IMG_FILE  = 1          -- use the picture chosen from IMAGE_DIR

-- Per-cell voltages for each battery type: empty = left end of the dial,
-- full = right end, >= green is green, >= yellow is yellow, below is red.
local BATT_TYPES = {
  { name = "LiPo",   empty = 3.60, full = 4.20, yellow = 3.80, green = 4.05 },
  { name = "LiFe",   empty = 3.00, full = 3.45, yellow = 3.15, green = 3.25 },
  { name = "Li-Ion", empty = 3.30, full = 4.20, yellow = 3.60, green = 3.90 },
  { name = "NiMH",   empty = 1.10, full = 1.40, yellow = 1.20, green = 1.25 },
}

-- Demo timer: the pot sweeps from DEMO_TIMER_START down to DEMO_TIMER_END
-- seconds (negative shows the overtime display).
local DEMO_TIMER_START = 600
local DEMO_TIMER_END   = -30

-- Dial segment size in degrees. Larger = fewer instructions, coarser arcs.
local SEG_DEG = 6

------------------------------------------------------------------------
-- Colours
------------------------------------------------------------------------
local C_BG         = lcd.RGB(11, 13, 16)
local C_TILE       = lcd.RGB(27, 32, 38)
local C_TRACK      = lcd.RGB(38, 43, 49)
local C_TEXT       = lcd.RGB(255, 255, 255)
local C_SUBTEXT    = lcd.RGB(169, 176, 184)
local C_DIMTEXT    = lcd.RGB(138, 146, 156)
local C_GREY       = lcd.RGB(90, 90, 90)

local C_GREEN      = lcd.RGB(0, 200, 60)
local C_YELLOW     = lcd.RGB(240, 200, 0)
local C_RED        = lcd.RGB(220, 30, 30)
local C_RED_TEXT   = lcd.RGB(255, 74, 74)
local C_GREEN_DIM  = lcd.RGB(0, 70, 25)
local C_YELLOW_DIM = lcd.RGB(85, 70, 0)
local C_RED_DIM    = lcd.RGB(80, 16, 16)

local C_ARMED      = lcd.RGB(11, 125, 54)
local C_DISARMED   = lcd.RGB(200, 30, 30)

local RATE_NAMES  = { "LOW", "MED", "HIGH" }
local RATE_COLORS = {
  lcd.RGB(47, 111, 214),   -- LOW  blue
  lcd.RGB(139, 79, 216),   -- MED  purple
  lcd.RGB(224, 106, 18),   -- HIGH orange
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function clamp01(t)
  if t < 0 then return 0 elseif t > 1 then return 1 end
  return t
end

local function cellFrac(cell, bt)
  return clamp01((cell - bt.empty) / (bt.full - bt.empty))
end

local function zoneColor(cell, bt)
  if cell >= bt.green then return C_GREEN
  elseif cell >= bt.yellow then return C_YELLOW end
  return C_RED
end

-- Pots/sliders report -1024..1024; turn that into a 0..1 position.
local function potToFrac(p)
  return clamp01((p + 1024) / 2048)
end

-- True when a "voltage" source is really a stick, pot or slider rather than
-- a telemetry sensor. Uses the source category when Ethos provides it;
-- otherwise falls back to values no battery can have (negative or > 100 V).
local function isAnalogInput(src, v)
  if CATEGORY_ANALOG ~= nil then
    local ok, cat = pcall(function() return src:category() end)
    if ok and cat ~= nil then return cat == CATEGORY_ANALOG end
  end
  return v ~= nil and (v < 0 or v > 100)
end

-- True/false for a switch source, nil if none is set.
local function switchOn(src)
  if src == nil then return nil end
  local ok, s = pcall(function() return src:state() end)
  if ok and type(s) == "boolean" then return s end
  local v = src:value()
  return v ~= nil and v > 0
end

local function formatTimer(secs)
  local neg = secs < 0
  local a = math.abs(secs)
  local m = math.min(99, math.floor(a / 60))
  local s = a % 60
  return string.format("%s%02d:%02d", neg and "-" or "", m, s)
end

-- Choose the largest font that fits text into maxW x maxH; returns text size.
local FONTS = { FONT_XXL, FONT_XL, FONT_L, FONT_STD, FONT_S }
local function fitFont(text, maxW, maxH)
  for _, f in ipairs(FONTS) do
    lcd.font(f)
    local tw, th = lcd.getTextSize(text)
    if tw <= maxW and th <= maxH then return tw, th end
  end
  lcd.font(FONT_S)
  return lcd.getTextSize(text)
end

-- Draw text centred on x, with its top at y.
local function drawCentered(x, y, text, tw)
  lcd.drawText(math.floor(x - tw / 2), math.floor(y), text)
end

-- Point on a circle; deg 0 = up, clockwise positive.
local function polar(cx, cy, r, deg)
  local a = math.rad(deg)
  return math.floor(cx + r * math.sin(a) + 0.5), math.floor(cy - r * math.cos(a) + 0.5)
end

------------------------------------------------------------------------
-- Image
------------------------------------------------------------------------
-- Full path for a picked file. The picker may hand back just the file name
-- or a full path depending on Ethos version, so accept both.
local function filePath(f)
  if f == nil or f == "" then return nil end
  if string.find(f, "/", 1, true) or string.find(f, ":", 1, true) then return f end
  return IMAGE_DIR .. "/" .. f
end

-- The path to show: the picked picture, or the model's own image.
local function imagePath(widget)
  if widget.imageMode == IMG_FILE then
    return filePath(widget.imageFile)
  end
  local ok, mp = pcall(function() return model.bitmap() end)
  if ok and type(mp) == "string" and mp ~= "" then return mp end
  return nil
end

-- Ethos pickers often hand back the name without its extension, and the
-- radio and simulator differ on leading slashes, so try the likely spellings.
-- Real extensions first: Ethos can hand back an empty bitmap for a path
-- that doesn't exist, so the bare name is only a last resort.
local IMAGE_EXTS = { ".png", ".bmp", ".jpg", "" }

local function hasExt(p)
  return string.match(p, "%.[%a%d]+$") ~= nil
end

-- A loaded bitmap counts only if it has a real size (when Ethos can tell us).
local function tryLoad(p)
  local ok, bmp = pcall(function() return lcd.loadBitmap(p) end)
  if not (ok and bmp) then return nil end
  local okW, bw = pcall(function() return bmp:width() end)
  if okW and type(bw) == "number" and bw <= 0 then return nil end
  return bmp
end

local function loadImage(path)
  local bases = { path }
  if string.sub(path, 1, 1) == "/" then
    bases[#bases + 1] = string.sub(path, 2)
  elseif not string.find(path, ":", 1, true) then
    bases[#bases + 1] = "/" .. path
  end
  for _, base in ipairs(bases) do
    if hasExt(base) then
      local bmp = tryLoad(base)
      if bmp then return bmp, base end
    else
      for _, ext in ipairs(IMAGE_EXTS) do
        local bmp = tryLoad(base .. ext)
        if bmp then return bmp, base .. ext end
      end
    end
  end
  return nil
end

-- Load the image only when its path changes; nil if it can't be loaded.
local function getBitmap(widget)
  local path = imagePath(widget)
  if path ~= widget.bmpPath then
    widget.bmpPath = path
    widget.bmp = nil
    if path then widget.bmp = loadImage(path) end
  end
  return widget.bmp
end

------------------------------------------------------------------------
-- Cached dials
------------------------------------------------------------------------
-- Precompute the inner/outer vertex of every segment edge once.
local function makeDial(cx, cy, r1, r2, a0, a1)
  local n = math.max(1, math.floor((a1 - a0) / SEG_DEG + 0.5))
  local step = (a1 - a0) / n
  local xi, yi, xo, yo, mid = {}, {}, {}, {}, {}
  for i = 0, n do
    local a = a0 + i * step
    xi[i], yi[i] = polar(cx, cy, r1, a)
    xo[i], yo[i] = polar(cx, cy, r2, a)
    mid[i] = a + step / 2
  end
  return { cx = cx, cy = cy, r1 = r1, r2 = r2, a0 = a0, a1 = a1, n = n,
           xi = xi, yi = yi, xo = xo, yo = yo, mid = mid }
end

local function dialAngle(d, f)
  return d.a0 + f * (d.a1 - d.a0)
end

-- One pass over the segments: filled part in fillColor up to fillA, the rest
-- in the dim zone colour (aY/aG = yellow/green start angles), or in the
-- plain track colour when aY is nil.
local function drawDial(d, fillA, fillColor, aY, aG)
  local xi, yi, xo, yo, mid = d.xi, d.yi, d.xo, d.yo, d.mid
  local cur = nil
  for i = 0, d.n - 1 do
    local m = mid[i]
    local c
    if fillA and m <= fillA then c = fillColor
    elseif aY == nil then c = C_TRACK
    elseif m < aY then c = C_RED_DIM
    elseif m < aG then c = C_YELLOW_DIM
    else c = C_GREEN_DIM end
    if c ~= cur then lcd.color(c); cur = c end
    local j = i + 1
    lcd.drawFilledTriangle(xi[i], yi[i], xo[i], yo[i], xo[j], yo[j])
    lcd.drawFilledTriangle(xi[i], yi[i], xo[j], yo[j], xi[j], yi[j])
  end
end

-- Small white marker across the band at angle a.
local function drawMarker(d, a)
  local a0 = math.max(d.a0, a - 2)
  local a1 = math.min(d.a1, a + 2)
  local x1, y1 = polar(d.cx, d.cy, d.r1 - 3, a0)
  local x2, y2 = polar(d.cx, d.cy, d.r2 + 3, a0)
  local x3, y3 = polar(d.cx, d.cy, d.r2 + 3, a1)
  local x4, y4 = polar(d.cx, d.cy, d.r1 - 3, a1)
  lcd.color(C_TEXT)
  lcd.drawFilledTriangle(x1, y1, x2, y2, x3, y3)
  lcd.drawFilledTriangle(x1, y1, x3, y3, x4, y4)
end

-- Zoned battery dial with fill and marker. cell = per-cell volts or nil.
local function drawZoneDial(d, bt, cell, color)
  local aY = dialAngle(d, cellFrac(bt.yellow, bt))
  local aG = dialAngle(d, cellFrac(bt.green, bt))
  local fillA = cell and dialAngle(d, cellFrac(cell, bt)) or nil
  drawDial(d, fillA, color, aY, aG)
  if fillA then drawMarker(d, fillA) end
end

------------------------------------------------------------------------
-- Layout (computed once per widget size)
------------------------------------------------------------------------
local function buildLayout(w, h)
  local L = { w = w, h = h }
  local pad = math.max(4, math.floor(h * 0.03))
  L.pad = pad
  lcd.font(FONT_S)
  local _, lh = lcd.getTextSize("Ag")
  L.lh = lh

  -- Columns: left half for the image + rates, right half for the rest.
  local split = math.floor(w * 0.5)
  L.split = split
  L.lx = pad
  L.lw = split - pad - math.floor(pad / 2)
  L.rx = split + math.floor(pad / 2) + 1
  L.rw = w - L.rx - pad

  -- Left: image panel above the rates strip.
  L.ratesH = math.max(24, math.floor(h * 0.12))
  L.ratesY = h - pad - L.ratesH
  L.imgX, L.imgY = L.lx, pad
  L.imgW = L.lw
  L.imgH = L.ratesY - pad - pad

  -- Right top: timer ring + engine badge.
  L.rowH = math.floor((h - 2 * pad) * 0.44)
  local ringD = math.min(L.rowH, math.floor(L.rw * 0.55))
  local ringR = math.max(12, math.floor(ringD / 2))
  local rBand = math.max(5, math.floor(ringR * 0.13))
  L.ring = makeDial(L.rx + ringR, pad + math.floor(L.rowH / 2), ringR - rBand, ringR, 0, 360)
  L.engX = L.rx + ringD + pad
  L.engW = L.rx + L.rw - L.engX

  -- Right bottom: receiver half dial.
  L.rxDivY = pad + L.rowH + pad
  L.rxY = L.rxDivY + math.floor(pad / 2) + 1
  local rxH = h - L.rxY - pad
  local top = L.rxY + lh + 4
  local availH = rxH - lh - 4
  local rr = math.max(16, math.floor(math.min(L.rw / 2, availH)))
  local rrBand = math.max(6, math.floor(rr * 0.2))
  local rcx = math.floor(L.rx + L.rw / 2)
  local rcy = math.floor(top + (availH - rr) / 2 + rr)
  L.rxDial = makeDial(rcx, rcy, rr - rrBand, rr, -90, 90)

  return L
end

------------------------------------------------------------------------
-- Widget callbacks
------------------------------------------------------------------------
local function create()
  return {
    -- settings
    imageMode = IMG_MODEL,
    imageFile = "",       -- picture picked from IMAGE_DIR
    rxSource = nil,
    rxType = 1,           -- index into BATT_TYPES
    rxCells = 2,
    timerSource = nil,
    armSwitch = nil,
    rateSwitches = {},    -- [1]=LOW, [2]=MED, [3]=HIGH switch positions
    demoSource = nil,     -- pot/slider that fakes values for testing
    -- live values
    rxVolts = nil,
    timerSecs = nil, timerMax = 0, lastTimer = nil,
    armed = nil,
    rate = nil,
    demo = false,
    lastKey = nil,
    layout = nil,
    bmp = nil, bmpPath = nil,
  }
end

local function wakeup(widget)
  -- Demo pot position 0..1, or nil when demo mode is off.
  local demoT = nil
  if widget.demoSource then
    local p = widget.demoSource:value()
    if p then demoT = potToFrac(p) end
  end
  local rxBt = BATT_TYPES[widget.rxType] or BATT_TYPES[1]
  local rxCells = math.max(1, widget.rxCells)

  -- A pot/slider picked directly as the receiver voltage source drives the
  -- dial like demo mode (raw -1024..1024 would otherwise show as volts).
  local rxT, rxRaw = demoT, nil
  if rxT == nil and widget.rxSource then
    rxRaw = widget.rxSource:value()
    if isAnalogInput(widget.rxSource, rxRaw) then rxT = potToFrac(rxRaw) end
  end

  -- Receiver battery
  local rv
  if rxT then
    -- Sweep a little past each end of the receiver dial.
    local lo = rxBt.empty - 0.10 * (rxBt.full - rxBt.empty)
    local hi = rxBt.full + 0.05 * (rxBt.full - rxBt.empty)
    rv = rxCells * (lo + (hi - lo) * rxT)
  else
    rv = rxRaw
  end
  widget.rxVolts = (rv ~= nil and rv > 0.5) and rv or nil

  -- Timer (seconds). The ring's full scale is the start value, which is
  -- the highest value seen; a jump upwards means the timer was reset.
  if demoT and widget.timerSource == nil then
    widget.timerSecs = math.floor(DEMO_TIMER_END + (DEMO_TIMER_START - DEMO_TIMER_END) * demoT)
    widget.timerMax = DEMO_TIMER_START
    widget.lastTimer = nil
  else
    local tv = widget.timerSource and widget.timerSource:value() or nil
    if tv ~= nil then
      tv = math.floor(tv)
      if widget.lastTimer == nil or tv > widget.lastTimer then
        widget.timerMax = math.max(tv, 0)
      end
      widget.lastTimer = tv
    end
    widget.timerSecs = tv
  end

  -- Engine arm switch (simulated in demo if none set: armed above half way)
  if demoT and widget.armSwitch == nil then
    widget.armed = demoT > 0.5
  else
    widget.armed = switchOn(widget.armSwitch)
  end

  -- Rates: one switch position per rate (e.g. SA-down / SA-mid / SA-up).
  -- The first position that is active wins. Simulated in demo if none set.
  local rs = widget.rateSwitches
  local anyRate = rs[1] ~= nil or rs[2] ~= nil or rs[3] ~= nil
  local rate = nil
  if demoT and not anyRate then
    rate = math.min(3, math.floor(demoT * 3) + 1)
  else
    for i = 1, 3 do
      if switchOn(rs[i]) then rate = i; break end
    end
  end
  widget.rate = rate

  widget.demo = (demoT ~= nil) or (rxT ~= nil)

  local key = string.format("%s|%s|%s|%s|%s|%s|%s", tostring(widget.demo),
    widget.rxVolts and string.format("%.2f", widget.rxVolts) or "-",
    tostring(widget.timerSecs), tostring(widget.timerMax),
    tostring(widget.armed), tostring(widget.rate), tostring(imagePath(widget)))
  if key ~= widget.lastKey then
    widget.lastKey = key
    lcd.invalidate()
  end
end

------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------
local function paintImage(widget, L)
  local x, y, w, h = L.imgX, L.imgY, L.imgW, L.imgH
  local bmp = getBitmap(widget)

  local drawn = false
  if bmp then
    -- Scale to fit, keeping proportions, centred in the panel.
    local ok = pcall(function()
      local bw, bh = bmp:width(), bmp:height()
      if type(bw) ~= "number" or type(bh) ~= "number" or bw <= 0 or bh <= 0 then
        error("no size")
      end
      local s = math.min(w / bw, h / bh)
      local dw, dh = math.floor(bw * s), math.floor(bh * s)
      lcd.drawBitmap(math.floor(x + (w - dw) / 2), math.floor(y + (h - dh) / 2), bmp, dw, dh)
    end)
    if not ok then
      -- Size unknown on this firmware: stretch to the panel instead.
      ok = pcall(function() lcd.drawBitmap(x, y, bmp, w, h) end)
    end
    drawn = ok
  end

  if not drawn then
    lcd.color(C_TILE)
    lcd.drawFilledRectangle(x, y, w, h)
    lcd.font(FONT_S)
    lcd.color(C_DIMTEXT)
    local msg
    local path = imagePath(widget)
    if path then msg = "Image not found"
    elseif widget.imageMode == IMG_FILE then msg = "Pick a picture"
    else msg = "Model has no image" end
    local tw, th = lcd.getTextSize(msg)
    lcd.drawText(math.floor(x + (w - tw) / 2), math.floor(y + (h - th) / 2), msg)
    -- Show what was tried, and what the picker handed back, so a wrong
    -- path is easy to spot.
    local lines = {}
    if path then lines[#lines + 1] = path end
    if widget.imageMode == IMG_FILE then
      lines[#lines + 1] = "picker: '" .. tostring(widget.imageFile) .. "'"
    end
    local ly = math.floor(y + (h + th) / 2 + 4)
    for _, s in ipairs(lines) do
      local pw = lcd.getTextSize(s)
      lcd.drawText(math.floor(x + math.max(0, (w - pw) / 2)), ly, s)
      ly = ly + th + 2
    end
  end

  if widget.demo then
    -- Make demo mode obvious so it never gets left on for a real flight.
    lcd.font(FONT_S)
    lcd.color(C_RED_TEXT)
    lcd.drawText(x + w, y, "DEMO", RIGHT)
  end
end

local function paintRates(widget, L)
  local x, y, w, h = L.lx, L.ratesY, L.lw, L.ratesH
  lcd.font(FONT_S)
  lcd.color(C_SUBTEXT)
  local lw, lh = lcd.getTextSize("RATES")
  lcd.drawText(x, math.floor(y + (h - lh) / 2), "RATES")

  local gap = 6
  local bx = x + lw + 10
  local bw = math.floor((x + w - bx - 2 * gap) / 3)
  for i = 1, 3 do
    local px = bx + (i - 1) * (bw + gap)
    local on = widget.rate == i
    lcd.color(on and RATE_COLORS[i] or C_TILE)
    lcd.drawFilledRectangle(px, y, bw, h)
    if on then
      lcd.color(C_TEXT)
      lcd.drawRectangle(px, y, bw, h)
      lcd.drawRectangle(px + 1, y + 1, bw - 2, h - 2)
    end
    lcd.color(on and C_TEXT or C_DIMTEXT)
    local tw, th = fitFont(RATE_NAMES[i], bw - 10, h - 8)
    lcd.drawText(math.floor(px + (bw - tw) / 2), math.floor(y + (h - th) / 2), RATE_NAMES[i])
  end
end

local function paintTimer(widget, L)
  local d = L.ring
  local secs = widget.timerSecs

  local frac, color, textColor, text = 0, C_TEXT, C_TEXT, "--:--"
  if secs ~= nil then
    text = formatTimer(secs)
    if widget.timerMax > 0 then frac = clamp01(secs / widget.timerMax) end
    if secs < TIMER_WARN then
      color, textColor = C_RED, C_RED_TEXT
    end
  else
    textColor = C_GREY
  end

  drawDial(d, frac > 0 and 360 * frac or nil, color, nil, nil)

  lcd.color(textColor)
  local tw, th = fitFont(text, d.r1 * 1.6, d.r1 * 0.75)
  local ty = d.cy - th * 0.6
  drawCentered(d.cx, ty, text, tw)

  lcd.font(FONT_S)
  lcd.color(C_SUBTEXT)
  local label = (widget.timerSource or widget.demo) and "TIMER" or "Set timer"
  local lw = lcd.getTextSize(label)
  drawCentered(d.cx, ty + th, label, lw)
end

local function paintEngine(widget, L)
  local x, y, w, h = L.engX, L.pad, L.engW, L.rowH
  local bg, state = C_GREY, "SET SWITCH"
  if widget.armed == true then
    bg, state = C_ARMED, "ARMED"
  elseif widget.armed == false then
    bg, state = C_DISARMED, "DISARMED"
  end
  lcd.color(bg)
  lcd.drawFilledRectangle(x, y, w, h)

  lcd.color(C_TEXT)
  local sw, sh = fitFont(state, w - 12, h * 0.4)
  lcd.font(FONT_S)
  local lw, lh = lcd.getTextSize("ENGINE")
  local by = y + (h - (lh + 4 + sh)) / 2
  drawCentered(x + w / 2, by, "ENGINE", lw)
  fitFont(state, w - 12, h * 0.4)
  drawCentered(x + w / 2, by + lh + 4, state, sw)
end

local function paintReceiver(widget, L)
  local d = L.rxDial
  local bt = BATT_TYPES[widget.rxType] or BATT_TYPES[1]
  local cells = math.max(1, widget.rxCells)

  lcd.font(FONT_S)
  lcd.color(C_SUBTEXT)
  lcd.drawText(L.rx, L.rxY, "RECEIVER")

  local cell, color, text, sub = nil, C_GREY, "--.-V", nil
  if widget.rxVolts then
    cell = widget.rxVolts / cells
    color = zoneColor(cell, bt)
    text = string.format("%.1fV", widget.rxVolts)
    sub = string.format("%dS %s  %.2fV/cell", cells, bt.name, cell)
  else
    sub = (widget.rxSource or widget.demo) and "No telemetry" or "Set source"
  end
  lcd.drawText(L.rx + L.rw, L.rxY, sub, RIGHT)

  drawZoneDial(d, bt, cell, color)

  lcd.color(color == C_RED and C_RED_TEXT or color)
  local tw, th = fitFont(text, d.r1 * 1.3, d.r1 * 0.55)
  drawCentered(d.cx, d.cy - th, text, tw)
end

local function paint(widget)
  local w, h = lcd.getWindowSize()
  local L = widget.layout
  if L == nil or L.w ~= w or L.h ~= h then
    L = buildLayout(w, h)
    widget.layout = L
  end

  lcd.color(C_BG)
  lcd.drawFilledRectangle(0, 0, w, h)

  -- Dividers
  lcd.color(C_TRACK)
  lcd.drawFilledRectangle(L.split, L.pad, 1, h - 2 * L.pad)
  lcd.drawFilledRectangle(L.lx, L.ratesY - math.floor(L.pad / 2) - 1, L.lw, 1)
  lcd.drawFilledRectangle(L.rx, L.rxDivY, L.rw, 1)

  paintImage(widget, L)
  paintRates(widget, L)
  paintTimer(widget, L)
  paintEngine(widget, L)
  paintReceiver(widget, L)
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local RX_TYPE_CHOICES = {}
for i, bt in ipairs(BATT_TYPES) do RX_TYPE_CHOICES[i] = { bt.name, i } end

local RX_CELL_CHOICES = {
  { "1S", 1 }, { "2S", 2 }, { "3S", 3 }, { "4S", 4 }, { "5S", 5 },
}

local IMAGE_CHOICES = {
  { "Model image", IMG_MODEL },
  { "Picture from " .. IMAGE_DIR, IMG_FILE },
}

local function configure(widget)
  local pictureField = nil
  local function updatePictureField()
    if pictureField then
      pcall(function() pictureField:enable(widget.imageMode == IMG_FILE) end)
    end
  end

  local line = form.addLine("Image")
  form.addChoiceField(line, nil, IMAGE_CHOICES,
    function() return widget.imageMode end,
    function(v) widget.imageMode = v; updatePictureField(); lcd.invalidate() end)

  -- Ethos file picker listing the pictures in IMAGE_DIR, like the standard
  -- Bitmap widget. Falls back to a text box on firmware without the picker.
  line = form.addLine("Picture")
  local ok, field = pcall(function()
    return form.addFileField(line, nil, IMAGE_DIR, "image",
      function() return widget.imageFile end,
      function(v) widget.imageFile = v or ""; lcd.invalidate() end)
  end)
  if ok and field then
    pictureField = field
  else
    pictureField = form.addTextField(line, nil,
      function() return widget.imageFile end,
      function(v) widget.imageFile = v or ""; lcd.invalidate() end)
  end
  updatePictureField()

  line = form.addLine("Receiver voltage")
  form.addSourceField(line, nil,
    function() return widget.rxSource end,
    function(v) widget.rxSource = v end)

  line = form.addLine("Receiver battery type")
  form.addChoiceField(line, nil, RX_TYPE_CHOICES,
    function() return widget.rxType end,
    function(v) widget.rxType = v; lcd.invalidate() end)

  line = form.addLine("Receiver cells")
  form.addChoiceField(line, nil, RX_CELL_CHOICES,
    function() return widget.rxCells end,
    function(v) widget.rxCells = v; lcd.invalidate() end)

  line = form.addLine("Timer")
  form.addSourceField(line, nil,
    function() return widget.timerSource end,
    function(v) widget.timerSource = v; widget.lastTimer = nil; widget.timerMax = 0 end)

  line = form.addLine("Engine arm switch")
  form.addSwitchField(line, nil,
    function() return widget.armSwitch end,
    function(v) widget.armSwitch = v end)

  -- Pick the matching position of the same 3-position switch for each.
  for i = 1, 3 do
    line = form.addLine(RATE_NAMES[i] .. " rate switch position")
    form.addSwitchField(line, nil,
      function() return widget.rateSwitches[i] end,
      function(v) widget.rateSwitches[i] = v end)
  end

  line = form.addLine("Demo source (testing)")
  form.addSourceField(line, nil,
    function() return widget.demoSource end,
    function(v) widget.demoSource = v; widget.lastTimer = nil end)
end

-- Ethos stores settings by position, so settings saved by an older version
-- of this widget can land in the wrong slot. Keep only values of the
-- right type; anything else falls back to the default.
local function asSource(v)
  if type(v) == "userdata" or type(v) == "table" then return v end
  return nil
end
local function asString(v, def)
  if type(v) == "string" then return v end
  return def
end
local function asInt(v, def, lo, hi)
  if type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi then return v end
  return def
end

local function read(widget)
  widget.imageFile   = asString(storage.read("image"), "")
  -- Older versions had no mode: a typed-in file name meant "use that file".
  widget.imageMode   = asInt(storage.read("imgMode"), nil, IMG_MODEL, IMG_FILE)
    or ((widget.imageFile ~= "") and IMG_FILE or IMG_MODEL)
  widget.rxSource    = asSource(storage.read("rxSrc"))
  widget.rxType      = asInt(storage.read("rxType"), 1, 1, #BATT_TYPES)
  widget.rxCells     = asInt(storage.read("rxCells"), 2, 1, 12)
  widget.timerSource = asSource(storage.read("timerSrc"))
  widget.armSwitch   = asSource(storage.read("armSw"))
  widget.rateSwitches = {
    asSource(storage.read("rateLow")),
    asSource(storage.read("rateMed")),
    asSource(storage.read("rateHigh")),
  }
  widget.demoSource  = asSource(storage.read("demo"))
end

local function write(widget)
  storage.write("image", widget.imageFile)
  storage.write("imgMode", widget.imageMode)
  storage.write("rxSrc", widget.rxSource)
  storage.write("rxType", widget.rxType)
  storage.write("rxCells", widget.rxCells)
  storage.write("timerSrc", widget.timerSource)
  storage.write("armSw", widget.armSwitch)
  storage.write("rateLow", widget.rateSwitches[1])
  storage.write("rateMed", widget.rateSwitches[2])
  storage.write("rateHigh", widget.rateSwitches[3])
  storage.write("demo", widget.demoSource)
end

local function init()
  system.registerWidget({
    key = "gasdash",
    name = "Gas Flight Dash",
    title = false,
    create = create,
    wakeup = wakeup,
    paint = paint,
    configure = configure,
    read = read,
    write = write,
  })
end

return { init = init }
