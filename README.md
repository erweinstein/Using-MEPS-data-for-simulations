# Using MEPS data for simulations

### Real health care outcomes as simulation populations: a worked example with the 2023 Medical Expenditure Panel Survey

**By**  
Eliot R. Weinstein  
eliotw@uchicago.edu  
[erweinstein.com](https://erweinstein.com)

Simulation studies in statistics, biostatistics and economics usually draw data
from textbook distributions (normal, gamma, lognormal), whose parameters are
sometimes "calibrated" to a real dataset. Real outcomes are often stranger than
that: health care spending has a lump at zero and a tail in which 1% of adults
account for ~19% of all spending, and the change in a symptom score over a year
can have a far heavier tail than the score itself. This folder shows how to get
four public use files from the **Medical Expenditure Panel Survey (MEPS)**, run
by the Agency for Healthcare Research and Quality (AHRQ), turn them into small
analysis-ready files, and use them as the *population* in a simulation (a
"plasmode" simulation; Franklin et al. 2014), with six worked examples.

It grew out of a project on planning a trial's size from a pilot study, where
we needed realistic heavy-tailed outcomes; the first example is that
application. The others are general-purpose: how standard tests behave with
cost data, survey-design-aware inference and a resampling check on it, how
concentrated spending is, what a calibrated parametric model gets wrong, and
whether a change score or ANCOVA should be used with a baseline measurement.

**Start with [`WALKTHROUGH.md`](WALKTHROUGH.md)**, which tours the MEPS website,
explains each step and why we took it, and summarizes what the examples found.

---

## Quick start (RStudio on Windows, macOS, or Linux)

1. Download four files from the [MEPS Data Files page](https://meps.ahrq.gov/mepsweb/data_stats/download_data_files.jsp)
   in Stata format (`.dta`), and unzip them into one folder:

   | File | MEPS number | What one row is |
   |---|---|---|
   | `h251.dta` | HC-251, 2023 Full Year Consolidated | a person |
   | `h249.dta` | HC-249, 2023 Medical Conditions | a person's condition |
   | `h248d.dta` | HC-248D, 2023 Hospital Inpatient Stays | a hospital stay |
   | `h252.dta` | HC-252, Panel 27 Longitudinal (2022–2023) | a person, two years |

   (`WALKTHROUGH.md` §2 shows where these are on the site; `R/01_extract_meps.R`
   also has commented code to download them from R.)
2. Open `meps_for_simulation.Rproj` in RStudio (this sets the working directory).
3. In `R/01_extract_meps.R`, set `meps_dir` to that folder, using forward
   slashes (`"C:/Users/you/Documents/MEPS 2023"`), and run it. It writes four
   small CSVs to `data/`.
4. Run the example scripts (in any order once the CSVs exist):

```r
source("R/02_describe_populations.R")      # what the outcomes look like (seconds)
source("R/03_plasmode_sd_planning.R")      # planning from a pilot's SD (~15-60 min)
source("R/04_tests_for_costs.R")           # t, Wilcoxon and log tests with costs (~4 min)
source("R/05_survey_design_and_concentration.R")  # design-based SEs, PSU bootstrap, top shares, Gini (~2 min)
source("R/06_parametric_vs_plasmode.R")    # calibrated two-part and NB models vs the real data (~1 min)
source("R/07_change_scores_vs_ancova.R")   # baseline-adjusted analyses with the panel (seconds)
```

Results go to `output/` (CSV tables and PNG figures). Times are from a modest
two-core machine; the slow one can be shortened by lowering `REPS` at the top.

**Dependencies.** R (4.1 or later, for the `|>` pipe), with `haven`, `dplyr`,
`ggplot2`, `survey` and `MASS` (each script installs what it needs if it is
missing).

---

## What is here

```
README.md                         this file
WALKTHROUGH.md                    the tour of the MEPS site, what we did and why, and what we found
CITATION.md                       how to cite MEPS and this folder
LICENSE                           MIT (code and text; the MEPS data are not included)
meps_for_simulation.Rproj         RStudio project
R/00_functions.R                  shared helpers: load the "populations", weighted moments, weighted draws
R/01_extract_meps.R               the four .dta files -> four small CSVs in data/
R/02_describe_populations.R       weighted moments, quantiles and histograms of eight outcomes
R/03_plasmode_sd_planning.R       pilot-based sample size: chi-square, Bonett, percentile, BCa limits
R/04_tests_for_costs.R            size and power of Welch t, Wilcoxon and log-scale t tests for spending
R/05_survey_design_and_concentration.R   Taylor vs PSU-bootstrap SEs; top 1/5/10/50% shares; Gini
R/06_parametric_vs_plasmode.R     two-part (gamma, lognormal) and negative binomial models calibrated to MEPS
R/07_change_scores_vs_ancova.R    follow-up, change score and ANCOVA with the two-year panel
docs/                             two figures shown in WALKTHROUGH.md
data/                             the CSVs made by 01 (not in the repository; see data/README.md)
output/                           tables and figures made by 02-07
```

---

## Using the MEPS data responsibly

MEPS public use files are free to download, but each comes with a **data use
agreement** (section A of every file's documentation): use the data only for
statistical analysis, make no attempt to identify anyone, do not link the
files to other identifiable data, and cite AHRQ and MEPS as the source. For
that reason this repository does **not** include the data, or any file made
from them; the scripts make them on your machine from files you download
yourself.

## How to cite

See [`CITATION.md`](CITATION.md). In short: cite the MEPS files you use (AHRQ
asks for this), and this folder if it helped.

## License

MIT for the code and text (see `LICENSE`). The MEPS data are published by AHRQ
and are not covered by this license.
