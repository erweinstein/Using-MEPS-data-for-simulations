# 18_cms_ma_crosswalk.R -- A better bridge for Medicare Advantage: CMS's public county files.
#
# The Compendium lists the Medicare Advantage (MA) contracts each health system offers
# (sys_ma_plan_contracts), but its MA enrollment is a national total per system. CMS publishes,
# every month, MA enrollment by contract and county ("Monthly MA Enrollment by State/County/
# Contract") and the share of Medicare beneficiaries in MA by county ("MA State/County
# Penetration"). Joining the two by contract number places system-plan enrollees where they
# *live*, so the regional measure for MEPS no longer depends on where a system's hospitals are.
#
# This script, for July of 2016, 2018 and 2020-2023:
#   1. computes MA penetration by Census region from CMS (an administrative benchmark for the MEPS
#      household reports of MA, which R/16 tabulates);
#   2. computes the share of MA enrollees, and of all Medicare beneficiaries, in plans offered by
#      Compendium health systems, by region (and checks the national total against the
#      Compendium's own sys_ma_plan_enroll);
#   3. refits R/16's two-level MA model with the new regional measure.
#
# Downloads (public, cms.gov > Medicare Advantage/Part D Contract and Enrollment Data):
#   "Monthly MA Enrollment by State/County/Contract", July of each year (full version where there
#   is one; for 2016 only the abridged "alt" file was found, which omits small cells), and
#   "MA State/County Penetration", July of each year. Unzip them into `cms_dir` (or CMS_MA_DIR).
# Needs data/meps_fyc_2016_2023.rds (written by R/16) and data/compendium/systems.csv (R/14).
# Output: output/compendium/cms_ma_region_year.csv, ma_benchmark.csv, ma_contextual_model.csv.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

cms_dir <- Sys.getenv("CMS_MA_DIR", "C:/Users/YOU/folder/CMS MA")   # <-- change
out_dir <- file.path("output", "compendium")
suppressMessages({library(dplyr)})
years <- c(2016, 2018, 2020:2023)
regions <- list(`1` = c("CT", "ME", "MA", "NH", "RI", "VT", "NJ", "NY", "PA"),
                `2` = c("IL", "IN", "MI", "OH", "WI", "IA", "KS", "MN", "MO", "NE", "ND", "SD"),
                `3` = c("DE", "DC", "FL", "GA", "MD", "NC", "SC", "VA", "WV", "AL", "KY", "MS", "TN", "AR", "LA", "OK", "TX"),
                `4` = c("AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY", "AK", "CA", "HI", "OR", "WA"))
state_region <- setNames(rep(as.integer(names(regions)), lengths(regions)), unlist(regions))
name_abb <- setNames(c(state.abb, "DC"), toupper(c(state.name, "District of Columbia")))   # some years are in capitals
region_name <- c(`0` = "US", `1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West")
num <- function(x) suppressWarnings(as.numeric(gsub("[,%]", "", x)))
find1 <- function(pattern) { f <- list.files(cms_dir, pattern, recursive = TRUE, full.names = TRUE, ignore.case = TRUE); if (length(f)) f[1] else NA }

# ---- 1. Penetration by region (CMS) -------------------------------------------------------------------
pen <- bind_rows(lapply(years, function(y) {
  f <- find1(sprintf("State_County_Penetration_MA_%d_07\\.csv$", y)); if (is.na(f)) return(NULL)
  d <- read.csv(f, colClasses = "character", check.names = FALSE)
  data.frame(year = y, state_name = d[["State Name"]], fipsst = d$FIPSST, eligibles = num(d$Eligibles), enrolled = num(d$Enrolled))
}))
pen$region <- unname(state_region[name_abb[toupper(trimws(pen$state_name))]])   # NA: territories, "Pending"
pen_r <- pen |> filter(!is.na(region)) |> group_by(year, region) |>
  summarise(eligibles = sum(eligibles, na.rm = TRUE), ma_enrolled = sum(enrolled, na.rm = TRUE), .groups = "drop")
pen_r <- bind_rows(pen_r, pen_r |> group_by(year) |> summarise(region = 0L, eligibles = sum(eligibles), ma_enrolled = sum(ma_enrolled))) |>
  mutate(pct_ma_cms = 100 * ma_enrolled / eligibles)

# ---- 2. Enrollment in system-offered contracts, by where enrollees live --------------------------------
systems <- read.csv(file.path("data", "compendium", "systems.csv"), colClasses = c(health_sys_id = "character"))
contracts <- systems |> filter(!is.na(sys_ma_plan_contracts), sys_ma_plan_contracts != "") |>
  select(year, health_sys_id, sys_ma_plan_contracts, sys_ma_plan_enroll) |>
  mutate(contract = strsplit(sys_ma_plan_contracts, "[;, ]+")) |> tidyr::unnest(contract) |> filter(contract != "")
scc <- bind_rows(lapply(years, function(y) {
  f <- find1(sprintf("SCC_Enrollment_MA(_Alt)?_%d_07\\.csv$", y)); if (is.na(f)) return(NULL)
  d <- read.csv(f, colClasses = "character", check.names = FALSE)
  data.frame(year = y, state = d$State, contract = d[["Contract ID"]], enrolled = num(d$Enrolled), abridged = grepl("Alt", f))
}))
scc$region <- unname(state_region[scc$state])
in_sys <- scc |> semi_join(contracts |> distinct(year, contract), by = c("year", "contract"))   # each contract once
sys_r <- in_sys |> filter(!is.na(region)) |> group_by(year, region) |> summarise(system_plan_enrolled = sum(enrolled, na.rm = TRUE), .groups = "drop")
sys_r <- bind_rows(sys_r, sys_r |> group_by(year) |> summarise(region = 0L, system_plan_enrolled = sum(system_plan_enrolled)))
ma <- pen_r |> left_join(sys_r, by = c("year", "region")) |>
  mutate(pct_ma_in_system_plans = 100 * system_plan_enrolled / ma_enrolled,
         pct_medicare_in_system_plans = 100 * system_plan_enrolled / eligibles,
         region_name = region_name[as.character(region)]) |> arrange(year, region)
ma$abridged_scc_file <- ma$year %in% unique(scc$year[scc$abridged])
write.csv(ma, file.path(out_dir, "cms_ma_region_year.csv"), row.names = FALSE)
check <- contracts |> distinct(year, health_sys_id, sys_ma_plan_enroll) |> group_by(year) |>
  summarise(compendium_total = if (all(is.na(sys_ma_plan_enroll))) NA else sum(sys_ma_plan_enroll, na.rm = TRUE)) |>
  left_join(sys_r |> filter(region == 0) |> select(year, cms_county_total = system_plan_enrolled), by = "year")
cat("Enrollment in system-offered MA contracts, national: Compendium's total vs CMS county files (July):\n"); print(as.data.frame(check))
cat("\nMA by Census region (CMS, July):\n")
print(ma |> select(year, region_name, pct_ma_cms, pct_ma_in_system_plans, pct_medicare_in_system_plans) |>
        mutate(across(where(is.double), ~ round(.x, 1))), row.names = FALSE)

# ---- 3. Benchmark: MEPS household reports against CMS ---------------------------------------------------
ry <- read.csv(file.path(out_dir, "meps_region_year.csv"))
bench <- ry |> select(year, region, pct_ma_meps = pct_ma_of_medicare, pct_ma_meps_se = pct_ma_se) |>
  inner_join(ma |> filter(region > 0) |> select(year, region, region_name, pct_ma_cms), by = c("year", "region")) |>
  mutate(ratio = pct_ma_meps / pct_ma_cms, lo = (pct_ma_meps - 1.96 * pct_ma_meps_se) / pct_ma_cms,
         hi = (pct_ma_meps + 1.96 * pct_ma_meps_se) / pct_ma_cms)
write.csv(bench, file.path(out_dir, "ma_benchmark.csv"), row.names = FALSE)
cat("\nMA share of Medicare: MEPS household reports vs CMS administrative counts:\n")
print(bench |> mutate(across(c(pct_ma_meps, pct_ma_cms, ratio, lo, hi), ~ round(.x, 2))) |>
        select(year, region_name, pct_ma_meps, pct_ma_cms, ratio, lo, hi), row.names = FALSE)

# ---- 4. The two-level MA model with the enrollee-based measure ------------------------------------------
meps <- readRDS(file.path("data", "meps_fyc_2016_2023.rds"))
W <- ma |> filter(region > 0) |> select(year, region, pct_ma_in_system_plans, pct_ma_cms)
d <- meps |> filter(medicare == 1, !is.na(ma)) |> inner_join(W, by = c("year", "region")) |>
  mutate(cell = paste(year, region), region_f = factor(region), year_f = factor(year), W10 = pct_ma_in_system_plans / 10)
fits <- list(between = ma ~ W10 + age_group + SEX + insurance + year_f + (1 | cell),
             within = ma ~ W10 + age_group + SEX + insurance + year_f + region_f + (1 | cell))
mods <- bind_rows(lapply(names(fits), function(k) {
  m <- lme4::glmer(fits[[k]], data = d, family = binomial, nAGQ = 0)
  cf <- summary(m)$coefficients["W10", ]
  data.frame(version = k, cells = length(unique(d$cell)), people = nrow(d), log_or_per_10_points = cf[1], se = cf[2],
             lo = cf[1] - 1.96 * cf[2], hi = cf[1] + 1.96 * cf[2], context_range = paste(round(range(d$pct_ma_in_system_plans), 1), collapse = " to "))
}))
rownames(mods) <- NULL
write.csv(mods, file.path(out_dir, "ma_contextual_model.csv"), row.names = FALSE)
cat("\nMedicare Advantage (MEPS) on the % of MA enrollees in health-system plans (CMS + Compendium), per 10 points:\n")
print(mods |> mutate(across(c(log_or_per_10_points, se, lo, hi), ~ round(.x, 3))), row.names = FALSE)
