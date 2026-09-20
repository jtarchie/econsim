local ffi = require("ffi")
local rl = require("rl")
local sim = require("sim")
local scen = require("scen")

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local RL_LINES, RL_QUADS = 1, 7
local KEY = { SPACE = 32, MINUS = 45, EQUAL = 61, C = 67, F = 70, G = 71, H = 72, J = 74, L = 76, M = 77, R = 82, S = 83, T = 84, LB = 91, RB = 93 }
local NG, HN = sim.NG, sim.HN
local hist = sim.hist
-- the world is sized by init() from the cap/grid/cell knobs, so these are bound after it runs
local W, U, L, flashes, live, nlive

local function color(r, g, b, a) return ffi.new("Color", r, g, b, a or 255) end
local WHITE, DIM, PANEL, BG = color(230, 230, 230), color(150, 150, 150), color(0, 0, 0, 185), color(12, 12, 16)
local FLASH_RGB = { [0] = { 255, 255, 255 }, { 80, 255, 120 }, { 255, 60, 60 }, { 255, 170, 40 }, { 80, 160, 255 } }
-- one colour per money channel, reused by the income-source view and the inspector bars
local CHAN_RGB = {
  { 150, 150, 160 },
  { 90, 220, 120 },
  { 220, 110, 90 },
  { 90, 170, 255 },
  { 255, 120, 200 },
  { 190, 150, 255 },
  { 255, 215, 90 },
  { 120, 230, 220 },
  { 230, 230, 230 },
}
local VIEWS = { "genome", "wealth rank", "dynasty", "income source" }

-- fail before the window opens: every raylib symbol must resolve, struct layouts must match the C ABI, and the sim must pass its audit
local RAYLIB_SYMBOLS = [[
  SetConfigFlags SetTraceLogLevel InitWindow CloseWindow WindowShouldClose GetScreenWidth GetScreenHeight SetTargetFPS GetFPS BeginDrawing EndDrawing ClearBackground TakeScreenshot GetTime IsKeyPressed IsKeyDown
  IsMouseButtonPressed IsMouseButtonDown IsMouseButtonReleased GetMouseX GetMouseY GetMouseDelta GetMouseWheelMove DrawText DrawRectangle GenImageGradientRadial LoadTextureFromImage UnloadImage SetTextureFilter
  UpdateTexture rlPushMatrix rlPopMatrix rlTranslatef rlScalef rlBegin rlEnd rlVertex2f rlTexCoord2f rlColor4ub rlSetTexture rlCheckRenderBatchLimit rlDrawRenderBatchActive
]]
for name in RAYLIB_SYMBOLS:gmatch("%S+") do
  assert(pcall(function() return rl[name] end), "raylib is missing symbol " .. name)
end
assert(ffi.sizeof("Color") == 4 and ffi.sizeof("Vector2") == 8 and ffi.sizeof("Texture2D") == 20, "raylib struct layout mismatch")
assert(ffi.sizeof("Image") == ffi.sizeof("void *") + 16, "raylib Image layout mismatch")
local opt = sim.parse_args(arg, {
  seed = "random seed (default: clock)",
  speed = "sim ticks per frame at start (default 2)",
  shot = "save shot.png after this many frames and exit",
  no_selftest = "skip the startup audit",
  width = "window width (default 1280)",
  height = "window height (default 800)",
  zoom = "starting zoom, 1 = whole world fits (default 1)",
  pick = "select the richest unit (for screenshots)",
  view = "start in this colour view: 0 genome, 1 wealth rank, 2 dynasty, 3 income source",
  mob = "open the mobility panel at startup",
  scenario = { "path to a scenario file to play out" },
  arm = { "which arm of the scenario to run" },
})
if not opt.no_selftest then sim.selftest(100) end
local sc = opt.scenario and scen.load(opt.scenario)
local arm = sc and scen.arm(sc, opt.arm)

rl.SetTraceLogLevel(4)
rl.SetConfigFlags(4 + 64)
-- 1280x800 fits any laptop desktop; a window taller than the screen loses its top strip to the macOS menu bar
rl.InitWindow(opt.width or 1280, opt.height or 800, "capitalism")
rl.SetTargetFPS(60)

local img = rl.GenImageGradientRadial(64, 64, 0.8, color(255, 255, 255), color(255, 255, 255, 0))
local dot = rl.LoadTextureFromImage(img)
rl.UnloadImage(img)
assert(dot.id > 0, "dot texture failed to upload")
rl.SetTextureFilter(dot, 1)

local land_px, land
local function paint_land()
  land_px = land_px or ffi.new("uint8_t[?]", sim.GRID * sim.GRID * 4)
  for c = 0, sim.GRID * sim.GRID - 1 do
    local f, o = sim.fert[c], sim.ore[c]
    land_px[c * 4], land_px[c * 4 + 1], land_px[c * 4 + 2], land_px[c * 4 + 3] = 18 + f * 20 + o * 75, 22 + f * 70 + o * 30, 18 + f * 20, 255
  end
  if land then
    rl.UpdateTexture(land, land_px)
  else
    land = rl.LoadTextureFromImage(ffi.new("Image", land_px, sim.GRID, sim.GRID, 1, 7))
    assert(land.id > 0, "land texture failed to upload")
    rl.SetTextureFilter(land, 1)
  end
end

local seed = opt.seed or os.time()
local play
if sc then
  play = scen.begin(sc, arm, seed)
else
  sim.init(seed)
end
W = sim.W
U, L, flashes = sim.units, sim.loans, sim.flashes
live, nlive = sim.live_set()
assert(#sim.GENES == NG and sim.GRID * sim.CELL == W, "sim exports inconsistent")
paint_land()

-- fit the world to window height, then nudge right of the 330px stats panel
local zoom = (opt.zoom or 1) * rl.GetScreenHeight() / W
local cam_x, cam_y = (rl.GetScreenWidth() - W * zoom) / 2 + 90, (rl.GetScreenHeight() - W * zoom) / 2
local speed, paused, show_links, show_flash, show_ui = opt.speed or 2, false, true, true, true
local sel_gen, drag = 0, 0
local ticks_since_stats, tick_ms = 0, 0
local view, show_mob = min(#VIEWS - 1, max(0, floor(opt.view or 0))), opt.mob ~= nil

local function quad(x, y, r)
  rl.rlCheckRenderBatchLimit(4)
  rl.rlTexCoord2f(0, 0)
  rl.rlVertex2f(x - r, y - r)
  rl.rlTexCoord2f(0, 1)
  rl.rlVertex2f(x - r, y + r)
  rl.rlTexCoord2f(1, 1)
  rl.rlVertex2f(x + r, y + r)
  rl.rlTexCoord2f(1, 0)
  rl.rlVertex2f(x + r, y - r)
end

-- radius (not area) linear in worth relative to the median: deliberately exaggerated, area-true sizing looked uniform
local function radius(u) return max(1, min(60, 2.5 * sim.worth(u) / sim.stats.median_worth)) end

-- the channel a unit has taken most money from; what it lives on, rather than what its genes say it should
local function income_of(bio)
  local best, bv = 1, 0
  for c = 0, 8 do
    local v = bio.chan[c]
    if v > bv then
      best, bv = c + 1, v
    end
  end
  return best
end

local function tint(u, i)
  if view == 1 then
    local bio = sim.bio(i)
    local p = bio and bio.cur or 0
    return 40 + p * 215, 60 + (1 - abs(p * 2 - 1)) * 120, 255 - p * 215
  elseif view == 2 then
    -- three coprime multipliers mod a prime: adjacent founder numbers land nowhere near each other in any channel
    local d = u.dyn
    return 45 + d * 71 % 211, 45 + d * 137 % 211, 45 + d * 199 % 211
  elseif view == 3 then
    local bio = sim.bio(i)
    local c = CHAN_RGB[bio and income_of(bio) or 1]
    return c[1], c[2], c[3]
  end
  return u.cr, u.cg, u.cb
end

local function draw_tile(ox, oy)
  rl.rlPushMatrix()
  rl.rlTranslatef(cam_x + ox * W * zoom, cam_y + oy * W * zoom, 0)
  rl.rlScalef(zoom, zoom, 1)

  rl.rlSetTexture(land.id)
  rl.rlBegin(RL_QUADS)
  rl.rlColor4ub(255, 255, 255, 255)
  quad(W / 2, W / 2, W / 2)
  rl.rlEnd()

  rl.rlSetTexture(dot.id)
  rl.rlBegin(RL_QUADS)
  local sh = sim.shock
  if sh.ttl > 0 then
    rl.rlColor4ub(200, 30, 30, min(90, sh.ttl))
    quad(sh.x, sh.y, sh.r * 1.2)
  end
  rl.rlEnd()

  if show_links then
    rl.rlSetTexture(0)
    rl.rlBegin(RL_LINES)
    for li = 0, sim.loan_hi() - 1 do
      local l = L[li]
      if l.active == 1 then
        local a, b = U[l.lender], U[l.borrower]
        -- draw to the nearest image of the borrower, not its stored coordinates: a loan across the seam is short, and the old guard dropped 3% of them unseen
        local dx, dy = b.x - a.x, b.y - a.y
        dx = dx > W / 2 and dx - W or (dx < -W / 2 and dx + W or dx)
        dy = dy > W / 2 and dy - W or (dy < -W / 2 and dy + W or dy)
        rl.rlCheckRenderBatchLimit(2)
        rl.rlColor4ub(a.cr, a.cg, a.cb, min(220, 50 + l.owed / 10))
        rl.rlVertex2f(a.x, a.y)
        rl.rlColor4ub(a.cr, a.cg, a.cb, 10)
        rl.rlVertex2f(a.x + dx, a.y + dy)
      end
    end
    rl.rlEnd()
  end

  -- a continent's worth of units is mostly sub-pixel at low zoom; drawing those costs four
  -- vertices each to tint one pixel, so skip them and keep the batch for what is actually visible
  local rmin = 0.4 / zoom
  rl.rlSetTexture(dot.id)
  rl.rlBegin(RL_QUADS)
  for s = 0, nlive - 1 do
    local i = live[s]
    local u = U[i]
    if u.stubborn == 0 then
      local r = radius(u)
      if r > rmin then
        local cr, cg, cb = tint(u, i)
        rl.rlColor4ub(cr, cg, cb, r > 8 and 150 or 235)
        quad(u.x, u.y, r)
      end
    end
  end
  rl.rlEnd()
  rl.rlSetTexture(0)
  rl.rlBegin(RL_QUADS)
  for s = 0, nlive - 1 do
    local i = live[s]
    local u = U[i]
    if u.stubborn == 1 then
      local r = radius(u) * 0.7
      if r > rmin then
        local cr, cg, cb = tint(u, i)
        rl.rlColor4ub(cr, cg, cb, 235)
        quad(u.x, u.y, r)
      end
    end
  end
  rl.rlEnd()
  rl.rlSetTexture(dot.id)
  rl.rlBegin(RL_QUADS)
  for k = 0, sim.NFLASH - 1 do
    local f = flashes[k]
    if f.ttl > 0 and show_flash then
      local c = FLASH_RGB[f.kind]
      rl.rlColor4ub(c[1], c[2], c[3], f.ttl * 6)
      quad(f.x, f.y, (f.kind == 0 and 3 or 6) + (24 - f.ttl) * 0.5)
    end
  end
  local sel = sim.selected
  if sel >= 0 then
    rl.rlColor4ub(255, 255, 255, 90)
    quad(U[sel].x, U[sel].y, radius(U[sel]) + 8)
  end
  rl.rlEnd()
  rl.rlSetTexture(0)
  rl.rlPopMatrix()
end

-- the world is a torus and has no edges, so drawing one square implied a boundary that is not there: every visible copy is drawn, and a town on the seam is one town again
local function draw_world()
  for k = 0, sim.NFLASH - 1 do
    local f = flashes[k]
    if f.ttl > 0 then f.ttl = f.ttl - 1 end
  end
  local span = W * zoom
  local i0, i1 = floor(-cam_x / span), floor((rl.GetScreenWidth() - cam_x) / span)
  local j0, j1 = floor(-cam_y / span), floor((rl.GetScreenHeight() - cam_y) / span)
  -- a cap only bites on a small world zoomed right out; a large one spans the screen in one copy, so this never costs a continent anything
  i1, j1 = min(i1, i0 + 4), min(j1, j0 + 4)
  for i = i0, i1 do
    for j = j0, j1 do
      draw_tile(i, j)
    end
  end
end

local function spark(series, x, y, w, h, r, g, b, lo, hi)
  local s = sim.stats
  local n, head = s.hist_n, s.hist_head
  if n < 2 then return end
  local base = series * HN
  if not lo then
    lo, hi = 1e30, -1e30
    for k = 0, n - 1 do
      local v = hist[base + (head - n + k + HN) % HN]
      lo, hi = min(lo, v), max(hi, v)
    end
  end
  local span = max(1e-9, hi - lo)
  rl.rlBegin(RL_LINES)
  rl.rlColor4ub(r, g, b, 255)
  for k = 0, n - 2 do
    local v0, v1 = hist[base + (head - n + k + HN) % HN], hist[base + (head - n + k + 1 + HN) % HN]
    rl.rlCheckRenderBatchLimit(2)
    rl.rlVertex2f(x + k * w / HN, y + h - (v0 - lo) / span * h)
    rl.rlVertex2f(x + (k + 1) * w / HN, y + h - (v1 - lo) / span * h)
  end
  rl.rlEnd()
end

local function draw_ui()
  local s, k = sim.stats, sim.knobs
  rl.DrawRectangle(0, 0, 330, rl.GetScreenHeight(), PANEL)
  local y = 8
  local function line(str, c)
    rl.DrawText(str, 10, y, 10, c or WHITE)
    y = y + 13
  end
  line(("fps %d   tick %d   %dx/frame   %.1f ms/tick%s"):format(rl.GetFPS(), s.tick, speed, tick_ms, paused and "   PAUSED" or ""))
  line(("pop %d (artisans %d, stubborn %d)   loans %d   debt %.0f"):format(s.pop, s.artisans, s.stubborn, s.nloans, s.debt))
  line(("gini %.3f  top 1%% owns %.0f%%  food %.2f  tools %.2f  capital %.1f"):format(s.gini, s.top1 * 100, s.price, s.tool_price, s.capital))
  line(("per 30t: births %d  starved %d  aged %d  defaults %d"):format(s.births, s.starved, s.aged, s.defaults))
  line(("         trades %d (spec %d)  volume %.0f (tools %.0f)"):format(s.trades, s.spec, s.volume, s.tool_volume))
  line(("lines %d of %d founders   biggest owns %.1f%% of people, %.1f%% of wealth"):format(s.lines, k.pop, s.top_line * 100, s.top_line_worth * 100))
  line(("view: %s   C to cycle   M mobility"):format(VIEWS[view + 1]), color(120, 220, 255))
  y = y + 4
  for i, name in ipairs({ "population", "gini", "food price", "tool price" }) do
    rl.DrawText(name, 10, y + 8, 10, DIM)
    spark(i - 1, 90, y, 225, 26, 120 + i * 40, 220, 255 - i * 50)
    y = y + 30
  end

  line("wealth distribution (log10 bins)", DIM)
  local peak = 1
  for b = 1, 24 do
    peak = max(peak, s.wealth_bins[b])
  end
  for b = 1, 24 do
    local h = floor(s.wealth_bins[b] / peak * 50)
    rl.DrawRectangle(10 + (b - 1) * 13, y + 50 - h, 11, h, color(255, 200, 80))
  end
  y = y + 58

  line("gene means (bar) and history (line)", DIM)
  for g = 1, NG do
    rl.DrawText(sim.GENES[g], 10, y, 10, WHITE)
    rl.DrawRectangle(90, y + 1, 100, 8, color(40, 40, 50))
    rl.DrawRectangle(90, y + 1, floor(s.means[g] * 100), 8, color(90, 200, 255))
    spark(3 + g, 200, y, 115, 10, 255, 255, 255, 0, 1)
    y = y + 13
  end
  y = y + 6
  line(("mutation %.3f  [ ]     estate tax %.0f%%  G T"):format(k.mut, k.estate_tax * 100))
  line("space pause   - = speed   S shock   J jubilee   R reset", DIM)
  line("L links   F flashes   H hide   drag pan   wheel zoom", DIM)
  line("green land = food, orange = ore.  squares = stubborn", DIM)
  if view == 3 then
    for c, name in ipairs(sim.CHANNELS) do
      local col = CHAN_RGB[c]
      rl.DrawRectangle(10 + ((c - 1) % 3) * 105, y + floor((c - 1) / 3) * 13, 8, 8, color(col[1], col[2], col[3]))
      rl.DrawText(name, 22 + ((c - 1) % 3) * 105, y + floor((c - 1) / 3) * 13, 10, WHITE)
    end
    y = y + 42
  elseif view == 1 then
    line("blue = poorest, red = richest, by rank among the living", DIM)
  elseif view == 2 then
    line("one colour per founding line; a spreading colour is a dynasty winning", DIM)
  end

  local sel = sim.selected
  if sel >= 0 then
    local u = U[sel]
    local bio = sim.bio(sel)
    local x0 = rl.GetScreenWidth() - 250
    local extra = bio and (30 + #sim.CHANNELS * 12) or 0
    rl.DrawRectangle(x0, 0, 250, 124 + NG * 13 + extra, PANEL)
    rl.DrawRectangle(x0 + 10, 8, 230, 6, color(u.cr, u.cg, u.cb))
    local rows = {
      ("unit %d   age %d   line %d%s"):format(sel, u.age, u.dyn, bio and ("   kids %d"):format(bio.kids) or ""),
      ("worth %.0f (%.1fx median)   money %.0f"):format(sim.worth(u), sim.worth(u) / sim.stats.median_worth, u.money),
      ("lent %.0f   debt %.0f"):format(u.lent, u.debt),
      ("food %.1f   tools %.1f   capital %.1f%s"):format(u.stock[0], u.stock[1], u.capital, u.stubborn == 1 and "   STUBBORN" or ""),
      ("belief food %.2f  tools %.2f   loans out %d"):format(u.belief[0], u.belief[1], u.nloans),
    }
    for i, str in ipairs(rows) do
      rl.DrawText(str, x0 + 10, 8 + i * 14, 10, WHITE)
    end
    local gy0 = 94
    if bio then
      rl.DrawText(("born t%d at %s   now %.0f%%   peak %.0f%%"):format(bio.born, bio.ppct < 0 and "founding" or ("%.0f%%"):format(bio.ppct * 100), bio.cur * 100, bio.peak * 100), x0 + 10, gy0, 10, color(120, 220, 255))
      rl.DrawText("where the money came from (net)", x0 + 10, gy0 + 14, 10, DIM)
      -- bars scaled to the largest flow either way, so a huge debt is as readable as a huge fortune
      local span = 1
      for c = 0, #sim.CHANNELS - 1 do
        span = max(span, abs(bio.chan[c]))
      end
      for c, name in ipairs(sim.CHANNELS) do
        local cy, v = gy0 + 16 + c * 12, bio.chan[c - 1]
        local col = CHAN_RGB[c]
        rl.DrawText(name, x0 + 10, cy, 10, WHITE)
        rl.DrawRectangle(x0 + 160, cy + 4, 80, 1, color(60, 60, 70))
        local w = floor(abs(v) / span * 40)
        rl.DrawRectangle(v >= 0 and x0 + 200 or x0 + 200 - w, cy + 1, max(1, w), 7, color(col[1], col[2], col[3]))
      end
      gy0 = gy0 + extra
    end
    for g = 1, NG do
      local gy = gy0 + g * 13
      rl.DrawText(sim.GENES[g], x0 + 10, gy, 10, WHITE)
      rl.DrawRectangle(x0 + 95, gy + 1, 140, 8, color(40, 40, 50))
      rl.DrawRectangle(x0 + 95, gy + 1, floor(u.g[g - 1] * 140), 8, color(u.cr, u.cg, u.cb))
    end
  end
end

local QN = { "poorest", "lower", "middle", "upper", "richest" }

-- deaths are the only place a whole life can be scored, so the mobility panel is always about the dead
local function draw_mobility()
  local d = sim.deaths
  local x0, y0 = 340, rl.GetScreenHeight() - 170
  rl.DrawRectangle(x0, y0, 430, 162, PANEL)
  rl.DrawText(("%d lives ended: %d starved, %d of old age (%d founders)"):format(d.n, d.cause[1], d.cause[2], d.founders), x0 + 10, y0 + 8, 10, WHITE)
  rl.DrawText("born (row) -> best rank ever reached (column)", x0 + 10, y0 + 24, 10, DIM)
  for q = 1, 5 do
    rl.DrawText(QN[q], x0 + 66 + (q - 1) * 68, y0 + 38, 10, DIM)
  end
  for p = 1, 5 do
    local row, tot = d.mob[p], 0
    for q = 1, 5 do
      tot = tot + row[q]
    end
    local ry = y0 + 52 + (p - 1) * 20
    rl.DrawText(QN[p], x0 + 10, ry, 10, DIM)
    for q = 1, 5 do
      local f = tot > 0 and row[q] / tot or 0
      rl.DrawRectangle(x0 + 62 + (q - 1) * 68, ry - 2, 62, 16, color(30 + f * 225, 60, 120 - f * 60))
      rl.DrawText(("%.0f%%"):format(f * 100), x0 + 80 + (q - 1) * 68, ry, 10, WHITE)
    end
  end
end

local function draw_caption()
  if not (play and play.caption) then return end
  local w = rl.GetScreenWidth()
  rl.DrawRectangle(340, 12, w - 590, 30, color(0, 0, 0, 210))
  rl.DrawText(play.caption, 354, 22, 14, color(255, 235, 150))
end

local function pick(mx, my)
  -- the click may land on any copy of the world, so fold it back onto the one the units live in
  local wx, wy = (mx - cam_x) / zoom % W, (my - cam_y) / zoom % W
  local best, best_d = -1, (14 / zoom) ^ 2
  for s = 0, nlive - 1 do
    local i = live[s]
    local u = U[i]
    local d = (u.x - wx) ^ 2 + (u.y - wy) ^ 2
    if d < best_d then
      best, best_d = i, d
    end
  end
  sim.selected, sel_gen = best, best >= 0 and U[best].gen or 0
end

-- screenshot helper: --pick opens the inspector on whoever is richest at shot time
local function pick_richest()
  local best, best_w = -1, -1
  for s = 0, nlive - 1 do
    local i = live[s]
    local w = sim.worth(U[i])
    if w > best_w then
      best, best_w = i, w
    end
  end
  sim.selected, sel_gen = best, best >= 0 and U[best].gen or 0
end

local shot, frames = opt.shot, 0
while not rl.WindowShouldClose() do
  -- refreshed every frame: births, deaths and compaction all move the live set
  live, nlive = sim.live_set()
  local k = sim.knobs
  if rl.IsKeyPressed(KEY.SPACE) then paused = not paused end
  if rl.IsKeyPressed(KEY.EQUAL) then speed = min(32, speed * 2) end
  if rl.IsKeyPressed(KEY.MINUS) then speed = max(1, speed / 2) end
  if rl.IsKeyPressed(KEY.L) then show_links = not show_links end
  if rl.IsKeyPressed(KEY.F) then show_flash = not show_flash end
  if rl.IsKeyPressed(KEY.H) then show_ui = not show_ui end
  if rl.IsKeyPressed(KEY.RB) then k.mut = min(0.5, k.mut * 1.25) end
  if rl.IsKeyPressed(KEY.LB) then k.mut = max(0.001, k.mut / 1.25) end
  if rl.IsKeyPressed(KEY.T) then k.estate_tax = min(1, k.estate_tax + 0.1) end
  if rl.IsKeyPressed(KEY.G) then k.estate_tax = max(0, k.estate_tax - 0.1) end
  if rl.IsKeyPressed(KEY.C) then view = (view + 1) % #VIEWS end
  if rl.IsKeyPressed(KEY.M) then show_mob = not show_mob end
  if rl.IsKeyPressed(KEY.J) then sim.jubilee() end
  local mx, my = rl.GetMouseX(), rl.GetMouseY()
  if rl.IsKeyPressed(KEY.S) then sim.trigger_shock((mx - cam_x) / zoom % W, (my - cam_y) / zoom % W) end
  if rl.IsKeyPressed(KEY.R) then
    seed = seed + 1
    if sc then
      play = scen.begin(sc, arm, seed)
    else
      sim.init(seed)
    end
    paint_land()
    sim.selected = -1
  end

  local wheel = rl.GetMouseWheelMove()
  if wheel ~= 0 then
    local z = max(0.2, min(12, zoom * (1 + wheel * 0.1)))
    cam_x, cam_y = mx - (mx - cam_x) * z / zoom, my - (my - cam_y) * z / zoom
    zoom = z
  end
  if rl.IsMouseButtonPressed(0) then drag = 0 end
  if rl.IsMouseButtonDown(0) then
    local d = rl.GetMouseDelta()
    cam_x, cam_y, drag = cam_x + d.x, cam_y + d.y, drag + abs(d.x) + abs(d.y)
  end
  if rl.IsMouseButtonReleased(0) and drag < 4 then pick(mx, my) end

  if not paused then
    local t0 = rl.GetTime()
    for _ = 1, speed do
      sim.tick()
      if play then scen.step(play, sim.tick_count()) end
    end
    tick_ms = tick_ms * 0.9 + (rl.GetTime() - t0) * 1000 / speed * 0.1
    ticks_since_stats = ticks_since_stats + speed
    if ticks_since_stats >= 30 then
      ticks_since_stats = 0
      sim.compute_stats()
    end
  end
  local sel = sim.selected
  if sel >= 0 and (U[sel].alive ~= 1 or U[sel].gen ~= sel_gen) then sim.selected = -1 end

  if opt.pick and shot and frames + 1 >= shot then pick_richest() end

  rl.BeginDrawing()
  rl.ClearBackground(BG)
  draw_world()
  if show_ui then
    draw_ui()
    draw_caption()
    if show_mob then draw_mobility() end
  end
  frames = frames + 1
  if shot and frames >= shot then
    rl.rlDrawRenderBatchActive()
    rl.TakeScreenshot("shot.png")
    rl.EndDrawing()
    break
  end
  rl.EndDrawing()
end
rl.CloseWindow()
