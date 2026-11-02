# 05_survey_design_and_concentration.R -- Using MEPS's sample design, and a resampling check on it.
#
# MEPS is not a simple random sample: households are clustered in primary
# sampling units (PSUs, VARPSU) within strata (VARSTR), and some groups are
# oversampled, so each person carries a weight (PERWT23F). The other scripts
# use the weights only to draw "representative" plasmode samples; this one does
# survey inference properly, with the survey package (Lumley 2004), and shows:
#   1. mean spending for adults with its Taylor-series (linearization) SE, the
#      design effect, and the SE a naive analysis would report;
#   2. the same SE from a with-replacement bootstrap of PSUs within strata, with
#      rescaled weights (Rao and Wu 1988; survey's "subbootstrap"): a bootstrap
#      that respects the design;
#   3. an economics-style summary of how concentrated spending is: the share of
#      all adult spending accounted for by the top 1%, 5%, 10% and 50% of
#      adults, and the Gini coefficient, with bootstrap SEs.
# A common mistake is to subset the data before declaring the design; the code
# declares it on everyone and then takes the adult subset (a "domain").
#
# Output: output/survey_mean.csv, output/spending_concentration.csv
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
if (!requireNamespace("survey", quietly = TRUE)) install.packages("survey")
library(survey)
options(survey.lonely.psu = "adjust")
set.seed(5)

fyc <- read_meps("meps_fyc2023.csv")
fyc <- subset(fyc, PERWT23F > 0)
fyc$adult <- fyc$AGE23X >= 18
des <- svydesign(id = ~VARPSU, strata = ~VARSTR, weights = ~PERWT23F, data = fyc, nest = TRUE)
ad  <- subset(des, adult)

# 1. Mean spending, Taylor-series SE and design effect
m <- svymean(~TOTEXP23, ad, deff = TRUE)
a <- subset(fyc, adult)
naive_se <- sd(a$TOTEXP23) / sqrt(nrow(a))          # ignores weights, strata and clusters
# 2. Bootstrap of PSUs within strata (Rao-Wu rescaling), 500 replicates
rep_ad <- subset(as.svrepdesign(des, type = "subbootstrap", replicates = 500), adult)
mb <- svymean(~TOTEXP23, rep_ad)
by_dep <- svyby(~TOTEXP23, ~depression, ad, svymean)
tab1 <- data.frame(
  quantity = c("Mean spending, adults", "Taylor-series SE", "Design effect",
               "Naive mean (unweighted)", "Naive SE (unweighted, SRS)",
               "PSU bootstrap SE (500 replicates)", "Mean spending, adults with depression",
               "Mean spending, adults without depression"),
  value = c(coef(m), SE(m), deff(m), mean(a$TOTEXP23), naive_se, SE(mb), coef(by_dep)[2], coef(by_dep)[1]))
write.csv(tab1, "output/survey_mean.csv", row.names = FALSE)
print(format(tab1, digits = 4, big.mark = ","), row.names = FALSE)

# 3. Concentration of spending: top shares and the Gini coefficient
conc <- function(w, data) {
  y <- data$TOTEXP23; keep <- data$adult & w > 0; y <- y[keep]; w <- w[keep]
  o <- order(y, decreasing = TRUE); y <- y[o]; w <- w[o]
  cw <- cumsum(w) / sum(w); cy <- cumsum(w * y) / sum(w * y)
  top <- function(p) cy[which(cw >= p)[1]]
  # Gini from the Lorenz curve (people ordered from lowest to highest spending)
  o2 <- rev(seq_along(y)); x <- c(0, cumsum(w[o2]) / sum(w)); L <- c(0, cumsum(w[o2] * y[o2]) / sum(w * y))
  gini <- 1 - sum((x[-1] - x[-length(x)]) * (L[-1] + L[-length(L)]))
  c(top1 = top(0.01), top5 = top(0.05), top10 = top(0.10), top50 = top(0.50), gini = gini)
}
cb <- withReplicates(as.svrepdesign(des, type = "subbootstrap", replicates = 500), conc)
tab2 <- data.frame(quantity = c("Share of spending, top 1% of adults", "Share, top 5%", "Share, top 10%",
                                "Share, top 50%", "Gini coefficient"),
                   estimate = as.numeric(coef(cb)), bootstrap_se = as.numeric(SE(cb)))
write.csv(tab2, "output/spending_concentration.csv", row.names = FALSE)
print(format(tab2, digits = 3), row.names = FALSE)
