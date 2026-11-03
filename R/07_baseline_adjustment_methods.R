# 07_baseline_adjustment_methods.R -- Baseline and follow-up from the MEPS panel: which analysis?
#
# A randomized trial with a baseline measurement can be analysed in many ways.
# This script compares seven, in plasmode trials drawn from the MEPS two-year
# panel (the same people measured in 2022 and 2023):
#
#   follow_up    the follow-up alone (difference in means)
#   change       the change from baseline (difference in mean changes)
#   ancova       follow-up regressed on arm and baseline (ANCOVA), model SE
#   ancova_lin   ANCOVA with an arm-by-baseline interaction (baseline centred),
#                with a robust (HC2) SE (Lin 2013); never less efficient than
#                follow_up asymptotically, and valid if the slopes differ by arm
#   clda         constrained longitudinal data analysis (Liang and Zeger 2000;
#                Lu 2010): baseline and follow-up are both responses in a
#                linear model with an unstructured covariance, and the two arms
#                share a baseline mean (as randomization implies). Fitted with
#                nlme::gls, in the spirit of Hedeker and Gibbons (2006).
#   aipw_spline  augmented inverse-probability-weighted (AIPW) estimator with
#                known randomization probability 1/2 and an outcome model for
#                each arm that is a natural spline in baseline (Tsiatis et al.
#                2008); its SE comes from the efficient influence function
#                (Hines et al. 2022). Allows a non-linear baseline relationship.
#   aipw_glm     (spending only) the same, with a log-link (quasi-Poisson) GLM
#                for the outcome model, a natural choice for costs.
#
# With correlation rho between baseline and follow-up (equal SDs), the
# variances of the first three are sigma^2, 2 sigma^2 (1 - rho) and
# sigma^2 (1 - rho^2) (Frison and Pocock 1992; Vickers and Altman 2001), and in
# a randomized trial with complete data ANCOVA is already (asymptotically) as
# efficient as any method that uses the baseline linearly (Yang and Tsiatis
# 2001); the others earn their place with missing data, several follow-ups,
# non-linearity, heterogeneity, or skewness.
#
# Design: for each outcome (K6, VR-12 mental summary, total spending), trials
# of n per arm, n = the ANCOVA formula's size for a difference of 0.3
# follow-up SDs with 80% power; (baseline, follow-up) pairs drawn with the
# longitudinal weights; the difference added to the treatment arm's follow-up;
# 2,000 trials with that difference and 2,000 with none.
#
# Output: output/baseline_methods_design.csv, output/baseline_methods.csv
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
for (p in c("sandwich", "nlme")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(splines)
set.seed(7)
pan <- read_meps("meps_panel.csv")
pan <- subset(pan, AGEY1X >= 18 & LONGWT > 0)
OUT <- list(K6 = c("K6SUM2", "K6SUM4"), VR12_MCS = c("VMCS2", "VMCS4"), spending = c("TOTEXPY1", "TOTEXPY2"))
REPS <- as.integer(Sys.getenv("R07_REPS", "2000")); EFFECT_SD <- 0.3

est_all <- function(y1, y2, g, glm_model = FALSE) {
  n <- length(g); out <- list()
  f1 <- lm(y2 ~ g); out$follow_up <- coef(summary(f1))["g", 1:2]
  f2 <- lm(I(y2 - y1) ~ g); out$change <- coef(summary(f2))["g", 1:2]
  f3 <- lm(y2 ~ g + y1); out$ancova <- coef(summary(f3))["g", 1:2]
  yc <- y1 - mean(y1); f4 <- lm(y2 ~ g * yc)
  out$ancova_lin <- c(coef(f4)["g"], sqrt(sandwich::vcovHC(f4, type = "HC2")["g", "g"]))
  long <- data.frame(id = rep(seq_len(n), 2), time = rep(0:1, each = n), y = c(y1, y2), g = rep(g, 2))
  long$tg <- long$time * long$g; long$tf <- factor(long$time)
  f5 <- try(nlme::gls(y ~ tf + tg, data = long, correlation = nlme::corSymm(form = ~ 1 | id),
                      weights = nlme::varIdent(form = ~ 1 | tf)), silent = TRUE)
  out$clda <- if (inherits(f5, "try-error")) c(NA, NA) else summary(f5)$tTable["tg", 1:2]
  aipw <- function(fit_fun) {               # known randomization probability 1/2
    d <- data.frame(y1 = y1, y2 = y2)
    # (with many tied baseline values, e.g. K6 = 0, ns() moves a knot and warns; harmless)
    m1 <- suppressWarnings(fit_fun(d[g == 1, ])); m0 <- suppressWarnings(fit_fun(d[g == 0, ]))
    p1 <- suppressWarnings(predict(m1, d, type = "response")); p0 <- suppressWarnings(predict(m0, d, type = "response"))
    psi <- p1 - p0 + g * (y2 - p1) / 0.5 - (1 - g) * (y2 - p0) / 0.5
    c(mean(psi), sd(psi) / sqrt(n))
  }
  out$aipw_spline <- aipw(function(d) lm(y2 ~ ns(y1, df = 3), data = d))
  if (glm_model) out$aipw_glm <- aipw(function(d) glm(y2 ~ ns(log1p(y1), df = 3), family = quasipoisson, data = d))
  do.call(rbind, out)
}

design <- list(); rows <- list()
for (k in names(OUT)) {
  b <- pan[[OUT[[k]][1]]]; f <- pan[[OUT[[k]][2]]]; ok <- b >= 0 & f >= 0
  b <- b[ok]; f <- f[ok]; w <- pan$LONGWT[ok] / sum(pan$LONGWT[ok])
  mb <- sum(w * b); mf <- sum(w * f)
  sb <- sqrt(sum(w * (b - mb)^2)); sf <- sqrt(sum(w * (f - mf)^2)); rho <- sum(w * (b - mb) * (f - mf)) / (sb * sf)
  sc <- sqrt(sum(w * ((f - b) - (mf - mb))^2))
  sa <- sqrt(sum(w * ((f - mf) - rho * sf / sb * (b - mb))^2))
  delta <- EFFECT_SD * sf; n <- n_per_arm(sa, delta)
  design[[k]] <- data.frame(outcome = k, N = length(b), rho = rho, sd_follow_up = sf, sd_change = sc,
    sd_ancova_resid = sa, n_follow_up = n_per_arm(sf, delta), n_change = n_per_arm(sc, delta),
    n_ancova = n, delta = delta)
  for (d0 in c(0, delta)) {
    res <- replicate(REPS, {
      i <- sample.int(length(b), 2 * n, TRUE, prob = w); g <- rep(0:1, each = n)
      est_all(b[i], f[i] + d0 * g, g, glm_model = (k == "spending"))
    }, simplify = FALSE)
    for (m in rownames(res[[1]])) {
      e <- vapply(res, function(r) r[m, 1], 0); s <- vapply(res, function(r) r[m, 2], 0)
      rows[[length(rows) + 1]] <- data.frame(outcome = k, n_per_arm = n,
        scenario = if (d0 == 0) "no effect" else "0.3 SD effect", method = m,
        bias = mean(e, na.rm = TRUE) - d0, empirical_se = sd(e, na.rm = TRUE), mean_model_se = mean(s, na.rm = TRUE),
        coverage = mean(abs(e - d0) <= qnorm(0.975) * s, na.rm = TRUE),
        rejection_rate = mean(abs(e) > qnorm(0.975) * s, na.rm = TRUE), failed = mean(is.na(e)))
    }
    message(k, if (d0 == 0) ", no effect" else ", effect", " done")
  }
}
dz <- do.call(rbind, design); res <- do.call(rbind, rows)
write.csv(dz, "output/baseline_methods_design.csv", row.names = FALSE)
write.csv(res, "output/baseline_methods.csv", row.names = FALSE)
print(format(dz, digits = 3, big.mark = ","), row.names = FALSE)
res$se_ratio <- res$mean_model_se / res$empirical_se
print(res[, c("outcome", "scenario", "method", "bias", "empirical_se", "se_ratio", "coverage", "rejection_rate")],
      digits = 3, row.names = FALSE)
