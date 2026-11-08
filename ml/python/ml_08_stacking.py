"""ml_08_stacking.py -- Stacked generalization and the Super Learner, written out by hand so each step
is visible (Wolpert 1992; Breiman 1996; van der Laan, Polley and Hubbard 2007; ESL sec. 8.8, ch. 16),
and a household bootstrap of the test metrics. Python version of ml/R/ml_08_stacking.R.

Steps: (1) out-of-fold predictions from each learner on the household folds; (2) the
cross-validated risk of each learner (the discrete Super Learner picks the smallest);
(3) non-negative weights summing to one that minimize the out-of-fold risk (squared error,
or log loss for the binary outcome); (4) refit each learner on all the training data and
combine with those weights. scikit-learn's StackingRegressor/StackingClassifier do the same
with a meta-model of your choice (shown at the end for log spending).
Output: output/ml/results_python.csv (chapter "08 stacking"), output/ml/sl_weights_python.csv,
output/ml/test_bootstrap_python.csv.

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import statsmodels.api as sm
import xgboost as xgb
from scipy.optimize import minimize
from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor, StackingRegressor
from sklearn.linear_model import LassoCV, LinearRegression, LogisticRegressionCV, RidgeCV
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "08 stacking"
Xtr_all, Xte_all = x_matrix(train), x_matrix(test)
folds = train.fold.values


# ---- learners: each is fit(X, y) -> predict(Xnew) ------------------------------------------------------
def L_mean(X, y, Xn, kind): return np.full(len(Xn), y.mean())


KEEP = list(x_matrix(train.head(1), drop_reference=True).columns)   # one dummy per category dropped


def L_glm(X, y, Xn, kind):
    # With every category's dummy plus an intercept the design is singular; drop the reference levels
    Xc, Xnc = sm.add_constant(X[KEEP], has_constant="add"), sm.add_constant(Xn[KEEP], has_constant="add")
    fam = {"gauss": sm.families.Gaussian(), "binary": sm.families.Binomial(), "qpois": sm.families.Poisson()}[kind]
    return sm.GLM(y, Xc, family=fam).fit(maxiter=100).predict(Xnc)


def L_qpois(X, y, Xn, kind): return L_glm(X, y, Xn, "qpois")


def L_lasso(X, y, Xn, kind):
    sc = StandardScaler().fit(X)
    if kind == "binary":
        m = LogisticRegressionCV(Cs=20, cv=5, penalty="l1", solver="liblinear", max_iter=2000).fit(sc.transform(X), y)
        return m.predict_proba(sc.transform(Xn))[:, 1]
    return LassoCV(cv=5, max_iter=20000).fit(sc.transform(X), y).predict(sc.transform(Xn))


def L_rf(X, y, Xn, kind):
    if kind == "binary":
        return RandomForestClassifier(500, max_features=8, min_samples_leaf=10, random_state=1, n_jobs=2).fit(X, y).predict_proba(Xn)[:, 1]
    return RandomForestRegressor(500, max_features=8, min_samples_leaf=5, random_state=1, n_jobs=2).fit(X, y).predict(Xn)


def make_xgb(objective, rounds, power=None):
    def L(X, y, Xn, kind):
        par = {"objective": objective, "learning_rate": 0.03, "max_depth": 3, "subsample": 0.8,
               "colsample_bytree": 0.8, "min_child_weight": 5, "nthread": 2, "seed": 1}
        if power:
            par["tweedie_variance_power"] = power
        return xgb.train(par, xgb.DMatrix(X, label=y), num_boost_round=rounds).predict(xgb.DMatrix(Xn))
    return L


LIBS = {"log_cost": ("gauss", {"mean": L_mean, "glm": L_glm, "lasso": L_lasso, "rf": L_rf,
                               "xgb": make_xgb("reg:squarederror", 300)}),
        "cost": ("gauss", {"mean": L_mean, "glm": L_glm, "qpois": L_qpois, "lasso": L_lasso, "rf": L_rf,
                           "xgb_tweedie": make_xgb("reg:tweedie", 200, 1.5)}),
        "high_cost": ("binary", {"mean": L_mean, "glm": lambda X, y, Xn, k: L_glm(X, y, Xn, "binary"), "lasso": L_lasso,
                                 "rf": L_rf, "xgb": make_xgb("binary:logistic", 170)})}


def convex_weights(Z, y, binary):
    """Non-negative weights summing to 1 minimizing out-of-fold risk."""
    k = Z.shape[1]

    def risk(a):
        w = np.abs(a) / np.abs(a).sum()
        p = Z @ w
        if binary:
            p = np.clip(p, 1e-6, 1 - 1e-6)
            return -np.mean(y * np.log(p) + (1 - y) * np.log(1 - p))
        return np.mean((y - p) ** 2)
    r = minimize(risk, np.ones(k) / k, method="Nelder-Mead", options={"maxiter": 20000, "xatol": 1e-6, "fatol": 1e-10})
    w = np.abs(r.x) / np.abs(r.x).sum()
    return np.where(w < 1e-3, 0, w) / np.where(w < 1e-3, 0, w).sum()


res, wts, preds = [], [], {}
for y, (kind, lib) in LIBS.items():
    yv = train[y].values.astype(float)
    Z = np.zeros((len(train), len(lib)))
    for f in range(1, 6):
        tr, va = folds != f, folds == f
        for j, L in enumerate(lib.values()):
            Z[va, j] = L(Xtr_all[tr], yv[tr], Xtr_all[va], kind)
    binary = kind == "binary"
    cv_risk = [(-np.mean(yv * np.log(np.clip(Z[:, j], 1e-6, 1 - 1e-6)) + (1 - yv) * np.log(1 - np.clip(Z[:, j], 1e-6, 1 - 1e-6))))
               if binary else np.mean((yv - Z[:, j]) ** 2) for j in range(len(lib))]
    w = convex_weights(Z, yv, binary)
    P = np.column_stack([L(Xtr_all, yv, Xte_all, kind) for L in lib.values()])
    sl = P @ w
    preds[y] = pd.DataFrame(np.column_stack([sl, P]), columns=["SL"] + list(lib))
    wts.append(pd.DataFrame({"outcome": y, "learner": list(lib), "weight": np.round(w, 3), "cv_risk": cv_risk}))
    print(wts[-1].to_string(index=False))
    res.append(evaluate(y, sl, "Super Learner", CH))
    d = int(np.argmin(cv_risk))
    res.append(evaluate(y, P[:, d], f"Discrete Super Learner ({list(lib)[d]})", CH))
    for j, nm in enumerate(lib):
        res.append(evaluate(y, P[:, j], f"  learner: {nm}", CH))

res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
pd.concat(wts).to_csv(OUT_DIR / "sl_weights_python.csv", index=False)

# scikit-learn's built-in stacking, for comparison (log spending; same household folds)
cv_splits = [(np.where(folds != f)[0], np.where(folds == f)[0]) for f in range(1, 6)]
st = StackingRegressor([("ols", LinearRegression()), ("rf", RandomForestRegressor(300, max_features=8, min_samples_leaf=5, random_state=1, n_jobs=2))],
                       final_estimator=RidgeCV(), cv=cv_splits).fit(Xtr_all, train.log_cost)
r2 = evaluate("log_cost", st.predict(Xte_all), "scikit-learn StackingRegressor (OLS + RF, ridge meta-model)", CH)
log_results(r2)
show(r2)

# ---- household bootstrap of the test metrics ---------------------------------------------------------------
rng = np.random.default_rng(1)
rows_of = test.groupby("household").indices
hh = list(rows_of)
out = []
for y, P in preds.items():
    metric = (lambda yy, p, w: w_auc(yy, p, w)) if y == "high_cost" else (lambda yy, p, w: w_r2(yy, p, w))
    singles = [c for c in P.columns if c not in ("SL", "mean")]
    best = max(singles, key=lambda c: metric(test[y].values, P[c].values, test.weight.values))
    B = np.zeros((2000, 3))
    for b in range(2000):
        idx = np.concatenate([rows_of[hh[i]] for i in rng.integers(0, len(hh), len(hh))])
        yy, w = test[y].values[idx], test.weight.values[idx]
        B[b, :2] = metric(yy, P.SL.values[idx], w), metric(yy, P[best].values[idx], w)
        B[b, 2] = B[b, 0] - B[b, 1]
    est = metric(test[y].values, P.SL.values, test.weight.values), metric(test[y].values, P[best].values, test.weight.values)
    q = np.quantile(B, [0.025, 0.975], axis=0)
    out.append({"outcome": y, "metric": "AUC" if y == "high_cost" else "R2", "best_single": best, "SL": est[0],
                "SL_lo": q[0, 0], "SL_hi": q[1, 0], "best": est[1], "best_lo": q[0, 1], "best_hi": q[1, 1],
                "diff": est[0] - est[1], "diff_lo": q[0, 2], "diff_hi": q[1, 2]})
out = pd.DataFrame(out)
print("\nTest-set metrics with 95% household-bootstrap intervals (2,000 resamples):\n", out.round(3).to_string(index=False))
out.to_csv(OUT_DIR / "test_bootstrap_python.csv", index=False)
