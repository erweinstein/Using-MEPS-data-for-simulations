# ml_01_classical.R -- Baselines and classical regression models (ISLR ch. 3-4; ESL ch. 3-4),
# and the health-economics standards for spending (log OLS with smearing, the two-part model,
# GLMs with a log link). Every later model has to beat these.
#
# Outcomes (2023): cost, log_cost, high_cost (top 10%), any_er, any_ip, ob_visits.
# Fitted on the training households, evaluated on the test households with the survey weights.
# Output: output/ml/results_R.csv (chapter "01 classical"); a weighted-vs-unweighted comparison
# is printed.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages(library(MASS))
if (!requireNamespace("glm2", quietly = TRUE)) install.packages("glm2")
ch <- "01 classical"
f_all <- reformulate(predictors_log)
res <- list()

# ---- baseline: the (weighted) training mean -------------------------------------------------------
for (y in outcomes) res[[length(res) + 1]] <- evaluate(y, rep(wmean(train[[y]], train$weight), nrow(test)), "Mean only", ch)

# ---- spending ------------------------------------------------------------------------------------
ols <- lm(update(f_all, cost ~ .), data = train)
res[[length(res) + 1]] <- evaluate("cost", predict(ols, test), "Linear regression", ch)

# log(1 + cost) by OLS, back-transformed with Duan's smearing factor
lols <- lm(update(f_all, log_cost ~ .), data = train)
smear <- mean(exp(residuals(lols)))
res[[length(res) + 1]] <- evaluate("log_cost", predict(lols, test), "Linear regression", ch)
res[[length(res) + 1]] <- evaluate("cost", exp(predict(lols, test)) * smear - 1, "Log OLS + smearing", ch)

# Two-part model: P(any spending) x E(spending | any), the second part a gamma GLM with a log link
tp1 <- glm(update(f_all, I(cost > 0) ~ .), data = train, family = binomial)
pos <- train[train$cost > 0, ]
st  <- coef(lm(update(f_all, log(cost) ~ .), data = pos))          # starting values
# With heavy-tailed spending, glm()'s plain IRLS can overshoot and oscillate (it then stops at a
# worse fit, deviance 7,136 here, and says it did not converge). glm2() halves the step whenever the
# deviance rises (Marschner 2011) and converges to the minimum (7,043.6).
tp2 <- suppressWarnings(glm2::glm2(update(f_all, cost ~ .), data = pos, family = Gamma(link = "log"), start = st,
                  control = glm.control(epsilon = 1e-10, maxit = 1000)))   # warnings = step-halving notes
if (!tp2$converged) warning("The gamma GLM did not converge.")
res[[length(res) + 1]] <- evaluate("cost", predict(tp1, test, type = "response") * predict(tp2, test, type = "response"),
                                   "Two-part (logit x gamma GLM)", ch)
# One-part GLM with a log link and Poisson variance ("quasi-Poisson"), robust to zeros
qp <- glm(update(f_all, cost ~ .), data = train, family = quasipoisson(link = "log"), control = glm.control(maxit = 100))
res[[length(res) + 1]] <- evaluate("cost", predict(qp, test, type = "response"), "GLM, log link (quasi-Poisson)", ch)

# ---- binary outcomes: logistic regression ----------------------------------------------------------
for (y in c("high_cost", "any_er", "any_ip")) {
  m <- glm(update(f_all, as.formula(paste(y, "~ ."))), data = train, family = binomial)
  res[[length(res) + 1]] <- evaluate(y, predict(m, test, type = "response"), "Logistic regression", ch)
}

# ---- office visits: Poisson and negative binomial --------------------------------------------------
pm <- glm(update(f_all, ob_visits ~ .), data = train, family = poisson)
nb <- glm.nb(update(f_all, ob_visits ~ .), data = train, control = glm.control(maxit = 100))
res[[length(res) + 1]] <- evaluate("ob_visits", predict(pm, test, type = "response"), "Poisson GLM", ch)
res[[length(res) + 1]] <- evaluate("ob_visits", predict(nb, test, type = "response"), "Negative binomial GLM", ch)

res <- do.call(rbind, res); log_results(res); show(res)

# ---- does fitting with the survey weights change anything? -----------------------------------------
wn <- train$weight / mean(train$weight)
cmp <- rbind(
  evaluate("high_cost", predict(glm(update(f_all, high_cost ~ .), data = train, family = binomial), test, type = "response"),
           "Logistic, unweighted fit", ch),
  evaluate("high_cost", predict(suppressWarnings(glm(update(f_all, high_cost ~ .), data = train, family = quasibinomial, weights = wn)),
                                test, type = "response"), "Logistic, weighted fit", ch),
  evaluate("log_cost", predict(lols, test), "Log OLS, unweighted fit", ch),
  evaluate("log_cost", predict(lm(update(f_all, log_cost ~ .), data = train, weights = wn), test), "Log OLS, weighted fit", ch))
cat("\nFitting with and without the survey weights (both evaluated with them):\n"); show(cmp)
