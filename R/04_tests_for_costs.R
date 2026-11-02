# 04_tests_for_costs.R -- How do common two-sample tests behave with real cost data?
#
# Health care spending is the textbook awkward outcome: many zeros, a long right
# tail, and a mean that is the quantity budget holders care about (Thompson and
# Barber 2000). Here two arms of n people are drawn from MEPS spending (all
# adults; adults with depression). Under the null both arms come from the same
# population; under the alternative the treatment arm's spending is cut by 20%
# for everyone (a multiplicative effect, so the mean falls by 20%).
#
# Tests: Welch's t test on spending; the Wilcoxon rank-sum test; a t test on
# log(1 + spending). The last two answer different questions from the first
# (a shift in the distribution, a ratio of geometric-type means), which is part
# of the lesson: more power is not the same as answering the question that was
# asked. The script also compares the t test's simulated power with what the
# usual normal-approximation formula predicts at the same n.
#
# Output: output/tests_for_costs.csv
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
P <- load_populations()
set.seed(4)
REPS <- 2000; N_GRID <- c(25, 50, 100, 250, 500, 1000, 2000); EFFECT <- 0.8

rows <- list()
for (k in c("spend_all", "spend_dep")) {
  mo <- wmoments(P[[k]]$y, P[[k]]$w)
  for (n in N_GRID) for (alt in c(FALSE, TRUE)) {
    pv <- t(replicate(REPS, {
      x <- draw(P[[k]], n); y <- draw(P[[k]], n) * if (alt) EFFECT else 1
      c(welch_t = t.test(x, y)$p.value,
        wilcoxon = suppressWarnings(wilcox.test(x, y, exact = FALSE)$p.value),
        log_t = t.test(log1p(x), log1p(y))$p.value)
    }))
    # power the normal formula predicts for the mean difference at this n
    delta <- (1 - EFFECT) * mo[["mean"]]
    sd_mix <- sqrt((mo[["sd"]]^2 + (EFFECT * mo[["sd"]])^2) / 2)
    pred <- if (alt) pnorm(sqrt(n / 2) * delta / sd_mix - qnorm(0.975)) else 0.05
    rows[[length(rows) + 1]] <- data.frame(population = k, n_per_arm = n,
      scenario = if (alt) "20% lower spending" else "no difference",
      test = colnames(pv), rejection_rate = colMeans(pv < 0.05), formula_power_t = pred)
  }
  message(k, " done")
}
res <- do.call(rbind, rows)
dir.create("output", showWarnings = FALSE)
write.csv(res, "output/tests_for_costs.csv", row.names = FALSE)
w <- reshape(res, idvar = c("population", "n_per_arm", "scenario", "formula_power_t"), timevar = "test", direction = "wide")
names(w) <- sub("rejection_rate.", "", names(w))
print(w[order(w$population, w$scenario, w$n_per_arm), ], digits = 2, row.names = FALSE)
