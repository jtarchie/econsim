local ffi = require("ffi")
local bit = require("bit")
local band = bit.band
-- branchy per-unit loop blows default trace limits and falls back to the interpreter
require("jit.opt").start("maxtrace=20000", "maxrecord=40000", "maxside=4000", "maxsnap=4000", "sizemcode=1024", "maxmcode=131072")
local floor, ceil, sqrt, atan2, abs = math.floor, math.ceil, math.sqrt, math.atan2, math.abs
local NAN = 0 / 0
local random, min, max, log = math.random, math.min, math.max, math.log

local NG, TERM, NFLASH, HN = 21, 600, 4096, 240
-- set from the max_holding knob at init; nothing in the model stops one unit owning everything, so this cap is what does, and it binds
local MAXCELLS = 8
-- world size is picked at init() from the cap/grid/cell knobs; everything below is derived from it
local CAP, GRID, CELL = 0, 0, 0
local MASK, GMASK, NC, W, R2, MAXLOANS, MAXPAIRS = 0, 0, 0, 0, 0, 0, 0
-- hot loops divide by these every unit; reciprocals let the JIT multiply instead
local INV_W, INV_CELL, INV_GRID = 0, 0, 0

local PROD, RESERVE, GREED, HERD, THRIFT, INVEST, RISK, TRUST, SPEED = 0, 1, 2, 3, 4, 5, 6, 7, 8
local SEEK_RICH, SEEK_KIN, MIGRATE, REPRO, ENDOW, INHERIT, BORROW, BUILD = 9, 10, 11, 12, 13, 14, 15, 16
local SPECULATE, PEDDLE, CRAFT, LAND = 17, 18, 19, 20
local FOOD, TOOLS = 0, 1

-- signed and exhaustive, so a unit's channels sum to exactly its money: that is what makes "where did this fortune come from" answerable, and validate() checks it
local NCHAN = 10
local CH = { FOUND = 0, SELL = 1, BUY = 2, CREDIT = 3, DEBT = 4, STAKE = 5, BEQUEST = 6, SCATTER = 7, DIVIDEND = 8, LAND = 9 }

ffi.cdef([[
typedef struct {
  float x, y, vx, vy;
  double money, debt, lent;
  float stock[2], belief[2], ask[2], surplus[2], capital, hue;
  uint32_t age, gen, heir_gen, dyn;
  int32_t default_tick, cell, heir;
  uint8_t nloans, alive, sold[2], cr, cg, cb, stubborn, ncells;
  float g[21];
} unit_t;
/* cold biography, --track only: kept out of unit_t so the memory-bound tick never drags it through cache */
typedef struct {
  double chan[10];
  float peak, cur, ppct;
  int32_t born, kids;
} trk_t;
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
    "land",
  },
  FLASH = { TRADE = 0, BIRTH = 1, DEATH = 2, DEFAULT = 3, LOAN = 4 },
  CHANNELS = { "founding", "sales", "purchases", "credit", "debt", "children", "bequest", "estates", "dividend", "land" },
  CAUSES = { "starved", "aged" },
  knobs = {
    cap = 16384,
    grid = 128,
    cell = 16,
    compact_every = 4,
    pop = 2000,
    money = 1500,
    artisans = 0.15,
    yield = 2.6,
    toolrate = 0.5,
    mut = 0.05,
    estate_tax = 0.0,
    shock_every = 600,
    stubborn_founders = 0.2,
    stubborn_birth = 0.02,
    track = 1,
    lending = 1.0,
    usury = 1.0,
    enclosure = 1.0,
    rent = 0.2,
    land_price = 150,
    max_holding = 8,
  },
  KNOB_HELP = {
    cap = "unit slots, a power of two; the hard population ceiling",
    grid = "cells per side, a power of two; world is grid x cell units across",
    cell = "cell size in world units; also the interaction radius",
    compact_every = "ticks between renumbering units into cell order; 0 = never",
    pop = "founding population (1..cap)",
    money = "money per founder; total supply = pop x money, fixed forever",
    artisans = "fraction of founders who start as tool-makers on ore land",
    yield = "food per unit labour on perfect land",
    toolrate = "tools per unit labour on perfect ore",
    mut = "per-gene mutation sigma at birth",
    estate_tax = "share of every estate paid to the commons dividend",
    shock_every = "mean ticks between crop failures, 0 = never",
    stubborn_founders = "fraction of founders who never adapt",
    stubborn_birth = "chance an adaptive unit's child is stubborn",
    track = "1 to record per-unit money channels, rank history and death records; 0 costs nothing",
    lending = "scales how often surplus money is offered as a loan; 0 is an economy with no credit",
    usury = "hard ceiling on the interest rate a lender may charge",
    enclosure = "scales how readily unowned land is claimed; 0 is a world where nobody can own land",
    rent = "share of what a cell yields that its owner collects from whoever works it",
    land_price = "money paid to the commons to claim one unowned cell",
    max_holding = "most cells one unit may hold; the top holders sit on this cap, so it bounds concentration",
  },
  shock = { x = 0, y = 0, r = 0, ttl = 0 },
  -- the unit the UI is following; compaction moves slots, so the sim owns this index
  selected = -1,
  stats = {},
}

local U, L, flashes, free_units, free_loans, dying, cell_start, cell_cursor, cell_items
local opp, res, sup, dem, sup_raw, dem_raw, fert, ore
local SC, NB, px, py, blk_x, blk_y, blk_s, pair_i, pair_j, pair_dx, pair_dy, sc_ax, sc_ay, sc_scale, sc_net, heirs, PRIMES
-- scratch for compaction: units are rebuilt into cell order, then copied back
local U2, nn2, remap
-- live[] is the dense set of alive slots; without it every tick would sweep all CAP slots to find them
local live, live_at, nlive = nil, nil, 0
local proj = ffi.new("float[?]", NG * 2)
local hist = ffi.new("float[?]", (4 + NG) * HN)
M.hist = hist

local ensure_size, ensure_track, check_static, reset_scratch, update_ranks
local nfree, nfree_loans, loan_hi, ndying, flash_head = 0, 0, 0, 0, 0
local tick, commons, supply = 0, 0, 0
local c_births, c_starved, c_aged, c_defaults, c_trades, c_volume, c_loans, c_spec, c_tool_vol = 0, 0, 0, 0, 0, 0, 0, 0, 0
-- lifetime counters, as one table because init() is already at LuaJIT's 60-upvalue ceiling
local TOT = { births = 0, starved = 0, aged = 0, defaults = 0, trades = 0, volume = 0 }
-- biography arrays and the dynasty histogram; TR is nil unless --track is on, so every use is guarded by trk
local TR, T2, TR_CAP, trk = nil, nil, 0, false
local dcount, dworth, ndyn = nil, nil, 0
-- own[cell] is the slot that owns it or -1; cells[] is the same fact per unit, so a death can find its own land without sweeping the map
local own, cells, cells2, enc = nil, nil, nil, false
local LND = { rent = 0, claims = 0, foreclosed = 0 }
-- the price rent is charged at must be the sim's own, not whatever compute_stats last left lying around, or a host that rarely asks for stats would charge rent at a year-old price
local REF = ffi.new("double[6]")
-- the cause a unit is dying of, parallel to dying[]: known at kill(), needed at bury(), and never after
local dying_why = nil

local function flash(x, y, kind)
  local f = flashes[flash_head]
  f.x, f.y, f.kind, f.ttl = x, y, kind, 24
  flash_head = band(flash_head + 1, NFLASH - 1)
end

local function led(i, k, v)
  local c = TR[i].chan
  c[k] = c[k] + v
end

-- swap-remove from the owner's list; the two sides of ownership must never disagree, and validate() says so
local function land_drop(c)
  local o = own[c]
  if o < 0 then return end
  local u = U[o]
  local base, n = o * MAXCELLS, U[o].ncells
  for k = 0, n - 1 do
    if cells[base + k] == c then
      cells[base + k] = cells[base + n - 1]
      u.ncells = n - 1
      break
    end
  end
  own[c] = -1
end

local function land_give(c, i)
  local u = U[i]
  if u.ncells >= MAXCELLS then return false end
  cells[i * MAXCELLS + u.ncells] = c
  u.ncells, own[c] = u.ncells + 1, i
  return true
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
  v = v - W * floor(v * INV_W)
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
  live[nlive], live_at[i], nlive = i, nlive, nlive + 1
  -- slots are reused, so the previous occupant's biography must not bleed into this one
  if trk then
    ffi.fill(TR + i, ffi.sizeof("trk_t"))
    TR[i].born, TR[i].ppct = tick, -1
  end
  return i, u
end

function M.init(seed)
  M.check_knobs()
  ensure_size()
  ensure_track()
  -- fixed seed: hue projection must match across runs so colors are comparable
  math.randomseed(1234)
  for k = 0, NG * 2 - 1 do
    proj[k] = gauss()
  end
  math.randomseed(seed or os.time())

  ffi.fill(U, CAP * ffi.sizeof("unit_t"))
  ffi.fill(L, MAXLOANS * ffi.sizeof("loan_t"))
  nlive = 0
  ffi.fill(flashes, NFLASH * ffi.sizeof("flash_t"))
  ffi.fill(hist, ffi.sizeof(hist))
  tick, commons, loan_hi, ndying, M.selected = 0, 0, 0, 0, -1
  ffi.fill(sup, NC * 2 * 4)
  ffi.fill(dem, NC * 2 * 4)
  reset_scratch()
  flash_head, M.shock.x, M.shock.y, M.shock.r = 0, 0, 0, 0
  c_births, c_starved, c_aged, c_defaults, c_trades, c_volume, c_loans, c_spec, c_tool_vol = 0, 0, 0, 0, 0, 0, 0, 0, 0
  LND.rent, LND.claims, LND.foreclosed = 0, 0, 0
  REF[0], REF[1], REF[2], REF[3], REF[4], REF[5] = 10, 20, 0, 0, 0, 0
  TOT.births, TOT.starved, TOT.aged, TOT.defaults, TOT.trades, TOT.volume = 0, 0, 0, 0, 0, 0
  if trk then ffi.fill(TR, CAP * ffi.sizeof("trk_t")) end
  M.reset_deaths()
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

  local kn = M.knobs
  for n = 1, kn.pop do
    local x, y
    local field = random() < kn.artisans and ore or fert
    repeat
      x, y = random() * W, random() * W
    until field[floor(y * INV_CELL) * GRID + floor(x * INV_CELL)] > 0.55
    local i, u = spawn(x, y)
    -- one dynasty per founder, carried down every descendant: lineage share is the metric selection actually optimises
    u.dyn = n
    if trk then TR[i].chan[0] = kn.money end
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

local max_cell, blk_n = 0, 0

-- counting sort over live[], not over all CAP slots: an empty continent must not cost what a full one does
local function build_grid()
  ffi.fill(cell_start, (NC + 1) * 4)
  for s = 0, nlive - 1 do
    local u = U[live[s]]
    local c = band(floor(u.y * INV_CELL), GMASK) * GRID + band(floor(u.x * INV_CELL), GMASK)
    u.cell = c
    cell_start[c + 1] = cell_start[c + 1] + 1
  end
  local hi = 0
  for c = 1, NC do
    local n = cell_start[c]
    if n > hi then hi = n end
    cell_start[c] = n + cell_start[c - 1]
    cell_cursor[c - 1] = cell_start[c - 1]
  end
  cell_cursor[NC] = cell_start[NC]
  max_cell = hi
  -- a chunk can only end between cells, so one cell's worth of pairs must always fit
  if blk_x == nil or 9 * hi > blk_n then
    blk_n = max(64, 2 ^ ceil(log(18 * hi) / log(2)))
    blk_x, blk_y = ffi.new("float[?]", blk_n), ffi.new("float[?]", blk_n)
    blk_s = ffi.new("int32_t[?]", blk_n)
  end
  if blk_n * hi >= MAXPAIRS then
    MAXPAIRS = 2 ^ ceil(log(2 * blk_n * hi) / log(2))
    pair_i, pair_j = ffi.new("int32_t[?]", MAXPAIRS), ffi.new("int32_t[?]", MAXPAIRS)
    pair_dx, pair_dy = ffi.new("float[?]", MAXPAIRS), ffi.new("float[?]", MAXPAIRS)
  end
  for s = 0, nlive - 1 do
    local i = live[s]
    local c = U[i].cell
    local at = cell_cursor[c]
    cell_items[at] = i
    cell_cursor[c] = at + 1
  end
end

-- Renumber units into cell order. Every phase reads units through cell_items, so after this
-- the gathers are sequential instead of jumping across a unit array far larger than cache.
-- Slot identity is not economic state: the same units stay in the same visit order, so the
-- trajectory is unchanged. Only the indices that name them move, and every reference is remapped.
local UNIT_BYTES, TRK_BYTES = ffi.sizeof("unit_t"), ffi.sizeof("trk_t")
local function compact()
  ffi.fill(remap, CAP * 4, 0xFF)
  for s = 0, nlive - 1 do
    local i = cell_items[s]
    remap[i], nn2[s] = s, SC[i].nn
    ffi.copy(U2 + s, U + i, UNIT_BYTES)
    if trk then ffi.copy(T2 + s, TR + i, TRK_BYTES) end
    if enc then ffi.copy(cells2 + s * MAXCELLS, cells + i * MAXCELLS, MAXCELLS * 4) end
  end
  ffi.copy(U, U2, nlive * UNIT_BYTES)
  if trk then
    ffi.copy(TR, T2, nlive * TRK_BYTES)
    ffi.fill(TR + nlive, (CAP - nlive) * TRK_BYTES)
  end
  if enc then
    ffi.copy(cells, cells2, nlive * MAXCELLS * 4)
    ffi.fill(cells + nlive * MAXCELLS, (CAP - nlive) * MAXCELLS * 4, 0xFF)
    -- own[] names slots, and every slot just moved; a dead owner would remap to -1, which reads as unowned
    for c = 0, NC - 1 do
      local o = own[c]
      if o >= 0 then own[c] = remap[o] end
    end
  end
  -- dead slots must read as never-used: validate() insists they hold no money
  ffi.fill(U + nlive, (CAP - nlive) * UNIT_BYTES)
  for s = 0, nlive - 1 do
    local u = U[s]
    local h = u.heir
    -- an heir that died is dropped outright; previously only the gen counter caught it
    u.heir = h >= 0 and remap[h] or -1
    SC[s].nn, cell_items[s], live[s], live_at[s] = nn2[s], s, s, s
  end
  for li = 0, loan_hi - 1 do
    local l = L[li]
    if l.active == 1 then
      l.lender, l.borrower = remap[l.lender], remap[l.borrower]
    end
  end
  for k = 0, nfree - 1 do
    free_units[k] = CAP - 1 - k
  end
  M.selected = M.selected >= 0 and remap[M.selected] or -1
end

local function kill(i, u, why)
  u.alive = 2
  dying[ndying], dying_why[ndying] = i, why
  ndying = ndying + 1
  flash(u.x, u.y, 2)
end

ffi.cdef([[
typedef struct { double rich_m; float bel_sum[2], best_ask[2], rdx, rdy, kdx, kdy, px, py; int32_t nn, best[2], cand; } scan_t;
/* every field the pair loop reads off a neighbour, and nothing else: 48 bytes in cell order
   instead of chasing a 192-byte unit_t across an array far bigger than cache */
typedef struct { float hue, bel0, bel1, ask0, ask1, sur0, sur1; double money; } nb_t;
]])
local off_x = ffi.new("int32_t[9]", -1, 0, 1, -1, 0, 1, -1, 0, 1)
local off_y = ffi.new("int32_t[9]", -1, -1, -1, 0, 0, 0, 1, 1, 1)
-- forward half of the ring: with the home cell scanned only ahead of each unit, this visits
-- every unordered pair exactly once instead of once from each end
local off_hx = ffi.new("int32_t[4]", 1, -1, 0, 1)
local off_hy = ffi.new("int32_t[4]", 0, 1, 1, 1)
local CARRY, MINQ = ffi.new("float[2]", 300, 40), ffi.new("float[2]", 0.5, 0.05)
local unmet = ffi.new("double[8]")

local function is_prime(v)
  if v % 2 == 0 then return v == 2 end
  for d = 3, floor(sqrt(v)), 2 do
    if v % d == 0 then return false end
  end
  return true
end

-- pairs are produced in chunks so the buffer stays a fixed 8MB no matter how large CAP gets
local PAIRCHUNK = 2 ^ 20

-- (re)size every buffer to the cap/grid/cell knobs. Called from init(); a no-op when the shape is unchanged.
ensure_size = function()
  local k = M.knobs
  if k.cap == CAP and k.grid == GRID and k.cell == CELL then return end
  CAP, GRID, CELL = k.cap, k.grid, k.cell
  MASK, GMASK, NC = CAP - 1, GRID - 1, GRID * GRID
  W, R2, MAXLOANS = GRID * CELL, CELL * CELL, CAP
  INV_W, INV_CELL, INV_GRID = 1 / W, 1 / CELL, 1 / GRID
  MAXPAIRS = min(PAIRCHUNK, CAP * 16)

  U = ffi.new("unit_t[?]", CAP)
  L = ffi.new("loan_t[?]", MAXLOANS)
  flashes = ffi.new("flash_t[?]", NFLASH)
  free_units, free_loans = ffi.new("int32_t[?]", CAP), ffi.new("int32_t[?]", MAXLOANS)
  dying, dying_why, heirs = ffi.new("int32_t[?]", CAP), ffi.new("uint8_t[?]", CAP), ffi.new("int32_t[?]", CAP)
  live, live_at = ffi.new("int32_t[?]", CAP), ffi.new("int32_t[?]", CAP)
  cell_start, cell_cursor = ffi.new("int32_t[?]", NC + 1), ffi.new("int32_t[?]", NC + 1)
  cell_items = ffi.new("int32_t[?]", CAP)
  opp, res = ffi.new("float[?]", NC * 2), ffi.new("float[?]", NC * 2)
  sup, dem = ffi.new("float[?]", NC * 2), ffi.new("float[?]", NC * 2)
  sup_raw, dem_raw = ffi.new("float[?]", NC * 2), ffi.new("float[?]", NC * 2)
  fert, ore = res, res + NC
  SC = ffi.new("scan_t[?]", CAP)
  NB = ffi.new("nb_t[?]", CAP)
  px, py = ffi.new("float[?]", CAP), ffi.new("float[?]", CAP)
  U2, nn2, remap = ffi.new("unit_t[?]", CAP), ffi.new("int32_t[?]", CAP), ffi.new("int32_t[?]", CAP)
  pair_i, pair_j = ffi.new("int32_t[?]", MAXPAIRS), ffi.new("int32_t[?]", MAXPAIRS)
  pair_dx, pair_dy = ffi.new("float[?]", MAXPAIRS), ffi.new("float[?]", MAXPAIRS)
  sc_ax, sc_ay = ffi.new("float[?]", CAP), ffi.new("float[?]", CAP)
  sc_scale, sc_net = ffi.new("float[?]", CAP * 2), ffi.new("float[?]", CAP)

  -- trade/lend visit order is a coprime stride, so the strides must exceed any population
  PRIMES = {}
  local p = CAP
  for n = 1, 5 do
    repeat
      p = p + 1
    until is_prime(p)
    PRIMES[n] = p
  end

  M.CAP, M.W, M.GRID, M.CELL, M.MAXLOANS = CAP, W, GRID, CELL, MAXLOANS
  M.units, M.loans, M.flashes, M.fert, M.ore = U, L, flashes, fert, ore
  check_static()
end

-- the biography arrays follow the track knob, which init() may flip without the world changing shape
ensure_track = function()
  trk = M.knobs.track == 1
  if trk and TR_CAP ~= CAP then
    TR, T2, TR_CAP = ffi.new("trk_t[?]", CAP), ffi.new("trk_t[?]", CAP), CAP
  end
  if ndyn ~= M.knobs.pop then
    ndyn = M.knobs.pop
    dcount, dworth = ffi.new("int32_t[?]", ndyn + 1), ffi.new("double[?]", ndyn + 1)
  end
  enc, MAXCELLS = M.knobs.enclosure > 0, M.knobs.max_holding
  if enc and (cells == nil or ffi.sizeof(cells) ~= CAP * MAXCELLS * 4) then
    own = ffi.new("int32_t[?]", NC)
    cells, cells2 = ffi.new("int32_t[?]", CAP * MAXCELLS), ffi.new("int32_t[?]", CAP * MAXCELLS)
  end
  if enc then
    ffi.fill(own, NC * 4, 0xFF)
    ffi.fill(cells, CAP * MAXCELLS * 4, 0xFF)
  end
  -- an --enclosure=0 run must not hand out the ownership map a previous init left allocated
  M.track, M.own = TR, enc and own or nil
end

-- scratch carries last tick's scan into produce(); stale values from a previous run made reseeded runs diverge
function reset_scratch()
  ffi.fill(SC, CAP * ffi.sizeof("scan_t"))
  ffi.fill(sc_ax, CAP * 4)
  ffi.fill(sc_ay, CAP * 4)
  ffi.fill(sc_scale, CAP * 2 * 4)
  ffi.fill(sc_net, CAP * 4)
  ffi.fill(cell_start, (NC + 1) * 4)
end

local function upkeep_of(g) return 0.6 + 0.8 * g[PROD] end

local function phase_produce(pop)
  local sh = M.shock
  local sx, sy, sr2 = sh.x, sh.y, sh.ttl > 0 and sh.r * sh.r or -1
  local YIELD, TOOLRATE = M.knobs.yield, M.knobs.toolrate
  -- rent is charged on what the land yields, valued at the going price, so a landlord's take tracks the market rather than a constant
  local RENT = enc and M.knobs.rent or 0
  local pf, pt = REF[0], REF[1]
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
    local density = 0.5 + 0.5 * crowd
    local grain, forge = YIELD * labor * farm * f / density, TOOLRATE * labor * craft * ore[cell] / density
    local net = grain - upkeep
    sc_net[i] = net
    u.stock[FOOD] = (u.stock[FOOD] + net) * 0.998
    u.stock[TOOLS] = u.stock[TOOLS] + forge
    u.capital = u.capital * 0.997
    if RENT > 0 then
      local o = own[cell]
      -- what the tenant cannot pay is simply not paid: arrears would need a whole second credit system
      if o >= 0 and o ~= i then
        local due = min(u.money, floor(RENT * (grain * pf + forge * pt)))
        if due > 0 then
          u.money, U[o].money = u.money - due, U[o].money + due
          LND.rent = LND.rent + due
          if trk then
            led(i, CH.LAND, -due)
            led(o, CH.LAND, due)
          end
        end
      end
    end
    if u.stock[FOOD] < 0 then
      c_starved, TOT.starved = c_starved + 1, TOT.starved + 1
      kill(i, u, 1)
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
  -- Blocked by row, with the left neighbour carried in a register. Every cell's new value is
  -- the next cell's left input, so reading it back from the array serialised the sweep on a
  -- store-to-load forward; keeping it live halves the cost. Splitting the six fields into
  -- separate passes was tried and lost -- they share this index arithmetic.
  for row = 0, NC - 1, GRID do
    local ub, db, e = band(row - GRID, NC - 1), band(row + GRID, NC - 1), row + GMASK
    local p1, p2, p3 = opp[e], sup[e], dem[e]
    local q1, q2, q3 = opp[NC + e], sup[NC + e], dem[NC + e]
    for cx = 0, GMASK do
      local c = row + cx
      local r = cx == GMASK and row or c + 1
      local up, dn = ub + cx, db + cx
      local crowd = 1 + 0.5 * (cell_start[c + 1] - cell_start[c])
      p1 = max(res[c] / crowd, max(p1, opp[r], opp[up], opp[dn]) * 0.99)
      p2 = max(sup_raw[c], max(p2, sup[r], sup[up], sup[dn]) * 0.95)
      p3 = max(dem_raw[c], max(p3, dem[r], dem[up], dem[dn]) * 0.95)
      opp[c], sup[c], dem[c] = p1, p2, p3
      local c2, r2, u2, d2 = NC + c, NC + r, NC + up, NC + dn
      q1 = max(res[c2] / crowd, max(q1, opp[r2], opp[u2], opp[d2]) * 0.99)
      q2 = max(sup_raw[c2], max(q2, sup[r2], sup[u2], sup[d2]) * 0.95)
      q3 = max(dem_raw[c2], max(q3, dem[r2], dem[u2], dem[d2]) * 0.95)
      opp[c2], sup[c2], dem[c2] = q1, q2, q3
    end
  end
end

-- Emits one chunk of pairs and returns where to resume, so the buffer stays a fixed size
-- however large the world gets. A unit's whole 3x3 block is always emitted together, so the
-- chunk can only end on a unit boundary; build_grid guarantees the headroom for that.
-- The 3x3 block is 2304 square units but the interaction disc is only 804, so two thirds of
-- candidates are out of range. Rejecting them here, in a loop that walks NB in cell order and
-- touches nothing else, keeps them out of the branchy consumer below.
-- Every unit in a cell scans the same neighbour block, so gather that block once into a small
-- contiguous scratch and let the whole cell test against it out of L1. Walking cell_items
-- per unit instead meant scattered streams re-read for every unit in the cell.
--
-- Only the forward half of the ring is scanned. Each unordered pair is therefore emitted once
-- and the consumer applies it to both ends, which halves enumeration and halves the distance
-- tests. Verlet lists were measured instead and rejected: units cover up to 31% of the
-- interaction radius per tick, so the skin needed to stay conservative makes the cached list
-- the same size as the grid's candidate set.
local function build_pairs(c0)
  local P, c, limit = 0, c0, MAXPAIRS - blk_n * max_cell
  while c < NC do
    local lo, hi = cell_start[c], cell_start[c + 1]
    if hi > lo then
      local cx, cy, m = band(c, GMASK), floor(c * INV_GRID), 0
      for n = 0, 3 do
        local nx, ny = cx + off_hx[n], cy + off_hy[n]
        -- the seam is a property of the neighbour cell, not of each candidate
        local ox = nx < 0 and -W or (nx >= GRID and W or 0)
        local oy = ny < 0 and -W or (ny >= GRID and W or 0)
        local nc = band(ny, GMASK) * GRID + band(nx, GMASK)
        for t = cell_start[nc], cell_start[nc + 1] - 1 do
          blk_x[m], blk_y[m], blk_s[m] = px[t] + ox, py[t] + oy, cell_items[t]
          m = m + 1
        end
      end
      for s = lo, hi - 1 do
        local ux, uy, i = px[s], py[s], cell_items[s]
        -- own cell, forward only: no self-compare needed, and no pair counted twice
        for t = s + 1, hi - 1 do
          local dx, dy = px[t] - ux, py[t] - uy
          -- a dying unit carries a NaN position, so this rejects it without a flag load
          if dx * dx + dy * dy < R2 then
            pair_i[P], pair_j[P], pair_dx[P], pair_dy[P] = i, cell_items[t], dx, dy
            P = P + 1
          end
        end
        for k = 0, m - 1 do
          local dx, dy = blk_x[k] - ux, blk_y[k] - uy
          if dx * dx + dy * dy < R2 then
            pair_i[P], pair_j[P], pair_dx[P], pair_dy[P] = i, blk_s[k], dx, dy
            P = P + 1
          end
        end
      end
    end
    c = c + 1
    if P > limit then break end
  end
  return P, c
end

local function phase_scan(pop)
  -- gather the neighbour view once; the pair loop then reads it ~9 times per unit
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local u, b, a = U[i], NB[i], SC[i]
    -- NaN position = invisible to the pair filter; dying units must not be anyone's neighbour
    px[s], py[s] = u.alive == 1 and u.x or NAN, u.alive == 1 and u.y or NAN
    b.hue, b.money = u.hue, u.money
    b.bel0, b.bel1 = u.belief[0], u.belief[1]
    b.ask0, b.ask1 = u.ask[0], u.ask[1]
    b.sur0, b.sur1 = u.surplus[0], u.surplus[1]
    a.nn, a.cand, a.rich_m = 0, -1, u.money
    a.best[0], a.best[1], a.best_ask[0], a.best_ask[1], a.bel_sum[0], a.bel_sum[1] = -1, -1, 1e30, 1e30, 0, 0
    a.rdx, a.rdy, a.kdx, a.kdy, a.px, a.py = 0, 0, 0, 0, 0, 0
  end

  -- flat pair loop: nesting the branchy body inside the 3x3 cell loops explodes LuaJIT side traces.
  -- best[]/cand collect neighbour SLOTS here and are translated to unit indices below.
  local at = 0
  repeat
    local P
    P, at = build_pairs(at)
    -- one long flat loop beats a short per-unit one: trace-entry overhead dominated there,
    -- even though every accumulator here is a read-modify-write against SC
    for p = 0, P - 1 do
      local i, j = pair_i[p], pair_j[p]
      local a, b = SC[i], SC[j]
      local oi, oj = NB[i], NB[j]
      local dx, dy = pair_dx[p], pair_dy[p]
      local kw = 1 - (180 - abs(abs(oj.hue - oi.hue) - 180)) / 90
      local pw = max(0, 1 - (dx * dx + dy * dy) / 64)

      local na = a.nn + 1
      a.nn, a.bel_sum[0], a.bel_sum[1] = na, a.bel_sum[0] + oj.bel0, a.bel_sum[1] + oj.bel1
      -- jittered ask: without it every buyer mobs the single cheapest seller and most orders fail
      local ja = 1 + 0.3 * random()
      if oj.sur0 > 0.5 and oj.ask0 * ja < a.best_ask[0] then
        a.best[0], a.best_ask[0] = j, oj.ask0 * ja
      end
      if oj.sur1 > 0.05 and oj.ask1 * ja < a.best_ask[1] then
        a.best[1], a.best_ask[1] = j, oj.ask1 * ja
      end
      if random() * na < 1 then a.cand = j end
      if oj.money > a.rich_m then
        a.rich_m, a.rdx, a.rdy = oj.money, dx, dy
      end
      a.kdx, a.kdy, a.px, a.py = a.kdx + dx * kw, a.kdy + dy * kw, a.px - dx * pw, a.py - dy * pw

      -- the same encounter seen from the other side: kinship and separation are symmetric,
      -- the offset is negated, and each side draws its own ask jitter as it did before
      local nb = b.nn + 1
      b.nn, b.bel_sum[0], b.bel_sum[1] = nb, b.bel_sum[0] + oi.bel0, b.bel_sum[1] + oi.bel1
      local jb = 1 + 0.3 * random()
      if oi.sur0 > 0.5 and oi.ask0 * jb < b.best_ask[0] then
        b.best[0], b.best_ask[0] = i, oi.ask0 * jb
      end
      if oi.sur1 > 0.05 and oi.ask1 * jb < b.best_ask[1] then
        b.best[1], b.best_ask[1] = i, oi.ask1 * jb
      end
      if random() * nb < 1 then b.cand = i end
      if oi.money > b.rich_m then
        b.rich_m, b.rdx, b.rdy = oi.money, -dx, -dy
      end
      b.kdx, b.kdy, b.px, b.py = b.kdx - dx * kw, b.kdy - dy * kw, b.px + dx * pw, b.py + dy * pw
    end
  until at >= NC

  for s = 0, pop - 1 do
    local i = cell_items[s]
    local u, a = U[i], SC[i]
    local g, cell = u.g, u.cell
    local cx = band(cell, GMASK)
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
  local at = start % pop
  stride = stride % pop
  for _ = 0, pop - 1 do
    local i = cell_items[at]
    at = at + stride
    if at >= pop then at = at - pop end
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
        if trk then
          led(best, CH.SELL, cost)
          led(i, CH.BUY, -cost)
        end
        c_trades, c_volume = c_trades + 1, c_volume + cost
        REF[2 + k], REF[4 + k] = REF[2 + k] + qty, REF[4 + k] + cost
        TOT.trades, TOT.volume = TOT.trades + 1, TOT.volume + cost
        c_tool_vol = c_tool_vol + cost * k
        if want then
          -- floored like every other belief update: a seller asking below the floor could otherwise drag a buyer under it
          u.belief[k] = max(0.05, u.belief[k] + (ask - u.belief[k]) * 0.3 * (1 - u.stubborn))
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
  local at = start % pop
  local offer, cap_rate = 0.05 * M.knobs.lending, M.knobs.usury
  stride = stride % pop
  for _ = 0, pop - 1 do
    local i = cell_items[at]
    at = at + stride
    if at >= pop then at = at - pop end
    local u = U[i]
    local g, cand = u.g, SC[i].cand
    if u.alive == 1 and cand >= 0 and u.nloans < 4 and nfree_loans > 0 and random() < g[INVEST] * offer then
      local spare = u.money - u.belief[FOOD] * upkeep_of(g) * (20 + 200 * g[RESERVE])
      local amount = floor(spare * (0.1 + 0.4 * g[INVEST]))
      local o = U[cand]
      local rate = min(cap_rate, 0.05 + 0.5 * g[GREED])
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
        if trk then
          led(i, CH.CREDIT, -amount)
          led(cand, CH.DEBT, amount)
        end
        c_loans = c_loans + 1
        flash(o.x, o.y, 4)
      end
    end
  end
end

-- gated on money, so enclosure is a rich unit's move: the barrier to entry is the mechanism, not a side effect
local function phase_claim(pop)
  local rate, price = 0.02 * M.knobs.enclosure, M.knobs.land_price
  for s = 0, pop - 1 do
    local i = cell_items[s]
    local u = U[i]
    if u.alive == 1 and u.ncells < MAXCELLS and u.money >= price and random() < u.g[LAND] * rate then
      local best, bv = -1, -1
      if u.g[SPECULATE] > 0.5 then
        local cx, cy = band(u.cell, GMASK), floor(u.cell * INV_GRID)
        for n = 0, 8 do
          local c = band(cy + off_y[n], GMASK) * GRID + band(cx + off_x[n], GMASK)
          if own[c] < 0 and res[c] + res[NC + c] > bv then
            best, bv = c, res[c] + res[NC + c]
          end
        end
      elseif own[u.cell] < 0 then
        best = u.cell
      end
      if best >= 0 and land_give(best, i) then
        u.money, commons = u.money - price, commons + price
        LND.claims = LND.claims + 1
        if trk then led(i, CH.LAND, -price) end
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
      u.x, u.y = x - W * floor(x * INV_W), y - W * floor(y * INV_W)
      -- W minus a hair rounds up to W in float32 storage
      if u.x >= W then u.x = 0 end
      if u.y >= W then u.y = 0 end
      u.age = u.age + 1
      if u.age > 3000 and random() < 0.002 then
        c_aged, TOT.aged = c_aged + 1, TOT.aged + 1
        kill(i, u, 2)
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
      c.money, c.capital, c.cell, c.dyn = floor(u.money * frac), u.capital * frac, at, u.dyn
      u.money, u.capital = u.money - c.money, u.capital - c.capital
      if trk then
        led(ci, CH.FOUND, c.money)
        led(i, CH.STAKE, -c.money)
        -- the rank the child is born into, kept for the mobility table it will land in when it dies
        TR[ci].ppct, TR[i].kids = TR[i].cur, TR[i].kids + 1
      end
      -- fixed food stake paid from surplus: births limited by food, not by infants starving
      c.stock[FOOD], c.stock[TOOLS], c.belief[FOOD], c.belief[TOOLS] = 60, u.stock[TOOLS] * frac, u.belief[FOOD], u.belief[TOOLS]
      u.stock[FOOD], u.stock[TOOLS] = u.stock[FOOD] - 60, u.stock[TOOLS] - c.stock[TOOLS]
      u.surplus[FOOD], u.surplus[TOOLS] = u.surplus[FOOD] - 60, min(u.surplus[TOOLS], u.stock[TOOLS])
      u.heir, u.heir_gen = ci, c.gen
      paint(c)
      c_births, TOT.births = c_births + 1, TOT.births + 1
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
        if trk and pay ~= 0 then
          led(l.borrower, CH.DEBT, -pay)
          led(l.lender, CH.CREDIT, pay)
        end
        if l.owed <= 0 then
          close_loan(li, l, le)
        elseif b.alive == 2 or tick > l.expiry then
          b.debt, b.default_tick = b.debt - l.owed, tick
          -- the lender takes land rather than nothing, which is how default concentrates ownership instead of just destroying credit
          if enc and b.ncells > 0 and le.ncells < MAXCELLS and le.alive == 1 then
            local c = cells[l.borrower * MAXCELLS + b.ncells - 1]
            land_drop(c)
            land_give(c, l.lender)
            LND.foreclosed = LND.foreclosed + 1
          end
          c_defaults, TOT.defaults = c_defaults + 1, TOT.defaults + 1
          flash(le.x, le.y, 3)
          close_loan(li, l, le)
        end
      end
    end
  end
end

-- wealth rank in fifths; 1 is the poorest fifth of the living at the last compute_stats()
local function quint(p) return max(1, min(5, floor(p * 5) + 1)) end

-- lifetime aggregates over everyone who has died: the only place a whole life can be summarised
function M.reset_deaths()
  local d = { n = 0, founders = 0, cause = { 0, 0 }, mob = {}, q = {} }
  for p = 1, 5 do
    d.mob[p] = { 0, 0, 0, 0, 0 }
  end
  for q = 1, 5 do
    local chan = {}
    for c = 1, NCHAN do
      chan[c] = 0
    end
    d.q[q] = { n = 0, age = 0, kids = 0, chan = chan }
  end
  M.deaths = d
end

-- one row per death, for whatever you want to plot; the in-memory aggregates above answer most of it
function M.open_death_log(path)
  local f = assert(io.open(path, "w"))
  f:write("tick,born,age,dynasty,cause,parent_pct,peak_pct,kids,money")
  for _, name in ipairs(M.CHANNELS) do
    f:write(",", name)
  end
  f:write("\n")
  M.death_log = f
  return f
end

local DEATH_ROW = "%d,%d,%d,%d,%s,%.4f,%.4f,%d,%.0f," .. ("%.0f,"):rep(NCHAN - 1) .. "%.0f\n"

local function record_death(i, u, why)
  local t, d = TR[i], M.deaths
  local q = quint(t.peak)
  local row = d.q[q]
  d.n, d.cause[why] = d.n + 1, d.cause[why] + 1
  row.n, row.age, row.kids = row.n + 1, row.age + u.age, row.kids + t.kids
  for c = 1, NCHAN do
    row.chan[c] = row.chan[c] + t.chan[c - 1]
  end
  if t.ppct >= 0 then
    local p = quint(t.ppct)
    d.mob[p][q] = d.mob[p][q] + 1
  else
    d.founders = d.founders + 1
  end
  local f = M.death_log
  if f then f:write(DEATH_ROW:format(tick, t.born, u.age, u.dyn, M.CAUSES[why], t.ppct, t.peak, t.kids, u.money, t.chan[0], t.chan[1], t.chan[2], t.chan[3], t.chan[4], t.chan[5], t.chan[6], t.chan[7], t.chan[8])) end
end

local function bury()
  for k = 0, ndying - 1 do
    local i = dying[k]
    local u = U[i]
    if trk then record_death(i, u, dying_why[k]) end
    local estate = u.money
    local tax = floor(estate * M.knobs.estate_tax)
    commons, estate = commons + tax, estate - tax
    local h = u.heir
    local has_heir = h >= 0 and U[h].alive == 1 and U[h].gen == u.heir_gen
    if has_heir then
      local part = floor(estate * u.g[INHERIT])
      U[h].money, estate = U[h].money + part, estate - part
      if trk then led(h, CH.BEQUEST, part) end
    end
    -- land passes whole to the heir and is not split or taxed, so holdings compound down a line where money does not
    if enc then
      while u.ncells > 0 do
        local c = cells[i * MAXCELLS + u.ncells - 1]
        land_drop(c)
        if has_heir then land_give(c, h) end
      end
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
    if trk and share ~= 0 then
      for t = 0, nn - 1 do
        led(heirs[t], CH.SCATTER, share)
      end
    end
    estate = estate - share * nn
    commons = commons + estate
    if trk then ffi.fill(TR + i, TRK_BYTES) end
    u.money, u.alive, u.gen = 0, 0, u.gen + 1
    free_units[nfree] = i
    nfree = nfree + 1
    -- swap-remove keeps live[] dense; order is not index order, but it is reproducible
    local at, last = live_at[i], live[nlive - 1]
    nlive = nlive - 1
    live[at], live_at[last] = last, at
  end
  ndying = 0
end

function M.tick()
  tick = tick + 1
  build_grid()
  local ce = M.knobs.compact_every
  if ce > 0 and tick % ce == 0 then compact() end

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
    before = dbg and M.totals()
    if enc then phase_claim(pop) end
    if dbg then M.check_conserved("claim", before, M.totals(), true) end
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
    local alive = CAP - nfree
    local per = alive > 0 and floor(commons / alive) or 0
    if per > 0 then
      for s = 0, nlive - 1 do
        local u = U[live[s]]
        u.money = u.money + per
      end
      if trk then
        for s = 0, nlive - 1 do
          led(live[s], CH.DIVIDEND, per)
        end
      end
      commons = commons - per * alive
    end
  end
  -- eased rather than replaced: a thin tick's few trades must not swing what every tenant is charged
  for k = 0, 1 do
    if REF[2 + k] > 0 then REF[k] = REF[k] * 0.9 + REF[4 + k] / REF[2 + k] * 0.1 end
    REF[2 + k], REF[4 + k] = 0, 0
  end
  if trk and (tick % 30 == 0 or tick == 1) then update_ranks() end
end

-- every debt forgiven where it stands. No money moves, so the supply is untouched; the lenders simply never see it again
function M.jubilee()
  local n = 0
  for li = 0, loan_hi - 1 do
    local l = L[li]
    if l.active == 1 then
      local le = U[l.lender]
      U[l.borrower].debt = U[l.borrower].debt - l.owed
      close_loan(li, l, le)
      n = n + 1
    end
  end
  return n
end

function M.trigger_shock(x, y)
  local sh = M.shock
  sh.x, sh.y, sh.r, sh.ttl = x or random() * W, y or random() * W, 150 + random() * 250, 400
end

function M.check_money()
  local sum = commons
  for s = 0, nlive - 1 do
    sum = sum + U[live[s]].money
  end
  assert(sum == supply, ("money leak at tick %d: %.0f ~= %.0f"):format(tick, sum, supply))
end

-- net worth at the going (median-belief) prices; drives circle size, gini and the histogram
function M.worth(u)
  local s = M.stats
  return max(0, u.money + u.lent - u.debt + u.stock[0] * (s.price or 10) + (u.stock[1] + u.capital) * (s.tool_price or 20))
end

-- Order statistics over a sample, not the whole population. Sorting three Lua tables of a
-- quarter-million entries cost more than a tick and grew the Lua heap into the hundreds of MB;
-- these FFI buffers are fixed-size and allocation-free. Below SAMPLE units nothing is sampled,
-- so the small worlds this started as still report exact figures.
local SAMPLE = 16384
local sw, sp, st = ffi.new("double[?]", SAMPLE), ffi.new("double[?]", SAMPLE), ffi.new("double[?]", SAMPLE)
local rw = ffi.new("double[?]", SAMPLE)
local gsum = ffi.new("double[?]", NG)
local LOG10 = log(10)

local function insertion(a, lo, hi)
  for i = lo + 1, hi do
    local v, j = a[i], i - 1
    while j >= lo and a[j] > v do
      a[j + 1] = a[j]
      j = j - 1
    end
    a[j + 1] = v
  end
end

-- introsort on a double array. Deliberately does not use math.random for its pivot: stats are
-- computed between ticks, and drawing from the sim's RNG stream there would make the trajectory
-- depend on how often the caller asked for stats.
local function sortd(a, lo, hi)
  while hi - lo > 24 do
    local mid = lo + floor((hi - lo) / 2)
    if a[mid] < a[lo] then
      a[mid], a[lo] = a[lo], a[mid]
    end
    if a[hi] < a[lo] then
      a[hi], a[lo] = a[lo], a[hi]
    end
    if a[hi] < a[mid] then
      a[hi], a[mid] = a[mid], a[hi]
    end
    local p, i, j = a[mid], lo, hi
    repeat
      while a[i] < p do
        i = i + 1
      end
      while a[j] > p do
        j = j - 1
      end
      if i <= j then
        a[i], a[j] = a[j], a[i]
        i, j = i + 1, j - 1
      end
    until i > j
    -- recurse into the smaller half, iterate on the larger: bounds stack depth at log2(n)
    if j - lo < hi - i then
      sortd(a, lo, j)
      lo = i
    else
      sortd(a, i, hi)
      hi = j
    end
  end
  insertion(a, lo, hi)
end

-- sampled by the tick, not by the host: an unsampled peak rank reads as zero rather than as missing, which would turn the mobility table into fiction
update_ranks = function()
  local s = M.stats
  local pf, pt = s.price or 10, s.tool_price or 20
  local stride = max(1, ceil(nlive / SAMPLE))
  local m, n = 0, 0
  for k = 0, nlive - 1 do
    local u = U[live[k]]
    if u.alive == 1 then
      if n % stride == 0 and m < SAMPLE then
        rw[m] = max(0, u.money + u.lent - u.debt + u.stock[0] * pf + (u.stock[1] + u.capital) * pt)
        m = m + 1
      end
      n = n + 1
    end
  end
  if m == 0 then return end
  sortd(rw, 0, m - 1)
  local inv = 0.5 / m
  for k = 0, nlive - 1 do
    local i = live[k]
    local u = U[i]
    if u.alive == 1 then
      local w = max(0, u.money + u.lent - u.debt + u.stock[0] * pf + (u.stock[1] + u.capital) * pt)
      local lo, hi = 0, m
      while lo < hi do
        local mid = floor((lo + hi) / 2)
        if rw[mid] < w then
          lo = mid + 1
        else
          hi = mid
        end
      end
      local lo2 = lo
      hi = m
      while lo2 < hi do
        local mid = floor((lo2 + hi) / 2)
        if rw[mid] <= w then
          lo2 = mid + 1
        else
          hi = mid
        end
      end
      -- the tie block's midpoint: a field of equals must rank in the middle, not all at the top
      local t = TR[i]
      t.cur = (lo + lo2) * inv
      if t.cur > t.peak then t.peak = t.cur end
    end
  end
end

function M.compute_stats()
  local s = M.stats
  local n, debt, artisans, capital, stubborn = 0, 0, 0, 0, 0
  local bins = s.wealth_bins
  ffi.fill(gsum, NG * 8)
  for b = 1, 24 do
    bins[b] = 0
  end
  -- worth is valued at the previous pass's prices, as it always was: this pass sets the new ones
  local pf, pt = s.price or 10, s.tool_price or 20
  local stride = max(1, ceil(nlive / SAMPLE))
  local m = 0
  ffi.fill(dcount, (ndyn + 1) * 4)
  ffi.fill(dworth, (ndyn + 1) * 8)
  for k = 0, nlive - 1 do
    local u = U[live[k]]
    if u.alive == 1 then
      local w = max(0, u.money + u.lent - u.debt + u.stock[0] * pf + (u.stock[1] + u.capital) * pt)
      if n % stride == 0 and m < SAMPLE then
        sw[m], sp[m], st[m] = w, u.belief[FOOD], u.belief[TOOLS]
        m = m + 1
      end
      local dy = u.dyn
      dcount[dy], dworth[dy] = dcount[dy] + 1, dworth[dy] + w
      n = n + 1
      capital = capital + u.capital
      if u.g[CRAFT] > 0.5 then artisans = artisans + 1 end
      stubborn = stubborn + u.stubborn
      debt = debt + u.debt
      for g = 0, NG - 1 do
        gsum[g] = gsum[g] + u.g[g]
      end
      local b = min(24, 1 + floor(log(w + 1) / LOG10 * 4))
      bins[b] = bins[b] + 1
    end
  end

  if m > 0 then
    sortd(sp, 0, m - 1)
    sortd(st, 0, m - 1)
    sortd(sw, 0, m - 1)
  end
  local mid = floor(m / 2)
  s.price = m > 0 and sp[mid] or 0
  s.tool_price = m > 0 and st[mid] or 0
  s.median_worth = max(1, m > 0 and sw[mid] or 1)
  s.artisans, s.capital, s.stubborn = artisans, n > 0 and capital / n or 0, stubborn

  local cum, total = 0, 0
  for k = 0, m - 1 do
    cum, total = cum + (k + 1) * sw[k], total + sw[k]
  end
  s.gini = (m > 0 and total > 0) and min(1, max(0, 2 * cum / (m * total) - (m + 1) / m)) or 0
  local top = 0
  for k = max(0, m - floor(m / 100)), m - 1 do
    top = top + sw[k]
  end
  s.top1 = total > 0 and top / total or 0

  -- how much of the map one founding line now holds: what selection is actually maximising, unlike money
  local lines, big, bigw, allw = 0, 0, 0, 0
  for d = 1, ndyn do
    local c = dcount[d]
    allw = allw + dworth[d]
    if c > 0 then
      lines = lines + 1
      if c > big then
        big, bigw = c, dworth[d]
      end
    end
  end
  s.lines, s.top_line, s.top_line_worth = lines, n > 0 and big / n or 0, allw > 0 and bigw / allw or 0

  -- landless is the number that matters: owning nothing is the condition enclosure creates
  local held, lords, biggest = 0, 0, 0
  if enc then
    for k = 0, nlive - 1 do
      local u = U[live[k]]
      if u.alive == 1 and u.ncells > 0 then
        held, lords = held + u.ncells, lords + 1
        if u.ncells > biggest then biggest = u.ncells end
      end
    end
  end
  s.owned, s.landlords, s.landless, s.biggest_holding = held / NC, lords, n - lords, biggest

  local means = s.means or {}
  for k = 1, NG do
    means[k] = n > 0 and gsum[k - 1] / n or 0
  end
  s.pop, s.debt, s.means, s.tick, s.commons = n, debt, means, tick, commons
  s.nloans = MAXLOANS - nfree_loans
  s.births, s.starved, s.aged, s.defaults = c_births, c_starved, c_aged, c_defaults
  -- the per-30-tick counters above are zeroed here, so anything comparing whole runs needs these
  s.tot_births, s.tot_starved, s.tot_aged, s.tot_defaults, s.tot_trades, s.tot_volume = TOT.births, TOT.starved, TOT.aged, TOT.defaults, TOT.trades, TOT.volume
  s.trades, s.volume, s.new_loans, s.spec, s.tool_volume = c_trades, c_volume, c_loans, c_spec, c_tool_vol
  s.rent, s.claims, s.foreclosed = LND.rent, LND.claims, LND.foreclosed
  s.ref_price, s.ref_tool = REF[0], REF[1]
  c_spec, c_tool_vol = 0, 0
  LND.rent, LND.claims, LND.foreclosed = 0, 0, 0
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
function M.tick_count() return tick end

-- renderer walks these instead of all CAP slots
function M.live_set() return live, nlive end
function M.fields() return opp, sup, dem, res end

-- the biography of one slot, or nil when --track is off
function M.bio(i) return trk and i >= 0 and TR[i] or nil end
function M.tracking() return trk end
function M.NCHAN() return NCHAN end

---------------------------------------------------------------------------------------------------
-- Assertions. Static ones run at load; state ones run per phase when M.debug, and in M.selftest().
---------------------------------------------------------------------------------------------------
local function check(cond, fmt, ...)
  if not cond then error(("sim invariant violated at tick %d: " .. fmt):format(tick, ...), 2) end
end
local function finite(v) return v == v and v > -math.huge and v < math.huge end
local function whole(v) return v == floor(v) end
local function pow2(v) return v > 0 and band(v, v - 1) == 0 end

check_static = function()
  check(pow2(CAP) and pow2(GRID) and pow2(NFLASH), "cap/grid and NFLASH must be powers of two (band() masks depend on it)")
  check(MASK == CAP - 1 and GMASK == GRID - 1 and NC == GRID * GRID and W == GRID * CELL, "derived constants out of sync")
  check(R2 <= CELL * CELL, "interaction radius %g exceeds cell size %d: the 3x3 scan would miss neighbours", sqrt(R2), CELL)
  check(#M.GENES == NG, "GENES has %d names for %d genes", #M.GENES, NG)
  check(ffi.sizeof("unit_t") > 0 and ffi.sizeof(U[0].g) == NG * 4, "unit_t.g holds %d floats, NG is %d", ffi.sizeof(U[0].g) / 4, NG)
  local idx = { PROD, RESERVE, GREED, HERD, THRIFT, INVEST, RISK, TRUST, SPEED, SEEK_RICH, SEEK_KIN, MIGRATE, REPRO, ENDOW, INHERIT, BORROW, BUILD, SPECULATE, PEDDLE, CRAFT, LAND }
  check(#idx == NG, "%d gene index constants for %d genes", #idx, NG)
  local seen = {}
  for _, k in ipairs(idx) do
    check(k >= 0 and k < NG and not seen[k], "gene index %d out of range or duplicated", k)
    seen[k] = true
  end
  check(#PRIMES == 5, "%d visit strides, expected 5", #PRIMES)
  for _, p in ipairs(PRIMES) do
    check(p > CAP and is_prime(p), "stride %d must be a prime above cap so it is coprime with every population size", p)
  end
  check(MAXPAIRS >= 9, "pair buffer holds %d, too small for one unit's neighbourhood", MAXPAIRS)
  check(ffi.sizeof(hist) == (4 + NG) * HN * 4, "hist buffer does not match 4 + NG series")
  check(ffi.sizeof(res) == NC * 2 * 4 and ffi.sizeof(opp) == ffi.sizeof(res) and ffi.sizeof(sup) == ffi.sizeof(res) and ffi.sizeof(dem) == ffi.sizeof(res), "field buffers must hold 2 goods x NC cells")
  check(TERM > 0, "TERM must be positive")
  check(FOOD == 0 and TOOLS == 1, "goods are indexed 0/1 by phase_trade and the k=0,NC,NC field loops")
  check(CARRY[0] > MINQ[0] and CARRY[1] > MINQ[1], "CARRY must exceed MINQ or speculation can never trade")
  check(W * INV_W == 1 and CELL * INV_CELL == 1 and GRID * INV_GRID == 1, "reciprocal constants do not invert their divisors exactly")
end

function M.check_knobs()
  local k = M.knobs
  check(pow2(k.cap) and k.cap <= 2 ^ 26, "knob cap=%g must be a power of two, at most %d", k.cap, 2 ^ 26)
  check(pow2(k.grid) and k.grid >= 4, "knob grid=%g must be a power of two, at least 4", k.grid)
  check(whole(k.compact_every) and k.compact_every >= 0, "knob compact_every=%g must be a whole number", k.compact_every)
  check(pow2(k.cell) and k.cell >= 4, "knob cell=%g must be a power of two, at least 4 (exact reciprocals)", k.cell)
  check(k.cap <= k.grid * k.grid * 64, "cap=%g units will not fit in %d cells; raise grid", k.cap, k.grid * k.grid)
  check(whole(k.pop) and k.pop >= 1 and k.pop <= k.cap, "knob pop=%g must be an integer in 1..%d", k.pop, k.cap)
  check(whole(k.money) and k.money >= 1 and k.pop * k.money < 2 ^ 52, "knob money=%g must be a positive integer (supply stays exact in a double)", k.money)
  check(k.artisans >= 0 and k.artisans <= 1, "knob artisans=%g outside [0,1]", k.artisans)
  check(k.yield > 0 and k.toolrate > 0, "knobs yield=%g toolrate=%g must be positive", k.yield, k.toolrate)
  check(k.mut > 0 and k.mut <= 0.5, "knob mut=%g outside (0, 0.5]", k.mut)
  check(k.estate_tax >= 0 and k.estate_tax <= 1, "knob estate_tax=%g outside [0,1]", k.estate_tax)
  check(k.shock_every >= 0, "knob shock_every=%g negative", k.shock_every)
  check(k.stubborn_founders >= 0 and k.stubborn_founders <= 1, "knob stubborn_founders=%g outside [0,1]", k.stubborn_founders)
  check(k.stubborn_birth >= 0 and k.stubborn_birth <= 1, "knob stubborn_birth=%g outside [0,1]", k.stubborn_birth)
  check(k.track == 0 or k.track == 1, "knob track=%g must be 0 or 1", k.track)
  check(k.lending >= 0 and k.lending <= 1, "knob lending=%g outside [0,1]", k.lending)
  check(k.usury > 0, "knob usury=%g must be positive", k.usury)
  check(k.enclosure >= 0 and k.enclosure <= 1, "knob enclosure=%g outside [0,1]", k.enclosure)
  check(k.rent >= 0 and k.rent < 1, "knob rent=%g outside [0,1)", k.rent)
  check(whole(k.land_price) and k.land_price >= 1, "knob land_price=%g must be a positive integer", k.land_price)
  check(whole(k.max_holding) and k.max_holding >= 1 and k.max_holding <= 64, "knob max_holding=%g must be a whole number in 1..64", k.max_holding)
end

function M.totals()
  local t = { money = commons, food = 0, tools = 0, capital = 0, pop = 0 }
  for s = 0, nlive - 1 do
    local u = U[live[s]]
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
  check(nlive == CAP - nfree, "live list holds %d, %d slots are in use", nlive, CAP - nfree)
  for s = 0, nlive - 1 do
    local i = live[s]
    check(live_at[i] == s, "live_at[%d]=%d but it sits at %d", i, live_at[i], s)
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
      check(band(floor(u.y * INV_CELL), GMASK) * GRID + band(floor(u.x * INV_CELL), GMASK) == c, "unit %d at (%.1f,%.1f) filed under cell %d", i, u.x, u.y, c)
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

-- lazily sized: only runs that actually call validate() pay for these
local v_debt, v_lent, v_nl, v_n = nil, nil, nil, 0

-- full state audit; valid between ticks
function M.validate()
  M.check_knobs()
  check(commons >= 0 and whole(commons), "commons=%g must be a non-negative integer", commons)
  check(nfree >= 0 and nfree <= CAP and nfree_loans >= 0 and nfree_loans <= MAXLOANS, "free counters out of range")
  check(ndying == 0, "%d units left unburied", ndying)
  check(loan_hi >= 0 and loan_hi <= MAXLOANS, "loan_hi=%d", loan_hi)

  local alive, money = 0, commons
  -- FFI, not Lua tables keyed by unit index: at continental cap the hash tables alone ran to
  -- hundreds of MB, which put the full audit out of reach on exactly the runs that need it
  if v_n ~= CAP then
    v_debt, v_lent, v_nl, v_n = ffi.new("double[?]", CAP), ffi.new("double[?]", CAP), ffi.new("int32_t[?]", CAP), CAP
  end
  local debt, lent, nl = v_debt, v_lent, v_nl
  ffi.fill(nl, CAP * 4)
  ffi.fill(debt, CAP * 8)
  ffi.fill(lent, CAP * 8)
  for i = 0, MASK do
    local u = U[i]
    check(u.alive <= 1, "unit %d alive=%d between ticks", i, u.alive)
    if u.alive == 0 then
      check(u.money == 0, "dead slot %d still holds %.0f money", i, u.money)
      if trk then
        for c = 0, NCHAN - 1 do
          check(TR[i].chan[c] == 0, "dead slot %d still carries %s %.0f", i, M.CHANNELS[c + 1], TR[i].chan[c])
        end
      end
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
      check(u.dyn >= 1 and u.dyn <= ndyn, "unit %d dynasty=%d outside 1..%d founders", i, u.dyn, ndyn)
      if trk then
        local t, sum = TR[i], 0
        for c = 0, NCHAN - 1 do
          check(finite(t.chan[c]) and whole(t.chan[c]), "unit %d channel %s=%g must be a whole number", i, M.CHANNELS[c + 1], t.chan[c])
          sum = sum + t.chan[c]
        end
        -- exhaustive by construction: any transfer that forgot its ledger entry shows up here
        check(sum == u.money, "unit %d holds %.0f but its channels account for %.0f", i, u.money, sum)
        check(t.peak >= 0 and t.peak <= 1 and t.cur >= 0 and t.cur <= 1 and t.peak >= t.cur - 1e-6, "unit %d rank cur=%g peak=%g", i, t.cur, t.peak)
        check(t.ppct >= -1 and t.ppct <= 1 and t.born >= 0 and t.born <= tick and t.kids >= 0, "unit %d biography (parent %g, born %d, kids %d)", i, t.ppct, t.born, t.kids)
      end
      for k = 0, 1 do
        check(finite(u.stock[k]) and u.stock[k] >= -1e-3, "unit %d stock[%d]=%g", i, k, u.stock[k])
        check(finite(u.belief[k]) and u.belief[k] >= 0.049, "unit %d belief[%d]=%g", i, k, u.belief[k])
        check(finite(u.ask[k]) and u.ask[k] >= 0 and finite(u.surplus[k]), "unit %d ask/surplus[%d] not finite", i, k)
        check(u.surplus[k] <= u.stock[k] + 1e-3, "unit %d offers more of good %d (%g) than it holds (%g)", i, k, u.surplus[k], u.stock[k])
      end
      for k = 0, NG - 1 do
        check(u.g[k] >= 0 and u.g[k] <= 1, "unit %d gene %s=%g outside [0,1]", i, M.GENES[k + 1], u.g[k])
      end
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
  for k = 0, nlive - 1 do
    local i = live[k]
    check(U[i].debt == debt[i], "unit %d debt %.0f ~= %.0f owed on its loans", i, U[i].debt, debt[i])
    check(U[i].lent == lent[i], "unit %d lent %.0f ~= %.0f owed to it", i, U[i].lent, lent[i])
    check(U[i].nloans == nl[i], "unit %d nloans %d ~= %d loans it holds", i, U[i].nloans, nl[i])
  end

  -- the two sides of ownership are stored separately for speed, so prove they still agree
  if enc then
    local held = 0
    for c = 0, NC - 1 do
      local o = own[c]
      check(o >= -1 and o < CAP, "cell %d owned by slot %d", c, o)
      if o >= 0 then
        held = held + 1
        check(U[o].alive == 1, "cell %d is owned by dead slot %d", c, o)
        local found = false
        for k = 0, U[o].ncells - 1 do
          if cells[o * MAXCELLS + k] == c then found = true end
        end
        check(found, "cell %d says slot %d owns it, but that unit does not list it", c, o)
      end
    end
    local listed = 0
    for k = 0, nlive - 1 do
      local i = live[k]
      local u = U[i]
      check(u.ncells <= MAXCELLS, "unit %d holds %d cells, over the cap of %d", i, u.ncells, MAXCELLS)
      listed = listed + u.ncells
      for a = 0, u.ncells - 1 do
        local c = cells[i * MAXCELLS + a]
        check(c >= 0 and c < NC and own[c] == i, "unit %d lists cell %d, which is owned by %d", i, c, c >= 0 and c < NC and own[c] or -2)
        for b = 0, a - 1 do
          check(cells[i * MAXCELLS + b] ~= c, "unit %d lists cell %d twice", i, c)
        end
      end
    end
    check(held == listed, "%d cells name an owner but %d are listed by their owners", held, listed)
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
  check(s.lines >= (alive > 0 and 1 or 0) and s.lines <= min(alive, ndyn), "%d surviving lines among %d units", s.lines, alive)
  check(finite(REF[0]) and REF[0] > 0 and finite(REF[1]) and REF[1] > 0, "reference prices %g / %g must stay positive: rent is charged at them", REF[0], REF[1])
  check(not enc or (s.owned >= 0 and s.owned <= 1 and s.landlords + s.landless == alive), "%d landlords + %d landless ~= %d alive", s.landlords, s.landless, alive)
  check(s.top_line >= 0 and s.top_line <= 1 + 1e-9 and s.top_line_worth >= 0 and s.top_line_worth <= 1 + 1e-9, "line shares %g / %g", s.top_line, s.top_line_worth)
  local d = M.deaths
  check(d.n == d.cause[1] + d.cause[2], "%d deaths recorded, %d by cause", d.n, d.cause[1] + d.cause[2])
  check(not trk or d.n == TOT.starved + TOT.aged, "%d deaths recorded, %d units died", d.n, TOT.starved + TOT.aged)
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

-- a fresh copy, so a runner sweeping several configurations in one process can get back to zero
function M.defaults()
  local out = {}
  for k, v in pairs(DEFAULTS) do
    out[k] = v
  end
  return out
end

-- knobs the command line set explicitly, so a scenario can be overridden from the shell but not silently
M.knobs_set = {}

local function fingerprint()
  local h = commons + tick
  for i = 0, MASK do
    local u = U[i]
    if u.alive == 1 then h = (h * 31 + u.money + floor(u.x * 64) + floor(u.y * 64) * 3 + floor(u.stock[0] * 16) + u.ncells * 7 + i) % 2147483647 end
  end
  return h
end

-- the stats sort is hand-rolled, so prove it rather than trust it: duplicates, negatives,
-- already-sorted and reversed runs all hit different paths through the partition
local function check_sort()
  local N = 1000
  local probe = ffi.new("double[?]", N)
  local pats = {
    function(k) return (k * 97) % 23 - 11 end,
    function(k) return k end,
    function(k) return N - k end,
    function(_) return 7 end,
    function(k) return k < N / 2 and 1 or 0 end,
  }
  for pi, f in ipairs(pats) do
    local sum = 0
    for k = 0, N - 1 do
      probe[k] = f(k)
      sum = sum + probe[k]
    end
    sortd(probe, 0, N - 1)
    local out = 0
    for k = 0, N - 1 do
      out = out + probe[k]
      check(k == 0 or probe[k] >= probe[k - 1], "stats sort (pattern %d) left %g before %g", pi, probe[k - 1], probe[k])
    end
    check(out == sum, "stats sort (pattern %d) changed the multiset: %g -> %g", pi, sum, out)
  end
end

-- short audited run; call before opening a window so a broken build fails at startup, not mid-demo
function M.selftest(ticks)
  check_sort()
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
        local flag, h = n:gsub("_", "-"), M.KNOB_HELP[n] or extras[n]
        io.stderr:write(("  --%-18s %s%s\n"):format(flag, type(h) == "table" and h[1] or h, DEFAULTS[n] and (" (default %s)"):format(DEFAULTS[n]) or ""))
      end
      os.exit(key == "help" and 0 or 2)
    end
    -- an extra declared as a table takes text; everything else must be a number, silently-ignored typos being the worse failure
    if type(extras[key]) == "table" then
      out[key] = val
    else
      local num = tonumber(val)
      if val == "" then num = 1 end
      if not num then
        io.stderr:write(("--%s needs a number, got '%s'\n"):format(key, val))
        os.exit(2)
      end
      if M.knobs[key] ~= nil then
        M.knobs[key], M.knobs_set[key] = num, true
      else
        out[key] = num
      end
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
