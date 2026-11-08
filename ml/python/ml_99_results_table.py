"""ml_99_results_table.py -- One table of test-set results from both languages, for ML_WALKTHROUGH.md
section 5. Reads output/ml/results_R.csv and output/ml/results_python.csv and writes
output/ml/results_table.md (R^2 for log_cost, cost and ob_visits; AUC for the binary outcomes).
A cell shows one number when R and Python agree to 3 decimals, "R / Python" when they differ, and the
number with "(R)" or "(Py)" when only one language fitted that model.

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
from pathlib import Path

import pandas as pd

OUT = Path("output/ml")
METRIC = {"log_cost": "R2", "cost": "R2", "ob_visits": "R2", "high_cost": "AUC", "any_er": "AUC", "any_ip": "AUC"}
HEAD = {"log_cost": "log spending (R²)", "cost": "spending (R²)", "ob_visits": "office visits (R²)",
        "high_cost": "top 10% (AUC)", "any_er": "any ER (AUC)", "any_ip": "any stay (AUC)"}


def load(lang):
    d = pd.read_csv(OUT / f"results_{lang}.csv")
    d = d[d.apply(lambda r: METRIC.get(r.outcome) == r.metric, axis=1)]
    d = d[~d.model.str.strip().str.startswith(("learner:", "Discrete"))]
    d["model"] = d.model.str.strip()
    return d.set_index(["chapter", "model", "outcome"]).value


r, p = load("R"), load("python")
keys = pd.Index(r.index.tolist() + [k for k in p.index if k not in r.index])
rows = {}
for ch, mod, y in keys:
    a, b = r.get((ch, mod, y)), p.get((ch, mod, y))
    if a is not None and b is not None:
        cell = f"{a:.3f}" if round(a, 3) == round(b, 3) else f"{a:.3f} / {b:.3f}"
    else:
        cell = f"{a:.3f} (R)" if a is not None else f"{b:.3f} (Py)"
    rows.setdefault((ch, mod), {})[y] = cell
order = sorted(rows, key=lambda k: (k[0], list(rows).index(k)))
lines = ["| Chapter | Model | " + " | ".join(HEAD.values()) + " |", "|---" * (2 + len(HEAD)) + "|"]
for ch, mod in order:
    lines.append(f"| {ch} | {mod} | " + " | ".join(rows[(ch, mod)].get(y, "–") for y in HEAD) + " |")
(OUT / "results_table.md").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
