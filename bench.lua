-- steady-state throughput in unit-ticks/s; the number to watch when tuning for continental scale.
-- best of several passes: system noise only ever adds time, so the minimum is the honest figure.
local sim = require("sim")
local opt = sim.parse_args(arg, {
  ticks = "measured ticks per pass (default 200)",
  warm = "warmup ticks (default 100)",
  passes = "measured passes, best wins (default 3)",
  seed = "random seed (default 1)",
})
local ticks, warm, passes = opt.ticks or 200, opt.warm or 100, opt.passes or 3
sim.debug = false
-- biography off unless asked for: this harness measures the tick, and --track is a reporting feature
if not sim.knobs_set.track then sim.knobs.track = 0 end
sim.init(opt.seed or 1)
for _ = 1, warm do
  sim.tick()
end
local best, pop = math.huge, 0
for _ = 1, passes do
  sim.compute_stats()
  local p0 = sim.stats.pop
  local t0 = os.clock()
  for _ = 1, ticks do
    sim.tick()
  end
  local dt = os.clock() - t0
  if dt < best then
    best, pop = dt, (p0 + sim.stats.pop) / 2
  end
end
sim.compute_stats()
print(("pop %d  %.1f ms/tick  %.1f ticks/s  %.2fM unit-ticks/s"):format(sim.stats.pop, best / ticks * 1000, ticks / best, pop * ticks / best / 1e6))
