"""ml_common.py -- Shared pieces for the machine learning walkthrough (Python): the data, the
predictor sets, design matrices, survey-weighted metrics, and a results log.
Every script in ml/python/ starts with `from ml_common import *` (run from the project folder:
`python ml/python/ml_02_regularization.py`).

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
from pathlib import Path

import numpy as np
import pandas as pd

ML_FILE = Path("data/meps_ml.csv")
OUT_DIR = Path("output/ml")
OUT_DIR.mkdir(parents=True, exist_ok=True)
if not ML_FILE.exists():
    raise SystemExit("Run ml/python/ml_00_extract.py (or ml/R/ml_00_extract.R) first.")

ml = pd.read_csv(ML_FILE)
CAT_VARS = ["race_eth", "region", "marital", "education", "poverty", "insurance"]
REFERENCE = {"race_eth": "White", "region": "South", "marital": "Married", "education": "High school",
             "poverty": "High income", "insurance": "Any private"}
ID_VARS = ["person", "household", "weight", "stratum", "psu", "test", "fold"]
OUTCOMES = ["cost", "high_cost", "log_cost", "ob_visits", "any_er", "any_ip"]
PREDICTORS = [c for c in ml.columns if c not in ID_VARS + OUTCOMES]
SKEWED = ["cost_2022", "oop_2022", "ob_visits_2022", "er_visits_2022", "stays_2022", "rx_2022"]
for v in SKEWED:
    ml["log_" + v] = np.log1p(ml[v])
PREDICTORS_LOG = [v for v in PREDICTORS if v not in SKEWED] + ["log_" + v for v in SKEWED]
NUM_VARS = [v for v in PREDICTORS_LOG if v not in CAT_VARS]

train = ml[ml.test == 0].reset_index(drop=True)
test = ml[ml.test == 1].reset_index(drop=True)


def x_matrix(d, vars=PREDICTORS_LOG, drop_reference=False):
    """Numeric columns plus one dummy per category (all levels, like model.matrix(~ . - 1)
    with full dummies in R), in a fixed column order so train and test match."""
    cols = []
    for v in vars:
        if v in CAT_VARS:
            levels = sorted(ml[v].dropna().unique())
            for lv in levels:
                if drop_reference and lv == REFERENCE[v]:
                    continue
                cols.append(pd.Series((d[v] == lv).astype(float), name=f"{v}{lv}"))
        else:
            cols.append(d[v].astype(float).rename(v))
    return pd.concat(cols, axis=1)


def folds_for(d):
    """The household-grouped cross-validation folds stored in the data (1-5)."""
    return d["fold"].values


# ---- survey-weighted metrics on the test set ----------------------------------------------------------
def wmean(x, w):
    return np.sum(w * x) / np.sum(w)


def w_rmse(y, p, w): return np.sqrt(wmean((y - p) ** 2, w))
def w_mae(y, p, w): return wmean(np.abs(y - p), w)
def w_r2(y, p, w): return 1 - wmean((y - p) ** 2, w) / wmean((y - wmean(y, w)) ** 2, w)
def w_brier(y, p, w): return wmean((y - p) ** 2, w)


def w_logloss(y, p, w):
    p = np.clip(p, 1e-12, 1 - 1e-12)
    return -wmean(y * np.log(p) + (1 - y) * np.log(1 - p), w)


def w_poisdev(y, p, w):
    p = np.maximum(p, 1e-12)
    t = np.where(y > 0, y * np.log(np.where(y > 0, y, 1) / p), 0.0)
    return 2 * wmean(t - (y - p), w)


def w_auc(y, p, w):
    """Weighted AUC: P(score of a random positive > a random negative), ties count half."""
    d = pd.DataFrame({"p": p, "pos": w * (y == 1), "neg": w * (y == 0)}).groupby("p", sort=True)[["pos", "neg"]].sum()
    cum_neg = d.neg.cumsum() - d.neg
    s = np.sum(d.pos * (cum_neg + d.neg / 2))
    return s / (d.pos.sum() * d.neg.sum())


def evaluate(outcome, pred, model, chapter, d=None):
    d = test if d is None else d
    y, w, pred = d[outcome].values.astype(float), d.weight.values, np.asarray(pred, dtype=float)
    if outcome in ("cost", "log_cost"):
        m = {"RMSE": w_rmse(y, pred, w), "MAE": w_mae(y, pred, w), "R2": w_r2(y, pred, w)}
    elif outcome == "ob_visits":
        m = {"Poisson deviance": w_poisdev(y, pred, w), "RMSE": w_rmse(y, pred, w), "R2": w_r2(y, pred, w)}
    else:
        m = {"AUC": w_auc(y, pred, w), "Brier": w_brier(y, pred, w), "Log loss": w_logloss(y, pred, w)}
    return pd.DataFrame({"chapter": chapter, "model": model, "outcome": outcome, "metric": list(m), "value": list(m.values())})


def log_results(res):
    """Append to output/ml/results_python.csv; reruns replace their own rows."""
    f = OUT_DIR / "results_python.csv"
    if f.exists():
        old = pd.read_csv(f)
        key = old.chapter + "|" + old.model + "|" + old.outcome
        old = old[~key.isin(res.chapter + "|" + res.model + "|" + res.outcome)]
        res = pd.concat([old, res], ignore_index=True)
    res.to_csv(f, index=False)
    return res


def show(res):
    print(res.pivot_table(index=["model", "outcome"], columns="metric", values="value", sort=False).round(4).to_string())
