"""ml_14_updated_super_learner.py -- An updated Super Learner for chapter 13's five problems, built from
what the last few years of work on stacking recommend, and tested against chapter 13's stack on the
same household test sets.

What changes, and where each idea comes from:

1. A bigger, more varied library, with several fixed configurations of a learner rather than one
   tuned version (Phillips, van der Laan, Lee and Gruber 2023, "Practical considerations for
   specifying a super learner"). To chapter 13's ten learners it adds LightGBM, CatBoost, a deeper
   XGBoost, extremely randomized trees, a spline-ridge model (a GAM-like learner), and two recent
   learner made for tables: the tabular foundation model TabPFN v2 (Hollmann et al. 2025). (TabM,
   Gorishniy, Kotelnikov and Babenko 2025, was tried and dropped as too slow on a CPU.)
2. Fold-bagged predictions: the five models fitted for the out-of-fold predictions also make the
   test predictions (their average), instead of one refit on all the training data. AutoGluon and the
   TabArena benchmark do this (Erickson et al. 2020, 2025); the stacking weights are then learned on
   predictions of the same kind as those they are applied to, and slow learners are fitted 5 times,
   not 6.
3. Several meta-learners:
   - NNLS with weights summing to one (pystacked's "nnls1", chapter 13's stack);
   - for yes/no outcomes, a convex combination on the logit scale chosen by log-likelihood (the
     SuperLearner package's method.CC_nloglik);
   - greedy ensemble selection with replacement (Caruana, Niculescu-Mizil, Crew and Ksikes 2004),
     the post-hoc ensembling of AutoGluon and TabArena;
   - input-dependent stacking: the weights are a softmax of linear functions of a few variables, with
     a ridge penalty that pulls them toward constant weights (feature-weighted linear stacking, Sill
     et al. 2009; a penalized, non-Bayesian version of Bayesian hierarchical stacking, Yao, Pirs,
     Vehtari and Gelman 2022).
4. The final choice is a discrete Super Learner over all of it -- each base learner and each
   ensemble -- by cross-validated risk (squared error; log loss for yes/no outcomes, as Phillips et
   al. recommend). The ensembles' risks come from a second level of cross-validation on the
   out-of-fold predictions (household folds), so the choice never sees the test data.

Everything is judged on the test data, survey-weighted, against chapter 13's stack and against OLS /
logistic regression, with household-bootstrap 95% intervals for the differences.

Run chapter 13 first (it writes output/ml/ch13/*_test_predictions.csv). The base-learner predictions
are cached in output/ml/ch14/, so the meta-learners can be rerun without refitting.

Add --configs for 16 more random configurations of LightGBM, CatBoost and XGBoost (TabArena-style
post-hoc ensembling of many configurations; cached separately).

Usage:  python ml/python/ml_14_updated_super_learner.py [S3 S3b S1 S2 S4]   (hours on 2 CPU cores, most of
        it TabPFN -- add --no-foundation to leave it out: then about 15 minutes)

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import time
import warnings
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import xgboost as xgb  # noqa: E402
from scipy.optimize import minimize  # noqa: E402
from sklearn.base import clone  # noqa: E402
from sklearn.compose import ColumnTransformer  # noqa: E402
from sklearn.ensemble import ExtraTreesClassifier, ExtraTreesRegressor  # noqa: E402
from sklearn.linear_model import LogisticRegression, LogisticRegressionCV, RidgeCV  # noqa: E402
from sklearn.pipeline import make_pipeline  # noqa: E402
from sklearn.preprocessing import SplineTransformer, StandardScaler  # noqa: E402

import ml_13_model_comparison as M  # noqa: E402  (chapter 13's data, learners, metrics and colors)

warnings.filterwarnings("ignore")
OUT = Path("output/ml/ch14")
OUT.mkdir(parents=True, exist_ok=True)
DOCS = M.DOCS
FOUNDATION = "--no-foundation" not in sys.argv
CONFIGS = "--configs" in sys.argv
EPS = 1e-4


# ---- the added learners --------------------------------------------------------------------------------------
def extra_learners(kind, X, n):
    from catboost import CatBoostClassifier, CatBoostRegressor
    from lightgbm import LGBMClassifier, LGBMRegressor
    reg = kind == "reg"
    cont = [j for j in range(X.shape[1]) if X.iloc[:, j].nunique() > 10]          # continuous columns get splines
    spl = ColumnTransformer([("spline", SplineTransformer(n_knots=5, degree=3, extrapolation="linear"), cont)],
                            remainder="passthrough")
    lib = {
        "LightGBM": (LGBMRegressor if reg else LGBMClassifier)(
            n_estimators=400, learning_rate=0.03, num_leaves=15, min_child_samples=20, subsample=0.8, subsample_freq=1,
            colsample_bytree=0.8, reg_lambda=1.0, n_jobs=2, random_state=1, verbose=-1),
        "CatBoost": (CatBoostRegressor if reg else CatBoostClassifier)(
            iterations=800, learning_rate=0.03, depth=6, verbose=0, thread_count=2, random_seed=1),
        "XGBoost (deeper)": (xgb.XGBRegressor if reg else xgb.XGBClassifier)(
            n_estimators=600, learning_rate=0.02, max_depth=6, min_child_weight=10, subsample=0.7, colsample_bytree=0.6,
            n_jobs=2, random_state=1),
        "Extra trees": (ExtraTreesRegressor if reg else ExtraTreesClassifier)(
            n_estimators=500, min_samples_leaf=5, max_features=0.4, n_jobs=2, random_state=1),
        "Spline ridge (GAM-like)": make_pipeline(spl, StandardScaler(), RidgeCV(alphas=np.logspace(-1, 5, 30))) if reg else
            make_pipeline(spl, StandardScaler(), LogisticRegressionCV(Cs=10, cv=3, l1_ratios=[0.0], scoring="neg_log_loss",
                                                                       max_iter=5000)),
    }
    if FOUNDATION and n < 7500:      # not for S4 (10,354 training rows): too slow on a CPU here
        from tabpfn import TabPFNClassifier, TabPFNRegressor
        from tabpfn.constants import ModelVersion
        # TabM was tried and dropped: 32 minutes for five fits of the stays data on a shared 2-core CPU, and
        # weaker than the boosted trees there (as in chapter 11)
        # two ensemble members (the default is 8) to keep CPU time down
        lib["TabPFN v2"] = _Arr((TabPFNRegressor if reg else TabPFNClassifier).create_default_for_version(
            ModelVersion.V2, device="cpu", random_state=1, ignore_pretraining_limits=True, n_estimators=2))
    return lib


def config_learners(kind, seed=14):
    """Sixteen more configurations of the boosted trees, drawn at random from the ranges TabArena's search
    spaces use (Erickson et al. 2025), for post-hoc ensembling of many configurations ("--configs")."""
    from catboost import CatBoostClassifier, CatBoostRegressor
    from lightgbm import LGBMClassifier, LGBMRegressor
    reg = kind == "reg"
    rng = np.random.default_rng(seed)
    lib = {}
    for i in range(8):
        lr = rng.choice([0.01, 0.02, 0.05])
        lib[f"LightGBM config {i + 1}"] = (LGBMRegressor if reg else LGBMClassifier)(
            n_estimators={0.01: 1200, 0.02: 600, 0.05: 250}[float(lr)], learning_rate=float(lr),
            num_leaves=int(rng.choice([7, 15, 31, 63])), min_child_samples=int(rng.choice([10, 20, 50, 100])),
            colsample_bytree=float(rng.choice([0.5, 0.7, 0.9])), subsample=0.8, subsample_freq=1,
            reg_lambda=float(rng.choice([0.0, 1.0, 10.0])), n_jobs=2, random_state=i, verbose=-1)
    for i in range(4):
        lib[f"CatBoost config {i + 1}"] = (CatBoostRegressor if reg else CatBoostClassifier)(
            iterations=600, learning_rate=float(rng.choice([0.03, 0.05])), depth=int(rng.choice([4, 6, 8])),
            l2_leaf_reg=float(rng.choice([1, 3, 10])), verbose=0, thread_count=2, random_seed=i)
    for i in range(4):
        lib[f"XGBoost config {i + 1}"] = (xgb.XGBRegressor if reg else xgb.XGBClassifier)(
            n_estimators=500, learning_rate=float(rng.choice([0.02, 0.03, 0.05])), max_depth=int(rng.choice([3, 4, 5, 6])),
            min_child_weight=float(rng.choice([1, 5, 20])), subsample=float(rng.choice([0.6, 0.8, 0.9])),
            colsample_bytree=float(rng.choice([0.5, 0.7, 0.9])), reg_lambda=float(rng.choice([1, 5])), n_jobs=2, random_state=i)
    return lib


class _Arr:
    """Pass plain arrays to learners that do not take data frames."""
    def __init__(self, m): self.m = m
    def fit(self, X, y): self.m.fit(np.asarray(X, dtype=np.float32), y); return self
    def predict(self, X): return self.m.predict(np.asarray(X, dtype=np.float32))
    def predict_proba(self, X): return self.m.predict_proba(np.asarray(X, dtype=np.float32))


def fresh(m):
    return _Arr(clone(m.m)) if isinstance(m, _Arr) else clone(m)


# ---- 1. the library: out-of-fold and fold-bagged test predictions ------------------------------------------------
def build_library(sid, part="main"):
    S = M.SCEN[sid]
    cache = OUT / (f"{sid}_library.npz" if part == "main" else f"{sid}_library_{part}.npz")
    d = pd.read_csv(S["file"], dtype={"person": str, "stay": str})
    for v in S["log"]:
        d[v] = np.log1p(d[v])
    kind, yname = S["kind"], S["y"]
    cols = [c for c in d.columns if c not in S["drop"]]
    tr, te = d[d.test == 0].reset_index(drop=True), d[d.test == 1].reset_index(drop=True)
    enc = M.Encoder(tr, cols)
    Xtr, Xte = enc(tr), enc(te)
    ytr = tr[yname].values.astype(float)
    folds = tr.fold.values
    splits = [(np.where(folds != f)[0], np.where(folds == f)[0]) for f in range(1, 6)]
    if cache.exists():
        z = np.load(cache, allow_pickle=True)
        have = list(z["names"])
    else:
        have = []
    if part == "main":
        lib13 = M.learners(kind, splits, len(tr))
        plan = {k: ("tune", v) for k, v in lib13.items()} | {k: ("fixed", v) for k, v in extra_learners(kind, Xtr, len(tr)).items()}
    else:
        plan = {k: ("fixed", v) for k, v in config_learners(kind).items()}
    oof, tst, secs = ({k: z["oof"][:, i] for i, k in enumerate(have)}, {k: z["test"][:, i] for i, k in enumerate(have)},
                      dict(zip(have, z["secs"]))) if have else ({}, {}, {})
    print(f"\n=== {sid} ({part}): {S['title']} -- {len(tr)} training, {len(te)} test; {len(plan)} learners "
          f"({len(have)} cached) ===", flush=True)
    for k, (how, est) in plan.items():
        if k in have:
            continue
        t0 = time.time()
        if how == "tune":
            est.fit(Xtr, ytr)
            base = M.frozen(est)
        else:
            base = est
        z_oof, z_te = np.zeros(len(tr)), np.zeros((len(te), 5))
        for i, (a, b) in enumerate(splits):
            m = fresh(base).fit(Xtr.iloc[a], ytr[a])
            z_oof[b] = M.predict(m, Xtr.iloc[b], kind)
            z_te[:, i] = M.predict(m, Xte, kind)
        z_te = z_te.mean(axis=1)                                   # fold-bagged test prediction
        if kind == "clf" and k == "SVM":                           # Platt scaling of the out-of-fold scores
            pl = LogisticRegression(C=np.inf).fit(z_oof.reshape(-1, 1), ytr)
            z_oof, z_te = pl.predict_proba(z_oof.reshape(-1, 1))[:, 1], pl.predict_proba(z_te.reshape(-1, 1))[:, 1]
        oof[k], tst[k], secs[k] = z_oof, z_te, time.time() - t0
        names = list(oof)
        np.savez(cache, names=np.array(names, dtype=object), oof=np.column_stack([oof[n] for n in names]),
                 test=np.column_stack([tst[n] for n in names]), secs=np.array([secs[n] for n in names]))
        print(f"  {k:24s} {secs[k]:7.1f}s", flush=True)
    names = [k for k in plan if k in oof]
    return dict(S=S, kind=kind, tr=tr, te=te, ytr=ytr, yte=te[yname].values.astype(float), folds=folds,
                names=names, Z=np.column_stack([oof[n] for n in names]), Zt=np.column_stack([tst[n] for n in names]),
                secs={n: secs[n] for n in names})


# ---- 2. meta-learners --------------------------------------------------------------------------------------------
def save(fig, fname, public):
    fig.savefig(OUT / fname, bbox_inches="tight", dpi=200)
    if public:
        fig.savefig(DOCS / fname, bbox_inches="tight", dpi=200)
    plt.close(fig)


def clip(p): return np.clip(p, EPS, 1 - EPS)
def logit(p): p = clip(p); return np.log(p / (1 - p))
def logloss(y, p, w=None): p = clip(p); return np.average(-(y * np.log(p) + (1 - y) * np.log(1 - p)), weights=w)
def sqerr(y, p, w=None): return np.average((y - p) ** 2, weights=w)


def risk(kind): return sqerr if kind == "reg" else logloss


def meta_nnls(Z, y, kind, ctx):
    a = M.convex_weights(Z, y)
    return a, (lambda Zt, ct: Zt @ a)


def meta_cc_nloglik(Z, y, kind, ctx):
    """Convex combination of the learners' logits, by log-likelihood (SuperLearner's method.CC_nloglik)."""
    L = logit(Z)
    k = L.shape[1]
    f = lambda a: logloss(y, 1 / (1 + np.exp(-(L @ a))))
    g = lambda a: L.T @ (1 / (1 + np.exp(-(L @ a))) - y) / len(y)
    r = minimize(f, np.ones(k) / k, jac=g, method="SLSQP", bounds=[(0, 1)] * k,
                 constraints=[{"type": "eq", "fun": lambda a: a.sum() - 1}], options={"maxiter": 500})
    a = np.where(r.x < 1e-4, 0, r.x); a = a / a.sum()
    return a, (lambda Zt, ct: 1 / (1 + np.exp(-(logit(Zt) @ a))))


def meta_caruana(Z, y, kind, ctx, iters=100):
    """Greedy ensemble selection with replacement: add, one at a time, the learner that most lowers the
    loss of the running average; the weights are the counts."""
    loss = risk(kind)
    cnt = np.zeros(Z.shape[1])
    s = np.zeros(len(y))
    for t in range(iters):
        j = int(np.argmin([loss(y, (s + Z[:, k]) / (t + 1)) for k in range(Z.shape[1])]))
        cnt[j] += 1
        s += Z[:, j]
    a = cnt / cnt.sum()
    return a, (lambda Zt, ct: Zt @ a)


def meta_input_dependent(Z, y, kind, ctx, lams=(0.001, 0.01, 0.1)):
    """Weights w_k(x) = softmax_k(c_k + b_k' z(x)) over the learners NNLS keeps, with z = age (standardized)
    and the tertile of the NNLS stack's prediction; ridge penalty lam * |b|^2 toward constant weights,
    lam chosen by 4-fold cross-validation inside the training rows."""
    a0 = M.convex_weights(Z, y)
    keep = np.where(a0 > 0)[0]
    if len(keep) < 2:
        return a0, (lambda Zt, ct: Zt @ a0)
    F = Z[:, keep]
    base = Z @ a0
    cuts = np.quantile(base, [1 / 3, 2 / 3])
    age_mu, age_sd = ctx["age"].mean(), ctx["age"].std()

    def zmat(Zx, age):
        b0 = Zx @ a0
        return np.column_stack([(age - age_mu) / age_sd, (b0 > cuts[0]) & (b0 <= cuts[1]), b0 > cuts[1]]).astype(float)
    Zf = zmat(Z, ctx["age"])
    K, P = F.shape[1], Zf.shape[1]
    binary = kind == "clf"

    def unpack(th): return th[:K], th[K:].reshape(K, P)

    def fit(Fx, Zx, yx, lam):
        c0 = np.log(np.maximum(a0[keep], 1e-3))

        def obj(th):
            c, B = unpack(th)
            eta = c[None, :] + Zx @ B.T
            eta -= eta.max(axis=1, keepdims=True)
            W = np.exp(eta); W /= W.sum(axis=1, keepdims=True)
            p = (W * Fx).sum(axis=1)
            if binary:
                pc = clip(p)
                L = logloss(yx, pc); gp = -(yx / pc - (1 - yx) / (1 - pc)) / len(yx)
            else:
                L = sqerr(yx, p); gp = -2 * (yx - p) / len(yx)
            G = gp[:, None] * W * (Fx - p[:, None])                       # d loss / d eta_ik
            gc, gB = G.sum(axis=0), G.T @ Zx + 2 * lam * B
            return L + lam * np.sum(B ** 2), np.r_[gc, gB.ravel()]
        r = minimize(obj, np.r_[c0, np.zeros(K * P)], jac=True, method="L-BFGS-B", options={"maxiter": 500})
        return r.x

    def pred(th, Fx, Zx):
        c, B = unpack(th)
        eta = c[None, :] + Zx @ B.T
        eta -= eta.max(axis=1, keepdims=True)
        W = np.exp(eta); W /= W.sum(axis=1, keepdims=True)
        return (W * Fx).sum(axis=1), W

    inner = np.unique(ctx["folds"], return_inverse=True)[1] % 4
    cv = {lam: np.mean([risk(kind)(y[inner == f], pred(fit(F[inner != f], Zf[inner != f], y[inner != f], lam),
                                                     F[inner == f], Zf[inner == f])[0]) for f in range(4)]) for lam in lams}
    lam = min(cv, key=cv.get)
    th = fit(F, Zf, y, lam)
    a = np.zeros(Z.shape[1]); a[keep] = pred(th, F, Zf)[1].mean(axis=0)   # average weights, for display
    return a, (lambda Zt, ct: pred(th, Zt[:, keep], zmat(Zt, ct["age"]))[0])


METAS = {"NNLS": meta_nnls, "Logit convex (CC_nloglik)": meta_cc_nloglik,
         "Ensemble selection (Caruana)": meta_caruana, "Input-dependent weights": meta_input_dependent}


# ---- 3. the discrete Super Learner over learners and ensembles ----------------------------------------------------
def run(sid):
    t0 = time.time()
    L = build_library(sid)
    n_main = len(L["names"])
    if CONFIGS or (OUT / f"{sid}_library_configs.npz").exists():
        L2 = build_library(sid, "configs")
        L["names"] += L2["names"]; L["secs"] |= L2["secs"]
        L["Z"], L["Zt"] = np.column_stack([L["Z"], L2["Z"]]), np.column_stack([L["Zt"], L2["Zt"]])
    S, kind, names, Z, Zt, ytr, yte = L["S"], L["kind"], L["names"], L["Z"], L["Zt"], L["ytr"], L["yte"]
    tr, te, folds = L["tr"], L["te"], L["folds"]
    ctx_tr, ctx_te = {"age": tr.age.values.astype(float), "folds": folds}, {"age": te.age.values.astype(float)}
    lossf = risk(kind)
    n13 = [n for n in names if n in M.LEARNERS]
    libs = {"ch13 library": [names.index(n) for n in n13], "Full library": list(range(n_main)),
            "Full library without TabPFN": [i for i in range(n_main) if names[i] != "TabPFN v2"],
            "Full library + 16 configurations": list(range(len(names)))}
    cands = {}
    for lname, idx in libs.items():
        if (lname == "Full library without TabPFN" and len(idx) == n_main) or (lname.startswith("Full library +") and len(idx) == n_main):
            continue
        for mname, mf in METAS.items():
            if mname.startswith("Logit") and kind == "reg":
                continue
            if lname == "ch13 library" and mname != "NNLS":
                continue
            if lname == "Full library without TabPFN" and mname != "NNLS":
                continue
            if lname.startswith("Full library +") and mname not in ("NNLS", "Ensemble selection (Caruana)"):
                continue
            cands[f"{mname}, {lname[0].lower() + lname[1:]}"] = (idx, mf)

    # level-2 cross-validation: each ensemble's meta-learner refitted without fold f, scored on fold f
    cvp = {}
    for c, (idx, mf) in cands.items():
        p = np.zeros(len(ytr))
        for f in range(1, 6):
            a_, b_ = folds != f, folds == f
            _, pf = mf(Z[a_][:, idx], ytr[a_], kind, {k: v[a_] for k, v in ctx_tr.items()})
            p[b_] = pf(Z[b_][:, idx], {k: v[b_] for k, v in ctx_tr.items()})
        cvp[c] = p
    cv_risk = {n: lossf(ytr, clip(Z[:, i]) if kind == "clf" else Z[:, i]) for i, n in enumerate(names)} | \
              {c: lossf(ytr, p) for c, p in cvp.items()}
    chosen = min(cv_risk, key=cv_risk.get)

    fits, test_pred = {}, {n: Zt[:, i] for i, n in enumerate(names)}
    for c, (idx, mf) in cands.items():
        a, pf = mf(Z[:, idx], ytr, kind, ctx_tr)
        fits[c] = pd.Series(a, index=[names[i] for i in idx])
        test_pred[c] = pf(Zt[:, idx], ctx_te)
    test_pred["Updated Super Learner"] = test_pred[chosen]

    # chapter 13's stack and OLS / logistic (refitted on all training data, as in chapter 13)
    p13 = pd.read_csv(M.OUT / f"{sid}_test_predictions.csv")
    assert np.allclose(p13.y.values, yte), "test rows differ from chapter 13"
    base_name = "Logistic" if kind == "clf" else "OLS"
    test_pred["Chapter 13 stack"] = p13["Stack"].values
    test_pred[f"{base_name} (chapter 13)"] = p13[base_name].values

    mname, mfun = M.headline(kind)
    keys = list(test_pred)
    P = np.column_stack([test_pred[k] for k in keys])
    w, hh = te.weight.values, te.household.values
    boot = M.hh_boot(yte, P, w, hh, mfun)
    j13, jb = keys.index("Chapter 13 stack"), keys.index(f"{base_name} (chapter 13)")
    rows = []
    for j, k in enumerate(keys):
        rows.append({"scenario": sid, "candidate": k, "cv_risk": cv_risk.get(k, cv_risk.get(chosen) if k == "Updated Super Learner" else np.nan),
                     f"test_{mname}": mfun(yte, P[:, j], w), "lo": np.percentile(boot[:, j], 2.5), "hi": np.percentile(boot[:, j], 97.5),
                     "test_loss": M.wmean((yte - P[:, j]) ** 2, w) if kind == "reg" else logloss(yte, P[:, j], w),
                     "diff_vs_ch13_stack": mfun(yte, P[:, j], w) - mfun(yte, P[:, j13], w),
                     "d13_lo": np.percentile(boot[:, j] - boot[:, j13], 2.5), "d13_hi": np.percentile(boot[:, j] - boot[:, j13], 97.5),
                     "diff_vs_baseline": mfun(yte, P[:, j], w) - mfun(yte, P[:, jb], w),
                     "db_lo": np.percentile(boot[:, j] - boot[:, jb], 2.5), "db_hi": np.percentile(boot[:, j] - boot[:, jb], 97.5),
                     "seconds": L["secs"].get(k, np.nan), "chosen": k == chosen})
    res = pd.DataFrame(rows)
    res.to_csv(OUT / f"{sid}_results.csv", index=False)
    wt = pd.DataFrame(fits).fillna(0)
    wt.to_csv(OUT / f"{sid}_weights.csv")
    show = ["candidate", "cv_risk", f"test_{mname}", "lo", "hi", "diff_vs_ch13_stack", "d13_lo", "d13_hi"]
    print(res[show].round(4).to_string(index=False))
    print(f"  chosen by cross-validated risk: {chosen}")
    print(wt.round(3).to_string())
    plot(sid, S, res, wt, chosen, mname, kind)
    print(f"  {sid} done in {(time.time() - t0) / 60:.1f} min", flush=True)
    return res


def plot(sid, S, res, wt, chosen, mname, kind):
    r = res.copy()
    base = r.candidate.str.contains("chapter 13")
    ens = r.candidate.str.contains("library") | (r.candidate == "Updated Super Learner") | (r.candidate == "Chapter 13 stack")
    best_single = r[~ens & ~base].sort_values("cv_risk").head(4)
    r = pd.concat([r[base], best_single, r[ens]]).drop_duplicates("candidate").iloc[::-1].reset_index(drop=True)
    fig, ax = plt.subplots(figsize=(7.4, 0.36 * len(r) + 1.6))
    yy = np.arange(len(r))
    col = np.where(r.candidate == "Updated Super Learner", M.ORANGE, np.where(r.candidate == "Chapter 13 stack", M.AQUA, M.BLUE))
    ax.hlines(yy, r.lo, r.hi, color=col, lw=2)
    ax.scatter(r[f"test_{mname}"], yy, color=col, s=36, zorder=3)
    lab = [f"{c}  [chosen: {chosen}]" if c == "Updated Super Learner" else c for c in r.candidate]
    ax.set_yticks(yy, lab, fontsize=8)
    ax.grid(axis="y", visible=False)
    ax.set_xlabel(f"Test-data {mname}, survey-weighted (95% household-bootstrap interval)")
    ax.set_title(f"{S['title']}\nThe updated Super Learner, its candidates, chapter 13's stack (aqua) and the "
                 f"best single learners by CV risk", loc="left", fontsize=9)
    fig.tight_layout()
    save(fig, f"fig14_{sid}_candidates.png", public=True)
    # weights of the full-library ensembles
    w = wt[[c for c in wt.columns if "full library" in c and "without" not in c]]
    w.columns = [c.replace("16 configurations", "configs") for c in w.columns]
    w = w.loc[(w > 0.005).any(axis=1)]
    fig, ax = plt.subplots(figsize=(7.4, 0.32 * len(w) + 1.6))
    im = ax.imshow(w.values, cmap="Blues", vmin=0, vmax=max(0.5, w.values.max()), aspect="auto")
    ax.set_xticks(range(w.shape[1]), [c.replace(", full library", "") for c in w.columns], rotation=25, ha="right", fontsize=7.5)
    ax.set_yticks(range(w.shape[0]), w.index, fontsize=8)
    ax.grid(False)
    for i in range(w.shape[0]):
        for j in range(w.shape[1]):
            if w.values[i, j] > 0.005:
                ax.text(j, i, f"{w.values[i, j]:.2f}", ha="center", va="center", fontsize=7.5,
                        color="white" if w.values[i, j] > 0.3 else M.INK)
    ax.set_title(f"{S['title']}\nWeights of the full-library ensembles (input-dependent: average weight)",
                 loc="left", fontsize=9)
    fig.tight_layout()
    save(fig, f"fig14_{sid}_weights.png", public=True)


def summary():
    fs = sorted(OUT.glob("S*_results.csv"))
    if not fs:
        return
    r = pd.concat([pd.read_csv(f) for f in fs])
    order = [s for s in ["S1", "S2", "S3", "S3b", "S4"] if s in set(r.scenario)]
    show = ["Updated Super Learner", "Ensemble selection (Caruana), full library + 16 configurations",
            "NNLS, full library + 16 configurations", "NNLS, full library", "Ensemble selection (Caruana), full library",
            "Input-dependent weights, full library", "Logit convex (CC_nloglik), full library",
            "NNLS, full library without TabPFN", "NNLS, ch13 library"]
    names = {"S1": "S1 log spending (R2)", "S2": "S2 top 10% (AUC)", "S3": "S3 log nights per stay (R2)",
             "S3b": "S3b week or more (AUC)", "S4": "S4 high use (AUC)"}
    fig, axs = plt.subplots(1, len(order), figsize=(3.0 * len(order) + 1.5, 4.2), sharey=True)
    axs = np.atleast_1d(axs)
    yy = np.arange(len(show))[::-1]
    for ax, s in zip(axs, order):
        d = r[r.scenario == s].set_index("candidate").reindex(show)
        ax.axvline(0, color=M.INK, lw=1)
        col = [M.ORANGE] + [M.BLUE] * (len(show) - 1)
        ax.hlines(yy, d.d13_lo, d.d13_hi, color=col, lw=1.8)
        ax.scatter(d.diff_vs_ch13_stack, yy, color=col, s=26, zorder=3)
        ax.set_title(names[s], loc="left", fontsize=8.5)
        ax.set_xlabel("Gain over chapter 13's stack")
        ax.grid(axis="y", visible=False)
    axs[0].set_yticks(yy, show, fontsize=8)
    fig.suptitle("The updated Super Learner and its ensembles against chapter 13's stack (test data, survey-weighted; "
                 "household-bootstrap 95% intervals)", x=0.01, ha="left", fontsize=10, color=M.INK)
    fig.tight_layout()
    save(fig, "fig14_summary.png", public=True)
    r.to_csv(OUT / "all_results.csv", index=False)


if __name__ == "__main__":
    todo = [a for a in sys.argv[1:] if not a.startswith("--")] or ["S3", "S3b", "S1", "S2", "S4"]
    for s in todo:
        run(s)
    summary()
