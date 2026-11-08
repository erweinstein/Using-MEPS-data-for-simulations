# 15_compendium_profiles.R -- How much of U.S. health care delivery is in health systems, by Census
# region and year, from AHRQ's Compendium of U.S. Health Systems (the files made by R/14).
#
# Everything here is about institutions, and none of it is in MEPS. The region-by-year tables are
# the bridge to MEPS (R/16), whose public files identify only the Census region.
#
# Output (output/compendium/):
#   region_profiles.csv       region x year: share of hospitals, beds, discharges, physicians,
#                             nursing homes, home health organizations and outpatient sites in systems
#   hospital_types.csv        region x year x hospital type (CCN): number and share in systems
#   insurance_products.csv    year: systems with insurance products, MA, Medicaid managed care,
#                             marketplace plans; MA enrollment in system-offered contracts; ACOs
#   named_systems.csv         Banner Health and Intermountain Health, every year
#   system_sizes.csv          the distribution of system sizes in 2023 (for R/17)
# and docs/fig_compendium_regions.png.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

in_dir <- file.path("data", "compendium")
out_dir <- file.path("output", "compendium")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
suppressMessages({library(dplyr); library(ggplot2)})
rd <- function(f) read.csv(file.path(in_dir, f), colClasses = c(health_sys_id = "character"), check.names = FALSE)
systems <- rd("systems.csv"); hospitals <- rd("hospitals.csv"); nh <- rd("nursing_homes.csv")
hh <- rd("home_health.csv"); practices <- rd("practices.csv")
os <- if (file.exists(file.path(in_dir, "outpatient_sites.csv"))) rd("outpatient_sites.csv") else NULL
region_name <- c(`1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West")
share <- function(x, w = rep(1, length(x))) { ok <- !is.na(x) & !is.na(w); sum(x[ok] * w[ok]) / sum(w[ok]) }

# Region rows plus a national row ("US", region 0)
by_region <- function(d, f) {
  r <- d |> filter(!is.na(region)) |> group_by(year, region) |> group_modify(~ f(.x)) |> ungroup()
  n <- d |> filter(!is.na(region)) |> group_by(year) |> group_modify(~ f(.x)) |> ungroup() |> mutate(region = 0L)
  bind_rows(r, n) |> mutate(region_name = ifelse(region == 0, "US", region_name[as.character(region)])) |> arrange(year, region)
}

# ---- 1. Region x year profile ------------------------------------------------------------------------
acute <- hospitals |> filter(acute == 1)
p_hosp <- by_region(acute, function(d) data.frame(
  acute_hospitals = nrow(d), pct_acute_hosp_in_system = 100 * share(d$in_system),
  pct_acute_beds_in_system = if (all(is.na(d$beds))) NA else 100 * share(d$in_system, d$beds),
  pct_acute_dsch_in_system = if (all(is.na(d$discharges))) NA else 100 * share(d$in_system, d$discharges),
  acute_discharges_hcris = if (all(is.na(d$discharges))) NA else sum(d$discharges, na.rm = TRUE),
  systems_with_hospital_here = n_distinct(d$health_sys_id[d$in_system == 1])))
p_all_dsch <- by_region(hospitals, function(d) data.frame(
  all_discharges_hcris = if (all(is.na(d$discharges))) NA else sum(d$discharges, na.rm = TRUE)))
p_md <- by_region(practices, function(d) data.frame(
  physicians_mdppas = sum(d$physicians, na.rm = TRUE), pct_physicians_in_system = 100 * share(d$in_system, d$physicians),
  pct_np_pa_in_system = 100 * share(d$in_system, d$np_pa)))
p_nh <- by_region(nh, function(d) data.frame(nursing_homes = nrow(d), pct_nh_in_system = 100 * share(d$in_system),
  pct_nh_corporate_owner = 100 * mean(d$corp_parent_type %in% "CORPORATE OWNER")))
p_hh <- by_region(hh, function(d) data.frame(home_health_orgs = nrow(d), pct_hh_in_system = 100 * share(d$in_system)))
prof <- Reduce(function(a, b) full_join(a, b, by = c("year", "region", "region_name")),
               list(p_hosp, p_all_dsch, p_md, p_nh, p_hh))
if (!is.null(os)) prof <- full_join(prof, by_region(os, function(d) data.frame(
  outpatient_sites = nrow(d), pct_os_in_system = 100 * share(d$in_system),
  pct_os_physicians_in_system = 100 * share(d$in_system, d$physicians))), by = c("year", "region", "region_name"))
# MA offered by the system of the hospital (by hospital location), for the years with an AHA-based flag
ma_flag <- systems |> filter(!is.na(sys_mcare_adv)) |> select(year, health_sys_id, sys_mcare_adv, sys_anyins_product)
p_ma <- by_region(acute |> inner_join(ma_flag, by = c("year", "health_sys_id")) |> bind_rows(acute |> filter(in_system == 0, year %in% ma_flag$year) |>
                    mutate(sys_mcare_adv = 0, sys_anyins_product = 0)),
                  function(d) data.frame(pct_acute_hosp_system_offers_ma = 100 * mean(d$sys_mcare_adv == 1),
                                         pct_acute_hosp_system_any_insurance = 100 * mean(d$sys_anyins_product == 1)))
prof <- left_join(prof, p_ma, by = c("year", "region", "region_name")) |> arrange(year, region)
write.csv(prof, file.path(out_dir, "region_profiles.csv"), row.names = FALSE)
show <- prof |> filter(year == 2023 | (year == 2022 & !is.na(pct_physicians_in_system)))
cat("Share of each kind of institution in Compendium health systems (%), by Census region:\n")
print(prof |> filter(year %in% c(2016, 2023)) |>
        select(year, region_name, pct_acute_hosp_in_system, pct_acute_dsch_in_system, pct_nh_in_system, pct_hh_in_system,
               pct_acute_hosp_system_offers_ma) |> mutate(across(where(is.double), ~ round(.x, 1))), row.names = FALSE)
cat("\nPhysicians (Medicare MD-PPAS) in system-affiliated practices (%):\n")
print(prof |> filter(!is.na(pct_physicians_in_system)) |> select(year, region_name, pct_physicians_in_system) |>
        tidyr::pivot_wider(names_from = region_name, values_from = pct_physicians_in_system) |>
        mutate(across(-year, ~ round(.x, 1))), row.names = FALSE)

# ---- 2. Hospital types (CCN), in systems or not ----------------------------------------------------
types <- hospitals |> filter(!is.na(region)) |> group_by(year, type) |>
  summarise(hospitals = n(), pct_in_system = round(100 * mean(in_system), 1), in_system = sum(in_system),
            beds = sum(beds, na.rm = TRUE), discharges = sum(discharges, na.rm = TRUE), .groups = "drop")
write.csv(types, file.path(out_dir, "hospital_types.csv"), row.names = FALSE)
cat("\nHospitals by type (CCN), 2023:\n"); print(types |> filter(year == 2023) |> select(-year), row.names = FALSE)

# ---- 3. Insurance products, MA enrollment and ACOs (systems lists) ----------------------------------
ins <- systems |> group_by(year) |> summarise(
  systems = n(),
  pct_any_insurance_product = round(100 * mean(sys_anyins_product == 1, na.rm = TRUE), 1),
  pct_offers_ma_aha = round(100 * mean(sys_mcare_adv == 1, na.rm = TRUE), 1),
  pct_offers_ma_cms_2016 = round(100 * mean(sys_ma_plan == 1, na.rm = TRUE), 1),
  pct_medicaid_managed_care = round(100 * mean(sys_mcaid_mngcare == 1, na.rm = TRUE), 1),
  pct_marketplace_plan = round(100 * mean(sys_healthins_mktplc == 1, na.rm = TRUE), 1),
  systems_with_ma_enrollment = if (all(is.na(sys_ma_plan_enroll))) NA else sum(sys_ma_plan_enroll > 0, na.rm = TRUE),
  ma_enrollment_in_system_contracts = if (all(is.na(sys_ma_plan_enroll))) NA else sum(sys_ma_plan_enroll, na.rm = TRUE),
  pct_aco_any_2016 = round(100 * mean(sys_acoany == 1, na.rm = TRUE), 1),
  pct_with_aco_physicians_2018 = round(100 * mean(sys_aco > 0, na.rm = TRUE), 1),
  aco_physicians_2018 = if (all(is.na(sys_aco))) NA else sum(sys_aco, na.rm = TRUE),
  pct_any_apm_2018 = round(100 * mean(sys_apm == 1, na.rm = TRUE), 1),
  pct_bundled_payment_2016 = round(100 * mean(sys_bundledpayment == 1, na.rm = TRUE), 1), .groups = "drop")
ins[ins == "NaN"] <- NA
write.csv(ins, file.path(out_dir, "insurance_products.csv"), row.names = FALSE)
cat("\nInsurance products, MA and ACOs (share of systems, %):\n"); print(as.data.frame(ins), row.names = FALSE)

# ---- 4. Named systems ---------------------------------------------------------------------------------
named <- systems |> filter(grepl("^Banner Health|^Intermountain", health_sys_name)) |>
  select(year, health_sys_name, health_sys_state, sys_multistate, hosp_cnt, acutehosp_cnt, sys_beds, sys_dsch, total_mds,
         prim_care_mds, total_nps, total_pas, grp_cnt, nh_cnt, hhco_cnt, sys_anyins_product, sys_mcare_adv, sys_ma_plan,
         sys_ma_plan_enroll, sys_mcaid_mngcare, sys_healthins_mktplc, sys_acoany, sys_aco, sys_ownership) |>
  arrange(health_sys_name, year)
named_states <- hospitals |> filter(grepl("^Banner Health|^Intermountain", health_sys_name)) |>
  group_by(year, health_sys_name) |> summarise(hospital_states = paste(sort(unique(state)), collapse = " "), .groups = "drop")
named <- left_join(named, named_states, by = c("year", "health_sys_name"))
write.csv(named, file.path(out_dir, "named_systems.csv"), row.names = FALSE)
cat("\nBanner Health and Intermountain:\n"); print(named |> select(year, health_sys_name, hosp_cnt, sys_beds, sys_dsch, total_mds, nh_cnt,
                                                                 hhco_cnt, sys_mcare_adv, sys_ma_plan_enroll, hospital_states), row.names = FALSE)

# ---- 5. System sizes, 2023 (used by R/17) --------------------------------------------------------------
sizes <- systems |> filter(year == 2023) |>
  select(health_sys_id, health_sys_state, hq_region, acutehosp_cnt, sys_beds, sys_dsch, total_mds, prim_care_mds)
write.csv(sizes, file.path(out_dir, "system_sizes.csv"), row.names = FALSE)

# ---- 6. Figure ---------------------------------------------------------------------------------------------
long <- prof |> select(year, region_name, `Acute hospitals` = pct_acute_hosp_in_system,
                       `Acute discharges` = pct_acute_dsch_in_system, `Physicians (Medicare)` = pct_physicians_in_system,
                       `Nursing homes` = pct_nh_in_system, `Home health orgs` = pct_hh_in_system) |>
  tidyr::pivot_longer(-c(year, region_name), names_to = "what", values_to = "pct") |> filter(!is.na(pct)) |>
  mutate(region_name = factor(region_name, c("US", "Northeast", "Midwest", "South", "West")),
         what = factor(what, c("Acute hospitals", "Acute discharges", "Physicians (Medicare)", "Home health orgs", "Nursing homes")))
g <- ggplot(long, aes(year, pct, colour = region_name, linewidth = region_name == "US")) + geom_line() + geom_point(size = 1.2) +
  facet_wrap(~ what, nrow = 1) + scale_linewidth_manual(values = c(0.6, 1.4), guide = "none") +
  scale_colour_manual(values = c(US = "black", Northeast = "#1b9e77", Midwest = "#d95f02", South = "#7570b3", West = "#e7298a")) +
  scale_x_continuous(breaks = c(2016, 2018, 2020, 2022)) + ylim(0, 100) +
  labs(x = NULL, y = "% in a Compendium health system", colour = NULL,
       title = "How much of each kind of provider belongs to a health system, by Census region",
       subtitle = "AHRQ Compendium of U.S. Health Systems, 2016-2023 (years with data for each kind)") +
  theme_minimal(base_size = 10) + theme(legend.position = "bottom")
ggsave("docs/fig_compendium_regions.png", g, width = 11, height = 4, dpi = 150)
cat("\nWrote", out_dir, "and docs/fig_compendium_regions.png\n")
