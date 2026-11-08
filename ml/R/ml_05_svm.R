# ml_05_svm.R -- Support vector machines (ISLR ch. 9; ESL ch. 12): a linear and a radial-kernel
# SVM for the binary outcomes (with Platt-scaled probabilities) and support vector regression for
# log spending.
#
# SVMs need standardized predictors; cost (C) and the kernel width (gamma) are chosen on the
# household folds from a small grid. SVMs were built for classification margins, not
# probabilities, and scale poorly with n (the radial kernel's cost grows with n squared or worse);
# they are included because ISLR and ESL cover them, and to show where they stand on data like these.
# Output: output/ml/results_R.csv (chapter "05 SVM").
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages(library(e1071))
ch <- "05 SVM"
set.seed(1)
Xtr <- x_matrix(train); Xte <- x_matrix(test); sc <- scaler(Xtr); Ztr <- sc(Xtr); Zte <- sc(Xte)
keep <- apply(Ztr, 2, sd) > 0; Ztr <- Ztr[, keep]; Zte <- Zte[, keep]
res <- list()

cv_svm <- function(y, kernel, grid, type) {
  score <- apply(grid, 1, function(g) mean(sapply(1:5, function(f) {
    tr <- train$fold != f
    yy <- if (type == "C-classification") factor(train[[y]][tr]) else train[[y]][tr]
    m <- svm(Ztr[tr, ], yy, type = type, kernel = kernel, cost = g[["cost"]], gamma = g[["gamma"]],
             probability = type == "C-classification", scale = FALSE)
    if (type == "C-classification") { p <- attr(predict(m, Ztr[!tr, ], probability = TRUE), "probabilities")[, "1"]
      mean((train[[y]][!tr] - p)^2) } else mean((train[[y]][!tr] - predict(m, Ztr[!tr, ]))^2)
  })))
  grid[which.min(score), ]
}
g_lin <- expand.grid(cost = c(0.01, 0.1, 1), gamma = 1)
g_rbf <- expand.grid(cost = c(0.3, 1, 3), gamma = c(0.3, 1, 3) / ncol(Ztr))
for (y in c("high_cost", "any_er")) {
  for (k in c("linear", "radial")) {
    best <- cv_svm(y, k, if (k == "linear") g_lin else g_rbf, "C-classification")
    m <- svm(Ztr, factor(train[[y]]), type = "C-classification", kernel = k, cost = best$cost, gamma = best$gamma,
             probability = TRUE, scale = FALSE)
    p <- attr(predict(m, Zte, probability = TRUE), "probabilities")[, "1"]
    res[[length(res) + 1]] <- evaluate(y, p, paste0("SVM, ", k, " kernel"), ch)
    cat(y, k, ": cost =", best$cost, if (k == "radial") paste("gamma =", signif(best$gamma, 2)) else "", "\n")
  }
}
best <- cv_svm("log_cost", "radial", g_rbf, "eps-regression")
m <- svm(Ztr, train$log_cost, type = "eps-regression", kernel = "radial", cost = best$cost, gamma = best$gamma, scale = FALSE)
res[[length(res) + 1]] <- evaluate("log_cost", predict(m, Zte), "SVR, radial kernel", ch)
res <- do.call(rbind, res); log_results(res); show(res)
