LUA ?= luajit

.PHONY: run check lint fmt fmt-check ci shots bench bench-big scenarios $(SCENARIOS)

SCENARIOS := $(patsubst scenarios/%.lua,%,$(wildcard scenarios/*.lua))
SEEDS ?= 8

run:
	$(LUA) main.lua

check:
	$(LUA) check.lua

lint:
	luacheck *.lua

fmt:
	stylua *.lua

fmt-check:
	stylua --check *.lua

ci: fmt-check lint check

# one target per scenario file: `make estate-tax SEEDS=20`
$(SCENARIOS):
	$(LUA) run.lua --scenario=scenarios/$@.lua --seeds=$(SEEDS)

scenarios: $(SCENARIOS)

bench:
	$(LUA) bench.lua

# a quarter-million units on a 16384x16384 map; needs ~300MB
bench-big:
	$(LUA) bench.lua --cap=524288 --grid=1024 --pop=200000 --ticks=25 --warm=40

# the captions in README.md are these commands; keep the two in sync
shots:
	$(LUA) main.lua --no-selftest --seed=7 --speed=2  --shot=8              && mv shot.png docs/01-founding.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=16 --shot=40             && mv shot.png docs/02-growth.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=32 --shot=94             && mv shot.png docs/03-mature.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=32 --shot=94 --pick      && mv shot.png docs/04-inspector.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=16 --shot=50 --zoom=6    && mv shot.png docs/05-town.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=16 --shot=45 --shock-every=25 && mv shot.png docs/06-shock.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=32 --shot=94 --view=3 --mob  && mv shot.png docs/07-mobility.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=8  --shot=40 --view=1 --scenario=scenarios/credit.lua --arm=no-credit && mv shot.png docs/08-scenario.png
