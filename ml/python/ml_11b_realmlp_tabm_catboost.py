"""ml_11b_realmlp_tabm_catboost.py -- Three more recent strong defaults for tabular data, each run
with its published default settings and no tuning of our own:

- RealMLP (Holzmueller, Grinsztajn and Steinwart 2024): a multilayer perceptron with a set of
  carefully chosen defaults (robust scaling, embeddings for numeric features, a learning-rate
  schedule, and more), pre-tuned on a benchmark of other data sets ("TD" = tuned defaults).
- TabM (Gorishniy, Kotelnikov and Babenko 2025): an MLP that trains an ensemble of 32 networks at
  once, sharing most weights (parameter-efficient ensembling).
- CatBoost (Prokhorenkova et al. 2018): gradient boosting with ordered boosting and symmetric
  trees. Not new, but the strongest boosting library in the TabArena benchmark (Erickson et al.
  2025), and often good without tuning.

RealMLP and TabM come from the pytabkit package (pip install pytabkit), which holds out 20% of the
training rows for early stopping. CatBoost is given 1,000 rounds at its default learning rate
schedule with the same 20% held out for early stopping. We do not hold out whole households here
(pytabkit splits rows); the household folds matter less for early stopping than for model choice,
but it is a small leak worth knowing about.

In R: CatBoost has an R package (installed from its GitHub releases, not CRAN); RealMLP and TabM
are Python only (reticulate can call them).
Output: output/ml/results_python.csv (chapter "11 recent tabular models").

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import time
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from catboost import CatBoostClassifier, CatBoostRegressor
from pytabkit import RealMLP_TD_Classifier, RealMLP_TD_Regressor, TabM_D_Classifier, TabM_D_Regressor

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "11 recent tabular models"
Xtr, Xte = x_matrix(train).values.astype(np.float32), x_matrix(test).values.astype(np.float32)
rng = np.random.default_rng(1)
val = rng.random(len(Xtr)) < 0.2           # CatBoost's early-stopping rows
res = []
for y in ["log_cost", "high_cost", "any_er", "any_ip"]:
    reg = y == "log_cost"
    yv = train[y].values.astype(np.float32 if reg else int)
    models = {
        "RealMLP (pytabkit, tuned defaults)": (RealMLP_TD_Regressor if reg else RealMLP_TD_Classifier)(device="cpu", random_state=1, n_threads=2),
        "TabM (pytabkit, defaults)": (TabM_D_Regressor if reg else TabM_D_Classifier)(device="cpu", random_state=1, n_threads=2),
    }
    for name, m in models.items():
        t = time.time()
        m.fit(Xtr, yv)
        p = m.predict(Xte) if reg else m.predict_proba(Xte)[:, 1]
        res.append(evaluate(y, np.asarray(p).ravel(), name, CH))
        print(f"{y} {name}: {time.time() - t:.0f} s")
    cb = (CatBoostRegressor if reg else CatBoostClassifier)(iterations=1000, random_seed=1, verbose=0, thread_count=2,
                                                         train_dir=str(OUT_DIR / "catboost_info"))
    cb.fit(Xtr[~val], yv[~val], eval_set=(Xtr[val], yv[val]), early_stopping_rounds=100)
    p = cb.predict(Xte) if reg else cb.predict_proba(Xte)[:, 1]
    res.append(evaluate(y, p, "CatBoost (defaults, early stopping)", CH))
res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
