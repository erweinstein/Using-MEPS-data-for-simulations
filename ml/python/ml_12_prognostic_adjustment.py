"""ml_12_prognostic_adjustment.py -- From prediction back to simulation and trial design: adjusting a
randomized trial's analysis for a machine-learning prognostic score. Python version of
ml/R/ml_12_prognostic_adjustment.R.

Idea (Schuler et al. 2022, "PROCOVA"): train a model on historical data to predict the outcome under
control, compute that prediction (the "prognostic score") for each trial participant from baseline
data, and adjust for it in an ANCOVA. Randomization keeps the estimate unbiased whatever the model's
quality, and the variance falls by about (1 - R^2), R^2 being the squared correlation of score and
outcome, so the sample size needed falls by the same factor.

Plasmode simulation: training households are the "historical data", test households the trial
population. Each simulated trial draws 2 x 300 adults from the test set, randomizes them, and lowers
the treated arm's log(1 + 2023 spending) by 0.5. Five analyses, 5,000 trials with and without the
effect, and the (1 - R^2) planning shortcut against the simulated power.
Output: output/ml/prognostic_python.csv.

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import xgboost as xgb
from scipy import stats
from sklearn.linear_model import LassoCV
from sklearn.model_selection import PredefinedSplit
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
Xtr, Xte = x_matrix(train), x_matrix(test)
sc = StandardScaler().fit(Xtr)
las = LassoCV(cv=PredefinedSplit(train.fold.values), max_iter=20000).fit(sc.transform(Xtr), train.log_cost)
s_lasso = las.predict(sc.transform(Xte))
par = {"objective": "reg:squarederror", "learning_rate": 0.03, "max_depth": 3, "subsample": 0.8,
       "colsample_bytree": 0.8, "min_child_weight": 5, "nthread": 2, "seed": 1}
b = xgb.train(par, xgb.DMatrix(Xtr, label=train.log_cost), num_boost_round=300)
s_xgb = b.predict(xgb.DMatrix(Xte))
y_pop, prior = test.log_cost.values, test.log_cost_2022.values
covs = {"prior": prior, "s_lasso": s_lasso, "s_xgb": s_xgb}
r2 = {k: np.corrcoef(v, y_pop)[0, 1] ** 2 for k, v in covs.items()}
print("R^2 between each baseline covariate/score and log 2023 spending:", {k: round(float(v), 3) for k, v in r2.items()})

N_ARM, DELTA, REPS = 300, -0.5, 5000
DESIGNS = {"unadjusted": [], "prior_year": ["prior"], "lasso_score": ["s_lasso"],
           "boosted_score": ["s_xgb"], "both_scores": ["s_lasso", "s_xgb"]}
rng = np.random.default_rng(2026)
t = np.repeat([0.0, 1.0], N_ARM)


def ols_t(y, Z):
    """Coefficient and classical standard error of the treatment indicator in y ~ 1 + t + Z."""
    X = np.column_stack([np.ones_like(t), t] + Z)
    XtX_inv = np.linalg.inv(X.T @ X)
    beta = XtX_inv @ X.T @ y
    resid = y - X @ beta
    s2 = resid @ resid / (len(y) - X.shape[1])
    return beta[1], np.sqrt(s2 * XtX_inv[1, 1])


def simulate(eff):
    est, se = np.zeros((len(DESIGNS), REPS)), np.zeros((len(DESIGNS), REPS))
    for r in range(REPS):
        i = rng.choice(len(y_pop), 2 * N_ARM, replace=False)
        y = y_pop[i] + eff * t
        for j, cols in enumerate(DESIGNS.values()):
            est[j, r], se[j, r] = ols_t(y, [covs[c][i] for c in cols])
    return est, se


e1, s1 = simulate(DELTA)
e0, s0 = simulate(0.0)
crit = stats.t.ppf(0.975, 2 * N_ARM - 4)
out = pd.DataFrame({"analysis": list(DESIGNS), "mean_estimate": e1.mean(1), "empirical_sd": e1.std(1, ddof=1),
                    "mean_se": s1.mean(1), "power": (np.abs(e1 / s1) > crit).mean(1),
                    "type1": (np.abs(e0 / s0) > crit).mean(1)})
out["variance_ratio"] = (out.empirical_sd / out.empirical_sd[0]) ** 2
Zb = np.column_stack([np.ones_like(y_pop), s_lasso, s_xgb])
fit_b = np.linalg.lstsq(Zb, y_pop, rcond=None)[0]
r2_both = 1 - np.var(y_pop - Zb @ fit_b) / np.var(y_pop)
out["r2"] = [0, r2["prior"], r2["s_lasso"], r2["s_xgb"], r2_both]
out["predicted_ratio"] = 1 - out.r2
sd_y = y_pop.std(ddof=1)
out["predicted_power"] = stats.norm.cdf(abs(DELTA) / (sd_y * np.sqrt(2 / N_ARM * out.predicted_ratio)) - stats.norm.ppf(0.975))
n_unadj = np.ceil(2 * (stats.norm.ppf(0.975) + stats.norm.ppf(0.8)) ** 2 * sd_y ** 2 / DELTA ** 2)
out["n_per_arm_80"] = np.ceil(n_unadj * out.predicted_ratio).astype(int)
out.to_csv(OUT_DIR / "prognostic_python.csv", index=False)
print(f"\n{REPS} simulated trials of 2 x {N_ARM}, effect {DELTA} on log(1 + spending):")
print(out.round(3).to_string(index=False))
