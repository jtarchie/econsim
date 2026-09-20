# capitalism

An agent-based economy that you watch rather than read about. Units farm, mine, haggle, lend, go
broke, inherit and breed on a wrap-around world, and every behaviour they have is a number in a
genome that mutates at birth. Nobody is told how to act — prices, towns, trade routes, credit
bubbles and inequality are what is left after the selection pressure runs for a few thousand ticks.

The world is sized at startup. The default is 2,000 units on 2048×2048; `--cap`/`--grid` scale that
to a continent — a quarter of a million units on 16384×16384 has been run to steady state with every
invariant intact. See [Scale](#scale).

LuaJIT + raylib, ~1,600 lines, no dependencies beyond the raylib shared library.

![mature economy](docs/03-mature.png)

## Run it

```sh
brew install luajit raylib     # macOS; any LuaJIT 2.1 + raylib 5/6 works
luajit main.lua                # opens the window
luajit check.lua               # headless: 5000 ticks, asserts every invariant, prints ticks/sec
luajit bench.lua               # headless throughput, best of N passes, no assertions
```

`main.lua` refuses to open a window until every raylib symbol resolves, the C struct layouts match,
and the simulation reproduces a known fingerprint from a fixed seed. If it starts, it is correct-ish.

## What you are looking at

**The land** is a static two-resource map. Green is fertility (food per unit of labour), orange is
ore (tools). They mostly do not overlap, which is the central tension of the whole model: the people
who can make tools do not live where the food is.

**Each dot is one person.** Its colour is a fixed projection of its 20-gene genome onto a hue, so
similar colours mean similar strategies and a spreading colour is a strategy winning. Its radius is
net worth relative to the median (money + loans out − debt + goods and capital at market prices),
deliberately exaggerated so a 10× fortune is impossible to miss. Squares are the *stubborn* class:
frozen genome, frozen price beliefs, no drives. They are the control group, and the fact that they
are still ~40% of the population at tick 3,000 is the point: adaptation buys less than you would think.

**Lines are loans**, drawn from lender to borrower, brightness in proportion to the amount owed.
**Flashes** mark events: white = trade, green = birth, red = death, orange = default, blue = a loan
written. A translucent red disc is a crop failure (a regional shock), which is the only way food is
destroyed other than eating and spoilage.

### The panel

| Row | Meaning |
|---|---|
| `fps / tick / 16×frame / ms per tick` | render rate, simulation age, ticks run per frame, cost of a tick |
| `pop (artisans, stubborn)` | living units; artisans are tool-makers, stubborn are the frozen class |
| `gini / top 1% owns` | inequality. Gini is 0 when everyone is equal, 1 when one person owns everything |
| `food / tools / capital` | median transaction prices, and mean installed capital per head |
| `per 30t:` | births, starvations, old-age deaths and loan defaults in the last 30 ticks |
| sparklines | population, Gini, food price and tool price over the last 240 samples |
| wealth distribution | histogram of net worth in log₁₀ buckets — watch the right tail grow |
| gene means | population-average of each gene (bar) and its history (line) |

Click anyone to open the inspector on the right: their money, stock, debts, price beliefs and full
genome.

## The states to watch for

Each caption is the command that produced the image, so you can re-run any of them.

### Founding — 2,000 strangers, no trades yet

`luajit main.lua --seed=7 --speed=2 --shot=8`

![founding](docs/01-founding.png)

2,000 founders with equal money, 300 food and a random age, dropped onto land that is at least
decent (fertility > 0.55, or ore for the 15% who start as artisans). Genes are uniform random apart
from productivity and craft, which are biased so the first generation is not 95% stillborn. Gini is
0.000 and the prices on screen are beliefs, not trades: nothing has been sold yet.

### Growth — towns condense on the good land

`luajit main.lua --seed=7 --speed=16 --shot=40`

![growth](docs/02-growth.png)

By tick ~600 the map has emptied except for a dozen dense settlements sitting on fertility peaks,
linked by loan lines. Population is up, Gini has gone from 0.000 to 0.32, and the sparklines show
food price diving as the first harvests hit the market and then recovering to about 10. 2,160 loans
are outstanding. The red disc top-centre is a crop failure in progress.

### Maturity — a stable, unequal economy

`luajit main.lua --seed=7 --speed=32 --shot=94`

![mature](docs/03-mature.png)

At tick ~3000 population, prices and Gini (0.333) have flattened out. The wealth histogram is a long
right tail, births roughly balance deaths, and defaults have dropped to ~1 per 30 ticks because the
reckless lenders are already dead. Note `artisans 3`: the tool sector has quietly died, which is the
big open problem (see [`PLAN.md`](PLAN.md)).

### Inspector — one person's whole life

`luajit main.lua --seed=7 --speed=32 --shot=94 --pick`

![inspector](docs/04-inspector.png)

`--pick` selects the richest unit for the screenshot. This one is worth 6× the median, is 3,164 ticks
old, holds 139 food and no tools, and its genome says why: high productivity, high risk, high
speculation, near-zero thrift and craft. It is a farmer-speculator that never touched the tool trade.

### Close up — individuals and credit

`luajit main.lua --seed=7 --speed=16 --shot=50 --zoom=6`

![town](docs/05-town.png)

Zoomed into a single town. Big translucent circles are the rich, pinpricks are the poor, and the
threads between them are outstanding loans. The colour mixing shows several genomes coexisting in
the same market rather than one lineage sweeping.

### Crop failure — the shock channel

`luajit main.lua --seed=7 --speed=16 --shot=45 --shock-every=25`

![shock](docs/06-shock.png)

Inside the red disc, fertility drops to 15% for as long as the shock lasts. Red death flashes cluster
inside it, starvations and defaults tick up, and the survivors walk out along the food-supply
gradient. Press `S` to drop one wherever the mouse is; `--shock-every=0` turns them off entirely.

## Controls

| Key | Action |
| --- | --- |
| `space` | pause |
| `-` / `=` | halve / double ticks per frame |
| `S` | crop failure at the mouse |
| `R` | reset with the next seed |
| `L` / `F` | toggle loan links / event flashes |
| `H` | hide the panels |
| `[` / `]` | mutation σ down / up |
| `G` / `T` | estate tax down / up (share of every estate paid into a flat dividend) |
| drag / wheel | pan / zoom |
| click | select a unit |

## Flags

Both binaries take the same world knobs; `--help` prints them with defaults.

```
--cap --grid --cell --compact-every                      world size and memory layout
--pop --money --artisans --yield --toolrate --mut        economy
--estate-tax --shock-every --stubborn-founders --stubborn-birth
```

`--cap` is the hard population ceiling (a power of two), `--grid` the cells per side (a power of
two), `--cell` the cell size in world units — which is also the interaction radius. The world is
`grid × cell` across, so `--grid=1024` is a 16384×16384 map. Everything is allocated from these at
`init()`, so memory is fixed from the moment it returns: about 750 bytes per unit slot plus 40
bytes per cell — 427MB measured for `--cap=524288 --grid=1024`.

`main.lua` adds `--seed --speed --shot --width --height --zoom --pick --no-selftest`.
`check.lua` adds `--ticks --seed --fast`. `bench.lua` adds `--ticks --warm --passes --seed`.
Unknown flags, non-numbers and out-of-range values exit 2.

## How a tick works

0. **Grid** — counting sort of the live set into `cell` × `cell` buckets, so neighbour lookups are
   O(1). Every `--compact-every` ticks the units are then renumbered into that cell order and every
   reference to them (loans, heirs, the live list, the UI selection) is remapped, so the per-unit
   gathers that follow walk memory forwards instead of jumping around an array far larger than cache.
   Slot identity carries no economic state, so this changes nothing but the addresses.
2. **Produce** — food and tools from the local field × labour × capital, divided by crowding.
   Splitting effort between the two is penalised (squared shares), so specialising pays.
3. **Scan** — each unit looks at its cell neighbourhood once: who is selling, who is rich, who is kin.
4. **Trade** — two markets, food and tools. Buyers pay up to their belief-driven willingness to pay,
   sellers ask their reference price plus greed. Both sides update their beliefs from what happened.
5. **Lend** — surplus money becomes a fixed-term loan; the borrower converts it to capital, which
   multiplies labour and depreciates 0.3% per tick. Death or strategic default leaves the lender short.
6. **Move** — hunger climbs the food-supply field, cargo climbs the demand field, and ambition climbs
   the yield-per-head field. Movement is paid for by distance actually travelled.
7. **Birth** — enough money, enough food banked and not too crowded: a child is placed by a greedy
   climb of the opportunity field, with a mutated genome and a stake out of the parent's pocket.
8. **Settle** — loan instalments, deaths, estates (creditors, then heirs, then neighbours), dividend.

**Money is closed and exact.** It is stored as integer-valued doubles and every transfer is floored,
so `sum(money) + sum(escrow)` is the same number on tick 1 and tick 100,000. Only food and tools are
created and destroyed. That invariant is what `check.lua` exists to defend.

## Scale

Everything is a flat FFI array sized at `init()`, so the only ceiling is memory. Measured on an
M-series laptop, LuaJIT 2.1, single-threaded, assertions off (`bench.lua`, best of 3 passes):

| world | cap | steady-state pop | ms/tick | ticks/s | unit-ticks/s |
|---|---|---|---|---|---|
| 2048² (default) | 16,384 | ~2,000 | 1.6 | 620 | 1.36M |
| 8192² | 262,144 | ~126,000 | 143 | 7.0 | 0.92M |
| 16384² | 524,288 | ~276,000 | 285 | 3.5 | 0.91M |

Cost per unit depends on how clustered the population is, not just its size: a freshly seeded
16384² world ticks in ~40ms because everyone is spread thin, and slows as towns condense and each
unit acquires neighbours. The table is steady state, which is the pessimistic end.

```sh
luajit bench.lua --cap=524288 --grid=1024 --pop=200000 --ticks=25
luajit main.lua  --cap=262144 --grid=512  --pop=100000     # watchable
```

A continent runs, but it runs at a few ticks per second, not at 60. Roughly half of a tick is
neighbour discovery — about twelve candidates per unit, of which a third are inside the interaction
radius — and that half is memory-latency bound, not compute bound. The profiler reports ~94% of the
tick executing compiled traces with no aborts, so there is no interpreter overhead left to reclaim.

Things that were tried and **lost**, so they are not in the code:

- Splitting the six field propagations into one pass each. They share their index arithmetic; six
  passes cost six times as much.
- Holding the scan accumulators in registers per unit instead of read-modify-writing `SC`. The inner
  loop is only ~7 iterations, and trace-entry overhead ate the saving.
- Rejecting out-of-range candidates in the consumer instead of the producer. It moves the work, it
  does not remove it.

What would actually move the needle next is threads — the tick decomposes cleanly by cell — and
LuaJIT has no shared-memory parallel loop. That is the argument for a C kernel, not the language.

## Genes

Each gene has a cost, or it would simply evolve to 1.0 and the simulation would be boring.

| Gene | Effect |
|---|---|
| `productivity` | output per tick — costs upkeep |
| `craft` | share of labour spent on tools rather than food |
| `reserve` | buffer kept back before selling or lending |
| `greed` | markup over reference price — fewer sales, more spoilage |
| `herd` | weight on neighbours' prices — follows bubbles |
| `thrift` | willingness to pay when hungry — starves if too low |
| `invest` / `risk` | share of surplus lent out, and tolerance for bad borrowers |
| `borrow` | appetite for debt |
| `trust` | repay versus strategically default — defaulters get refused locally |
| `build` | converts money into capital |
| `speculate` | buys to resell rather than to consume |
| `peddle` | carries cargo toward demand |
| `speed` / `seek_rich` / `seek_kin` / `migrate` | movement drives |
| `repro_thresh` / `endowment` / `inherit` | when to breed, the child's stake, how the estate splits |

## Development

```sh
make run      # windowed
make check    # headless audit
make lint     # luacheck
make fmt      # stylua
make ci       # fmt-check + lint + check
make bench    # throughput, default world
make bench-big # throughput, 16384x16384 continent
make shots    # regenerate docs/*.png
```

Formatting is [StyLua](https://github.com/JohnnyMorganz/StyLua) with `.stylua.toml`
(220 columns, 2-space indent, one-line statements preserved); `make fmt-check` fails on unformatted
code. Linting is [luacheck](https://github.com/lunarmodules/luacheck) with `.luacheckrc`
(`std = "luajit"`, so `ffi`, `bit` and `jit` are known globals). Both come from Homebrew:
`brew install stylua luacheck`. The tree is warning-free; keep it that way.

The simulation asserts aggressively, in four tiers, so a production run pays for none of them:

| tier | runs | cost |
|---|---|---|
| static checks on constants and struct layout | once per `init()` | free |
| per-phase conservation checks | only when `sim.debug` is true | 1.1× |
| `sim.validate()` — every unit, loan and free-list reconciled against the ledger | only when called | O(cap) |
| `sim.selftest()` — same seed twice, fingerprints compared | `main.lua` startup unless `--no-selftest` | fixed, always on the default small world |

There are no assertions inside any per-unit loop; the `if dbg then` branches sit once per phase.
`check.lua` turns all of it on (`--fast` turns the per-phase tier off); `bench.lua` and `main.lua`
leave it off. `validate()` uses FFI scratch rather than Lua tables so the full audit still runs at
continental cap.

[`PLAN.md`](PLAN.md) has the design rationale, the performance traps (LuaJIT trace aborts, raylib
struct-by-value FFI calls), the bugs the assertions caught, and what is still broken — chiefly that
the tool sector does not sustain itself, because ore and farmland are too far apart for a 30-tick
food buffer.

## License

MIT
