# ml_10_uncertainty_subgroups.R -- Prediction intervals with guaranteed coverage (conformal
# prediction), and how well a model works within subgroups.
#
# 1. Conformal prediction (Vovk, Gammerman and Shafer 2005; Lei et al. 2018; Angelopoulos and Bates
#    2023). Train on folds 1-4, calibrate on fold 5, test on the test set. For log(1 + 2023
#    spending), 90% intervals by
#    (a) split conformal: prediction +- the 90% quantile of the calibration |residuals|;
#    (b) conformalized quantile regression (CQR; Romano, Patterson and Candes 2019): quantile
#        boosting for the 5th and 95th percentiles, widened by the calibration set's conformity
#        scores, so the width adapts to the person;
#    (c) CQR calibrated separately within each insurance group ("Mondrian" conformal; Vovk et al.
#        2005), which guarantees coverage within each group, not just overall.
#    Coverage is guaranteed on average over people like those in the calibration data
#    (exchangeability), not for each person, and the survey weights are not used in the guarantee.
# 2. Subgroups: for the top-10% classifier (chapter 4's boosted model), AUC and calibration in the
#    large (observed / predicted share) by insurance, race and ethnicity, and age group.
# Output: output/ml/conformal_R.csv, output/ml/subgroups_R.csv.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages(library(xgboost))
set.seed(1)
alpha <- 0.10
fit_idx <- train$fold != 5; cal_idx <- train$fold == 5
Xtr <- x_matrix(train); Xte <- x_matrix(test)
xgbfit <- function(obj, y, rows, rounds, extra = list()) {
  par <- do.call(xgb.params, c(list(objective = obj, learning_rate = 0.03, max_depth = 3, subsample = 0.8,
                                    colsample_bytree = 0.8, min_child_weight = 5, nthread = 2, seed = 1), extra))
  xgb.train(par, xgb.DMatrix(Xtr[rows, ], label = y[rows]), nrounds = rounds, verbose = 0)
}
y <- train$log_cost
qhat <- function(s, a) { n <- length(s); sort(s)[min(n, ceiling((n + 1) * (1 - a)))] }

# (a) split conformal around a mean model
m <- xgbfit("reg:squarederror", y, fit_idx, 300)
r_cal <- abs(y[cal_idx] - predict(m, Xtr[cal_idx, ]))
q <- qhat(r_cal, alpha); mu <- predict(m, Xte)
iv <- list(split = cbind(lo = mu - q, hi = mu + q))
# (b) CQR with quantile boosting
mlo <- xgbfit("reg:quantileerror", y, fit_idx, 300, list(quantile_alpha = alpha / 2))
mhi <- xgbfit("reg:quantileerror", y, fit_idx, 300, list(quantile_alpha = 1 - alpha / 2))
lo_c <- predict(mlo, Xtr[cal_idx, ]); hi_c <- predict(mhi, Xtr[cal_idx, ])
s_cal <- pmax(lo_c - y[cal_idx], y[cal_idx] - hi_c)
q2 <- qhat(s_cal, alpha)
lo_t <- predict(mlo, Xte); hi_t <- predict(mhi, Xte)
iv$cqr <- cbind(lo = lo_t - q2, hi = hi_t + q2)
iv$quantile_boost_only <- cbind(lo = lo_t, hi = hi_t)
# (c) Mondrian CQR by insurance group
g_cal <- train$insurance[cal_idx]; g_te <- test$insurance
lo_m <- lo_t; hi_m <- hi_t
for (g in levels(g_te)) { qg <- qhat(s_cal[g_cal == g], alpha); lo_m[g_te == g] <- lo_t[g_te == g] - qg; hi_m[g_te == g] <- hi_t[g_te == g] + qg }
iv$cqr_by_insurance <- cbind(lo = lo_m, hi = hi_m)

yt <- test$log_cost
groups <- list(All = rep(TRUE, nrow(test)), `Any private` = g_te == "Any private", `Public only` = g_te == "Public only",
               Uninsured = g_te == "Uninsured", `Age 18-44` = test$age < 45, `Age 65+` = test$age >= 65,
               `Top 10% in 2023` = test$high_cost == 1)
out <- do.call(rbind, lapply(names(iv), function(k) do.call(rbind, lapply(names(groups), function(gn) { i <- groups[[gn]]
  data.frame(method = k, group = gn, n = sum(i), coverage = mean(yt[i] >= iv[[k]][i, "lo"] & yt[i] <= iv[[k]][i, "hi"]),
             median_width_log = median(iv[[k]][i, "hi"] - pmax(iv[[k]][i, "lo"], 0)),
             median_upper_dollars = median(expm1(iv[[k]][i, "hi"]))) }))))
write.csv(out, file.path(out_dir, "conformal_R.csv"), row.names = FALSE)
cat("90% prediction intervals for log(1 + 2023 spending), coverage on the test set (unweighted):\n")
print(reshape(out[, c("method", "group", "coverage")], idvar = "group", timevar = "method", direction = "wide"), digits = 3, row.names = FALSE)
cat("\nMedian upper limit in dollars:\n")
print(reshape(out[, c("method", "group", "median_upper_dollars")], idvar = "group", timevar = "method", direction = "wide"), digits = 4, row.names = FALSE)

# ---- 2. subgroup performance of the top-10% classifier ----------------------------------------------------
b <- xgb.load(file.path(out_dir, "xgb_high_cost.json")); p <- predict(b, Xte)
sg <- list(insurance = test$insurance, race_eth = test$race_eth,
           age = cut(test$age, c(17, 44, 64, Inf), labels = c("18-44", "45-64", "65+")))
sub <- do.call(rbind, lapply(names(sg), function(v) do.call(rbind, lapply(levels(droplevels(factor(sg[[v]]))), function(l) {
  i <- sg[[v]] == l; w <- test$weight[i]
  data.frame(variable = v, group = l, n = sum(i), top10_share = wmean(test$high_cost[i], w),
             auc = if (length(unique(test$high_cost[i])) == 2) w_auc(test$high_cost[i], p[i], w) else NA,
             observed_over_predicted = wmean(test$high_cost[i], w) / wmean(p[i], w)) }))))
write.csv(sub, file.path(out_dir, "subgroups_R.csv"), row.names = FALSE)
cat("\nTop-10% classifier by subgroup (test set, weighted):\n"); print(sub, digits = 3, row.names = FALSE)
