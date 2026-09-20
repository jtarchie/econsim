return {
  name = "jubilee",
  about = "Let debt pile up for 2000 ticks, then cancel all of it at once. Who is actually rescued, and does the debt simply rebuild?",
  ticks = 4000,
  arms = {
    { name = "never" },
    { name = "once" },
    { name = "every-500" },
  },
  events = {
    { at = 1800, say = "debt has been accumulating since the first surplus" },
    { at = 2000, arm = "once", jubilee = true, say = "JUBILEE: every debt forgiven where it stands" },
    { at = 500, arm = "every-500", jubilee = true },
    { at = 1000, arm = "every-500", jubilee = true },
    { at = 1500, arm = "every-500", jubilee = true },
    { at = 2000, arm = "every-500", jubilee = true, say = "fourth jubilee; lenders have stopped expecting repayment" },
    { at = 2500, arm = "every-500", jubilee = true },
    { at = 3000, arm = "every-500", jubilee = true },
    { at = 3500, arm = "every-500", jubilee = true },
    { at = 2600, arm = "once", say = "watch whether total debt returns to where it was" },
  },
}
