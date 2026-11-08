# ml_00_extract.R -- The machine learning data set: predict 2023 health care use and spending
# from 2022 characteristics, for adults in MEPS Panel 27 (the two-year longitudinal file).
#
# Why this design. A model that predicts this year's spending from this year's visits or
# diagnoses learns little (the visits are the spending). Health plans, Medicare's risk
# adjustment and most research instead predict *next* year from *this* year: a
# "prospective" design. The MEPS two-year panel file has both years for the same people.
#
# Input:  h252.dta (Panel 27, 2022-2023; HC-252), in `meps_dir`.
# Output: data/meps_ml.csv, one row per adult (18+ at the end of 2022) in scope all five
#         rounds with a positive longitudinal weight (6,353 people for Panel 27), with
#   - predictors from 2022 (year 1): demographics, insurance, health status, chronic
#     conditions, functioning, the self-administered questionnaire (SAQ) scores, and
#     2022 use and spending;
#   - outcomes for 2023 (year 2): spending (`cost`), log(1 + spending) (`log_cost`),
#     top 10% of spenders (`high_cost`), any emergency room visit (`any_er`), any
#     hospital stay (`any_ip`) and the number of office-based visits (`ob_visits`);
#   - `weight` (LONGWT), `stratum`, `psu`, `household` (DUID) and two columns that fix
#     the train/test split and the cross-validation folds, so that the R and Python
#     walkthroughs use exactly the same rows: `test` (30% of households) and `fold`
#     (5 folds of the training households). People in the same household are kept
#     together, because their spending is correlated.
# Missing values. MEPS's negative codes become missing. Numeric predictors are filled
# with the training-set median and get a `_miss` indicator when more than 1% are missing;
# categorical predictors get a "Missing" level. (A simple, transparent choice; the
# walkthrough discusses alternatives.)
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

meps_dir <- "C:/Users/YOU/folder/MEPS 2023"   # <-- folder with h252.dta
out_file <- "data/meps_ml.csv"
panel_file <- "h252"                           # Panel 27 (2022-2023); for other panels see WALKTHROUGH.md

for (p in c("haven", "dplyr")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(haven); library(dplyr)

f <- file.path(meps_dir, paste0(panel_file, ".dta"))
if (!file.exists(f)) stop("Not found: ", f, " (download HC-252 from the MEPS website; see WALKTHROUGH.md)")
d <- read_dta(f)
neg_na <- function(x) { x <- as.numeric(zap_labels(x)); x[x < 0] <- NA; x }
yn <- function(x) { x <- neg_na(x); ifelse(is.na(x), NA, as.numeric(x == 1)) }          # 1 = yes, 2 = no
lev <- function(x, labs) { x <- neg_na(x); factor(ifelse(is.na(x), "Missing", labs[as.character(x)]), levels = c(unname(labs), "Missing")) }

d <- d |> filter(neg_na(AGEY1X) >= 18, ALL5RDS == 1, LONGWT > 0)

ml <- tibble(
  person = d$DUPERSID, household = d$DUID,
  weight = d$LONGWT, stratum = d$VARSTR, psu = d$VARPSU,
  # ---- outcomes, 2023
  cost = neg_na(d$TOTEXPY2),
  ob_visits = neg_na(d$OBTOTVY2),
  any_er = as.numeric(neg_na(d$ERTOTY2) > 0),
  any_ip = as.numeric(neg_na(d$IPDISY2) > 0),
  # ---- predictors, 2022: demographics and coverage
  age = neg_na(d$AGEY1X),
  female = as.numeric(neg_na(d$SEX) == 2),
  race_eth = lev(d$RACETHX, c(`1` = "Hispanic", `2` = "White", `3` = "Black", `4` = "Asian", `5` = "Other or multiple")),
  region = lev(d$REGIONY1, c(`1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West")),
  marital = lev(d$MARRYY1X, c(`1` = "Married", `2` = "Widowed", `3` = "Divorced", `4` = "Separated", `5` = "Never married")),
  education = lev(d$HIDEG, c(`1` = "No degree", `2` = "GED", `3` = "High school", `4` = "Bachelor's", `5` = "Master's",
                             `6` = "Doctorate", `7` = "Other degree")),
  poverty = lev(d$POVCATY1, c(`1` = "Poor", `2` = "Near poor", `3` = "Low income", `4` = "Middle income", `5` = "High income")),
  insurance = lev(d$INSCOVY1, c(`1` = "Any private", `2` = "Public only", `3` = "Uninsured")),
  medicare = yn(d$MCREVY1), medicaid = yn(d$MCDEVY1),
  employed = as.numeric(neg_na(d$EMPST2) %in% 1:3),
  usual_source = yn(d$HAVEUS2),
  # ---- health status and conditions, 2022
  health = neg_na(d$RTHLTH2),             # 1 excellent ... 5 poor
  mental_health = neg_na(d$MNHLTH2),      # 1 excellent ... 5 poor
  high_bp = yn(d$HIBPDXY1), diabetes = yn(d$DIABDXY1_M18), arthritis = yn(d$ARTHDXY1),
  asthma = yn(d$ASTHDXY1), coronary = yn(d$CHDDXY1), heart_attack = yn(d$MIDXY1),
  angina = yn(d$ANGIDXY1), other_heart = yn(d$OHRTDXY1), stroke = yn(d$STRKDXY1),
  emphysema = yn(d$EMPHDXY1), high_chol = yn(d$CHOLDXY1), cancer = yn(d$CANCERY1),
  adl_help = yn(d$ADLHLP1), iadl_help = yn(d$IADLHP1), walk_limit = yn(d$WLKLIM1),
  bmi = neg_na(d$ADBMI2),
  pcs = neg_na(d$VPCS2), mcs = neg_na(d$VMCS2), k6 = neg_na(d$K6SUM2), phq2 = neg_na(d$PHQ22),
  # ---- use and spending, 2022
  cost_2022 = neg_na(d$TOTEXPY1), oop_2022 = neg_na(d$TOTSLFY1),
  ob_visits_2022 = neg_na(d$OBTOTVY1), er_visits_2022 = neg_na(d$ERTOTY1),
  stays_2022 = neg_na(d$IPDISY1), rx_2022 = neg_na(d$RXTOTY1)
)
ml <- ml |> filter(!is.na(cost))

# ---- split by household: about 30% of households for testing, 5 folds among the rest ---------------
# The split is a fixed function of the household ID (integer arithmetic, no random number
# generator), so the R and Python versions of this script give exactly the same split.
hh <- as.numeric(ml$household)
u_test <- ((hh * 7919 + 104729) %% 1000003) / 1000003
u_fold <- ((hh * 15485863 + 32452843) %% 999983) / 999983
ml$test <- as.integer(u_test < 0.3)
ml$fold <- ifelse(ml$test == 1, 0L, as.integer(floor(u_fold * 5)) + 1L)

# ---- outcomes that need the weights: top 10% of spenders (weighted, in 2023) -----------------------
wq <- function(x, w, p) { o <- order(x); x[o][which(cumsum(w[o]) / sum(w) >= p)[1]] }
cut90 <- wq(ml$cost, ml$weight, 0.9)
ml$high_cost <- as.numeric(ml$cost >= cut90)
ml$log_cost <- log1p(ml$cost)

# ---- fill missing numeric predictors with training medians, add indicators -----------------------
num <- c("age", "medicare", "medicaid", "usual_source", "health", "mental_health", "high_bp", "diabetes",
         "arthritis", "asthma", "coronary", "heart_attack", "angina", "other_heart", "stroke", "emphysema",
         "high_chol", "cancer", "adl_help", "iadl_help", "walk_limit", "bmi", "pcs", "mcs", "k6", "phq2",
         "cost_2022", "oop_2022", "ob_visits_2022", "er_visits_2022", "stays_2022", "rx_2022")
for (v in num) {
  m <- is.na(ml[[v]])
  if (mean(m) > 0.01) ml[[paste0(v, "_miss")]] <- as.numeric(m)
  ml[[v]][m] <- median(ml[[v]][ml$test == 0], na.rm = TRUE)
}
ml <- ml |> relocate(test, fold, .after = psu) |> relocate(high_cost, log_cost, .after = cost)

dir.create(dirname(out_file), showWarnings = FALSE)
write.csv(ml, out_file, row.names = FALSE)
message(out_file, ": ", nrow(ml), " adults, ", sum(ml$test), " in the test set; top-10% cut-off $",
        format(round(cut90), big.mark = ","), "; ", ncol(ml), " columns")
