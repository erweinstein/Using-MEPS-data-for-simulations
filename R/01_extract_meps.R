# 01_extract_meps.R -- Make small, analysis-ready CSVs from four MEPS public use files.
#
# The example uses 2023, but only the settings at the top need to change for
# another year (WALKTHROUGH.md, section 4.2, shows how to find the file numbers).
# Put the unzipped Stata (.dta) files in one folder and set `meps_dir` below.
# For 2023 the files are:
#   h251.dta   Full Year Consolidated (HC-251): one row per person
#   h249.dta   Medical Conditions (HC-249): one row per person-condition
#   h248d.dta  Hospital Inpatient Stays (HC-248D): one row per stay
#   h252.dta   Panel 27 Longitudinal, 2022-2023 (HC-252): one row per person, two years
# Any file that is missing is skipped. Columns are chosen by name pattern, and
# year-suffixed names are given generic names in the output (TOTEXP23 -> TOTEXP,
# PERWT23F -> PERWT, AGE23X -> AGE, ...), so the example scripts work for any year.
#
# Output (in `out_dir`): meps_fyc.csv, meps_stays.csv, meps_panel.csv and
# meps_variables.csv (every variable's name and label, in every file read).
# Negative values are MEPS missing-data codes and are kept.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

meps_dir <- "C:/Users/YOU/folder/MEPS 2023"   # <-- change to your folder
out_dir  <- "data"                             # CSVs go here (relative to the project folder)
# Use forward slashes in Windows paths ("C:/Users/..."), or double backslashes
# ("C:\\Users\\..."). A single backslash is an escape character in R strings.

# ---- settings for the data year ------------------------------------------------------------------
year  <- 2023
files <- c(fyc = "h251", cond = "h249", stays = "h248d", panel = "h252")   # file names for that year
yy    <- sprintf("%02d", year %% 100)                                      # "23"
# Optional: longitudinal files covering more than two years (Panels 23 and 24
# were followed for four years: HC-236, 2018-2021, and HC-245, 2019-2022). Each
# is written to meps_panel4_<name>.csv; set to character(0) to skip.
multi_year_panels <- c("h245", "h236")

for (p in c("haven", "dplyr")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(haven); library(dplyr)

# Optional: let R download the files instead of using the website. The MEPS
# package (written at AHRQ; https://github.com/e-mitchell/meps_r_pkg) has
# get_puf_names(year) to look up the file names and dl_meps() to download them.
# install.packages("devtools"); devtools::install_github("e-mitchell/meps_r_pkg/MEPS")
# MEPS::get_puf_names(year = year)
# for (fn in files) {
#   z <- MEPS::dl_meps(fn, ext = "dta", dir = meps_dir)
#   unzip(z, exdir = meps_dir)
# }

dir.create(out_dir, showWarnings = FALSE)
f  <- function(x) file.path(meps_dir, paste0(x, ".dta"))
fo <- function(x) file.path(out_dir, x)
rd <- function(x) {
  if (!file.exists(f(x))) { message("Not found, skipped: ", f(x)); return(NULL) }
  message("Reading ", f(x)); read_dta(f(x))
}
keep <- function(d, pat) {                     # columns whose names match any pattern
  nm <- names(d)[Reduce(`|`, lapply(pat, grepl, x = names(d)))]
  zap_labels(d[, nm])
}
generic <- function(d) {                       # drop the year from year-suffixed names
  nm <- names(d)
  nm <- sub(paste0("^AGE", yy, "X$"), "AGE", nm)
  nm <- sub(paste0("^PERWT", yy, "F$"), "PERWT", nm)
  nm <- sub(paste0("^([A-Z]+)", yy, "$"), "\\1", nm)          # e.g. TOTEXP23 -> TOTEXP
  nm <- sub(paste0("^(IP|IPF|IPD)XP", yy, "X$"), "\\1XP", nm)
  names(d) <- nm; d
}

fyc   <- rd(files[["fyc"]])
cond  <- rd(files[["cond"]])
stays <- rd(files[["stays"]])
panel <- rd(files[["panel"]])

# 0. Variable list for every file read (names and labels only, no data)
vars <- bind_rows(lapply(list(fyc = fyc, conditions = cond, stays = stays, panel = panel), function(d) {
  if (is.null(d)) return(NULL)
  data.frame(variable = names(d),
             label = vapply(d, function(v) { l <- attr(v, "label"); if (is.null(l)) "" else l }, ""))
}), .id = "file")
write.csv(vars, fo("meps_variables.csv"), row.names = FALSE)

# 1. Depression flags from the conditions file. MEPS releases ICD-10 codes
#    collapsed to three characters, and some are collapsed further for
#    confidentiality, so check the codebook for the codes that appear.
dep <- NULL
if (!is.null(cond)) {
  icd <- grep("^ICD10", names(cond), value = TRUE)[1]
  message("ICD-10 variable used: ", icd)
  dep <- cond |> filter(.data[[icd]] %in% c("F32", "F33")) |> distinct(DUPERSID) |> mutate(depression = 1L)
  message("People with a depression condition (ICD-10 F32/F33): ", nrow(dep))
  # A second definition, from AHRQ's Clinical Classifications Software Refined
  # (CCSR) category MBD002, "Depressive disorders" (CCSR1X, CCSR2X, ... columns)
  ccsr <- grep("^CCSR[0-9]+X$", names(cond), value = TRUE)
  if (length(ccsr) > 0) {
    dc <- cond[apply(as.matrix(cond[, ccsr]) == "MBD002", 1, any, na.rm = TRUE), ] |>
      distinct(DUPERSID) |> mutate(depression_ccsr = 1L)
    dep <- full_join(dep, dc, by = "DUPERSID")
    message("People with a depression condition (CCSR MBD002): ", nrow(dc))
  }
}
add_dep <- function(d) {
  if (is.null(dep)) return(d)
  d |> left_join(dep, by = "DUPERSID") |>
    mutate(across(any_of(c("depression", "depression_ccsr")), ~ coalesce(.x, 0L)))
}

# 2. Person-level file, everyone (ages kept so the adult cut can be made later)
if (!is.null(fyc)) {
  out <- keep(fyc, c("^DUPERSID$", "^PANEL$", paste0("^AGE", yy, "X$"), "^SEX$",
                     paste0("^(TOTEXP|IPDIS|IPNGTD|OBTOTV|ERTOT|RXTOT)", yy, "$"),
                     "^K6SUM", "^PHQ2", "MCS", paste0("^PERWT", yy, "F$"), "^VARSTR$", "^VARPSU$"))
  out <- add_dep(generic(out))
  write.csv(out, fo("meps_fyc.csv"), row.names = FALSE)
  message("meps_fyc.csv: ", nrow(out), " people, ", ncol(out), " columns")
}

# 3. One row per hospital stay
if (!is.null(stays)) {
  out <- keep(stays, c("^DUPERSID$", "^EVNTIDX$", "^NUMNIGH", "^ZERONITE", "^IPBEG", "^IPEND",
                       "^EMERROOM", "^RSNINHOS", "^SPECCOND", paste0("XP", yy, "X$"),
                       paste0("^PERWT", yy, "F$"), "^VARSTR$", "^VARPSU$"))
  out <- generic(out)
  if (!is.null(fyc)) out <- out |> left_join(generic(zap_labels(fyc[, c("DUPERSID", paste0("AGE", yy, "X"))])), by = "DUPERSID")
  out <- add_dep(out)
  write.csv(out, fo("meps_stays.csv"), row.names = FALSE)
  message("meps_stays.csv: ", nrow(out), " stays, ", ncol(out), " columns")
}

# 4. Two-year panel (baseline and follow-up; names already say Y1/Y2 or the round)
if (!is.null(panel)) {
  out <- keep(panel, c("^DUPERSID$", "^AGE", "^SEX$", "^TOTEXPY", "^IPDISY", "^IPNGTDY", "^OBTOTVY",
                       "^ERTOTY", "^RXTOTY", "^K6SUM", "^PHQ2", "MCS", "^LONGWT", "^ALL5RDS",
                       "^VARSTR$", "^VARPSU$"))
  write.csv(out, fo("meps_panel.csv"), row.names = FALSE)
  message("meps_panel.csv: ", nrow(out), " people, ", ncol(out), " columns")
}
# 5. Longitudinal files covering more than two years
for (fn in multi_year_panels) {
  d <- rd(fn); if (is.null(d)) next
  out <- keep(d, c("^DUPERSID$", "^PANEL$", "^YEARIND$", "^ALL[0-9]RDS$", "^AGEY", "^SEX$", "^TOTEXPY",
                   "^TOTSLFY", "^OBTOTVY", "^ERTOTY", "^IPDISY", "^IPNGTDY", "^K6SUM", "^PHQ2", "^VMCS",
                   "^VPCS", "^LONGWT$", "^LSAQWT$", "^VARSTR$", "^VARPSU$"))
  write.csv(out, fo(paste0("meps_panel4_", fn, ".csv")), row.names = FALSE)
  message("meps_panel4_", fn, ".csv: ", nrow(out), " people, ", ncol(out), " columns")
}
writeLines(c(paste("MEPS data year:", year), paste("Files:", paste(c(files, multi_year_panels), collapse = ", ")),
             paste("Made:", Sys.time())), fo("meps_info.txt"))
message("Done. The CSVs are in ", normalizePath(out_dir))
