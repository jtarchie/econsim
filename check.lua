local sim = require("sim")
local opt = sim.parse_args(arg, { ticks = "ticks to run (default 5000)", seed = "random seed (default 1)", fast = "skip per-tick assertions" })
local ticks = opt.ticks or 5000
sim.selftest()
sim.debug = not opt.fast
sim.init(opt.seed or 1)
local t0 = os.clock()
for t = 1, ticks do
  sim.tick()
  if sim.debug and t % 25 == 0 then sim.validate() end
  if t % 500 == 0 then
    sim.compute_stats()
    sim.validate()
    local s = sim.stats
    print(("t=%5d pop=%5d gini=%.3f top1=%.2f price=%7.2f tool=%7.2f artisans=%5d stub=%5d cap=%5.1f loans=%5d debt=%9.0f | b=%4d starve=%4d old=%4d def=%4d trades=%6d spec=%6d vol=%8.0f toolvol=%7.0f")
      :format(t, s.pop, s.gini, s.top1, s.price, s.tool_price, s.artisans, s.stubborn, s.capital, s.nloans, s.debt, s.births, s.starved, s.aged, s.defaults, s.trades, s.spec, s.volume, s.tool_volume))
    local m = sim.stats.unmet
    print(("        unmet food: noseller=%d soldout=%d nocash=%d price=%d | tools: noseller=%d soldout=%d nocash=%d price=%d"):format(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7]))
  end
end
local dt = os.clock() - t0
sim.validate()
print(("%d ticks in %.2fs = %.0f ticks/s, all invariants held"):format(ticks, dt, ticks / dt))
local s = sim.stats
for k, name in ipairs(sim.GENES) do io.write(("%s=%.2f "):format(name, s.means[k])) end
print()
