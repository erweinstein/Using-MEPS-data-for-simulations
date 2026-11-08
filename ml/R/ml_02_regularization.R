# ml_02_regularization.R -- Shrinkage: ridge, lasso and the elastic net (ISLR ch. 6; ESL sec. 3.4,
# 4.4.4, 18.4), with the penalty chosen by 5-fold cross-validation over households.
#
# glmnet standardizes the predictors internally and reports coefficients on the original
# scale. The folds are the `fold` column of the data (households kept together), passed as
# `foldid`, so R and Python cross-validate on the same splits.
# Output: output/ml/results_R.csv (chapter "02 regularization"), output/ml/lasso_path_R.csv
# (how many predictors the lasso keeps), output/ml/lasso_coef_R.csv.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages(library(glmnet))
ch <- "02 regularization"
Xtr <- x_matrix(train); Xte <- x_matrix(test)
fam <- c(cost = "gaussian", log_cost = "gaussian", high_cost = "binomial", any_er = "binomial",
         any_ip = "binomial", ob_visits = "poisson")
res <- list(); keep <- list()
for (y in names(fam)) {
  for (a in c(0, 0.5, 1)) {
    nm <- c(`0` = "Ridge", `0.5` = "Elastic net (alpha = 0.5)", `1` = "Lasso")[as.character(a)]
    cv <- cv.glmnet(Xtr, train[[y]], family = fam[[y]], alpha = a, foldid = train$fold)
    p <- as.numeric(predict(cv, Xte, s = "lambda.min", type = "response"))
    res[[length(res) + 1]] <- evaluate(y, p, nm, ch)
    if (a == 1) keep[[y]] <- data.frame(outcome = y, lambda_min = cv$lambda.min, lambda_1se = cv$lambda.1se,
                                        kept_min = cv$nzero[cv$lambda == cv$lambda.min],
                                        kept_1se = cv$nzero[cv$lambda == cv$lambda.1se], of = ncol(Xtr))
    if (a == 1 && y == "high_cost") {
      b <- as.matrix(coef(cv, s = "lambda.1se")); b <- b[b[, 1] != 0, , drop = FALSE]
      write.csv(data.frame(term = rownames(b), coef = b[, 1]), file.path(out_dir, "lasso_coef_R.csv"), row.names = FALSE)
    }
  }
}
res <- do.call(rbind, res); log_results(res); show(res)
keep <- do.call(rbind, keep); write.csv(keep, file.path(out_dir, "lasso_path_R.csv"), row.names = FALSE)
cat("\nPredictors kept by the lasso (of", ncol(Xtr), "columns):\n"); print(keep, digits = 3, row.names = FALSE)
cat("\nLasso (lambda.1se) coefficients for the top-10% outcome, log-odds:\n")
print(read.csv(file.path(out_dir, "lasso_coef_R.csv")), digits = 3, row.names = FALSE)
