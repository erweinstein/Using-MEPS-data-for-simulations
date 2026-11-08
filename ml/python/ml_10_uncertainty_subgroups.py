"""ml_10_uncertainty_subgroups.py -- Conformal prediction intervals (split conformal, conformalized
quantile regression, and Mondrian CQR by insurance group) for log(1 + 2023 spending), and subgroup
performance of the top-10% classifier. Python version of ml/R/ml_10_uncertainty_subgroups.R (xgboost;
the MAPIE package offers the same methods ready-made).
Output: output/ml/conformal_python.csv, output/ml/subgroups_python.csv.

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

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
ALPHA = 0.10
Xtr, Xte = x_matrix(train), x_matrix(test)
fit_i, cal_i = (train.fold != 5).values, (train.fold == 5).values
y = train.log_cost.values


def xgbfit(obj, rows, rounds, **extra):
    par = {"objective": obj, "learning_rate": 0.03, "max_depth": 3, "subsample": 0.8, "colsample_bytree": 0.8,
           "min_child_weight": 5, "nthread": 2, "seed": 1, **extra}
    return xgb.train(par, xgb.DMatrix(Xtr[rows], label=y[rows]), num_boost_round=rounds)


def qhat(s, a):
    n = len(s)
    return np.sort(s)[min(n, int(np.ceil((n + 1) * (1 - a)))) - 1]


P = lambda m, X: m.predict(xgb.DMatrix(X))  # noqa: E731
m = xgbfit("reg:squarederror", fit_i, 300)
q = qhat(np.abs(y[cal_i] - P(m, Xtr[cal_i])), ALPHA)
mu = P(m, Xte)
iv = {"split": (mu - q, mu + q)}
mlo = xgbfit("reg:quantileerror", fit_i, 300, quantile_alpha=ALPHA / 2)
mhi = xgbfit("reg:quantileerror", fit_i, 300, quantile_alpha=1 - ALPHA / 2)
s_cal = np.maximum(P(mlo, Xtr[cal_i]) - y[cal_i], y[cal_i] - P(mhi, Xtr[cal_i]))
q2 = qhat(s_cal, ALPHA)
lo_t, hi_t = P(mlo, Xte), P(mhi, Xte)
iv["cqr"] = (lo_t - q2, hi_t + q2)
iv["quantile_boost_only"] = (lo_t, hi_t)
g_cal, g_te = train.insurance.values[cal_i], test.insurance.values
lo_m, hi_m = lo_t.copy(), hi_t.copy()
for g in np.unique(g_te):
    qg = qhat(s_cal[g_cal == g], ALPHA)
    lo_m[g_te == g] -= qg
    hi_m[g_te == g] += qg
iv["cqr_by_insurance"] = (lo_m, hi_m)

yt = test.log_cost.values
GROUPS = {"All": np.ones(len(test), bool), "Any private": g_te == "Any private", "Public only": g_te == "Public only",
          "Uninsured": g_te == "Uninsured", "Age 18-44": test.age.values < 45, "Age 65+": test.age.values >= 65,
          "Top 10% in 2023": test.high_cost.values == 1}
rows = []
for k, (lo, hi) in iv.items():
    for gn, i in GROUPS.items():
        rows.append({"method": k, "group": gn, "n": i.sum(), "coverage": np.mean((yt[i] >= lo[i]) & (yt[i] <= hi[i])),
                     "median_upper_dollars": np.median(np.expm1(hi[i]))})
out = pd.DataFrame(rows)
out.to_csv(OUT_DIR / "conformal_python.csv", index=False)
print("90% prediction intervals, coverage on the test set:\n",
      out.pivot(index="group", columns="method", values="coverage").loc[list(GROUPS)].round(3).to_string())

b = xgb.Booster()
b.load_model(str(OUT_DIR / "xgb_high_cost_py.json"))
p = P(b, Xte)
age_g = pd.cut(test.age, [17, 44, 64, np.inf], labels=["18-44", "45-64", "65+"]).astype(str)
sub = []
for v, s in {"insurance": test.insurance, "race_eth": test.race_eth, "age": age_g}.items():
    for lv in s.unique():
        i = (s == lv).values
        w = test.weight.values[i]
        yy = test.high_cost.values[i]
        sub.append({"variable": v, "group": lv, "n": i.sum(), "top10_share": wmean(yy, w),
                    "auc": w_auc(yy, p[i], w) if len(np.unique(yy)) == 2 else np.nan,
                    "observed_over_predicted": wmean(yy, w) / wmean(p[i], w)})
sub = pd.DataFrame(sub)
sub.to_csv(OUT_DIR / "subgroups_python.csv", index=False)
print("\nTop-10% classifier by subgroup (test set, weighted):\n", sub.round(3).to_string(index=False))
