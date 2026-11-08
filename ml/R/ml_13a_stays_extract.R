# ml_13a_stays_extract.R -- R version of ml/python/ml_13a_stays_extract.py: the two data sets for
# chapter 13. Either script writes the same files (same rows, columns and split):
#   data/meps_stays.csv      one row per hospital stay of an adult, 2021-2023 (nights per stay)
#   data/meps_util_2023.csv  adults in the 2023 full-year file, with "high use" as defined in IBM's
#                            AI Fairness 360 MEPS example (10+ office, outpatient and ER visits,
#                            inpatient nights and home health visits)
# See the Python script's header for the design, the variables and what is left out on purpose.
# Not redistributed (MEPS data use agreement); git ignores data/.
#
# Files (MEPS public use files, Stata format): h229d, h229if1, h231, h233 (2021); h239d, h239if1,
# h241, h243 (2022); h248d, h248if1, h249, h251 (2023).
#
# Usage:  Rscript ml/R/ml_13a_stays_extract.R "C:/Users/YOU/folder/MEPS raw"
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

args <- commandArgs(trailingOnly = TRUE)
meps_dir <- if (length(args)) args[1] else "C:/Users/YOU/folder/MEPS raw"   # <-- change
files <- list(`2021` = c("h229d", "h229if1", "h231", "h233"), `2022` = c("h239d", "h239if1", "h241", "h243"),
              `2023` = c("h248d", "h248if1", "h249", "h251"))
body <- c("BLD", "CIR", "DEN", "DIG", "EAR", "END", "EXT", "EYE", "FAC", "GEN", "INF", "INJ", "MAL", "MBD", "MUS",
          "NEO", "NVS", "PNL", "PRG", "RSP", "SKN", "SYM")
rd <- function(f, cols = NULL) { d <- haven::read_dta(file.path(meps_dir, paste0(f, ".dta")), col_select = if (is.null(cols)) tidyselect::everything() else tidyselect::all_of(cols))
  as.data.frame(haven::zap_labels(d)) }
neg_na <- function(x) { x <- suppressWarnings(as.numeric(x)); x[x < 0] <- NA; x }
yn <- function(x) { x <- neg_na(x); ifelse(is.na(x), NA, as.numeric(x == 1)) }
lev <- function(x, labs) { x <- neg_na(x); out <- unname(labs[as.character(x)]); out[is.na(out)] <- "Missing"; out }
RACE <- c(`1` = "Hispanic", `2` = "White", `3` = "Black", `4` = "Asian", `5` = "Other or multiple")
REG <- c(`1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West")
MAR <- c(`1` = "Married", `2` = "Widowed", `3` = "Divorced", `4` = "Separated", `5` = "Never married")
EDU <- c(`1` = "No degree", `2` = "GED", `3` = "High school", `4` = "Bachelor's", `5` = "Master's", `6` = "Doctorate", `7` = "Other degree")
POV <- c(`1` = "Poor", `2` = "Near poor", `3` = "Low income", `4` = "Middle income", `5` = "High income")
INS <- c(`1` = "Any private", `2` = "Public only", `3` = "Uninsured")

person_vars <- function(p, yy) data.frame(
  person = p$DUPERSID, stratum = p$VARSTR, psu = p$VARPSU, weight = p[[sprintf("PERWT%dF", yy)]],
  age = neg_na(p[[sprintf("AGE%dX", yy)]]), female = as.numeric(neg_na(p$SEX) %in% 2),
  race_eth = lev(p$RACETHX, RACE), region = lev(p[[sprintf("REGION%d", yy)]], REG), marital = lev(p[[sprintf("MARRY%dX", yy)]], MAR),
  education = lev(p$HIDEG, EDU), poverty = lev(p[[sprintf("POVCAT%d", yy)]], POV), insurance = lev(p[[sprintf("INSCOV%d", yy)]], INS),
  medicare = yn(p[[sprintf("MCREV%d", yy)]]), medicaid = yn(p[[sprintf("MCDEV%d", yy)]]), usual_source = yn(p$HAVEUS42),
  health = neg_na(p$RTHLTH31), mental_health = neg_na(p$MNHLTH31), high_bp = yn(p$HIBPDX), coronary = yn(p$CHDDX),
  angina = yn(p$ANGIDX), heart_attack = yn(p$MIDX), other_heart = yn(p$OHRTDX), stroke = yn(p$STRKDX), emphysema = yn(p$EMPHDX),
  high_chol = yn(p$CHOLDX), cancer = yn(p$CANCERDX), diabetes = yn(p$DIABDX_M18), arthritis = yn(p$ARTHDX), asthma = yn(p$ASTHDX),
  adl_help = yn(p$ADLHLP31), iadl_help = yn(p$IADLHP31), walk_limit = yn(p$WLKLIM31),
  pcs = neg_na(p$VPCS42), mcs = neg_na(p$VMCS42), k6 = neg_na(p$K6SUM42), stringsAsFactors = FALSE)

split_folds <- function(d) {
  hh <- as.numeric(d$household)
  d$test <- as.integer(((hh * 7919 + 104729) %% 1000003) / 1000003 < 0.3)
  d$fold <- ifelse(d$test == 1, 0L, as.integer(floor(((hh * 15485863 + 32452843) %% 999983) / 999983 * 5)) + 1L)
  d
}
impute <- function(d, vars) { for (v in vars) { m <- is.na(d[[v]]); if (mean(m) > 0.01) d[[paste0(v, "_miss")]] <- as.numeric(m)
  d[[v]][m] <- median(d[[v]][d$test == 0], na.rm = TRUE) }; d }
# (R's integer arithmetic would overflow in the split formula; the products stay below 2^53 as doubles, so they are exact.)

stays <- do.call(rbind, lapply(names(files), function(y) {
  f <- files[[y]]; year <- as.integer(y); yy <- year %% 100
  ip <- rd(f[1], c("DUID", "DUPERSID", "EVNTIDX", "IPBEGYR", "IPBEGMM", "NUMNIGHX", "EMERROOM", "SPECCOND", "RSNINHOS", "ANYOPER"))
  link <- rd(f[2], c("DUPERSID", "CONDIDX", "EVNTIDX")); cond <- rd(f[3])
  ccsr <- grep("^CCSR[0-9]X$", names(cond), value = TRUE)
  cl <- merge(link, cond[c("CONDIDX", ccsr)], by = "CONDIDX")
  long <- do.call(rbind, lapply(ccsr, function(v) data.frame(EVNTIDX = cl$EVNTIDX, ccsr = cl[[v]])))
  long <- long[grepl("^[A-Z]{3}[0-9]{3}$", long$ccsr), ]; long$body <- substr(long$ccsr, 1, 3)
  long <- unique(long[c("EVNTIDX", "body")])
  bs <- as.data.frame.matrix(table(factor(long$EVNTIDX, levels = unique(ip$EVNTIDX)), factor(long$body, levels = body)))
  bs[] <- lapply(bs, function(x) as.numeric(x > 0)); names(bs) <- paste0("dx_", body)
  ncond <- tapply(cl$CONDIDX, cl$EVNTIDX, function(x) length(unique(x)))
  bs$n_conditions <- as.numeric(ncond[rownames(bs)]); bs$n_conditions[is.na(bs$n_conditions)] <- 0
  bs$EVNTIDX <- rownames(bs)
  ip <- merge(ip, bs, by = "EVNTIDX", all.x = TRUE)
  fyc <- c("DUPERSID", "VARSTR", "VARPSU", sprintf("PERWT%dF", yy), sprintf("AGE%dX", yy), "SEX", "RACETHX", sprintf("REGION%d", yy),
           sprintf("POVCAT%d", yy), sprintf("INSCOV%d", yy), sprintf("MARRY%dX", yy), "HIDEG", sprintf("MCREV%d", yy), sprintf("MCDEV%d", yy),
           "HAVEUS42", "RTHLTH31", "MNHLTH31", "HIBPDX", "CHDDX", "ANGIDX", "MIDX", "OHRTDX", "STRKDX", "EMPHDX", "CHOLDX", "CANCERDX",
           "DIABDX_M18", "ARTHDX", "ASTHDX", "ADLHLP31", "IADLHP31", "WLKLIM31", "VPCS42", "VMCS42", "K6SUM42")
  p <- person_vars(rd(f[4], fyc), yy)
  s <- merge(ip, p, by.x = "DUPERSID", by.y = "person")
  dx <- grep("^dx_|^n_conditions$", names(s), value = TRUE); s[dx][is.na(s[dx])] <- 0
  data.frame(stay = as.character(s$EVNTIDX), household = s$DUID, year = neg_na(s$IPBEGYR), file_year = year, person = s$DUPERSID,
             s[setdiff(names(p), "person")], nights = neg_na(s$NUMNIGHX), admit_month = neg_na(s$IPBEGMM), via_er = yn(s$EMERROOM), specific_condition = yn(s$SPECCOND),
             any_operation = yn(s$ANYOPER),
             reason = lev(s$RSNINHOS, c(`1` = "Operation", `2` = "Treatment", `3` = "Tests only", `4` = "Birth (mother)",
                                        `5` = "Born (baby)", `6` = "Pregnancy complication", `91` = "Other")),
             s[paste0("dx_", body)], n_conditions = s$n_conditions, stringsAsFactors = FALSE)
}))
# Files hold the stays that ended in their year; count stays by the year they began and keep 2021-2023 admissions
stays <- stays[which(stays$age >= 18 & stays$nights >= 1 & stays$weight > 0 & stays$reason != "Born (baby)" & stays$year >= 2021), ]
stays$log_nights <- log(stays$nights); stays$long_stay <- as.numeric(stays$nights >= 7)
stays <- split_folds(stays)
stays <- impute(stays, c("age", "medicare", "medicaid", "usual_source", "health", "mental_health", "high_bp", "coronary", "angina",
                         "heart_attack", "other_heart", "stroke", "emphysema", "high_chol", "cancer", "diabetes", "arthritis", "asthma",
                         "adl_help", "iadl_help", "walk_limit", "pcs", "mcs", "k6", "via_er", "specific_condition", "any_operation", "admit_month"))
write.csv(stays, "data/meps_stays.csv", row.names = FALSE)
cat(sprintf("data/meps_stays.csv: %d stays of %d adults; %d in the test set; median nights %g; a week or more %.1f%%\n",
            nrow(stays), length(unique(stays$person)), sum(stays$test), median(stays$nights), 100 * mean(stays$long_stay)))

# ---- high use of care in 2023 (AI Fairness 360's MEPS definition) ----------------------------------------
p <- rd("h251")
u <- person_vars(p, 23)
u <- data.frame(u[1], household = p$DUID, u[-1], employed = as.numeric(neg_na(p$EMPST31) %in% 1:3),
                act_limit = yn(p$ACTLIM31), cog_limit = yn(p$COGLIM31), phq2 = neg_na(p$PHQ242))
use <- rowSums(sapply(c("OBTOTV23", "OPTOTV23", "ERTOT23", "IPNGTD23", "HHTOTD23"), function(v) { x <- neg_na(p[[v]]); x[is.na(x)] <- 0; x }))
u$utilization <- use; u$high_use <- as.numeric(use >= 10); u$white_nh <- as.numeric(u$race_eth == "White")
u <- u[which(u$age >= 18 & u$weight > 0), ]
u <- split_folds(u)
u <- impute(u, c("usual_source", "health", "mental_health", "high_bp", "coronary", "angina", "heart_attack", "other_heart", "stroke",
                 "emphysema", "high_chol", "cancer", "diabetes", "arthritis", "asthma", "adl_help", "iadl_help", "walk_limit",
                 "act_limit", "cog_limit", "pcs", "mcs", "k6", "phq2"))
u <- u[c("person", "household", "stratum", "psu", "weight", "age", "female", "race_eth", "region", "marital", "education", "poverty",
         "insurance", "employed", "usual_source", "health", "mental_health", "high_bp", "coronary", "angina", "heart_attack", "other_heart",
         "stroke", "emphysema", "high_chol", "cancer", "diabetes", "arthritis", "asthma", "adl_help", "iadl_help", "walk_limit",
         "act_limit", "cog_limit", "pcs", "mcs", "k6", "phq2", "utilization", "high_use", "white_nh", "test", "fold",
         grep("_miss$", names(u), value = TRUE))]           # the Python script's column order (no Medicare/Medicaid here)
write.csv(u, "data/meps_util_2023.csv", row.names = FALSE)
cat(sprintf("data/meps_util_2023.csv: %d adults; high use (weighted) %.1f%%\n", nrow(u), 100 * weighted.mean(u$high_use, u$weight)))
