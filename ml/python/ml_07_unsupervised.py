"""ml_07_unsupervised.py -- Principal components, k-means and hierarchical clustering, and principal
components regression (ISLR/ISLP ch. 12 and sec. 6.3; ESL ch. 14). Python version of
ml/R/ml_07_unsupervised.R (scikit-learn).
Output: output/ml/clusters_python.csv, output/ml/results_python.csv (chapter "07 unsupervised").

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.cluster import AgglomerativeClustering, KMeans
from sklearn.decomposition import PCA
from sklearn.linear_model import LinearRegression
from sklearn.metrics import adjusted_rand_score, silhouette_score
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from ml_common import *  # noqa: E402,F403

warnings.simplefilter("ignore")
CH = "07 unsupervised"
HEALTH = ["health", "mental_health", "high_bp", "diabetes", "arthritis", "asthma", "coronary", "heart_attack",
          "angina", "other_heart", "stroke", "emphysema", "high_chol", "cancer", "adl_help", "iadl_help",
          "walk_limit", "bmi", "pcs", "mcs", "k6", "phq2"]
H = StandardScaler().fit_transform(ml[HEALTH])
pca = PCA().fit(H)
print("Variance explained by the first 6 components (%):", np.round(100 * pca.explained_variance_ratio_[:6], 1),
      f"cumulative {100 * pca.explained_variance_ratio_[:6].sum():.1f}%")
load = pd.DataFrame(pca.components_[:3].T, index=HEALTH, columns=["PC1", "PC2", "PC3"]).round(2)
print(load.reindex(load.PC1.abs().sort_values(ascending=False).index).to_string())

scores = pca.transform(H)[:, :6]
Z = np.column_stack([scores, StandardScaler().fit_transform(ml[["log_cost_2022"]])])
rng = np.random.default_rng(1)
sub = rng.choice(len(Z), 2000, replace=False)
for k in range(2, 9):
    km = KMeans(k, n_init=25, random_state=1).fit(Z)
    print(f"k = {k}: within-cluster SS {km.inertia_:.0f}, silhouette {silhouette_score(Z[sub], km.labels_[sub]):.3f}")
km = KMeans(4, n_init=25, random_state=1).fit(Z)
ml["cluster"] = km.labels_ + 1
rows = []
for cl, d in ml.groupby("cluster"):
    w = d.weight
    rows.append({"cluster": cl, "n": len(d), "pop_share": w.sum() / ml.weight.sum(), "age": wmean(d.age, w),
                 "fair_poor_health": wmean(d.health >= 4, w), "walk_limit": wmean(d.walk_limit, w),
                 "mean_cost_2022": wmean(d.cost_2022, w), "mean_cost_2023": wmean(d.cost, w), "top10_2023": wmean(d.high_cost, w)})
desc = pd.DataFrame(rows).sort_values("mean_cost_2023")
print("\nk-means clusters (k = 4), described by 2023 outcomes the clustering did not use:\n", desc.round(3).to_string(index=False))
desc.to_csv(OUT_DIR / "clusters_python.csv", index=False)
ward = AgglomerativeClustering(4, linkage="ward").fit(Z[sub])
print(f"\nAgreement of Ward (4 groups) with k-means on 2,000 adults (adjusted Rand index): "
      f"{adjusted_rand_score(ward.labels_, km.labels_[sub]):.3f}")

# principal components regression of log spending
sc = StandardScaler().fit(x_matrix(train))
Ztr, Zte = sc.transform(x_matrix(train)), sc.transform(x_matrix(test))
folds = train.fold.values
err = []
for m in range(1, 41):
    e = []
    for f in range(1, 6):
        p = PCA(m).fit(Ztr[folds != f])
        lr = LinearRegression().fit(p.transform(Ztr[folds != f]), train.log_cost[folds != f])
        e.append(np.mean((train.log_cost[folds == f] - lr.predict(p.transform(Ztr[folds == f]))) ** 2))
    err.append(np.mean(e))
m = int(np.argmin(err)) + 1
p = PCA(m).fit(Ztr)
lr = LinearRegression().fit(p.transform(Ztr), train.log_cost)
res = evaluate("log_cost", lr.predict(p.transform(Zte)), f"Principal components regression ({m} PCs)", CH)
log_results(res)
show(res)
