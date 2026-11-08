# data/

`R/01_extract_meps.R` writes its CSVs here: `meps_fyc.csv`,
`meps_stays.csv`, `meps_panel.csv`, `meps_variables.csv` and `meps_info.txt`. They are made
from MEPS public use files you download yourself, and are not part of the
repository (see "Using the MEPS data responsibly" in the README).

The machine learning chapters' `ml/R/ml_00_extract.R` (or `ml/python/ml_00_extract.py`;
both write the same file) writes `meps_ml.csv` here from the Panel 27 longitudinal
file (HC-252, `h252.dta`): one row per adult (18 or older at the end of 2022, in
scope all five rounds, positive longitudinal weight), 6,353 rows for the 2023
release. Its columns:

| Columns | What they are |
|---|---|
| `person`, `household` | MEPS person and dwelling-unit IDs (DUPERSID, DUID) |
| `weight`, `stratum`, `psu` | longitudinal weight (LONGWT) and variance strata and PSUs |
| `test`, `fold` | the shared split: 1 = test household (30%); folds 1–5 for training households, 0 for test |
| `cost`, `high_cost`, `log_cost` | 2023 total spending, top 10% of 2023 spending (weighted cut-off), log(1 + spending) |
| `ob_visits`, `any_er`, `any_ip` | 2023 office-based visits, any ER visit, any hospital discharge |
| `age` … `usual_source` | 2022 demographics, insurance, employment and usual source of care |
| `health`, `mental_health` | self-rated health (1 excellent to 5 poor) |
| `high_bp` … `cancer` | 12 chronic conditions ever diagnosed (1 = yes) |
| `adl_help`, `iadl_help`, `walk_limit`, `bmi` | functioning and body mass index |
| `pcs`, `mcs`, `k6`, `phq2` | SF-12 physical and mental component scores, K6 and PHQ-2 (self-administered questionnaire) |
| `cost_2022` … `rx_2022` | 2022 spending, out-of-pocket spending, office visits, ER visits, stays, prescriptions |
| `*_miss` | 1 if that predictor was missing and filled with the training median |

Like the other files here, it is made from MEPS public use files and must not be
posted or shared beyond the people you work with.
