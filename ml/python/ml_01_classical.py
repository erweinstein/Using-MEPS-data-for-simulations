"""ml_01_classical.py -- Baselines and classical regression models (ISLR/ISLP ch. 3-4; ESL ch. 3-4),
and the health-economics standards for spending (log OLS with smearing, the two-part model, GLMs
with a log link). Python version of ml/R/ml_01_classical.R (statsmodels).

Output: output/ml/results_python.csv (chapter "01 classical").

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import statsmodels.api as sm

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "01 classical"
Xtr = sm.add_constant(x_matrix(train, drop_reference=True))
Xte = sm.add_constant(x_matrix(test, drop_reference=True))
res = []

for y in OUTCOMES:
    res.append(evaluate(y, np.full(len(test), wmean(train[y], train.weight)), "Mean only", CH))

ols = sm.OLS(train.cost, Xtr).fit()
res.append(evaluate("cost", ols.predict(Xte), "Linear regression", CH))

lols = sm.OLS(train.log_cost, Xtr).fit()
smear = np.mean(np.exp(lols.resid))
res.append(evaluate("log_cost", lols.predict(Xte), "Linear regression", CH))
res.append(evaluate("cost", np.exp(lols.predict(Xte)) * smear - 1, "Log OLS + smearing", CH))
print(f"Smearing factor: {smear:.1f}")

pos = train.cost > 0
tp1 = sm.GLM((train.cost > 0).astype(float), Xtr, family=sm.families.Binomial()).fit()
# With heavy-tailed spending, plain IRLS can overshoot and oscillate (it stops at a worse fit,
# deviance 7,136 here); Newton's method from the log-OLS start reaches the minimum (7,043.6).
st = sm.OLS(np.log(train.cost[pos]), Xtr[pos]).fit().params
tp2 = sm.GLM(train.cost[pos], Xtr[pos], family=sm.families.Gamma(sm.families.links.Log())).fit(
    start_params=st, method="newton", maxiter=1000)
res.append(evaluate("cost", tp1.predict(Xte) * tp2.predict(Xte), "Two-part (logit x gamma GLM)", CH))
qp = sm.GLM(train.cost, Xtr, family=sm.families.Poisson()).fit(maxiter=200, scale="X2")
res.append(evaluate("cost", qp.predict(Xte), "GLM, log link (quasi-Poisson)", CH))

for y in ["high_cost", "any_er", "any_ip"]:
    m = sm.GLM(train[y], Xtr, family=sm.families.Binomial()).fit()
    res.append(evaluate(y, m.predict(Xte), "Logistic regression", CH))

pm = sm.GLM(train.ob_visits, Xtr, family=sm.families.Poisson()).fit()
nb = sm.NegativeBinomial(train.ob_visits, Xtr).fit(disp=0, maxiter=500)
res.append(evaluate("ob_visits", pm.predict(Xte), "Poisson GLM", CH))
res.append(evaluate("ob_visits", nb.predict(Xte), "Negative binomial GLM", CH))

res = pd.concat(res, ignore_index=True)
log_results(res)
show(res)

wn = train.weight / train.weight.mean()
cmp = pd.concat([
    evaluate("high_cost", sm.GLM(train.high_cost, Xtr, family=sm.families.Binomial()).fit().predict(Xte), "Logistic, unweighted fit", CH),
    evaluate("high_cost", sm.GLM(train.high_cost, Xtr, family=sm.families.Binomial(), freq_weights=wn).fit().predict(Xte),
             "Logistic, weighted fit", CH),
    evaluate("log_cost", lols.predict(Xte), "Log OLS, unweighted fit", CH),
    evaluate("log_cost", sm.WLS(train.log_cost, Xtr, weights=wn).fit().predict(Xte), "Log OLS, weighted fit", CH)])
print("\nFitting with and without the survey weights (both evaluated with them):")
show(cmp)
