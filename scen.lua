-- data, not code, so the same file can be watched in the window and measured over many seeds by run.lua
local sim = require("sim")

local M = {}

local EVENT_KEYS = { at = true, arm = true, set = true, shock = true, say = true, hold = true, jubilee = true }
-- everything allocated in init(): setting one mid-run would not do what the scenario author meant
local FROZEN = { cap = true, grid = true, cell = true, pop = true, money = true, artisans = true, track = true, compact_every = true }

local function fail(fmt, ...) error(("scenario: " .. fmt):format(...), 0) end

local function check_knobs(where, t)
  if type(t) ~= "table" then fail("%s must be a table of knobs", where) end
  for k, v in pairs(t) do
    if sim.knobs[k] == nil then fail("%s sets unknown knob '%s'", where, tostring(k)) end
    if type(v) ~= "number" then fail("%s sets %s to a %s, not a number", where, k, type(v)) end
  end
end

function M.load(path)
  local chunk, err = loadfile(path)
  if not chunk then fail("%s", err) end
  local ok, sc = pcall(chunk)
  if not ok then fail("%s", sc) end
  if type(sc) ~= "table" then fail("%s did not return a table", path) end

  sc.name = sc.name or path:match("([^/]+)%.lua$") or path
  sc.about = sc.about or ""
  sc.ticks = sc.ticks or 3000
  sc.knobs = sc.knobs or {}
  sc.arms = sc.arms or { { name = "only" } }
  sc.events = sc.events or {}
  check_knobs("scenario knobs", sc.knobs)

  local seen = {}
  for n, a in ipairs(sc.arms) do
    if type(a.name) ~= "string" then fail("arm %d has no name", n) end
    if seen[a.name] then fail("two arms are both called '%s'", a.name) end
    seen[a.name], a.knobs = true, a.knobs or {}
    check_knobs(("arm '%s'"):format(a.name), a.knobs)
    a.timeline = {}
  end

  for n, e in ipairs(sc.events) do
    for k in pairs(e) do
      if not EVENT_KEYS[k] then fail("event %d has unknown field '%s'", n, tostring(k)) end
    end
    if type(e.at) ~= "number" or e.at < 1 or e.at % 1 ~= 0 then fail("event %d needs a whole tick 'at'", n) end
    if e.arm and not seen[e.arm] then fail("event %d fires on arm '%s', which does not exist", n, e.arm) end
    if e.set then
      check_knobs(("event %d"):format(n), e.set)
      for k in pairs(e.set) do
        if FROZEN[k] then fail("event %d sets %s, which only takes effect at init", n, k) end
      end
    end
    if e.shock and type(e.shock) ~= "table" and e.shock ~= true then fail("event %d shock must be true or {x=,y=}", n) end
    for _, a in ipairs(sc.arms) do
      if not e.arm or e.arm == a.name then a.timeline[#a.timeline + 1] = e end
    end
  end
  for _, a in ipairs(sc.arms) do
    table.sort(a.timeline, function(p, q) return p.at < q.at end)
  end
  return sc
end

function M.arm(sc, name)
  if not name then return sc.arms[1] end
  for _, a in ipairs(sc.arms) do
    if a.name == name then return a end
  end
  fail("no arm called '%s' (have %s)", name, M.arm_names(sc))
end

function M.arm_names(sc)
  local out = {}
  for _, a in ipairs(sc.arms) do
    out[#out + 1] = a.name
  end
  return table.concat(out, ", ")
end

-- defaults, then the scenario, then the arm, then anything named on the command line
function M.begin(sc, arm, seed)
  local k = sim.defaults()
  for _, src in ipairs({ sc.knobs, arm.knobs }) do
    for key, v in pairs(src) do
      k[key] = v
    end
  end
  for key in pairs(sim.knobs_set) do
    k[key] = sim.knobs[key]
  end
  for key, v in pairs(k) do
    sim.knobs[key] = v
  end
  sim.check_knobs()
  sim.init(seed)
  return { sc = sc, arm = arm, seed = seed, next = 1, caption = nil, until_tick = 0 }
end

-- per tick, not per frame: an event must land on its exact tick however many ticks a frame runs
function M.step(st, t)
  local tl = st.arm.timeline
  while st.next <= #tl and tl[st.next].at <= t do
    local e = tl[st.next]
    st.next = st.next + 1
    if e.set then
      for key, v in pairs(e.set) do
        sim.knobs[key] = v
      end
      sim.check_knobs()
    end
    if e.shock then sim.trigger_shock(type(e.shock) == "table" and e.shock.x or nil, type(e.shock) == "table" and e.shock.y or nil) end
    if e.jubilee then st.jubilees = (st.jubilees or 0) + sim.jubilee() end
    if e.say then
      st.caption, st.until_tick = e.say, t + (e.hold or 400)
    end
  end
  if t > st.until_tick then st.caption = nil end
end

return M
