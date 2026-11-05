# 12_robust_se_mmrm_by_arm.R -- Standard errors for the MMRM fitted by arm.
#
# Script 10 found that fitting the MMRM separately in each arm (each arm with its own
# covariance and its own baseline slopes) removed the bias that a varying effect plus
# baseline- and arm-dependent dropout causes, but that its model-based SE was too small
# when it mattered (coverage 89% for the K6 and 83% for spending in scenario B). The
# obvious remedies, tested here in the same three-follow-up setting (script 09/10, Part 2):
#
#   mmrm            MMRM (cLDA form, one unstructured covariance), model-based SE
#   mmrm_cr2        the same fit, cluster-robust (sandwich) SE with the CR2 small-sample
#                   correction (Bell and McCaffrey 2002; Pustejovsky and Tipton 2018;
#                   clubSandwich::vcovCR), people as clusters
#   by_arm          MMRM fitted by arm (linear baseline term at each time, as in script 10),
#                   model-based SE
#   by_arm_cr2      the same fits, CR2 sandwich SE for each arm's time-4 mean, combined as
#                   sqrt(V1 + V0)
#   by_arm_boot     the same estimate, SE from a nonparametric bootstrap of the whole
#                   procedure (people resampled within arm, both arms refitted; B = 100;
#                   scenario B only, where the model-based SE failed, since each trial
#                   then needs 200 more MMRM fits)
#
# The sandwich protects against a wrong covariance model (for example, a variance that
# changes with baseline), but not against a wrong mean model; the bootstrap also carries the
# averaging over everyone's baseline. Neither changes the estimate.
#
# Output: output/robust_se_mmrm_by_arm.csv
# Runtime: about 4-6 hours with the defaults (scenario A: R12_REPS_A = 500 trials, no
# bootstrap; scenario B: R12_REPS_B = 150 trials, R12_B = 100; finished blocks of 50 trials are
# saved in output/ckpt/ and reused). For a quick look, R12_REPS_A=50 R12_REPS_B=50 R12_B=20.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
for (p in c("nlme", "clubSandwich")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(parallel)
RNGkind("L'Ecuyer-CMRG")
CORES <- if (.Platform$OS.type == "windows") 1 else 2
REPS_SC <- c(A = as.integer(Sys.getenv("R12_REPS_A", "500")), B = as.integer(Sys.getenv("R12_REPS_B", "150")))
B_SC <- c(A = 0L, B = as.integer(Sys.getenv("R12_B", "100")))
EFFECT_SD <- 0.3; CHUNK <- 50
SCENARIOS <- strsplit(Sys.getenv("R12_SCENARIOS", "A,B"), ",")[[1]]
dir.create("output/ckpt", recursive = TRUE, showWarnings = FALSE)

wecdf <- function(b, w) { o <- order(b); cw <- cumsum(w[o]); f <- numeric(length(b)); f[o] <- cw - w[o] / 2; f }

# MMRM in one arm, conditional on baseline (as in script 10, linear baseline term); returns the
# time-4 mean at the mean of x0all, its model-based variance and its CR2 variance
mmrm_arm <- function(Y, x0all, robust = TRUE) {
  # (the data frame has a name of its own: clubSandwich re-evaluates the fit's data argument by name,
  # and would otherwise find the pooled data frame of the caller)
  n <- nrow(Y)
  arm_long <- data.frame(id = rep(seq_len(n), 3), tnum = rep(2:4, each = n), y = as.vector(Y[, 2:4]), y0 = rep(Y[, 1], 3))
  arm_long <- arm_long[!is.na(arm_long$y), ]; arm_long <- arm_long[order(arm_long$id, arm_long$tnum), ]
  arm_long$tf <- factor(arm_long$tnum, levels = 2:4); arm_long$z1 <- arm_long$y0 - mean(x0all)
  fit <- nlme::gls(y ~ 0 + tf + tf:z1, data = arm_long, correlation = nlme::corSymm(form = ~ as.integer(tf) | id),
                   weights = nlme::varIdent(form = ~ 1 | tf), control = nlme::glsControl(msMaxIter = 200))
  cf <- coef(fit); a <- setNames(numeric(length(cf)), names(cf)); a["tf4"] <- 1
  vm <- drop(t(a) %*% vcov(fit) %*% a)
  vr <- if (robust) drop(t(a) %*% as.matrix(clubSandwich::vcovCR(fit, cluster = arm_long$id, type = "CR2")) %*% a) else NA
  c(sum(a * cf), vm, vr)
}
by_arm <- function(Y, g, robust = TRUE) {
  e <- lapply(0:1, function(k) mmrm_arm(Y[g == k, ], Y[, 1], robust))
  c(est = e[[2]][1] - e[[1]][1], v_model = e[[2]][2] + e[[1]][2], v_cr2 = e[[2]][3] + e[[1]][3])
}

summarise <- function(res, tgt, labels) {
  rows <- list()
  for (m in rownames(res[[1]])) {
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
run_chunked <- function(tag, reps, f) {
  out <- list()
  for (c0 in seq(1, reps, by = CHUNK)) {
    idx <- c0:min(reps, c0 + CHUNK - 1)
    ck <- sprintf("output/ckpt/12_%s_%05d.rds", tag, c0)
    if (file.exists(ck)) { out <- c(out, readRDS(ck)); next }
    set.seed(12000 + c0 + sum(utf8ToInt(tag)))
    r <- mclapply(idx, function(i) f(), mc.cores = CORES, mc.set.seed = TRUE)
    saveRDS(r, ck); out <- c(out, r)
    message(tag, ": ", max(idx), " of ", reps)
  }
  out
}

pf <- list.files(data_dir, "^meps_panel4_.*\\.csv$", full.names = TRUE)
if (length(pf) == 0) stop("No four-year panel files in ", data_dir, ". Set multi_year_panels in R/01_extract_meps.R.")
p4 <- do.call(rbind, lapply(pf, function(x) {
  d <- read.csv(x); d$w_long <- d$LONGWT / sum(d$LONGWT); d$w_saq <- d$LSAQWT / sum(d$LSAQWT); d }))
OUT2 <- list(K6 = list(v = paste0("K6SUM", c(2, 4, 6, 8)), w = "w_saq"),
             VR12_MCS = list(v = paste0("VMCS", c(2, 4, 6, 8)), w = "w_saq"),
             spending = list(v = paste0("TOTEXPY", 1:4), w = "w_long"))

rows <- list()
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
  for (sc in SCENARIOS) {
    varying <- sc == "B"; REPS <- REPS_SC[[sc]]; B <- B_SC[[sc]]
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
      if (inherits(fm, "try-error")) { out$mmrm <- out$mmrm_cr2 <- rep(NA, 4) } else {
        out$mmrm <- c(summary(fm)$tTable["tg4", 1:2], NA, NA)
        vc <- try(as.matrix(clubSandwich::vcovCR(fm, cluster = long$id, type = "CR2")), silent = TRUE)
        out$mmrm_cr2 <- c(coef(fm)["tg4"], if (inherits(vc, "try-error")) NA else sqrt(vc["tg4", "tg4"]), NA, NA)
      }
      e <- try(by_arm(Y, g), silent = TRUE)
      if (inherits(e, "try-error")) { out$by_arm <- out$by_arm_cr2 <- rep(NA, 4); if (B > 0) out$by_arm_boot <- rep(NA, 4) } else {
        out$by_arm <- c(e[["est"]], sqrt(e[["v_model"]]), NA, NA)
        out$by_arm_cr2 <- c(e[["est"]], sqrt(e[["v_cr2"]]), NA, NA)
        if (B > 0) {
        i0 <- which(g == 0); i1 <- which(g == 1)
        bt <- vapply(seq_len(B), function(b) {
          ii <- c(i0[sample.int(n, n, TRUE)], i1[sample.int(n, n, TRUE)])
          r <- try(by_arm(Y[ii, ], g[ii], robust = FALSE)[["est"]], silent = TRUE)
          if (inherits(r, "try-error")) NA_real_ else r }, 0)
        bt <- bt[is.finite(bt)]
        out$by_arm_boot <- c(e[["est"]], sd(bt), NA, NA)
        }
      }
      do.call(rbind, out)
    }
    res <- run_chunked(paste0(k, "_", sc, "_", REPS, "_", B), REPS, one)
    rows[[length(rows) + 1]] <- summarise(res, ate, data.frame(outcome = k, n_per_arm = n, scenario =
      if (varying) "B: varying effect + MAR dropout" else "A: constant effect, MEPS missingness"))
    message(k, ", scenario ", sc, " done")
  }
}
r <- do.call(rbind, rows)
write.csv(r, "output/robust_se_mmrm_by_arm.csv", row.names = FALSE)
print(r[, c("outcome", "scenario", "method", "relative_bias", "empirical_se", "mean_se", "coverage", "power")],
      digits = 3, row.names = FALSE)
