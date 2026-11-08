# 14_compendium_extract.R -- Read AHRQ's Compendium of U.S. Health Systems (2016-2023) and write
# tidy, stacked CSVs, one row per institution per year, each with its Census region (the only
# geography in the public MEPS files) so that the Compendium can be cross-referenced with MEPS.
#
# The Compendium (ahrq.gov/chsp) is public. Download the files from AHRQ's site into one folder
# and set `compendium_dir` (or the environment variable COMPENDIUM_DIR). The files used:
#   systems lists        chsp-compendium-2019update.xlsx (this is the 2016 Compendium, updated
#                        in 2019), chsp-compendium-2018-updated-2021, -2020-rev, -2021-rev,
#                        -2022-rev, -2023-rev
#   hospital linkage     compendium_system_hospital_linkage_file.xls (2016),
#                        chsp-hospital-linkage-2018, -2020-rev, -2021-rev, -2022-rev, -2023
#   nursing homes        chsp-nh-linkage-2020 to -2023
#   home health          chsp-hhco-linkage-2020 to -2023
#   group practices      20xx-group-practice-linkage-public-file (2016, 2018, 2020, 2021, 2022)
#   outpatient sites     chsp-os-linkage-2022
# (Browsers add "(1)" to repeated downloads; the script matches the files by pattern.)
#
# Output in data/compendium/: systems.csv, hospitals.csv, nursing_homes.csv, home_health.csv,
# practices.csv, outpatient_sites.csv. All are public AHRQ data, but they are large, so data/
# stays out of the repository like the MEPS extracts.
#
# Hospital type comes from the Medicare CMS Certification Number (CCN): its last four digits
# give the provider type (0001-0879 short-term acute, 1300-1399 critical access, 2000-2299
# long-term acute care, 3025-3099 inpatient rehabilitation, 3300-3399 children's, 4000-4499
# psychiatric). Hospitals without a CCN are mostly federal (VA, IHS, military).
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

compendium_dir <- Sys.getenv("COMPENDIUM_DIR", "C:/Users/YOU/folder/AHRQ Compendium")   # <-- change
out_dir <- file.path("data", "compendium")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
for (p in c("readxl", "dplyr")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
suppressMessages(library(dplyr))

find_file <- function(pattern) {
  f <- list.files(compendium_dir, pattern = pattern, full.names = TRUE, ignore.case = TRUE)
  f <- f[grepl("\\.xlsx?$", f, ignore.case = TRUE)]                  # not the PDF documentation
  if (length(f) == 0) { message("  (not found: ", pattern, ")"); return(NULL) }
  f[1]
}
rd <- function(pattern) { f <- find_file(pattern); if (is.null(f)) NULL else as.data.frame(readxl::read_excel(f, guess_max = 1e5)) }

# ---- Census regions, coded as in MEPS (REGION: 1 Northeast, 2 Midwest, 3 South, 4 West) ----------
regions <- list(
  `1` = c("CT", "ME", "MA", "NH", "RI", "VT", "NJ", "NY", "PA"),
  `2` = c("IL", "IN", "MI", "OH", "WI", "IA", "KS", "MN", "MO", "NE", "ND", "SD"),
  `3` = c("DE", "DC", "FL", "GA", "MD", "NC", "SC", "VA", "WV", "AL", "KY", "MS", "TN", "AR", "LA", "OK", "TX"),
  `4` = c("AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY", "AK", "CA", "HI", "OR", "WA"))
state_region <- setNames(rep(as.integer(names(regions)), lengths(regions)), unlist(regions))
region_name <- c(`1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West")
add_region <- function(state) unname(state_region[toupper(trimws(state))])   # NA for territories

ccn_type <- function(ccn) {
  ccn <- toupper(trimws(as.character(ccn)))
  ccn <- ifelse(!is.na(ccn) & grepl("^[0-9]{5}$", ccn), paste0("0", ccn), ccn)   # Excel drops a leading zero
  ok <- !is.na(ccn) & grepl("^[0-9A-Z]{2}[0-9]{4}$", ccn)
  k <- suppressWarnings(as.integer(substr(ccn, 3, 6)))
  out <- rep("Other", length(ccn))
  out[!ok] <- "No CCN or non-standard"
  out[ok & k >= 1 & k <= 879] <- "Short-term acute"
  out[ok & k >= 1300 & k <= 1399] <- "Critical access"
  out[ok & k >= 2000 & k <= 2299] <- "Long-term acute care (LTACH)"
  out[ok & k >= 3025 & k <= 3099] <- "Inpatient rehabilitation"
  out[ok & k >= 3300 & k <= 3399] <- "Children's"
  out[ok & k >= 4000 & k <= 4499] <- "Psychiatric"
  out
}
fix_ccn <- function(ccn) { ccn <- toupper(trimws(as.character(ccn))); ifelse(!is.na(ccn) & grepl("^[0-9]{5}$", ccn), paste0("0", ccn), ccn) }
num <- function(x) suppressWarnings(as.numeric(x))
col_or_na <- function(d, v) if (v %in% names(d)) d[[v]] else rep(NA, nrow(d))

# ---- 1. Systems lists ---------------------------------------------------------------------------------
sys_files <- c(`2016` = "compendium-2019", `2018` = "compendium-2018", `2020` = "compendium-2020",
               `2021` = "compendium-2021", `2022` = "compendium-2022", `2023` = "compendium-2023")
sys_vars <- c("health_sys_id", "health_sys_name", "health_sys_city", "health_sys_state", "total_mds", "prim_care_mds",
              "total_nps", "total_pas", "grp_cnt", "hosp_cnt", "acutehosp_cnt", "nh_cnt", "hhco_cnt", "sys_multistate",
              "sys_beds", "sys_dsch", "sys_res", "deg_children", "sys_incl_majteachhosp", "sys_teachint",
              "sys_incl_highdpphosp", "sys_highucburden", "sys_anyins_product", "sys_mcare_adv", "sys_ma_plan",
              "sys_mcaid_mngcare", "sys_healthins_mktplc", "sys_ma_plan_enroll", "sys_ownership", "maj_inv_owned",
              "sys_aco", "sys_acoany", "sys_apm", "sys_ebpm", "sys_pctm", "sys_bundledpayment", "hos_net_revenue", "hos_total_revenue")
# Definitions change between years (see each year's technical documentation):
#   sys_ma_plan        2016 only: system offers an MA plan, from matches to CMS's MA contract data
#   sys_mcare_adv      2018-2023: a system hospital told the AHA survey the system offers an MA plan
#   sys_acoany         2016 only: system participates in at least one ACO contract (1/0)
#   sys_aco            2018 only: NUMBER of system physicians in a Medicare ACO (not a flag)
#   sys_apm            2018 only: system physicians in any Medicare alternative payment model (1/0)
systems <- bind_rows(lapply(names(sys_files), function(y) {
  d <- rd(sys_files[[y]]); if (is.null(d)) return(NULL)
  o <- as.data.frame(setNames(lapply(sys_vars, function(v) col_or_na(d, v)), sys_vars))
  for (v in setdiff(sys_vars, c("health_sys_id", "health_sys_name", "health_sys_city", "health_sys_state"))) o[[v]] <- num(o[[v]])
  o$year <- as.integer(y); o
}))
systems$hq_region <- add_region(systems$health_sys_state)
systems <- systems |> select(year, everything())
write.csv(systems, file.path(out_dir, "systems.csv"), row.names = FALSE)
cat("systems:", nrow(systems), "rows;", paste(table(systems$year), collapse = ", "), "by year\n")

# ---- 2. Hospital linkage files ------------------------------------------------------------------------
hosp_files <- c(`2016` = "system_hospital_linkage_file\\.xls$", `2018` = "hospital-linkage-2018",
                `2020` = "hospital-linkage-2020", `2021` = "hospital-linkage-2021",
                `2022` = "hospital-linkage-2022", `2023` = "hospital-linkage-2023")
hospitals <- bind_rows(lapply(names(hosp_files), function(y) {
  d <- rd(hosp_files[[y]]); if (is.null(d)) return(NULL)
  data.frame(year = as.integer(y), hospital_id = as.character(d$compendium_hospital_id), ccn = fix_ccn(d$ccn),
             hospital_name = d$hospital_name, state = toupper(d$hospital_state),
             acute = num(d$acutehosp_flag), health_sys_id = as.character(d$health_sys_id),
             health_sys_name = d$health_sys_name, beds = num(col_or_na(d, "hos_beds")),
             discharges = num(col_or_na(d, "hos_dsch")), residents = num(col_or_na(d, "hos_res")),
             ownership = num(col_or_na(d, "hos_ownership")), corp_parent_type = col_or_na(d, "corp_parent_type"),
             net_revenue = num(col_or_na(d, "hos_net_revenue")))
}))
hospitals$in_system <- as.integer(!is.na(hospitals$health_sys_id) & hospitals$health_sys_id != "")
hospitals$type <- ccn_type(hospitals$ccn)
hospitals$region <- add_region(hospitals$state)
write.csv(hospitals, file.path(out_dir, "hospitals.csv"), row.names = FALSE)
cat("hospitals:", nrow(hospitals), "rows;", paste(table(hospitals$year), collapse = ", "), "by year\n")

# ---- 3. Nursing homes and home health care organizations ---------------------------------------------
facility <- function(kind, years, prefix, extra = NULL) bind_rows(lapply(years, function(y) {
  d <- rd(paste0(kind, "-linkage-", y)); if (is.null(d)) return(NULL)
  o <- data.frame(year = y, ccn = fix_ccn(d$ccn), name = d[[paste0(prefix, "_name")]], state = toupper(d[[paste0(prefix, "_state")]]),
                  health_sys_id = as.character(d$health_sys_id), corp_parent_type = col_or_na(d, "corp_parent_type"))
  if (!is.null(extra)) o[[extra]] <- d[[extra]]
  o
}))
nh <-facility("nh", 2020:2023, "nursing_home")
hh <- facility("hhco", 2020:2023, "home_health_care_org", extra = "home_health_care_org_type")
for (nm in c("nh", "hh")) {
  d <- get(nm); d$in_system <- as.integer(!is.na(d$health_sys_id) & d$health_sys_id != ""); d$region <- add_region(d$state); assign(nm, d)
}
write.csv(nh, file.path(out_dir, "nursing_homes.csv"), row.names = FALSE)
write.csv(hh, file.path(out_dir, "home_health.csv"), row.names = FALSE)
cat("nursing homes:", nrow(nh), "rows; home health:", nrow(hh), "rows\n")

# ---- 4. Group practices (one row per tax ID; physician counts from Medicare's MD-PPAS) ---------------
gp_files <- c(`2016` = "2016-group-practice", `2018` = "2018-group-practice", `2020` = "2020-group-practice",
              `2021` = "2021-group-practice", `2022` = "2022-group-practice")
practices <- bind_rows(lapply(names(gp_files), function(y) {
  d <- rd(gp_files[[y]]); if (is.null(d)) return(NULL)
  data.frame(year = as.integer(y), tin_name = d$tin_name, state = toupper(d$state_md_ppas),
             health_sys_id = as.character(d$health_sys_id), physicians = num(d$md_do_md_ppas),
             np_pa = num(d$np_pa_md_ppas), service_lines = d$service_lines_md_ppas, ma_only_tin = num(d$ma_only_tin))
}))
practices$in_system <- as.integer(!is.na(practices$health_sys_id) & practices$health_sys_id != "")
practices$region <- add_region(practices$state)
write.csv(practices, file.path(out_dir, "practices.csv"), row.names = FALSE)
cat("group practices:", nrow(practices), "rows;", paste(table(practices$year), collapse = ", "), "by year\n")

# ---- 5. Outpatient sites (2022 only) ---------------------------------------------------------------------
os <- rd("os-linkage-2022")
if (!is.null(os)) {
  os <- data.frame(year = 2022L, state = toupper(os$os_state), type = os$os_type, specialty = os$os_specialty,
                   physicians = num(os$os_mds), health_sys_id = as.character(os$health_sys_id),
                   corp_parent_type = os$corp_parent_type, rural_nonmsa = num(os$rural_nonmsa))
  os$in_system <- as.integer(!is.na(os$health_sys_id) & os$health_sys_id != "")
  os$region <- add_region(os$state)
  write.csv(os, file.path(out_dir, "outpatient_sites.csv"), row.names = FALSE)
  cat("outpatient sites:", nrow(os), "rows\n")
}
writeLines(c(paste("Compendium extract made", format(Sys.Date())), paste("from", normalizePath(compendium_dir))),
           file.path(out_dir, "compendium_info.txt"))
