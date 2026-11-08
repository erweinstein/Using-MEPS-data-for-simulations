"""ml_06_neural_nets.py -- Neural networks (ISLR/ISLP ch. 10; ESL ch. 11). Python version of
ml/R/ml_06_neural_nets.R, plus a deeper network in PyTorch.

1. scikit-learn's MLP with one hidden layer and an L2 penalty (alpha, the weight decay), size
   and penalty chosen on the household folds; 5 random starts averaged.
2. A two-hidden-layer network in PyTorch (ReLU, dropout, AdamW, early stopping on a validation
   fold), the kind of model ISLP's deep-learning lab builds, for the binary and log-spending
   outcomes.
Output: output/ml/results_python.csv (chapter "06 neural networks").

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.neural_network import MLPClassifier, MLPRegressor
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "06 neural networks"
sc = StandardScaler().fit(x_matrix(train))
Ztr, Zte = sc.transform(x_matrix(train)), sc.transform(x_matrix(test))
folds = train.fold.values
res = []


def mlp(y, size, alpha, seed):
    kw = dict(hidden_layer_sizes=(size,), alpha=alpha, max_iter=2000, early_stopping=False, random_state=seed)
    return MLPRegressor(**kw) if y == "log_cost" else MLPClassifier(**kw)


def pred(m, Z, y):
    return m.predict(Z) if y == "log_cost" else m.predict_proba(Z)[:, 1]


for y in ["log_cost", "high_cost", "any_er", "any_ip"]:
    best = None
    for size in (3, 8, 16):
        for alpha in (0.1, 1.0, 5.0):
            err = np.mean([np.mean((train[y].values[folds == f] -
                                    np.mean([pred(mlp(y, size, alpha, s).fit(Ztr[folds != f], train[y].values[folds != f]),
                                                  Ztr[folds == f], y) for s in (1, 2)], axis=0)) ** 2) for f in range(1, 6)])
            if best is None or err < best[0]:
                best = (err, size, alpha)
    p = np.mean([pred(mlp(y, best[1], best[2], s).fit(Ztr, train[y]), Zte, y) for s in range(1, 6)], axis=0)
    res.append(evaluate(y, p, "Neural network (1 hidden layer)", CH))
    print(f"{y}: hidden units = {best[1]}, alpha = {best[2]}")

# ---- a deeper network in PyTorch ------------------------------------------------------------------------
try:
    import torch
    from torch import nn

    torch.manual_seed(1)

    def torch_fit(y, binary, epochs=300):
        val = folds == 5                                    # one training fold for early stopping
        Xa, ya = torch.tensor(Ztr[~val], dtype=torch.float32), torch.tensor(train[y].values[~val], dtype=torch.float32)
        Xv, yv = torch.tensor(Ztr[val], dtype=torch.float32), torch.tensor(train[y].values[val], dtype=torch.float32)
        net = nn.Sequential(nn.Linear(Ztr.shape[1], 64), nn.ReLU(), nn.Dropout(0.3),
                            nn.Linear(64, 32), nn.ReLU(), nn.Dropout(0.3), nn.Linear(32, 1))
        opt = torch.optim.AdamW(net.parameters(), lr=1e-3, weight_decay=1e-2)
        loss_fn = nn.BCEWithLogitsLoss() if binary else nn.MSELoss()
        best, state, wait = np.inf, None, 0
        for ep in range(epochs):
            net.train()
            for idx in torch.randperm(len(ya)).split(128):
                opt.zero_grad()
                loss_fn(net(Xa[idx]).squeeze(1), ya[idx]).backward()
                opt.step()
            net.eval()
            with torch.no_grad():
                v = loss_fn(net(Xv).squeeze(1), yv).item()
            if v < best - 1e-5:
                best, state, wait = v, {k: t.clone() for k, t in net.state_dict().items()}, 0
            else:
                wait += 1
                if wait >= 20:
                    break
        net.load_state_dict(state)
        net.eval()
        with torch.no_grad():
            out = net(torch.tensor(Zte, dtype=torch.float32)).squeeze(1)
        return (torch.sigmoid(out) if binary else out).numpy()

    for y in ["log_cost", "high_cost", "any_er", "any_ip"]:
        res.append(evaluate(y, torch_fit(y, y != "log_cost"), "Deep network (PyTorch, 2 hidden layers)", CH))
except ImportError:
    print("PyTorch is not installed; skipping the deeper network.")

res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
