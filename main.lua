local ffi = require("ffi")
local rl = require("rl")
local sim = require("sim")

local floor, min, max, log, abs, sqrt = math.floor, math.min, math.max, math.log, math.abs, math.sqrt
local RL_LINES, RL_QUADS = 1, 7
local KEY = { SPACE = 32, MINUS = 45, EQUAL = 61, F = 70, G = 71, H = 72, L = 76, R = 82, S = 83, T = 84, LB = 91, RB = 93 }
local W, CAP, NG, HN = sim.W, sim.CAP, sim.NG, sim.HN
local U, L, flashes, hist = sim.units, sim.loans, sim.flashes, sim.hist

local function color(r, g, b, a) return ffi.new("Color", r, g, b, a or 255) end
local WHITE, DIM, PANEL, BG = color(230, 230, 230), color(150, 150, 150), color(0, 0, 0, 185), color(12, 12, 16)
local FLASH_RGB = { [0] = { 255, 255, 255 }, { 80, 255, 120 }, { 255, 60, 60 }, { 255, 170, 40 }, { 80, 160, 255 } }

-- fail before the window opens: every raylib symbol must resolve, struct layouts must match the C ABI, and the sim must pass its audit
for _, name in ipairs({ "SetConfigFlags", "SetTraceLogLevel", "InitWindow", "CloseWindow", "WindowShouldClose", "GetScreenWidth",
  "GetScreenHeight", "SetTargetFPS", "GetFPS", "BeginDrawing", "EndDrawing", "ClearBackground", "TakeScreenshot", "GetTime",
  "IsKeyPressed", "IsKeyDown", "IsMouseButtonPressed", "IsMouseButtonDown", "IsMouseButtonReleased", "GetMouseX", "GetMouseY",
  "GetMouseDelta", "GetMouseWheelMove", "DrawText", "DrawRectangle", "GenImageGradientRadial", "LoadTextureFromImage",
  "UnloadImage", "SetTextureFilter", "UpdateTexture", "rlPushMatrix", "rlPopMatrix", "rlTranslatef", "rlScalef", "rlBegin",
  "rlEnd", "rlVertex2f", "rlTexCoord2f", "rlColor4ub", "rlSetTexture", "rlCheckRenderBatchLimit", "rlDrawRenderBatchActive" }) do
  assert(pcall(function() return rl[name] end), "raylib is missing symbol " .. name)
end
assert(ffi.sizeof("Color") == 4 and ffi.sizeof("Vector2") == 8 and ffi.sizeof("Texture2D") == 20, "raylib struct layout mismatch")
assert(ffi.sizeof("Image") == ffi.sizeof("void *") + 16, "raylib Image layout mismatch")
assert(#sim.GENES == NG and sim.GRID * sim.CELL == W, "sim exports inconsistent")
local opt = sim.parse_args(arg, {
  seed = "random seed (default: clock)", speed = "sim ticks per frame at start (default 2)",
  shot = "save shot.png after this many frames and exit", no_selftest = "skip the startup audit",
})
if not opt.no_selftest then sim.selftest(100) end

rl.SetTraceLogLevel(4)
rl.SetConfigFlags(4 + 64)
rl.InitWindow(1400, 900, "capitalism")
rl.SetTargetFPS(60)

local img = rl.GenImageGradientRadial(64, 64, 0.8, color(255, 255, 255), color(255, 255, 255, 0))
local dot = rl.LoadTextureFromImage(img)
rl.UnloadImage(img)
assert(dot.id > 0, "dot texture failed to upload")
rl.SetTextureFilter(dot, 1)

local land_px = ffi.new("uint8_t[?]", sim.GRID * sim.GRID * 4)
local land
local function paint_land()
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
sim.init(seed)
paint_land()

local zoom = 900 / W
local cam_x, cam_y = 340, 0
local speed, paused, show_links, show_flash, show_ui = opt.speed or 2, false, true, true, true
local sel, sel_gen, drag = -1, 0, 0
local ticks_since_stats, tick_ms = 0, 0

local function quad(x, y, r)
  rl.rlCheckRenderBatchLimit(4)
  rl.rlTexCoord2f(0, 0); rl.rlVertex2f(x - r, y - r)
  rl.rlTexCoord2f(0, 1); rl.rlVertex2f(x - r, y + r)
  rl.rlTexCoord2f(1, 1); rl.rlVertex2f(x + r, y + r)
  rl.rlTexCoord2f(1, 0); rl.rlVertex2f(x + r, y - r)
end

-- radius (not area) linear in worth relative to the median: deliberately exaggerated, area-true sizing looked uniform
local function radius(u)
  return max(1, min(60, 2.5 * sim.worth(u) / sim.stats.median_worth))
end

local function draw_world()
  rl.rlPushMatrix()
  rl.rlTranslatef(cam_x, cam_y, 0)
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
        if abs(a.x - b.x) < W / 2 and abs(a.y - b.y) < W / 2 then
          rl.rlCheckRenderBatchLimit(2)
          rl.rlColor4ub(a.cr, a.cg, a.cb, min(220, 50 + l.owed / 10))
          rl.rlVertex2f(a.x, a.y)
          rl.rlColor4ub(a.cr, a.cg, a.cb, 10)
          rl.rlVertex2f(b.x, b.y)
        end
      end
    end
    rl.rlEnd()
  end

  rl.rlSetTexture(dot.id)
  rl.rlBegin(RL_QUADS)
  for i = 0, CAP - 1 do
    local u = U[i]
    if u.alive == 1 and u.stubborn == 0 then
      local r = radius(u)
      rl.rlColor4ub(u.cr, u.cg, u.cb, r > 8 and 150 or 235)
      quad(u.x, u.y, r)
    end
  end
  rl.rlEnd()
  rl.rlSetTexture(0)
  rl.rlBegin(RL_QUADS)
  for i = 0, CAP - 1 do
    local u = U[i]
    if u.alive == 1 and u.stubborn == 1 then
      rl.rlColor4ub(u.cr, u.cg, u.cb, 235)
      quad(u.x, u.y, radius(u) * 0.7)
    end
  end
  rl.rlEnd()
  rl.rlSetTexture(dot.id)
  rl.rlBegin(RL_QUADS)
  for k = 0, sim.NFLASH - 1 do
    local f = flashes[k]
    if f.ttl > 0 then
      f.ttl = f.ttl - 1
      if show_flash then
        local c = FLASH_RGB[f.kind]
        rl.rlColor4ub(c[1], c[2], c[3], f.ttl * 6)
        quad(f.x, f.y, (f.kind == 0 and 3 or 6) + (24 - f.ttl) * 0.5)
      end
    end
  end
  if sel >= 0 then
    rl.rlColor4ub(255, 255, 255, 90)
    quad(U[sel].x, U[sel].y, radius(U[sel]) + 8)
  end
  rl.rlEnd()
  rl.rlSetTexture(0)
  rl.rlPopMatrix()
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
  y = y + 4
  for i, name in ipairs({ "population", "gini", "food price", "tool price" }) do
    rl.DrawText(name, 10, y + 8, 10, DIM)
    spark(i - 1, 90, y, 225, 26, 120 + i * 40, 220, 255 - i * 50)
    y = y + 30
  end

  line("wealth distribution (log10 bins)", DIM)
  local peak = 1
  for b = 1, 24 do peak = max(peak, s.wealth_bins[b]) end
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
  line("space pause   - = speed   S shock   R reset", DIM)
  line("L links   F flashes   H hide   drag pan   wheel zoom", DIM)
  line("green land = food, orange = ore.  squares = stubborn", DIM)

  if sel >= 0 then
    local u = U[sel]
    local x0 = rl.GetScreenWidth() - 250
    rl.DrawRectangle(x0, 0, 250, 124 + NG * 13, PANEL)
    rl.DrawRectangle(x0 + 10, 8, 230, 6, color(u.cr, u.cg, u.cb))
    local rows = {
      ("unit %d   age %d   hue %.0f"):format(sel, u.age, u.hue),
      ("worth %.0f (%.1fx median)   money %.0f"):format(sim.worth(u), sim.worth(u) / sim.stats.median_worth, u.money),
      ("lent %.0f   debt %.0f"):format(u.lent, u.debt),
      ("food %.1f   tools %.1f   capital %.1f%s"):format(u.stock[0], u.stock[1], u.capital, u.stubborn == 1 and "   STUBBORN" or ""),
      ("belief food %.2f  tools %.2f   loans out %d"):format(u.belief[0], u.belief[1], u.nloans),
    }
    for i, str in ipairs(rows) do rl.DrawText(str, x0 + 10, 8 + i * 14, 10, WHITE) end
    for g = 1, NG do
      local gy = 94 + g * 13
      rl.DrawText(sim.GENES[g], x0 + 10, gy, 10, WHITE)
      rl.DrawRectangle(x0 + 95, gy + 1, 140, 8, color(40, 40, 50))
      rl.DrawRectangle(x0 + 95, gy + 1, floor(u.g[g - 1] * 140), 8, color(u.cr, u.cg, u.cb))
    end
  end
end

local function pick(mx, my)
  local wx, wy = (mx - cam_x) / zoom, (my - cam_y) / zoom
  local best, best_d = -1, (14 / zoom) ^ 2
  for i = 0, CAP - 1 do
    local u = U[i]
    if u.alive == 1 then
      local d = (u.x - wx) ^ 2 + (u.y - wy) ^ 2
      if d < best_d then best, best_d = i, d end
    end
  end
  sel, sel_gen = best, best >= 0 and U[best].gen or 0
end

local shot, frames = opt.shot, 0
while not rl.WindowShouldClose() do
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
  local mx, my = rl.GetMouseX(), rl.GetMouseY()
  if rl.IsKeyPressed(KEY.S) then sim.trigger_shock((mx - cam_x) / zoom % W, (my - cam_y) / zoom % W) end
  if rl.IsKeyPressed(KEY.R) then
    seed = seed + 1
    sim.init(seed)
    paint_land()
    sel = -1
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
    for _ = 1, speed do sim.tick() end
    tick_ms = tick_ms * 0.9 + (rl.GetTime() - t0) * 1000 / speed * 0.1
    ticks_since_stats = ticks_since_stats + speed
    if ticks_since_stats >= 30 then
      ticks_since_stats = 0
      sim.compute_stats()
    end
  end
  if sel >= 0 and (U[sel].alive ~= 1 or U[sel].gen ~= sel_gen) then sel = -1 end

  rl.BeginDrawing()
  rl.ClearBackground(BG)
  draw_world()
  if show_ui then draw_ui() end
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
