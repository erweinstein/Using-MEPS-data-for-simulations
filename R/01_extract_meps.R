# 01_extract_meps.R -- Make small, analysis-ready CSVs from four 2023 MEPS public use files.
#
# Put the unzipped Stata (.dta) files in one folder and set `meps_dir` below:
#   h251.dta   2023 Full Year Consolidated (HC-251): one row per person
#   h249.dta   2023 Medical Conditions (HC-249): one row per person-condition
#   h248d.dta  2023 Hospital Inpatient Stays (HC-248D): one row per stay
#   h252.dta   Panel 27 Longitudinal, 2022-2023 (HC-252): one row per person, two years
# Any file that is missing is skipped. Columns are chosen by name pattern, so the
# year suffixes do not need to be exact; meps_variables.csv lists every variable in
# every file (name and label) so names can be checked afterwards.
#
# Output (in `out_dir`): meps_fyc2023.csv, meps_stays2023.csv, meps_panel27.csv,
# meps_variables.csv. Negative values are MEPS missing-data codes and are kept.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

meps_dir <- "C:/Users/YOU/folder/MEPS 2023"   # <-- change to your folder
out_dir  <- "data"                             # CSVs go here (relative to the project folder)
# Use forward slashes in Windows paths ("C:/Users/..."), or double backslashes
# ("C:\\Users\\..."). A single backslash is an escape character in R strings.

for (p in c("haven", "dplyr")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(haven); library(dplyr)

# Optional: let R download the files instead of using the website. The MEPS
# package (written at AHRQ; https://github.com/e-mitchell/meps_r_pkg) has a
# dl_meps() function; uncomment to use it.
# install.packages("devtools"); devtools::install_github("e-mitchell/meps_r_pkg/MEPS")
# for (fn in c("h251", "h249", "h248d", "h252")) {
#   z <- MEPS::dl_meps(fn, ext = "dta", dir = meps_dir)
#   unzip(z, exdir = meps_dir)
# }

dir.create(out_dir, showWarnings = FALSE)
f  <- function(x) file.path(meps_dir, x)
fo <- function(x) file.path(out_dir, x)
rd <- function(x) {
  if (!file.exists(f(x))) { message("Not found, skipped: ", x); return(NULL) }
  message("Reading ", x); read_dta(f(x))
}
keep <- function(d, pat) {                     # columns whose names match any pattern
  nm <- names(d)[Reduce(`|`, lapply(pat, grepl, x = names(d)))]
  zap_labels(d[, nm])
}

fyc   <- rd("h251.dta")
cond  <- rd("h249.dta")
stays <- rd("h248d.dta")
panel <- rd("h252.dta")

# 0. Variable list for every file read (names and labels only, no data)
vars <- bind_rows(lapply(list(h251 = fyc, h249 = cond, h248d = stays, h252 = panel), function(d) {
  if (is.null(d)) return(NULL)
  data.frame(variable = names(d),
             label = vapply(d, function(v) { l <- attr(v, "label"); if (is.null(l)) "" else l }, ""))
}), .id = "file")
write.csv(vars, fo("meps_variables.csv"), row.names = FALSE)

# 1. Depression flag from the conditions file (ICD-10 F32 or F33). MEPS releases
#    ICD-10 codes collapsed to three characters, and some are collapsed further
#    for confidentiality, so check the codebook for the codes that appear.
dep <- NULL
if (!is.null(cond)) {
  icd <- grep("^ICD10", names(cond), value = TRUE)[1]
  message("ICD-10 variable used: ", icd)
  dep <- cond |> filter(.data[[icd]] %in% c("F32", "F33")) |> distinct(DUPERSID) |> mutate(depression = 1L)
  message("People with a depression condition (ICD-10): ", nrow(dep))
  # A second definition, from AHRQ's Clinical Classifications Software Refined
  # (CCSR) category MBD002, "Depressive disorders" (CCSR1X, CCSR2X, ... columns)
  ccsr <- grep("^CCSR[0-9]+X$", names(cond), value = TRUE)
  if (length(ccsr) > 0) {
    dc <- cond[apply(as.matrix(cond[, ccsr]) == "MBD002", 1, any, na.rm = TRUE), ] |>
      distinct(DUPERSID) |> mutate(depression_ccsr = 1L)
    dep <- full_join(dep, dc, by = "DUPERSID") |>
      mutate(depression = coalesce(depression, 0L), depression_ccsr = coalesce(depression_ccsr, 0L))
    message("People with a depression condition (CCSR MBD002): ", nrow(dc))
  }
}

# 2. Person-level file, everyone (ages kept so the adult cut can be made later)
if (!is.null(fyc)) {
  out <- keep(fyc, c("^DUPERSID$", "^PANEL$", "^AGE23X$", "^SEX$", "^TOTEXP23$", "^IPDIS23$",
                     "^IPNGTD23$", "^OBTOTV23$", "^ERTOT23$", "^RXTOT23$", "^K6SUM", "^PHQ2",
                     "MCS", "^PERWT23F$", "^VARSTR$", "^VARPSU$"))
  if (!is.null(dep)) out <- out |> left_join(dep, by = "DUPERSID") |>
    mutate(across(any_of(c("depression", "depression_ccsr")), ~ coalesce(.x, 0L)))
  write.csv(out, fo("meps_fyc2023.csv"), row.names = FALSE)
  message("meps_fyc2023.csv: ", nrow(out), " people, ", ncol(out), " columns")
}

# 3. One row per hospital stay
if (!is.null(stays)) {
  out <- keep(stays, c("^DUPERSID$", "^EVNTIDX$", "^NUMNIGH", "^ZERONITE", "^IPBEG", "^IPEND",
                       "^EMERROOM", "^RSNINHOS", "^SPECCOND", "XP23X$", "^PERWT23F$", "^VARSTR$", "^VARPSU$"))
  if (!is.null(fyc)) out <- out |> left_join(zap_labels(fyc[, c("DUPERSID", "AGE23X")]), by = "DUPERSID")
  if (!is.null(dep)) out <- out |> left_join(dep, by = "DUPERSID") |>
    mutate(across(any_of(c("depression", "depression_ccsr")), ~ coalesce(.x, 0L)))
  write.csv(out, fo("meps_stays2023.csv"), row.names = FALSE)
  message("meps_stays2023.csv: ", nrow(out), " stays, ", ncol(out), " columns")
}

# 4. Two-year panel (baseline and follow-up)
if (!is.null(panel)) {
  out <- keep(panel, c("^DUPERSID$", "^AGE", "^SEX$", "^TOTEXPY", "^IPDISY", "^IPNGTDY", "^OBTOTVY",
                       "^ERTOTY", "^RXTOTY", "^K6SUM", "^PHQ2", "MCS", "^LONGWT", "^ALL5RDS",
                       "^VARSTR$", "^VARPSU$"))
  write.csv(out, fo("meps_panel27.csv"), row.names = FALSE)
  message("meps_panel27.csv: ", nrow(out), " people, ", ncol(out), " columns")
}
message("Done. The CSVs are in ", normalizePath(out_dir))
