"""ml_05_svm.py -- Support vector machines (ISLR/ISLP ch. 9; ESL ch. 12). Python version of
ml/R/ml_05_svm.R (scikit-learn): linear and radial-kernel SVMs for the binary outcomes, with
Platt-scaled probabilities, and support vector regression for log spending. C and gamma are
chosen on the household folds from the same small grid as R.
Output: output/ml/results_python.csv (chapter "05 SVM").

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.model_selection import GridSearchCV, PredefinedSplit
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC, SVR

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "05 SVM"
sc = StandardScaler().fit(x_matrix(train))
Ztr, Zte = sc.transform(x_matrix(train)), sc.transform(x_matrix(test))
p_ = Ztr.shape[1]
cv = PredefinedSplit(train.fold.values - 1)
res = []
for y in ["high_cost", "any_er"]:
    for k, grid in [("linear", {"C": [0.01, 0.1, 1]}),
                    ("rbf", {"C": [0.3, 1, 3], "gamma": [0.3 / p_, 1 / p_, 3 / p_]})]:
        m = GridSearchCV(SVC(kernel=k, probability=True, random_state=1), grid, cv=cv, scoring="neg_brier_score", n_jobs=2)
        m.fit(Ztr, train[y])
        res.append(evaluate(y, m.predict_proba(Zte)[:, 1], f"SVM, {'radial' if k == 'rbf' else k} kernel", CH))
        print(y, k, m.best_params_)
m = GridSearchCV(SVR(kernel="rbf"), {"C": [0.3, 1, 3], "gamma": [0.3 / p_, 1 / p_, 3 / p_]}, cv=cv,
                 scoring="neg_mean_squared_error", n_jobs=2).fit(Ztr, train.log_cost)
res.append(evaluate("log_cost", m.predict(Zte), "SVR, radial kernel", CH))
res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)
