# Using MEPS data for simulations and machine learning

### How-to guides, with R and Python code, for using public health care survey data as a simulation population and for machine learning research

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

The second half of the guide (**machine learning**) uses the same survey to
fit, compare and explain the most common kinds of machine learning models,
chapter by chapter following *An Introduction to Statistical Learning* (R and
Python editions), *The Elements of Statistical Learning* and Molnar's
*Interpretable Machine Learning*, in **both R and Python** on exactly the same
rows, folds and test set. The task is prospective: predict 2023 spending, top
spenders, emergency room visits, hospital stays and office visits for 6,353
adults from their 2022 characteristics. Beyond the textbooks it covers
stacking and the Super Learner, conformal prediction intervals, subgroup
checks, recent tabular models (TabPFN, RealMLP, TabM, CatBoost), and a last
chapter that returns to trial design: adjusting a trial's analysis for a
machine-learning prognostic score, checked by plasmode simulation.

A companion note, [`docs/MEPS_and_institutions.md`](docs/MEPS_and_institutions.md),
sets out what MEPS can and cannot say about hospitals, health systems, plans,
ACOs and post-acute facilities, and what AHRQ's *Compendium of U.S. Health
Systems* adds; `R/14`-`R/18` link the two by Census region and year, benchmark
MEPS's hospital stays and Medicare Advantage reports against hospital and CMS
records, and use real system
sizes to plan a trial that randomizes health systems.

**Start with [`WALKTHROUGH.md`](WALKTHROUGH.md)** (simulations) **or
[`ML_WALKTHROUGH.md`](ML_WALKTHROUGH.md)** (machine learning).

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
source("R/11_mnar_sensitivity.R")              # dropout that depends on the missing values: MAR analyses, delta-adjusted MI, tipping points (~1-2 hours)
source("R/12_robust_se_mmrm_by_arm.R")         # sandwich (CR2) and bootstrap SEs for the MMRM fitted by arm (~4-6 hours; resumes if stopped)
```

**The machine learning half** needs the real Panel 27 file (`h252.dta`; the
synthetic data do not cover it). In R, set `meps_dir` in `ml/R/ml_00_extract.R`
and run the chapters in order:

```r
source("ml/R/ml_00_extract.R")       # data/meps_ml.csv: 6,353 adults, 2022 predictors, 2023 outcomes
source("ml/R/ml_01_classical.R")     # ... through ml/R/ml_12_prognostic_adjustment.R
```

In Python (3.10 or later), from the repository's top folder:

```bash
python ml/python/ml_00_extract.py    # the same data/meps_ml.csv
python ml/python/ml_01_classical.py  # ... through ml_12; ml_11 and ml_11b are Python only
python ml/python/ml_99_results_table.py   # one table of both languages' results
```

Chapter 13 compares ten learners and their stack on four problems; its extract also needs the
2021-2023 stay, condition-link, condition and full-year files (listed in the script's header):

```bash
python ml/python/ml_13a_stays_extract.py "C:/Users/YOU/folder/MEPS raw"   # or Rscript ml/R/ml_13a_stays_extract.R ...
python ml/python/ml_13_model_comparison.py          # S1-S4 (~35 min); or Rscript ml/R/ml_13_model_comparison.R (~2 hours)
python ml/python/ml_13c_summary.py                  # one figure and table across scenarios and languages
python ml/python/ml_14_updated_super_learner.py --configs   # chapter 14 (hours on a CPU, most of it TabPFN;
                                                            # add --no-foundation to skip it: about 30 minutes)
Rscript ml/R/ml_14_updated_super_learner.R                  # the SuperLearner-package version (about an hour)
```

Results go to `output/` (CSV tables and PNG figures). Times are from a modest
two-core machine; the slow ones can be shortened by lowering `REPS` at the top.

**Dependencies.** R (4.1 or later, for the `|>` pipe), with `haven`, `dplyr`,
`ggplot2`, `survey`, `sandwich`, `nlme`, `geepack`, `clubSandwich` and `MASS` (each script installs what
it needs if it is missing). The machine learning chapters also use `glmnet`,
`mgcv`, `FNN`, `rpart`, `ranger`, `xgboost`, `e1071`, `nnet`, `cluster`,
`SuperLearner`, `glm2` and `patchwork` in R, and `pandas`,
`statsmodels`, `scikit-learn`, `pygam`, `xgboost`, `lightgbm`, `torch`, `shap`,
`tabpfn`, `pytabkit` and `catboost` in Python.

---

## What is here

```
README.md                         this file
WALKTHROUGH.md                    the simulation guide: the MEPS site, each step and why, adapting it, examples, cautions
ML_WALKTHROUGH.md                 the machine learning guide: the prediction problem, each chapter, results, recent methods
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
R/11_mnar_sensitivity.R           MNAR dropout: MMRM and MI under MAR, delta-adjusted MI (pattern mixture), copy-reference MI, tipping points
R/12_robust_se_mmrm_by_arm.R      honest SEs for 10's MMRM fitted by arm: cluster-robust (CR2) and bootstrap
R/13_review_workbook.R            a readable Excel workbook of the extracts, for showing someone (not for posting)
R/14_compendium_extract.R         AHRQ's Compendium of U.S. Health Systems (2016-2023) -> stacked CSVs with Census regions
R/15_compendium_profiles.R        share of hospitals, physicians, nursing homes, home health in systems, by region and year
R/16_meps_compendium_linkage.R    MEPS (2016, 2018-2023) linked to the Compendium by region and year: benchmark, two-level models
R/17_cluster_sizes_design_effect.R  design effects for a trial randomizing real health systems (unequal cluster sizes)
R/18_cms_ma_crosswalk.R           CMS county MA files + Compendium contracts: system-plan MA by region; MEPS vs CMS benchmark
R/19_major_systems_and_events.R   the 15 major systems over time, and the mergers and spin-offs that move many hospitals
ml/R/, ml/python/                 the machine learning chapters, one script per chapter in each language:
  ml_00_extract                   h252.dta -> data/meps_ml.csv, with the shared train/test split and folds
  ml_common                       shared data loading, design matrix, survey-weighted metrics, results log
  ml_01_classical                 baselines, linear/logistic/count GLMs, log OLS with smearing, two-part model
  ml_02_regularization            ridge, lasso, elastic net
  ml_03_nonlinear                 GAMs with splines, k-nearest neighbours
  ml_04_trees_ensembles           trees, random forests, boosting (squared error, Tweedie, logistic, Poisson)
  ml_05_svm                       linear and radial SVMs, support vector regression
  ml_06_neural_nets               one hidden layer; in Python also a deeper PyTorch network
  ml_07_unsupervised              PCA, k-means and hierarchical clustering, principal components regression
  ml_08_stacking                  stacking and the Super Learner; household bootstrap of test metrics
  ml_09_interpretation            permutation importance, PDP/ICE, ALE, SHAP
  ml_10_uncertainty_subgroups     split conformal, CQR, Mondrian CQR; subgroup AUC and calibration
  ml_11_tabpfn, ml_11b_...        (Python) TabPFN v2, RealMLP, TabM, CatBoost
  ml_12_prognostic_adjustment     a trial adjusted for an ML prognostic score (PROCOVA), by plasmode simulation
  ml_13a_stays_extract            2021-2023 hospital stays (nights per stay) and 2023 "high use" (AI Fairness 360's definition)
  ml_13_model_comparison          ten learners + stack on four problems: in-/out-of-sample plots, importance, ROC,
                                  calibration, fairness by race and ethnicity
  ml_13c_summary                  (Python) gains over OLS/logistic across scenarios, both languages
  ml_14_updated_super_learner     a bigger library, fold-bagging, four meta-learners and a discrete Super Learner
                                  over them, against chapter 13's stack
ml/stata/ml_13_pystacked.do       chapter 13's length-of-stay comparison with Stata's pystacked (not run here; untested)
  ml_99_results_table             (Python) both languages' test results in one table
docs/                             figures shown in WALKTHROUGH.md (from the 2023 files)
docs/ml/                          chapter 13's summary figures (metrics, importance, ROC, calibration, fairness)
docs/MEPS_and_institutions.md     what MEPS can and cannot say about hospitals, health systems, plans, ACOs and facilities,
                                  and what the Compendium adds (R/14-R/19)
docs/NOTES_poster_and_paper.md    notes for the poster and paper (the institutions highlight box)
data/                             the CSVs made by 01 (not in the repository; see data/README.md)
data_example/                     the synthetic data made by 00_make_example_data.R (made on first use)
output/                           tables and figures made by 02-12 and the ml chapters (not in the repository)
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
