"""ml_13_model_comparison.py -- Ten learners and a stacked ensemble, side by side, on four MEPS
problems, with the plots of an applied comparison: predicted against observed in the training
data (in-sample) and in the test data (out-of-sample), the variable importance of the best
model, and, for yes/no outcomes, ROC curves and calibration.

The layout follows Stata's pystacked (Ahrens, Hansen and Schaffer 2023, Stata Journal 23(4):
909-931): a set of base learners, each tuned by cross-validation, combined by non-negative
least squares with weights that sum to one (pystacked's default final estimator, "nnls1"), and
graphed learner by learner with the stacking weight in each panel's title.

Scenarios (pick with the first argument; default all):
  S1  log(1 + 2023 spending) from 2022 characteristics          (data/meps_ml.csv, ml_00)
  S2  top 10% of 2023 spenders, yes/no                           (data/meps_ml.csv)
  S3  nights in hospital per stay, adults 2021-2023, log scale   (data/meps_stays.csv, ml_13a)
  S3b a stay of a week or more, yes/no                           (data/meps_stays.csv)
  S4  high use of care in 2023, the AI Fairness 360 definition,  (data/meps_util_2023.csv, ml_13a)
      with fairness metrics by race and ethnicity and a reweighing fix

The ten learners (the regression version; the yes/no version uses the logistic counterparts):
  OLS / logistic regression; lasso; ridge; elastic net; k nearest neighbors; a single
  regression tree (CART); random forest; gradient boosting (XGBoost); support vector machine
  (RBF kernel); neural network (multilayer perceptron); and the stack of all ten.

Design. Train/test split and the five cross-validation folds are by household (from ml_00 and
ml_13a), so people in one household never sit on both sides. Every learner is tuned on the same
five folds; the stacking weights come from out-of-fold predictions at the tuned settings. Models
are fitted without the survey weights (they are prediction models for these people, not
population estimates); test metrics are survey-weighted, with 95% intervals from a household
bootstrap of the test set.

Privacy (MEPS data use agreement): plots that show individual people (the predicted-vs-observed
scatter grids) are written to output/ml/ch13/ only. Plots of summaries (metrics, importance,
ROC, calibration by decile, fairness) are also copied to docs/ml/.

Usage:  python ml/python/ml_13_model_comparison.py [S1 S2 S3 S3b S4]

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import shutil
import sys
import time
import warnings
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import xgboost as xgb
from scipy.optimize import minimize
from sklearn.calibration import CalibratedClassifierCV
from sklearn.exceptions import ConvergenceWarning
from sklearn.linear_model import (ElasticNetCV, LassoCV, LinearRegression, LogisticRegression,
                                  LogisticRegressionCV, RidgeCV)
from sklearn.model_selection import GridSearchCV
from sklearn.neighbors import KNeighborsClassifier, KNeighborsRegressor
from sklearn.neural_network import MLPClassifier, MLPRegressor
from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC, SVR
from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor

warnings.filterwarnings("ignore", category=ConvergenceWarning)
warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=UserWarning)

OUT = Path("output/ml/ch13")
DOCS = Path("docs/ml")
OUT.mkdir(parents=True, exist_ok=True)
DOCS.mkdir(parents=True, exist_ok=True)
NJ = 2
B_BOOT = 300

# colors (validated categorical palette, light mode): blue, orange, aqua; gray for "the rest"
BLUE, ORANGE, AQUA, GRAY, INK, MUTED = "#2a78d6", "#eb6834", "#1baf7a", "#b4b2a9", "#2b2b29", "#6b6a64"
plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False,
                     "axes.edgecolor": MUTED, "axes.labelcolor": INK, "xtick.color": MUTED, "ytick.color": MUTED,
                     "axes.titlesize": 9, "axes.titlecolor": INK, "figure.dpi": 100, "savefig.dpi": 200,
                     "axes.grid": True, "grid.color": "#e6e5e0", "grid.linewidth": 0.6})

# ---- scenarios ----------------------------------------------------------------------------------------------
ML_DROP = ["person", "household", "weight", "stratum", "psu", "test", "fold", "cost", "high_cost", "log_cost",
           "ob_visits", "any_er", "any_ip"]
SKEWED = ["cost_2022", "oop_2022", "ob_visits_2022", "er_visits_2022", "stays_2022", "rx_2022"]
SCEN = {
    "S1": dict(file="data/meps_ml.csv", y="log_cost", kind="reg", drop=ML_DROP, log=SKEWED,
               title="Log(1 + 2023 spending), adults in Panel 27", unit="log(1 + $)"),
    "S2": dict(file="data/meps_ml.csv", y="high_cost", kind="clf", drop=ML_DROP, log=SKEWED,
               title="Top 10% of 2023 spenders, adults in Panel 27"),
    "S3": dict(file="data/meps_stays.csv", y="log_nights", kind="reg", log=[],
               drop=["stay", "household", "person", "weight", "stratum", "psu", "test", "fold", "file_year", "nights", "log_nights", "long_stay"],
               title="Nights per hospital stay, adults 2021-2023 (log scale)", unit="log(nights)"),
    "S3b": dict(file="data/meps_stays.csv", y="long_stay", kind="clf", log=[],
                drop=["stay", "household", "person", "weight", "stratum", "psu", "test", "fold", "file_year", "nights", "log_nights", "long_stay"],
                title="Hospital stay of a week or more, adults 2021-2023"),
    "S4": dict(file="data/meps_util_2023.csv", y="high_use", kind="clf", log=[],
               drop=["person", "household", "weight", "stratum", "psu", "test", "fold", "utilization", "high_use", "white_nh"],
               title="High use of care in 2023 (10+ visits and nights; AI Fairness 360 definition)"),
}
BODY = {"BLD": "blood", "CIR": "circulatory", "DEN": "dental", "DIG": "digestive", "EAR": "ear", "END": "endocrine",
        "EXT": "external causes", "EYE": "eye", "FAC": "health-status factors", "GEN": "genitourinary",
        "INF": "infectious", "INJ": "injury", "MAL": "congenital", "MBD": "mental/behavioral", "MUS": "musculoskeletal",
        "NEO": "neoplasms", "NVS": "nervous system", "PNL": "perinatal", "PRG": "pregnancy", "RSP": "respiratory",
        "SKN": "skin", "SYM": "symptoms/signs"}
LABELS = {"reason": "Reason for stay", "via_er": "Admitted through ER", "any_operation": "Any operation",
          "admit_month": "Month of admission", "year": "Year of admission",
          "specific_condition": "Stay for a specific condition", "n_conditions": "Number of linked conditions",
          "age": "Age", "female": "Female", "race_eth": "Race and ethnicity", "region": "Region", "marital": "Marital status",
          "education": "Education", "poverty": "Income (poverty category)", "insurance": "Insurance", "medicare": "Medicare",
          "medicaid": "Medicaid", "usual_source": "Usual source of care", "health": "Self-rated health",
          "mental_health": "Self-rated mental health", "pcs": "Physical component score (PCS)",
          "mcs": "Mental component score (MCS)", "k6": "K6 distress", "phq2": "PHQ-2", "adl_help": "Help with ADLs",
          "iadl_help": "Help with IADLs", "walk_limit": "Limited walking", "act_limit": "Activity limits",
          "cog_limit": "Cognitive limits", "employed": "Employed", "high_bp": "High blood pressure", "diabetes": "Diabetes",
          "arthritis": "Arthritis", "asthma": "Asthma", "coronary": "Coronary heart disease", "heart_attack": "Heart attack",
          "angina": "Angina", "other_heart": "Other heart disease", "stroke": "Stroke", "emphysema": "Emphysema",
          "high_chol": "High cholesterol", "cancer": "Cancer", "bmi": "BMI",
          "cost_2022": "2022 spending (log)", "oop_2022": "2022 out-of-pocket (log)", "ob_visits_2022": "2022 office visits (log)",
          "er_visits_2022": "2022 ER visits (log)", "stays_2022": "2022 hospital stays (log)", "rx_2022": "2022 prescriptions (log)",
          **{f"dx_{k}": f"Diagnosis: {v}" for k, v in BODY.items()}}
LABELS.update({f"{k}_miss": f"{v} missing" for k, v in list(LABELS.items())})
LEARNERS = ["OLS", "Lasso", "Ridge", "Elastic net", "KNN", "Tree (CART)", "Random forest", "XGBoost", "SVM",
            "Neural net"]


# ---- survey-weighted metrics -------------------------------------------------------------------------------
def wmean(x, w): return np.sum(w * x) / np.sum(w)
def w_r2(y, p, w): return 1 - wmean((y - p) ** 2, w) / wmean((y - wmean(y, w)) ** 2, w)
def w_rmse(y, p, w): return np.sqrt(wmean((y - p) ** 2, w))
def w_brier(y, p, w): return wmean((y - p) ** 2, w)


def w_auc(y, p, w):
    d = pd.DataFrame({"p": p, "pos": w * (y == 1), "neg": w * (y == 0)}).groupby("p", sort=True)[["pos", "neg"]].sum()
    cum_neg = d.neg.cumsum() - d.neg
    return np.sum(d.pos * (cum_neg + d.neg / 2)) / (d.pos.sum() * d.neg.sum())


def w_roc(y, p, w):
    o = np.argsort(-p, kind="mergesort")
    tp, fp = np.cumsum(w[o] * (y[o] == 1)), np.cumsum(w[o] * (y[o] == 0))
    return np.r_[0, fp / fp[-1]], np.r_[0, tp / tp[-1]]


def headline(kind):
    return ("R2", w_r2) if kind == "reg" else ("AUC", w_auc)


# ---- design matrix ------------------------------------------------------------------------------------------
class Encoder:
    """One 0/1 column per category level (levels fixed from the training data), numeric columns as is."""
    def __init__(self, d, cols):
        self.cols = cols
        self.cats = {c: sorted(d[c].dropna().unique()) for c in cols if not pd.api.types.is_numeric_dtype(d[c])}

    def __call__(self, d):
        out = {}
        for c in self.cols:
            if c in self.cats:
                for lv in self.cats[c]:
                    out[f"{c}={lv}"] = (d[c] == lv).astype(float).values
            else:
                out[c] = d[c].astype(float).values
        return pd.DataFrame(out)


def scaled(est): return make_pipeline(StandardScaler(), est)


def learners(kind, splits, n):
    """The ten learners with their tuning grids; each tuned by the household folds."""
    gs = lambda est, grid, sc: GridSearchCV(est, grid, cv=splits, scoring=sc, n_jobs=NJ)
    if kind == "reg":
        sc = "neg_mean_squared_error"
        return {
            "OLS": LinearRegression(),
            "Lasso": scaled(LassoCV(cv=splits, alphas=50, max_iter=20000, n_jobs=NJ)),
            "Ridge": scaled(RidgeCV(alphas=np.logspace(-2, 4, 30), cv=splits)),
            "Elastic net": scaled(ElasticNetCV(l1_ratio=[0.2, 0.5, 0.8], cv=splits, alphas=40, max_iter=20000, n_jobs=NJ)),
            "KNN": gs(scaled(KNeighborsRegressor()), {"kneighborsregressor__n_neighbors": [15, 30, 60, 120]}, sc),
            "Tree (CART)": gs(DecisionTreeRegressor(random_state=1), {"max_depth": [3, 5, 8], "min_samples_leaf": [20, 60]}, sc),
            "Random forest": gs(RandomForestRegressor(400, random_state=1, n_jobs=1),
                                {"max_features": [0.2, 0.4], "min_samples_leaf": [5, 20]}, sc),
            "XGBoost": gs(xgb.XGBRegressor(learning_rate=0.03, subsample=0.8, colsample_bytree=0.8, min_child_weight=5,
                                           n_jobs=1, random_state=1),
                          {"n_estimators": [200, 500], "max_depth": [2, 4]}, sc),
            "SVM": gs(scaled(SVR(epsilon=0.1)), {"svr__C": [0.3, 1, 3]}, sc),
            "Neural net": gs(scaled(MLPRegressor(hidden_layer_sizes=(32, 16), early_stopping=True, max_iter=600, random_state=1)),
                             {"mlpregressor__alpha": [0.1, 1.0, 10.0]}, sc)}
    sc = "neg_log_loss"
    big = n > 8000
    return {
        "OLS": LogisticRegression(C=np.inf, max_iter=5000),            # labelled "Logistic" in plots
        "Lasso": scaled(LogisticRegressionCV(Cs=15, cv=splits, l1_ratios=[1.0], solver="liblinear", scoring=sc, max_iter=5000)),
        "Ridge": scaled(LogisticRegressionCV(Cs=15, cv=splits, l1_ratios=[0.0], scoring=sc, max_iter=5000)),
        "Elastic net": scaled(LogisticRegressionCV(Cs=10, cv=splits, solver="saga", l1_ratios=[0.5],
                                                   scoring=sc, max_iter=5000, n_jobs=NJ)),
        "KNN": gs(scaled(KNeighborsClassifier()), {"kneighborsclassifier__n_neighbors": [30, 60, 120, 240]}, sc),
        "Tree (CART)": gs(DecisionTreeClassifier(random_state=1), {"max_depth": [3, 5, 8], "min_samples_leaf": [20, 60]}, sc),
        "Random forest": gs(RandomForestClassifier(400, random_state=1, n_jobs=1),
                            {"max_features": [0.2, 0.4], "min_samples_leaf": [5, 20]}, sc),
        "XGBoost": gs(xgb.XGBClassifier(learning_rate=0.03, subsample=0.8, colsample_bytree=0.8, min_child_weight=5,
                                        n_jobs=1, random_state=1),
                      {"n_estimators": [200, 500], "max_depth": [2, 4]}, sc),
        # SVM: C tuned on AUC (no probabilities needed), then Platt scaling from out-of-fold scores
        "SVM": gs(scaled(SVC(kernel="rbf", cache_size=1000)), {"svc__C": [0.5, 2] if big else [0.3, 1, 3]}, "roc_auc"),
        # no early stopping: scikit-learn's stops on validation *accuracy*, which with a 10-20% outcome can
        # halt at "predict nobody" (S3b's network did, AUC 0.63); weight decay (alpha) regularizes instead
        "Neural net": gs(scaled(MLPClassifier(hidden_layer_sizes=(32, 16), max_iter=300, random_state=1)),
                         {"mlpclassifier__alpha": [0.1, 1.0, 10.0]}, sc)}


def best_params(est):
    if isinstance(est, GridSearchCV):
        return {k.split("__")[-1]: v for k, v in est.best_params_.items()}
    last = est.steps[-1][1] if hasattr(est, "steps") else est
    for a in ("alpha_", "C_", "l1_ratio_"):
        if hasattr(last, a):
            v = getattr(last, a)
            return {a.rstrip("_"): float(np.ravel(v)[0])} | ({"l1_ratio": float(np.ravel(last.l1_ratio_)[0])} if a == "alpha_" and hasattr(last, "l1_ratio_") else {})
    return {}


def frozen(est):
    """The tuned learner with its settings fixed (so out-of-fold refits do not re-tune)."""
    from sklearn.base import clone
    if isinstance(est, GridSearchCV):
        return clone(est.best_estimator_)
    m = clone(est)
    last = m.steps[-1][1] if hasattr(m, "steps") else m
    fitted = est.steps[-1][1] if hasattr(est, "steps") else est
    if isinstance(last, LassoCV):
        return make_pipeline(StandardScaler(), __import__("sklearn.linear_model", fromlist=["Lasso"]).Lasso(alpha=fitted.alpha_, max_iter=20000))
    if isinstance(last, ElasticNetCV):
        from sklearn.linear_model import ElasticNet
        return make_pipeline(StandardScaler(), ElasticNet(alpha=fitted.alpha_, l1_ratio=fitted.l1_ratio_, max_iter=20000))
    if isinstance(last, RidgeCV):
        from sklearn.linear_model import Ridge
        return make_pipeline(StandardScaler(), Ridge(alpha=fitted.alpha_))
    if isinstance(last, LogisticRegressionCV):
        kw = dict(C=float(np.ravel(fitted.C_)[0]), l1_ratio=float(np.ravel(fitted.l1_ratio_)[0]), solver=last.solver,
                  max_iter=5000)
        return make_pipeline(StandardScaler(), LogisticRegression(**kw))
    return m


def predict(est, X, kind):
    if kind == "reg":
        return est.predict(X)
    if hasattr(est, "predict_proba"):
        try:
            return est.predict_proba(X)[:, 1]
        except AttributeError:
            pass
    return est.decision_function(X)


def convex_weights(Z, y):
    """pystacked's 'nnls1': non-negative least squares with weights summing to one."""
    k = Z.shape[1]
    r = minimize(lambda a: np.mean((y - Z @ a) ** 2), np.ones(k) / k, method="SLSQP", bounds=[(0, 1)] * k,
                 constraints=[{"type": "eq", "fun": lambda a: a.sum() - 1}], options={"maxiter": 1000, "ftol": 1e-12})
    w = np.where(r.x < 1e-4, 0, r.x)
    return w / w.sum()


def hh_boot(y, P, w, hh, fun, B=B_BOOT, seed=13):
    """Household bootstrap of a test metric for each column of P (same resamples for all)."""
    rng = np.random.default_rng(seed)
    u, inv = np.unique(hh, return_inverse=True)
    out = np.zeros((B, P.shape[1]))
    for b in range(B):
        cnt = np.bincount(rng.integers(0, len(u), len(u)), minlength=len(u))[inv]
        wb = w * cnt
        k = wb > 0
        out[b] = [fun(y[k], P[k, j], wb[k]) for j in range(P.shape[1])]
    return out


# ---- run one scenario --------------------------------------------------------------------------------------
def run(sid):
    S = SCEN[sid]
    t_all = time.time()
    d = pd.read_csv(S["file"], dtype={"person": str, "stay": str})
    for v in S["log"]:
        d[v] = np.log1p(d[v])
    kind, yname = S["kind"], S["y"]
    cols = [c for c in d.columns if c not in S["drop"]]
    tr, te = d[d.test == 0].reset_index(drop=True), d[d.test == 1].reset_index(drop=True)
    enc = Encoder(tr, cols)
    Xtr, Xte = enc(tr), enc(te)
    ytr, yte, wte = tr[yname].values.astype(float), te[yname].values.astype(float), te.weight.values
    folds = tr.fold.values
    splits = [(np.where(folds != f)[0], np.where(folds == f)[0]) for f in range(1, 6)]
    lib = learners(kind, splits, len(tr))
    name = (lambda k: "Logistic" if (k == "OLS" and kind == "clf") else k)
    print(f"\n=== {sid}: {S['title']} -- {len(tr)} training, {len(te)} test, {Xtr.shape[1]} columns ===", flush=True)

    fits, oof, ins, oos, info = {}, {}, {}, {}, []
    for k, est in lib.items():
        t0 = time.time()
        est.fit(Xtr, ytr)
        fz = frozen(est)
        z = np.zeros(len(tr))
        for a, b in splits:
            z[b] = predict(fz.fit(Xtr.iloc[a], ytr[a]), Xtr.iloc[b], kind)
        final = est
        if kind == "clf" and k == "SVM":          # Platt scaling on the out-of-fold scores
            platt = LogisticRegression(C=np.inf).fit(z.reshape(-1, 1), ytr)
            z = platt.predict_proba(z.reshape(-1, 1))[:, 1]
            final = _Platt(est, platt)
        oof[k], fits[k] = z, final
        ins[k], oos[k] = predict(final, Xtr, kind), predict(final, Xte, kind)
        info.append({"learner": name(k), "settings": str(best_params(est)), "seconds": round(time.time() - t0, 1)})
        print(f"  {name(k):14s} {time.time() - t0:6.1f}s  {best_params(est)}", flush=True)

    Z = np.column_stack([oof[k] for k in lib])
    wts = convex_weights(Z, ytr)
    W = dict(zip(lib, wts))
    ins["Stack"] = np.column_stack([ins[k] for k in lib]) @ wts
    oos["Stack"] = np.column_stack([oos[k] for k in lib]) @ wts
    oof["Stack"] = Z @ wts
    keys = list(lib) + ["Stack"]

    # metrics: test (with household-bootstrap CI), training (in-sample), and out-of-fold
    mname, mfun = headline(kind)
    Pte = np.column_stack([oos[k] for k in keys])
    boot = hh_boot(yte, Pte, wte, te.household.values, mfun)
    wtr = tr.weight.values
    rows = []
    for j, k in enumerate(keys):
        r = {"scenario": sid, "learner": name(k), "stack_weight": W.get(k, np.nan),
             f"test_{mname}": mfun(yte, oos[k], wte), "lo": np.percentile(boot[:, j], 2.5), "hi": np.percentile(boot[:, j], 97.5),
             f"train_{mname}": mfun(ytr, ins[k], wtr), f"cv_{mname}": mfun(ytr, oof[k], wtr)}
        if kind == "reg":
            r["test_RMSE"] = w_rmse(yte, oos[k], wte)
        else:
            r["test_Brier"] = w_brier(yte, oos[k], wte)
        rows.append(r)
    met = pd.DataFrame(rows).merge(pd.DataFrame(info), on="learner", how="left")
    # difference from the OLS / logistic baseline, with its own bootstrap interval
    base = boot[:, 0]
    met["diff_vs_baseline"] = met[f"test_{mname}"] - met[f"test_{mname}"].iloc[0]
    met["diff_lo"] = [np.percentile(boot[:, j] - base, 2.5) for j in range(len(keys))]
    met["diff_hi"] = [np.percentile(boot[:, j] - base, 97.5) for j in range(len(keys))]
    met.to_csv(OUT / f"{sid}_metrics.csv", index=False)
    print(met.drop(columns=["settings"]).round(3).to_string(index=False))

    best = keys[int(np.argmax(met[f"test_{mname}"].values))]
    best_single = list(lib)[int(np.argmax(met[f"test_{mname}"].values[:-1]))]
    print(f"  best on the test set: {name(best)}; best single learner: {name(best_single)}")

    # ---- plots ----
    title_of = lambda k: f"{name(k)} (weight = {W[k]:.2f})" if k in W else "Stack"
    if kind == "reg":
        grid_scatter(sid, S, keys, title_of, ytr, ins, "in_sample", "In-sample (training data) predictions")
        grid_scatter(sid, S, keys, title_of, yte, oos, "out_of_sample", "Out-of-sample (test data) predictions")
    else:
        grid_roc(sid, S, keys, title_of, ytr, ins, wtr, "in_sample", "In-sample (training data) ROC curves")
        grid_roc(sid, S, keys, title_of, yte, oos, wte, "out_of_sample", "Out-of-sample (test data) ROC curves")
        roc_overlay(sid, S, keys, name, yte, oos, wte, best)
        calibration_grid(sid, S, keys, title_of, yte, oos, wte)
    metric_plot(sid, S, met, mname)

    # ---- variable importance (permutation, survey-weighted, grouped by original variable) ----
    def pred_fn(model_keys, weights):
        def f(dd):
            X = enc(dd)
            return np.column_stack([predict(fits[k], X, kind) for k in model_keys]) @ weights
        return f
    targets = [(best, pred_fn(list(lib), wts) if best == "Stack" else pred_fn([best], np.ones(1)))]
    if best == "Stack":
        targets.append((best_single, pred_fn([best_single], np.ones(1))))
    vips = []
    for k, f in targets:
        v = perm_importance(f, te, cols, yte, wte, kind)
        v["model"] = name(k)
        vips.append(v)
    vip = pd.concat(vips)
    vip.to_csv(OUT / f"{sid}_importance.csv", index=False)
    vip_plot(sid, S, vip)
    if hasattr(fits[best_single], "best_estimator_") and best_single in ("XGBoost", "Random forest", "Tree (CART)"):
        imp = pd.Series(fits[best_single].best_estimator_.feature_importances_, index=Xtr.columns)
        imp.sort_values(ascending=False).to_csv(OUT / f"{sid}_builtin_importance_{best_single.replace(' ', '_')}.csv")

    pd.DataFrame({"household": te.household, "weight": wte, "y": yte, **{name(k): oos[k] for k in keys}}).to_csv(
        OUT / f"{sid}_test_predictions.csv", index=False)
    if sid == "S4":
        fairness(S, tr, te, enc, fits, oos, keys, name, best)
    print(f"  {sid} done in {(time.time() - t_all) / 60:.1f} min", flush=True)
    return met


class _Platt:
    def __init__(self, svm, platt): self.svm, self.platt = svm, platt
    def predict_proba(self, X):
        p = self.platt.predict_proba(self.svm.decision_function(X).reshape(-1, 1))[:, 1]
        return np.column_stack([1 - p, p])


def perm_importance(f, te, cols, y, w, kind, reps=5, seed=7):
    """Increase in survey-weighted test MSE (regression) or Brier score (yes/no) when one variable is
    shuffled, averaged over `reps` shuffles; a categorical variable's dummies move together."""
    rng = np.random.default_rng(seed)
    loss = lambda p: wmean((y - p) ** 2, w)
    base = loss(f(te))
    rows = []
    for c in cols:
        inc = []
        for _ in range(reps):
            dd = te.copy()
            dd[c] = dd[c].values[rng.permutation(len(dd))]
            inc.append(loss(f(dd)) - base)
        rows.append({"variable": c, "increase": np.mean(inc)})
    v = pd.DataFrame(rows)
    v["proportion"] = v.increase.clip(lower=0) / v.increase.clip(lower=0).sum()
    return v.sort_values("proportion", ascending=False)


# ---- plotting helpers ------------------------------------------------------------------------------------------
def save(fig, fname, public):
    fig.savefig(OUT / fname, bbox_inches="tight")
    if public:
        shutil.copy(OUT / fname, DOCS / fname)
    plt.close(fig)


def grid_scatter(sid, S, keys, title_of, y, P, tag, sup):
    fig, axs = plt.subplots(3, 4, figsize=(12, 9), sharex=True, sharey=True)
    lo, hi = np.percentile(y, 0.2), np.percentile(y, 99.8)
    pad = 0.03 * (hi - lo)
    lo, hi = lo - pad, hi + pad
    for ax, k in zip(axs.flat, keys):
        ax.scatter(y, P[k], s=4, alpha=0.25, color=BLUE, linewidths=0)
        ax.plot([lo, hi], [lo, hi], color=INK, lw=1)
        ax.set_title(title_of(k))
        ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
    for ax in axs.flat[len(keys):]:
        ax.axis("off")
    for ax in axs[-1]:
        ax.set_xlabel(f"Observed {S['unit']}")
    for ax in axs[:, 0]:
        ax.set_ylabel(f"Predicted {S['unit']}")
    fig.suptitle(f"{S['title']}\n{sup}; the line is predicted = observed", x=0.06, ha="left", fontsize=11, color=INK)
    fig.tight_layout()
    save(fig, f"fig13_{sid}_{tag}.png", public=False)          # shows individuals: output/ only


def grid_roc(sid, S, keys, title_of, y, P, w, tag, sup):
    fig, axs = plt.subplots(3, 4, figsize=(12, 9), sharex=True, sharey=True)
    for ax, k in zip(axs.flat, keys):
        fx, ty = w_roc(y, P[k], w)
        ax.plot([0, 1], [0, 1], color=GRAY, lw=1)
        ax.plot(fx, ty, color=BLUE, lw=1.6)
        ax.set_title(f"{title_of(k)}\nAUC = {w_auc(y, P[k], w):.3f}")
    for ax in axs.flat[len(keys):]:
        ax.axis("off")
    for ax in axs[-1]:
        ax.set_xlabel("False-positive rate")
    for ax in axs[:, 0]:
        ax.set_ylabel("True-positive rate")
    fig.suptitle(f"{S['title']}\n{sup}, survey-weighted", x=0.06, ha="left", fontsize=11, color=INK)
    fig.tight_layout()
    save(fig, f"fig13_{sid}_{tag}.png", public=True)


def roc_overlay(sid, S, keys, name, y, P, w, best):
    fig, ax = plt.subplots(figsize=(5.2, 5))
    ax.plot([0, 1], [0, 1], color=GRAY, lw=1, ls=":")
    hl = {"OLS": ORANGE, "Stack": AQUA}
    if best not in hl:
        hl[best] = BLUE
    for k in keys:
        if k not in hl:
            fx, ty = w_roc(y, P[k], w)
            ax.plot(fx, ty, color=GRAY, lw=0.8, alpha=0.8)
    for k, c in hl.items():
        fx, ty = w_roc(y, P[k], w)
        ax.plot(fx, ty, color=c, lw=2, label=f"{name(k)} (AUC {w_auc(y, P[k], w):.3f})")
    ax.plot([], [], color=GRAY, lw=0.8, label="Other learners")
    ax.set_xlabel("False-positive rate"); ax.set_ylabel("True-positive rate")
    ax.set_title(f"{S['title']}\nTest-data ROC curves, survey-weighted", loc="left")
    ax.legend(frameon=False, loc="lower right")
    fig.tight_layout()
    save(fig, f"fig13_{sid}_roc.png", public=True)


def calibration_grid(sid, S, keys, title_of, y, P, w):
    fig, axs = plt.subplots(3, 4, figsize=(12, 9), sharex=True, sharey=True)
    for ax, k in zip(axs.flat, keys):
        p = np.clip(P[k], 0, 1)
        q = pd.qcut(pd.Series(p).rank(method="first"), 10, labels=False)
        g = pd.DataFrame({"q": q, "p": p * w, "y": y * w, "w": w}).groupby("q").sum()
        ax.plot([0, 1], [0, 1], color=GRAY, lw=1)
        ax.plot(g.p / g.w, g.y / g.w, "o-", color=BLUE, ms=4, lw=1.2)
        ax.set_title(f"{title_of(k)}\nBrier = {w_brier(y, p, w):.3f}")
    for ax in axs.flat[len(keys):]:
        ax.axis("off")
    for ax in axs[-1]:
        ax.set_xlabel("Mean predicted probability (decile)")
    for ax in axs[:, 0]:
        ax.set_ylabel("Observed share")
    fig.suptitle(f"{S['title']}\nCalibration in the test data: deciles of predicted probability, survey-weighted",
                 x=0.06, ha="left", fontsize=11, color=INK)
    fig.tight_layout()
    save(fig, f"fig13_{sid}_calibration.png", public=True)


def metric_plot(sid, S, met, mname):
    m = met.iloc[::-1].reset_index(drop=True)
    fig, ax = plt.subplots(figsize=(6.5, 4.6))
    yy = np.arange(len(m))
    ax.hlines(yy, m.lo, m.hi, color=BLUE, lw=2)
    ax.plot(m[f"test_{mname}"], yy, "o", color=BLUE, ms=7, label="Test data (95% household-bootstrap interval)")
    ax.plot(m[f"cv_{mname}"], yy, "D", color=AQUA, ms=5, label="Cross-validated (out-of-fold, training data)")
    ax.plot(m[f"train_{mname}"], yy, "o", mfc="white", mec=ORANGE, mew=1.5, ms=7, label="In-sample (training data)")
    ax.set_yticks(yy, m.learner)
    ax.grid(axis="y", visible=False)
    ax.set_xlabel(f"Survey-weighted {mname}")
    ax.set_title(f"{S['title']}\n{mname} by learner: in-sample, cross-validated and test", loc="left")
    ax.legend(frameon=False, loc="upper center", bbox_to_anchor=(0.45, -0.13), ncol=1, fontsize=8)
    fig.tight_layout()
    save(fig, f"fig13_{sid}_metrics.png", public=True)


def vip_plot(sid, S, vip, top=15):
    models = list(vip.model.unique())
    fig, axs = plt.subplots(1, len(models), figsize=(5.4 * len(models), 5.2), squeeze=False)
    for ax, mdl in zip(axs[0], models):
        v = vip[vip.model == mdl].head(top).iloc[::-1]
        ax.barh([LABELS.get(x, x) for x in v.variable], v.proportion, color=BLUE, height=0.7)
        ax.grid(axis="y", visible=False)
        ax.set_xlabel("Proportion importance")
        ax.set_title(f"{mdl}: top {top} variables", loc="left")
    fig.suptitle(f"{S['title']}\nPermutation importance on the test data (share of the total rise in "
                 f"{'squared error' if S['kind'] == 'reg' else 'Brier score'})", x=0.02, ha="left", fontsize=10, color=INK)
    fig.tight_layout()
    save(fig, f"fig13_{sid}_vip.png", public=True)


# ---- fairness (S4) ---------------------------------------------------------------------------------------------
def group_rates(y, p, w, a, thr):
    """Metrics by group a (1 = privileged: non-Hispanic White), at threshold thr."""
    out = {}
    for g in (1, 0):
        k = a == g
        yh = (p[k] >= thr).astype(float)
        yk, wk = y[k], w[k]
        out[g] = {"base_rate": wmean(yk, wk), "selection_rate": wmean(yh, wk),
                  "TPR": wmean(yh[yk == 1], wk[yk == 1]), "FPR": wmean(yh[yk == 0], wk[yk == 0]),
                  "AUC": w_auc(yk, p[k], wk), "mean_predicted": wmean(p[k], wk)}
    r = {"disparate_impact": out[0]["selection_rate"] / out[1]["selection_rate"],
         "statistical_parity_diff": out[0]["selection_rate"] - out[1]["selection_rate"],
         "equal_opportunity_diff": out[0]["TPR"] - out[1]["TPR"],
         "average_odds_diff": 0.5 * ((out[0]["TPR"] - out[1]["TPR"]) + (out[0]["FPR"] - out[1]["FPR"])),
         "AUC_privileged": out[1]["AUC"], "AUC_unprivileged": out[0]["AUC"],
         "calib_ratio_privileged": out[1]["mean_predicted"] / out[1]["base_rate"],
         "calib_ratio_unprivileged": out[0]["mean_predicted"] / out[0]["base_rate"]}
    return r, out


def fairness(S, tr, te, enc, fits, oos, keys, name, best):
    """AI Fairness 360's MEPS metrics, the threshold set so the share flagged in the training data equals
    the share with high use, before and after Kamiran-Calders reweighing (logistic and XGBoost)."""
    from sklearn.base import clone
    y, w, a = te.high_use.values, te.weight.values, te.white_nh.values
    ytr, atr = tr.high_use.values, tr.white_nh.values
    Xtr, Xte = enc(tr), enc(te)
    rate = wmean(ytr, tr.weight.values)
    rows, detail = [], []

    def add(label, p_tr, p_te):
        o = np.argsort(-p_tr)
        cw = np.cumsum(tr.weight.values[o]) / tr.weight.sum()
        thr = p_tr[o][np.searchsorted(cw, rate)]
        r, out = group_rates(y, p_te, w, a, thr)
        rows.append({"model": label, "threshold": thr, "AUC": w_auc(y, p_te, w), **r})
        for g, v in out.items():
            detail.append({"model": label, "group": "White non-Hispanic" if g == 1 else "All other adults", **v})

    for k in ["OLS", "XGBoost"] + ([best] if best not in ("OLS", "XGBoost", "Stack") else []):
        add(name(k), predict(fits[k], Xtr, "clf"), oos[k])
    # reweighing: weight each (group, outcome) cell by P(group) P(outcome) / P(group, outcome)
    pa, py = atr.mean(), ytr.mean()
    rw = np.ones(len(tr))
    for g in (0, 1):
        for t in (0, 1):
            k = (atr == g) & (ytr == t)
            rw[k] = ((pa if g else 1 - pa) * (py if t else 1 - py)) / k.mean()
    for k in ["OLS", "XGBoost"]:
        m = fits[k] if k == "OLS" else fits[k].best_estimator_
        m2 = clone(m)
        m2.fit(Xtr, ytr, **({"sample_weight": rw}))
        add(f"{name(k)} + reweighing", m2.predict_proba(Xtr)[:, 1], m2.predict_proba(Xte)[:, 1])
    # fairness through unawareness: drop race and ethnicity from the predictors
    cols_nr = [c for c in enc.cols if c != "race_eth"]
    enc2 = Encoder(tr, cols_nr)
    for k in ["OLS", "XGBoost"]:
        m = clone(fits[k] if k == "OLS" else fits[k].best_estimator_).fit(enc2(tr), ytr)
        add(f"{name(k)} without race", m.predict_proba(enc2(tr))[:, 1], m.predict_proba(enc2(te))[:, 1])
    f = pd.DataFrame(rows)
    f.to_csv(OUT / "S4_fairness.csv", index=False)
    pd.DataFrame(detail).to_csv(OUT / "S4_fairness_by_group.csv", index=False)
    print(f.round(3).to_string(index=False))

    fig, axs = plt.subplots(1, 3, figsize=(13, 4.4), sharey=True)
    lab = f.model[::-1].values
    yy = np.arange(len(lab))
    for ax, (col, ref, ttl) in zip(axs, [("disparate_impact", 1, "Disparate impact\n(share flagged, others / White NH)"),
                                         ("equal_opportunity_diff", 0, "Equal opportunity difference\n(TPR, others - White NH)"),
                                         ("average_odds_diff", 0, "Average odds difference\n(mean of TPR and FPR gaps)")]):
        ax.axvline(ref, color=INK, lw=1)
        ax.hlines(yy, ref, f[col][::-1].values, color=GRAY, lw=1.5)
        ax.plot(f[col][::-1].values, yy, "o", color=BLUE, ms=7)
        ax.set_title(ttl, loc="left")
        ax.grid(axis="y", visible=False)
    axs[0].set_yticks(yy, lab)
    base = detail[0]
    fig.suptitle("High use of care in 2023: AI Fairness 360's group metrics on the test data, survey-weighted. "
                 f"The base rates differ ({100 * base['base_rate']:.0f}% vs "
                 f"{100 * detail[1]['base_rate']:.0f}%),\nso a perfectly accurate model would also have disparate "
                 "impact well below 1. Threshold: flag the same share as have high use in the training data.",
                 x=0.02, ha="left", fontsize=9.5, color=INK)
    fig.tight_layout()
    save(fig, "fig13_S4_fairness.png", public=True)


if __name__ == "__main__":
    todo = sys.argv[1:] or list(SCEN)
    allm = [run(s) for s in todo]
    f = OUT / "all_metrics.csv"
    new = pd.concat(allm)
    if f.exists():
        old = pd.read_csv(f)
        new = pd.concat([old[~old.scenario.isin(todo)], new])
    new.to_csv(f, index=False)
