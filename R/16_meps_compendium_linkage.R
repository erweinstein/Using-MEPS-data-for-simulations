# 16_meps_compendium_linkage.R -- Cross-referencing MEPS with AHRQ's Compendium of U.S. Health Systems.
#
# Public MEPS files have no provider identifiers and no geography finer than the Census region, so
# no MEPS person, visit or stay can be linked to a hospital or health system. What *can* be linked is
# the region and the year: each MEPS person gets the characteristics of the health care system in
# their region that year (a "contextual" or ecological linkage). This script:
#
#   1. tabulates, from the MEPS full-year files for 2016 and 2018-2023, survey-weighted region x year
#      measures of hospital use and spending, where physician visits happen (office vs hospital
#      outpatient department), Medicare Advantage and Medicaid managed care (with design-based SEs);
#   2. benchmarks MEPS against the Compendium's hospital data: MEPS-estimated hospital discharges
#      against the discharges hospitals report to CMS (HCRIS), by region and year;
#   3. merges the Compendium's region x year profile (R/15) onto MEPS people, and fits two-level
#      models (people within region-years) relating each outcome to a regional system measure:
#        - share of physician visits in hospital outpatient departments  vs  % of physicians in
#          system-affiliated practices (vertical integration);
#        - Medicare Advantage enrollment among people with Medicare  vs  % of acute hospitals whose
#          system offers an MA plan;
#        - hospital spending per person  vs  % of acute hospitals in systems;
#   4. writes the MEPS-only figures for docs/MEPS_and_institutions.md (2023, national), so that the
#      note's numbers are reproducible.
#
# With 4 regions and 4-6 years there are only 16-24 region-years: the models show how the linkage
# works and what it can and cannot say; they are not evidence about effects of health systems.
#
# Needs: the MEPS full-year files h192 (2016, SAS transport .ssp), h209 (2018), h216 (2019),
# h224 (2020), h233 (2021), h243 (2022), h251 (2023) in `meps_dir` (or MEPS_DIR), and the
# Compendium tables from R/14 and R/15.
# Output: output/compendium/meps_region_year.csv, benchmark_discharges.csv, contextual_models.csv,
# meps_institutions_2023.csv; docs/fig_meps_compendium.png.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

meps_dir <- Sys.getenv("MEPS_DIR", "C:/Users/YOU/folder/MEPS")   # <-- change
out_dir <- file.path("output", "compendium")
for (p in c("haven", "survey", "lme4", "dplyr", "ggplot2", "patchwork")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
suppressMessages({library(dplyr); library(survey); library(ggplot2)})
options(survey.lonely.psu = "adjust")
fyc_files <- c(`2016` = "h192", `2018` = "h209", `2019` = "h216", `2020` = "h224", `2021` = "h233", `2022` = "h243", `2023` = "h251")
region_name <- c(`1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West")

# ---- 1. Read each year's full-year file (only the columns needed) ------------------------------------
read_fyc <- function(year) {
  yy <- sprintf("%02d", year %% 100); f <- fyc_files[[as.character(year)]]
  want <- c("DUPERSID", "VARSTR", "VARPSU", "SEX", paste0(c("PERWT", "REGION", "AGE", "INSCOV", "MCREV", "MCRPHO", "MCDEV", "MCDHMO",
            "TOTEXP", "IPTEXP", "IPFEXP", "OPTEXP", "OPFEXP", "ERTEXP", "ERFEXP", "OBVEXP", "HHAEXP", "HHNEXP",
            "IPDIS", "OBDRV", "OPDRV", "HHAGD"), yy), paste0("AGE", yy, "X"), paste0("PERWT", yy, "F"),
            "REGION53", "REGION42", "REGION31")
  dta <- file.path(meps_dir, paste0(f, ".dta")); ssp <- file.path(meps_dir, paste0(f, ".ssp"))
  d <- if (file.exists(dta)) haven::read_dta(dta, col_select = any_of(want)) else haven::read_xpt(ssp, col_select = any_of(want))
  d <- haven::zap_labels(d); names(d) <- sub(paste0(yy, "(X|F)?$"), "", names(d))
  d$year <- year; as.data.frame(d)
}
meps <- bind_rows(lapply(as.integer(names(fyc_files)), read_fyc)) |>
  filter(PERWT > 0) |>
  # Region at the end of the year; for people out of scope by then (deaths, entering an
  # institution), the region in their last round in scope
  mutate(region = case_when(REGION %in% 1:4 ~ REGION, REGION53 %in% 1:4 ~ REGION53,
                            REGION42 %in% 1:4 ~ REGION42, REGION31 %in% 1:4 ~ REGION31),
         across(c(TOTEXP, IPTEXP, IPFEXP, OPTEXP, OPFEXP, ERTEXP, ERFEXP, OBVEXP, HHAEXP, HHNEXP, IPDIS, OBDRV, OPDRV, HHAGD), ~ pmax(.x, 0)),
         hosp_exp = IPTEXP + OPTEXP + ERTEXP, hosp_fac_exp = IPFEXP + OPFEXP + ERFEXP,
         md_visits = OBDRV + OPDRV, any_stay = as.integer(IPDIS > 0),
         medicare = as.integer(MCREV == 1), ma = ifelse(MCREV == 1, as.integer(MCRPHO == 1), NA),
         medicaid = as.integer(MCDEV == 1), mcd_hmo = ifelse(MCDEV == 1, as.integer(MCDHMO == 1), NA),
         adult = as.integer(AGE >= 18), age_group = cut(AGE, c(-Inf, 17, 44, 64, Inf), c("0-17", "18-44", "45-64", "65+")),
         insurance = factor(INSCOV, 1:3, c("Any private", "Public only", "Uninsured")),
         stratum = paste(year, VARSTR), psu = paste(year, VARSTR, VARPSU))
cat("MEPS people with a positive weight, by year:\n"); print(table(meps$year))
cat("Region missing:", sum(is.na(meps$region)), "\n")
saveRDS(meps, file.path("data", "meps_fyc_2016_2023.rds"))   # for R/18 (MEPS data: stays in data/, not committed)

# ---- 2. Region x year estimates, with design-based SEs -------------------------------------------------
# One design per year (each year's strata and PSUs); estimates by region as domains.
se_of <- function(x, v) { s <- SE(x); if (is.null(dim(s))) as.numeric(s) else as.numeric(s[, grep(paste0("(^|\\.)", v, "$"), colnames(s))[1]]) }
est_year <- function(d) {
  des <- svydesign(ids = ~ VARPSU, strata = ~ VARSTR, weights = ~ PERWT, data = d, nest = TRUE)
  des <- subset(des, !is.na(region))
  tot <- svyby(~ TOTEXP + hosp_exp + hosp_fac_exp + IPDIS + OBDRV + OPDRV + HHAEXP, ~ region, des, svytotal, na.rm = TRUE)
  mn <- svyby(~ any_stay + TOTEXP + hosp_exp, ~ region, des, svymean, na.rm = TRUE)
  opd <- svyby(~ OPDRV, ~ region, des, svyratio, denominator = ~ md_visits, na.rm = TRUE)
  hshare <- svyby(~ hosp_exp, ~ region, des, svyratio, denominator = ~ TOTEXP, na.rm = TRUE)
  ma <- svyby(~ ma, ~ region, subset(des, medicare == 1), svymean, na.rm = TRUE)
  mh <- svyby(~ mcd_hmo, ~ region, subset(des, medicaid == 1), svymean, na.rm = TRUE)
  pop <- svyby(~ I(PERWT > 0), ~ region, des, svytotal)
  data.frame(year = d$year[1], region = tot$region, population = coef(pop)[grepl("TRUE", names(coef(pop)))],
             discharges = tot$IPDIS, discharges_se = se_of(tot, "IPDIS"),
             pct_any_stay = 100 * mn$any_stay, mean_exp = mn$TOTEXP, mean_hosp_exp = mn$hosp_exp, mean_hosp_exp_se = se_of(mn, "hosp_exp"),
             pct_hosp_of_exp = 100 * coef(hshare), pct_opd_of_md_visits = 100 * coef(opd), pct_opd_se = 100 * se_of(opd, "OPDRV"),
             pct_ma_of_medicare = 100 * ma$ma, pct_ma_se = 100 * se_of(ma, "ma"), pct_hmo_of_medicaid = 100 * mh$mcd_hmo,
             total_exp_bn = tot$TOTEXP / 1e9, hosp_exp_bn = tot$hosp_exp / 1e9, home_health_agency_exp_bn = tot$HHAEXP / 1e9)
}
ry <- bind_rows(lapply(split(meps, meps$year), est_year)) |>
  mutate(region_name = region_name[as.character(region)])
write.csv(ry, file.path(out_dir, "meps_region_year.csv"), row.names = FALSE)
cat("\nMEPS, region x year (survey-weighted):\n")
print(ry |> select(year, region_name, pct_any_stay, mean_hosp_exp, pct_opd_of_md_visits, pct_ma_of_medicare, pct_hmo_of_medicaid) |>
        mutate(across(where(is.double), ~ round(.x, 1))), row.names = FALSE)

# ---- 3. Benchmark: MEPS discharges against hospital-reported (HCRIS) discharges -----------------------
prof <- read.csv(file.path(out_dir, "region_profiles.csv"))
bench <- ry |> select(year, region, region_name, discharges, discharges_se) |>
  inner_join(prof |> filter(region > 0, !is.na(all_discharges_hcris)) |>
               select(year, region, acute_discharges_hcris, all_discharges_hcris), by = c("year", "region")) |>
  mutate(ratio_to_acute = discharges / acute_discharges_hcris, ratio_lo = (discharges - 1.96 * discharges_se) / acute_discharges_hcris,
         ratio_hi = (discharges + 1.96 * discharges_se) / acute_discharges_hcris, ratio_to_all = discharges / all_discharges_hcris)
nat <- bench |> group_by(year) |> summarise(region_name = "US", discharges = sum(discharges), discharges_se = sqrt(sum(discharges_se^2)),
                                            acute_discharges_hcris = sum(acute_discharges_hcris), all_discharges_hcris = sum(all_discharges_hcris), .groups = "drop") |>
  mutate(ratio_to_acute = discharges / acute_discharges_hcris, ratio_lo = (discharges - 1.96 * discharges_se) / acute_discharges_hcris,
         ratio_hi = (discharges + 1.96 * discharges_se) / acute_discharges_hcris, ratio_to_all = discharges / all_discharges_hcris, region = 0L)
bench <- bind_rows(bench, nat) |> arrange(year, region)
write.csv(bench, file.path(out_dir, "benchmark_discharges.csv"), row.names = FALSE)
cat("\nMEPS-estimated discharges / discharges reported by non-federal general acute hospitals (HCRIS):\n")
print(bench |> transmute(year, region_name, meps_millions = round(discharges / 1e6, 2), hcris_acute_millions = round(acute_discharges_hcris / 1e6, 2),
                         ratio = round(ratio_to_acute, 2), lo = round(ratio_lo, 2), hi = round(ratio_hi, 2)), row.names = FALSE)

# ---- 4. Contextual two-level models ---------------------------------------------------------------------
# Level 1 (person i in region-year j):  y_ij = b0j + b1 x_ij + e_ij
# Level 2 (region-year j):              b0j = g00 + g01 W_j + (region and year effects) + u0j
# Combined:                             y_ij = g00 + g01 W_j + b1 x_ij + region + year + u0j + e_ij
# x_ij: age group, sex and insurance (to compare like with like across regions and years).
# Two versions: "between" (no region effects: compares regions with each other as well as over
# time) and "within" (region and year effects: uses only how regions changed relative to each
# other, the more defensible comparison, and with these few cells a very imprecise one).
# MEPS weights are not used in the multilevel fits (person-level weights in multilevel models need
# rescaling at each level; Rabe-Hesketh and Skrondal 2006); the composition variables stand in.
ctx <- prof |> filter(region > 0) |> select(year, region, pct_physicians_in_system, pct_acute_hosp_system_offers_ma, pct_acute_hosp_in_system)
dat <- meps |> filter(!is.na(region)) |> inner_join(ctx, by = c("year", "region")) |>
  mutate(cell = paste(year, region), region_f = factor(region), year_f = factor(year))
fit_ctx <- function(outcome, W, d, label, family = NULL) {
  d <- d[!is.na(d[[outcome]]) & !is.na(d[[W]]), ]
  d$W10 <- d[[W]] / 10                                  # per 10 percentage points
  base <- paste(outcome, "~ W10 + age_group + SEX + insurance + year_f")
  forms <- c(between = paste(base, "+ (1 | cell)"), within = paste(base, "+ region_f + (1 | cell)"))
  bind_rows(lapply(names(forms), function(k) {
    m <- if (is.null(family)) lme4::lmer(as.formula(forms[[k]]), data = d) else lme4::glmer(as.formula(forms[[k]]), data = d, family = family, nAGQ = 0)
    cf <- summary(m)$coefficients["W10", ]
    data.frame(outcome = label, context = W, version = k, cells = length(unique(d$cell)), people = nrow(d),
               estimate = cf[1], se = cf[2], lo = cf[1] - 1.96 * cf[2], hi = cf[1] + 1.96 * cf[2],
               scale = if (is.null(family)) "difference in outcome per 10 points" else "log odds ratio per 10 points",
               context_range = paste(round(range(d[[W]]), 1), collapse = " to "))
  }))
}
visits <- dat |> filter(md_visits > 0, !is.na(pct_physicians_in_system)) |> mutate(opd_share = 100 * OPDRV / md_visits)
mods <- bind_rows(
  fit_ctx("opd_share", "pct_physicians_in_system", visits, "% of a person's physician visits in a hospital outpatient department"),
  fit_ctx("ma", "pct_acute_hosp_system_offers_ma", dat |> filter(medicare == 1), "Medicare Advantage (people with Medicare)", family = binomial),
  fit_ctx("hosp_exp", "pct_acute_hosp_in_system", dat, "hospital spending per person ($; inpatient + outpatient + ER)"))
rownames(mods) <- NULL
write.csv(mods, file.path(out_dir, "contextual_models.csv"), row.names = FALSE)
cat("\nContextual two-level models (coefficient of the regional system measure, per 10 percentage points):\n")
print(mods |> mutate(across(c(estimate, se, lo, hi), ~ signif(.x, 3))) |> select(outcome, version, cells, people, estimate, lo, hi, context_range), row.names = FALSE)

# ---- 5. MEPS-only national figures for 2023 (docs/MEPS_and_institutions.md) ----------------------------
d23 <- meps |> filter(year == 2023)
des23 <- svydesign(ids = ~ VARPSU, strata = ~ VARSTR, weights = ~ PERWT, data = d23, nest = TRUE)
tt <- svytotal(~ TOTEXP + hosp_exp + hosp_fac_exp + HHAEXP + HHNEXP, des23)
m23 <- svymean(~ any_stay + I(ERTEXP > 0 | FALSE), des23)
inst <- data.frame(measure = c("Total spending ($bn)", "Inpatient + outpatient + ER spending ($bn)", "Share of spending in hospital settings (%)",
                               "Facility part of hospital-setting spending, share of all spending (%)", "Home health spending, share (%)",
                               "People with a hospital stay (%)", "People with Medicare in Medicare Advantage (%)",
                               "People with Medicaid in a Medicaid HMO (%)", "Physician visits in hospital outpatient departments (%)"),
                   value = c(coef(tt)["TOTEXP"] / 1e9, coef(tt)["hosp_exp"] / 1e9, 100 * coef(tt)["hosp_exp"] / coef(tt)["TOTEXP"],
                             100 * coef(tt)["hosp_fac_exp"] / coef(tt)["TOTEXP"], 100 * (coef(tt)["HHAEXP"] + coef(tt)["HHNEXP"]) / coef(tt)["TOTEXP"],
                             100 * coef(svymean(~ any_stay, des23)), 100 * coef(svymean(~ ma, subset(des23, medicare == 1), na.rm = TRUE)),
                             100 * coef(svymean(~ mcd_hmo, subset(des23, medicaid == 1), na.rm = TRUE)),
                             100 * coef(svyratio(~ OPDRV, ~ md_visits, des23))))
inst$value <- round(inst$value, 1)
write.csv(inst, file.path(out_dir, "meps_institutions_2023.csv"), row.names = FALSE)
cat("\nMEPS-only figures, 2023 (national):\n"); print(inst, row.names = FALSE)

# ---- 6. Figure: the region-year cells behind the models ------------------------------------------------
cells <- ry |> inner_join(ctx, by = c("year", "region"))
th <- theme_minimal(base_size = 10) + theme(legend.position = "bottom")
cols <- c(Northeast = "#1b9e77", Midwest = "#d95f02", South = "#7570b3", West = "#e7298a")
g1 <- ggplot(cells |> filter(!is.na(pct_physicians_in_system)), aes(pct_physicians_in_system, pct_opd_of_md_visits, colour = region_name)) +
  geom_path(aes(group = region_name), alpha = 0.5) + geom_point() + geom_text(aes(label = year %% 100), size = 2.5, vjust = -0.8, show.legend = FALSE) +
  scale_colour_manual(values = cols) + labs(x = "% of physicians in system-affiliated\npractices (Compendium)",
                                            y = "% of physician visits in hospital\noutpatient departments (MEPS)", colour = NULL) + th
g2 <- ggplot(cells |> filter(!is.na(pct_acute_hosp_system_offers_ma)), aes(pct_acute_hosp_system_offers_ma, pct_ma_of_medicare, colour = region_name)) +
  geom_path(aes(group = region_name), alpha = 0.5) + geom_point() + geom_text(aes(label = year %% 100), size = 2.5, vjust = -0.8, show.legend = FALSE) +
  scale_colour_manual(values = cols) + labs(x = "% of acute hospitals whose system\noffers an MA plan (Compendium)",
                                            y = "% of people with Medicare\nin Medicare Advantage (MEPS)", colour = NULL) + th
g3 <- ggplot(bench |> filter(region > 0), aes(factor(year), ratio_to_acute, colour = region_name)) +
  geom_pointrange(aes(ymin = ratio_lo, ymax = ratio_hi), position = position_dodge(0.5), show.legend = FALSE) + geom_hline(yintercept = 1, linetype = 2) +
  scale_colour_manual(values = cols) + labs(x = NULL, y = "MEPS discharges / discharges reported\nby acute hospitals (HCRIS)", colour = NULL) + th
g <- patchwork::wrap_plots(g1, g2, g3, nrow = 1, guides = "collect") & theme(legend.position = "bottom", plot.margin = margin(8, 8, 4, 8))
ggsave("docs/fig_meps_compendium.png", g + patchwork::plot_annotation(
  title = "MEPS and the Compendium of U.S. Health Systems, linked by Census region and year",
  subtitle = "Each point is a region-year (labels: year). Right: 95% intervals from MEPS's design-based SEs."), width = 13, height = 4.6, dpi = 150)
cat("\nWrote", out_dir, "and docs/fig_meps_compendium.png\n")
