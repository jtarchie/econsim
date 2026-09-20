return {
  name = "enclosure",
  about = "Land can be owned, and working someone else's land costs you a share of what you grow. Claiming costs money, so only those who already have some can enclose. Does that concentrate wealth on its own, and what does it cost the people who end up landless?",
  ticks = 4000,
  arms = {
    { name = "commons", knobs = { enclosure = 0 } },
    { name = "enclosed" },
    { name = "enclosed-taxed", knobs = { estate_tax = 0.6 } },
    { name = "low-rent", knobs = { rent = 0.05 } },
  },
  events = {
    { at = 1, arm = "commons", say = "nobody can own land here: every cell is open to whoever stands on it" },
    { at = 1, arm = "enclosed", say = "land can be claimed, for 150 in cash" },
    { at = 1200, say = "the good land is going; watch the landless count and the land gene" },
    { at = 3000, say = "compare gini against population -- a flatter distribution of fewer people is not a better outcome" },
  },
}
