LUA ?= luajit

.PHONY: run check fmt fmt-check shots

run:
	$(LUA) main.lua

check:
	$(LUA) check.lua

fmt:
	stylua *.lua

fmt-check:
	stylua --check *.lua

# the captions in README.md are these commands; keep the two in sync
shots:
	$(LUA) main.lua --no-selftest --seed=7 --speed=2  --shot=8              && mv shot.png docs/01-founding.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=16 --shot=40             && mv shot.png docs/02-growth.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=32 --shot=94             && mv shot.png docs/03-mature.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=32 --shot=94 --pick      && mv shot.png docs/04-inspector.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=16 --shot=50 --zoom=6    && mv shot.png docs/05-town.png
	$(LUA) main.lua --no-selftest --seed=7 --speed=16 --shot=45 --shock-every=25 && mv shot.png docs/06-shock.png
