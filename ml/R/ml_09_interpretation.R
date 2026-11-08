# ml_09_interpretation.R -- Interpreting a black-box model (Molnar, Interpretable Machine Learning,
# 3rd ed.): permutation importance, partial dependence and individual conditional expectation
# (ICE) curves, accumulated local effects (ALE), and SHAP values, for chapter 4's boosted model of
# being a top-10% spender in 2023 (xgboost, output/ml/xgb_high_cost.json), with the logistic
# regression of chapter 1 alongside for comparison.
#
# - Permutation importance (Molnar ch. 23): the loss in test AUC when one predictor's values are
#   shuffled, averaged over 10 shuffles. Dummy variables of one categorical predictor are
#   shuffled together.
# - Partial dependence and ICE (ch. 19 and 13): the predicted probability as one predictor is set
#   to each value of a grid, for everyone (ICE) and on average (PDP).
# - ALE (ch. 20): local differences within intervals of the predictor, accumulated; unlike the
#   PDP it does not average over impossible combinations of correlated predictors (here, 2022
#   spending and 2022 visits).
# - SHAP (ch. 17-18): each person's prediction split into one additive part per predictor (exact
#   TreeSHAP from xgboost's predcontrib, on the log-odds scale).
# Output: output/ml/importance_R.csv, output/ml/shap_summary_R.csv, figures in output/ml/fig_*_R.png.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages({library(xgboost); library(ggplot2); library(patchwork)})
set.seed(1)
Xtr <- x_matrix(train); Xte <- x_matrix(test)
b <- xgb.load(file.path(out_dir, "xgb_high_cost.json"))
pred <- function(X) predict(b, X)
lg <- glm(update(reformulate(predictors_log), high_cost ~ .), data = train, family = binomial)

# ---- permutation importance (test set, weighted AUC) ---------------------------------------------------
groups <- lapply(predictors_log, function(v) if (v %in% cat_vars) grep(paste0("^", v), colnames(Xte)) else which(colnames(Xte) == v))
names(groups) <- predictors_log
base <- w_auc(test$high_cost, pred(Xte), test$weight)
imp <- sapply(groups, function(j) mean(replicate(10, { X <- Xte; X[, j] <- X[sample(nrow(X)), j, drop = FALSE]
  base - w_auc(test$high_cost, pred(X), test$weight) })))
imp <- sort(imp, decreasing = TRUE)
write.csv(data.frame(predictor = names(imp), auc_loss = imp), file.path(out_dir, "importance_R.csv"), row.names = FALSE)
cat("Test AUC", round(base, 4), "; loss in AUC when each predictor is shuffled (top 10):\n"); print(round(head(imp, 10), 4))

# ---- PDP, ICE and ALE for three predictors ------------------------------------------------------------------
pdp_ice <- function(v, grid) {
  ice <- sapply(grid, function(g) { X <- Xte; X[, v] <- g; pred(X) })
  list(grid = grid, ice = ice, pdp = colSums(ice * test$weight) / sum(test$weight))
}
ale <- function(v, K = 20) {                                    # first-order ALE (Apley and Zhu 2020)
  x <- Xte[, v]; z <- unique(quantile(x, seq(0, 1, length.out = K + 1), type = 1))
  k <- pmax(1, findInterval(x, z, rightmost.closed = TRUE, left.open = TRUE)); k[k > length(z) - 1] <- length(z) - 1
  lo <- Xte; hi <- Xte; lo[, v] <- z[k]; hi[, v] <- z[k + 1]
  d <- pred(hi) - pred(lo)
  m <- tapply(d * test$weight, k, sum) / tapply(test$weight, k, sum)
  eff <- c(0, cumsum(m)); eff <- eff - sum(eff[-1] * tapply(test$weight, k, sum)) / sum(test$weight)
  data.frame(x = z[seq_along(eff)], ale = eff)
}
vars <- c(log_cost_2022 = "2022 spending (log of 1 + $)", age = "Age in 2022", pcs = "Physical component score (VR-12)")
plots <- list()
for (v in names(vars)) {
  grid <- quantile(Xte[, v], seq(0.02, 0.98, length.out = 25))
  pi <- pdp_ice(v, grid); a <- ale(v)
  ice_d <- data.frame(x = rep(grid, each = 200), y = as.numeric(pi$ice[sample(nrow(Xte), 200), ]),
                      id = rep(1:200, times = length(grid)))
  plots[[v]] <- ggplot() +
    geom_line(data = ice_d, aes(x, y, group = id), colour = "grey70", linewidth = 0.2, alpha = 0.6) +
    geom_line(data = data.frame(x = grid, y = pi$pdp), aes(x, y), colour = "#1f4e79", linewidth = 1.1) +
    geom_line(data = transform(a, y = ale + wmean(pred(Xte), test$weight)), aes(x, y), colour = "#c55a11",
              linewidth = 1, linetype = "dashed") +
    labs(x = vars[[v]], y = "P(top 10% in 2023)") + theme_minimal(base_size = 10)
}
p <- wrap_plots(plots, nrow = 1) + plot_annotation(
  title = "How the boosted model's predicted risk of being a top-10% spender depends on three predictors",
  subtitle = "Grey: ICE curves for 200 test-set adults; blue: partial dependence (weighted average); orange dashed: ALE (centred, shifted to the mean prediction)")
ggsave(file.path(out_dir, "fig_pdp_ice_ale_R.png"), p, width = 12, height = 4, dpi = 200, bg = "white")

# ---- SHAP values (exact TreeSHAP), compared with the logistic regression's coefficients -----------------
sh <- predict(b, Xte, predcontrib = TRUE)                     # one column per feature + "(Intercept)"/"BIAS"
sh <- sh[, colnames(sh) %in% colnames(Xte)]
grp <- sapply(groups, function(j) rowSums(sh[, colnames(Xte)[j], drop = FALSE]))
mean_abs <- sort(colSums(abs(grp) * test$weight) / sum(test$weight), decreasing = TRUE)
write.csv(data.frame(predictor = names(mean_abs), mean_abs_shap = mean_abs), file.path(out_dir, "shap_summary_R.csv"), row.names = FALSE)
cat("\nMean |SHAP| (log-odds), top 10:\n"); print(round(head(mean_abs, 10), 3))
top <- names(mean_abs)[1:10]
sd_ <- do.call(rbind, lapply(top, function(v) { x <- if (v %in% cat_vars) NA else Xte[, v]
  data.frame(predictor = v, shap = grp[, v], value = if (all(is.na(x))) NA else (rank(x) - 1) / (length(x) - 1)) }))
sd_$predictor <- factor(sd_$predictor, levels = rev(top))
g <- ggplot(sd_, aes(shap, predictor, colour = value)) + geom_jitter(height = 0.2, size = 0.4, alpha = 0.5) +
  scale_colour_gradient(low = "#2c7bb6", high = "#d7191c", na.value = "grey50", name = "Predictor\nvalue (rank)") +
  labs(x = "SHAP value (contribution to the log-odds of being a top-10% spender)", y = NULL,
       title = "SHAP summary: the boosted model for top-10% spending in 2023 (test set)") + theme_minimal(base_size = 10)
ggsave(file.path(out_dir, "fig_shap_R.png"), g, width = 8, height = 5, dpi = 200, bg = "white")
cat("\nLogistic regression, the same predictors: largest |coefficient x SD| (log-odds per SD):\n")
cf <- coef(lg)[-1]; sds <- sapply(names(cf), function(n) if (n %in% colnames(Xtr)) sd(Xtr[, n]) else NA)
print(round(head(sort(abs(cf * sds), decreasing = TRUE), 10), 3))
