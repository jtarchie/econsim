local ffi = require("ffi")
local bit = require("bit")
local band = bit.band
-- branchy per-unit loop blows default trace limits and falls back to the interpreter
require("jit.opt").start("maxtrace=20000", "maxrecord=40000", "maxside=4000", "maxsnap=4000", "sizemcode=1024", "maxmcode=131072")
local floor, ceil, sqrt, atan2, abs = math.floor, math.ceil, math.sqrt, math.atan2, math.abs
local random, min, max, log = math.random, math.min, math.max, math.log

local CAP, GRID, CELL, NG = 16384, 128, 16, 20
local MASK, GMASK, NC = CAP - 1, GRID - 1, GRID * GRID
local W = GRID * CELL
local HALF, R2 = W / 2, CELL * CELL
local MAXLOANS, TERM = CAP * 4, 600
local NFLASH, HN = 4096, 240

local PROD, RESERVE, GREED, HERD, THRIFT, INVEST, RISK, TRUST, SPEED = 0, 1, 2, 3, 4, 5, 6, 7, 8
local SEEK_RICH, SEEK_KIN, MIGRATE, REPRO, ENDOW, INHERIT, BORROW, BUILD = 9, 10, 11, 12, 13, 14, 15, 16
local SPECULATE, PEDDLE, CRAFT = 17, 18, 19
local FOOD, TOOLS = 0, 1

ffi.cdef([[
typedef struct {
  float x, y, vx, vy;
  double money, debt, lent;
  float stock[2], belief[2], ask[2], surplus[2], capital, hue;
  uint32_t age, gen, heir_gen;
  int32_t default_tick, cell, heir;
  uint8_t nloans, alive, sold[2], cr, cg, cb, stubborn;
  float g[20];
} unit_t;
typedef struct {
  int32_t lender, borrower, expiry;
  uint32_t lgen, bgen;
  double owed, installment;
  uint8_t active;
} loan_t;
typedef struct { float x, y; uint8_t kind, ttl; } flash_t;
]])

local M = {
  CAP = CAP,
  W = W,
  GRID = GRID,
  CELL = CELL,
  NG = NG,
  HN = HN,
  NFLASH = NFLASH,
  GENES = {
    "productivity",
    "reserve",
    "greed",
    "herd",
    "thrift",
    "invest",
    "risk",
    "trust",
    "speed",
    "seek_rich",
    "seek_kin",
    "migrate",
    "repro_thresh",
    "endowment",
    "inherit",
    "borrow",
    "build",
    "speculate",
    "peddle",
    "craft",
  },
  FLASH = { TRADE = 0, BIRTH = 1, DEATH = 2, DEFAULT = 3, LOAN = 4 },
  knobs = { pop = 2000, money = 1500, artisans = 0.15, yield = 2.6, toolrate = 0.5, mut = 0.05, estate_tax = 0.0, shock_every = 600, stubborn_founders = 0.2, stubborn_birth = 0.02 },
  KNOB_HELP = {
    pop = "founding population (1..16384)",
    money = "money per founder; total supply = pop x money, fixed forever",
    artisans = "fraction of founders who start as tool-makers on ore land",
    yield = "food per unit labour on perfect land",
    toolrate = "tools per unit labour on perfect ore",
    mut = "per-gene mutation sigma at birth",
    estate_tax = "share of every estate paid to the commons dividend",
    shock_every = "mean ticks between crop failures, 0 = never",
    stubborn_founders = "fraction of founders who never adapt",
    stubborn_birth = "chance an adaptive unit's child is stubborn",
  },
  shock = { x = 0, y = 0, r = 0, ttl = 0 },
  stats = {},
}

local U = ffi.new("unit_t[?]", CAP)
local L = ffi.new("loan_t[?]", MAXLOANS)
local flashes = ffi.new("flash_t[?]", NFLASH)
local free_units, free_loans = ffi.new("int32_t[?]", CAP), ffi.new("int32_t[?]", MAXLOANS)
local dying = ffi.new("int32_t[?]", CAP)
local cell_start, cell_cursor = ffi.new("int32_t[?]", NC + 1), ffi.new("int32_t[?]", NC + 1)
local cell_items = ffi.new("int32_t[?]", CAP)
local proj = ffi.new("float[?]", NG * 2)
local hist = ffi.new("float[?]", (4 + NG) * HN)
local opp, res = ffi.new("float[?]", NC * 2), ffi.new("float[?]", NC * 2)
local sup, dem = ffi.new("float[?]", NC * 2), ffi.new("float[?]", NC * 2)
local sup_raw, dem_raw = ffi.new("float[?]", NC * 2), ffi.new("float[?]", NC * 2)
local fert, ore = res, res + NC
M.units, M.loans, M.flashes, M.fert, M.ore, M.hist = U, L, flashes, fert, ore, hist

local nfree, nfree_loans, loan_hi, ndying, flash_head = 0, 0, 0, 0, 0
local tick, commons, supply = 0, 0, 0
local c_births, c_starved, c_aged, c_defaults, c_trades, c_volume, c_loans, c_spec, c_tool_vol = 0, 0, 0, 0, 0, 0, 0, 0, 0

local function flash(x, y, kind)
  local f = flashes[flash_head]
  f.x, f.y, f.kind, f.ttl = x, y, kind, 24
  flash_head = band(flash_head + 1, NFLASH - 1)
end

local function paint(u)
  local a, b = 0, 0
  for k = 0, NG - 1 do
    local d = u.g[k] - 0.5
    a, b = a + d * proj[k * 2], b + d * proj[k * 2 + 1]
  end
  local h = (atan2(b, a) / math.pi * 180 + 360) % 360
  local s, v = min(1, 0.35 + sqrt(a * a + b * b) * 1.2), 1
  local c = v * s
  local x = c * (1 - abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, bl
  if h < 60 then
    r, g, bl = c, x, 0
  elseif h < 120 then
    r, g, bl = x, c, 0
  elseif h < 180 then
    r, g, bl = 0, c, x
  elseif h < 240 then
    r, g, bl = 0, x, c
  elseif h < 300 then
    r, g, bl = x, 0, c
  else
    r, g, bl = c, 0, x
  end
  u.hue, u.cr, u.cg, u.cb = h, (r + m) * 255, (g + m) * 255, (bl + m) * 255
end

local function gauss() return sqrt(-2 * log(1 - random())) * math.cos(6.283185307 * random()) end

local function wrap(v)
  v = v - W * floor(v / W)
  return v < W - 0.001 and v or 0
end

local function spawn(x, y)
  nfree = nfree - 1
  local i = free_units[nfree]
  local u = U[i]
  local gen = u.gen
  ffi.fill(u, ffi.sizeof("unit_t"))
  u.gen, u.x, u.y, u.alive, u.heir, u.default_tick = gen, x, y, 1, -1, -1000000
  u.belief[FOOD], u.belief[TOOLS] = 10, 20
  return i, u
end

local reset_scratch

function M.init(seed)
  -- fixed seed: hue projection must match across runs so colors are comparable
  math.randomseed(1234)
  for k = 0, NG * 2 - 1 do
    proj[k] = gauss()
  end
  math.randomseed(seed or os.time())

  ffi.fill(U, ffi.sizeof(U))
  ffi.fill(L, ffi.sizeof(L))
  ffi.fill(flashes, ffi.sizeof(flashes))
  ffi.fill(hist, ffi.sizeof(hist))
  tick, commons, loan_hi, ndying = 0, 0, 0, 0
  ffi.fill(sup, ffi.sizeof(sup))
  ffi.fill(dem, ffi.sizeof(dem))
  reset_scratch()
  flash_head, M.shock.x, M.shock.y, M.shock.r = 0, 0, 0, 0
  c_births, c_starved, c_aged, c_defaults, c_trades, c_volume, c_loans, c_spec, c_tool_vol = 0, 0, 0, 0, 0, 0, 0, 0, 0
  nfree, nfree_loans = CAP, MAXLOANS
  for i = 0, CAP - 1 do
    free_units[i] = CAP - 1 - i
  end
  for i = 0, MAXLOANS - 1 do
    free_loans[i] = MAXLOANS - 1 - i
  end
  M.shock.ttl = 0

  local w = 6.283185307 / GRID
  for k = 0, NC, NC do
    local ph = {}
    for n = 1, 8 do
      ph[n] = random() * 6.283185307
    end
    for cy = 0, GRID - 1 do
      for cx = 0, GRID - 1 do
        local f = math.sin(cx * w + ph[1]) * math.sin(cy * w * 2 + ph[2])
          + math.sin(cx * w * 3 + ph[3]) * math.sin(cy * w + ph[4]) * 0.7
          + math.sin(cx * w * 5 + ph[5]) * math.sin(cy * w * 4 + ph[6]) * 0.4
          + math.sin((cx + cy) * w * 2 + ph[7]) * 0.5
        res[k + cy * GRID + cx] = max(0.05, min(1, 0.5 + f * 0.3))
      end
    end
  end
  for c = 0, NC * 2 - 1 do
    opp[c] = res[c]
  end

  M.check_knobs()
  local kn = M.knobs
  for _ = 1, kn.pop do
    local x, y
    local field = random() < kn.artisans and ore or fert
    repeat
      x, y = random() * W, random() * W
    until field[floor(y / CELL) * GRID + floor(x / CELL)] > 0.55
    local _, u = spawn(x, y)
    for k = 0, NG - 1 do
      u.g[k] = random()
    end
    -- uniform-random founders are ~95% unviable at this yield; bias toward farmers to skip the long bottleneck
    u.g[PROD], u.g[CRAFT] = 0.6 + 0.4 * random(), field == ore and 1 - 0.15 * random() or 0.15 * random()
    u.money, u.stock[FOOD], u.capital, u.age = kn.money, 300, 10, random(0, 2500)
    u.stubborn = random() < M.knobs.stubborn_founders and 1 or 0
    paint(u)
  end
  supply = kn.pop * kn.money
  M.stats = { hist_n = 0, hist_head = 0, wealth_bins = {} }
  M.compute_stats()
end

local function build_grid()
  for c = 0, NC do
    cell_start[c] = 0
  end
  for i = 0, MASK do
    local u = U[i]
    if u.alive == 1 then
      local c = band(floor(u.y / CELL), GMASK) * GRID + band(floor(u.x / CELL), GMASK)
      u.cell = c
      cell_start[c + 1] = cell_start[c + 1] + 1
    end
  end
  for c = 1, NC do
    cell_start[c] = cell_start[c] + cell_start[c - 1]
  end
  for c = 0, NC do
    cell_cursor[c] = cell_start[c]
  end
  for i = 0, MASK do
    local u = U[i]
    if u.alive == 1 then
      cell_items[cell_cursor[u.cell]] = i
      cell_cursor[u.cell] = cell_cursor[u.cell] + 1
    end
  end
end

local function kill(i, u)
  u.alive = 2
  dying[ndying] = i
  ndying = ndying + 1
  flash(u.x, u.y, 2)
end

ffi.cdef([[
typedef struct { double rich_m; float bel_sum[2], best_ask[2], rdx, rdy, kdx, kdy, px, py; int32_t nn, best[2], cand; } scan_t;
]])
local MAXPAIRS = CAP * 48
local SC = ffi.new("scan_t[?]", CAP)
local pair_i, pair_j = ffi.new("int32_t[?]", MAXPAIRS), ffi.new("int32_t[?]", MAXPAIRS)
local off_x = ffi.new("int32_t[9]", -1, 0, 1, -1, 0, 1, -1, 0, 1)
local off_y = ffi.new("int32_t[9]", -1, -1, -1, 0, 0, 0, 1, 1, 1)
local sc_ax, sc_ay, sc_scale = ffi.new("float[?]", CAP), ffi.new("float[?]", CAP), ffi.new("float[?]", CAP * 2)
local sc_net = ffi.new("float[?]", CAP)
local CARRY, MINQ = ffi.new("float[2]", 300, 40), ffi.new("float[2]", 0.5, 0.05)
local PRIMES = { 16411, 17389, 19993, 24733, 31337 }
local unmet = ffi.new("double[8]")

-- scratch carries last tick's scan into produce(); stale values from a previous run made reseeded runs diverge
function reset_scratch()
  ffi.fill(SC, ffi.sizeof(SC))
  ffi.fill(sc_ax, ffi.sizeof(sc_ax))
  ffi.fill(sc_ay, ffi.sizeof(sc_ay))
  ffi.fill(sc_scale, ffi.sizeof(sc_scale))
  ffi.fill(sc_net, ffi.sizeof(sc_net))
  ffi.fill(cell_start, ffi.sizeof(cell_start))
end

local function upkeep_of(g) return 0.6 + 0.8 * g[PROD] end

local function phase_produce(pop)
  local sh = M.shock
  local sx, sy, sr2 = sh.x, sh.y, sh.ttl > 0 and sh.r * sh.r or -1
  local YIELD, TOOLRATE = M.knobs.yield, M.knobs.toolrate
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local u = U[i]
    local g, cell = u.g, u.cell
    local crowd = cell_start[cell + 1] - cell_start[cell]
    local dx, dy = abs(u.x - sx), abs(u.y - sy)
    dx, dy = min(dx, W - dx), min(dy, W - dy)
    local f = fert[cell]
    if dx * dx + dy * dy < sr2 then f = f * 0.15 end

    -- movement is paid per distance actually travelled: a standing cost made the speed gene evolve to zero
    local upkeep, nn = upkeep_of(g) + 0.03 * (u.vx * u.vx + u.vy * u.vy), SC[i].nn
    local labor = g[PROD] * (1 + 0.15 * sqrt(u.capital))
    -- squared labour shares: splitting effort is wasteful, so specialising + trading beats self-sufficiency
    local farm, craft = (1 - g[CRAFT]) * (1 - g[CRAFT]), g[CRAFT] * g[CRAFT]
    local net = YIELD * labor * farm * f / (0.5 + 0.5 * crowd) - upkeep
    sc_net[i] = net
    u.stock[FOOD] = (u.stock[FOOD] + net) * 0.998
    u.stock[TOOLS] = u.stock[TOOLS] + TOOLRATE * labor * craft * ore[cell] / (0.5 + 0.5 * crowd)
    u.capital = u.capital * 0.997
    if u.stock[FOOD] < 0 then
      c_starved = c_starved + 1
      kill(i, u)
    else
      -- would-be parents shop for the child's food stake, else landless artisans could never reproduce
      local broody = u.age > 300 and u.money - u.debt > 300 + 3000 * g[REPRO]
      local reserve, target = upkeep * (10 + 90 * g[RESERVE]) + (broody and 60 or 0), 60 * g[BUILD]
      local install = max(0, min(u.stock[TOOLS], target - u.capital))
      u.stock[TOOLS], u.capital = u.stock[TOOLS] - install, u.capital + install
      local short = target - u.capital
      u.surplus[FOOD] = u.stock[FOOD] - reserve
      u.surplus[TOOLS] = short > MINQ[TOOLS] and -short or u.stock[TOOLS]
      sc_scale[i * 2], sc_scale[i * 2 + 1] = reserve, target
      for k = 0, 1 do
        if u.surplus[k] > 0 and u.sold[k] == 0 and nn > 0 and u.stubborn == 0 then u.belief[k] = max(0.05, u.belief[k] * 0.99) end
        u.sold[k] = 0
        u.ask[k] = u.belief[k] * (0.8 + 0.6 * g[GREED])
      end
    end
  end
end

-- 16px vision can't find a market: supply/demand per cell, max-propagated with decay, gives a gradient to the nearest one
local function update_fields(pop)
  ffi.fill(sup_raw, ffi.sizeof(sup_raw))
  ffi.fill(dem_raw, ffi.sizeof(dem_raw))
  for s = 0, pop - 1 do
    local u = U[cell_items[s]]
    local c, solvent = u.cell, min(1, u.money)
    sup_raw[c], sup_raw[NC + c] = sup_raw[c] + max(0, u.surplus[0]), sup_raw[NC + c] + max(0, u.surplus[1])
    dem_raw[c], dem_raw[NC + c] = dem_raw[c] + max(0, -u.surplus[0]) * solvent, dem_raw[NC + c] + max(0, -u.surplus[1]) * solvent
  end
  for c = 0, NC - 1 do
    local n = cell_start[c + 1] - cell_start[c]
    local cx, row = band(c, GMASK), c - band(c, GMASK)
    local l, r = row + band(cx - 1, GMASK), row + band(cx + 1, GMASK)
    local up, dn = band(c - GRID, NC - 1), band(c + GRID, NC - 1)
    for k = 0, NC, NC do
      opp[k + c] = max(res[k + c] / (1 + 0.5 * n), max(opp[k + l], opp[k + r], opp[k + up], opp[k + dn]) * 0.99)
      sup[k + c] = max(sup_raw[k + c], max(sup[k + l], sup[k + r], sup[k + up], sup[k + dn]) * 0.95)
      dem[k + c] = max(dem_raw[k + c], max(dem[k + l], dem[k + r], dem[k + up], dem[k + dn]) * 0.95)
    end
  end
end

local function build_pairs(pop)
  local P = 0
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local cell = U[i].cell
    local cx, cy = band(cell, GMASK), floor(cell / GRID)
    for n = 0, 8 do
      local c = band(cy + off_y[n], GMASK) * GRID + band(cx + off_x[n], GMASK)
      local t0 = cell_start[c]
      for t = t0, min(cell_start[c + 1], t0 + MAXPAIRS - P) - 1 do
        pair_i[P], pair_j[P] = i, cell_items[t]
        P = P + 1
      end
    end
  end
  return P
end

local function phase_scan(pop)
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local a = SC[i]
    a.nn, a.cand, a.rich_m = 0, -1, U[i].money
    a.best[0], a.best[1], a.best_ask[0], a.best_ask[1], a.bel_sum[0], a.bel_sum[1] = -1, -1, 1e30, 1e30, 0, 0
    a.rdx, a.rdy, a.kdx, a.kdy, a.px, a.py = 0, 0, 0, 0, 0, 0
  end

  -- flat pair loop: nesting the branchy body inside the 3x3 cell loops explodes LuaJIT side traces
  for p = 0, build_pairs(pop) - 1 do
    local i, j = pair_i[p], pair_j[p]
    local u, o = U[i], U[j]
    local dx, dy = o.x - u.x, o.y - u.y
    dx, dy = dx - W * floor(dx / W + 0.5), dy - W * floor(dy / W + 0.5)
    local d2 = dx * dx + dy * dy
    if d2 < R2 and j ~= i and o.alive == 1 then
      local a = SC[i]
      local nn = a.nn + 1
      a.nn, a.bel_sum[0], a.bel_sum[1] = nn, a.bel_sum[0] + o.belief[0], a.bel_sum[1] + o.belief[1]
      -- jittered ask: without it every buyer mobs the single cheapest seller and most orders fail
      local jit = 1 + 0.3 * random()
      if o.surplus[0] > 0.5 and o.ask[0] * jit < a.best_ask[0] then
        a.best[0], a.best_ask[0] = j, o.ask[0] * jit
      end
      if o.surplus[1] > 0.05 and o.ask[1] * jit < a.best_ask[1] then
        a.best[1], a.best_ask[1] = j, o.ask[1] * jit
      end
      if random() * nn < 1 then a.cand = j end
      if o.money > a.rich_m then
        a.rich_m, a.rdx, a.rdy = o.money, dx, dy
      end
      local kw = 1 - (180 - abs(abs(o.hue - u.hue) - 180)) / 90
      local pw = max(0, 1 - d2 / 64)
      a.kdx, a.kdy, a.px, a.py = a.kdx + dx * kw, a.kdy + dy * kw, a.px - dx * pw, a.py - dy * pw
    end
  end

  for s = 0, pop - 1 do
    local i = cell_items[s]
    local u, a = U[i], SC[i]
    local g, cell = u.g, u.cell
    local cx, cy = band(cell, GMASK), floor(cell / GRID)
    -- stubborn units never revise prices or go looking for something better; only separation moves them
    local open = 1 - u.stubborn
    local hw = g[HERD] * 0.1 * min(1, a.nn) * open
    u.belief[0] = u.belief[0] + (a.bel_sum[0] / max(1, a.nn) - u.belief[0]) * hw
    u.belief[1] = u.belief[1] + (a.bel_sum[1] / max(1, a.nn) - u.belief[1]) * hw
    local row = cell - cx
    local l, r = row + band(cx - 1, GMASK), row + band(cx + 1, GMASK)
    local up, dn = band(cell - GRID, NC - 1), band(cell + GRID, NC - 1)
    local wr, wk = (2 * g[SEEK_RICH] - 1) * 0.03, (2 * g[SEEK_KIN] - 1) * 0.01
    -- reasons to move: need walks to supply, cargo walks to demand, anyone drifts to better yield per head
    -- only real starvation risk uproots a unit: under 60 ticks of food and not feeding itself. 'Below reserve' sent every farmer to market
    local h01 = sc_net[i] < 0 and max(0, min(1, 1 + u.stock[0] / (sc_net[i] * 60))) or 0
    local hunger = h01 * 120
    local lack = max(0, min(1, -u.surplus[1] / (sc_scale[i * 2 + 1] + 0.01))) * 6 * g[PEDDLE] * (1 - h01)
    local v0, v1 = max(0, u.surplus[0]) * u.belief[0], max(0, u.surplus[1]) * u.belief[1]
    local k = v1 > v0 and NC or 0
    local wd = ((u.surplus[0] > 100 or u.surplus[1] > 5) and g[PEDDLE] * 100 or 0) / (dem[k + cell] + 0.01)
    local w0, w1 = hunger / (sup[cell] + 0.01), lack / (sup[NC + cell] + 0.01)
    -- a hungry unit drops the pull of its workplace, else it hovers between mine and market until it starves
    -- compare a newcomer's yield elsewhere with mine here (crowd minus myself), else every empty neighbour cell looks better forever
    local ko = g[CRAFT] > 0.5 and NC or 0
    local here = res[ko + cell] / (0.5 + 0.5 * (cell_start[cell + 1] - cell_start[cell]))
    local gain = max(0, min(1, max(opp[ko + l], opp[ko + r], opp[ko + up], opp[ko + dn]) / (here + 0.01) - 1.15))
    local settle = g[MIGRATE] * 200 * gain * (1 - h01) / (opp[ko + cell] + 0.01)
    sc_ax[i] = open * (a.rdx * wr + a.kdx * wk + (random() - 0.5) * 0.3 + (dem[k + r] - dem[k + l]) * wd + (sup[r] - sup[l]) * w0 + (sup[NC + r] - sup[NC + l]) * w1 + (opp[ko + r] - opp[ko + l]) * settle)
    sc_ay[i] = open * (a.rdy * wr + a.kdy * wk + (random() - 0.5) * 0.3 + (dem[k + dn] - dem[k + up]) * wd + (sup[dn] - sup[up]) * w0 + (sup[NC + dn] - sup[NC + up]) * w1 + (opp[ko + dn] - opp[ko + up]) * settle)
  end
end

local function phase_trade(pop, start, stride, k)
  local urge_gene = k == FOOD and THRIFT or BUILD
  for n = 0, pop - 1 do
    local i = cell_items[(start + n * stride) % pop]
    local u = U[i]
    if u.alive == 1 then
      local g, best, want = u.g, SC[i].best[k], u.surplus[k] < 0
      local need, budget, wtp
      if want then
        -- tool spending is a gene-set share of cash: a food-price-scaled reserve starved the tool market whenever food got dear
        need, budget = -u.surplus[k], k == FOOD and u.money or floor(u.money * (0.1 + 0.4 * g[BUILD]))
        -- nobody bids more per unit than would exhaust their cash filling the need: keeps prices tied to the money supply
        wtp = min(budget / max(1, need), u.belief[k] * (0.5 + 3 * g[urge_gene] * need / sc_scale[i * 2 + k]))
      else
        need, budget, wtp = CARRY[k] * g[SPECULATE] - u.surplus[k], floor(u.money * 0.25 * g[SPECULATE]), u.belief[k] * g[SPECULATE] * 0.9
      end
      local s = U[max(0, best)]
      local ask = s.ask[k]
      if best >= 0 and s.alive == 1 and s.surplus[k] > MINQ[k] and need > MINQ[k] and budget >= 1 and ask <= wtp then
        local qty = min(need, s.surplus[k], budget / ask)
        local cost = min(budget, max(1, ceil(qty * ask)))
        s.belief[k] = s.belief[k] * (1.01 - 0.01 * s.stubborn)
        s.stock[k], s.surplus[k], s.money, s.sold[k] = s.stock[k] - qty, s.surplus[k] - qty, s.money + cost, 1
        u.stock[k], u.surplus[k], u.money = u.stock[k] + qty, u.surplus[k] + qty, u.money - cost
        c_trades, c_volume = c_trades + 1, c_volume + cost
        c_tool_vol = c_tool_vol + cost * k
        if want then
          u.belief[k] = u.belief[k] + (ask - u.belief[k]) * 0.3 * (1 - u.stubborn)
        else
          -- speculative buys leave belief alone: arbitrage needs a price memory from elsewhere
          c_spec = c_spec + 1
        end
        if band(c_trades, 15) == 0 then flash(u.x, u.y, 0) end
      elseif want then
        -- why wanting buyers go unserved, per good: 0 no seller in range, 1 seller sold out, 2 no cash, 3 ask above bid
        local why = best < 0 and 0 or (s.alive ~= 1 or s.surplus[k] <= MINQ[k]) and 1 or budget < 1 and 2 or 3
        unmet[k * 4 + why] = unmet[k * 4 + why] + 1
      end
      if want and u.stubborn == 0 and not (best >= 0 and s.alive == 1 and s.surplus[k] > MINQ[k] and need > MINQ[k] and budget >= 1 and ask <= wtp) then
        -- a bid can't exceed what the buyer holds: anchors prices to the money supply
        u.belief[k] = min(max(0.05, budget / max(1, need)), u.belief[k] * 1.01)
      end
    end
  end
end

local function phase_lend(pop, start, stride)
  for k = 0, pop - 1 do
    local i = cell_items[(start + k * stride) % pop]
    local u = U[i]
    local g, cand = u.g, SC[i].cand
    if u.alive == 1 and cand >= 0 and u.nloans < 4 and nfree_loans > 0 and random() < g[INVEST] * 0.05 then
      local spare = u.money - u.belief[FOOD] * upkeep_of(g) * (20 + 200 * g[RESERVE])
      local amount = floor(spare * (0.1 + 0.4 * g[INVEST]))
      local o = U[cand]
      local rate = 0.05 + 0.5 * g[GREED]
      if amount >= 50 and o.alive == 1 and o.debt / (o.money + 1) < 0.2 + 3 * g[RISK] and tick - o.default_tick > 4000 * (1 - g[RISK]) and rate <= 0.05 + 0.6 * o.g[BORROW] and o.debt < 5000 * o.g[BORROW] then
        nfree_loans = nfree_loans - 1
        local li = free_loans[nfree_loans]
        loan_hi = max(loan_hi, li + 1)
        local l = L[li]
        local owed = ceil(amount * (1 + rate))
        l.lender, l.lgen, l.borrower, l.bgen = i, u.gen, cand, o.gen
        l.owed, l.installment, l.expiry, l.active = owed, ceil(owed / TERM), tick + TERM * 2, 1
        u.money, u.lent, u.nloans = u.money - amount, u.lent + owed, u.nloans + 1
        o.money, o.debt = o.money + amount, o.debt + owed
        c_loans = c_loans + 1
        flash(o.x, o.y, 4)
      end
    end
  end
end

local function phase_move(pop)
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local u = U[i]
    if u.alive == 1 then
      local vx, vy = u.vx * 0.9 + sc_ax[i] * 0.1, u.vy * 0.9 + sc_ay[i] * 0.1
      local k = min(1, (1 + 3 * u.g[SPEED]) / (sqrt(vx * vx + vy * vy) + 1e-6))
      vx, vy = vx * k, vy * k
      u.vx, u.vy = vx, vy
      -- separation bypasses the speed gene: sedentary units still can't stack, which bounds pair count
      local x, y = u.x + vx + max(-1, min(1, SC[i].px * 0.15)), u.y + vy + max(-1, min(1, SC[i].py * 0.15))
      u.x, u.y = x - W * floor(x / W), y - W * floor(y / W)
      -- W minus a hair rounds up to W in float32 storage
      if u.x >= W then u.x = 0 end
      if u.y >= W then u.y = 0 end
      u.age = u.age + 1
      if u.age > 3000 and random() < 0.002 then
        c_aged = c_aged + 1
        kill(i, u)
      end
    end
  end
end

local function phase_birth(pop)
  local mut = M.knobs.mut
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local u = U[i]
    local g, cell = u.g, u.cell
    if u.alive == 1 and nfree > 0 and u.age > 300 and u.surplus[FOOD] >= 0 and u.stock[FOOD] >= 60 + upkeep_of(g) * 10 and SC[i].nn < 8 and u.money - u.debt > 300 + 3000 * g[REPRO] and random() < 0.02 then
      local frac = 0.1 + 0.4 * g[ENDOW]
      -- children set out for better land: greedy climb of the opportunity field, since walking there on a 30-tick food buffer is a death march
      local ko, at = g[CRAFT] > 0.5 and NC or 0, cell
      for _ = 1, floor(g[MIGRATE] * 16) * (1 - u.stubborn) do
        local cx, row = band(at, GMASK), at - band(at, GMASK)
        local l, r = row + band(cx - 1, GMASK), row + band(cx + 1, GMASK)
        local up, dn = band(at - GRID, NC - 1), band(at + GRID, NC - 1)
        local nxt = at
        if opp[ko + l] > opp[ko + nxt] then nxt = l end
        if opp[ko + r] > opp[ko + nxt] then nxt = r end
        if opp[ko + up] > opp[ko + nxt] then nxt = up end
        if opp[ko + dn] > opp[ko + nxt] then nxt = dn end
        at = nxt
      end
      local bx, by = at == cell and u.x or (band(at, GMASK) + 0.5) * CELL, at == cell and u.y or (floor(at / GRID) + 0.5) * CELL
      local ci, c = spawn(wrap(bx + random() * 48 - 24), wrap(by + random() * 48 - 24))
      if u.stubborn == 1 then
        ffi.copy(c.g, g, ffi.sizeof(c.g))
        c.stubborn = 1
      else
        for k = 0, NG - 1 do
          c.g[k] = max(0, min(1, g[k] + gauss() * mut))
        end
        -- career change: squared labour shares leave a fitness valley at craft~0.5 that small mutations can't cross
        if random() < 0.03 then c.g[CRAFT] = 1 - c.g[CRAFT] end
        c.stubborn = random() < M.knobs.stubborn_birth and 1 or 0
      end
      c.money, c.capital, c.cell = floor(u.money * frac), u.capital * frac, at
      u.money, u.capital = u.money - c.money, u.capital - c.capital
      -- fixed food stake paid from surplus: births limited by food, not by infants starving
      c.stock[FOOD], c.stock[TOOLS], c.belief[FOOD], c.belief[TOOLS] = 60, u.stock[TOOLS] * frac, u.belief[FOOD], u.belief[TOOLS]
      u.stock[FOOD], u.stock[TOOLS] = u.stock[FOOD] - 60, u.stock[TOOLS] - c.stock[TOOLS]
      u.surplus[FOOD], u.surplus[TOOLS] = u.surplus[FOOD] - 60, min(u.surplus[TOOLS], u.stock[TOOLS])
      u.heir, u.heir_gen = ci, c.gen
      paint(c)
      c_births = c_births + 1
      flash(c.x, c.y, 1)
    end
  end
end

local function close_loan(li, l, le)
  l.active = 0
  le.lent, le.nloans = le.lent - l.owed, le.nloans - 1
  free_loans[nfree_loans] = li
  nfree_loans = nfree_loans + 1
end

local function step_loans()
  for li = 0, loan_hi - 1 do
    local l = L[li]
    if l.active == 1 then
      local le, b = U[l.lender], U[l.borrower]
      if le.alive == 2 then
        local h = le.heir
        if h >= 0 and h ~= l.borrower and U[h].alive == 1 and U[h].gen == le.heir_gen then
          le.lent, le.nloans = le.lent - l.owed, le.nloans - 1
          le = U[h]
          l.lender, l.lgen = h, le.gen
          le.lent, le.nloans = le.lent + l.owed, le.nloans + 1
        else
          b.debt = b.debt - l.owed
          close_loan(li, l, le)
        end
      end
      if l.active == 1 then
        local pay = 0
        if b.alive == 2 then
          pay = min(l.owed, b.money)
        elseif random() < 0.2 + 0.8 * b.g[TRUST] then
          pay = min(l.installment, l.owed, b.money)
        end
        b.money, le.money = b.money - pay, le.money + pay
        b.debt, le.lent, l.owed = b.debt - pay, le.lent - pay, l.owed - pay
        if l.owed <= 0 then
          close_loan(li, l, le)
        elseif b.alive == 2 or tick > l.expiry then
          b.debt, b.default_tick = b.debt - l.owed, tick
          c_defaults = c_defaults + 1
          flash(le.x, le.y, 3)
          close_loan(li, l, le)
        end
      end
    end
  end
end

local heirs = ffi.new("int32_t[?]", CAP)
local function bury()
  for k = 0, ndying - 1 do
    local i = dying[k]
    local u = U[i]
    local estate = u.money
    local tax = floor(estate * M.knobs.estate_tax)
    commons, estate = commons + tax, estate - tax
    local h = u.heir
    if h >= 0 and U[h].alive == 1 and U[h].gen == u.heir_gen then
      local part = floor(estate * u.g[INHERIT])
      U[h].money, estate = U[h].money + part, estate - part
    end
    local cx, cy, nn = band(u.cell, GMASK), floor(u.cell / GRID), 0
    for n = 0, 8 do
      local c = band(cy + off_y[n], GMASK) * GRID + band(cx + off_x[n], GMASK)
      for t = cell_start[c], cell_start[c + 1] - 1 do
        heirs[nn] = cell_items[t]
        if U[cell_items[t]].alive == 1 then nn = nn + 1 end
      end
    end
    local share = floor(estate / max(1, nn))
    for t = 0, nn - 1 do
      U[heirs[t]].money = U[heirs[t]].money + share
    end
    estate = estate - share * nn
    commons = commons + estate
    u.money, u.alive, u.gen = 0, 0, u.gen + 1
    free_units[nfree] = i
    nfree = nfree + 1
  end
  ndying = 0
end

function M.tick()
  tick = tick + 1
  build_grid()

  local sh = M.shock
  if sh.ttl > 0 then
    sh.ttl = sh.ttl - 1
  elseif M.knobs.shock_every > 0 and random() < 1 / M.knobs.shock_every then
    M.trigger_shock()
  end

  local pop = cell_start[NC]
  local dbg = M.debug
  if dbg then M.check_grid() end
  if pop > 0 then
    phase_produce(pop)
    phase_scan(pop)
    if dbg then M.check_scan(pop) end
    update_fields(pop)
    if dbg then M.check_fields() end
    local before = dbg and M.totals()
    phase_trade(pop, random(0, pop - 1), PRIMES[random(#PRIMES)], FOOD)
    phase_trade(pop, random(0, pop - 1), PRIMES[random(#PRIMES)], TOOLS)
    if dbg then M.check_conserved("trade", before, M.totals(), true) end
    before = dbg and M.totals()
    phase_lend(pop, random(0, pop - 1), PRIMES[random(#PRIMES)])
    if dbg then M.check_conserved("lend", before, M.totals(), true) end
    phase_move(pop)
    before = dbg and M.totals()
    phase_birth(pop)
    if dbg then M.check_conserved("birth", before, M.totals(), true) end
  end
  local before = dbg and M.totals()
  step_loans()
  if dbg then M.check_conserved("loans", before, M.totals(), false) end
  bury()
  if dbg then M.check_conserved("bury", before, M.totals(), false) end

  if tick % 10 == 0 then
    local pop = CAP - nfree
    local per = pop > 0 and floor(commons / pop) or 0
    if per > 0 then
      for i = 0, MASK do
        if U[i].alive == 1 then U[i].money = U[i].money + per end
      end
      commons = commons - per * pop
    end
  end
end

function M.trigger_shock(x, y)
  local sh = M.shock
  sh.x, sh.y, sh.r, sh.ttl = x or random() * W, y or random() * W, 150 + random() * 250, 400
end

function M.check_money()
  local sum = commons
  for i = 0, MASK do
    if U[i].alive == 1 then sum = sum + U[i].money end
  end
  assert(sum == supply, ("money leak at tick %d: %.0f ~= %.0f"):format(tick, sum, supply))
end

-- net worth at the going (median-belief) prices; drives circle size, gini and the histogram
function M.worth(u)
  local s = M.stats
  return max(0, u.money + u.lent - u.debt + u.stock[0] * (s.price or 10) + (u.stock[1] + u.capital) * (s.tool_price or 20))
end

local wealth, prices, tprices = {}, {}, {}
function M.compute_stats()
  local s = M.stats
  local n, price, debt, artisans, capital, stubborn = 0, 0, 0, 0, 0, 0
  local means = {}
  for k = 1, NG do
    means[k] = 0
  end
  for i = 0, MASK do
    local u = U[i]
    if u.alive == 1 then
      n = n + 1
      wealth[n] = M.worth(u)
      prices[n], tprices[n] = u.belief[FOOD], u.belief[TOOLS]
      capital = capital + u.capital
      if u.g[CRAFT] > 0.5 then artisans = artisans + 1 end
      stubborn = stubborn + u.stubborn
      debt = debt + u.debt
      for k = 1, NG do
        means[k] = means[k] + u.g[k - 1]
      end
    end
  end
  for k = #wealth, n + 1, -1 do
    wealth[k], prices[k], tprices[k] = nil, nil, nil
  end
  table.sort(prices)
  table.sort(tprices)
  s.stubborn = stubborn
  s.tool_price, s.artisans, s.capital = tprices[floor(n / 2) + 1] or 0, artisans, n > 0 and capital / n or 0
  price = prices[floor(n / 2) + 1] or 0
  table.sort(wealth)
  s.median_worth = max(1, wealth[floor(n / 2) + 1] or 1)
  local cum, total = 0, 0
  for k = 1, n do
    cum, total = cum + k * wealth[k], total + wealth[k]
  end
  s.gini = (n > 0 and total > 0) and (2 * cum / (n * total) - (n + 1) / n) or 0
  s.top1 = 0
  for k = max(1, n - floor(n / 100) + 1), n do
    s.top1 = s.top1 + wealth[k]
  end
  s.top1 = total > 0 and s.top1 / total or 0
  for b = 1, 24 do
    s.wealth_bins[b] = 0
  end
  for k = 1, n do
    local b = min(24, 1 + floor(log(wealth[k] + 1) / log(10) * 4))
    s.wealth_bins[b] = s.wealth_bins[b] + 1
  end
  for k = 1, NG do
    means[k] = n > 0 and means[k] / n or 0
  end
  s.pop, s.price, s.debt, s.means, s.tick, s.commons = n, price, debt, means, tick, commons
  s.nloans = MAXLOANS - nfree_loans
  s.births, s.starved, s.aged, s.defaults = c_births, c_starved, c_aged, c_defaults
  s.trades, s.volume, s.new_loans, s.spec, s.tool_volume = c_trades, c_volume, c_loans, c_spec, c_tool_vol
  c_spec, c_tool_vol = 0, 0
  s.unmet = s.unmet or {}
  for k = 0, 7 do
    s.unmet[k], unmet[k] = unmet[k], 0
  end
  c_births, c_starved, c_aged, c_defaults, c_trades, c_volume, c_loans = 0, 0, 0, 0, 0, 0, 0

  local h = s.hist_head
  hist[0 * HN + h], hist[1 * HN + h], hist[2 * HN + h], hist[3 * HN + h] = n, s.gini, s.price, s.tool_price
  for k = 1, NG do
    hist[(3 + k) * HN + h] = means[k]
  end
  s.hist_head, s.hist_n = (h + 1) % HN, min(HN, s.hist_n + 1)
end

function M.loan_hi() return loan_hi end

---------------------------------------------------------------------------------------------------
-- Assertions. Static ones run at load; state ones run per phase when M.debug, and in M.selftest().
---------------------------------------------------------------------------------------------------
local function check(cond, fmt, ...)
  if not cond then error(("sim invariant violated at tick %d: " .. fmt):format(tick, ...), 2) end
end
local function finite(v) return v == v and v > -math.huge and v < math.huge end
local function whole(v) return v == floor(v) end
local function pow2(v) return v > 0 and band(v, v - 1) == 0 end

do
  check(pow2(CAP) and pow2(GRID) and pow2(NFLASH), "CAP/GRID/NFLASH must be powers of two (band() masks depend on it)")
  check(MASK == CAP - 1 and GMASK == GRID - 1 and NC == GRID * GRID and W == GRID * CELL, "derived constants out of sync")
  check(R2 <= CELL * CELL, "interaction radius %g exceeds cell size %d: the 3x3 scan would miss neighbours", sqrt(R2), CELL)
  check(#M.GENES == NG, "GENES has %d names for %d genes", #M.GENES, NG)
  check(ffi.sizeof("unit_t") > 0 and ffi.sizeof(U[0].g) == NG * 4, "unit_t.g holds %d floats, NG is %d", ffi.sizeof(U[0].g) / 4, NG)
  local idx = { PROD, RESERVE, GREED, HERD, THRIFT, INVEST, RISK, TRUST, SPEED, SEEK_RICH, SEEK_KIN, MIGRATE, REPRO, ENDOW, INHERIT, BORROW, BUILD, SPECULATE, PEDDLE, CRAFT }
  check(#idx == NG, "%d gene index constants for %d genes", #idx, NG)
  local seen = {}
  for _, k in ipairs(idx) do
    check(k >= 0 and k < NG and not seen[k], "gene index %d out of range or duplicated", k)
    seen[k] = true
  end
  for _, p in ipairs(PRIMES) do
    check(p > CAP, "stride %d must exceed CAP so it is coprime with every population size", p)
    for d = 2, floor(sqrt(p)) do
      check(p % d ~= 0, "stride %d is not prime", p)
    end
  end
  check(MAXPAIRS >= CAP * 9, "pair buffer too small")
  check(ffi.sizeof(hist) == (4 + NG) * HN * 4, "hist buffer does not match 4 + NG series")
  check(ffi.sizeof(res) == NC * 2 * 4 and ffi.sizeof(opp) == ffi.sizeof(res) and ffi.sizeof(sup) == ffi.sizeof(res) and ffi.sizeof(dem) == ffi.sizeof(res), "field buffers must hold 2 goods x NC cells")
  check(TERM > 0, "TERM must be positive")
  check(FOOD == 0 and TOOLS == 1, "goods are indexed 0/1 by phase_trade and the k=0,NC,NC field loops")
  check(CARRY[0] > MINQ[0] and CARRY[1] > MINQ[1], "CARRY must exceed MINQ or speculation can never trade")
end

function M.check_knobs()
  local k = M.knobs
  check(whole(k.pop) and k.pop >= 1 and k.pop <= CAP, "knob pop=%g must be an integer in 1..%d", k.pop, CAP)
  check(whole(k.money) and k.money >= 1 and k.pop * k.money < 2 ^ 52, "knob money=%g must be a positive integer (supply stays exact in a double)", k.money)
  check(k.artisans >= 0 and k.artisans <= 1, "knob artisans=%g outside [0,1]", k.artisans)
  check(k.yield > 0 and k.toolrate > 0, "knobs yield=%g toolrate=%g must be positive", k.yield, k.toolrate)
  check(k.mut > 0 and k.mut <= 0.5, "knob mut=%g outside (0, 0.5]", k.mut)
  check(k.estate_tax >= 0 and k.estate_tax <= 1, "knob estate_tax=%g outside [0,1]", k.estate_tax)
  check(k.shock_every >= 0, "knob shock_every=%g negative", k.shock_every)
  check(k.stubborn_founders >= 0 and k.stubborn_founders <= 1, "knob stubborn_founders=%g outside [0,1]", k.stubborn_founders)
  check(k.stubborn_birth >= 0 and k.stubborn_birth <= 1, "knob stubborn_birth=%g outside [0,1]", k.stubborn_birth)
end

function M.totals()
  local t = { money = commons, food = 0, tools = 0, capital = 0, pop = 0 }
  for i = 0, MASK do
    local u = U[i]
    if u.alive ~= 0 then
      t.money, t.food, t.tools, t.capital = t.money + u.money, t.food + u.stock[0], t.tools + u.stock[1], t.capital + u.capital
      t.pop = t.pop + 1
    end
  end
  return t
end

-- goods=true for phases that only move goods between units; money must be exact everywhere
function M.check_conserved(phase, a, b, goods)
  check(a.money == b.money, "%s leaked money: %.0f -> %.0f", phase, a.money, b.money)
  check(b.money == supply, "%s: money %.0f ~= supply %.0f", phase, b.money, supply)
  if goods then
    for _, f in ipairs({ "food", "tools", "capital" }) do
      check(abs(a[f] - b[f]) <= 1e-4 * (abs(a[f]) + 1) + 0.05, "%s created or destroyed %s: %.4f -> %.4f", phase, f, a[f], b[f])
    end
  end
end

function M.check_grid()
  check(cell_start[0] == 0, "cell_start[0]=%d", cell_start[0])
  local alive = 0
  for i = 0, MASK do
    if U[i].alive == 1 then alive = alive + 1 end
    check(U[i].alive <= 1, "unit %d still marked dying (alive=2) at tick start", i)
  end
  check(cell_start[NC] == alive, "grid holds %d units, %d are alive", cell_start[NC], alive)
  for c = 0, NC - 1 do
    check(cell_start[c + 1] >= cell_start[c], "cell_start not monotone at cell %d", c)
    for s = cell_start[c], cell_start[c + 1] - 1 do
      local i = cell_items[s]
      check(i >= 0 and i < CAP and U[i].alive == 1 and U[i].cell == c, "cell %d lists unit %d (alive=%d cell=%d)", c, i, U[i].alive, U[i].cell)
      local u = U[i]
      check(band(floor(u.y / CELL), GMASK) * GRID + band(floor(u.x / CELL), GMASK) == c, "unit %d at (%.1f,%.1f) filed under cell %d", i, u.x, u.y, c)
    end
  end
end

function M.check_scan(pop)
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local a = SC[i]
    check(a.nn >= 0 and a.nn < CAP, "unit %d scan nn=%d", i, a.nn)
    check(a.cand >= -1 and a.cand < CAP and a.cand ~= i, "unit %d lend candidate %d", i, a.cand)
    check((a.cand >= 0) == (a.nn > 0), "unit %d: cand=%d but nn=%d", i, a.cand, a.nn)
    for k = 0, 1 do
      local b = a.best[k]
      check(b >= -1 and b < CAP and b ~= i, "unit %d best seller[%d]=%d", i, k, b)
      check(b < 0 or U[b].alive ~= 0, "unit %d best seller[%d]=%d is a dead slot", i, k, b)
      check(b < 0 or a.best_ask[k] < 1e30, "unit %d has seller[%d] with no ask", i, k)
    end
    check(finite(sc_ax[i]) and finite(sc_ay[i]), "unit %d steering is not finite (%g,%g)", i, sc_ax[i], sc_ay[i])
    check(finite(a.px) and finite(a.py), "unit %d separation push not finite", i)
    check(U[i].alive ~= 1 or (sc_scale[i * 2] > 0 and sc_scale[i * 2 + 1] >= 0), "unit %d reserve/target scale (%g,%g)", i, sc_scale[i * 2], sc_scale[i * 2 + 1])
  end
end

function M.check_fields()
  for c = 0, NC * 2 - 1 do
    check(res[c] >= 0.05 and res[c] <= 1, "resource field[%d]=%g outside [0.05,1]", c, res[c])
    check(finite(opp[c]) and opp[c] >= 0 and opp[c] <= 1.0001, "opportunity field[%d]=%g", c, opp[c])
    check(finite(sup[c]) and sup[c] >= 0 and sup[c] >= sup_raw[c], "supply field[%d]=%g (raw %g)", c, sup[c], sup_raw[c])
    check(finite(dem[c]) and dem[c] >= 0 and dem[c] >= dem_raw[c], "demand field[%d]=%g (raw %g)", c, dem[c], dem_raw[c])
  end
end

-- full state audit; valid between ticks
function M.validate()
  M.check_knobs()
  check(commons >= 0 and whole(commons), "commons=%g must be a non-negative integer", commons)
  check(nfree >= 0 and nfree <= CAP and nfree_loans >= 0 and nfree_loans <= MAXLOANS, "free counters out of range")
  check(ndying == 0, "%d units left unburied", ndying)
  check(loan_hi >= 0 and loan_hi <= MAXLOANS, "loan_hi=%d", loan_hi)

  local alive, money = 0, commons
  local debt, lent, nl = {}, {}, {}
  for i = 0, MASK do
    local u = U[i]
    check(u.alive <= 1, "unit %d alive=%d between ticks", i, u.alive)
    if u.alive == 0 then
      check(u.money == 0, "dead slot %d still holds %.0f money", i, u.money)
    else
      alive, money = alive + 1, money + u.money
      check(finite(u.x) and finite(u.y) and u.x >= 0 and u.x < W and u.y >= 0 and u.y < W, "unit %d off the map (%g,%g)", i, u.x, u.y)
      check(finite(u.vx) and finite(u.vy), "unit %d velocity not finite", i)
      check(sqrt(u.vx * u.vx + u.vy * u.vy) <= 1 + 3 * u.g[SPEED] + 1e-3, "unit %d faster than its speed gene allows", i)
      check(u.stubborn <= 1, "unit %d stubborn=%d", i, u.stubborn)
      check(u.stubborn == 0 or (u.vx == 0 and u.vy == 0) or u.age < 2, "stubborn unit %d is moving (%g,%g)", i, u.vx, u.vy)
      check(u.money >= 0 and whole(u.money), "unit %d money=%g must be a non-negative integer", i, u.money)
      check(u.debt >= 0 and whole(u.debt) and u.lent >= 0 and whole(u.lent), "unit %d debt=%g lent=%g", i, u.debt, u.lent)
      check(finite(u.capital) and u.capital >= 0, "unit %d capital=%g", i, u.capital)
      check(u.cell >= 0 and u.cell < NC, "unit %d cell=%d", i, u.cell)
      check(u.hue >= 0 and u.hue < 360.001, "unit %d hue=%g", i, u.hue)
      check(u.age < 1e6, "unit %d age=%d", i, u.age)
      check(u.heir >= -1 and u.heir < CAP and u.heir ~= i, "unit %d heir=%d", i, u.heir)
      for k = 0, 1 do
        check(finite(u.stock[k]) and u.stock[k] >= -1e-3, "unit %d stock[%d]=%g", i, k, u.stock[k])
        check(finite(u.belief[k]) and u.belief[k] >= 0.049, "unit %d belief[%d]=%g", i, k, u.belief[k])
        check(finite(u.ask[k]) and u.ask[k] >= 0 and finite(u.surplus[k]), "unit %d ask/surplus[%d] not finite", i, k)
        check(u.surplus[k] <= u.stock[k] + 1e-3, "unit %d offers more of good %d (%g) than it holds (%g)", i, k, u.surplus[k], u.stock[k])
      end
      for k = 0, NG - 1 do
        check(u.g[k] >= 0 and u.g[k] <= 1, "unit %d gene %s=%g outside [0,1]", i, M.GENES[k + 1], u.g[k])
      end
      debt[i], lent[i], nl[i] = 0, 0, 0
    end
  end
  check(money == supply, "money %.0f ~= supply %.0f", money, supply)
  check(alive + nfree == CAP, "%d alive + %d free ~= %d slots", alive, nfree, CAP)

  local seen = {}
  for k = 0, nfree - 1 do
    local i = free_units[k]
    check(i >= 0 and i < CAP and U[i].alive == 0 and not seen[i], "free list entry %d (slot %d) is alive, out of range, or duplicated", k, i)
    seen[i] = true
  end

  local active = 0
  for li = 0, MAXLOANS - 1 do
    local l = L[li]
    if l.active == 1 then
      active = active + 1
      check(li < loan_hi, "active loan %d beyond loan_hi=%d", li, loan_hi)
      check(l.lender >= 0 and l.lender < CAP and l.borrower >= 0 and l.borrower < CAP, "loan %d endpoints out of range", li)
      check(l.lender ~= l.borrower, "loan %d lends to itself", li)
      local le, b = U[l.lender], U[l.borrower]
      check(le.alive == 1 and le.gen == l.lgen, "loan %d lender %d is dead or a reused slot", li, l.lender)
      check(b.alive == 1 and b.gen == l.bgen, "loan %d borrower %d is dead or a reused slot", li, l.borrower)
      check(l.owed > 0 and whole(l.owed) and l.installment >= 1 and whole(l.installment), "loan %d owed=%g installment=%g", li, l.owed, l.installment)
      check(l.expiry >= tick, "loan %d expired at %d but is still active", li, l.expiry)
      debt[l.borrower], lent[l.lender], nl[l.lender] = debt[l.borrower] + l.owed, lent[l.lender] + l.owed, nl[l.lender] + 1
    else
      check(l.active == 0, "loan %d active=%d", li, l.active)
    end
  end
  check(active == MAXLOANS - nfree_loans, "%d active loans but %d slots in use", active, MAXLOANS - nfree_loans)
  seen = {}
  for k = 0, nfree_loans - 1 do
    local li = free_loans[k]
    check(li >= 0 and li < MAXLOANS and L[li].active == 0 and not seen[li], "free loan entry %d (slot %d) is active, out of range, or duplicated", k, li)
    seen[li] = true
  end
  for i, d in pairs(debt) do
    check(U[i].debt == d, "unit %d debt %.0f ~= %.0f owed on its loans", i, U[i].debt, d)
    check(U[i].lent == lent[i], "unit %d lent %.0f ~= %.0f owed to it", i, U[i].lent, lent[i])
    check(U[i].nloans == nl[i], "unit %d nloans %d ~= %d loans it holds", i, U[i].nloans, nl[i])
  end

  for k = 0, NFLASH - 1 do
    check(flashes[k].kind <= 4 and flashes[k].ttl <= 24, "flash %d kind=%d ttl=%d", k, flashes[k].kind, flashes[k].ttl)
  end
  local sh = M.shock
  check(sh.ttl >= 0 and (sh.ttl == 0 or (sh.r > 0 and sh.x >= 0 and sh.x < W and sh.y >= 0 and sh.y < W)), "shock state invalid")

  local s = M.stats
  if s.tick ~= tick then return end
  check(s.pop == alive, "stats pop %d ~= %d alive", s.pop, alive)
  check(s.gini >= -1e-9 and s.gini <= 1 and s.top1 >= 0 and s.top1 <= 1 + 1e-9, "gini=%g top1=%g", s.gini, s.top1)
  check(s.artisans <= s.pop and s.stubborn <= s.pop, "artisans/stubborn exceed pop")
  local bins = 0
  for b = 1, 24 do
    bins = bins + s.wealth_bins[b]
  end
  check(bins == alive, "wealth histogram counts %d of %d units", bins, alive)
  for k = 1, NG do
    check(s.means[k] >= 0 and s.means[k] <= 1, "gene mean %s=%g", M.GENES[k], s.means[k])
  end
  check(s.hist_n >= 1 and s.hist_n <= HN and s.hist_head >= 0 and s.hist_head < HN, "history ring indices")
end

local DEFAULTS = {}
for k, v in pairs(M.knobs) do
  DEFAULTS[k] = v
end

local function fingerprint()
  local h = commons + tick
  for i = 0, MASK do
    local u = U[i]
    if u.alive == 1 then h = (h * 31 + u.money + floor(u.x * 64) + floor(u.y * 64) * 3 + floor(u.stock[0] * 16) + i) % 2147483647 end
  end
  return h
end

-- short audited run; call before opening a window so a broken build fails at startup, not mid-demo
function M.selftest(ticks)
  local was, mine = M.debug, M.knobs
  M.debug, M.knobs = true, DEFAULTS
  local prints = {}
  for run = 1, 2 do
    M.init(12345)
    M.validate()
    local t0 = M.totals()
    check(t0.pop > 0 and t0.money == supply, "init produced pop=%d money=%.0f supply=%.0f", t0.pop, t0.money, supply)
    for _ = 1, ticks or 150 do
      M.tick()
      M.validate()
    end
    check(M.stats.pop > 0, "population went extinct within the self-test window")
    prints[run] = fingerprint()
  end
  check(prints[1] == prints[2], "same seed gave different runs (%d vs %d): hidden nondeterminism", prints[1], prints[2])
  M.debug, M.knobs = was, mine
end

-- "--key=value" for any knob plus caller-declared extras; unknown keys and non-numbers are errors, not silently ignored
function M.parse_args(argv, extras)
  local out, names = {}, {}
  for k in pairs(M.knobs) do
    names[#names + 1] = k
  end
  for k in pairs(extras) do
    names[#names + 1] = k
  end
  table.sort(names)
  for _, a in ipairs(argv) do
    local key, val = a:match("^%-%-([%w_-]+)=?(.*)$")
    key = key and key:gsub("-", "_")
    if key == "help" or not key or (M.knobs[key] == nil and extras[key] == nil) then
      io.stderr:write(key == "help" and "" or ("unknown argument: " .. a .. "\n"), "options (--name=value):\n")
      for _, n in ipairs(names) do
        local flag = n:gsub("_", "-")
        io.stderr:write(("  --%-18s %s%s\n"):format(flag, M.KNOB_HELP[n] or extras[n], DEFAULTS[n] and (" (default %s)"):format(DEFAULTS[n]) or ""))
      end
      os.exit(key == "help" and 0 or 2)
    end
    local num = tonumber(val)
    if val == "" then num = 1 end
    if not num then
      io.stderr:write(("--%s needs a number, got '%s'\n"):format(key, val))
      os.exit(2)
    end
    if M.knobs[key] ~= nil then
      M.knobs[key] = num
    else
      out[key] = num
    end
  end
  local ok, err = pcall(M.check_knobs)
  if not ok then
    io.stderr:write(err:gsub("^.-: knob ", "bad option: "), "\n")
    os.exit(2)
  end
  return out
end

return M
