-- Electric Flight Dash widget for FrSky Ethos
-- Copy this folder to the radio SD card as /scripts/electricflightdash/main.lua
--
-- Designed for a full-screen widget (one widget filling the whole screen).
--
-- Layout:
--   FLIGHT BATTERY      DEMO  |  ( 07:42 )   [  ENGINE  ]
--        .-~~~~~~~-.          |  ( TIMER )   [ DISARMED ]
--      /   22.20V    \        |-------------------------------
--     |  3.70V/cell 6S |      |  RECEIVER       2S  4.00V/cell
--                             |        .-~~~~~~~-.
--   RATES [LOW][MED][HIGH]    |      /    8.0V     \
--
-- Flight battery: 240 degree dial, Auto (1S-12S) or fixed cell count.
-- Timer:          any Ethos timer, shown as MM:SS. Ring and digits turn red
--                 in the last minute and when the timer runs past zero.
-- Engine:         green ARMED / red DISARMED from a logical or physical switch.
-- Receiver:       half dial from a telemetry voltage, with a pack preset
--                 (6.0 / 7.2 / 8.4 V) and adjustable colour bands.
-- Rates:          LOW / MED / HIGH from a 3-position switch. Each rate gets
--                 its own switch-position setting (e.g. SA-up / SA-mid /
--                 SA-down), so Ethos reports the active position directly.
-- Trims:          edge bars for the four stick trims (Mode 2: throttle left,
--                 elevator right, rudder and aileron along the bottom).
--                 Found automatically; can be changed or hidden in settings.
--
-- Demo mode (for bench testing): pick a pot or slider as "Demo source".
--   * Flight and receiver battery voltages always follow the pot. With fixed
--     flight cells the pot sweeps 3.40-4.30 V/cell; with Auto the travel is
--     split into 2S, 3S, 4S ... 12S bands, each sweeping 3.40-4.30 V/cell.
--   * Timer, engine switch and rates switch use the real ones if they are
--     set; any that are not set are simulated from the pot as well.
--   * A pot or slider picked directly as "Flight battery voltage" or
--     "Receiver voltage" drives just that dial the same way, so each dial
--     can have its own slider.
--   A red DEMO tag is shown whenever any of this is active.
--
-- Performance: Ethos limits how many Lua instructions one callback may run.
-- Dial geometry is therefore computed once per widget size and cached, and
-- each dial is drawn in a single pass with no overdraw.

------------------------------------------------------------------------
-- Settings you may want to tweak
------------------------------------------------------------------------
local TIMER_WARN = 60        -- seconds left when the timer turns red

-- Per-cell voltages for each battery type: empty = left end of the dial,
-- full = right end, >= green is green, >= yellow is yellow, below is red.
local BATT_TYPES = {
  { name = "LiPo",   empty = 3.60, full = 4.20, yellow = 3.80, green = 4.05 },
  { name = "LiFe",   empty = 3.00, full = 3.45, yellow = 3.15, green = 3.25 },
  { name = "Li-Ion", empty = 3.30, full = 4.20, yellow = 3.60, green = 3.90 },
  { name = "NiMH",   empty = 1.10, full = 1.40, yellow = 1.20, green = 1.25 },
}

-- Receiver pack presets (volts). Dial runs from empty (left) to full
-- (right); green from `green`, yellow from `yellow`, red below that.
-- Picking a preset fills these in; each can then be adjusted in settings.
local RX_PRESETS = {
  { name = "6.0V", empty = 5.00, yellow = 5.40, green = 5.70, full = 6.00 },
  { name = "7.2V", empty = 6.00, yellow = 6.30, green = 6.50, full = 7.20 },
  { name = "8.4V", empty = 6.50, yellow = 6.70, green = 7.00, full = 8.40 },
}
local RX_DEFAULT_PRESET = 3

local FLIGHT_TYPE = BATT_TYPES[1]   -- flight pack is LiPo

-- Flight pack auto-detect, 1S to MAX_CELLS. When telemetry first appears the
-- cell count is the total voltage divided by DETECT_FULL_CELL, rounded up.
-- That is right for any charged pack (12S needs >= 3.90 V/cell, 6S >= 3.55),
-- and the count is then held (latched) so sag under load can't lower it.
-- The latch clears when telemetry is lost, e.g. when the pack is unplugged.
local MAX_CELLS = 12
local DETECT_FULL_CELL = 4.25

-- Demo with Auto cells: pot travel is split into one band per pack size,
-- 2S to 12S in 1S steps.
local DEMO_AUTO_PACKS = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }

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

-- The receiver's dial ranges in volts, shaped like a battery type with one
-- "cell". Falls back to the preset if the adjusted values are out of order.
local function rxProfile(widget)
  local p = { empty = widget.rxEmpty, yellow = widget.rxYellow,
              green = widget.rxGreen, full = widget.rxFull }
  if not (p.empty and p.yellow and p.green and p.full)
     or not (p.empty <= p.yellow and p.yellow <= p.green and p.green < p.full) then
    p = RX_PRESETS[widget.rxPreset] or RX_PRESETS[RX_DEFAULT_PRESET]
  end
  return p
end

local function detectCells(volts)
  local n = math.ceil(volts / DETECT_FULL_CELL)
  if n < 1 then n = 1 elseif n > MAX_CELLS then n = MAX_CELLS end
  return n
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

-- Dial style: a dark track, a fill that fades red -> yellow -> green along
-- the scale, rounded ends, a white dot at the tip, and a scale of ticks
-- inside the arc.
local RGB_RED, RGB_YELLOW, RGB_GREEN = { 220, 30, 30 }, { 240, 200, 0 }, { 0, 200, 60 }
local C_TICK = lcd.RGB(90, 98, 108)
local TICK_FONT = FONT_XS or FONT_S

local function mixRGB(a, b, t)
  t = clamp01(t)
  return lcd.RGB(math.floor(a[1] + (b[1] - a[1]) * t + 0.5),
                 math.floor(a[2] + (b[2] - a[2]) * t + 0.5),
                 math.floor(a[3] + (b[3] - a[3]) * t + 0.5))
end

-- Colour of every segment: red at the empty end, yellow where the yellow
-- band starts (fY) and green from where the green band starts (fG).
-- Cached on the dial until the bands change.
local function gradientColors(d, fY, fG)
  local key = string.format("%.3f|%.3f", fY, fG)
  if d.gradKey == key then return d.grad end
  local cols = {}
  for i = 0, d.n - 1 do
    local f = (d.mid[i] - d.a0) / (d.a1 - d.a0)
    if f < fY and fY > 0 then
      cols[i] = mixRGB(RGB_RED, RGB_YELLOW, f / fY)
    elseif f < fG and fG > fY then
      cols[i] = mixRGB(RGB_YELLOW, RGB_GREEN, (f - fY) / (fG - fY))
    else
      cols[i] = mixRGB(RGB_GREEN, RGB_GREEN, 0)
    end
  end
  d.grad, d.gradKey = cols, key
  return d.grad
end

-- Track plus fill up to frac (0..1, nil = no reading). The fill uses the
-- per-segment colours in cols, or one solid colour.
local function drawSweep(d, frac, cols, solid)
  local xi, yi, xo, yo, mid = d.xi, d.yi, d.xo, d.yo, d.mid
  local fillA = frac and dialAngle(d, clamp01(frac)) or nil
  local cur = nil
  for i = 0, d.n - 1 do
    local c = C_TILE
    if fillA and mid[i] <= fillA then c = solid or cols[i] end
    if c ~= cur then lcd.color(c); cur = c end
    local j = i + 1
    lcd.drawFilledTriangle(xi[i], yi[i], xo[i], yo[i], xo[j], yo[j])
    lcd.drawFilledTriangle(xi[i], yi[i], xo[j], yo[j], xi[j], yi[j])
  end

  local rm = (d.r1 + d.r2) / 2
  local cap = math.max(2, math.floor((d.r2 - d.r1) / 2))
  if d.a1 - d.a0 < 360 then
    -- Rounded ends of the track.
    local sx, sy = polar(d.cx, d.cy, rm, d.a0)
    lcd.color((fillA and fillA > d.a0) and (solid or cols[0]) or C_TILE)
    lcd.drawFilledCircle(sx, sy, cap)
    local ex, ey = polar(d.cx, d.cy, rm, d.a1)
    lcd.color((fillA and fillA >= d.a1) and (solid or cols[d.n - 1]) or C_TILE)
    lcd.drawFilledCircle(ex, ey, cap)
  end
  if fillA then
    local tx, ty = polar(d.cx, d.cy, rm, fillA)
    lcd.color(C_TEXT)
    lcd.drawFilledCircle(tx, ty, cap + 3)
  end
end

-- Scale inside the arc: scale.n intervals, a labelled major tick every
-- scale.major ticks. Positions are cached on the dial per scale.key.
local function drawTicks(d, scale)
  if d.tickKey ~= scale.key then
    local t = {}
    local rin = d.r1 - 3
    local big = math.max(5, math.floor(d.r2 * 0.08))
    lcd.font(TICK_FONT)
    for k = 0, scale.n do
      local f = k / scale.n
      local a = dialAngle(d, f)
      local major = (k % scale.major == 0)
      local len = major and big or math.floor(big / 2)
      local x0, y0 = polar(d.cx, d.cy, rin - len, a)
      local x1, y1 = polar(d.cx, d.cy, rin, a)
      local e = { x0, y0, x1, y1, major }
      if major then
        local txt = scale.label(f)
        local tw, th = lcd.getTextSize(txt)
        local lx, ly = polar(d.cx, d.cy, rin - big - 3 - math.max(tw, th) / 2, a)
        e.txt, e.lx, e.ly = txt, math.floor(lx - tw / 2), math.floor(ly - th / 2)
      end
      t[#t + 1] = e
    end
    d.ticks, d.tickKey = t, scale.key
  end
  lcd.font(TICK_FONT)
  for _, e in ipairs(d.ticks) do
    lcd.color(e[5] and C_SUBTEXT or C_TICK)
    lcd.drawLine(e[1], e[2], e[3], e[4])
    if e.txt then
      lcd.color(C_SUBTEXT)
      lcd.drawText(e.lx, e.ly, e.txt)
    end
  end
end

-- Battery dial: gradient fill to the reading plus its scale.
-- cell = per-cell volts (or volts for a one-"cell" profile), nil = none.
local function drawZoneDial(d, bt, cell, scale)
  local fY, fG = cellFrac(bt.yellow, bt), cellFrac(bt.green, bt)
  drawSweep(d, cell and cellFrac(cell, bt) or nil, gradientColors(d, fY, fG), nil)
  if scale then drawTicks(d, scale) end
end

-- Receiver scale: a tick every 0.1 V, labelled every 0.5 V.
local function rxScale(bt)
  local n = math.max(4, math.min(40, math.floor((bt.full - bt.empty) / 0.1 + 0.5)))
  return { key = string.format("rx%.2f|%.2f", bt.empty, bt.full), n = n, major = 5,
           label = function(f)
             return string.format("%.1f", bt.empty + f * (bt.full - bt.empty))
           end }
end

------------------------------------------------------------------------
-- Trims: edge bars like the Ethos home screen (Mode 2 layout):
-- throttle on the left edge, elevator on the right edge, rudder along the
-- bottom-left and aileron along the bottom-right. The marker turns green
-- when a trim is centred.
------------------------------------------------------------------------
local TRIM_RUD, TRIM_ELE, TRIM_THR, TRIM_AIL = 1, 2, 3, 4
local TRIM_NAMES = { "Rudder", "Elevator", "Throttle", "Aileron" }
local TRIM_KEYS  = { "rud", "ele", "thr", "ail" }
local C_TRIM_TICK = lcd.RGB(90, 98, 108)

-- Find the four stick trims. Matches them by name when Ethos names them
-- that way; otherwise assumes T1..T4 = rudder, elevator, throttle, aileron.
-- Any of them can be changed in the widget settings.
local function findTrims()
  local found, byOrder, named = {}, {}, false
  if CATEGORY_TRIM == nil then return found end
  for m = 0, 3 do
    local ok, src = pcall(function()
      return system.getSource({ category = CATEGORY_TRIM, member = m })
    end)
    if ok and src then
      byOrder[m + 1] = src
      local okN, n = pcall(function() return src:name() end)
      n = (okN and type(n) == "string") and string.lower(n) or ""
      for i, k in ipairs(TRIM_KEYS) do
        if found[i] == nil and string.find(n, k, 1, true) then
          found[i] = src
          named = true
        end
      end
    end
  end
  if not named then return byOrder end
  return found
end

-- Trim position as 0..1 (0.5 = centre), whether it is centred, and the
-- number to show (as Ethos shows it, e.g. "+4" or "-114").
-- Uses the source's own range when Ethos provides it, else +/-1024.
local function trimFrac(src)
  if src == nil then return nil, false, nil end
  local ok, v = pcall(function() return src:value() end)
  if not ok or type(v) ~= "number" then return nil, false, nil end
  local scale = 1024
  local okM, mx = pcall(function() return src:maximum() end)
  if okM and type(mx) == "number" and mx > 0 then scale = mx end

  local label = nil
  local okS, sv = pcall(function() return src:stringValue() end)
  if okS and type(sv) == "string" and sv ~= "" then
    label = sv
  else
    label = string.format("%d", math.floor(v + 0.5))
  end
  if string.match(label, "^%d") and string.match(label, "[1-9]") then
    label = "+" .. label
  end
  return clamp01((v / scale + 1) / 2), math.abs(v) < 0.5, label
end

local TRIM_FONT = FONT_XS or FONT_S

-- One trim bar: thin track, centre tick, a square marker and the trim
-- number beside it. Vertical bars put positive trim at the top; their
-- number sits above or below the marker, whichever side has more room.
local function drawTrimBar(x, y, len, t, frac, centred, label, vertical)
  local trackT = math.max(2, math.floor(t * 0.3))
  local off = math.floor((t - trackT) / 2)
  local mid = math.floor(len / 2)
  lcd.color(C_TRACK)
  if vertical then
    lcd.drawFilledRectangle(x + off, y, trackT, len)
    lcd.color(C_TRIM_TICK)
    lcd.drawFilledRectangle(x, y + mid - 1, t, 2)
  else
    lcd.drawFilledRectangle(x, y + off, len, trackT)
    lcd.color(C_TRIM_TICK)
    lcd.drawFilledRectangle(x + mid - 1, y, 2, t)
  end
  if frac == nil then return end

  local p = math.floor(frac * (len - t) + 0.5)
  local mx, my
  if vertical then mx, my = x, y + (len - t) - p else mx, my = x + p, y end
  lcd.color(centred and C_GREEN or C_TEXT)
  lcd.drawFilledRectangle(mx, my, t, t)

  -- A centred trim is shown by the green marker, so no number then.
  if label == nil or centred then return end
  lcd.font(TRIM_FONT)
  local tw, th = lcd.getTextSize(label)
  local tx, ty
  if vertical then
    tx = (x == 0) and 0 or (x + t - tw)   -- flush with the screen edge
    ty = (frac > 0.5) and (my + t + 3) or (my - th - 3)
  else
    -- Put the number on whichever side of the marker has more room.
    tx = (frac > 0.5) and (mx - tw - 4) or (mx + t + 4)
    ty = y + math.floor((t - th) / 2)
  end
  lcd.color(C_BG)
  lcd.drawFilledRectangle(tx - 2, ty, tw + 4, th)
  lcd.color(C_TEXT)
  lcd.drawText(tx, ty, label)
end

local function paintTrims(widget, L)
  if not L.trims then return end
  local f, c, s, t = widget.trimFrac, widget.trimCentred, widget.trimLabel, L.tb
  drawTrimBar(L.tLeftX,  L.tVy, L.tVlen,   t, f[TRIM_THR], c[TRIM_THR], s[TRIM_THR], true)
  drawTrimBar(L.tRightX, L.tVy, L.tVlen,   t, f[TRIM_ELE], c[TRIM_ELE], s[TRIM_ELE], true)
  drawTrimBar(L.tRudX,   L.tHy, L.tRudLen, t, f[TRIM_RUD], c[TRIM_RUD], s[TRIM_RUD], false)
  drawTrimBar(L.tAilX,   L.tHy, L.tAilLen, t, f[TRIM_AIL], c[TRIM_AIL], s[TRIM_AIL], false)
end

------------------------------------------------------------------------
-- Layout (computed once per widget size)
------------------------------------------------------------------------
local function buildLayout(w, h, trims)
  local L = { w = w, h = h }
  local pad = math.max(4, math.floor(h * 0.03))
  L.pad = pad
  lcd.font(FONT_S)
  local _, lh = lcd.getTextSize("Ag")
  L.lh = lh

  -- Trim bars take a strip on the left, right and bottom edges.
  L.trims = trims
  local ox, cw, ch = 0, w, h
  if trims then
    local t = math.max(8, math.floor(h * 0.045))
    L.tb = t
    -- Side strips only hold the bars; the side numbers sit above or below
    -- their markers, lined up with the screen edge.
    ox = t + 3
    cw = w - 2 * ox
    ch = h - t - 3
  end
  L.ch = ch

  -- Columns: left half for flight battery + rates, right half for the rest.
  local split = ox + math.floor(cw * 0.5)
  L.split = split
  L.lx = ox + pad
  L.lw = split - pad - math.floor(pad / 2)
  L.rx = split + math.floor(pad / 2) + 1
  L.rw = ox + cw - L.rx - pad

  -- Left: flight dial above the rates strip.
  L.ratesH = math.max(24, math.floor(ch * 0.12))
  L.ratesY = ch - pad - L.ratesH
  local fTop = pad + lh + 2
  local fH = L.ratesY - pad - fTop
  local r = math.max(16, math.floor(math.min(L.lw / 2, fH / 1.5)))
  local band = math.max(5, math.floor(r * 0.14))
  local cx = math.floor(L.lx + L.lw / 2)
  local cy = math.floor(fTop + (fH - 1.5 * r) / 2 + r)
  L.flight = makeDial(cx, cy, r - band, r, -120, 120)

  -- Right top: timer ring and engine light as two equal circles, each with
  -- its name underneath (same size as the circles on the Gas Flight Dash).
  L.rowH = math.floor((ch - 2 * pad) * 0.44)
  local ringR = math.max(12, math.floor(math.min((L.rw / 3 - pad) / 2, (L.rowH - lh - 3) / 2)))
  local rBand = math.max(5, math.floor(ringR * 0.13))
  L.circR = ringR
  L.circY = math.floor(pad + (L.rowH - (2 * ringR + 3 + lh)) / 2 + ringR)
  L.ring = makeDial(math.floor(L.rx + L.rw * 0.25), L.circY, ringR - rBand, ringR, 0, 360)
  L.engCx = math.floor(L.rx + L.rw * 0.75)

  -- Right bottom: receiver half dial.
  L.rxDivY = pad + L.rowH + pad
  L.rxY = L.rxDivY + math.floor(pad / 2) + 1
  local rxH = ch - L.rxY - pad
  local top = L.rxY + lh + 4
  local availH = rxH - lh - 4
  local rr = math.max(16, math.floor(math.min(L.rw / 2, availH)))
  local rrBand = math.max(5, math.floor(rr * 0.14))
  local rcx = math.floor(L.rx + L.rw / 2)
  local rcy = math.floor(top + (availH - rr) / 2 + rr)
  L.rxDial = makeDial(rcx, rcy, rr - rrBand, rr, -90, 90)

  if trims then
    local t = L.tb
    L.tLeftX, L.tRightX = 0, w - t
    L.tVy, L.tVlen = pad, ch - 2 * pad
    L.tHy = h - t
    L.tRudX, L.tRudLen = L.lx, L.lw
    L.tAilX, L.tAilLen = L.rx, L.rw
  end

  return L
end

------------------------------------------------------------------------
-- Widget callbacks
------------------------------------------------------------------------
local function create()
  return {
    -- settings
    battSource = nil,
    battCells = 0,        -- 0 = Auto
    rxSource = nil,
    rxPreset = RX_DEFAULT_PRESET,  -- index into RX_PRESETS
    rxEmpty  = RX_PRESETS[RX_DEFAULT_PRESET].empty,
    rxYellow = RX_PRESETS[RX_DEFAULT_PRESET].yellow,
    rxGreen  = RX_PRESETS[RX_DEFAULT_PRESET].green,
    rxFull   = RX_PRESETS[RX_DEFAULT_PRESET].full,
    timerSource = nil,
    armSwitch = nil,
    rateSwitches = {},    -- [1]=LOW, [2]=MED, [3]=HIGH switch positions
    demoSource = nil,     -- pot/slider that fakes values for testing
    -- live values
    volts = nil, cells = 0, latched = 0,
    rxVolts = nil,
    timerSecs = nil, timerMax = 0, lastTimer = nil,
    armed = nil,
    rate = nil,
    demo = false,
    lastKey = nil,
    trimShow = 1,         -- 1 = show the trim edge bars
    trimSources = findTrims(),
    trimFrac = {}, trimCentred = {}, trimLabel = {},
    layout = nil,
  }
end

local function wakeup(widget)
  -- Demo pot position 0..1, or nil when demo mode is off.
  local demoT = nil
  if widget.demoSource then
    local p = widget.demoSource:value()
    if p then demoT = potToFrac(p) end
  end
  local rxBt = rxProfile(widget)

  -- A pot/slider picked directly as a voltage source drives that dial like
  -- demo mode (raw -1024..1024 would otherwise show as hundreds of volts).
  local flightT, flightRaw = demoT, nil
  if flightT == nil and widget.battSource then
    flightRaw = widget.battSource:value()
    if isAnalogInput(widget.battSource, flightRaw) then flightT = potToFrac(flightRaw) end
  end
  local rxT, rxRaw = demoT, nil
  if rxT == nil and widget.rxSource then
    rxRaw = widget.rxSource:value()
    if isAnalogInput(widget.rxSource, rxRaw) then rxT = potToFrac(rxRaw) end
  end

  -- Flight battery
  local v
  local demoPack = nil
  if flightT then
    local demoT = flightT
    if widget.battCells > 0 then
      v = widget.battCells * (3.40 + 0.90 * demoT)   -- 3.40 to 4.30 V/cell
    else
      -- Auto: split the pot travel into one band per pack size (2S to 12S,
      -- smallest first). Each band sweeps a realistic 3.40 to 4.30 V/cell.
      -- The cell count is what auto-detect gives for that pack fully charged,
      -- as if it had just been plugged in.
      local nb = #DEMO_AUTO_PACKS
      local band = math.min(nb - 1, math.floor(demoT * nb))
      local t = demoT * nb - band
      local pack = DEMO_AUTO_PACKS[band + 1]
      v = pack * (3.40 + 0.90 * t)
      demoPack = detectCells(pack * 4.20)
    end
  else
    v = flightRaw
  end
  if v == nil or v < 1 then
    widget.volts = nil
    widget.latched = 0
  else
    widget.volts = v
    if widget.battCells > 0 then
      widget.cells = widget.battCells
    elseif demoPack then
      widget.cells = demoPack
    else
      -- Latch the highest count so sag under load can't flip 6S to 3S.
      local n = detectCells(v)
      if n > widget.latched then widget.latched = n end
      widget.cells = widget.latched
    end
  end

  -- Receiver battery
  local rv
  if rxT then
    -- Sweep a little past each end of the receiver dial.
    local lo = rxBt.empty - 0.10 * (rxBt.full - rxBt.empty)
    local hi = rxBt.full + 0.05 * (rxBt.full - rxBt.empty)
    rv = lo + (hi - lo) * rxT
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

  widget.demo = (demoT ~= nil) or (flightT ~= nil) or (rxT ~= nil)

  local key = string.format("%s|%s|%d|%s|%s|%s|%s|%s", tostring(widget.demo),
    widget.volts and string.format("%.2f", widget.volts) or "-", widget.cells,
    widget.rxVolts and string.format("%.2f", widget.rxVolts) or "-",
    tostring(widget.timerSecs), tostring(widget.timerMax),
    tostring(widget.armed), tostring(widget.rate))
  -- Trims
  local trimKey = ""
  if widget.trimShow == 1 then
    for i = 1, 4 do
      local fr, ctr, lbl = trimFrac(widget.trimSources[i])
      widget.trimFrac[i], widget.trimCentred[i], widget.trimLabel[i] = fr, ctr, lbl
      trimKey = trimKey .. (fr and string.format("%.3f", fr) or "-") .. (ctr and "c" or "") .. tostring(lbl) .. "|"
    end
  end
  key = key .. "|" .. trimKey
  if key ~= widget.lastKey then
    widget.lastKey = key
    lcd.invalidate()
  end
end

------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------
-- Flight scale: a tick every 0.05 V/cell, labelled every 0.1 V (3.6-4.2).
local FLIGHT_SCALE = { key = "flight", n = 12, major = 2,
  label = function(f)
    return string.format("%.1f", FLIGHT_TYPE.empty + f * (FLIGHT_TYPE.full - FLIGHT_TYPE.empty))
  end }

local function paintFlight(widget, L)
  local d = L.flight
  lcd.font(FONT_S)
  lcd.color(C_SUBTEXT)
  lcd.drawText(L.lx, L.pad, "FLIGHT BATTERY")
  if widget.demo then
    -- Make demo mode obvious so it never gets left on for a real flight.
    lcd.color(C_RED_TEXT)
    lcd.drawText(L.lx + L.lw, L.pad, "DEMO", RIGHT)
  end

  -- Percentage is the position on the 3.60-4.20 V/cell scale (a straight
  -- line, not a true state of charge).
  local pct, total, sub, color, cell
  if widget.volts then
    cell = widget.volts / widget.cells
    color = zoneColor(cell, FLIGHT_TYPE)
    pct = string.format("%d%%", math.floor(cellFrac(cell, FLIGHT_TYPE) * 100 + 0.5))
    total = string.format("%.2fV", widget.volts)
    sub = string.format("%.2fV/cell  %dS", cell, widget.cells)
  else
    color = C_GREY
    pct = "--%"
    total = "--.--V"
    sub = (widget.battSource or widget.demo) and "No telemetry" or "Set source"
  end

  drawZoneDial(d, FLIGHT_TYPE, cell, FLIGHT_SCALE)

  -- Big percentage, then pack volts, then volts per cell and cell count.
  lcd.color(color == C_RED and C_RED_TEXT or color)
  local pw, ph = fitFont(pct, d.r1 * 1.0, d.r1 * 0.5)
  local py = d.cy - ph * 0.8
  drawCentered(d.cx, py, pct, pw)

  lcd.color(widget.volts and C_TEXT or C_GREY)
  local tw, th = fitFont(total, d.r1 * 1.0, d.r1 * 0.22)
  drawCentered(d.cx, py + ph, total, tw)

  lcd.color(C_SUBTEXT)
  local sw = fitFont(sub, d.r1 * 1.2, d.r1 * 0.18)
  drawCentered(d.cx, py + ph + th + 2, sub, sw)
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

  drawSweep(d, frac > 0 and frac or nil, nil, color)

  lcd.color(textColor)
  local tw, th = fitFont(text, d.r1 * 1.6, d.r1 * 0.75)
  drawCentered(d.cx, d.cy - th / 2, text, tw)

  -- Name underneath, like the engine light.
  lcd.font(FONT_S)
  lcd.color(C_SUBTEXT)
  local label = (widget.timerSource or widget.demo) and "TIMER" or "Set timer"
  local lw = lcd.getTextSize(label)
  drawCentered(d.cx, L.circY + L.circR + 3, label, lw)
end

-- Engine light: green ARMED / red DISARMED / grey SET when no switch is set,
-- the same size as the timer ring, with ENGINE underneath.
local function paintEngine(widget, L)
  local cx, cy, r = L.engCx, L.circY, L.circR
  local bg, state = C_GREY, "SET"
  if widget.armed == true then
    bg, state = C_ARMED, "ARMED"
  elseif widget.armed == false then
    bg, state = C_DISARMED, "DISARMED"
  end
  lcd.color(bg)
  lcd.drawFilledCircle(cx, cy, r)

  lcd.color(C_TEXT)
  local sw, sh = fitFont(state, r * 1.6, r * 0.6)
  drawCentered(cx, cy - sh / 2, state, sw)

  lcd.font(FONT_S)
  lcd.color(C_SUBTEXT)
  local lw = lcd.getTextSize("ENGINE")
  drawCentered(cx, cy + r + 3, "ENGINE", lw)
end

local function paintReceiver(widget, L)
  local d = L.rxDial
  local bt = rxProfile(widget)

  lcd.font(FONT_S)
  lcd.color(C_SUBTEXT)
  lcd.drawText(L.rx, L.rxY, "RECEIVER")

  local cell, color, text, sub = nil, C_GREY, "--.-V", nil
  if widget.rxVolts then
    cell = widget.rxVolts
    color = zoneColor(cell, bt)
    text = string.format("%.1fV", widget.rxVolts)
    sub = string.format("%.1f-%.1fV", bt.empty, bt.full)
  else
    sub = (widget.rxSource or widget.demo) and "No telemetry" or "Set source"
  end
  lcd.drawText(L.rx + L.rw, L.rxY, sub, RIGHT)

  drawZoneDial(d, bt, cell, rxScale(bt))

  lcd.color(color == C_RED and C_RED_TEXT or color)
  local tw, th = fitFont(text, d.r1 * 1.0, d.r1 * 0.5)
  drawCentered(d.cx, d.cy - th, text, tw)
end

local function paint(widget)
  local w, h = lcd.getWindowSize()
  local L = widget.layout
  local trims = widget.trimShow == 1
  if L == nil or L.w ~= w or L.h ~= h or L.trims ~= trims then
    L = buildLayout(w, h, trims)
    widget.layout = L
  end

  lcd.color(C_BG)
  lcd.drawFilledRectangle(0, 0, w, h)

  -- Dividers
  lcd.color(C_TRACK)
  lcd.drawFilledRectangle(L.split, L.pad, 1, L.ch - 2 * L.pad)
  lcd.drawFilledRectangle(L.lx, L.ratesY - math.floor(L.pad / 2) - 1, L.lw, 1)
  lcd.drawFilledRectangle(L.rx, L.rxDivY, L.rw, 1)

  paintFlight(widget, L)
  paintRates(widget, L)
  paintTimer(widget, L)
  paintEngine(widget, L)
  paintReceiver(widget, L)
  paintTrims(widget, L)
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local FLIGHT_CELL_CHOICES = { { "Auto (1S-12S)", 0 } }
for n = 1, MAX_CELLS do
  FLIGHT_CELL_CHOICES[#FLIGHT_CELL_CHOICES + 1] = { n .. "S", n }
end

local RX_PRESET_CHOICES = {}
for i, p in ipairs(RX_PRESETS) do RX_PRESET_CHOICES[i] = { p.name .. " pack", i } end

-- A volts setting shown with two decimals (the field works in hundredths).
local function addVoltsField(label, get, set)
  local line = form.addLine(label)
  local f = form.addNumberField(line, nil, 300, 1500,
    function() return math.floor((get() or 0) * 100 + 0.5) end,
    function(v) set(v / 100); lcd.invalidate() end)
  pcall(function() f:decimals(2) end)
  pcall(function() f:suffix("V") end)
end

local function configure(widget)
  local line = form.addLine("Flight battery voltage")
  form.addSourceField(line, nil,
    function() return widget.battSource end,
    function(v) widget.battSource = v; widget.latched = 0 end)

  line = form.addLine("Flight battery cells")
  form.addChoiceField(line, nil, FLIGHT_CELL_CHOICES,
    function() return widget.battCells end,
    function(v) widget.battCells = v; widget.latched = 0 end)

  line = form.addLine("Receiver voltage")
  form.addSourceField(line, nil,
    function() return widget.rxSource end,
    function(v) widget.rxSource = v end)

  line = form.addLine("Receiver pack")
  form.addChoiceField(line, nil, RX_PRESET_CHOICES,
    function() return widget.rxPreset end,
    function(v)
      local p = RX_PRESETS[v] or RX_PRESETS[RX_DEFAULT_PRESET]
      widget.rxPreset = v
      widget.rxEmpty, widget.rxYellow, widget.rxGreen, widget.rxFull =
        p.empty, p.yellow, p.green, p.full
      lcd.invalidate()
    end)

  addVoltsField("Receiver dial start",
    function() return widget.rxEmpty end, function(v) widget.rxEmpty = v end)
  addVoltsField("Receiver yellow from",
    function() return widget.rxYellow end, function(v) widget.rxYellow = v end)
  addVoltsField("Receiver green from",
    function() return widget.rxGreen end, function(v) widget.rxGreen = v end)
  addVoltsField("Receiver dial end",
    function() return widget.rxFull end, function(v) widget.rxFull = v end)

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

  line = form.addLine("Trim bars")
  form.addChoiceField(line, nil, { { "Show", 1 }, { "Hide", 0 } },
    function() return widget.trimShow end,
    function(v) widget.trimShow = v; lcd.invalidate() end)

  for i = 1, 4 do
    line = form.addLine(TRIM_NAMES[i] .. " trim")
    form.addSourceField(line, nil,
      function() return widget.trimSources[i] end,
      function(v) widget.trimSources[i] = v; lcd.invalidate() end)
  end

  line = form.addLine("Demo source (testing)")
  form.addSourceField(line, nil,
    function() return widget.demoSource end,
    function(v) widget.demoSource = v; widget.latched = 0; widget.lastTimer = nil end)
end

-- Ethos stores settings by position, so settings saved by an older version
-- of this widget can land in the wrong slot. Keep only values of the
-- right type; anything else falls back to the default.
local function asSource(v)
  if type(v) == "userdata" or type(v) == "table" then return v end
  return nil
end
local function asInt(v, def, lo, hi)
  if type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi then return v end
  return def
end

local function read(widget)
  widget.battSource  = asSource(storage.read("battSrc"))
  widget.battCells   = asInt(storage.read("battCells"), 0, 0, MAX_CELLS)
  widget.rxSource    = asSource(storage.read("rxSrc"))
  storage.read("rxType")    -- old slots, no longer used; still read so the
  storage.read("rxCells")   -- settings after them stay in line
  widget.timerSource = asSource(storage.read("timerSrc"))
  widget.armSwitch   = asSource(storage.read("armSw"))
  widget.rateSwitches = {
    asSource(storage.read("rateLow")),
    asSource(storage.read("rateMed")),
    asSource(storage.read("rateHigh")),
  }
  widget.demoSource  = asSource(storage.read("demo"))
  widget.trimShow    = asInt(storage.read("trims"), 1, 0, 1)
  -- Unset trims fall back to the ones found automatically.
  local auto = findTrims()
  widget.trimSources = {}
  for i, k in ipairs(TRIM_KEYS) do
    widget.trimSources[i] = asSource(storage.read("trim_" .. k)) or auto[i]
  end
  widget.rxPreset = asInt(storage.read("rxPreset"), RX_DEFAULT_PRESET, 1, #RX_PRESETS)
  local p = RX_PRESETS[widget.rxPreset]
  local function volts(key, def)
    local v = asInt(storage.read(key), nil, 100, 2000)
    return v and v / 100 or def
  end
  widget.rxEmpty  = volts("rxEmpty",  p.empty)
  widget.rxYellow = volts("rxYellow", p.yellow)
  widget.rxGreen  = volts("rxGreen",  p.green)
  widget.rxFull   = volts("rxFull",   p.full)
end

local function write(widget)
  storage.write("battSrc", widget.battSource)
  storage.write("battCells", widget.battCells)
  storage.write("rxSrc", widget.rxSource)
  storage.write("rxType", 0)    -- unused slots, kept so the settings
  storage.write("rxCells", 0)   -- after them stay in line
  storage.write("timerSrc", widget.timerSource)
  storage.write("armSw", widget.armSwitch)
  storage.write("rateLow", widget.rateSwitches[1])
  storage.write("rateMed", widget.rateSwitches[2])
  storage.write("rateHigh", widget.rateSwitches[3])
  storage.write("demo", widget.demoSource)
  storage.write("trims", widget.trimShow)
  for i, k in ipairs(TRIM_KEYS) do
    storage.write("trim_" .. k, widget.trimSources[i])
  end
  storage.write("rxPreset", widget.rxPreset)
  local function cv(v) return math.floor(v * 100 + 0.5) end
  storage.write("rxEmpty",  cv(widget.rxEmpty))
  storage.write("rxYellow", cv(widget.rxYellow))
  storage.write("rxGreen",  cv(widget.rxGreen))
  storage.write("rxFull",   cv(widget.rxFull))
end

local function init()
  system.registerWidget({
    key = "fltdash",      -- unchanged so existing screens keep their settings
    name = "Electric Flight Dash",
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
