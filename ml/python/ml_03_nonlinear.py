"""ml_03_nonlinear.py -- Generalized additive models with splines (ISLR/ISLP ch. 7; ESL ch. 5, sec. 9.1)
and k-nearest neighbours (ISLR sec. 2.2, 3.5, 4.7; ESL ch. 13). Python version of
ml/R/ml_03_nonlinear.R (pygam, scikit-learn).

pygam has no Tweedie family, so spending uses a Poisson-family GAM with a log link (the
quasi-Poisson idea of chapter 1); R uses a Tweedie GAM. pygam's smoothing parameters are chosen
by a grid search on GCV/UBRE rather than REML.
Output: output/ml/results_python.csv (chapter "03 nonlinear").

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from functools import reduce
from operator import add
from pathlib import Path

import numpy as np
import pandas as pd
from pygam import LinearGAM, LogisticGAM, PoissonGAM, l, s
from sklearn.model_selection import GridSearchCV, PredefinedSplit
from sklearn.neighbors import KNeighborsRegressor
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "03 nonlinear"
SMOOTH = ["age", "bmi", "pcs", "mcs", "log_cost_2022", "log_rx_2022", "log_ob_visits_2022"]
Xtr_df, Xte_df = x_matrix(train, drop_reference=True), x_matrix(test, drop_reference=True)
cols = list(Xtr_df.columns)
terms = reduce(add, [s(cols.index(v), n_splines=8) if v in SMOOTH else l(i) for i, v in enumerate(cols)])
Xtr, Xte = Xtr_df.values, Xte_df.values
lam = np.logspace(-2, 3, 6)
res = []


def fit(model):
    return model(terms).gridsearch(Xtr, yv, lam=lam, progress=False)


def poisson_gam_cv(y, scale):
    """pygam's GCV/UBRE choice undersmooths Poisson GAMs for these outcomes (the fit does not
    converge and the predictions explode), so choose one smoothing level for all terms on the
    household folds by Poisson deviance. Spending is divided by `scale` (thousands of dollars)
    for numerical stability; predictions are multiplied back."""
    yv, folds, best = train[y].values / scale, train.fold.values, None
    for lv in [10, 100, 1000, 10000]:
        dev = 0.0
        for f in range(1, 6):
            g = PoissonGAM(terms, lam=lv, max_iter=1000).fit(Xtr[folds != f], yv[folds != f])
            mu, yy = np.maximum(g.predict(Xtr[folds == f]), 1e-12), yv[folds == f]
            dev += 2 * np.sum(np.where(yy > 0, yy * np.log(np.where(yy > 0, yy, 1) / mu), 0) - (yy - mu))
        if best is None or dev < best[1]:
            best = (lv, dev)
    print(f"{y}: Poisson GAM smoothing chosen by CV, lam = {best[0]}")
    return PoissonGAM(terms, lam=best[0], max_iter=1000).fit(Xtr, yv), scale


for y, model, name in [("log_cost", LinearGAM, "GAM (splines)"), ("high_cost", LogisticGAM, "GAM (splines)"),
                       ("any_er", LogisticGAM, "GAM (splines)"), ("any_ip", LogisticGAM, "GAM (splines)")]:
    yv = train[y].values
    g = fit(model)
    p = g.predict_proba(Xte) if model is LogisticGAM else g.predict(Xte)
    res.append(evaluate(y, p, name, CH))
for y, scale, name in [("cost", 1000.0, "GAM, Poisson family (log link)"), ("ob_visits", 1.0, "GAM, Poisson")]:
    g, sc_ = poisson_gam_cv(y, scale)
    res.append(evaluate(y, g.predict(Xte) * sc_, name, CH))

# ---- k-nearest neighbours on standardized predictors, k chosen on the household folds -------------
sc = StandardScaler().fit(x_matrix(train))
Ztr, Zte = sc.transform(x_matrix(train)), sc.transform(x_matrix(test))
cv = PredefinedSplit(train.fold.values - 1)
for y in ["log_cost", "cost", "high_cost", "any_er", "any_ip", "ob_visits"]:
    m = GridSearchCV(KNeighborsRegressor(), {"n_neighbors": [5, 10, 20, 40, 80, 160]}, cv=cv,
                     scoring="neg_mean_squared_error").fit(Ztr, train[y])
    print(f"{y}: k = {m.best_params_['n_neighbors']}")
    res.append(evaluate(y, m.predict(Zte), "KNN (k chosen by CV)", CH))

res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
