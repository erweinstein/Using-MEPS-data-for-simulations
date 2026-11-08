# ml_12_prognostic_adjustment.R -- From prediction back to simulation and trial design: adjusting a
# randomized trial's analysis for a machine-learning prognostic score.
#
# Idea (Schuler et al. 2022, "PROCOVA"; qualified by the European Medicines Agency in 2022): train a
# model on historical data to predict the outcome under control, compute that prediction (the
# "prognostic score") for each trial participant from their baseline data, and adjust for it in an
# ANCOVA. The estimate stays unbiased whatever the model's quality (randomization does the work),
# and its variance falls by about the factor (1 - rho^2), where rho is the correlation between the
# score and the outcome. So the sample size needed falls by the same factor, and a better model buys
# a smaller trial.
#
# Plasmode simulation: the "historical data" are the training households (2022 -> 2023); the trial
# population is the test households. Each simulated trial draws 2 x 300 adults from the test set,
# randomizes them, and lowers the treated arm's log(1 + 2023 spending) by 0.5 (a large effect,
# about 39% lower 1 + spending, chosen so that the power differences are easy to see). Analyses: (1) difference in means; (2) ANCOVA on 2022 log spending; (3) ANCOVA on a
# lasso prognostic score; (4) ANCOVA on a boosted (xgboost) score; (5) on both. 5,000 trials each,
# with and without an effect. Then the planning shortcut: power from the normal formula with the
# variance multiplied by (1 - R^2), and the per-arm size for 80% power multiplied by (1 - R^2),
# against the simulated power. (Here R^2 is computed on the trial population itself; in practice
# it would come from held-out historical data, which this mimics because the scores never saw it.)
# Output: output/ml/prognostic_R.csv.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages({library(glmnet); library(xgboost)})
set.seed(2026)
Xtr <- x_matrix(train); Xte <- x_matrix(test)
las <- cv.glmnet(Xtr, train$log_cost, alpha = 1, foldid = train$fold)
s_lasso <- as.numeric(predict(las, Xte, s = "lambda.min"))
par <- xgb.params(objective = "reg:squarederror", learning_rate = 0.03, max_depth = 3, subsample = 0.8,
                  colsample_bytree = 0.8, min_child_weight = 5, nthread = 2, seed = 1)
b <- xgb.train(par, xgb.DMatrix(Xtr, label = train$log_cost), nrounds = 300, verbose = 0)
s_xgb <- predict(b, Xte)
pop <- data.frame(y = test$log_cost, prior = test$log_cost_2022, s_lasso, s_xgb)
r2 <- sapply(pop[, -1], function(s) cor(s, pop$y)^2)
cat("R^2 between each baseline covariate/score and log 2023 spending in the trial population:\n"); print(round(r2, 3))

n_arm <- 300; delta <- -0.5; reps <- 5000
one <- function(eff) {
  i <- sample(nrow(pop), 2 * n_arm); d <- pop[i, ]; d$t <- rep(0:1, each = n_arm); d$y <- d$y + eff * d$t
  est <- function(f) { m <- lm(f, data = d); c(coef(m)[["t"]], sqrt(vcov(m)["t", "t"])) }
  rbind(unadjusted = est(y ~ t), prior_year = est(y ~ t + prior), lasso_score = est(y ~ t + s_lasso),
        boosted_score = est(y ~ t + s_xgb), both_scores = est(y ~ t + s_lasso + s_xgb))
}
sim <- function(eff) { a <- replicate(reps, one(eff)); list(est = a[, 1, ], se = a[, 2, ]) }
h1 <- sim(delta); h0 <- sim(0)
df <- 2 * n_arm - 4
out <- data.frame(analysis = rownames(h1$est),
                  mean_estimate = rowMeans(h1$est), empirical_sd = apply(h1$est, 1, sd), mean_se = rowMeans(h1$se),
                  power = rowMeans(abs(h1$est / h1$se) > qt(0.975, df)),
                  type1 = rowMeans(abs(h0$est / h0$se) > qt(0.975, df)))
out$variance_ratio <- (out$empirical_sd / out$empirical_sd[1])^2
out$r2 <- c(0, r2[c("prior", "s_lasso", "s_xgb")], summary(lm(y ~ s_lasso + s_xgb, data = pop))$r.squared)
out$predicted_ratio <- 1 - out$r2
sd_y <- sd(pop$y)
out$predicted_power <- pnorm(abs(delta) / (sd_y * sqrt(2 / n_arm * out$predicted_ratio)) - qnorm(0.975))
# per-arm size for 80% power (two-sided 5%), from the population SD, and with the (1 - R^2) shortcut
n_unadj <- ceiling(2 * (qnorm(0.975) + qnorm(0.8))^2 * sd_y^2 / delta^2)
out$n_per_arm_80 <- ceiling(n_unadj * out$predicted_ratio)
write.csv(out, file.path(out_dir, "prognostic_R.csv"), row.names = FALSE)
cat("\n", reps, " simulated trials of 2 x ", n_arm, ", effect ", delta, " on log(1 + spending):\n", sep = "")
print(out, digits = 3, row.names = FALSE)
