# 00_functions.R -- Shared helpers, sourced by the example scripts (02-07).
#
# load_populations() reads the CSVs made by 01_extract_meps.R and returns a list
# of "populations": each is an outcome vector y with survey weights w (scaled to
# sum to 1), restricted to adults (18+) with a positive weight and a valid value.
# MEPS codes missing values as negative numbers (-1 inapplicable, -7 refused,
# -8 don't know, -15 cannot be computed, ...), so for outcomes that cannot be
# negative those rows are dropped; for changes between years, a change is
# computed only when both years are valid.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

data_dir <- "data"
for (p in c("dplyr", "ggplot2")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)

read_meps <- function(name) {
  fn <- file.path(data_dir, name)
  if (!file.exists(fn)) stop("Not found: ", fn, ". Run R/01_extract_meps.R first.")
  read.csv(fn)
}

load_populations <- function() {
  fyc <- read_meps("meps_fyc2023.csv"); pan <- read_meps("meps_panel27.csv"); sty <- read_meps("meps_stays2023.csv")
  a <- subset(fyc, AGE23X >= 18 & PERWT23F > 0); d <- subset(a, depression == 1)
  s <- subset(sty, AGE23X >= 18 & PERWT23F > 0)
  p <- subset(pan, AGEY1X >= 18 & LONGWT > 0)
  chg <- function(x1, x2) ifelse(x1 >= 0 & x2 >= 0, x2 - x1, NA)
  P <- list(
    spend_all   = list(y = a$TOTEXP23, w = a$PERWT23F, label = "Total spending, all adults"),
    spend_dep   = list(y = d$TOTEXP23, w = d$PERWT23F, label = "Total spending, adults with depression"),
    visits_dep  = list(y = d$OBTOTV23, w = d$PERWT23F, label = "Office visits, adults with depression"),
    nights_stay = list(y = s$NUMNIGHX, w = s$PERWT23F, label = "Nights per hospital stay"),
    k6_dep      = list(y = d$K6SUM42,  w = d$PERWT23F, label = "K6 distress score, adults with depression"),
    k6_chg      = list(y = chg(p$K6SUM2, p$K6SUM4), w = p$LONGWT, label = "Change in K6 over a year"),
    mcs_chg     = list(y = chg(p$VMCS2, p$VMCS4),   w = p$LONGWT, label = "Change in VR-12 mental summary over a year"),
    spend_chg   = list(y = chg(p$TOTEXPY1, p$TOTEXPY2), w = p$LONGWT, label = "Change in total spending, 2022 to 2023"))
  for (k in names(P)) {
    ok <- !is.na(P[[k]]$y) & (grepl("_chg$", k) | P[[k]]$y >= 0)
    P[[k]]$y <- P[[k]]$y[ok]; P[[k]]$w <- P[[k]]$w[ok] / sum(P[[k]]$w[ok])
  }
  P
}

# Weighted population moments (the weights make these estimates for US adults)
wmoments <- function(y, w) {
  w <- w / sum(w); m <- sum(w * y); v <- sum(w * (y - m)^2)
  wq <- function(p) { o <- order(y); y[o][which(cumsum(w[o]) >= p)[1]] }
  c(N = length(y), mean = m, sd = sqrt(v), skewness = sum(w * (y - m)^3) / v^1.5,
    kurtosis = sum(w * (y - m)^4) / v^2, share_zero = sum(w * (y == 0)),
    median = wq(0.5), p90 = wq(0.9), p99 = wq(0.99), max = max(y))
}

# Draw a "plasmode" sample of size n: rows drawn with replacement, with
# probability proportional to the survey weight, so each draw is like one
# person sampled at random from the US adult population (as MEPS represents it)
draw <- function(P, n) P$y[sample.int(length(P$y), n, replace = TRUE, prob = P$w)]

# n per arm for a two-sample comparison of means (normal approximation)
n_per_arm <- function(sd, delta, alpha = 0.05, power = 0.8)
  ceiling(2 * (qnorm(1 - alpha / 2) + qnorm(power))^2 * sd^2 / delta^2)
