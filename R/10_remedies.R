# 10_remedies.R -- Testing two remedies suggested by scripts 08 and 09.
#
# Scripts 08 and 09 found two problems when the treatment effect varies with
# baseline and dropout depends on baseline and arm (MAR):
#   (1) ANCOVA, cLDA, MMRM, the random-slope model and GEE were biased (about
#       -3% to -15% of the effect), because each assumes the same baseline-
#       outcome slope (one covariance matrix) in both arms;
#   (2) AIPW was close to unbiased, but its influence-function SE was too small
#       (coverage 85-93% where 95% was intended), mostly for spending.
# The remedies suggested there, tested here:
#
# Part 1 (one follow-up, the script 08 setting):
#   ancova_cc       ANCOVA on complete cases (reference)
#   ancova_lin_cc   Lin (2013) interaction ANCOVA, HC2 SE (as in 08). With one
#                   follow-up and complete baselines, a cLDA or MMRM fitted
#                   separately in each arm gives the same estimate (regression
#                   of follow-up on baseline in each arm, averaged over all
#                   baselines), so it stands in for "MMRM by arm" here
#   aipw            AIPW, influence-function SE (as in 08)
#   aipw_boot       the same estimate, SE from a nonparametric bootstrap of the
#                   whole procedure (resampling people within arm, refitting
#                   both models; B = 200)
#   aipw_boot_pct   the same bootstrap, percentile interval (coverage only)
#   aipw_linear     AIPW with linear (not spline) outcome and dropout models,
#                   influence-function SE: a check on whether the spline fits
#                   (overfitting in small arms) cause the small SEs
#
# Part 2 (three follow-ups, the script 09 setting, MEPS's own missingness plus,
# in scenario B, extra MAR dropout):
#   mmrm            MMRM as in 09 (cLDA form, one unstructured covariance)
#   mmrm_by_arm     MMRM fitted separately in each arm: the follow-ups on time
#                   (as a factor) with a separate baseline slope at each time,
#                   unstructured covariance and variances, so each arm has its
#                   own covariance and its own baseline slopes; the effect at
#                   the last follow-up is the difference of the two arms'
#                   predictions averaged over everyone's baseline (with a
#                   centred baseline, the difference of the time-4 intercepts);
#                   SE = sqrt(V1 + V0) from the two fits
#   mmrm_by_arm_ns  the same with a natural spline in baseline (3 df) at each
#                   time, for a nonlinear baseline-outcome relationship
#   aipw_last       AIPW as in 09, influence-function SE
#   aipw_last_boot  the same estimate, bootstrap SE (B = 200)
#
# Output: output/remedies_one_follow_up.csv, output/remedies_several_follow_ups.csv
# Runtime: several hours with the defaults (R10_REPS1 = 500, R10_REPS2 = 500,
# R10_B = 200; each finished block of 50 trials is saved in output/ckpt/ and
# reused if the script is restarted). For a quick look, set R10_REPS1=100,
# R10_REPS2=50, R10_B=50.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
for (p in c("sandwich", "nlme")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(splines); library(parallel)
RNGkind("L'Ecuyer-CMRG")
CORES <- if (.Platform$OS.type == "windows") 1 else 2
REPS1 <- as.integer(Sys.getenv("R10_REPS1", "500")); REPS2 <- as.integer(Sys.getenv("R10_REPS2", "500"))
B <- as.integer(Sys.getenv("R10_B", "200")); EFFECT_SD <- 0.3; CHUNK <- 50
dir.create("output/ckpt", recursive = TRUE, showWarnings = FALSE)

wecdf <- function(b, w) { o <- order(b); cw <- cumsum(w[o]); f <- numeric(length(b)); f[o] <- cw - w[o] / 2; f }

# AIPW for a missing outcome y (r = 1 observed), randomization probability 1/2.
# Returns the estimate and the influence-function SE.
aipw <- function(y0, y, r, g, spline = TRUE) {
  d <- data.frame(y0 = y0, y = ifelse(r == 1, y, NA), r = r)
  fo <- if (spline) y ~ ns(y0, df = 3) else y ~ y0
  fr <- if (spline) r ~ ns(y0, df = 3) else r ~ y0
  mu <- pr <- matrix(1, nrow(d), 2)
  for (k in 0:1) {
    mu[, k + 1] <- suppressWarnings(predict(lm(fo, data = d[g == k & r == 1, ]), d))
    if (any(r[g == k] == 0))
      pr[, k + 1] <- pmax(suppressWarnings(predict(glm(fr, family = binomial, data = d[g == k, ]), d, type = "response")), 0.02)
  }
  yz <- ifelse(r == 1, y, 0)
  psi <- mu[, 2] - mu[, 1] + g * r * (yz - mu[, 2]) / (0.5 * pr[, 2]) - (1 - g) * r * (yz - mu[, 1]) / (0.5 * pr[, 1])
  c(mean(psi), sd(psi) / sqrt(length(psi)))
}
# Bootstrap of the whole AIPW procedure, resampling people within arm
aipw_boot <- function(y0, y, r, g, B) {
  i0 <- which(g == 0); i1 <- which(g == 1)
  vapply(seq_len(B), function(b) {
    i <- c(i0[sample.int(length(i0), length(i0), TRUE)], i1[sample.int(length(i1), length(i1), TRUE)])
    e <- try(aipw(y0[i], y[i], r[i], g[i])[1], silent = TRUE)
    if (inherits(e, "try-error")) NA_real_ else e }, 0)
}
add_boot <- function(est, bt, out, name) {
  bt <- bt[is.finite(bt)]
  out[[name]] <- c(est, sd(bt), NA, NA)
  out[[paste0(name, "_pct")]] <- c(est, NA, quantile(bt, c(0.025, 0.975), names = FALSE))
  out
}

summarise <- function(res, target_of, labels) {
  rows <- list()
  for (m in rownames(res[[1]])) {
    tgt <- target_of(m)
    e <- vapply(res, function(x) x[m, 1], 0); s <- vapply(res, function(x) x[m, 2], 0)
    lo <- vapply(res, function(x) x[m, 3], 0); hi <- vapply(res, function(x) x[m, 4], 0)
    pct <- all(is.na(s)) && any(is.finite(lo))
    cover <- if (pct) mean(lo <= tgt & tgt <= hi, na.rm = TRUE) else mean(abs(e - tgt) <= qnorm(0.975) * s, na.rm = TRUE)
    power <- if (pct) mean(lo > 0 | hi < 0, na.rm = TRUE) else mean(abs(e) > qnorm(0.975) * s, na.rm = TRUE)
    rows[[length(rows) + 1]] <- data.frame(labels, method = m, target = tgt,
      relative_bias = (mean(e, na.rm = TRUE) - tgt) / tgt, empirical_se = sd(e, na.rm = TRUE),
      mean_se = if (pct) NA else mean(s, na.rm = TRUE), median_se = if (pct) NA else median(s, na.rm = TRUE),
      coverage = cover, power = power, failed = mean(is.na(e)))
  }
  do.call(rbind, rows)
}

# Run reps in chunks of CHUNK, each saved to output/ckpt/ (survives restarts)
run_chunked <- function(tag, reps, f) {
  out <- list()
  for (c0 in seq(1, reps, by = CHUNK)) {
    idx <- c0:min(reps, c0 + CHUNK - 1)
    ck <- sprintf("output/ckpt/10_%s_%05d.rds", tag, c0)
    if (file.exists(ck)) { out <- c(out, readRDS(ck)); next }
    set.seed(10000 + c0 + sum(utf8ToInt(tag)))
    r <- mclapply(idx, function(i) f(), mc.cores = CORES, mc.set.seed = TRUE)
    saveRDS(r, ck); out <- c(out, r)
    message(tag, ": ", max(idx), " of ", reps)
  }
  out
}

# ---- Part 1: one follow-up (script 08 setting) ----------------------------------------------------
pan <- subset(read_meps("meps_panel.csv"), AGEY1X >= 18 & LONGWT > 0)
OUT1 <- list(K6 = c("K6SUM2", "K6SUM4"), VR12_MCS = c("VMCS2", "VMCS4"), spending = c("TOTEXPY1", "TOTEXPY2"))
rows1 <- list()
for (k in names(OUT1)) {
  b <- pan[[OUT1[[k]][1]]]; f <- pan[[OUT1[[k]][2]]]; ok <- b >= 0 & f >= 0
  b <- b[ok]; f <- f[ok]; w <- pan$LONGWT[ok] / sum(pan$LONGWT[ok])
  Fb <- wecdf(b, w); mf <- sum(w * f); sf <- sqrt(sum(w * (f - mf)^2))
  mb <- sum(w * b); sb <- sqrt(sum(w * (b - mb)^2)); rho <- sum(w * (b - mb) * (f - mf)) / (sb * sf)
  delta <- EFFECT_SD * sf; n <- n_per_arm(sf * sqrt(1 - rho^2), delta)
  alpha <- uniroot(function(a) mean(0.5 * plogis(a + (2 * Fb - 1)) + 0.5 * plogis(a + 2.5 * (2 * Fb - 1))) - 0.25, c(-10, 10))$root
  for (varying in c(FALSE, TRUE)) {
    ate <- if (varying) sum(w * delta * (0.5 + Fb)) else delta
    lab <- paste0(if (varying) "varying effect" else "constant effect", ", MAR dropout")
    one <- function() {
      i <- sample.int(length(b), 2 * n, TRUE, prob = w); g <- rep(0:1, each = n)
      y1 <- b[i]; u <- 2 * Fb[i] - 1
      y2 <- f[i] + g * (if (varying) delta * (0.5 + Fb[i]) else delta)
      r <- rbinom(2 * n, 1, 1 - plogis(alpha + ifelse(g == 1, 2.5, 1) * u)); o <- r == 1
      out <- list()
      out$ancova_cc <- c(coef(summary(lm(y2[o] ~ g[o] + y1[o])))[2, 1:2], NA, NA)
      dl <- data.frame(y2 = y2, g = g, yc = y1 - mean(y1))[o, ]
      fl <- lm(y2 ~ g * yc, data = dl)
      out$ancova_lin_cc <- c(coef(fl)["g"], sqrt(sandwich::vcovHC(fl, type = "HC2")["g", "g"]), NA, NA)
      a <- aipw(y1, y2, r, g); out$aipw <- c(a, NA, NA)
      out <- add_boot(a[1], aipw_boot(y1, y2, r, g, B), out, "aipw_boot")
      out$aipw_linear <- c(aipw(y1, y2, r, g, spline = FALSE), NA, NA)
      do.call(rbind, out)
    }
    res <- run_chunked(paste0("p1_", k, "_", if (varying) "vary" else "const", "_", REPS1, "_", B), REPS1, one)
    rows1[[length(rows1) + 1]] <- summarise(res, function(m) ate,
                                            data.frame(outcome = k, n_per_arm = n, scenario = lab))
    message("Part 1: ", k, ", ", lab, " done")
  }
}
r1 <- do.call(rbind, rows1)
write.csv(r1, "output/remedies_one_follow_up.csv", row.names = FALSE)
print(r1[, c("outcome", "scenario", "method", "relative_bias", "empirical_se", "mean_se", "coverage", "power")],
      digits = 3, row.names = FALSE)

# ---- Part 2: three follow-ups (script 09 setting) -------------------------------------------------
pf <- list.files(data_dir, "^meps_panel4_.*\\.csv$", full.names = TRUE)
if (length(pf) == 0) stop("No four-year panel files in ", data_dir, ". Set multi_year_panels in R/01_extract_meps.R.")
p4 <- do.call(rbind, lapply(pf, function(x) {
  d <- read.csv(x); d$w_long <- d$LONGWT / sum(d$LONGWT); d$w_saq <- d$LSAQWT / sum(d$LSAQWT); d }))
OUT2 <- list(K6 = list(v = paste0("K6SUM", c(2, 4, 6, 8)), w = "w_saq"),
             VR12_MCS = list(v = paste0("VMCS", c(2, 4, 6, 8)), w = "w_saq"),
             spending = list(v = paste0("TOTEXPY", 1:4), w = "w_long"))

# MMRM in one arm, conditional on baseline: follow-ups 2-4 on time with a
# separate baseline term at each time; returns the time-4 mean averaged over
# the baselines of everyone randomized (x0all), with its variance
mmrm_arm <- function(Y, x0all, spline) {
  n <- nrow(Y)
  long <- data.frame(id = rep(seq_len(n), 3), tnum = rep(2:4, each = n), y = as.vector(Y[, 2:4]), y0 = rep(Y[, 1], 3))
  long <- long[!is.na(long$y), ]; long <- long[order(long$id, long$tnum), ]
  long$tf <- factor(long$tnum, levels = 2:4)
  if (spline) {
    bs <- ns(x0all, df = 3)                       # basis fixed on all randomized baselines
    Z <- predict(bs, long$y0); for (j in 1:3) long[[paste0("z", j)]] <- Z[, j]
    fm <- y ~ 0 + tf + tf:z1 + tf:z2 + tf:z3
    zbar <- colMeans(predict(bs, x0all))
  } else {
    long$z1 <- long$y0 - mean(x0all); fm <- y ~ 0 + tf + tf:z1; zbar <- 0
  }
  fit <- nlme::gls(fm, data = long, correlation = nlme::corSymm(form = ~ as.integer(tf) | id),
                   weights = nlme::varIdent(form = ~ 1 | tf), control = nlme::glsControl(msMaxIter = 200))
  cf <- coef(fit); V <- vcov(fit); nm <- names(cf)
  a <- setNames(numeric(length(cf)), nm); a["tf4"] <- 1
  for (j in seq_along(zbar)) a[paste0("tf4:z", j)] <- zbar[j]
  c(sum(a * cf), drop(t(a) %*% V %*% a))
}

rows2 <- list(); design2 <- list()
for (k in names(OUT2)) {
  Yp <- as.matrix(p4[, OUT2[[k]]$v]); Yp[Yp < 0] <- NA
  keep <- p4$AGEY1X >= 18 & p4[[OUT2[[k]]$w]] > 0 & !is.na(Yp[, 1])
  Yp <- Yp[keep, ]; w <- p4[[OUT2[[k]]$w]][keep]; w <- w / sum(w)
  Fb <- wecdf(Yp[, 1], w)
  o4 <- !is.na(Yp[, 4]); w4 <- w[o4] / sum(w[o4])
  m4 <- sum(w4 * Yp[o4, 4]); s4 <- sqrt(sum(w4 * (Yp[o4, 4] - m4)^2)); m1 <- sum(w4 * Yp[o4, 1])
  rho <- sum(w4 * (Yp[o4, 1] - m1) * (Yp[o4, 4] - m4)) / (sqrt(sum(w4 * (Yp[o4, 1] - m1)^2)) * s4)
  done <- sum(w[o4]); delta <- EFFECT_SD * s4
  n <- ceiling(n_per_arm(s4 * sqrt(1 - rho^2), delta) / done)
  alpha <- uniroot(function(a) mean(0.5 * plogis(a + (2 * Fb - 1)) + 0.5 * plogis(a + 2.5 * (2 * Fb - 1))) - 0.25, c(-10, 10))$root
  for (sc in c("A", "B")) {
    varying <- sc == "B"
    ate <- if (varying) sum(w * delta * (0.5 + Fb)) else delta
    one <- function() {
      i <- sample.int(nrow(Yp), 2 * n, TRUE, prob = w); g <- rep(0:1, each = n)
      Y <- Yp[i, ]; fac <- if (varying) 0.5 + Fb[i] else 1
      for (t in 2:4) Y[, t] <- Y[, t] + g * delta * fac * (t - 1) / 3
      if (varying) {
        u <- 2 * Fb[i] - 1
        drop <- rbinom(2 * n, 1, plogis(alpha + ifelse(g == 1, 2.5, 1) * u)) == 1
        from <- sample(2:4, 2 * n, TRUE)
        for (t in 2:4) Y[drop & from <= t, t] <- NA
      }
      out <- list()
      long <- data.frame(id = rep(seq_len(2 * n), 4), tnum = rep(1:4, each = 2 * n), y = as.vector(Y), g = rep(g, 4))
      long <- long[!is.na(long$y), ]; long <- long[order(long$id, long$tnum), ]
      long$tf <- factor(long$tnum); for (j in 2:4) long[[paste0("tg", j)]] <- long$g * (long$tnum == j)
      fm <- try(nlme::gls(y ~ tf + tg2 + tg3 + tg4, data = long, correlation = nlme::corSymm(form = ~ tnum | id),
                          weights = nlme::varIdent(form = ~ 1 | tf), control = nlme::glsControl(msMaxIter = 200)), silent = TRUE)
      out$mmrm <- if (inherits(fm, "try-error")) rep(NA, 4) else c(summary(fm)$tTable["tg4", 1:2], NA, NA)
      for (sp in c(FALSE, TRUE)) {
        e <- try(lapply(0:1, function(a) mmrm_arm(Y[g == a, ], Y[, 1], sp)), silent = TRUE)
        out[[if (sp) "mmrm_by_arm_ns" else "mmrm_by_arm"]] <- if (inherits(e, "try-error")) rep(NA, 4) else
          c(e[[2]][1] - e[[1]][1], sqrt(e[[2]][2] + e[[1]][2]), NA, NA)
      }
      r <- as.integer(!is.na(Y[, 4]))
      a <- aipw(Y[, 1], Y[, 4], r, g); out$aipw_last <- c(a, NA, NA)
      out <- add_boot(a[1], aipw_boot(Y[, 1], Y[, 4], r, g, B), out, "aipw_last_boot")
      do.call(rbind, out)
    }
    res <- run_chunked(paste0("p2_", k, "_", sc, "_", REPS2, "_", B), REPS2, one)
    rows2[[length(rows2) + 1]] <- summarise(res, function(m) ate, data.frame(outcome = k, n_per_arm = n, scenario =
      if (varying) "B: varying effect + MAR dropout" else "A: constant effect, MEPS missingness"))
    message("Part 2: ", k, ", scenario ", sc, " done")
  }
}
r2 <- do.call(rbind, rows2)
write.csv(r2, "output/remedies_several_follow_ups.csv", row.names = FALSE)
print(r2[, c("outcome", "scenario", "method", "relative_bias", "empirical_se", "mean_se", "coverage", "power")],
      digits = 3, row.names = FALSE)
