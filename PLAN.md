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
- Tool sector does not sustain: ~1-2M unmet tool wants per 500 ticks, ~all "no seller in range"; artisans fall
  from ~60 founders to <10. Ore and farmland are apart, food buffers are ~30 ticks, round trips are hundreds.
  Bigger buffers + slower spoilage alone did not fix it. Candidates: dedicated hauliers (long-range trade
  contracts instead of walking), or artisans living in farm towns with ore delivered.
- Units still huddle on founding sites; colonisation of empty fertile land is slow.
- ~3-4 ms/tick at 3-4k units with assertions off.
