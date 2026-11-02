# 03_plasmode_sd_planning.R -- Planning a trial's size from a pilot's SD, checked on real outcomes.
#
# A common way to size a two-arm trial is to run a small pilot, estimate the
# outcome's SD, and plug an upper confidence limit for the SD (not the estimate
# itself) into the usual formula, so that the main trial has its intended power
# with a known probability q (Browne 1995). The usual limit assumes a normal
# outcome; health-care costs and lengths of stay are far from normal. Here each
# MEPS outcome plays the population: a pilot of m people per arm is drawn from
# it (weighted), each rule gives an upper limit for the SD at q = 0.8, and the
# plan is "adequate" when the limit is at least the population SD. If a rule
# works, about 80% of pilots should give adequate plans.
#
# Rules: plug-in (the pilot SD itself); chi-square limit (exact for a normal
# outcome); Bonett's (2006) kurtosis-adjusted limit, with the pilot's kurtosis
# and with the population's (an "oracle" showing what outside information about
# the tails would buy); bootstrap percentile limit; BCa limit (Efron 1987).
#
# Output: output/plasmode_sd.csv, output/fig_plasmode_sd.png
# Runtime: ~10-20 minutes with the defaults (set REPS lower to try it quickly).
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
library(ggplot2)
P <- load_populations()
set.seed(2023)
REPS <- 1000; B <- 999; Q <- 0.8; M_GRID <- c(10, 20, 30, 60)

pooled_var <- function(x, y) (sum((x - mean(x))^2) + sum((y - mean(y))^2)) / (length(x) + length(y) - 2)

chisq_upper <- function(s, df, q = Q) s * sqrt(df / qchisq(1 - q, df))

bonett_upper <- function(x, y, q = Q, kurtosis = NULL) {   # Bonett (2006), two arms pooled
  N <- length(x) + length(y); f <- N - 2
  trim <- function(v) v - mean(v, trim = min(1 / (2 * sqrt(length(v) - 4)), 0.49))
  ss <- sum((x - mean(x))^2) + sum((y - mean(y))^2); rt <- c(trim(x), trim(y))
  z <- qnorm(q); cc <- N / (N - z)
  g4 <- if (is.null(kurtosis)) N * sum(rt^4) / ss^2 else kurtosis
  se <- cc * sqrt(max(g4 - (N - 3) / N, 1e-8) / f)
  sqrt(exp(log(cc * ss / f) + z * se))
}

boot_upper <- function(x, y, q = Q) {      # percentile and BCa upper limits for the SD
  m1 <- length(x); m2 <- length(y); f <- m1 + m2 - 2
  ss <- function(M) rowSums((M - rowMeans(M))^2)
  th <- pooled_var(x, y)
  ts <- (ss(matrix(x[sample.int(m1, B * m1, TRUE)], B)) + ss(matrix(y[sample.int(m2, B * m2, TRUE)], B))) / f
  jk <- c(vapply(seq_len(m1), function(i) pooled_var(x[-i], y), 0),
          vapply(seq_len(m2), function(i) pooled_var(x, y[-i]), 0))
  d <- mean(jk) - jk; acc <- if (sum(d^2) > 0) sum(d^3) / (6 * sum(d^2)^1.5) else 0
  z0 <- qnorm(min(max(mean(ts < th) + 0.5 * mean(ts == th), 1 / B), 1 - 1 / B))
  z <- qnorm(q); w <- 1 - acc * (z0 + z)
  c(percentile = sqrt(unname(quantile(ts, q, type = 6))),
    bca = if (w > 0) sqrt(unname(quantile(ts, pnorm(z0 + (z0 + z) / w), type = 6))) else NA)
}

one_pilot <- function(Pk, m, sd0, kurt0) {
  x <- draw(Pk, m); y <- draw(Pk, m)
  s <- sqrt(pooled_var(x, y))
  if (s == 0) return(c(plugin = 0, chisq = 0, bonett = 0, bonett_oracle = 0, percentile = 0, bca = 0))
  c(plugin = s, chisq = chisq_upper(s, 2 * m - 2), bonett = bonett_upper(x, y),
    bonett_oracle = bonett_upper(x, y, kurtosis = kurt0), boot_upper(x, y)) / sd0
}

rows <- list()
for (k in names(P)) {
  mo <- wmoments(P[[k]]$y, P[[k]]$w)
  for (m in M_GRID) {
    r <- t(replicate(REPS, one_pilot(P[[k]], m, mo[["sd"]], mo[["kurtosis"]])))
    rows[[length(rows) + 1]] <- data.frame(population = k, label = P[[k]]$label, m = m,
      rule = colnames(r), adequate = colMeans(r >= 1, na.rm = TRUE),
      median_ratio = apply(r, 2, median, na.rm = TRUE))
    message(k, ", m = ", m, " done")
  }
}
res <- do.call(rbind, rows)
write.csv(res, "output/plasmode_sd.csv", row.names = FALSE)

lab <- c(plugin = "Plug-in (pilot SD)", chisq = "Chi-square limit", bonett = "Bonett (pilot kurtosis)",
         bonett_oracle = "Bonett (population kurtosis)", percentile = "Bootstrap percentile", bca = "BCa")
res$rule <- factor(res$rule, levels = names(lab), labels = lab)
res$label <- factor(res$label, levels = unique(res$label))
g <- ggplot(res, aes(m, adequate, colour = rule)) +
  geom_hline(yintercept = Q, colour = "#F5A11C", linewidth = 0.8) +
  geom_line(linewidth = 0.8) + geom_point(size = 1.4) + facet_wrap(~label, ncol = 2) +
  scale_x_continuous(breaks = M_GRID) + scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  scale_colour_manual(values = c("#9B9B9B", "#862633", "#B85C6B", "#555555", "#8A8C45", "#1B5E83")) +
  theme_minimal(base_size = 11) + theme(legend.position = "bottom", panel.grid.minor = element_blank()) +
  guides(colour = guide_legend(nrow = 2)) +
  labs(x = "Pilot size per arm", y = "Share of pilots giving an adequately powered trial", colour = NULL,
       title = "Planning from a pilot's SD, with MEPS outcomes as the population",
       subtitle = paste0("Target 80% (orange line); ", REPS, " pilots per point; B = ", B, " bootstrap resamples"))
ggsave("output/fig_plasmode_sd.png", g, width = 9, height = 10.5, dpi = 200, bg = "white")
