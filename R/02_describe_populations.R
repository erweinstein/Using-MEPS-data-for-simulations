# 02_describe_populations.R -- What do the MEPS outcomes look like?
#
# Weighted moments and quantiles for eight outcomes (see 00_functions.R), and a
# histogram of each. These are the "populations" the later scripts sample from.
# For reference, a normal distribution has skewness 0 and kurtosis 3; Blanca et
# al. (2013) found kurtosis between about 1.1 and 10.4 in 693 small samples of
# psychological measures, and Micceri (1989) found every one of 440 large
# achievement and psychometric distributions non-normal.
#
# Output: output/populations.csv, output/fig_populations.png
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("R/00_functions.R")
library(ggplot2)
P <- load_populations()

tab <- do.call(rbind, lapply(names(P), function(k)
  data.frame(population = k, label = P[[k]]$label, t(wmoments(P[[k]]$y, P[[k]]$w)))))
dir.create("output", showWarnings = FALSE)
write.csv(tab, "output/populations.csv", row.names = FALSE)
print(format(tab[, -1], digits = 3, big.mark = ","), row.names = FALSE)

# Histograms (weighted). Spending, visits and nights are shown on a log(1 + y)
# scale, and the change in spending on a signed log scale, sign(y) log(1 + |y|).
logged <- c("spend_all", "spend_dep", "nights_stay", "visits_dep")
hd <- do.call(rbind, lapply(names(P), function(k) {
  y <- P[[k]]$y; lab <- P[[k]]$label
  if (k %in% logged) { y <- log1p(y); lab <- paste0(lab, " (log 1 + y)") }
  if (k == "spend_chg") { y <- sign(y) * log1p(abs(y)); lab <- paste0(lab, " (signed log)") }
  data.frame(label = lab, y = y, w = P[[k]]$w)
}))
hd$label <- factor(hd$label, levels = unique(hd$label))
g <- ggplot(hd, aes(y, weight = w)) +
  geom_histogram(bins = 40, fill = "#1B5E83", colour = "white", linewidth = 0.1) +
  facet_wrap(~label, scales = "free", ncol = 2) + theme_minimal(base_size = 11) +
  theme(axis.text.y = element_blank(), panel.grid.minor = element_blank()) +
  labs(x = NULL, y = NULL, title = "Eight MEPS outcomes used as simulation populations",
       subtitle = paste0("Weighted to US adults; ", if (file.exists(file.path(data_dir, "meps_info.txt")))
         readLines(file.path(data_dir, "meps_info.txt"))[1] else paste("data in", data_dir)))
ggsave("output/fig_populations.png", g, width = 9, height = 10, dpi = 200, bg = "white")
