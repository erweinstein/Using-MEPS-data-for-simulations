# 08_varying_effects_and_dropout.R -- Baseline adjustment when the effect varies and follow-ups are missing.
#
# Script 07 compares analyses of a baseline-and-follow-up trial with complete
# data and the same effect for everyone. Here, with the same MEPS panel, two
# common complications are added:
#
#   * a treatment effect that varies with baseline: person i's effect is
#     delta * (0.5 + F(b_i)), where F is the population distribution function of
#     the baseline, so the effect runs from half to one and a half times delta
#     (bigger for people with higher baseline values) and the population
#     average effect is about delta (computed exactly below);
#   * missing follow-ups, missing at random given baseline and arm (MAR):
#     P(missing) = plogis(alpha + beta_arm * (2 F(b_i) - 1)), with beta = 1 in
#     the control arm and 2.5 in the treatment arm (people with high baseline
#     values drop out more, especially under treatment), alpha set for ~25%
#     missing overall.
#
# Scenarios: varying effect, complete data; constant effect, dropout; varying
# effect, dropout. Methods (CC = complete cases only):
#   follow_up_cc, change_cc, ancova_cc   as in 07, on complete cases
#   ancova_lin_cc   ANCOVA with arm-by-baseline interaction, HC2 SE (Lin 2013),
#                   averaged over the baseline distribution of everyone
#                   randomized (all baselines are observed)
#   clda            constrained longitudinal data analysis on all observed data
#                   (every baseline, observed follow-ups); valid under MAR if
#                   its model is right, but it assumes one covariance matrix
#                   (so one baseline-follow-up slope) for both arms
#   aipw            augmented IPW for missing outcomes (doubly robust): an
#                   outcome model and a dropout model in each arm, both splines
#                   in baseline; SE from the influence function
#
# The target is the population average treatment effect. Reported: bias,
# empirical SE, coverage of nominal 95% intervals, power.
#
# Output: output/varying_effects_dropout.csv
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
for (p in c("sandwich", "nlme")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(splines); library(parallel)
RNGkind("L'Ecuyer-CMRG"); set.seed(8)
CORES <- if (.Platform$OS.type == "windows") 1 else 2   # mclapply runs serially on Windows
pan <- read_meps("meps_panel.csv")
pan <- subset(pan, AGEY1X >= 18 & LONGWT > 0)
OUT <- list(K6 = c("K6SUM2", "K6SUM4"), VR12_MCS = c("VMCS2", "VMCS4"), spending = c("TOTEXPY1", "TOTEXPY2"))
REPS <- as.integer(Sys.getenv("R08_REPS", "1000")); EFFECT_SD <- 0.3

wecdf <- function(b, w) { o <- order(b); cw <- cumsum(w[o]); f <- numeric(length(b)); f[o] <- cw - w[o] / 2; f }
qlogis_target <- function(u, target) {          # alpha giving the target overall missing share
  uniroot(function(a) mean(0.5 * plogis(a + 1 * u) + 0.5 * plogis(a + 2.5 * u)) - target, c(-10, 10))$root
}

one_trial <- function(b, f, Fb, w, n, delta, varying, dropout, alpha) {
  i <- sample.int(length(b), 2 * n, TRUE, prob = w); g <- rep(0:1, each = n)
  y1 <- b[i]; u <- 2 * Fb[i] - 1
  eff <- if (varying) delta * (0.5 + Fb[i]) else rep(delta, 2 * n)
  y2 <- f[i] + g * eff
  r <- if (dropout) rbinom(2 * n, 1, 1 - plogis(alpha + ifelse(g == 1, 2.5, 1) * u)) else rep(1L, 2 * n)
  o <- r == 1; out <- list()
  out$follow_up_cc <- coef(summary(lm(y2[o] ~ g[o])))[2, 1:2]
  out$change_cc    <- coef(summary(lm(I(y2[o] - y1[o]) ~ g[o])))[2, 1:2]
  out$ancova_cc    <- coef(summary(lm(y2[o] ~ g[o] + y1[o])))[2, 1:2]
  # Lin: interaction model on complete cases, effect averaged over all baselines
  yc <- y1 - mean(y1); dl <- data.frame(y2 = y2, g = g, yc = yc)[o, ]
  fl <- lm(y2 ~ g * yc, data = dl); V <- sandwich::vcovHC(fl, type = "HC2")
  out$ancova_lin_cc <- c(coef(fl)["g"], sqrt(V["g", "g"]))     # yc centred at the mean of everyone
  # cLDA on all observed data
  long <- data.frame(id = c(seq_len(2 * n), which(o)), tf = factor(rep(0:1, c(2 * n, sum(o)))),
                     y = c(y1, y2[o]), g = c(g, g[o]))
  long$tg <- (long$tf == "1") * long$g
  fc <- try(nlme::gls(y ~ tf + tg, data = long, correlation = nlme::corSymm(form = ~ 1 | id),
                      weights = nlme::varIdent(form = ~ 1 | tf)), silent = TRUE)
  out$clda <- if (inherits(fc, "try-error")) c(NA, NA) else summary(fc)$tTable["tg", 1:2]
  # AIPW for missing outcomes, known randomization probability 1/2
  d <- data.frame(y1 = y1, y2 = y2, r = r)
  mfit <- function(k) suppressWarnings(lm(y2 ~ ns(y1, df = 3), data = d[g == k & r == 1, ]))
  pfit <- function(k) if (all(r[g == k] == 1)) NULL else
    suppressWarnings(glm(r ~ ns(y1, df = 3), family = binomial, data = d[g == k, ]))
  m1 <- suppressWarnings(predict(mfit(1), d)); m0 <- suppressWarnings(predict(mfit(0), d))
  pr <- function(k) { pf <- pfit(k); if (is.null(pf)) rep(1, 2 * n) else pmax(suppressWarnings(predict(pf, d, type = "response")), 0.02) }
  p1 <- pr(1); p0 <- pr(0); y2z <- ifelse(o, y2, 0)
  psi <- m1 - m0 + g * r * (y2z - m1) / (0.5 * p1) - (1 - g) * r * (y2z - m0) / (0.5 * p0)
  out$aipw <- c(mean(psi), sd(psi) / sqrt(2 * n))
  rbind(do.call(rbind, out), missing_share = c(mean(!o), NA))
}

rows <- list()
SCEN <- list(c(varying = TRUE, dropout = FALSE), c(varying = FALSE, dropout = TRUE), c(varying = TRUE, dropout = TRUE))
for (k in names(OUT)) {
  b <- pan[[OUT[[k]][1]]]; f <- pan[[OUT[[k]][2]]]; ok <- b >= 0 & f >= 0
  b <- b[ok]; f <- f[ok]; w <- pan$LONGWT[ok] / sum(pan$LONGWT[ok])
  Fb <- wecdf(b, w); mf <- sum(w * f); sf <- sqrt(sum(w * (f - mf)^2))
  mb <- sum(w * b); sb <- sqrt(sum(w * (b - mb)^2)); rho <- sum(w * (b - mb) * (f - mf)) / (sb * sf)
  delta <- EFFECT_SD * sf; n <- n_per_arm(sf * sqrt(1 - rho^2), delta)
  alpha <- qlogis_target(2 * Fb - 1, 0.25)
  for (sc in SCEN) {
    ate <- if (sc[["varying"]]) sum(w * delta * (0.5 + Fb)) else delta
    res <- mclapply(seq_len(REPS), function(r) one_trial(b, f, Fb, w, n, delta, sc[["varying"]], sc[["dropout"]], alpha),
                    mc.cores = CORES)
    lab <- paste0(if (sc[["varying"]]) "varying effect" else "constant effect", ", ",
                  if (sc[["dropout"]]) "MAR dropout" else "complete data")
    for (m in setdiff(rownames(res[[1]]), "missing_share")) {
      e <- vapply(res, function(x) x[m, 1], 0); s <- vapply(res, function(x) x[m, 2], 0)
      rows[[length(rows) + 1]] <- data.frame(outcome = k, n_per_arm = n, scenario = lab, method = m,
        ate = ate, bias = mean(e, na.rm = TRUE) - ate, relative_bias = (mean(e, na.rm = TRUE) - ate) / ate,
        empirical_se = sd(e, na.rm = TRUE), mean_model_se = mean(s, na.rm = TRUE),
        coverage = mean(abs(e - ate) <= qnorm(0.975) * s, na.rm = TRUE),
        power = mean(abs(e) > qnorm(0.975) * s, na.rm = TRUE),
        missing_share = mean(vapply(res, function(x) x["missing_share", 1], 0)), failed = mean(is.na(e)))
    }
    message(k, ": ", lab, " done")
  }
}
res <- do.call(rbind, rows)
write.csv(res, "output/varying_effects_dropout.csv", row.names = FALSE)
print(res[, c("outcome", "scenario", "method", "relative_bias", "empirical_se", "coverage", "power", "missing_share")],
      digits = 3, row.names = FALSE)
