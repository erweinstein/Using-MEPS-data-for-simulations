# ml_07_unsupervised.R -- Unsupervised learning (ISLR ch. 12; ESL ch. 14): principal components of
# 2022 health status, clusters of adults by health and use, and principal components regression
# (ISLR sec. 6.3).
#
# - PCA of 18 standardized health measures (self-rated health, conditions, functioning, BMI and
#   the SAQ scores). Which directions carry the variation?
# - k-means (k = 2-8, 25 random starts) on the first principal components, plus 2022 spending,
#   and Ward hierarchical clustering; clusters described by 2023 spending (weighted), which the
#   clustering never saw.
# - Principal components regression of log spending, the number of components chosen on the
#   household folds.
# Output: output/ml/pca_R.csv, output/ml/clusters_R.csv, output/ml/results_R.csv (chapter
# "07 unsupervised").
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages(library(cluster))
ch <- "07 unsupervised"
set.seed(1)
health_vars <- c("health", "mental_health", "high_bp", "diabetes", "arthritis", "asthma", "coronary", "heart_attack",
                 "angina", "other_heart", "stroke", "emphysema", "high_chol", "cancer", "adl_help", "iadl_help",
                 "walk_limit", "bmi", "pcs", "mcs", "k6", "phq2")
H <- scale(ml[, health_vars])
pc <- prcomp(H)
ve <- pc$sdev^2 / sum(pc$sdev^2)
cat("Variance explained by the first 6 components:", round(100 * ve[1:6], 1), "% (cumulative",
    round(100 * sum(ve[1:6]), 1), "%)\n")
load <- round(pc$rotation[, 1:3], 2); print(load[order(-abs(load[, 1])), ])
write.csv(data.frame(var = rownames(pc$rotation), pc$rotation[, 1:4], row.names = NULL), file.path(out_dir, "pca_R.csv"), row.names = FALSE)

# ---- k-means on the first 6 components plus log 2022 spending ----------------------------------------
Z <- cbind(pc$x[, 1:6], log_cost = as.numeric(scale(ml$log_cost_2022)))
wss <- sapply(2:8, function(k) kmeans(Z, k, nstart = 25, iter.max = 50)$tot.withinss)
sil <- sapply(2:8, function(k) { km <- kmeans(Z, k, nstart = 25, iter.max = 50)
  mean(silhouette(km$cluster[1:2000], dist(Z[1:2000, ]))[, 3]) })     # silhouette on 2,000 adults (memory)
cat("Within-cluster SS, k = 2-8:", round(wss), "\nMean silhouette, k = 2-8:", round(sil, 3), "\n")
k <- 4
km <- kmeans(Z, k, nstart = 25, iter.max = 50)
ml$cluster <- km$cluster
desc <- do.call(rbind, lapply(sort(unique(ml$cluster)), function(cl) { d <- ml[ml$cluster == cl, ]
  data.frame(cluster = cl, n = nrow(d), pop_share = sum(d$weight) / sum(ml$weight), age = wmean(d$age, d$weight),
             fair_poor_health = wmean(d$health >= 4, d$weight), walk_limit = wmean(d$walk_limit, d$weight),
             mean_cost_2022 = wmean(d$cost_2022, d$weight), mean_cost_2023 = wmean(d$cost, d$weight),
             top10_2023 = wmean(d$high_cost, d$weight)) }))
desc <- desc[order(desc$mean_cost_2023), ]
cat("\nk-means clusters (k = 4), described by variables the clustering did not use (2023):\n"); print(desc, digits = 3, row.names = FALSE)
write.csv(desc, file.path(out_dir, "clusters_R.csv"), row.names = FALSE)

# ---- hierarchical clustering (Ward) on a subsample, compared with k-means --------------------------
idx <- sample(nrow(Z), 2000)
hc <- hclust(dist(Z[idx, ]), method = "ward.D2")
cat("\nAgreement of Ward (4 groups) with k-means on 2,000 adults (adjusted Rand index):",
    round({t <- table(cutree(hc, 4), ml$cluster[idx]); n <- sum(t)
      a <- sum(choose(t, 2)); b <- sum(choose(rowSums(t), 2)); c <- sum(choose(colSums(t), 2)); e <- b * c / choose(n, 2)
      (a - e) / ((b + c) / 2 - e)}, 3), "\n")

# ---- principal components regression of log spending ------------------------------------------------
Xtr <- x_matrix(train); Xte <- x_matrix(test); sc <- scaler(Xtr); Ztr <- sc(Xtr); Zte <- sc(Xte)
keep <- apply(Ztr, 2, sd) > 0; Ztr <- Ztr[, keep]; Zte <- Zte[, keep]
p_tr <- prcomp(Ztr, center = FALSE)
cv_err <- sapply(1:40, function(m) mean(sapply(1:5, function(f) { tr <- train$fold != f
  pp <- prcomp(Ztr[tr, ], center = FALSE); s_tr <- pp$x[, 1:m, drop = FALSE]; s_te <- Ztr[!tr, ] %*% pp$rotation[, 1:m, drop = FALSE]
  b <- lm.fit(cbind(1, s_tr), train$log_cost[tr])$coefficients; mean((train$log_cost[!tr] - cbind(1, s_te) %*% b)^2) })))
m <- which.min(cv_err)
b <- lm.fit(cbind(1, p_tr$x[, 1:m]), train$log_cost)$coefficients
res <- evaluate("log_cost", cbind(1, Zte %*% p_tr$rotation[, 1:m]) %*% b, paste0("Principal components regression (", m, " PCs)"), ch)
log_results(res); show(res)
