"""ml_09_interpretation.py -- Interpreting a black-box model (Molnar, Interpretable Machine Learning,
3rd ed.): permutation importance, partial dependence and ICE curves, accumulated local effects (ALE)
and SHAP values, for chapter 4's xgboost model of being a top-10% spender in 2023
(output/ml/xgb_high_cost_py.json). Python version of ml/R/ml_09_interpretation.R (scikit-learn's
inspection tools for the idea, hand-written versions for weighted test-set summaries, and the shap
package for SHAP values).
Output: output/ml/importance_python.csv, output/ml/shap_summary_python.csv, figures in
output/ml/fig_*_python.png.

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import shap  # noqa: E402
import xgboost as xgb  # noqa: E402

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
rng = np.random.default_rng(1)
Xte = x_matrix(test)
b = xgb.Booster()
b.load_model(str(OUT_DIR / "xgb_high_cost_py.json"))
pred = lambda X: b.predict(xgb.DMatrix(X))  # noqa: E731
w, yv = test.weight.values, test.high_cost.values

# permutation importance (dummies of one categorical predictor shuffled together)
groups = {v: [c for c in Xte.columns if c.startswith(v)] if v in CAT_VARS else [v] for v in PREDICTORS_LOG}
base = w_auc(yv, pred(Xte), w)
imp = {}
for v, cols in groups.items():
    losses = []
    for _ in range(10):
        X = Xte.copy()
        X[cols] = X[cols].values[rng.permutation(len(X))]
        losses.append(base - w_auc(yv, pred(X), w))
    imp[v] = np.mean(losses)
imp = pd.Series(imp).sort_values(ascending=False)
imp.rename("auc_loss").rename_axis("predictor").to_csv(OUT_DIR / "importance_python.csv")
print(f"Test AUC {base:.4f}; loss in AUC when each predictor is shuffled (top 10):\n{imp.head(10).round(4).to_string()}")


def ale(v, K=20):
    """First-order ALE (Apley and Zhu 2020), weighted."""
    x = Xte[v].values
    z = np.unique(np.quantile(x, np.linspace(0, 1, K + 1), method="inverted_cdf"))
    k = np.clip(np.searchsorted(z, x, side="left"), 1, len(z) - 1)
    lo, hi = Xte.copy(), Xte.copy()
    lo[v], hi[v] = z[k - 1], z[k]
    d = pred(hi) - pred(lo)
    m = np.array([np.sum(d[k == j] * w[k == j]) / np.sum(w[k == j]) if np.any(k == j) else 0 for j in range(1, len(z))])
    eff = np.concatenate([[0], np.cumsum(m)])
    wj = np.array([np.sum(w[k == j]) for j in range(1, len(z))])
    return z, eff - np.sum(eff[1:] * wj) / np.sum(wj)


VARS = {"log_cost_2022": "2022 spending (log of 1 + $)", "age": "Age in 2022", "pcs": "Physical component score (VR-12)"}
fig, axes = plt.subplots(1, 3, figsize=(12, 4))
mean_pred = np.sum(pred(Xte) * w) / np.sum(w)
for ax, (v, lab) in zip(axes, VARS.items()):
    grid = np.quantile(Xte[v], np.linspace(0.02, 0.98, 25))
    ice = np.column_stack([pred(Xte.assign(**{v: g})) for g in grid])
    for i in rng.choice(len(Xte), 200, replace=False):
        ax.plot(grid, ice[i], color="0.7", lw=0.3, alpha=0.6)
    ax.plot(grid, (ice * w[:, None]).sum(0) / w.sum(), color="#1f4e79", lw=2, label="Partial dependence")
    z, eff = ale(v)
    ax.plot(z, eff + mean_pred, color="#c55a11", lw=1.8, ls="--", label="ALE")
    ax.set_xlabel(lab)
    ax.set_ylabel("P(top 10% in 2023)")
axes[0].legend(fontsize=8)
fig.suptitle("How the boosted model's predicted risk depends on three predictors (grey: ICE curves for 200 adults)", fontsize=10)
fig.tight_layout()
fig.savefig(OUT_DIR / "fig_pdp_ice_ale_python.png", dpi=200)

# SHAP (exact TreeSHAP, log-odds scale)
ex = shap.TreeExplainer(b)
sv = ex.shap_values(Xte)
grp = pd.DataFrame({v: sv[:, [Xte.columns.get_loc(c) for c in cols]].sum(1) for v, cols in groups.items()})
mean_abs = (grp.abs().mul(w, axis=0).sum() / w.sum()).sort_values(ascending=False)
mean_abs.rename("mean_abs_shap").rename_axis("predictor").to_csv(OUT_DIR / "shap_summary_python.csv")
print(f"\nMean |SHAP| (log-odds), top 10:\n{mean_abs.head(10).round(3).to_string()}")
plt.figure()
shap.summary_plot(sv, Xte, max_display=10, show=False)
plt.title("SHAP summary: boosted model for top-10% spending in 2023 (test set)", fontsize=10)
plt.tight_layout()
plt.savefig(OUT_DIR / "fig_shap_python.png", dpi=200)
