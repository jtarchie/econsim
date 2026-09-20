# Capitalism sim — LuaJIT + raylib

Env verified: LuaJIT 2.1 (`/opt/homebrew/bin/luajit`), raylib 6.0 (brew, `libraylib.dylib`).

## Decisions

| Area | Choice |
|---|---|
| Genome | Fixed float vector, genes in [0,1], embedded in FFI struct |
| Space | 2D continuous, torus wrap, uniform-grid neighbor lookup |
| Scale | ~10k units, capacity 16384 |
| Economy | Single good (food) w/ local prices, pairwise trade, loans/investment, production |
| Evolution | In-sim continuous: die broke/starved/old, rich spawn mutated offspring |
| Color | Fixed random projection of genome -> hue, computed once at birth |
| Visuals | size=log(wealth), loan links, stats overlay, event flashes |

## Core invariant

Money is closed and exact. Store as `double` holding integer values; every transfer is floored.
`sum(money) + sum(escrow) == M` every tick. Only food is created (production) and destroyed
(eating, spoilage). This is the one runnable check (`check.lua`, headless, N ticks, assert).

Consequences: birth endowment comes out of parent's money. Death estate -> creditors first,
then offspring (inheritance), remainder -> nearest neighbors. `estate_tax` global knob routes a
fraction to a commons pool that pays out as a flat dividend.

## Data layout

AoS `unit_t[16384]` — pair interactions are random-access so genome next to state beats SoA.
~100B/unit = ~1.6MB, fits L2.

```c
typedef struct {
  float x, y, vx, vy;
  double money;
  float food, capital, last_price, hue;
  uint32_t age, gen;      // gen bumps on slot reuse; loans hold (idx, gen)
  uint8_t alive;
  float g[16];            // genome
} unit_t;

typedef struct { int32_t lender, borrower; uint32_t lgen, bgen;
                 double principal; float rate; } loan_t;
```

Free-lists for both. Max 4 outgoing loans/unit to bound link count.
Grid: counting sort into `cell_start[]`/`cell_items[]` int32 arrays, rebuilt per tick, O(n).
Cell size = interaction radius. Iteration order: random offset + coprime stride (kills index bias).
RNG: seeded `math.random` (LuaJIT's is deterministic per seed) -> reproducible runs.

## Genes (every gene needs a cost, or it evolves to 1.0 and the sim is boring)

| Gene | Effect | Cost |
|---|---|---|
| productivity | food/tick × local fertility × f(capital) | raises own food upkeep |
| reserve | food + money buffer kept before selling/lending | idle capital |
| greed | ask = ref_price × (1 + greed) | fewer sales, food spoils |
| herd | blend ref_price toward neighbor avg | follows bubbles |
| thrift | max willingness-to-pay when hungry | starves if too low |
| invest_rate | fraction of surplus money lent out | illiquid |
| risk | lend to poor borrowers at higher rate | defaults |
| trust | repay vs strategic default when squeezed | defaulters get refused (local reputation = last_default age) |
| speed | movement | food upkeep ∝ speed² |
| seek_rich / seek_kin | steer toward wealth / similar hue | crowding -> less fertility per head |
| repro_threshold | money needed to spawn | — |
| endowment | fraction given to child | parent weakened |
| inherit | estate split offspring vs neighbors | — |

Spare slots to 16. Mutation: per-gene gaussian σ=0.05, clamp [0,1]. Asexual v1; crossover with
nearest kin is a later knob.

## Mechanics per tick

1. Rebuild grid.
2. Produce: `food += productivity × fertility(x,y) × (1 + k·sqrt(capital)) / local_density`.
   Fertility = static noise field -> geography, rich/poor regions. Regional shock events
   (crop failure) = the "lost" channel besides defaults.
3. Eat: `food -= upkeep`; food<0 -> die. Spoilage: `food *= 0.99`.
4. Trade: hungry unit scans neighbors, cheapest ask ≤ WTP wins. Money moves, food moves,
   both update `last_price`.
5. Invest: surplus money -> loan to a neighbor; borrower converts to capital (diminishing
   returns, depreciates). Repay per tick from money; borrower death/default -> lender eats loss.
6. Move, age. Old-age death on — forces turnover + makes inheritance matter.
7. Birth: money > threshold and local density under cap -> child nearby w/ mutated genome.

Carrying capacity falls out of fertility/density; 16384 is only the hard ceiling.

## Rendering

Raylib struct-by-value calls (`DrawCircleV`, `Color`, `Vector2`) are **not JIT-compiled** —
LuaJIT falls back to the interpreter per call. 10k/frame of those is the main perf trap.
Use rlgl instead, all-scalar args, one batch:

- Units: one circle texture, `rlSetTexture` + `rlBegin(RL_QUADS)` + `rlColor4ub/rlTexCoord2f/rlVertex2f`.
- Links: `rlBegin(RL_LINES)`, alpha ∝ principal, toggle key.
- Flashes: ring buffer of {x,y,kind,ttl}, same quad batch.
- Overlay (Gini, wealth histogram, pop, mean price, per-gene means over time): normal raylib
  calls, few dozen per frame, interpreter cost irrelevant. Gini sort at 2Hz not per tick.

Hand-written `ffi.cdef` for the ~30 functions used. No binding lib: existing ones lag raylib 6
or ship their own runtime.

Sim ticks decoupled from frames: K ticks/frame, +/- keys. Space pauses. Click -> genome inspector.
Camera2D pan/zoom.

## Files

- `rl.lua` — cdef subset + `ffi.load("raylib")`
- `sim.lua` — state + `tick()`, zero raylib dependency
- `main.lua` — window, input, draw
- `check.lua` — headless: run 5k ticks, assert money invariant, print ticks/sec

## Milestones (each one runs)

- **M0** Window + 10k moving textured quads via rlgl. Confirm 60fps and `-jv` shows no aborts in
  the draw loop. Riskiest tech bit, do first.
- **M1** Grid, fertility field, produce/eat/starve. Population self-limits.
- **M2** Trade + prices, money invariant check, stats overlay. Overlay early: it is the tuning tool.
- **M3** All behavior genome-driven, hue projection, birth/mutation/death/inheritance.
- **M4** Loans, capital, defaults, link rendering, cascade flashes.
- **M5** Inspector, knobs (mutation σ, estate tax, shock rate), gene time-series.
- **Later** Headless batch GA over world params, genome save/load, crossover, 100k (swap draw path
  to instanced/points; sim layout already fits).

## Risks

- **Degenerate equilibria** (extinction, or one genome sweeps in 200 ticks). Mitigation: knobs +
  gene-mean plots from M2, fertility geography keeps niches distinct.
- **JIT trace aborts**: no closures/table allocs in tick, no struct-by-value FFI in hot loops,
  neighbor loops on cdata only. Verify with `luajit -jv`.
- **Stale loan refs** after slot reuse: `(idx, gen)` pairs.
- **Float drift in money**: avoided by integer-valued doubles.

## Status (2026-09-20) — land ownership

Prompted by noticing the world's "edges". Measurement first: movement already costs 1% of the food
bill, mean speed is 0.4 units/tick so crossing half the map outlasts a lifetime, 92% of cells are
empty and half of prime farmland is unoccupied. So the physical constraint was already crushing and
the price of moving was irrelevant. What was missing was the *economic* constraint — nobody could be
excluded from land, so land could not be a way to win or lose.

- `own[cell]` names the owning slot, `cells[unit]` the same fact from the other side so a death can
  find its own land without sweeping the map. Both sides are reconciled in `validate()`.
- **Rent** in `phase_produce`: work a cell someone else owns and a `rent` share of what it yields,
  valued at the market price, goes to the owner. Unpayable rent is simply not paid — arrears would
  need a second credit system.
- **Claiming** costs `land_price` in cash, paid to the commons. That barrier is the mechanism, not a
  side effect: enclosure is something only the already-moneyed can do. A unit with `speculate > 0.5`
  claims the best cell in its 3x3 block rather than the one under its feet, so land can be enclosed
  ahead of anyone reaching it.
- **Inheritance**: land passes whole to the heir, unsplit and untaxed by `estate_tax`.
- **Foreclosure**: a default hands one of the borrower's cells to the lender.
- New gene `land` (NG 20 -> 21) for claim appetite; `speculate` decides absentee vs occupied.
- New channel `land` (NCHAN 9 -> 10): net lifetime rent collected, less rent paid and purchase fees.

### Two bugs this surfaced
- **Rent was priced from `M.stats.price`**, which only updates when the *host* calls `compute_stats`.
  `run.lua` calls it once at the end, so rent would have been charged at the tick-0 price for an
  entire run — the simulation's behaviour depending on the observer. Replaced with `REF`, a
  volume-weighted price the tick maintains from trades it actually cleared. Same class of bug as the
  rank sampling one; anything the model *reads* must be owned by the model.
- **`max_holding` was a hidden policy knob.** At 8/16/32 cells the gini lands at 0.563/0.606/0.636 —
  concentration does not self-limit, the top holders sit on whatever cap exists. Promoted to a knob
  so the number is visible and ablatable rather than buried in a local.

### A latent bug it exposed
`phase_trade`'s post-trade belief update was the one belief path with no 0.05 floor on it. A seller
whose ask fell below the floor could drag a buyer under it, and `validate()` caught it at tick 3325.
It had never fired before because prices never went near the floor; rent draining tenant cash pushed
the economy into the regime that reaches it. Assertions written for one model paying off in the next.

### What it found
- gini 0.348 -> 0.594, top 1% share 0.047 -> 0.113, on the same seeds.
- Net lifetime `land` money by peak fifth: `-182 -611 -1102 -1181 +1048`. The bottom four fifths pay,
  the top fifth collects.
- Population falls a third, but through **fertility, not famine**: births -1742, starvations -1141 in
  absolute terms. Rent drains the money a birth requires.
- Re-measuring `credit` with land in the world **overturned the previous finding**: the richest fifth
  goes from `credit +48` to `credit -179, land +1048`. Where land can be owned the top stops lending
  for profit and collects rent, and ablating credit no longer dents the top 1%.
- `estate_tax = 0.6` barely dents it (+0.230 against +0.246), because land passes to heirs untaxed.
  Taxing money estates does not touch land inequality.
- The `land` and `speculate` gene means both climb over a run: the model selects for enclosing.

## Status (2026-09-20) — measurement layer

The sim could show that inequality happens but not say why anyone ended up where they did. Fixed by
recording, not by modelling:

- **Money channels.** Nine signed per-unit counters (`founding sales purchases credit debt children
  bequest estates dividend`), exhaustive by construction, so `sum(channels) == money` exactly for
  every unit. `validate()` asserts it, which is what makes a forgotten ledger entry a crash instead
  of a wrong table. Costs 96B/unit and ~1.5% of the tick (4% at 130k); `--track=0` removes both.
- **Dynasties.** `unit_t.dyn` (fits in existing padding, so free) carries the founder id down every
  descendant. `stats.lines / top_line / top_line_worth` — lineage share is what selection actually
  maximises, and it diverges from money.
- **Rank history.** `trk_t.cur/peak`, sampled by `tick()` itself every 30 ticks, never by the host:
  an unsampled rank reads as 0 rather than as missing and would silently fictionalise the mobility
  table. Tie blocks rank at their midpoint, else a field of equals all rank at 100%.
- **Death records.** Every life that ends folds into a 5x5 mobility matrix (born-fifth to best-fifth)
  and per-quintile means of lifespan, children and each channel. `--deaths=` streams a CSV row each.
- **Scenarios** (`scen.lua`, `scenarios/*.lua`): arms, tick-exact events (`set`, `shock`, `jubilee`,
  `say`), validated hard at load. `run.lua` runs every arm over shared seeds and reports the *paired*
  difference with a Student-t interval — unpaired comparison is useless here, since any intervention
  shifts the random stream and the trajectory is chaotic.
- New knobs `lending` (0 = no credit) and `usury` (rate cap) exist so credit can be ablated rather
  than argued about; `M.jubilee()` forgives every debt without moving money.

### What the measurement found
- Lending is the mechanism of the top fifth: net lifetime credit by peak quintile is
  `-7 -15 -36 -27 +35`. Ablating it cuts gini 0.048 +- 0.018 with **no** measurable output cost.
- Estates of dead neighbours dwarf named inheritance as an inflow (`123..1478` vs `11..113`). The
  scatter is local, so this is a geography effect: the rich stand in crowded towns.
- 75% of those born poorest never leave the bottom fifth; 31% born richest die there.

## Status (2026-09-18)

Run: `luajit main.lua [--seed= --speed= --shot= --no-selftest] [knobs]`. Audit: `luajit check.lua [--ticks= --seed= --fast] [knobs]`.
Knobs (both): `--pop --money --artisans --yield --toolrate --mut --estate-tax --shock-every --stubborn-founders
--stubborn-birth`; `--help` lists them with defaults. Unknown flags, non-numbers and out-of-range values exit 2.
Circle radius is linear in net worth (money + loans - debt + goods and capital at median prices) over the median.

### Assertions (sim.lua, bottom)
- Load time: constant coherence (powers of two, R2 <= CELL^2, gene index table, prime strides > CAP, buffer sizes).
- `M.debug` on: per-phase checks inside `tick()` — grid membership, scan outputs, field bounds, and conservation
  of money (exact) + food/tools/capital (float tol) across trade, lend, birth; money across loans and burial.
- `M.validate()`: every unit/loan/free-list/ledger invariant (debt/lent/nloans reconcile against the loan table).
- `M.selftest()`: two audited runs from one seed must produce the same fingerprint. main.lua runs it, plus a
  raylib symbol + struct-layout check, before the window opens.
- Bugs these caught: parent advertising tools already given to a child; births firing without the food stake
  (parent went to -37 food and starved: this was killing successful sellers); float32 wrap landing exactly on W;
  scratch buffers leaking state across `init()` (non-reproducible seeds).
- `stats.unmet[good*4 + why]`: why wanting buyers go unserved (no seller in range / sold out / no cash / price).

### Model now
- Two goods. Food from `fert` field, tools from a separate `ore` field; tools install as capital (depreciates
  0.3%/tick) and multiply labour. Squared labour shares (`craft`) make generalists wasteful; 3% career-flip at
  birth crosses the valley. `phase_trade(k)` is generic over the good.
- Movement has reasons, cost is per distance moved (a standing speed cost evolved speed to 0): starvation risk ->
  climb food supply field; cargo -> climb demand field (`peddle`); better yield per head elsewhere -> `migrate`.
  Fields are per-cell, max-propagated with decay. Children are placed by a greedy climb of the opportunity field.
- Stubborn class (squares): frozen genome (children are clones), frozen price beliefs, no drives. 20% of founders,
  2% of other births. They hold ~25-35% share, do not take over now that adaptive units are viable.

### Learned
- LuaJIT: branchy body inside low-trip-count nested loops -> side-trace explosion -> interpreter. Keep per-pair
  logic in `phase_scan`'s flat loop; nested loop bodies trivial. JIT limits raised at top of `sim.lua`.
- Ablate, don't guess: the hunger drive defined as "below reserve" was lethal on its own (would-be parents carry a
  +60 food target, so every farmer walked off its field). The stubborn sitters were masking an extinct adaptive
  population.
- A cash reserve scaled by food price silently zeroed every tool budget once food got dear.

### Open
- **Capital is dead, so "winning by investing" cannot be shown.** Nothing forces a loan into capital;
  the tool sector is extinct, so founder capital decays at 0.997/tick and is gone by ~1500. The
  mature economy is self-employed farmers plus moneylenders. Fixing the tool sector is now the
  blocker on the whole capital story, not just an untidy corner.
- **Nominal constants are not expressed in food-price units** (`300 + 3000*repro`, `amount >= 50`,
  `debt < 5000`). Changing the money supply therefore changes birth rates for an artificial reason,
  so no monetary scenario can be trusted yet. Note that a price-scaled reserve once zeroed every tool
  budget, so this needs ablating, not just editing.
- **No land ownership.** Nobody owns a cell, nobody collects rent, nobody works for anyone. That is
  the largest missing inequality channel: enclosure, rentiers, foreclosure concentrating land, losing
  by being born after the land is taken. Wage labour falls out of it afterwards.
- **Nobody borrows to eat.** Hunger cannot be financed, so there is no debt trap; and underfed units
  are not less productive, so poverty is not a trap either — losing is instant rather than slow.
- Tool sector does not sustain: ~1-2M unmet tool wants per 500 ticks, ~all "no seller in range"; artisans fall
  from ~60 founders to <10. Ore and farmland are apart, food buffers are ~30 ticks, round trips are hundreds.
  Bigger buffers + slower spoilage alone did not fix it. Candidates: dedicated hauliers (long-range trade
  contracts instead of walking), or artisans living in farm towns with ore delivered.
- Units still huddle on founding sites; colonisation of empty fertile land is slow.
- ~3-4 ms/tick at 3-4k units with assertions off.
