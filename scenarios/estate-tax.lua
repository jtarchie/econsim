return {
  name = "estate tax",
  about = "Taxing estates into a flat dividend: does it flatten the distribution, or just move the same money through a slower pipe?",
  ticks = 4000,
  arms = {
    { name = "none" },
    { name = "half", knobs = { estate_tax = 0.5 } },
    { name = "all", knobs = { estate_tax = 1.0 } },
  },
  events = {
    { at = 1200, say = "the economy has settled; inequality from here is about who inherits" },
    { at = 3000, say = "steady state: compare gini and the mobility table across arms" },
  },
}
