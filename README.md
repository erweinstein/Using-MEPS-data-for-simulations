# Using MEPS data for simulations

### A how-to guide, with R code, for using public health care survey data as the population in a simulation study

**By**  
Eliot R. Weinstein  
eliotw@uchicago.edu  
[erweinstein.com](https://erweinstein.com)

Simulation studies in statistics, biostatistics and economics usually draw data
from textbook distributions (normal, gamma, lognormal), whose parameters are
sometimes "calibrated" to a real dataset. Real outcomes are often stranger than
that: health care spending has a lump at zero and a tail in which 1% of adults
account for ~19% of all spending, and the change in a symptom score over a year
can have a far heavier tail than the score itself. A **plasmode** simulation
(Franklin et al. 2014) keeps the real data as the population and draws
simulated samples from it, adding a known "truth" where one is needed.

This folder shows **how to do that with the Medical Expenditure Panel Survey
(MEPS)**, run by the Agency for Healthcare Research and Quality (AHRQ):

- how to find what you need on the MEPS website, and what to read first in the
  documentation (`WALKTHROUGH.md`, section 2);
- how to read the files into R and cut them down to small, analysis-ready
  CSVs, for any year (`R/01_extract_meps.R`; `WALKTHROUGH.md`, section 4);
- how to draw simulated samples from them that represent US adults, and eight
  worked examples of methods questions to ask with them (`R/02`–`R/09`).

The worked example uses four 2023 files, and `WALKTHROUGH.md` reports what we
got with them so you know what to expect, but **you do not need those files,
or any data, to use the guide**: `R/00_make_example_data.R` makes a synthetic
stand-in with the same columns, and the scripts use it automatically until the
real files are in place.

It grew out of a project on planning a trial's size from a pilot study, where
we needed realistic heavy-tailed outcomes; the first example is that
application. The others are general-purpose: how standard tests behave with
cost data, survey-design-aware inference and a resampling check on it, how
concentrated spending is, what a calibrated parametric model gets wrong, and
how to analyse trials with a baseline and one or several follow-ups when
effects vary and data are missing (change scores, ANCOVA, constrained
longitudinal models, mixed models, GEE, and doubly robust estimators).

**Start with [`WALKTHROUGH.md`](WALKTHROUGH.md).**

---

## Quick start (RStudio on Windows, macOS, or Linux)

**To try the code first (no downloads):** open `meps_for_simulation.Rproj` in
RStudio and run any example script, e.g. `source("R/02_describe_populations.R")`.
Without real data, the scripts build and use the synthetic example data in
`data_example/` and say so in the console.

**To use real MEPS data:**

1. Download the files you need from the
   [MEPS Data Files page](https://meps.ahrq.gov/mepsweb/data_stats/download_data_files.jsp)
   in Stata format (`.dta`), and unzip them into one folder. The worked example
   uses these four (`WALKTHROUGH.md` §2 shows where they are, and §4.2 how to
   find the equivalents for another year):

   | File | MEPS number | What one row is |
   |---|---|---|
   | `h251.dta` | HC-251, 2023 Full Year Consolidated | a person |
   | `h249.dta` | HC-249, 2023 Medical Conditions | a person's condition |
   | `h248d.dta` | HC-248D, 2023 Hospital Inpatient Stays | a hospital stay |
   | `h252.dta` | HC-252, Panel 27 Longitudinal (2022–2023) | a person, two years |

   Script 09 also uses the four-year longitudinal files for Panels 24 and 23
   (HC-245, 2019–2022, `h245.dta`; HC-236, 2018–2021, `h236.dta`), which give
   a baseline and three follow-ups. (`R/01_extract_meps.R` also has commented
   code to download all of these from R.)
2. Open `meps_for_simulation.Rproj` in RStudio (this sets the working directory).
3. In `R/01_extract_meps.R`, set `meps_dir` to that folder, using forward
   slashes (`"C:/Users/you/Documents/MEPS 2023"`), and, for another year,
   `year` and `files`. Run it. It writes small CSVs to `data/`, and from then
   on the example scripts use them.
4. Run the example scripts (in any order once the CSVs exist):

```r
source("R/02_describe_populations.R")      # what the outcomes look like (seconds)
source("R/03_plasmode_sd_planning.R")      # planning from a pilot's SD (~15-60 min)
source("R/04_tests_for_costs.R")           # t, Wilcoxon and log tests with costs (~4 min)
source("R/05_survey_design_and_concentration.R")  # design-based SEs, PSU bootstrap, top shares, Gini (~2 min)
source("R/06_parametric_vs_plasmode.R")    # calibrated two-part and NB models vs the real data (~1 min)
source("R/07_baseline_adjustment_methods.R")  # change score, ANCOVA, cLDA, AIPW with the panel (~1-2 hours)
source("R/08_varying_effects_and_dropout.R")   # the same when effects vary and follow-ups are missing (~30 min)
source("R/09_several_follow_ups.R")            # three follow-ups with MEPS's real missing data: MMRM, mixed models, GEE (~1-2 hours)
source("R/10_remedies.R")                      # MMRM fitted by arm, and a bootstrap SE for AIPW (~5-6 hours; resumes if stopped)
```

Results go to `output/` (CSV tables and PNG figures). Times are from a modest
two-core machine; the slow ones can be shortened by lowering `REPS` at the top.

**Dependencies.** R (4.1 or later, for the `|>` pipe), with `haven`, `dplyr`,
`ggplot2`, `survey`, `sandwich`, `nlme`, `geepack` and `MASS` (each script installs what
it needs if it is missing).

---

## What is here

```
README.md                         this file
WALKTHROUGH.md                    the guide: the MEPS site, each step and why, adapting it, examples, cautions
CITATION.md                       how to cite MEPS and this folder
LICENSE                           MIT (code and text; no MEPS data are included)
meps_for_simulation.Rproj         RStudio project
R/00_functions.R                  shared helpers: load the "populations", weighted moments, weighted draws
R/00_make_example_data.R          synthetic stand-in data with the same columns (for trying the code)
R/01_extract_meps.R               MEPS .dta files -> small CSVs in data/ (any year: settings at the top)
R/02_describe_populations.R       weighted moments, quantiles and histograms of eight outcomes
R/03_plasmode_sd_planning.R       pilot-based sample size: chi-square, Bonett, percentile, BCa limits
R/04_tests_for_costs.R            size and power of Welch t, Wilcoxon and log-scale t tests for spending
R/05_survey_design_and_concentration.R   Taylor vs PSU-bootstrap SEs; top 1/5/10/50% shares; Gini
R/06_parametric_vs_plasmode.R     two-part (gamma, lognormal) and negative binomial models calibrated to MEPS
R/07_baseline_adjustment_methods.R  follow-up, change score, ANCOVA (with and without interaction), cLDA, AIPW
R/08_varying_effects_and_dropout.R  the same methods when the effect varies with baseline and follow-ups are missing at random
R/09_several_follow_ups.R         baseline + three follow-ups (four-year panels): MMRM, random-slope model, GEE, summary measures, AIPW
R/10_remedies.R                   remedies for 08 and 09: MMRM fitted by arm (linear and spline in baseline), AIPW with a bootstrap SE
docs/                             figures shown in WALKTHROUGH.md (from the 2023 files)
data/                             the CSVs made by 01 (not in the repository; see data/README.md)
data_example/                     the synthetic data made by 00_make_example_data.R (made on first use)
output/                           tables and figures made by 02-10
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
