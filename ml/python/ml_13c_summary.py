"""ml_13c_summary.py -- One picture and one table across chapter 13's scenarios: how much each learner
gained (or lost) over the plain regression (OLS or logistic), on the test data, with household-
bootstrap 95% intervals. Reads output/ml/ch13/all_metrics.csv (Python) and, if present,
all_metrics_R.csv (R); writes docs/ml/fig13_summary.png and output/ml/ch13/summary_table.md.

Usage:  python ml/python/ml_13c_summary.py

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

OUT, DOCS = Path("output/ml/ch13"), Path("docs/ml")
BLUE, ORANGE, INK, MUTED, GRAY = "#2a78d6", "#eb6834", "#2b2b29", "#6b6a64", "#b4b2a9"
plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False, "axes.edgecolor": MUTED,
                     "xtick.color": MUTED, "ytick.color": MUTED, "axes.titlesize": 9, "axes.titlecolor": INK,
                     "axes.grid": True, "grid.color": "#e6e5e0", "grid.linewidth": 0.6, "savefig.dpi": 200})
NAMES = {"S1": "S1 log spending (R2)", "S2": "S2 top 10% spender (AUC)", "S3": "S3 log nights per stay (R2)",
         "S3b": "S3b stay of a week or more (AUC)", "S4": "S4 high use of care (AUC)"}

py = pd.read_csv(OUT / "all_metrics.csv")
py["language"] = "Python"
frames = [py]
if (OUT / "all_metrics_R.csv").exists():
    r = pd.read_csv(OUT / "all_metrics_R.csv")
    r["language"] = "R"
    frames.append(r)
m = pd.concat(frames, ignore_index=True)
m["metric"] = np.where(m.filter(like="test_R2").notna().any(axis=1), "R2", "AUC")
m["test"] = m.get("test_R2").fillna(m.get("test_AUC")) if "test_AUC" in m else m.test_R2
m["learner"] = m.learner.replace({"Logistic": "OLS / logistic", "OLS": "OLS / logistic"})
order = ["OLS / logistic", "Lasso", "Ridge", "Elastic net", "KNN", "Tree (CART)", "Random forest", "XGBoost", "SVM",
         "Neural net", "Stack"]
scen = [s for s in NAMES if s in set(m.scenario)]

fig, axs = plt.subplots(1, len(scen), figsize=(3.1 * len(scen), 4.6), sharey=True)
axs = np.atleast_1d(axs)
yy = np.arange(len(order))[::-1]
for ax, s in zip(axs, scen):
    ax.axvline(0, color=INK, lw=1)
    for lang, c, off in [("Python", BLUE, 0.15), ("R", ORANGE, -0.15)]:
        d = m[(m.scenario == s) & (m.language == lang)].set_index("learner").reindex(order)
        if d.test.isna().all():
            continue
        ax.hlines(yy + off, d.diff_lo, d.diff_hi, color=c, lw=1.6)
        ax.plot(d.diff_vs_baseline, yy + off, "o", color=c, ms=4.5, label=lang)
    ax.set_title(NAMES[s], loc="left")
    ax.set_xlabel("Test-data gain over OLS / logistic")
    ax.grid(axis="y", visible=False)
axs[0].set_yticks(yy, order)
axs[0].legend(frameon=False, loc="lower left", fontsize=8)
fig.suptitle("Ten learners and their stack against the plain regression, five MEPS problems "
             "(survey-weighted; lines: household-bootstrap 95% intervals)", x=0.01, ha="left", fontsize=10.5, color=INK)
fig.tight_layout()
DOCS.mkdir(parents=True, exist_ok=True)
fig.savefig(DOCS / "fig13_summary.png", bbox_inches="tight")
fig.savefig(OUT / "fig13_summary.png", bbox_inches="tight")

rows = []
for lr in order:
    row = [lr]
    for s in scen:
        cell = []
        for lang in ["R", "Python"]:
            d = m[(m.scenario == s) & (m.language == lang) & (m.learner == lr)]
            cell.append(f"{d.test.iloc[0]:.3f}" if len(d) else "–")
        row.append(" / ".join(cell))
    rows.append(row)
hdr = "| Learner | " + " | ".join(NAMES[s] for s in scen) + " |\n|---|" + "---|" * len(scen) + "\n"
tab = hdr + "\n".join("| " + " | ".join(r) + " |" for r in rows) + "\n"
w = []
for s in scen:
    d = m[(m.scenario == s) & (m.language == "Python") & (m.learner != "Stack")]
    w.append(f"{s}: " + ", ".join(f"{a} {b:.2f}" for a, b in zip(d.learner, d.stack_weight) if b > 0.005))
(OUT / "summary_table.md").write_text("Test-data metric, R / Python\n\n" + tab + "\nStacking weights (Python):\n\n" +
                                      "\n".join("- " + x for x in w) + "\n")
print(tab)
print("\n".join(w))
