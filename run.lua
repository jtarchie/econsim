-- headless ensemble: every arm of a scenario over the same set of seeds, then the paired difference
local sim = require("sim")
local scen = require("scen")

local sqrt, max, min = math.sqrt, math.max, math.min

local opt = sim.parse_args(arg, {
  scenario = { "path to a scenario file (required)" },
  arm = { "run only this arm" },
  csv = { "write one row per run here" },
  deaths = { "write one row per death here; implies --track=1" },
  seeds = "how many seeds per arm (default 8)",
  seed0 = "first seed (default 1)",
  ticks = "override the scenario's tick count",
  quiet = "suppress the per-run progress line",
})
if not opt.scenario then
  io.stderr:write("run.lua needs --scenario=scenarios/estate-tax.lua\n")
  os.exit(2)
end
local sc = scen.load(opt.scenario)
local ticks = opt.ticks or sc.ticks
local nseeds, seed0 = opt.seeds or 8, opt.seed0 or 1
local arms = opt.arm and { scen.arm(sc, opt.arm) } or sc.arms

-- the run-level numbers that end up in the table; everything else lives in the death records
local METRICS = { "pop", "gini", "top1", "lines", "top_line", "price", "tool_price", "median_worth", "capital", "artisans", "nloans", "debt", "tot_births", "tot_starved", "tot_defaults", "tot_volume" }

local csv
if opt.csv then
  csv = assert(io.open(opt.csv, "w"))
  csv:write("scenario,arm,seed,ticks")
  for _, m in ipairs(METRICS) do
    csv:write(",", m)
  end
  csv:write("\n")
end
if opt.deaths then
  sim.knobs.track, sim.knobs_set.track = 1, true
  sim.open_death_log(opt.deaths)
end

-- results[arm][metric][seed], plus the death aggregates summed over that arm's seeds
local results, death_agg = {}, {}

local function blank_deaths()
  local d = { n = 0, founders = 0, cause = { 0, 0 }, mob = {}, q = {} }
  for p = 1, 5 do
    d.mob[p] = { 0, 0, 0, 0, 0 }
  end
  for q = 1, 5 do
    local chan = {}
    for c = 1, #sim.CHANNELS do
      chan[c] = 0
    end
    d.q[q] = { n = 0, age = 0, kids = 0, chan = chan }
  end
  return d
end

local function fold_deaths(into, from)
  into.n, into.founders = into.n + from.n, into.founders + from.founders
  for c = 1, 2 do
    into.cause[c] = into.cause[c] + from.cause[c]
  end
  for p = 1, 5 do
    for q = 1, 5 do
      into.mob[p][q] = into.mob[p][q] + from.mob[p][q]
    end
  end
  for q = 1, 5 do
    local a, b = into.q[q], from.q[q]
    a.n, a.age, a.kids = a.n + b.n, a.age + b.age, a.kids + b.kids
    for c = 1, #sim.CHANNELS do
      a.chan[c] = a.chan[c] + b.chan[c]
    end
  end
end

local t_start = os.clock()
for _, a in ipairs(arms) do
  results[a.name], death_agg[a.name] = {}, blank_deaths()
  for _, m in ipairs(METRICS) do
    results[a.name][m] = {}
  end
  for k = 0, nseeds - 1 do
    local seed = seed0 + k
    local st = scen.begin(sc, a, seed)
    for t = 1, ticks do
      sim.tick()
      scen.step(st, t)
    end
    sim.compute_stats()
    local s = sim.stats
    for _, m in ipairs(METRICS) do
      results[a.name][m][k + 1] = s[m] or 0
    end
    fold_deaths(death_agg[a.name], sim.deaths)
    if csv then
      csv:write(('"%s","%s",%d,%d'):format(sc.name, a.name, seed, ticks))
      for _, m in ipairs(METRICS) do
        csv:write(",", ("%.6g"):format(s[m] or 0))
      end
      csv:write("\n")
    end
    if not opt.quiet then io.stderr:write(("  %-12s seed %-4d pop %6d  gini %.3f  lines %4d\n"):format(a.name, seed, s.pop, s.gini, s.lines)) end
  end
end
if csv then csv:close() end
if sim.death_log then sim.death_log:close() end

-- Student t at 95% by degrees of freedom: the normal 1.96 understates the interval badly at the seed counts anyone actually runs
local TCRIT = { 12.71, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.16, 2.145, 2.131, 2.12, 2.11, 2.101, 2.093, 2.086 }
local function tcrit(df) return df < 1 and 0 or (TCRIT[df] or 1.96) end

local function mean_ci(v)
  local n = #v
  if n == 0 then return 0, 0 end
  local sum = 0
  for _, x in ipairs(v) do
    sum = sum + x
  end
  local mu = sum / n
  if n < 2 then return mu, 0 end
  local ss = 0
  for _, x in ipairs(v) do
    ss = ss + (x - mu) ^ 2
  end
  return mu, tcrit(n - 1) * sqrt(ss / (n - 1) / n)
end

local function paired_diff(a, b)
  local d = {}
  for k = 1, min(#a, #b) do
    d[k] = b[k] - a[k]
  end
  return mean_ci(d)
end

local W = io.write
local function rule(ch) W((ch or "-"):rep(96), "\n") end

W("\n")
rule("=")
W(("%s -- %d seeds x %d ticks, %.1fs\n"):format(sc.name, nseeds, ticks, os.clock() - t_start))
if sc.about ~= "" then W(sc.about, "\n") end
rule("=")

W(("%-14s"):format("metric"))
for _, a in ipairs(arms) do
  W(("%18s"):format(a.name))
end
W("\n")
rule()
for _, m in ipairs(METRICS) do
  W(("%-14s"):format(m))
  for _, a in ipairs(arms) do
    local mu, ci = mean_ci(results[a.name][m])
    W(("%12s +-%5s"):format(("%.4g"):format(mu), ("%.3g"):format(ci)))
  end
  W("\n")
end

-- Arms share their seeds, so the difference is paired: the same world twice, one knob apart.
if #arms > 1 and nseeds > 1 then
  local base = arms[1].name
  W("\n")
  W(("paired difference vs '%s' (same seed both sides; * = 95%% CI excludes zero)\n"):format(base))
  rule()
  W(("%-14s"):format("metric"))
  for k = 2, #arms do
    W(("%18s"):format(arms[k].name))
  end
  W("\n")
  for _, m in ipairs(METRICS) do
    W(("%-14s"):format(m))
    for k = 2, #arms do
      local mu, ci = paired_diff(results[base][m], results[arms[k].name][m])
      W(("%12s +-%5s"):format(("%+.4g"):format(mu), ("%.3g"):format(ci)))
      W(ci > 0 and math.abs(mu) > ci and "*" or " ")
    end
    W("\n")
  end
end

local QN = { "poorest", "lower", "middle", "upper", "richest" }

for _, a in ipairs(arms) do
  local d = death_agg[a.name]
  if d.n > 0 then
    W("\n")
    rule("=")
    W(("arm '%s': %d lives ended (%d starved, %d of old age, %d were founders)\n"):format(a.name, d.n, d.cause[1], d.cause[2], d.founders))
    rule("=")

    W("\nmobility -- rows: the fifth a unit was BORN into, columns: the best fifth it ever REACHED\n")
    W(("%-10s"):format(""))
    for q = 1, 5 do
      W(("%10s"):format(QN[q]))
    end
    W(("%10s\n"):format("born"))
    for p = 1, 5 do
      local row, tot = d.mob[p], 0
      for q = 1, 5 do
        tot = tot + row[q]
      end
      W(("%-10s"):format(QN[p]))
      for q = 1, 5 do
        W(("%9.0f%%"):format(tot > 0 and row[q] / tot * 100 or 0))
      end
      W(("%10d\n"):format(tot))
    end

    W("\nlives by peak fifth -- mean lifespan, children, and net money by channel\n")
    W(("%-10s%7s%7s%8s"):format("peak", "n", "age", "kids"))
    for _, name in ipairs(sim.CHANNELS) do
      W(("%10s"):format(name))
    end
    W("\n")
    for q = 1, 5 do
      local r = d.q[q]
      local n = max(1, r.n)
      W(("%-10s%7d%7.0f%8.2f"):format(QN[q], r.n, r.age / n, r.kids / n))
      for c = 1, #sim.CHANNELS do
        W(("%10.0f"):format(r.chan[c] / n))
      end
      W("\n")
    end
  end
end
W("\n")
