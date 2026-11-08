"""ml_04_trees_ensembles.py -- Trees, random forests and gradient boosting (ISLR/ISLP ch. 8; ESL sec. 9.2,
ch. 10 and 15). Python version of ml/R/ml_04_trees_ensembles.R (scikit-learn, xgboost, LightGBM).

- A single tree, pruned by cost-complexity (ccp_alpha) chosen on the household folds.
- Random forests (500 trees; max_features from a small grid on the folds).
- Gradient boosting with xgboost (the same settings as the R script) and LightGBM, with the
  number of rounds chosen by early stopping on the folds and a loss that matches the outcome
  (Tweedie for spending, logistic, Poisson, squared error for log spending).
Output: output/ml/results_python.csv (chapter "04 trees and ensembles"); xgboost models saved to
output/ml/xgb_*_py.json for chapter 9.

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
import xgboost as xgb
from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
from sklearn.model_selection import GridSearchCV, PredefinedSplit
from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "04 trees and ensembles"
Xtr, Xte = x_matrix(train), x_matrix(test)
cv = PredefinedSplit(train.fold.values - 1)
BINARY = ["high_cost", "any_er", "any_ip"]
res = []

# ---- a single tree, pruned by CV --------------------------------------------------------------------------
for y in ["log_cost", "cost", "high_cost", "any_er", "any_ip", "ob_visits"]:
    if y in BINARY:
        base, score = DecisionTreeClassifier(min_samples_leaf=20, random_state=1), "neg_log_loss"
    else:
        base, score = DecisionTreeRegressor(min_samples_leaf=20, random_state=1,
                                            criterion="poisson" if y == "ob_visits" else "squared_error"), "neg_mean_squared_error"
    path = base.cost_complexity_pruning_path(Xtr, train[y])
    alphas = np.unique(np.quantile(path.ccp_alphas, np.linspace(0, 0.99, 30)))
    m = GridSearchCV(base, {"ccp_alpha": alphas}, cv=cv, scoring=score).fit(Xtr, train[y])
    p = m.predict_proba(Xte)[:, 1] if y in BINARY else m.predict(Xte)
    res.append(evaluate(y, p, "Tree (pruned by CV)", CH))
    if y == "high_cost":
        print("Pruned tree for the top-10% outcome has", m.best_estimator_.get_n_leaves(), "leaves")

# ---- random forests -----------------------------------------------------------------------------------------
for y in ["log_cost", "cost", "high_cost", "any_er", "any_ip", "ob_visits"]:
    if y in BINARY:
        base, score = RandomForestClassifier(n_estimators=300, min_samples_leaf=10, random_state=1, n_jobs=2), "neg_brier_score"
    else:
        base, score = RandomForestRegressor(n_estimators=300, min_samples_leaf=5, random_state=1, n_jobs=2), "neg_mean_squared_error"
    m = GridSearchCV(base, {"max_features": [4, 8, 16]}, cv=cv, scoring=score).fit(Xtr, train[y])
    best = m.best_estimator_.set_params(n_estimators=500).fit(Xtr, train[y])
    p = best.predict_proba(Xte)[:, 1] if y in BINARY else best.predict(Xte)
    res.append(evaluate(y, p, "Random forest", CH))
    print(f"{y}: max_features = {m.best_params_['max_features']}")

# ---- gradient boosting: xgboost (same settings as R) and LightGBM ---------------------------------------
OBJ = {"log_cost": "reg:squarederror", "cost": "reg:tweedie", "high_cost": "binary:logistic",
       "any_er": "binary:logistic", "any_ip": "binary:logistic", "ob_visits": "count:poisson"}
LGB_OBJ = {"log_cost": "regression", "cost": "tweedie", "high_cost": "binary", "any_er": "binary",
           "any_ip": "binary", "ob_visits": "poisson"}
folds = [(np.where(train.fold != f)[0], np.where(train.fold == f)[0]) for f in range(1, 6)]
for y in OBJ:
    par = {"objective": OBJ[y], "learning_rate": 0.03, "max_depth": 3, "subsample": 0.8, "colsample_bytree": 0.8,
           "min_child_weight": 5, "nthread": 2, "seed": 1}
    if y == "cost":
        par["tweedie_variance_power"] = 1.5
    dtr = xgb.DMatrix(Xtr, label=train[y])
    h = xgb.cv(par, dtr, num_boost_round=3000, folds=folds, early_stopping_rounds=100, verbose_eval=False)
    b = xgb.train(par, dtr, num_boost_round=len(h))
    res.append(evaluate(y, b.predict(xgb.DMatrix(Xte)), f"Boosting (xgboost, {OBJ[y].split(':')[1]})", CH))
    b.save_model(str(OUT_DIR / f"xgb_{y}_py.json"))
    print(f"{y}: xgboost rounds = {len(h)}")

    lp = {"objective": LGB_OBJ[y], "learning_rate": 0.03, "num_leaves": 8, "bagging_fraction": 0.8, "bagging_freq": 1,
          "feature_fraction": 0.8, "min_data_in_leaf": 20, "num_threads": 2, "seed": 1, "verbose": -1}
    if y == "cost":
        lp["tweedie_variance_power"] = 1.5
    ltr = lgb.Dataset(Xtr, label=train[y], free_raw_data=False)
    h = lgb.cv(lp, ltr, num_boost_round=3000, folds=folds, callbacks=[lgb.early_stopping(100, verbose=False)])
    nb = len(next(iter(h.values())))
    lm = lgb.train(lp, ltr, num_boost_round=nb)
    res.append(evaluate(y, lm.predict(Xte), f"Boosting (LightGBM, {LGB_OBJ[y]})", CH))

par = {"objective": "reg:squarederror", "learning_rate": 0.03, "max_depth": 3, "subsample": 0.8,
       "colsample_bytree": 0.8, "min_child_weight": 5, "nthread": 2, "seed": 1}
dtr = xgb.DMatrix(Xtr, label=train.cost)
h = xgb.cv(par, dtr, num_boost_round=3000, folds=folds, early_stopping_rounds=100, verbose_eval=False)
b = xgb.train(par, dtr, num_boost_round=len(h))
res.append(evaluate("cost", b.predict(xgb.DMatrix(Xte)), "Boosting (xgboost, squarederror)", CH))

res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
