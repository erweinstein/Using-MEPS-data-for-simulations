# ml_06_neural_nets.R -- Neural networks (ISLR ch. 10; ESL ch. 11): a feed-forward network with one
# hidden layer (nnet), with the size and weight decay chosen on the household folds.
#
# ISLR's deep-learning lab uses keras or torch; for tabular data of this size a single hidden
# layer with weight decay (ESL sec. 11.5) is the relevant baseline, and the deep-learning
# packages are a large install. Networks are fitted to standardized predictors; spending is
# modelled on the log scale only (a network fitted to raw dollars is dominated by a few people).
# Each fit averages 5 networks from different random starts (ESL sec. 11.5.3; Ripley 1996).
# Output: output/ml/results_R.csv (chapter "06 neural networks").
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages(library(nnet))
ch <- "06 neural networks"
set.seed(1)
Xtr <- x_matrix(train); Xte <- x_matrix(test); sc <- scaler(Xtr); Ztr <- sc(Xtr); Zte <- sc(Xte)
res <- list()

fit_avg <- function(Z, y, size, decay, linout, Znew, reps = 5) {
  rowMeans(sapply(1:reps, function(r) {
    m <- nnet(Z, y, size = size, decay = decay, linout = linout, entropy = !linout, maxit = 500, trace = FALSE, MaxNWts = 1e5)
    as.numeric(predict(m, Znew))
  }))
}
for (y in c("log_cost", "high_cost", "any_er", "any_ip")) {
  linout <- y == "log_cost"
  grid <- expand.grid(size = c(3, 8, 16), decay = c(0.1, 1, 5))
  err <- apply(grid, 1, function(g) mean(sapply(1:5, function(f) {
    tr <- train$fold != f
    p <- fit_avg(Ztr[tr, ], train[[y]][tr], g[["size"]], g[["decay"]], linout, Ztr[!tr, ], reps = 2)
    mean((train[[y]][!tr] - p)^2)
  })))
  g <- grid[which.min(err), ]
  p <- fit_avg(Ztr, train[[y]], g$size, g$decay, linout, Zte)
  res[[length(res) + 1]] <- evaluate(y, p, "Neural network (1 hidden layer)", ch)
  cat(y, ": hidden units =", g$size, ", weight decay =", g$decay, "\n")
}
res <- do.call(rbind, res); log_results(res); show(res)
