* ml_13_pystacked.do -- Chapter 13's length-of-stay comparison (scenarios S3 and S3b) in Stata
* with pystacked (Ahrens, Hansen and Schaffer 2023, Stata Journal 23(4): 909-931), the command used
* for the in-sample / out-of-sample grids and variable importance in the capstone this chapter
* follows. It uses the same stays, the same household test set and the same five folds as
* ml/python/ml_13_model_comparison.py and ml/R/ml_13_model_comparison.R.
*
* NOT RUN HERE: written against pystacked's help file (version 0.4.8; statalasso.github.io/docs/
* pystacked/help) but not executed (no Stata in the environment where the chapter was built).
* Check it before relying on it; the R and Python scripts are the tested versions.
*
* Needs: Stata 16 or later with Python integration (scikit-learn >= 0.24),
*        ssc install pystacked
*        data/meps_stays.csv from ml/python/ml_13a_stays_extract.py or ml/R/ml_13a_stays_extract.R
* Unlike the R and Python scripts, pystacked's graphs and tables are not survey-weighted.
*
* Eliot R. Weinstein
* eliotw@uchicago.edu
* erweinstein.com

version 16
clear all
set more off
import delimited using "data/meps_stays.csv", clear varnames(1) case(preserve)

* categorical predictors -> 0/1 columns (one level left out of each)
foreach v in race_eth region marital education poverty insurance reason {
    tabulate `v', generate(`v'_)
    drop `v'_1
}
global X age female medicare medicaid usual_source health mental_health high_bp coronary angina ///
    heart_attack other_heart stroke emphysema high_chol cancer diabetes arthritis asthma adl_help  ///
    iadl_help walk_limit pcs mcs k6 year admit_month via_er specific_condition any_operation      ///
    n_conditions dx_* *_miss race_eth_* region_* marital_* education_* poverty_* insurance_* reason_*

* training data: test == 0; folds 1-5 come with the data (households kept together)
gen byte train = (test == 0)

* ---- S3: log nights per stay, ten learners and the stack ------------------------------------------------
* pystacked has no KNN or single-tree learner; it has two lasso variants and a linear SVM instead.
* The nine here plus the stack match the capstone's layout (3 x 4 grid with the weights in the titles).
pystacked log_nights $X if train, type(regress) foldvar(fold) finalest(nnls1) njobs(-1) pyseed(1) ///
    methods(ols lassoic lassocv ridgecv elasticcv linsvm svm rf gradboost nnet)                    ///
    cmdopt8(n_estimators(400) min_samples_leaf(5) max_features(0.4))                               ///
    cmdopt9(n_estimators(500) max_depth(4) learning_rate(0.03) subsample(0.8))                     ///
    cmdopt10(hidden_layer_sizes(32 16) alpha(1) early_stopping)                                    ///
    pipe6(stdscaler) pipe7(stdscaler) pipe10(stdscaler)
matrix list e(weights)                          // the stacking weights (non-negative, sum to one)

pystacked, table holdout                        // in-sample (training) and out-of-sample (test) MSPE
pystacked, graph holdout                        // out-of-sample: predicted vs observed, one panel per learner
pystacked, graph                                // in-sample
graph export "output/ml/ch13/fig13_S3_stata_graphs.png", replace   // shows individuals: keep in output/

predict double yhat_stack if !train             // stacked predictions on the test set
predict double yhat_ if !train, basexb          // each learner's
foreach v of varlist yhat_stack yhat_* {
    quietly correlate log_nights `v' if !train
    display "`v'" _col(20) "test R2 (squared correlation, unweighted) = " %5.3f r(rho)^2
}

* ---- variable importance for the boosted trees (as on the capstone's last page) -----------------------
* pystacked does not report importance; refit scikit-learn's gradient boosting through Python.
python:
import pandas as pd
from sfi import Data, Macro
from sklearn.ensemble import GradientBoostingRegressor
xs = Macro.getGlobal("X")
cols = [c for c in Data.getVarName(range(Data.getVarCount())) if any(
    c == p or (p.endswith("*") and c.startswith(p[:-1])) for p in xs.split())]
d = pd.DataFrame(Data.get(cols + ["log_nights", "train"]), columns=cols + ["log_nights", "train"])
d = d[d.train == 1]
gb = GradientBoostingRegressor(n_estimators=500, max_depth=4, learning_rate=0.03, subsample=0.8,
                               random_state=1).fit(d[cols], d.log_nights)
imp = pd.Series(gb.feature_importances_, index=cols).sort_values(ascending=False)
print(imp.head(15).round(3).to_string())
imp.to_csv("output/ml/ch13/S3_stata_gradboost_importance.csv")
end

* ---- S3b: a stay of a week or more (yes/no) -------------------------------------------------------------
pystacked long_stay $X if train, type(class) foldvar(fold) finalest(nnls1) njobs(-1) pyseed(1) ///
    methods(logit lassocv ridgecv elasticcv svm rf gradboost nnet)                               ///
    cmdopt6(n_estimators(400) min_samples_leaf(5) max_features(0.4))                             ///
    cmdopt7(n_estimators(500) max_depth(4) learning_rate(0.03) subsample(0.8))                   ///
    cmdopt8(hidden_layer_sizes(32 16) alpha(1) early_stopping)                                   ///
    pipe5(stdscaler) pipe8(stdscaler)
matrix list e(weights)
pystacked, table holdout                        // includes the confusion matrices
pystacked, graph holdout                        // ROC curves on the test set, one per learner
graph export "docs/ml/fig13_S3b_stata_roc.png", replace           // ROC curves are summaries: may be shared
