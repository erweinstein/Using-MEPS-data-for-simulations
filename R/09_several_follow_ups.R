# 09_several_follow_ups.R -- Trials with a baseline and three follow-ups, with MEPS's real missing data.
#
# Panels 23 and 24 of MEPS were followed for four years (HC-236, 2018-2021;
# HC-245, 2019-2022), so each person has up to four annual values of spending
# and four self-administered-questionnaire values of the K6 and the VR-12
# mental summary (rounds 2, 4, 6 and 8). Many people miss some of them, in
# intermittent as well as monotone patterns, which makes these files a
# realistic test bed for longitudinal trial analyses. (The four years include
# 2020, so the trajectories include the pandemic's disruptions, the same in both
# simulated arms.)
#
# Each plasmode trial draws 2n people (with the longitudinal weights) and keeps
# each person's own pattern of missing values. Baseline = year 1 (people with
# a missing baseline are excluded, as a trial would). The treatment effect grows
# linearly: delta * t/3 at follow-up t = 1, 2, 3, with delta = 0.3 SDs of the
# final value. Scenarios:
#   A. constant effect; MEPS's own missingness only (unrelated to arm);
#   B. effect varying with baseline, delta_i = delta (0.5 + F(b_i)), plus extra
#      dropout that depends on baseline and arm (MAR; ~25% of people drop out
#      at a random follow-up and miss the rest).
# The target is the average effect at the last follow-up (for the summary-
# measure analysis, the average effect over the three follow-ups).
#
# Methods:
#   ancova_last_cc  ANCOVA of the last follow-up on baseline, people observed then
#   ancova_mean     ANCOVA of the mean of each person's observed follow-ups
#                   (summary-measure analysis; Frison and Pocock 1992)
#   mmrm            mixed model for repeated measures: time as a factor, arm
#                   effects at each follow-up, common baseline mean (cLDA),
#                   unstructured covariance (nlme::gls); valid under MAR
#   lmm_slope       linear mixed model with random intercept and slope (Hedeker
#                   and Gibbons 2006): time as a factor for the common trend,
#                   arm-by-linear-time for the effect; valid under MAR if right
#   gee_exch        GEE with an exchangeable working correlation, same mean
#                   model as mmrm (geepack); valid under MCAR, not MAR
#   aipw_last       AIPW for the last follow-up: outcome and dropout models in
#                   baseline, in each arm (doubly robust if missingness depends
#                   on baseline and arm only)
#
# Output: output/several_follow_ups.csv, output/several_follow_ups_design.csv
# Runtime: ~1-2 hours with the default 500 trials per setting (settings already
# finished are saved in output/ckpt/ and reused if the script is restarted).
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
for (p in c("nlme", "geepack")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(splines); library(parallel)
RNGkind("L'Ecuyer-CMRG"); set.seed(9)
CORES <- if (.Platform$OS.type == "windows") 1 else 2
REPS <- as.integer(Sys.getenv("R09_REPS", "500")); EFFECT_SD <- 0.3
dir.create("output/ckpt", recursive = TRUE, showWarnings = FALSE)   # finished settings are saved here and reused

# ---- populations: pool whichever four-year panels were extracted ---------------------------------
pf <- list.files(data_dir, "^meps_panel4_.*\\.csv$", full.names = TRUE)
if (length(pf) == 0) stop("No four-year panel files in ", data_dir, ". Set multi_year_panels in R/01_extract_meps.R.")
pan <- do.call(rbind, lapply(pf, function(x) {
  d <- read.csv(x); d$panel_file <- basename(x)
  d$w_long <- d$LONGWT / sum(d$LONGWT); d$w_saq <- d$LSAQWT / sum(d$LSAQWT); d }))
pan$w_long <- pan$w_long / length(pf); pan$w_saq <- pan$w_saq / length(pf)
OUT <- list(K6 = list(v = paste0("K6SUM", c(2, 4, 6, 8)), w = "w_saq"),
            VR12_MCS = list(v = paste0("VMCS", c(2, 4, 6, 8)), w = "w_saq"),
            spending = list(v = paste0("TOTEXPY", 1:4), w = "w_long"))

wecdf <- function(b, w) { o <- order(b); cw <- cumsum(w[o]); f <- numeric(length(b)); f[o] <- cw - w[o] / 2; f }

fit_all <- function(Y, g, n) {          # Y: 2n x 4 matrix with NA for missing; g: arm
  out <- list()
  o3 <- !is.na(Y[, 4])
  out$ancova_last_cc <- coef(summary(lm(Y[o3, 4] ~ g[o3] + Y[o3, 1])))[2, 1:2]
  mf <- rowMeans(Y[, 2:4], na.rm = TRUE); om <- is.finite(mf)
  out$ancova_mean <- coef(summary(lm(mf[om] ~ g[om] + Y[om, 1])))[2, 1:2]
  long <- data.frame(id = rep(seq_len(2 * n), 4), tnum = rep(1:4, each = 2 * n), y = as.vector(Y), g = rep(g, 4))
  long <- long[!is.na(long$y), ]; long <- long[order(long$id, long$tnum), ]
  long$tf <- factor(long$tnum); long$tlin <- long$tnum - 1
  for (k in 2:4) long[[paste0("tg", k)]] <- long$g * (long$tnum == k)
  fm <- try(nlme::gls(y ~ tf + tg2 + tg3 + tg4, data = long, correlation = nlme::corSymm(form = ~ tnum | id),
                      weights = nlme::varIdent(form = ~ 1 | tf), control = nlme::glsControl(msMaxIter = 200)), silent = TRUE)
  out$mmrm <- if (inherits(fm, "try-error")) c(NA, NA) else summary(fm)$tTable["tg4", 1:2]
  long$gt <- long$g * long$tlin
  fl <- try(nlme::lme(y ~ tf + gt, random = ~ tlin | id, data = long,
                      control = nlme::lmeControl(opt = "optim", returnObject = TRUE)), silent = TRUE)
  out$lmm_slope <- if (inherits(fl, "try-error")) c(NA, NA) else 3 * summary(fl)$tTable["gt", 1:2]
  fg <- try(geepack::geeglm(y ~ tf + tg2 + tg3 + tg4, id = id, data = long, corstr = "exchangeable"), silent = TRUE)
  out$gee_exch <- if (inherits(fg, "try-error")) c(NA, NA) else coef(summary(fg))["tg4", 1:2]
  d <- data.frame(y0 = Y[, 1], y3 = Y[, 4], r = as.integer(o3))
  m <- lapply(0:1, function(k) suppressWarnings(lm(y3 ~ ns(y0, df = 3), data = d[g == k & o3, ])))
  p <- lapply(0:1, function(k) suppressWarnings(glm(r ~ ns(y0, df = 3), family = binomial, data = d[g == k, ])))
  mu <- sapply(m, function(f) suppressWarnings(predict(f, d)))
  pr <- sapply(p, function(f) pmax(suppressWarnings(predict(f, d, type = "response")), 0.02))
  y3z <- ifelse(o3, Y[, 4], 0)
  psi <- mu[, 2] - mu[, 1] + g * d$r * (y3z - mu[, 2]) / (0.5 * pr[, 2]) - (1 - g) * d$r * (y3z - mu[, 1]) / (0.5 * pr[, 1])
  out$aipw_last <- c(mean(psi), sd(psi) / sqrt(2 * n))
  do.call(rbind, out)
}

rows <- list(); design <- list()
for (k in names(OUT)) {
  Yp <- as.matrix(pan[, OUT[[k]]$v]); Yp[Yp < 0] <- NA
  keep <- pan$AGEY1X >= 18 & pan[[OUT[[k]]$w]] > 0 & !is.na(Yp[, 1])
  Yp <- Yp[keep, ]; w <- pan[[OUT[[k]]$w]][keep]; w <- w / sum(w)
  Fb <- wecdf(Yp[, 1], w)
  o4 <- !is.na(Yp[, 4]); w4 <- w[o4] / sum(w[o4])
  m4 <- sum(w4 * Yp[o4, 4]); s4 <- sqrt(sum(w4 * (Yp[o4, 4] - m4)^2)); m1 <- sum(w4 * Yp[o4, 1])
  rho <- sum(w4 * (Yp[o4, 1] - m1) * (Yp[o4, 4] - m4)) / (sqrt(sum(w4 * (Yp[o4, 1] - m1)^2)) * s4)
  done <- sum(w[o4]); delta <- EFFECT_SD * s4
  n <- ceiling(n_per_arm(s4 * sqrt(1 - rho^2), delta) / done)
  pats <- apply(!is.na(Yp), 1, function(z) paste(as.integer(z), collapse = ""))
  design[[k]] <- data.frame(outcome = k, N = nrow(Yp), complete_all = sum(w * (pats == "1111")),
                            observed_last = done, rho_first_last = rho, sd_last = s4, delta = delta, n_per_arm = n)
  alpha <- uniroot(function(a) mean(0.5 * plogis(a + (2 * Fb - 1)) + 0.5 * plogis(a + 2.5 * (2 * Fb - 1))) - 0.25, c(-10, 10))$root
  for (sc in c("A", "B")) {
    varying <- sc == "B"
    ate_last <- if (varying) sum(w * delta * (0.5 + Fb)) else delta
    ate_mean <- ate_last * mean((1:3) / 3)
    ck <- sprintf("output/ckpt/09_%s_%s_%d.rds", k, sc, REPS)
    res <- if (file.exists(ck)) readRDS(ck) else mclapply(seq_len(REPS), function(r) {
      i <- sample.int(nrow(Yp), 2 * n, TRUE, prob = w); g <- rep(0:1, each = n)
      Y <- Yp[i, ]; fac <- if (varying) 0.5 + Fb[i] else 1
      for (t in 2:4) Y[, t] <- Y[, t] + g * delta * fac * (t - 1) / 3
      if (sc == "B") {                     # extra MAR dropout, from a random follow-up onwards
        u <- 2 * Fb[i] - 1
        drop <- rbinom(2 * n, 1, plogis(alpha + ifelse(g == 1, 2.5, 1) * u)) == 1
        from <- sample(2:4, 2 * n, TRUE)
        for (t in 2:4) Y[drop & from <= t, t] <- NA
      }
      fit_all(Y, g, n)
    }, mc.cores = CORES)
    saveRDS(res, ck)
    for (m in rownames(res[[1]])) {
      tgt <- if (m == "ancova_mean") ate_mean else ate_last
      e <- vapply(res, function(x) x[m, 1], 0); s <- vapply(res, function(x) x[m, 2], 0)
      rows[[length(rows) + 1]] <- data.frame(outcome = k, scenario = if (varying)
        "B: varying effect + MAR dropout" else "A: constant effect, MEPS missingness", method = m, target = tgt,
        relative_bias = (mean(e, na.rm = TRUE) - tgt) / tgt, empirical_se = sd(e, na.rm = TRUE),
        mean_model_se = mean(s, na.rm = TRUE), coverage = mean(abs(e - tgt) <= qnorm(0.975) * s, na.rm = TRUE),
        power = mean(abs(e) > qnorm(0.975) * s, na.rm = TRUE), failed = mean(is.na(e)))
    }
    message(k, ", scenario ", sc, " done")
  }
}
dz <- do.call(rbind, design); res <- do.call(rbind, rows)
write.csv(dz, "output/several_follow_ups_design.csv", row.names = FALSE)
write.csv(res, "output/several_follow_ups.csv", row.names = FALSE)
print(format(dz, digits = 3), row.names = FALSE)
print(res[, c("outcome", "scenario", "method", "relative_bias", "empirical_se", "coverage", "power", "failed")],
      digits = 3, row.names = FALSE)
