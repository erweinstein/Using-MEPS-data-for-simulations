# 13_review_workbook.R -- A human-readable Excel workbook of the extracted MEPS data, for
# showing someone (an adviser, a professor) what the CSVs contain.
#
# Reads the CSVs made by R/01_extract_meps.R (data/), and, if the original .dta files are
# in `meps_dir`, their value labels. Writes output/MEPS_extract_for_review.xlsx with:
#   README     what the workbook is, where the data come from, and how to read it
#   Summary    weighted national estimates and unweighted counts for each extract
#   Codebook   every column: source file, MEPS label, what it means here, its codes
#   Adults     the full-year file (one row per person), codes replaced by words
#   Stays      hospital stays (one row per stay)
#   Panel      the two-year panel (one row per person)
#   Panel4_*   the four-year panels, if extracted
# Missing-data codes (-1, -7, -8, -15) are shown as words, so they are not mistaken
# for values.
#
# The workbook is made from MEPS public use files. Like the CSVs, keep it for your
# own use and to show people directly; do not post it or put it in a repository
# (see "Using the MEPS data responsibly" in the README). output/ is not committed.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

meps_dir <- "C:/Users/YOU/folder/MEPS 2023"   # optional: for value labels (same as in R/01)
data_dir <- "data"
out_file <- "output/MEPS_extract_for_review.xlsx"

for (p in c("openxlsx", "haven")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
library(openxlsx)

rdcsv <- function(f) { p <- file.path(data_dir, f); if (file.exists(p)) read.csv(p, check.names = FALSE) else NULL }
fyc   <- rdcsv("meps_fyc.csv")
stays <- rdcsv("meps_stays.csv")
panel <- rdcsv("meps_panel.csv")
p4    <- setNames(lapply(list.files(data_dir, "^meps_panel4_.*\\.csv$"), rdcsv),
                  sub("^meps_panel4_(.*)\\.csv$", "\\1", list.files(data_dir, "^meps_panel4_.*\\.csv$")))
vars  <- rdcsv("meps_variables.csv")
info  <- if (file.exists(file.path(data_dir, "meps_info.txt"))) readLines(file.path(data_dir, "meps_info.txt")) else "MEPS"
if (is.null(fyc)) stop("No data/meps_fyc.csv: run R/01_extract_meps.R first.")
year <- suppressWarnings(as.integer(sub("\\D*(\\d{4}).*", "\\1", info[1])))
if (is.na(year)) year <- 2023
yy <- sprintf("%02d", year %% 100)

# ---- MEPS's missing-data codes, and value labels ---------------------------------------------------
miss <- c(`-2` = "Determined in previous round", `-1` = "Inapplicable", `-7` = "Refused", `-8` = "Don't know", `-15` = "Cannot be computed",
          `-10` = "Top-coded", `-9` = "Not ascertained")
known <- list(SEX = c(`1` = "Male", `2` = "Female"),
              EMERROOM = c(`1` = "Yes", `2` = "No"), SPECCOND = c(`1` = "Yes", `2` = "No"),
              RSNINHOS = c(`1` = "Operation or surgical procedure", `2` = "Treatment/therapy",
                           `3` = "Diagnostic tests only", `4` = "Give birth to a baby (mother)",
                           `5` = "To be born (baby)", `6` = "Pregnancy-related complications", `91` = "Other"),
              depression = c(`0` = "No", `1` = "Yes"), depression_ccsr = c(`0` = "No", `1` = "Yes"),
              ALL5RDS = c(`1` = "Yes", `2` = "No"), ALL9RDS = c(`1` = "Yes", `2` = "No"))
# Value labels straight from the .dta files, if they are there
src_files <- c(fyc = "h251", stays = "h248d", panel = "h252")
if (dir.exists(meps_dir)) {
  for (k in names(src_files)) {
    f <- file.path(meps_dir, paste0(src_files[k], ".dta"))
    if (!file.exists(f)) next
    d <- haven::read_dta(f, n_max = 1)
    for (v in names(d)) {
      l <- attr(d[[v]], "labels")
      if (is.null(l) || length(l) == 0) next
      g <- sub(paste0(yy, "X?$|", yy, "F$"), "", v)                    # TOTEXP23 -> TOTEXP, PERWT23F -> PERWT
      lab <- setNames(tools::toTitleCase(tolower(sub("^-?[0-9]+ ", "", names(l)))), as.character(unname(l)))
      lab <- lab[!names(lab) %in% c(names(miss), "-2")]
      lab <- lab[lab != names(lab)]                                     # MEPS labels some scores' 0 as "0": not a code
      if (length(lab) == 1 && names(lab) == "0") lab <- lab[0]           # a score's 0 labelled with the question
      if (length(lab) && is.null(known[[g]])) known[[g]] <- lab
    }
  }
}
decode <- function(x, v) {
  out <- as.character(x)
  m <- !is.na(x) & as.character(x) %in% names(miss)
  out[m] <- paste0("[", miss[as.character(x[m])], "]")
  lab <- known[[v]]
  if (!is.null(lab)) { h <- !m & as.character(x) %in% names(lab); out[h] <- lab[as.character(x[h])] }
  if (is.null(lab) && is.numeric(x)) { out <- x; out[m] <- NA }        # numbers stay numbers; codes become blank
  out
}
readable <- function(d) {
  if (is.null(d)) return(NULL)
  for (v in setdiff(names(d), c("DUPERSID", "EVNTIDX"))) d[[v]] <- decode(d[[v]], v)
  d$DUPERSID <- as.character(d$DUPERSID)
  d
}

# ---- what each column means in our extracts ---------------------------------------------------------
meaning <- c(
  DUPERSID = "Person ID (household + person number). Links the files.",
  EVNTIDX = "Event (stay) ID.", PANEL = "MEPS panel (the year the household entered the survey).",
  AGE = "Age at the end of the year (or last age if the person left the survey).",
  SEX = "Sex.", K6SUM42 = "Kessler 6 psychological distress score, 0-24 (self-administered questionnaire, mid-year).",
  PHQ242 = "PHQ-2 depression screen, 0-6 (mid-year).",
  VMCS42 = "VR-12 mental component summary (norm-based, mean about 50, mid-year).",
  TOTEXP = "Total health care expenditure in the year, all payers, US dollars.",
  OBTOTV = "Office-based provider visits in the year.", ERTOT = "Emergency room visits in the year.",
  IPDIS = "Hospital discharges in the year.", IPNGTD = "Nights in hospital in the year.",
  RXTOT = "Prescription medicines, including refills.",
  PERWT = "Person weight: the number of US civilian noninstitutionalized people this person represents.",
  VARSTR = "Variance stratum (for design-based standard errors).",
  VARPSU = "Variance PSU within stratum (for design-based standard errors).",
  depression = "Has a condition coded ICD-10 F32/F33 (depression) in the conditions file (made by R/01).",
  depression_ccsr = "Has a condition in CCSR category MBD002 (depressive disorders) (made by R/01).",
  IPBEGYR = "Stay start year.", IPBEGMM = "Stay start month.", IPENDYR = "Stay end year.", IPENDMM = "Stay end month.",
  NUMNIGHX = "Nights in hospital for this stay (edited/imputed).", EMERROOM = "Did the stay begin with an ER visit?",
  SPECCOND = "Was the stay related to a specific condition?", RSNINHOS = "Reason for entering hospital.",
  IPXP = "Total payment for the stay (facility + doctor), US dollars.", IPFXP = "Facility payment for the stay.",
  IPDXP = "Doctor payment for the stay.", LONGWT = "Longitudinal weight for the panel.",
  ALL5RDS = "Took part in all five rounds (two-year panel).", ALL9RDS = "Took part in all nine rounds (four-year panel).",
  YEARIND = "Years in the panel (four-year panels).")
pattern_meaning <- function(v) {
  if (!is.na(meaning[v])) return(meaning[v])
  r <- c("^AGE[0-9]X$" = "Age in round %s.", "^AGEY([0-9])X$" = "Age in year %s.", "^AGELSTY([0-9])$" = "Last age in year %s.",
         "^K6SUM([0-9])$" = "Kessler 6 score in round %s.", "^PHQ2([0-9])$" = "PHQ-2 score in round %s.",
         "^VMCS([0-9])$" = "VR-12 mental component in round %s.", "^VPCS([0-9])$" = "VR-12 physical component in round %s.",
         "^TOTEXPY([0-9])$" = "Total expenditure in year %s.", "^TOTSLFY([0-9])$" = "Out-of-pocket expenditure in year %s.",
         "^OBTOTVY([0-9])$" = "Office-based visits in year %s.", "^ERTOTY([0-9])$" = "ER visits in year %s.",
         "^IPDISY([0-9])$" = "Hospital discharges in year %s.", "^IPNGTDY([0-9])$" = "Hospital nights in year %s.",
         "^RXTOTY([0-9])$" = "Prescriptions in year %s.")
  for (p in names(r)) if (grepl(p, v)) return(sprintf(r[[p]], sub(p, "\\1", v)))
  ""
}
meps_label <- function(v, file) {
  if (is.null(vars)) return("")
  cand <- c(v, paste0(v, yy), paste0(v, yy, "X"), paste0(v, yy, "F"))
  h <- vars[vars$file == file & vars$variable %in% cand, "label"]
  if (length(h)) h[1] else ""
}
codebook <- do.call(rbind, lapply(list(list("Adults", fyc, "fyc"), list("Stays", stays, "stays"), list("Panel", panel, "panel")),
  function(z) if (is.null(z[[2]])) NULL else data.frame(
    sheet = z[[1]], column = names(z[[2]]),
    meps_label = vapply(names(z[[2]]), meps_label, "", file = z[[3]]),
    meaning = vapply(names(z[[2]]), pattern_meaning, ""),
    codes = vapply(names(z[[2]]), function(v) if (is.null(known[[v]])) "" else
      paste(paste0(names(known[[v]]), " = ", known[[v]]), collapse = "; "), ""),
    non_missing = vapply(z[[2]], function(x) sum(!is.na(x) & !(as.character(x) %in% names(miss))), 0),
    row.names = NULL)))

# ---- weighted summary ------------------------------------------------------------------------------
w <- fyc$PERWT; pos <- function(x) x >= 0
wmean <- function(x, ok = pos(x)) sum(w[ok] * x[ok]) / sum(w[ok])
wq <- function(x, p, ok = pos(x)) { o <- order(x[ok]); cw <- cumsum(w[ok][o]) / sum(w[ok]); x[ok][o][which(cw >= p)[1]] }
top1 <- { o <- order(-fyc$TOTEXP); cw <- cumsum(w[o]) / sum(w); sum((w * fyc$TOTEXP)[o][cw <= 0.01]) / sum(w * fyc$TOTEXP) }
adult <- fyc$AGE >= 18
summary_tab <- data.frame(
  quantity = c("People in the full-year file (rows)", "Population represented (millions; sum of PERWT)",
               "Adults 18+ in the file (rows)", "Mean spending per person (US$)", "Median spending per person (US$)",
               "90th percentile of spending (US$)", "Share of spending by the top 1% of spenders",
               "Share with no spending", "Share with a hospital stay", "Share with an ER visit",
               "Share with a depression condition (F32/F33)", "Mean Kessler 6 score (adults with a score)",
               "Hospital stays in the stays file (rows)", "People in the two-year panel (rows)"),
  value = c(nrow(fyc), round(sum(w) / 1e6, 1), sum(adult), round(wmean(fyc$TOTEXP)), wq(fyc$TOTEXP, 0.5),
            wq(fyc$TOTEXP, 0.9), sprintf("%.1f%%", 100 * top1), sprintf("%.1f%%", 100 * wmean(fyc$TOTEXP == 0, TRUE)),
            sprintf("%.1f%%", 100 * wmean(fyc$IPDIS > 0, pos(fyc$IPDIS))), sprintf("%.1f%%", 100 * wmean(fyc$ERTOT > 0, pos(fyc$ERTOT))),
            sprintf("%.1f%%", 100 * wmean(fyc$depression == 1, TRUE)),
            round(wmean(fyc$K6SUM42, adult & pos(fyc$K6SUM42)), 2),
            if (is.null(stays)) NA else nrow(stays), if (is.null(panel)) NA else nrow(panel)),
  note = c("", "US civilian noninstitutionalized population", "", "Weighted", "Weighted", "Weighted", "Weighted",
           "Weighted", "Weighted", "Weighted", "Weighted", "Weighted", "", ""))

readme <- c(
  paste0("MEPS extract for review: ", info[1]),
  "",
  "What this is. A readable copy of the small analysis files made from the Medical Expenditure Panel Survey (MEPS),",
  "run by the Agency for Healthcare Research and Quality (AHRQ). The original public use files are on the MEPS website",
  "(meps.ahrq.gov); the files used are listed below. Each data sheet has one row per person (or per hospital stay).",
  "",
  paste0("Source files: ", paste(info[-1], collapse = " | ")),
  "",
  "How to read it.",
  " - Codes are replaced by words (Sex: Male/Female). MEPS's missing-data codes appear in square brackets in coded",
  "   columns ([Inapplicable], [Refused], [Don't know], [Cannot be computed]) and as blank cells in numeric columns.",
  " - Each person is a sample member who stands for PERWT people. Unweighted counts and averages describe the sample,",
  "   not the US population; the Summary sheet gives weighted national estimates.",
  " - The Codebook sheet explains every column, with the MEPS label and the codes.",
  " - Standard errors need the survey design (VARSTR, VARPSU, PERWT); see R/05 in the guide.",
  "",
  "Made by R/13_review_workbook.R in 'Using MEPS data for simulations' (Eliot R. Weinstein, erweinstein.com).",
  "Please keep it for your own use and to show people directly; it is not for posting or redistribution.")

# ---- write ------------------------------------------------------------------------------------------
dir.create(dirname(out_file), showWarnings = FALSE)
wb <- createWorkbook()
hs <- createStyle(textDecoration = "bold", fgFill = "#DCE6F1", border = "bottom", wrapText = TRUE)
add <- function(name, d, widths = NULL) {
  addWorksheet(wb, name)
  writeData(wb, name, d, headerStyle = hs)
  freezePane(wb, name, firstRow = TRUE)
  setColWidths(wb, name, cols = seq_along(d), widths = if (is.null(widths)) "auto" else widths)
}
addWorksheet(wb, "README"); writeData(wb, "README", readme); setColWidths(wb, "README", 1, 120)
add("Summary", summary_tab, c(48, 18, 40))
add("Codebook", codebook, c(10, 14, 45, 70, 60, 12))
add("Adults", readable(fyc))
if (!is.null(stays)) add("Stays", readable(stays))
if (!is.null(panel)) add("Panel", readable(panel))
for (k in names(p4)) add(paste0("Panel4_", k), readable(p4[[k]]))
saveWorkbook(wb, out_file, overwrite = TRUE)
message("Wrote ", out_file)
