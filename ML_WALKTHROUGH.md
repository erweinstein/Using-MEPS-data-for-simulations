# Using MEPS data for machine learning: a walkthrough

Eliot R. Weinstein · November 2026

This is the machine learning half of the guide. The first half
([`WALKTHROUGH.md`](WALKTHROUGH.md)) uses MEPS as the population in simulation
studies. This half uses the same survey to show how to fit, compare and explain
the most common kinds of machine learning models, following the chapters of
three textbooks:

- *An Introduction to Statistical Learning*, 2nd ed. (James, Witten, Hastie and
  Tibshirani 2021; "ISLR"), and its Python edition (James, Witten, Hastie,
  Tibshirani and Taylor 2023; "ISLP"), which have the same chapters;
- *The Elements of Statistical Learning*, 2nd ed. (Hastie, Tibshirani and
  Friedman 2009; "ESL");
- *Interpretable Machine Learning*, 3rd ed. (Molnar 2025; online at
  christophm.github.io/interpretable-ml-book).

It adds what those books do not cover: stacking and the Super Learner, conformal
prediction intervals, subgroup checks, methods from the last four years for
tabular data (TabPFN, RealMLP, TabM), and a last chapter that comes back to
simulation and trial design (adjusting a trial's analysis for a machine-learning
prognostic score). Every chapter has an R script and a Python script that use
exactly the same rows, folds and test set, so the numbers can be compared.

As in the first half, the numbers below are what we got with the 2023 release
of the files, shown so you know what to expect. The data are not part of the
repository (see "Using the MEPS data responsibly" in the README).

Contents

0. How this half connects to the first
1. The prediction problem and the data set
2. Running the code
3. How the models are judged
4. The chapters
5. All results in one table
6. Methods from the last four years, and what we left out
7. Lessons and cautions
8. References

---

## 0. How this half connects to the first

The simulation half treats MEPS as a population to sample from. Machine learning
uses it as a population to *predict*: who will be a high spender next year, who
will go to an emergency room, how many office visits someone will have. The two
meet in three places, which is why they share a repository:

- **Realistic outcomes break models in instructive ways.** Spending's lump at zero
  and long tail, which made the textbook distributions misleading in the
  simulation half, also make the obvious regression models misleading here
  (chapter 1's log-OLS-with-smearing prediction is off by a factor of eight).
- **Fitted models make better simulation populations.** A plasmode simulation
  that needs a known "truth" can take it from a model fitted to the real data
  (Franklin et al. 2014); the better the model, the more realistic the truth.
- **Predictions shrink trials.** Chapter 12 uses a prognostic score from the
  machine learning chapters to cut the sample size a simulated trial needs by
  about half, and checks the planning formula against simulation. This is the
  same question as the pilot-study work the guide grew out of, approached from
  the other side: instead of estimating the outcome's variance better, we
  explain more of it.

## 1. The prediction problem and the data set (`ml/R/ml_00_extract.R`, `ml/python/ml_00_extract.py`)

### 1.1 A prospective design

A model that predicts this year's spending from this year's visits and
diagnoses learns little: the visits *are* the spending. Health plans,
Medicare's risk adjustment and most of the research literature instead predict
**next** year from **this** year. MEPS's two-year longitudinal files follow the
same people for two years, so we use **Panel 27** (HC-252: people who entered
MEPS in 2022 and were followed through 2023):

- **predictors from 2022:** age, sex, race and ethnicity, region, marital
  status, education, family income relative to poverty, insurance (including
  Medicare and Medicaid), employment, having a usual source of care,
  self-rated physical and mental health, 12 chronic conditions, functional
  limitations, BMI, the SF-12 physical and mental component scores and the
  PHQ-2 and K6 screens from the self-administered questionnaire, and 2022 use
  and spending (total and
  out-of-pocket spending, office visits, ER visits, hospital stays and
  prescriptions);
- **outcomes from 2023:** total spending (`cost`), log(1 + spending)
  (`log_cost`), being in the top 10% of spenders (`high_cost`; the cut-off was
  $20,030), any ER visit (`any_er`), any hospital stay (`any_ip`), and the
  number of office-based visits (`ob_visits`).

The data set has **6,353 adults** (18 or older at the end of 2022, in scope for
all five interview rounds, with a positive longitudinal weight) and 59 columns.

### 1.2 Train and test sets that the two languages share

People in the same household have correlated spending, so households are kept
together: 30% of households (1,879 adults) are the **test set**, and the rest
are split into five **cross-validation folds**. Both are fixed by a formula of
the household ID, not by a random number generator, so R and Python get exactly
the same split:

```r
u      <- ((household * 7919 + 104729) %% 1000003) / 1000003
test   <- u < 0.3
fold   <- floor(((household * 15485863 + 32452843) %% 999983) / 999983 * 5) + 1
```

All tuning (penalties, tree depths, numbers of boosting rounds, network sizes)
uses only the folds of the training households. The test set is touched once
per model, at the end.

### 1.3 Missing values

MEPS's negative codes (−1 inapplicable, −7 refused, −8 don't know, and so on)
become missing. Numeric predictors are filled with the training-set median and
get a `_miss` indicator when more than 1% are missing; categorical predictors
get a "Missing" level. This is simple and transparent, and it lets every model
use every person. Multiple imputation, or letting tree models handle missing
values themselves (xgboost, LightGBM and CatBoost all can), are alternatives;
for prediction, as opposed to estimating coefficients, the simple approach
usually costs little (Josse et al. 2024).

### 1.4 A version you can show someone

`data/meps_ml.csv` is plain text with one row per adult and readable column
names, and `data/README.md` describes every column. For a quick look without R
or Python, `R/13_review_workbook.R` writes a spreadsheet with a description of
each extract, the variable list and summary statistics. Neither file may be
posted or shared beyond the people you work with: they are made from MEPS
public use files, which AHRQ's data use agreement does not let you
redistribute (the workbook says so on its first sheet).

## 2. Running the code

The scripts are in `ml/R/` and `ml/python/`, numbered by chapter, and are run
from the repository's top folder (in RStudio, open `meps_for_simulation.Rproj`
first):

```r
source("ml/R/ml_00_extract.R")      # once; needs h252.dta (see WALKTHROUGH.md, section 2)
source("ml/R/ml_01_classical.R")    # and so on through ml_12
```

```bash
python ml/python/ml_00_extract.py   # makes the same data/meps_ml.csv
python ml/python/ml_01_classical.py
```

`ml_common.R` and `ml_common.py` hold the shared pieces: reading the data, the
predictor list, the design matrix, the survey-weighted metrics, and a function
that appends each model's test results to `output/ml/results_R.csv` or
`output/ml/results_python.csv` (rerunning a chapter replaces its own rows).

**Packages.** R: glmnet, mgcv, FNN, rpart, ranger, xgboost, e1071, nnet,
cluster, SuperLearner, glm2, ggplot2, patchwork. Python: numpy, pandas,
statsmodels, scikit-learn, pygam, xgboost, lightgbm, torch, shap, tabpfn,
pytabkit and catboost. Most chapters run in a minute or two on a laptop. The
slow ones are the support vector machines (chapter 5), the neural networks'
tuning (chapter 6, 20–40 minutes), the Super Learner (chapter 8, about 15
minutes), and TabPFN on a CPU (chapter 11; much faster on a GPU).

## 3. How the models are judged

**Survey-weighted test metrics.** MEPS is a complex sample: some groups are
oversampled, and each person carries a weight saying how many US adults they
stand for. A model's error on the test set is an estimate of its error in the
population only if the test people are weighted, so every metric is a weighted
average over test people (with the longitudinal weight, `LONGWT`):

- for continuous outcomes, RMSE, mean absolute error and R² (one minus the
  weighted mean squared error over the weighted variance);
- for binary outcomes, the area under the ROC curve (AUC; the weighted
  probability that a random case is ranked above a random non-case), the
  Brier score and the log loss;
- for counts, the Poisson deviance as well as R².

**Weights for judging, not necessarily for fitting.** Chapter 1 fits the
logistic model for `high_cost` and the OLS model for `log_cost` both with and
without the weights. Unweighted fits did slightly better on the weighted test
metrics (AUC 0.815 vs 0.812; R² 0.487 vs 0.478). When the goal is prediction,
weights in fitting buy robustness to a misspecified model at the cost of
variance, and here the variance won. The other chapters fit without weights
and evaluate with them.

**How sure can we be?** With 1,879 test people in 1,155 households, test
metrics are estimates with real uncertainty. Chapter 8 resamples test
**households** 2,000 times. The 95% interval for the Super Learner's R² for
2023 spending is 0.11 to 0.33 in R (0.14 to 0.36 in Python): almost every
model's R² for spending lies inside it. Differences between two models on the
same test people are more precise than either model's metric, because the
noise is shared, so the bootstrap is also run on the difference (section 4.8).

## 4. The chapters

Each chapter below lists the textbook sections it follows, what the scripts do,
and what we found. The R and Python scripts have the same names, except where
noted.

### 4.1 Baselines and classical regression (`ml_01_classical`; ISLR ch. 3–4, ESL ch. 3–4)

The mean of the training data, linear and logistic regression, Poisson and
negative binomial regression for visit counts, and the health economist's
standard models for spending (Deb and Norton 2018; Mihaylova et al. 2011):

- **log OLS with Duan's smearing.** Fit OLS to log(1 + spending), predict, take
  exp, and multiply by the mean of exp(residuals). **R² = −61.** The smearing
  factor was 13.1: 16% of adults (weighted) had no spending in 2023, and the
  log-scale residuals of people who went from little or nothing in 2022 to a
  lot in 2023 are so large that their exponentials dominate the mean. The predicted mean spending was $60,900
  against an actual $7,700. Smearing assumes the residuals have the same
  distribution for everyone; with a lump at zero they do not.
- **a two-part model** (logistic for any spending × gamma GLM with a log link
  for the amount if any): R² 0.19.
- **a GLM with a log link** fitted by quasi-Poisson (Manning and Mullahy
  2001): R² **0.235**, which turned out to be about as good as anything in the
  later chapters.

Two practical notes. The gamma GLM's usual fitting algorithm (IRLS) did not
converge from its default start, oscillating at a worse deviance; R's `glm2`
(step-halving; Marschner 2011) from OLS-on-log starting values fixed it, and
Python's statsmodels needed Newton's method from the same start. And the
logistic regression for `high_cost` (AUC 0.815) is the classifier every later
model has to beat.

### 4.2 Shrinkage: ridge, lasso and the elastic net (`ml_02_regularization`; ISLR ch. 6, ESL sec. 3.4 and 4.4.4)

Penalties chosen by cross-validation over the household folds (glmnet's
`foldid` in R; scikit-learn's `PredefinedSplit` in Python). With 6,353 people
and 71 columns, shrinkage changes little (log spending R² 0.489 vs 0.487 for
OLS), which is itself the lesson: penalties pay off when predictors are many
relative to people.

What the lasso keeps is more interesting than what it predicts. At the
penalty that minimizes cross-validated error it kept 48 of 71 columns for log
spending; at the "one standard error" penalty, 22. For raw dollars it kept 26
at the minimum and **none** at the one-standard-error rule: with squared error
on a long-tailed outcome, the cross-validated error is so noisy that a model
with no predictors is within one standard error of the best. (In Python,
scikit-learn has no Poisson lasso, so the visit-count model there is ridge
only.)

### 4.3 Beyond linearity: GAMs and nearest neighbours (`ml_03_nonlinear`; ISLR ch. 7 and sec. 2.2, ESL ch. 5, sec. 9.1 and ch. 13)

Generalized additive models with penalized regression splines for the
continuous predictors (mgcv in R, smoothness chosen by REML; pygam in Python)
and k-nearest neighbours on standardized predictors.

The GAMs matched the linear models (log spending R² 0.486–0.490; `high_cost`
AUC 0.816–0.822) — the relation with the strongest predictor, 2022 spending, is
already close to linear on the log scale. KNN was the weakest method that
ran without trouble (R² 0.42, AUC 0.78): with 70 dimensions, many of them
binary, "near" means little.

Python's Poisson GAM for spending diverged until the outcome was divided by
1,000 and its penalty chosen by household-fold Poisson deviance; R's Tweedie
GAM converged but predicted poorly (R² 0.11). Spending in dollars is hard on
iterative fitting algorithms.

### 4.4 Trees, random forests and boosting (`ml_04_trees_ensembles`; ISLR ch. 8, ESL sec. 9.2 and ch. 10, 15)

A single tree pruned by cross-validation (cost complexity), a random forest
(ranger in R, scikit-learn in Python; `mtry` from a small grid), and gradient
boosting (xgboost in both, plus LightGBM in Python) with shallow trees, a
learning rate of 0.03, subsampling, and the number of rounds chosen by early
stopping on the household folds.

Two choices matter more than the library:

- **The loss should match the outcome.** For spending in dollars, boosting with
  squared error got R² 0.10–0.15; with a **Tweedie** loss (a point mass at zero
  plus a continuous tail; Yang, Qian and Zou 2018) it got **0.23–0.25**. For
  visit counts the Poisson loss is the natural one.
- **Pruning can remove everything.** R's cross-validated tree for any ER visit
  and any hospital stay (outcomes with 10–15% prevalence) was pruned to a single
  node, giving AUC 0.5: rpart's cross-validated error counts misclassifications,
  and predicting "no" for everyone is hard to beat on that count. Python's tree,
  pruned by cross-validated log loss, kept its splits (AUC 0.67).

The random forest was the best single classifier for `high_cost` in both
languages (AUC 0.823–0.825). The fitted boosting models are saved for chapter
9.

### 4.5 Support vector machines (`ml_05_svm`; ISLR ch. 9, ESL ch. 12)

Linear and radial-kernel SVMs for the binary outcomes (probabilities by Platt
scaling) and support vector regression for log spending, on standardized
predictors, cost and kernel width from a grid. They were among the weakest
models here (`high_cost` AUC 0.78; any ER visit 0.54–0.66, against 0.76 for
logistic regression) and the slowest to tune. SVMs were designed for
separating classes with a margin, not for probabilities of rare outcomes; they
are included because both textbooks give them a chapter, and to show where they
stand on data like these.

### 4.6 Neural networks (`ml_06_neural_nets`; ISLR ch. 10, ESL ch. 11)

A network with one hidden layer and weight decay (nnet in R, scikit-learn's
MLP in Python), with the size and decay chosen on the household folds and each
fit averaging five random starts (ESL sec. 11.5); in Python, also a deeper
network in PyTorch (two hidden layers, ReLU, dropout, AdamW, early stopping),
the kind ISLP's deep-learning lab builds. Spending is modelled on the log scale
only.

The one-hidden-layer network matched logistic regression (`high_cost` AUC
0.812; any ER visit 0.772, the best for that outcome in Python). The deeper
network was worse on every outcome (log spending R² 0.457 vs 0.482). With six
thousand people and mostly binary predictors, a deep network has little to find
that a GLM has not, and more ways to overfit. Section 6 covers the newer
networks designed for tabular data.

### 4.7 Unsupervised learning (`ml_07_unsupervised`; ISLR ch. 12 and sec. 6.3, ESL ch. 14)

Principal components of 18 health measures (the first component is overall
poor health: every loading points toward worse health), k-means and Ward hierarchical
clustering on the leading components plus 2022 spending, and principal
components regression.

The four k-means clusters are easy to describe and line up with 2023 spending,
which the clustering never saw: a large healthy group (69% of adults; mean 2023
spending $4,700, 5% in the top 10%), a middle-aged group with poor self-rated
health (9%; mean age 46, 38% in fair or poor health; $12,400), an older group with chronic conditions (20%;
$16,700) and a small group with serious functional limitations (2%; $25,700,
38% in the top 10%). Principal components regression with 38 components
(chosen by cross-validation) got R² 0.475, a little below OLS: the directions
of greatest variation in the predictors are not the ones that predict spending
best (ISLR sec. 6.3.1).

### 4.8 Stacking and the Super Learner (`ml_08_stacking`; ESL sec. 8.8 and ch. 16)

Stacked generalization (Wolpert 1992; Breiman 1996) combines several models'
predictions; the Super Learner (van der Laan, Polley and Hubbard 2007) is the
version with a theory behind it: with cross-validated predictions and a
suitable combining step, it does asymptotically as well as the best
combination of its candidates. The scripts do it in the open:

1. fit each learner (the mean; a GLM; the lasso; a random forest; boosting with
   the outcome's loss) on four household folds and predict the fifth, so every
   training person gets an out-of-fold prediction from every learner;
2. the **discrete** Super Learner picks the learner with the smallest
   cross-validated risk;
3. the Super Learner proper finds non-negative weights, summing to one, that
   minimize the out-of-fold squared error (or log loss for `high_cost`);
4. refit each learner on all the training data, and combine with those weights.

R uses the `SuperLearner` package (`method.NNLS`, and `method.NNloglik` for the
binary outcome); Python writes the steps out, and also shows scikit-learn's
`StackingRegressor`.

The weights are informative. For spending in dollars, the Tweedie boosting
model got 94–96% of the weight; for log spending, the weight was spread over
the GLM, random forest and boosting, which make different mistakes.

The household bootstrap of the test set shows what the Super Learner bought:

| Outcome (metric) | Super Learner | Best single learner | Difference (95% interval) |
|---|---|---|---|
| log spending (R²) | 0.496 (0.447–0.541) | random forest 0.493 | 0.004 (−0.004 to 0.011) |
| spending (R²) | 0.237 (0.106–0.334) | quasi-Poisson GLM 0.235 | 0.002 (−0.064 to 0.074) |
| top 10% (AUC) | 0.815 (0.773–0.857) | random forest 0.823 | −0.008 (−0.020 to 0.004) |

(R; Python's are close, see `output/ml/test_bootstrap_python.csv`.) Nothing
that a reader of a paper would call a difference. The Super Learner's promise
is to do as well as the best learner without your knowing in advance which
that is, and that is what it did; it did not beat the best learner, and on a
test set of this size it could not have shown that it had.

### 4.9 Interpreting a black box (`ml_09_interpretation`; Molnar ch. 13, 17–20 and 23)

For the boosting model of being a top-10% spender, with the logistic
regression alongside:

- **permutation importance** (Molnar ch. 23): the loss in weighted test AUC when
  one predictor is shuffled (dummies of one categorical variable shuffled
  together). 2022 spending dominates (AUC falls by 0.10–0.12); age and 2022
  prescriptions come next, at about 0.01;
- **partial dependence and ICE curves** (ch. 19 and 13), and **accumulated local
  effects** (ch. 20), which avoid averaging over impossible combinations of
  correlated predictors (2022 spending with zero 2022 visits);
- **SHAP values** (ch. 17–18), exact for trees (TreeSHAP; Lundberg et al. 2020):
  the same ordering, then mental health (MCS, PHQ-2), high blood pressure and
  physical functioning.

Two lessons. Importance from the GLM's coefficients and from SHAP disagree on
the correlated predictors (the 2022 use and spending variables share
credit differently), and neither is "the" importance: they answer different
questions. And none of these is causal: a large SHAP value for prescriptions
says the model leans on them, not that prescriptions cause spending.

The figures (`output/ml/fig_*`) show individual people's predictions, so they
stay out of the repository with the data.

### 4.10 Prediction intervals and subgroups (`ml_10_uncertainty_subgroups`)

**Conformal prediction** (Vovk, Gammerman and Shafer 2005; Lei et al. 2018;
Angelopoulos and Bates 2023) turns any model into prediction intervals with
guaranteed coverage, on average over people exchangeable with the calibration
set. Training on folds 1–4 and calibrating on fold 5, 90% intervals for log
spending:

| Group | Split conformal | CQR | CQR by insurance | Quantile boosting alone |
|---|---|---|---|---|
| All | 0.88 | 0.91 | 0.90 | 0.88 |
| Any private | 0.88 | 0.89 | 0.89 | 0.86 |
| Public only | 0.91 | 0.92 | 0.93 | 0.90 |
| Uninsured | 0.83 | 0.97 | 0.87 | 0.93 |
| Age 18–44 | 0.83 | 0.91 | 0.89 | 0.87 |
| Age 65+ | 0.96 | 0.91 | 0.91 | 0.89 |
| Top 10% in 2023 | 0.89 | 0.65 | 0.67 | 0.61 |

(R; coverage on the test set.) Split conformal adds the same width to
everyone, so it over-covers the old and under-covers the young.
**Conformalized quantile regression** (CQR; Romano, Patterson and Candès 2019)
lets the width depend on the person and gets close to 90% in most groups.
Calibrating separately within insurance groups ("Mondrian" conformal) guarantees
coverage within each group. None of them covers next year's top spenders: the
guarantee is marginal, and a group defined by the outcome itself is exactly
where a marginal guarantee says nothing. Gibbs, Cherian and Candès (2025)
extend conformal guarantees to groups and shifts defined by the predictors, not
by the outcome.

**Subgroups.** The top-10% classifier's AUC and calibration (observed share
over predicted share), by insurance, race and ethnicity, and age:
calibration ranged from 0.78 for Black adults and 0.79 for the uninsured
(the model over-predicts their chance of being top spenders) to 1.27 for Asian
adults, with 0.60 for the small "other or multiple races" group (61 people).
These are point estimates on small groups; but a model that will be used to
allocate care or outreach should be checked like this, and calibrated within
groups if needed (Obermeyer et al. 2019 show what goes wrong when the outcome
predicted, spending, is a poor stand-in for the need it is used to measure).

### 4.11 Recent tabular models (`ml_11_tabpfn.py`, `ml_11b_realmlp_tabm_catboost.py`; Python only)

See section 6.

### 4.12 Back to trials: adjusting for a prognostic score (`ml_12_prognostic_adjustment`)

In a randomized trial, adjusting the analysis for a baseline covariate that
predicts the outcome (ANCOVA) leaves the treatment estimate unbiased and cuts
its variance by about (1 − R²), R² being the squared correlation of covariate
and outcome. **PROCOVA** (Schuler et al. 2022) uses a machine-learning
prediction from historical data as that covariate; the European Medicines
Agency qualified it in 2022 for continuous outcomes in phase 2 and 3 trials.
Randomization does the work for unbiasedness, so the model can be anything;
its quality only buys precision.

A plasmode simulation: the training households are the "historical data", the
test households the trial population. Each simulated trial draws 2 × 300
adults, randomizes them, and lowers the treated arm's log(1 + 2023 spending)
by 0.5. 5,000 trials with the effect and 5,000 without:

| Analysis | R² | Variance ratio (simulated) | 1 − R² | Power (simulated) | Power (formula) | Type I error | n per arm for 80% |
|---|---|---|---|---|---|---|---|
| Difference in means | — | 1.00 | 1.00 | 0.46 | 0.47 | 0.054 | 659 |
| ANCOVA, 2022 log spending | 0.455 | 0.55 | 0.55 | 0.71 | 0.73 | 0.053 | 360 |
| ANCOVA, lasso score | 0.522 | 0.48 | 0.48 | 0.77 | 0.78 | 0.056 | 316 |
| ANCOVA, boosting score | 0.530 | 0.47 | 0.47 | 0.78 | 0.79 | 0.054 | 310 |
| ANCOVA, both scores | 0.531 | 0.47 | 0.47 | 0.78 | 0.79 | 0.055 | 309 |

(R; Python's are within simulation error.) Three things to take from it:

1. The (1 − R²) shortcut predicted the simulated variance ratio and power
   closely, so the sample size for an adjusted trial can be planned from an
   estimate of R², the same way it is planned from an estimate of the SD. (That
   estimate of R² is itself uncertain, the same problem the pilot-study work
   studies for the SD; `pilotplan`'s `v_cluster_mean` treats it for cluster
   means.)
2. **Most of the gain came from the simplest covariate.** Last year's spending
   alone halved the variance; the machine-learning scores took it from 0.55 to
   0.47, about 50 people per arm. Worth having, but the prior-year outcome is
   where most of the information is.
3. Type I error stayed near 5% (0.053–0.056; the simulation's standard error is
   0.003), as theory says it should with any fixed score.

## 5. All results in one table

The test-set metric for each model and outcome: R² for log spending, spending
and office visits, AUC for the binary outcomes. Where R and Python differ, both
are shown (R / Python); a dash means the model was not fitted for that outcome.

<!-- RESULTS TABLE -->

## 6. Methods from the last four years, and what we left out

**What the benchmarks say.** For tabular data like these, gradient-boosted
trees were long the default to beat (Grinsztajn, Oyallon and Varoquaux 2022).
The TabArena benchmark (Erickson et al. 2025), which keeps a running
leaderboard, now finds that tuned and ensembled neural networks designed for
tables (RealMLP, TabM) match or beat boosting, that CatBoost is the strongest
boosting library under ordinary tuning, and that the tabular foundation model
TabPFN v2 is the best single model on small data sets (up to 10,000 rows), even
without tuning. It also recommends cross-validation over a single holdout for
comparing models, which is what these chapters do.

**What we ran** (Python only; each with its published defaults and no tuning of
ours):

- **TabPFN v2** (Hollmann et al. 2025; `ml_11_tabpfn.py`): a transformer
  pre-trained on millions of synthetic data sets that predicts new rows from
  the training rows "in context", without fitting parameters to them. The v2
  weights are under an Apache 2.0 licence with an attribution requirement.
  Later versions (2.5, 2.6, 3 and 3.5, released between November 2025 and
  September 2026) handle much larger data, but their weights are for
  non-commercial use only and need a licence to be accepted at Prior Labs'
  site. On a CPU, TabPFN has to be told to accept more than 1,000 training
  rows (`ignore_pretraining_limits=True`) and is slow; on a GPU it takes
  seconds.
- **RealMLP** (Holzmüller, Grinsztajn and Steinwart 2024) and **TabM**
  (Gorishniy, Kotelnikov and Babenko 2025) from the `pytabkit` package
  (`ml_11b_realmlp_tabm_catboost.py`).
- **CatBoost** (Prokhorenkova et al. 2018) with early stopping.

<!-- RECENT RESULTS -->

**From R.** TabPFN, RealMLP and TabM are Python packages; R can call them
through `reticulate`:

```r
library(reticulate)
tabpfn <- import("tabpfn")
m <- tabpfn$TabPFNRegressor$create_default_for_version(
       import("tabpfn.constants")$ModelVersion$V2, device = "cpu",
       ignore_pretraining_limits = TRUE)
m$fit(Xtr, train$log_cost)
p <- m$predict(Xte)
```

CatBoost has an R package, installed from its GitHub releases rather than CRAN.

**Also new, also in the chapters above:** conformalized quantile regression and
Mondrian conformal (chapter 10), TreeSHAP and ALE (chapter 9), and PROCOVA
(chapter 12).

**Left out, with reasons.**

- *Causal machine learning* (double/debiased machine learning, causal forests,
  meta-learners for treatment effects). MEPS is observational, and these methods
  deserve their own walkthrough with a design that can support a causal
  question; the first half's chapter 6.5 has the doubly robust estimators for
  trials.
- *Survival models* (ISLR ch. 11): the panel has no event times of interest at
  the resolution these models need.
- *Large language models on the text fields*: the public files have no free
  text.
- *AutoML* (AutoGluon, H2O): useful in practice, but they hide the steps this
  guide is meant to show.

## 7. Lessons and cautions

- **Design before models.** Predicting next year from this year is what makes
  the problem meaningful; predicting this year's spending from this year's
  visits would have given an R² near one and no information.
- **Match the loss to the outcome.** Tweedie or log-link losses for spending,
  Poisson for counts, log loss for probabilities. The choice mattered more than
  the choice of algorithm.
- **Check that fits converged.** The gamma GLM, the Poisson GAM and the Tweedie
  GAM all had trouble with spending in dollars.
- **Report the test set's uncertainty.** A test set of 1,879 people cannot
  separate models whose R² differ by 0.02; the household bootstrap says so.
- **A simple model is a strong baseline.** A log-link GLM with sensible
  predictors was within noise of everything else for spending, and logistic
  regression for the top 10%.
- **Weights for evaluation, households for resampling.** Survey weights make
  the test metrics estimates for US adults; keeping households together keeps
  correlated people from leaking between training and test.
- **Coverage is marginal.** Conformal intervals cover on average, not for every
  group, and not for groups defined by the outcome.
- **Check subgroups.** Overall AUC and calibration can hide groups for whom the
  model is miscalibrated.
- **Not causal.** None of these models says what would happen if someone's
  insurance or health changed.
- **The data use agreement.** MEPS public use files may be used for research
  and statistical purposes only; do not try to identify anyone, and do not
  redistribute the files or row-level data made from them (including
  `data/meps_ml.csv` and figures that show individuals).

## 8. References

- Angelopoulos, A. N. and S. Bates (2023). Conformal prediction: a gentle
  introduction. *Foundations and Trends in Machine Learning* 16(4), 494–591.
- Breiman, L. (1996). Stacked regressions. *Machine Learning* 24, 49–64.
- Deb, P. and E. C. Norton (2018). Modeling health care expenditures and use.
  *Annual Review of Public Health* 39, 489–505.
- Duan, N. (1983). Smearing estimate: a nonparametric retransformation method.
  *Journal of the American Statistical Association* 78, 605–610.
- Erickson, N., L. Purucker, A. Tschalzev, D. Holzmüller, P. M. Desai, D.
  Salinas and F. Hutter (2025). TabArena: a living benchmark for machine
  learning on tabular data. *NeurIPS 2025 Datasets and Benchmarks Track*;
  arXiv:2506.16791.
- European Medicines Agency (2022). Qualification opinion for Prognostic
  Covariate Adjustment (PROCOVA™). Adopted by the CHMP on 15 September 2022.
- Franklin, J. M., S. Schneeweiss, J. M. Polinski and J. A. Rassen (2014).
  Plasmode simulation for the evaluation of pharmacoepidemiologic methods in
  complex healthcare databases. *Computational Statistics & Data Analysis* 72,
  219–226.
- Gibbs, I., J. J. Cherian and E. J. Candès (2025). Conformal prediction with
  conditional guarantees. *Journal of the Royal Statistical Society Series B*
  87, 1100–1126.
- Gorishniy, Y., A. Kotelnikov and A. Babenko (2025). TabM: advancing tabular
  deep learning with parameter-efficient ensembling. *ICLR 2025*.
- Grinsztajn, L., E. Oyallon and G. Varoquaux (2022). Why do tree-based models
  still outperform deep learning on typical tabular data? *NeurIPS 2022
  Datasets and Benchmarks Track*.
- Hastie, T., R. Tibshirani and J. Friedman (2009). *The Elements of Statistical
  Learning*, 2nd ed. Springer.
- Hollmann, N., S. Müller, L. Purucker, A. Krishnakumar, M. Körfer, S. B. Hoo,
  R. T. Schirrmeister and F. Hutter (2025). Accurate predictions on small data
  with a tabular foundation model. *Nature* 637, 319–326.
- Holzmüller, D., L. Grinsztajn and I. Steinwart (2024). Better by default:
  strong pre-tuned MLPs and boosted trees on tabular data. *NeurIPS 2024*.
- James, G., D. Witten, T. Hastie and R. Tibshirani (2021). *An Introduction to
  Statistical Learning with Applications in R*, 2nd ed. Springer.
- James, G., D. Witten, T. Hastie, R. Tibshirani and J. Taylor (2023). *An
  Introduction to Statistical Learning with Applications in Python*. Springer.
- Josse, J., J. M. Chen, N. Prost, G. Varoquaux and E. Scornet (2024). On the
  consistency of supervised learning with missing values. *Statistical Papers*
  65, 5447–5479.
- Lei, J., M. G'Sell, A. Rinaldo, R. J. Tibshirani and L. Wasserman (2018).
  Distribution-free predictive inference for regression. *Journal of the
  American Statistical Association* 113, 1094–1111.
- Lundberg, S. M., G. Erion, H. Chen, A. DeGrave, J. M. Prutkin, B. Nair, R.
  Katz, J. Himmelfarb, N. Bansal and S.-I. Lee (2020). From local explanations
  to global understanding with explainable AI for trees. *Nature Machine
  Intelligence* 2, 56–67.
- Manning, W. G. and J. Mullahy (2001). Estimating log models: to transform or
  not to transform? *Journal of Health Economics* 20, 461–494.
- Marschner, I. C. (2011). glm2: fitting generalized linear models with
  convergence problems. *The R Journal* 3(2), 12–15.
- Mihaylova, B., A. Briggs, A. O'Hagan and S. G. Thompson (2011). Review of
  statistical methods for analysing healthcare resources and costs. *Health
  Economics* 20, 897–916.
- Molnar, C. (2025). *Interpretable Machine Learning: A Guide for Making Black
  Box Models Explainable*, 3rd ed. christophm.github.io/interpretable-ml-book.
- Obermeyer, Z., B. Powers, C. Vogeli and S. Mullainathan (2019). Dissecting
  racial bias in an algorithm used to manage the health of populations.
  *Science* 366, 447–453.
- Prokhorenkova, L., G. Gusev, A. Vorobev, A. V. Dorogush and A. Gulin (2018).
  CatBoost: unbiased boosting with categorical features. *NeurIPS 2018*.
- Romano, Y., E. Patterson and E. J. Candès (2019). Conformalized quantile
  regression. *NeurIPS 2019*.
- Schuler, A., D. Walsh, D. Hall, J. Walsh and C. Fisher (2022). Increasing the
  efficiency of randomized trial estimates via linear adjustment for a
  prognostic score. *The International Journal of Biostatistics* 18(2),
  329–356.
- van der Laan, M. J., E. C. Polley and A. E. Hubbard (2007). Super learner.
  *Statistical Applications in Genetics and Molecular Biology* 6(1), article 25.
- Vovk, V., A. Gammerman and G. Shafer (2005). *Algorithmic Learning in a Random
  World*. Springer.
- Wolpert, D. H. (1992). Stacked generalization. *Neural Networks* 5, 241–259.
- Yang, Y., W. Qian and H. Zou (2018). Insurance premium prediction via gradient
  tree-boosted Tweedie compound Poisson models. *Journal of Business & Economic
  Statistics* 36, 456–470.
