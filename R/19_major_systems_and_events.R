# 19_major_systems_and_events.R -- The largest multistate health systems, and the mergers, spin-offs
# and other events that move many hospitals at once (and so can change how the Compendium's
# year-to-year numbers should be interpreted).
#
# 1. Major systems: Banner Health and Intermountain, plus the 13 largest systems by 2023 discharges
#    among those with hospitals in three or more states (the Compendium's sys_multistate = 3).
#    For each, every Compendium year: hospitals, acute hospitals, beds, discharges, physicians,
#    nursing homes, home health organizations, insurance products, MA enrollment, the states and
#    Census regions of its hospitals; and, from CMS's July 2023 county files (R/18), where its MA
#    enrollees live, by Census region.
# 2. Events: hospitals are followed across years by their Compendium hospital ID, and every move
#    of 8 or more hospitals from one system ID to another (or into or out of any system) between
#    consecutive Compendium years is listed; likewise for nursing homes and home health
#    organizations (followed by CCN). Name changes under the same system ID are listed separately.
#    How much the largest event of each kind moves the regional shares is computed.
#
# Needs data/compendium/*.csv (R/14) and, for the MA part, CMS's 2023 SCC file in CMS_MA_DIR.
# Output: output/compendium/major_systems.csv, major_systems_ma_region.csv, hospital_flows.csv,
# facility_flows.csv, system_renames.csv, event_effects.csv; docs/fig_major_systems.png.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

cms_dir <- Sys.getenv("CMS_MA_DIR", "C:/Users/YOU/folder/CMS MA")
in_dir <- file.path("data", "compendium"); out_dir <- file.path("output", "compendium")
suppressMessages({library(dplyr); library(ggplot2)})
rd <- function(f) read.csv(file.path(in_dir, f), colClasses = c(health_sys_id = "character"), check.names = FALSE)
systems <- rd("systems.csv"); hospitals <- rd("hospitals.csv"); nh <- rd("nursing_homes.csv"); hh <- rd("home_health.csv")
region_name <- c(`1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West")
yrs <- sort(unique(hospitals$year))

# ---- 1. Choose the major systems -------------------------------------------------------------------------
s23 <- systems |> filter(year == 2023)
named <- s23$health_sys_id[grepl("^Banner Health|^Intermountain", s23$health_sys_name)]
top <- s23 |> filter(sys_multistate == 3, !health_sys_id %in% named) |> arrange(desc(sys_dsch)) |> slice_head(n = 13)
major_ids <- c(named, top$health_sys_id)
cat("Major systems (Banner, Intermountain, and the 13 largest multistate systems by 2023 discharges):\n")
print(s23 |> filter(health_sys_id %in% major_ids) |> arrange(desc(sys_dsch)) |> select(health_sys_name, health_sys_state, hosp_cnt, sys_dsch), row.names = FALSE)

# A system's ID persists across years, but mergers create new IDs; carry each 2023 system back through
# its predecessors: in each earlier year, its own ID plus any system with 3 or more hospitals of which
# at least 40% are in the 2023 system (so a merger partner counts, even one that later shed some
# hospitals; a seller of a few hospitals does not).
lineage <- bind_rows(lapply(major_ids, function(id) {
  hid <- hospitals$hospital_id[hospitals$year == 2023 & hospitals$health_sys_id %in% id]
  bind_rows(lapply(yrs, function(y) {
    p <- hospitals |> filter(year == y, !is.na(health_sys_id), health_sys_id != "") |>
      group_by(health_sys_id, health_sys_name) |>
      summarise(n = n(), now_in_major = sum(hospital_id %in% hid), .groups = "drop") |>
      filter(health_sys_id == id | (now_in_major >= 3 & now_in_major / n >= 0.4))
    if (!nrow(p)) return(NULL)
    data.frame(major_id = id, year = y, pred_id = p$health_sys_id, pred_name = p$health_sys_name,
               hospitals = p$n, hospitals_now_in_major = p$now_in_major)
  }))
}))
write.csv(lineage, file.path(out_dir, "major_systems_lineage.csv"), row.names = FALSE)

prof <- bind_rows(lapply(major_ids, function(id) {
  nm23 <- s23$health_sys_name[s23$health_sys_id == id]
  bind_rows(lapply(yrs, function(y) {
    ids <- if (y == 2023) id else lineage$pred_id[lineage$major_id == id & lineage$year == y]
    if (!length(ids)) return(NULL)
    sy <- systems |> filter(year == y, health_sys_id %in% ids)
    hy <- hospitals |> filter(year == y, health_sys_id %in% ids)
    if (!nrow(sy)) return(NULL)
    data.frame(system_2023 = nm23, year = y, names_that_year = paste(unique(sy$health_sys_name), collapse = " + "),
               hq_state = paste(unique(sy$health_sys_state), collapse = "/"),
               hospitals = sum(sy$hosp_cnt, na.rm = TRUE), acute_hospitals = sum(sy$acutehosp_cnt, na.rm = TRUE),
               beds = sum(sy$sys_beds, na.rm = TRUE), discharges = sum(sy$sys_dsch, na.rm = TRUE),
               physicians = sum(sy$total_mds, na.rm = TRUE), primary_care_mds = sum(sy$prim_care_mds, na.rm = TRUE),
               nursing_homes = if (all(is.na(sy$nh_cnt))) NA else sum(sy$nh_cnt, na.rm = TRUE),
               home_health_orgs = if (all(is.na(sy$hhco_cnt))) NA else sum(sy$hhco_cnt, na.rm = TRUE),
               any_insurance = max(sy$sys_anyins_product, na.rm = TRUE), offers_ma = suppressWarnings(max(c(sy$sys_mcare_adv, sy$sys_ma_plan), na.rm = TRUE)),
               ma_enrollment = if (all(is.na(sy$sys_ma_plan_enroll))) NA else sum(sy$sys_ma_plan_enroll, na.rm = TRUE),
               medicaid_mc = suppressWarnings(max(sy$sys_mcaid_mngcare, na.rm = TRUE)),
               marketplace = suppressWarnings(max(sy$sys_healthins_mktplc, na.rm = TRUE)),
               ownership = paste(unique(na.omit(sy$sys_ownership)), collapse = "/"),
               states = length(unique(hy$state)), state_list = paste(sort(unique(hy$state)), collapse = " "),
               regions = paste(region_name[as.character(sort(unique(na.omit(hy$region))))], collapse = ", "),
               ltach = sum(hy$type == "Long-term acute care (LTACH)"), psychiatric = sum(hy$type == "Psychiatric"),
               rehab = sum(hy$type == "Inpatient rehabilitation"), critical_access = sum(hy$type == "Critical access"))
  }))
}))
prof[prof == -Inf] <- NA
prof$ownership <- c(`1` = "nonprofit", `2` = "church-operated", `3` = "public", `5` = "for-profit")[prof$ownership]
write.csv(prof, file.path(out_dir, "major_systems.csv"), row.names = FALSE)
cat("\n2023 profile of the 15 systems:\n")
print(prof |> filter(year == 2023) |> arrange(desc(discharges)) |>
        select(system_2023, hospitals, beds, discharges, physicians, nursing_homes, home_health_orgs, offers_ma, ma_enrollment, states, ownership),
      row.names = FALSE)

# ---- 2. Where each system's MA enrollees live (CMS July 2023 county files) -------------------------------
f_scc <- list.files(cms_dir, "SCC_Enrollment_MA_2023_07\\.csv$", recursive = TRUE, full.names = TRUE)
if (length(f_scc)) {
  regions <- list(`1` = c("CT", "ME", "MA", "NH", "RI", "VT", "NJ", "NY", "PA"),
                  `2` = c("IL", "IN", "MI", "OH", "WI", "IA", "KS", "MN", "MO", "NE", "ND", "SD"),
                  `3` = c("DE", "DC", "FL", "GA", "MD", "NC", "SC", "VA", "WV", "AL", "KY", "MS", "TN", "AR", "LA", "OK", "TX"),
                  `4` = c("AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY", "AK", "CA", "HI", "OR", "WA"))
  state_region <- setNames(rep(as.integer(names(regions)), lengths(regions)), unlist(regions))
  scc <- read.csv(f_scc[1], colClasses = "character", check.names = FALSE)
  scc <- data.frame(state = scc$State, contract = scc[["Contract ID"]], enrolled = suppressWarnings(as.numeric(gsub(",", "", scc$Enrolled))))
  ct <- s23 |> filter(health_sys_id %in% major_ids, !is.na(sys_ma_plan_contracts), sys_ma_plan_contracts != "") |>
    mutate(contract = strsplit(sys_ma_plan_contracts, "[;, ]+")) |> tidyr::unnest(contract) |> select(health_sys_name, contract)
  ma_reg <- scc |> inner_join(ct, by = "contract", relationship = "many-to-many") |>
    mutate(region = region_name[as.character(state_region[state])]) |>
    group_by(health_sys_name, region) |> summarise(enrolled = sum(enrolled, na.rm = TRUE), .groups = "drop") |>
    group_by(health_sys_name) |> mutate(share = round(100 * enrolled / sum(enrolled), 1)) |> ungroup()
  write.csv(ma_reg, file.path(out_dir, "major_systems_ma_region.csv"), row.names = FALSE)
  cat("\nWhere the major systems' MA enrollees lived, July 2023 (CMS county files):\n")
  print(ma_reg |> tidyr::pivot_wider(id_cols = health_sys_name, names_from = region, values_from = enrolled, values_fill = 0) |> as.data.frame())
}

# ---- 3. Events: large moves of hospitals between system IDs ------------------------------------------------
nm <- systems |> distinct(year, health_sys_id, health_sys_name)
sysname <- function(y, id) { x <- nm$health_sys_name[nm$year == y & nm$health_sys_id == id]; if (length(x)) x[1] else "(no system)" }
flows <- bind_rows(lapply(seq_along(yrs)[-1], function(i) {
  a <- yrs[i - 1]; b <- yrs[i]
  A <- hospitals |> filter(year == a) |> transmute(hospital_id, from = ifelse(in_system == 1, health_sys_id, "none"), acute, region)
  B <- hospitals |> filter(year == b) |> transmute(hospital_id, to = ifelse(in_system == 1, health_sys_id, "none"), discharges_after = discharges)
  A |> inner_join(B, by = "hospital_id") |> filter(from != to) |>
    group_by(from, to) |> summarise(hospitals = n(), acute = sum(acute), discharges_after = sum(discharges_after, na.rm = TRUE),
                                    regions = paste(sort(unique(region_name[as.character(region)])), collapse = ", "), .groups = "drop") |>
    filter(hospitals >= 8) |> mutate(period = paste(a, b, sep = "-"),
                                     from_name = vapply(from, function(x) if (x == "none") "(no system)" else sysname(a, x), ""),
                                     to_name = vapply(to, function(x) if (x == "none") "(no system)" else sysname(b, x), ""))
}))
flows <- flows |> arrange(period, desc(hospitals)) |> select(period, from_name, to_name, hospitals, acute, discharges_after, regions)
write.csv(flows, file.path(out_dir, "hospital_flows.csv"), row.names = FALSE)
cat("\nMoves of 8 or more hospitals between Compendium systems (followed by hospital ID):\n"); print(flows, row.names = FALSE)

renames <- systems |> group_by(health_sys_id) |> arrange(year) |>
  summarise(names = paste(unique(health_sys_name), collapse = " -> "), n_names = length(unique(health_sys_name)),
            max_hospitals = max(hosp_cnt, na.rm = TRUE), .groups = "drop") |> filter(n_names > 1) |> arrange(desc(max_hospitals))
write.csv(renames, file.path(out_dir, "system_renames.csv"), row.names = FALSE)
cat("\nSystems whose name changed under the same ID:", nrow(renames), "(largest 8):\n"); print(head(renames$names, 8))

fac_flows <- bind_rows(lapply(list(list(nh, "nursing homes"), list(hh, "home health organizations")), function(z) {
  d <- z[[1]] |> filter(!is.na(ccn)) |> distinct(year, ccn, .keep_all = TRUE) |> mutate(sid = ifelse(in_system == 1, health_sys_id, "none"))
  yy <- sort(unique(d$year))
  bind_rows(lapply(seq_along(yy)[-1], function(i) {
    a <- yy[i - 1]; b <- yy[i]
    d |> filter(year == a) |> select(ccn, from = sid) |> inner_join(d |> filter(year == b) |> select(ccn, to = sid), by = "ccn") |>
      filter(from != to) |> count(from, to, name = "facilities") |> filter(facilities >= 8) |>
      mutate(kind = z[[2]], period = paste(a, b, sep = "-"),
             from_name = vapply(from, function(x) if (x == "none") "(no system)" else sysname(a, x), ""),
             to_name = vapply(to, function(x) if (x == "none") "(no system)" else sysname(b, x), ""))
  }))
})) |> arrange(kind, period, desc(facilities)) |> select(kind, period, from_name, to_name, facilities)
write.csv(fac_flows, file.path(out_dir, "facility_flows.csv"), row.names = FALSE)
cat("\nMoves of 8 or more nursing homes or home health organizations:\n"); print(fac_flows, row.names = FALSE)

# ---- 4. How much do the biggest in-and-out events move the shares? -----------------------------------------
quorum <- hospitals |> filter(acute == 1) |> group_by(year) |>
  summarise(pct_in_system = 100 * mean(in_system),
            pct_if_quorum_not_a_system = 100 * mean(in_system == 1 & !grepl("Quorum", health_sys_name)),
            quorum_hospitals = sum(grepl("Quorum", health_sys_name)), .groups = "drop")
ltach <- hospitals |> filter(type == "Long-term acute care (LTACH)") |> group_by(year) |>
  summarise(pct_in_system = 100 * mean(in_system), pct_without_scionhealth = 100 * mean(in_system == 1 & !grepl("ScionHealth", health_sys_name)), .groups = "drop")
nh_eff <- nh |> distinct(year, ccn, .keep_all = TRUE) |> group_by(year) |>
  summarise(pct_in_system = 100 * mean(in_system), promedica = sum(grepl("ProMedica", vapply(seq_along(health_sys_id), function(i)
    if (is.na(health_sys_id[i])) "" else sysname(year[i], health_sys_id[i]), ""))), .groups = "drop")
hh_eff <- hh |> group_by(year) |>
  summarise(pct_in_system = 100 * mean(in_system), orgs = n(), hospices = sum(home_health_care_org_type == "Hospice"), .groups = "drop")
effects <- bind_rows(quorum |> mutate(what = "acute hospitals; Quorum Health"), ltach |> mutate(what = "LTACHs; ScionHealth"),
                     nh_eff |> mutate(what = "nursing homes; ProMedica"), hh_eff |> mutate(what = "home health organizations; coverage"))
write.csv(effects, file.path(out_dir, "event_effects.csv"), row.names = FALSE)
cat("\nEffects of the largest in-and-out events on the shares in systems:\n"); print(as.data.frame(effects |> mutate(across(where(is.double), ~ round(.x, 1)))))

# ---- 5. Figure: the 15 systems' hospitals and discharges over time ---------------------------------------
fig <- prof |> mutate(system_2023 = factor(system_2023, levels = prof |> filter(year == 2023) |> arrange(desc(discharges)) |> pull(system_2023)))
g <- ggplot(fig, aes(year, discharges / 1000)) + geom_line(colour = "#4C72B0") + geom_point(colour = "#4C72B0", size = 1) +
  facet_wrap(~ system_2023, scales = "free_y", ncol = 5) + scale_x_continuous(breaks = c(2016, 2020, 2023)) +
  expand_limits(y = 0) +
  labs(x = NULL, y = "Acute discharges (thousands)", title = "The 15 major systems, with their predecessors before mergers",
       subtitle = "AHRQ Compendium of U.S. Health Systems (2016, 2018, 2020-2023); discharges of non-federal general acute hospitals, from Medicare cost reports") +
  theme_minimal(base_size = 9)
ggsave("docs/fig_major_systems.png", g, width = 11, height = 6.5, dpi = 150)
cat("\nWrote", out_dir, "and docs/fig_major_systems.png\n")
