"""ml_00_extract.py -- Python version of ml/R/ml_00_extract.R: the machine learning data set
(predict 2023 use and spending from 2022 characteristics, adults in MEPS Panel 27).

It writes the same data/meps_ml.csv as the R script (same rows, columns, split and folds),
so either can be used. See the R script's header for the design and the variables.

Usage:  python ml/python/ml_00_extract.py "C:/Users/YOU/folder/MEPS 2023"

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

meps_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("C:/Users/YOU/folder/MEPS 2023")
out_file = Path("data/meps_ml.csv")
panel_file = "h252"

d = pd.read_stata(meps_dir / f"{panel_file}.dta", convert_categoricals=False)


def neg_na(x):
    x = pd.to_numeric(x, errors="coerce").astype(float)
    return x.where(x >= 0)


def yn(x):                          # 1 = yes, 2 = no -> 1/0, missing stays missing
    x = neg_na(x)
    return (x == 1).astype(float).where(x.notna())


def lev(x, labs):
    x = neg_na(x)
    out = x.map(lambda v: labs.get(int(v), "Missing") if pd.notna(v) else "Missing")
    return pd.Categorical(out, categories=list(labs.values()) + ["Missing"])


d = d[(neg_na(d.AGEY1X) >= 18) & (d.ALL5RDS == 1) & (d.LONGWT > 0)].reset_index(drop=True)

ml = pd.DataFrame({
    "person": d.DUPERSID, "household": d.DUID,
    "weight": d.LONGWT, "stratum": d.VARSTR, "psu": d.VARPSU,
    "cost": neg_na(d.TOTEXPY2),
    "ob_visits": neg_na(d.OBTOTVY2),
    "any_er": (neg_na(d.ERTOTY2) > 0).astype(float),
    "any_ip": (neg_na(d.IPDISY2) > 0).astype(float),
    "age": neg_na(d.AGEY1X),
    "female": (neg_na(d.SEX) == 2).astype(float),
    "race_eth": lev(d.RACETHX, {1: "Hispanic", 2: "White", 3: "Black", 4: "Asian", 5: "Other or multiple"}),
    "region": lev(d.REGIONY1, {1: "Northeast", 2: "Midwest", 3: "South", 4: "West"}),
    "marital": lev(d.MARRYY1X, {1: "Married", 2: "Widowed", 3: "Divorced", 4: "Separated", 5: "Never married"}),
    "education": lev(d.HIDEG, {1: "No degree", 2: "GED", 3: "High school", 4: "Bachelor's", 5: "Master's",
                               6: "Doctorate", 7: "Other degree"}),
    "poverty": lev(d.POVCATY1, {1: "Poor", 2: "Near poor", 3: "Low income", 4: "Middle income", 5: "High income"}),
    "insurance": lev(d.INSCOVY1, {1: "Any private", 2: "Public only", 3: "Uninsured"}),
    "medicare": yn(d.MCREVY1), "medicaid": yn(d.MCDEVY1),
    "employed": neg_na(d.EMPST2).isin([1, 2, 3]).astype(float),
    "usual_source": yn(d.HAVEUS2),
    "health": neg_na(d.RTHLTH2), "mental_health": neg_na(d.MNHLTH2),
    "high_bp": yn(d.HIBPDXY1), "diabetes": yn(d.DIABDXY1_M18), "arthritis": yn(d.ARTHDXY1),
    "asthma": yn(d.ASTHDXY1), "coronary": yn(d.CHDDXY1), "heart_attack": yn(d.MIDXY1),
    "angina": yn(d.ANGIDXY1), "other_heart": yn(d.OHRTDXY1), "stroke": yn(d.STRKDXY1),
    "emphysema": yn(d.EMPHDXY1), "high_chol": yn(d.CHOLDXY1), "cancer": yn(d.CANCERY1),
    "adl_help": yn(d.ADLHLP1), "iadl_help": yn(d.IADLHP1), "walk_limit": yn(d.WLKLIM1),
    "bmi": neg_na(d.ADBMI2),
    "pcs": neg_na(d.VPCS2), "mcs": neg_na(d.VMCS2), "k6": neg_na(d.K6SUM2), "phq2": neg_na(d.PHQ22),
    "cost_2022": neg_na(d.TOTEXPY1), "oop_2022": neg_na(d.TOTSLFY1),
    "ob_visits_2022": neg_na(d.OBTOTVY1), "er_visits_2022": neg_na(d.ERTOTY1),
    "stays_2022": neg_na(d.IPDISY1), "rx_2022": neg_na(d.RXTOTY1),
})
ml = ml[ml.cost.notna()].reset_index(drop=True)

# split by household, as a fixed function of the ID (same as the R script)
hh = ml.household.astype(np.int64)
u_test = ((hh * 7919 + 104729) % 1000003) / 1000003
u_fold = ((hh * 15485863 + 32452843) % 999983) / 999983
ml["test"] = (u_test < 0.3).astype(int)
ml["fold"] = np.where(ml.test == 1, 0, np.floor(u_fold * 5).astype(int) + 1)

# top 10% of spenders, weighted
o = np.argsort(ml.cost.values, kind="mergesort")
cw = np.cumsum(ml.weight.values[o]) / ml.weight.sum()
cut90 = ml.cost.values[o][np.argmax(cw >= 0.9)]
ml["high_cost"] = (ml.cost >= cut90).astype(float)
ml["log_cost"] = np.log1p(ml.cost)

num = ["age", "medicare", "medicaid", "usual_source", "health", "mental_health", "high_bp", "diabetes",
       "arthritis", "asthma", "coronary", "heart_attack", "angina", "other_heart", "stroke", "emphysema",
       "high_chol", "cancer", "adl_help", "iadl_help", "walk_limit", "bmi", "pcs", "mcs", "k6", "phq2",
       "cost_2022", "oop_2022", "ob_visits_2022", "er_visits_2022", "stays_2022", "rx_2022"]
for v in num:
    m = ml[v].isna()
    if m.mean() > 0.01:
        ml[v + "_miss"] = m.astype(float)
    ml.loc[m, v] = ml.loc[ml.test == 0, v].median()

first = ["person", "household", "weight", "stratum", "psu", "test", "fold", "cost", "high_cost", "log_cost"]
ml = ml[first + [c for c in ml.columns if c not in first]]
out_file.parent.mkdir(exist_ok=True)
ml.to_csv(out_file, index=False)
print(f"{out_file}: {len(ml)} adults, {ml.test.sum()} in the test set; top-10% cut-off ${cut90:,.0f}; {ml.shape[1]} columns")
