return {
  name = "credit",
  about = "Ablate lending. If fortunes are built on interest, an economy with no credit should have a flatter top -- and less output, because nobody can finance capital.",
  ticks = 4000,
  arms = {
    { name = "credit" },
    { name = "no-credit", knobs = { lending = 0 } },
    { name = "rate-capped", knobs = { usury = 0.08 } },
  },
  events = {
    { at = 1, arm = "no-credit", say = "no credit in this world: surplus money sits idle" },
    { at = 1, arm = "rate-capped", say = "interest capped at 8%: lending is legal but barely worth it" },
    { at = 2500, say = "compare the credit and debt rows of the death table" },
  },
}
