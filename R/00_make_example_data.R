# 00_make_example_data.R -- SYNTHETIC stand-in data, so the code can be tried without MEPS.
#
# Writes data_example/meps_fyc.csv, meps_stays.csv and meps_panel.csv with the
# same columns (and the same negative missing-value codes) as the files made by
# R/01_extract_meps.R. The values are made up: drawn from simple models with
# MEPS-like features (zeros and long tails in spending, overdispersed visit
# counts, bounded mental health scores, correlated baseline and follow-up,
# survey weights and design variables). They are only for learning the code;
# no result from them says anything about real people.
#
# The scripts use these automatically when data/meps_fyc.csv does not exist.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

set.seed(1996)                                   # MEPS's first year
dir.create("data_example", showWarnings = FALSE)
N <- 15000
id <- sprintf("9%07d", seq_len(N))
age <- pmin(85, round(c(runif(round(0.22 * N), 0, 17.9), runif(N - round(0.22 * N), 18, 85))))
sex <- sample(1:2, N, TRUE)
depression <- rbinom(N, 1, ifelse(age >= 18, 0.10, 0.02))
strat <- sample(1:100, N, TRUE); psu <- sample(1:2, N, TRUE)
w <- round(rlnorm(N, log(20000), 0.6), 2); w[sample.int(N, 400)] <- 0       # a few zero weights, as in MEPS

# spending: two-part (any spending, then a heavy-tailed amount)
lp <- -1.2 + 0.03 * age + 1.5 * depression + 0.3 * (sex == 2)
any <- rbinom(N, 1, plogis(lp + 1.5))
amt <- rgamma(N, shape = 0.35, rate = 0.35 / exp(7.9 + 0.012 * age + 0.5 * depression))
totexp <- round(any * amt)
visits <- rnbinom(N, size = 0.5, mu = exp(0.9 + 0.012 * age + 0.8 * depression)) * any
erv <- rnbinom(N, size = 0.3, mu = 0.2 * (1 + depression))
ipdis <- rbinom(N, 1, 0.06 + 0.002 * (age - 40) * (age > 40))
nights <- ipdis * (1 + rnbinom(N, size = 0.8, mu = 3.5))
rx <- rnbinom(N, size = 0.6, mu = exp(1.5 + 0.02 * age + depression)) * any
# mental health scores, from the self-administered questionnaire (about 60% of adults)
saq <- age >= 18 & runif(N) < 0.62
lat <- rnorm(N) + 1.2 * depression
k6 <- ifelse(saq, pmin(24, pmax(0, round(2.6 * exp(0.55 * lat) - 0.6 + rnorm(N, 0, 0.8)))), -1)
phq2 <- ifelse(saq, pmin(6, pmax(0, round(0.5 * exp(0.6 * lat) + rnorm(N, 0, 0.5)))), -1)
mcs <- ifelse(saq, round(pmin(75, 55 - 6 * lat + rnorm(N, 0, 5)), 2), -1)
fyc <- data.frame(DUPERSID = id, PANEL = sample(27:28, N, TRUE), AGE = age, SEX = sex,
  K6SUM42 = k6, PHQ242 = phq2, VMCS42 = mcs, TOTEXP = totexp, OBTOTV = visits, ERTOT = erv,
  IPDIS = ipdis, IPNGTD = nights, RXTOT = rx, PERWT = w, VARSTR = strat, VARPSU = psu, depression = depression)
write.csv(fyc, "data_example/meps_fyc.csv", row.names = FALSE)

# one row per hospital stay (people with ipdis = 1, some with two stays)
who <- which(ipdis == 1); who <- c(who, sample(who, round(0.3 * length(who))))
st <- data.frame(DUPERSID = id[who], EVNTIDX = paste0(id[who], sprintf("%03d", seq_along(who))),
  NUMNIGHX = rnbinom(length(who), size = 0.9, mu = 4.5), PERWT = w[who], VARSTR = strat[who],
  VARPSU = psu[who], AGE = age[who], depression = depression[who])
st$IPXP <- round(st$NUMNIGHX * rgamma(nrow(st), 2, 2 / 3000) + rgamma(nrow(st), 1.5, 1.5 / 6000))
write.csv(st, "data_example/meps_stays.csv", row.names = FALSE)

# two-year panel: correlated baseline (Y1, round 2) and follow-up (Y2, round 4)
M <- 8000; pid <- sprintf("8%07d", seq_len(M)); a1 <- round(runif(M, 0, 84)); dep <- rbinom(M, 1, 0.1)
l1 <- rnorm(M) + 1.2 * dep; l2 <- 0.75 * l1 + sqrt(1 - 0.75^2) * rnorm(M) + 0.3 * dep * 0.25
sq <- a1 >= 18 & runif(M) < 0.5
mk_k6 <- function(l) ifelse(sq, pmin(24, pmax(0, round(2.6 * exp(0.55 * l) - 0.6 + rnorm(M, 0, 0.8)))), -1)
mk_mcs <- function(l) ifelse(sq, round(pmin(75, 55 - 6 * l + rnorm(M, 0, 5)), 2), -1)
s1 <- rnorm(M); s2 <- 0.6 * s1 + 0.8 * rnorm(M)                                # persistence of spending
spend <- function(s) round(rbinom(M, 1, 0.85) * qgamma(pnorm(s), shape = 0.35, rate = 0.35 / exp(8.2 + 0.5 * dep)))
pan <- data.frame(DUPERSID = pid, AGEY1X = a1, AGEY2X = a1 + 1, SEX = sample(1:2, M, TRUE),
  K6SUM2 = mk_k6(l1), K6SUM4 = mk_k6(l2), VMCS2 = mk_mcs(l1), VMCS4 = mk_mcs(l2),
  TOTEXPY1 = spend(s1), TOTEXPY2 = spend(s2), VARPSU = sample(1:2, M, TRUE), VARSTR = sample(1:100, M, TRUE),
  LONGWT = round(rlnorm(M, log(30000), 0.6), 2))
write.csv(pan, "data_example/meps_panel.csv", row.names = FALSE)
# four-year panel (like HC-245): four annual values, intermittent missing values
M4 <- 5000; a4 <- round(runif(M4, 0, 82)); dep4 <- rbinom(M4, 1, 0.1)
L <- matrix(0, M4, 4); L[, 1] <- rnorm(M4) + 1.2 * dep4
for (t in 2:4) L[, t] <- 0.75 * L[, t - 1] + sqrt(1 - 0.75^2) * rnorm(M4)
S4 <- matrix(0, M4, 4); S4[, 1] <- rnorm(M4); for (t in 2:4) S4[, t] <- 0.6 * S4[, t - 1] + 0.8 * rnorm(M4)
saq4 <- a4 >= 18 & runif(M4) < 0.5
miss <- function() matrix(runif(M4 * 4) < 0.12, M4, 4)
k6m <- sapply(1:4, function(t) ifelse(saq4, pmin(24, pmax(0, round(2.6 * exp(0.55 * L[, t]) - 0.6 + rnorm(M4, 0, 0.8)))), -1))
mcsm <- sapply(1:4, function(t) ifelse(saq4, round(pmin(75, 55 - 6 * L[, t] + rnorm(M4, 0, 5)), 2), -1))
spm <- sapply(1:4, function(t) round(rbinom(M4, 1, 0.85) * qgamma(pnorm(S4[, t]), shape = 0.35, rate = 0.35 / exp(8.2 + 0.5 * dep4))))
k6m[miss()] <- -1; mcsm[miss()] <- -1
dropyr <- sample(c(2:4, 99), M4, TRUE, prob = c(0.02, 0.02, 0.02, 0.94))   # a few leave the survey
for (t in 2:4) spm[dropyr <= t, t] <- -1
p4 <- data.frame(DUPERSID = sprintf("7%07d", seq_len(M4)), PANEL = 24, AGEY1X = a4, SEX = sample(1:2, M4, TRUE))
for (t in 1:4) {
  p4[[paste0("K6SUM", 2 * t)]] <- k6m[, t]; p4[[paste0("VMCS", 2 * t)]] <- mcsm[, t]; p4[[paste0("TOTEXPY", t)]] <- spm[, t]
}
p4$LONGWT <- round(rlnorm(M4, log(30000), 0.6), 2); p4$LSAQWT <- ifelse(saq4, round(rlnorm(M4, log(60000), 0.6), 2), 0)
p4$VARSTR <- sample(1:100, M4, TRUE); p4$VARPSU <- sample(1:2, M4, TRUE)
write.csv(p4, "data_example/meps_panel4_example.csv", row.names = FALSE)
writeLines(c("SYNTHETIC example data (not MEPS)", "Made by R/00_make_example_data.R"), "data_example/meps_info.txt")
message("Synthetic example data written to data_example/")
