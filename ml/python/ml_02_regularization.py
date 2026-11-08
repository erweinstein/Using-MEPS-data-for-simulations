"""ml_02_regularization.py -- Ridge, lasso and the elastic net (ISLR/ISLP ch. 6; ESL sec. 3.4, 4.4.4,
18.4), with the penalty chosen by 5-fold cross-validation over households (the same folds as R).
Python version of ml/R/ml_02_regularization.R (scikit-learn).

scikit-learn does not standardize for you; glmnet does. We standardize with the training means
and SDs so the penalty treats every predictor alike. scikit-learn's Gaussian elastic net has the
same objective as glmnet's (alpha here = glmnet's lambda; l1_ratio = glmnet's alpha); for
logistic regression scikit-learn uses C = 1 / (n x lambda), and its Poisson regression has a ridge
penalty only.
Output: output/ml/results_python.csv (chapter "02 regularization").

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.linear_model import ElasticNetCV, LogisticRegressionCV, PoissonRegressor
from sklearn.model_selection import GridSearchCV, PredefinedSplit
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "02 regularization"
sc = StandardScaler().fit(x_matrix(train))
Xtr, Xte = sc.transform(x_matrix(train)), sc.transform(x_matrix(test))
cv = PredefinedSplit(train.fold.values - 1)          # the household folds stored in the data
NAMES = {0.0: "Ridge", 0.5: "Elastic net (alpha = 0.5)", 1.0: "Lasso"}
res = []

for y in ["cost", "log_cost"]:
    for a in (0.0, 0.5, 1.0):
        if a == 0.0:   # ElasticNetCV cannot fit l1_ratio = 0; use a grid search over ridge penalties
            from sklearn.linear_model import Ridge
            m = GridSearchCV(Ridge(), {"alpha": np.logspace(-2, 5, 40)}, cv=cv, scoring="neg_mean_squared_error").fit(Xtr, train[y])
        else:
            m = ElasticNetCV(l1_ratio=a, alphas=100, cv=cv, max_iter=20000).fit(Xtr, train[y])
        res.append(evaluate(y, m.predict(Xte), NAMES[a], CH))
        if a == 1.0:
            print(f"{y}: lasso keeps {np.sum(m.coef_ != 0)} of {Xtr.shape[1]} columns")

for y in ["high_cost", "any_er", "any_ip"]:
    for a in (0.0, 0.5, 1.0):
        m = LogisticRegressionCV(Cs=np.logspace(-4, 2, 30), cv=cv, penalty="elasticnet", solver="saga",
                                 l1_ratios=[a], scoring="neg_log_loss", max_iter=5000).fit(Xtr, train[y])
        res.append(evaluate(y, m.predict_proba(Xte)[:, 1], NAMES[a], CH))
        if a == 1.0:
            print(f"{y}: lasso keeps {np.sum(m.coef_ != 0)} of {Xtr.shape[1]} columns")

m = GridSearchCV(PoissonRegressor(max_iter=3000), {"alpha": np.logspace(-4, 1, 30)}, cv=cv,
                 scoring="neg_mean_poisson_deviance").fit(Xtr, train.ob_visits)
res.append(evaluate("ob_visits", m.predict(Xte), "Ridge", CH))

res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
