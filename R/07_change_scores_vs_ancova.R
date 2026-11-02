# 07_change_scores_vs_ancova.R -- Baseline and follow-up from the MEPS panel: change score or ANCOVA?
#
# A trial with a baseline measurement can analyse the follow-up alone, the
# change from baseline, or the follow-up adjusted for baseline (ANCOVA). With
# correlation rho between baseline and follow-up (and equal SDs), the variances
# are sigma^2, 2 sigma^2 (1 - rho) and sigma^2 (1 - rho^2): the change score
# beats the follow-up alone only when rho > 0.5, and ANCOVA is never worse than
# either (Frison and Pocock 1992; Vickers and Altman 2001). The MEPS Panel 27
# file has the same people in 2022 and 2023, so these quantities can be read off
# real outcomes, and a plasmode trial can check the power each analysis gives.
#
# For each outcome (K6, VR-12 mental summary, total spending): weighted SDs,
# rho, and the n per arm each analysis needs to detect a difference of 0.3
# follow-up SDs with 80% power; then 2,000 simulated trials at the n ANCOVA
# needs, drawing (baseline, follow-up) pairs from the panel with the weights and
# adding the difference to the treatment arm's follow-up.
#
# Output: output/change_vs_ancova.csv
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
set.seed(7)
pan <- read_meps("meps_panel27.csv")
pan <- subset(pan, AGEY1X >= 18 & LONGWT > 0)
OUT <- list(K6 = c("K6SUM2", "K6SUM4"), VR12_MCS = c("VMCS2", "VMCS4"), spending = c("TOTEXPY1", "TOTEXPY2"))
REPS <- 2000; EFFECT_SD <- 0.3

rows <- list()
for (k in names(OUT)) {
  b <- pan[[OUT[[k]][1]]]; f <- pan[[OUT[[k]][2]]]; ok <- b >= 0 & f >= 0
  b <- b[ok]; f <- f[ok]; w <- pan$LONGWT[ok] / sum(pan$LONGWT[ok])
  mb <- sum(w * b); mf <- sum(w * f)
  sb <- sqrt(sum(w * (b - mb)^2)); sf <- sqrt(sum(w * (f - mf)^2)); rho <- sum(w * (b - mb) * (f - mf)) / (sb * sf)
  sc <- sqrt(sum(w * ((f - b) - (mf - mb))^2))
  beta <- rho * sf / sb; sa <- sqrt(sum(w * ((f - mf) - beta * (b - mb))^2))   # residual SD, ANCOVA
  delta <- EFFECT_SD * sf
  n_f <- n_per_arm(sf, delta); n_c <- n_per_arm(sc, delta); n_a <- n_per_arm(sa, delta)
  pw <- rowMeans(replicate(REPS, {
    i <- sample.int(length(b), 2 * n_a, TRUE, prob = w); g <- rep(0:1, each = n_a)
    bb <- b[i]; ff <- f[i] + delta * g
    c(follow_up = t.test(ff ~ g)$p.value < 0.05, change = t.test((ff - bb) ~ g)$p.value < 0.05,
      ancova = summary(lm(ff ~ g + bb))$coefficients["g", 4] < 0.05)
  }))
  rows[[k]] <- data.frame(outcome = k, N = length(b), sd_baseline = sb, sd_follow_up = sf, rho = rho,
    sd_change = sc, sd_ancova_resid = sa, n_follow_up = n_f, n_change = n_c, n_ancova = n_a,
    power_follow_up = pw[1], power_change = pw[2], power_ancova = pw[3])
  message(k, " done")
}
tab <- do.call(rbind, rows)
write.csv(tab, "output/change_vs_ancova.csv", row.names = FALSE)
print(format(tab, digits = 3, big.mark = ","), row.names = FALSE)
