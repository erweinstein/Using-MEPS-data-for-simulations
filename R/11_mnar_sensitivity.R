# 11_mnar_sensitivity.R -- Dropout that depends on the missing values themselves (MNAR): what the
# usual analyses do, and what a delta-adjusted (pattern-mixture) sensitivity analysis and its
# tipping point tell us.
#
# Scripts 08-10 kept to missing values that are missing at random (MAR): whether a value is missing
# depends only on what was observed (baseline, arm). Under MAR, MMRM, multiple imputation (MI) and
# AIPW can be valid. If dropout depends on the value that would have been observed (people doing
# badly leave), the data cannot tell MAR from MNAR, so the usual advice (NRC 2010; ICH E9(R1), 2019)
# is a sensitivity analysis: impute under MAR, then shift the imputed values by delta (the mean
# difference between dropouts and completers with the same history, a pattern-mixture model;
# Little 1994; Daniels and Hogan 2008; Daniels et al. 2015) and find the TIPPING POINT, the delta at
# which the conclusion changes (Yan, Lee and Li 2009; Ratitch, O'Kelly and Tosiello 2013).
#
# Setting. The four-year panels (as in script 09), restricted to adults with all four values
# observed, so that the only missing values are the ones we create (monotone dropout) and the true
# answer is known. Baseline = year 1, follow-ups at years 2-4; the treatment effect grows linearly to
# 0.3 SDs of the last value (as in scenario A of script 09). Dropout before follow-up t has hazard
# logit(h) = a_g + b_g * z, about 25% of each arm by the last follow-up, where z is (minus) the
# normal score of a value (a low value, against the direction of the effect, means more dropout):
#   MAR   z from the previous (observed) value Y_{t-1}, b = 1 in both arms;
#   MNAR1 z from the current (missing) value Y_t, b = 1 in both arms (the same mechanism in both);
#   MNAR2 z from Y_t, b = 1.5 in the treated arm, b = 0 in the control arm (treated people who do
#         not benefit leave, a "lack of efficacy" pattern; control dropout completely at random).
#
# Methods (target: the effect at the last follow-up, as if no one had dropped out):
#   ancova_full     ANCOVA (last follow-up on baseline) before any dropout (the reference)
#   ancova_cc       ANCOVA on the people observed at the last follow-up
#   mmrm            MMRM (cLDA form, unstructured covariance, as in script 09); valid under MAR
#   mi_mar          multiple imputation under MAR, by arm (sequential regressions on the earlier
#                   values, proper draws, M = 20), ANCOVA in each completed data set, Rubin's rules
#   mi_delta_oracle the same imputations with the imputed last values shifted by each arm's true
#                   delta (computed from the population, so not available in practice: it shows
#                   what the delta adjustment does when delta is right)
#   mi_cr           reference-based ("copy reference") imputation: treated dropouts imputed from the
#                   control arm's models given their own history (Carpenter, Roger and Kenward 2013)
# For mi_mar we also record the tipping point: the shift delta_1 of the treated arm's imputed last
# values (control arm unshifted) at which the two-sided 5% test stops rejecting, in SDs of the last
# value. A negative tipping point means treated dropouts would have to do that much worse than MAR
# predicts to overturn the result. (The shift moves every imputation's estimate by the same amount,
# so the between-imputation variance is unchanged; the tipping point is solved exactly from the
# stored imputations.)
#
# Output: output/mnar_sensitivity.csv, output/mnar_sensitivity_design.csv (summaries only; no MEPS
# records are written)
# Runtime: about 1-2 hours with the defaults (R11_REPS = 500; finished settings are saved in
# output/ckpt/ and reused). For a quick look, set R11_REPS=50.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
if (!requireNamespace("nlme", quietly = TRUE)) install.packages("nlme")
library(parallel)
RNGkind("L'Ecuyer-CMRG"); set.seed(11)
CORES <- if (.Platform$OS.type == "windows") 1 else 2
REPS <- as.integer(Sys.getenv("R11_REPS", "500")); M_IMP <- 20; EFFECT_SD <- 0.3; DROP <- 0.25
DELTA_GRID <- c(0.1, 0.25, 0.5, 1)        # shifts (SDs of the last value) for the "significant at" shares
dir.create("output/ckpt", recursive = TRUE, showWarnings = FALSE)

# ---- populations (as in script 09), people with all four values -----------------------------------
pf <- list.files(data_dir, "^meps_panel4_.*\\.csv$", full.names = TRUE)
if (length(pf) == 0) stop("No four-year panel files in ", data_dir, ". Set multi_year_panels in R/01_extract_meps.R.")
pan <- do.call(rbind, lapply(pf, function(x) {
  d <- read.csv(x); d$w_long <- d$LONGWT / sum(d$LONGWT); d$w_saq <- d$LSAQWT / sum(d$LSAQWT); d }))
OUT <- list(K6 = list(v = paste0("K6SUM", c(2, 4, 6, 8)), w = "w_saq"),
            VR12_MCS = list(v = paste0("VMCS", c(2, 4, 6, 8)), w = "w_saq"),
            spending = list(v = paste0("TOTEXPY", 1:4), w = "w_long"))
SCEN <- list(MAR = list(cur = FALSE, b = c(1, 1)), MNAR1 = list(cur = TRUE, b = c(1, 1)),
             MNAR2 = list(cur = TRUE, b = c(0, 1.5)))          # b = c(control, treated)

# weighted normal scores: a function of y for each follow-up, from the population's distribution
score_fun <- function(y, w) {
  o <- order(y); ys <- y[o]; cw <- (cumsum(w[o]) - w[o] / 2) / sum(w)
  function(v) qnorm(pmin(pmax(approx(ys, cw, v, rule = 2, ties = list("ordered", mean))$y, 1e-4), 1 - 1e-4))
}

# monotone dropout: returns the visit (2-4) before which the person leaves, or 5 if never
dropout_visit <- function(Y, g, sc, a, Sfun) {
  n <- nrow(Y); out <- rep(5L, n); b <- ifelse(g == 1, sc$b[2], sc$b[1]); aa <- ifelse(g == 1, a[2], a[1])
  for (t in 2:4) {
    z <- -Sfun[[if (sc$cur) t else t - 1]](Y[, if (sc$cur) t else t - 1])
    leave <- out == 5L & runif(n) < plogis(aa + b * z)
    out[leave] <- t
  }
  out
}

# one set of proper sequential imputations; 'from' gives, for each row, the arm whose models impute it
impute_once <- function(Y, g, from) {
  for (t in 2:4) {
    for (k in 0:1) {
      fit_rows <- g == k & !is.na(Y[, t]); X <- cbind(1, Y[fit_rows, 1:(t - 1), drop = FALSE])
      fz <- lm.fit(X, Y[fit_rows, t]); df <- sum(fit_rows) - ncol(X)
      s2 <- sum(fz$residuals^2) / rchisq(1, df)
      XtXi <- chol2inv(qr.R(fz$qr)); beta <- fz$coefficients + drop(t(chol(s2 * XtXi)) %*% rnorm(ncol(X)))
      mis <- is.na(Y[, t]) & from == k
      if (any(mis)) Y[mis, t] <- drop(cbind(1, Y[mis, 1:(t - 1), drop = FALSE]) %*% beta) + rnorm(sum(mis), 0, sqrt(s2))
    }
  }
  Y
}

# Rubin's rules for the ANCOVA arm coefficient over completed data sets, with treated imputed last
# values shifted by d1 and control ones by d0 (closed form in the shift)
rubin_prep <- function(imps, g, Y1, D1, D0) {
  X <- cbind(1, g, Y1); XtXi <- solve(crossprod(X)); H <- XtXi %*% t(X); N <- nrow(X)
  rd <- function(D) D - drop(X %*% (H %*% D))
  list(est = vapply(imps, function(y) sum(H[2, ] * y), 0), r = lapply(imps, function(y) y - drop(X %*% (H %*% y))),
       c1 = sum(H[2, ] * D1), c0 = sum(H[2, ] * D0), r1 = rd(D1), r0 = rd(D0), v22 = XtXi[2, 2], dfres = N - 3)
}
rubin_at <- function(P, d1, d0 = 0) {
  q <- P$est + d1 * P$c1 + d0 * P$c0; M <- length(q)
  u <- vapply(P$r, function(r) sum((r + d1 * P$r1 + d0 * P$r0)^2), 0) / P$dfres * P$v22
  B <- var(q); Tv <- mean(u) + (1 + 1 / M) * B
  nu <- (M - 1) * (1 + mean(u) / ((1 + 1 / M) * B))^2
  c(est = mean(q), se = sqrt(Tv), crit = qt(0.975, nu))
}

fit_all <- function(Y, Yfull, g, s4) {
  n2 <- nrow(Y); out <- list(); o4 <- !is.na(Y[, 4])
  ancova <- function(y, gg, b) coef(summary(lm(y ~ gg + b)))[2, 1:2]
  out$ancova_full <- ancova(Yfull[, 4], g, Yfull[, 1])
  out$ancova_cc <- ancova(Y[o4, 4], g[o4], Y[o4, 1])
  long <- data.frame(id = rep(seq_len(n2), 4), tnum = rep(1:4, each = n2), y = as.vector(Y), g = rep(g, 4))
  long <- long[!is.na(long$y), ]; long <- long[order(long$id, long$tnum), ]; long$tf <- factor(long$tnum)
  for (k in 2:4) long[[paste0("tg", k)]] <- long$g * (long$tnum == k)
  fm <- try(nlme::gls(y ~ tf + tg2 + tg3 + tg4, data = long, correlation = nlme::corSymm(form = ~ tnum | id),
                      weights = nlme::varIdent(form = ~ 1 | tf), control = nlme::glsControl(msMaxIter = 200)), silent = TRUE)
  out$mmrm <- if (inherits(fm, "try-error")) c(NA, NA) else summary(fm)$tTable["tg4", 1:2]
  D1 <- as.numeric(g == 1 & !o4); D0 <- as.numeric(g == 0 & !o4)
  mar <- lapply(seq_len(M_IMP), function(j) impute_once(Y, g, g)[, 4])
  P <- rubin_prep(mar, g, Y[, 1], D1, D0)
  r0 <- rubin_at(P, 0); out$mi_mar <- r0[1:2]
  ro <- rubin_at(P, DELTA_TRUE[2] * s4, DELTA_TRUE[1] * s4); out$mi_delta_oracle <- ro[1:2]
  cr <- lapply(seq_len(M_IMP), function(j) impute_once(Y, g, rep(0, n2))[, 4])
  out$mi_cr <- rubin_at(rubin_prep(cr, g, Y[, 1], D1, D0), 0)[1:2]
  # tipping point (SDs of the last value): lower 95% limit = 0 as the treated shift d1 varies
  lower <- function(d) { r <- rubin_at(P, d * s4); r[1] - r[3] * r[2] }
  tip <- tryCatch(uniroot(lower, c(-30, 30), extendInt = "yes")$root, error = function(e) NA_real_)
  res <- do.call(rbind, out)
  attr(res, "extra") <- c(tip = tip, sig_mar = unname(abs(r0[1]) > r0[3] * r0[2]),
                          sig_oracle = unname(abs(ro[1]) > ro[3] * ro[2]),
                          drop1 = mean(!o4[g == 1]), drop0 = mean(!o4[g == 0]))
  res
}

rows <- list(); design <- list()
for (k in names(OUT)) {
  Yp <- as.matrix(pan[, OUT[[k]]$v]); Yp[Yp < 0] <- NA; w <- pan[[OUT[[k]]$w]]
  keep <- pan$AGEY1X >= 18 & w > 0 & rowSums(is.na(Yp)) == 0
  Yp <- Yp[keep, ]; w <- w[keep] / sum(w[keep])
  Sfun <- lapply(1:4, function(t) score_fun(Yp[, t], w))
  m4 <- sum(w * Yp[, 4]); s4 <- sqrt(sum(w * (Yp[, 4] - m4)^2)); m1 <- sum(w * Yp[, 1])
  rho <- sum(w * (Yp[, 1] - m1) * (Yp[, 4] - m4)) / (sqrt(sum(w * (Yp[, 1] - m1)^2)) * s4)
  delta <- EFFECT_SD * s4
  n <- ceiling(n_per_arm(s4 * sqrt(1 - rho^2), delta) / (1 - DROP))
  add_effect <- function(Y, g) { for (t in 2:4) Y[, t] <- Y[, t] + g * delta * (t - 1) / 3; Y }
  for (scn in names(SCEN)) {
    sc <- SCEN[[scn]]
    # calibrate a (each arm) to 25% dropout by the last follow-up, and find each arm's true delta:
    # the mean of the dropouts' last values minus their MAR-predicted mean (the arm's own
    # sequential regressions on the earlier values, fitted to a very large sample)
    big <- 2e5; ib <- sample.int(nrow(Yp), big, TRUE, prob = w)
    a <- c(0, 0); dtrue <- c(0, 0)
    for (gg in 0:1) {
      Yb <- add_effect(Yp[ib, ], gg)
      zz <- lapply(2:4, function(t) -Sfun[[if (sc$cur) t else t - 1]](Yb[, if (sc$cur) t else t - 1]))
      bb <- sc$b[gg + 1]
      stay <- function(aa) Reduce(`*`, lapply(zz, function(z) 1 - plogis(aa + bb * z)))
      a[gg + 1] <- uniroot(function(aa) mean(stay(aa)) - (1 - DROP), c(-15, 5))$root
      dv <- dropout_visit(Yb, rep(gg, big), sc, rep(a[gg + 1], 2), Sfun)
      Yo <- Yb; for (t in 2:4) Yo[dv <= t, t] <- NA
      pred <- Yo
      for (t in 2:4) {
        f <- lm.fit(cbind(1, Yo[!is.na(Yo[, t]), 1:(t - 1), drop = FALSE]), Yo[!is.na(Yo[, t]), t])
        mis <- is.na(Yo[, t]); pred[mis, t] <- drop(cbind(1, pred[mis, 1:(t - 1), drop = FALSE]) %*% f$coefficients)
      }
      dtrue[gg + 1] <- mean(Yb[dv <= 4, 4] - pred[dv <= 4, 4]) / s4
    }
    DELTA_TRUE <- dtrue
    design[[length(design) + 1]] <- data.frame(outcome = k, scenario = scn, N = nrow(Yp), rho_first_last = rho,
      sd_last = s4, delta = delta, n_per_arm = n, a_control = a[1], a_treated = a[2],
      true_delta_control_sd = dtrue[1], true_delta_treated_sd = dtrue[2])
    ck <- sprintf("output/ckpt/11_%s_%s_%d.rds", k, scn, REPS)
    res <- if (file.exists(ck)) readRDS(ck) else mclapply(seq_len(REPS), function(r) {
      i <- sample.int(nrow(Yp), 2 * n, TRUE, prob = w); g <- rep(0:1, each = n)
      Yfull <- add_effect(Yp[i, ], g)
      dv <- dropout_visit(Yfull, g, sc, a, Sfun)
      Y <- Yfull; for (t in 2:4) Y[dv <= t, t] <- NA
      fit_all(Y, Yfull, g, s4)
    }, mc.cores = CORES, mc.set.seed = TRUE)
    saveRDS(res, ck)
    ex <- do.call(rbind, lapply(res, attr, "extra"))
    for (m in rownames(res[[1]])) {
      e <- vapply(res, function(x) x[m, 1], 0); s <- vapply(res, function(x) x[m, 2], 0)
      rows[[length(rows) + 1]] <- data.frame(outcome = k, scenario = scn, method = m, target = delta,
        relative_bias = (mean(e, na.rm = TRUE) - delta) / delta, empirical_se = sd(e, na.rm = TRUE),
        mean_model_se = mean(s, na.rm = TRUE),
        coverage = mean(abs(e - delta) <= qnorm(0.975) * s, na.rm = TRUE),
        power = mean(abs(e) > qnorm(0.975) * s, na.rm = TRUE), failed = mean(is.na(e)))
    }
    tip <- ex[, "tip"]
    tp <- data.frame(outcome = k, scenario = scn, tip_median = median(tip, na.rm = TRUE),
      tip_p25 = unname(quantile(tip, 0.25, na.rm = TRUE)), tip_p75 = unname(quantile(tip, 0.75, na.rm = TRUE)),
      true_delta_treated = dtrue[2], share_sig_mar = mean(ex[, "sig_mar"]), share_sig_oracle = mean(ex[, "sig_oracle"]),
      share_tip_beyond_true = mean(tip < dtrue[2], na.rm = TRUE),
      dropout_treated = mean(ex[, "drop1"]), dropout_control = mean(ex[, "drop0"]))
    for (d in DELTA_GRID) tp[[paste0("sig_at_minus_", d)]] <- mean(tip < -d, na.rm = TRUE)
    design[[length(design)]] <- cbind(design[[length(design)]], tp[, -(1:2)])
    message(k, ", ", scn, " done")
  }
}
dz <- do.call(rbind, design); res <- do.call(rbind, rows)
write.csv(dz, "output/mnar_sensitivity_design.csv", row.names = FALSE)
write.csv(res, "output/mnar_sensitivity.csv", row.names = FALSE)
print(format(dz, digits = 3), row.names = FALSE)
print(res[, c("outcome", "scenario", "method", "relative_bias", "empirical_se", "mean_model_se", "coverage", "power")],
      digits = 3, row.names = FALSE)
