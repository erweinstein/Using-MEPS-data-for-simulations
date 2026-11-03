# 06_parametric_vs_plasmode.R -- Calibrating a parametric data-generating process to MEPS, and what it misses.
#
# The usual alternative to a plasmode simulation is a parametric one whose
# parameters are "calibrated" to real data: fit a model, then simulate from the
# fitted model. For spending, the standard choice in health economics is a
# two-part model (Duan et al. 1983): a logit for any spending, and a model for
# the amount among spenders, either a gamma GLM with a log link or a linear
# model for log spending (Manning and Mullahy 2001). For visit counts, the
# negative binomial. This script fits each to MEPS adults (covariates: age
# group, sex, depression), simulates a synthetic population from the fit, and
# compares the synthetic and real distributions: means match by construction,
# but do the tails? It then reruns a small version of 03's pilot-SD check in
# each synthetic world, to see whether the parametric simulation would have
# reached the same conclusion as the plasmode one.
#
# Output: output/parametric_vs_real.csv, output/parametric_vs_real_pilots.csv
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
library(MASS)
set.seed(6)

fyc <- read_meps("meps_fyc.csv")
a <- subset(fyc, AGE >= 18 & PERWT > 0 & TOTEXP >= 0 & OBTOTV >= 0)
a$age <- cut(a$AGE, c(17, 44, 64, Inf), labels = c("18-44", "45-64", "65+"))
a$sex <- factor(a$SEX); a$dep <- factor(a$depression); a$w <- a$PERWT / mean(a$PERWT)
a$any <- as.numeric(a$TOTEXP > 0)
pos <- subset(a, TOTEXP > 0)

# ---- fit -----------------------------------------------------------------------------------------
f_any  <- glm(any ~ age + sex + dep, family = quasibinomial, data = a, weights = w)
f_gam  <- glm(TOTEXP ~ age + sex + dep, family = Gamma(link = "log"), data = pos, weights = w)
f_logn <- lm(log(TOTEXP) ~ age + sex + dep, data = pos, weights = w)
f_nb   <- glm.nb(OBTOTV ~ age + sex + dep, data = a, weights = w)

# ---- simulate one synthetic value per real person ------------------------------------------------
p_any <- predict(f_any, a, type = "response")
mu_g  <- predict(f_gam, a, type = "response"); shape <- 1 / summary(f_gam)$dispersion
mu_l  <- predict(f_logn, a); sig <- summary(f_logn)$sigma
synth <- data.frame(
  real_spend   = a$TOTEXP,
  gamma_spend  = rbinom(nrow(a), 1, p_any) * rgamma(nrow(a), shape = shape, rate = shape / mu_g),
  lognorm_spend = rbinom(nrow(a), 1, p_any) * exp(rnorm(nrow(a), mu_l, sig)),
  real_visits  = a$OBTOTV,
  nb_visits    = rnbinom(nrow(a), size = f_nb$theta, mu = predict(f_nb, a, type = "response")))
w <- a$PERWT / sum(a$PERWT)
top1 <- function(y, w) { o <- order(y, decreasing = TRUE); cw <- cumsum(w[o]); sum((w * y)[o][cw <= 0.01]) / sum(w * y) }
tab <- do.call(rbind, lapply(names(synth), function(k)
  data.frame(series = k, t(wmoments(synth[[k]], w)), top1_share = top1(synth[[k]], w))))
write.csv(tab, "output/parametric_vs_real.csv", row.names = FALSE)
print(format(tab[, c("series", "mean", "sd", "skewness", "kurtosis", "share_zero", "p99", "max", "top1_share")],
             digits = 3, big.mark = ","), row.names = FALSE)
cat("Fitted gamma shape:", round(shape, 3), " lognormal sigma:", round(sig, 3), " NB theta (size):", round(f_nb$theta, 3), "\n")

# ---- would a parametric simulation have reached the same conclusion? -----------------------------
# Pilot-SD check from 03 (chi-square limit and bootstrap percentile only, q = 0.8)
pilot_check <- function(y, w, m, reps = 1000, B = 499, q = 0.8) {
  sd0 <- wmoments(y, w)[["sd"]]
  r <- replicate(reps, {
    x1 <- y[sample.int(length(y), m, TRUE, prob = w)]; x2 <- y[sample.int(length(y), m, TRUE, prob = w)]
    s <- sqrt((sum((x1 - mean(x1))^2) + sum((x2 - mean(x2))^2)) / (2 * m - 2))
    ss <- function(M) rowSums((M - rowMeans(M))^2)
    ts <- (ss(matrix(sample(x1, B * m, TRUE), B)) + ss(matrix(sample(x2, B * m, TRUE), B))) / (2 * m - 2)
    c(chisq = s * sqrt((2 * m - 2) / qchisq(1 - q, 2 * m - 2)) >= sd0, percentile = sqrt(quantile(ts, q)) >= sd0)
  })
  rowMeans(r)
}
rows <- list()
for (k in names(synth)) for (m in c(20, 60)) {
  pc <- pilot_check(synth[[k]], w, m)
  rows[[length(rows) + 1]] <- data.frame(series = k, m = m, chisq = pc[1], percentile = pc[2])
}
tab2 <- do.call(rbind, rows)
write.csv(tab2, "output/parametric_vs_real_pilots.csv", row.names = FALSE)
print(tab2, digits = 2, row.names = FALSE)
