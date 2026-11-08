# 17_cluster_sizes_design_effect.R -- Planning a trial that randomizes health systems: how unequal
# real system sizes inflate the design effect.
#
# A cluster-randomized trial loses precision to the intraclass correlation rho; with clusters of
# equal size m the design effect is 1 + (m - 1) rho. Real clusters are not equal. If patients are
# enrolled in proportion to a system's size (its discharges, or its primary care physicians), the
# spread of sizes matters through the coefficient of variation (cv = SD / mean) of the cluster sizes:
#
#   Eldridge, Ashby and Kerry (2006):  DE = 1 + ((cv^2 + 1) m - 1) rho     (m = mean cluster size)
#
# which is the design effect for an analysis that weights every patient equally. An analysis that
# weights clusters optimally (a mixed model, or cluster means weighted by m_j / (1 + (m_j - 1) rho))
# loses less; its exact design effect, for known rho and the sizes actually drawn, is
#   DE_opt = N / sum_j [ m_j / (1 + (m_j - 1) rho) ]    (N = total patients),
# because the variance of the optimally weighted mean is sigma^2 / sum_j w_j.
#
# Here the cluster sizes come from the Compendium's 2023 systems list: each simulated trial draws J
# systems at random, enrolls N patients in proportion to their discharges (or primary care
# physicians), and the three design effects (equal sizes, Eldridge, optimal weighting) are computed
# exactly; a capped version enrolls at most twice the mean per system. 2,000 draws per setting.
# Output: output/compendium/cluster_design_effects.csv.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

out_dir <- file.path("output", "compendium")
sizes <- read.csv(file.path(out_dir, "system_sizes.csv"))
set.seed(2023)
cv <- function(x) sd(x) / mean(x)
cat("Coefficient of variation of 2023 system sizes (all 639 systems):\n")
print(sapply(sizes[, c("acutehosp_cnt", "sys_beds", "sys_dsch", "total_mds", "prim_care_mds")], function(x) round(cv(na.omit(x)), 2)))

allocate <- function(size, N, cap = Inf) {   # patients per system, proportional to size, at most cap * mean
  m <- N * size / sum(size)
  if (is.finite(cap)) for (k in 1:50) { lim <- cap * N / length(size); over <- m > lim
    if (!any(over)) break
    extra <- sum(m[over] - lim); m[over] <- lim; m[!over] <- m[!over] + extra * m[!over] / sum(m[!over]) }
  m
}
de_draw <- function(size_var, J, N, rho, cap) {
  s <- na.omit(sizes[[size_var]]); s <- s[s > 0]
  r <- replicate(2000, {
    m <- allocate(sample(s, J), N, cap); mbar <- N / J
    c(eldridge = 1 + ((cv(m)^2 * (J - 1) / J + 1) * mbar - 1) * rho,   # population cv (divisor J) in the formula
      optimal = N / sum(m / (1 + (m - 1) * rho)), cv = cv(m))
  })
  c(equal = 1 + (N / J - 1) * rho, rowMeans(r))
}
grid <- expand.grid(size_var = c("sys_dsch", "prim_care_mds"), J = c(20, 60), N = 3000, rho = c(0.01, 0.05), cap = c(Inf, 2),
                    stringsAsFactors = FALSE)
res <- cbind(grid, t(mapply(de_draw, grid$size_var, grid$J, grid$N, grid$rho, grid$cap)))
res$size_measure <- ifelse(res$size_var == "sys_dsch", "discharges", "primary care physicians")
res$enrollment <- ifelse(is.finite(res$cap), "capped at 2x mean", "proportional to size")
res <- res[, c("size_measure", "enrollment", "J", "N", "rho", "cv", "equal", "eldridge", "optimal")]
res[, c("cv", "equal", "eldridge", "optimal")] <- round(res[, c("cv", "equal", "eldridge", "optimal")], 2)
res$extra_patients_pct_eldridge <- round(100 * (res$eldridge / res$equal - 1))
res$extra_patients_pct_optimal <- round(100 * (res$optimal / res$equal - 1))
write.csv(res, file.path(out_dir, "cluster_design_effects.csv"), row.names = FALSE)
cat("\nDesign effects for a trial of N = 3,000 patients in J randomly drawn 2023 health systems (mean of 2,000 draws):\n")
print(res, row.names = FALSE)
