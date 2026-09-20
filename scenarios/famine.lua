return {
  name = "famine",
  about = "A settled economy, then relentless crop failure. Who starves first, and does the survivors' distribution end up flatter or steeper?",
  ticks = 4000,
  knobs = { shock_every = 0 },
  arms = {
    { name = "calm" },
    { name = "famine" },
    { name = "famine-taxed", knobs = { estate_tax = 0.6 } },
  },
  events = {
    { at = 2000, say = "settled. from here the shocks begin" },
    { at = 2000, arm = "famine", set = { shock_every = 40 } },
    { at = 2000, arm = "famine-taxed", set = { shock_every = 40 } },
    { at = 2400, arm = "famine", say = "crop failures every ~40 ticks" },
    { at = 3600, say = "compare surviving population, not just gini: a flat distribution of corpses is not equality" },
  },
}
