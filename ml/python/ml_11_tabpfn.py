"""ml_11_tabpfn.py -- A tabular foundation model: TabPFN (Hollmann et al. 2023, 2025).

TabPFN is a transformer pre-trained on millions of synthetic tabular data sets. It does not fit
parameters to your data: given the training rows as context, it predicts the test rows in one forward
pass ("in-context learning"), with no tuning. Version 2 (Hollmann et al., Nature, 2025) handles up to
10,000 training rows and 500 features, and its weights are under the Prior Labs License (Apache 2.0
with an attribution requirement). Later versions (2.5, Nov. 2025; 2.6, Apr. 2026; 3, May 2026; 3.5,
Sep. 2026) handle far larger data, but their weights are released for non-commercial use only and
need license acceptance at priorlabs.ai (docs.priorlabs.ai/models, checked Nov. 2026).
This script uses the openly downloadable v2 weights (fetched from Hugging Face on first use) on a CPU;
a GPU makes it much faster (on a CPU, TabPFN refuses more than 1,000 training rows unless told
otherwise, so the script sets ignore_pretraining_limits=True; expect minutes per outcome). From R,
the same model can be called through reticulate (see the walkthrough).

Outcomes: log_cost (regression) and the three binary outcomes (classification). TabPFN is given the
raw predictors (no log transforms or standardization needed, but we give it the same columns as the
other models).
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

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
from tabpfn import TabPFNClassifier, TabPFNRegressor  # noqa: E402
from tabpfn.constants import ModelVersion  # noqa: E402

CH = "11 recent tabular models"
Xtr, Xte = x_matrix(train).values.astype(np.float32), x_matrix(test).values.astype(np.float32)
res = []
for y in ["log_cost", "high_cost", "any_er", "any_ip"]:
    t = time.time()
    if y == "log_cost":
        m = TabPFNRegressor.create_default_for_version(ModelVersion.V2, device="cpu", random_state=1,
                                                              ignore_pretraining_limits=True)
        p = m.fit(Xtr, train[y].values).predict(Xte)
    else:
        m = TabPFNClassifier.create_default_for_version(ModelVersion.V2, device="cpu", random_state=1,
                                                              ignore_pretraining_limits=True)
        p = m.fit(Xtr, train[y].values.astype(int)).predict_proba(Xte)[:, 1]
    res.append(evaluate(y, p, "TabPFN v2 (no tuning)", CH))
    print(f"{y}: {time.time() - t:.0f} s")
res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
