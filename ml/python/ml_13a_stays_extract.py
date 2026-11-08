"""ml_13a_stays_extract.py -- A length-of-stay data set from MEPS: one row per hospital stay of an
adult, 2021-2023, for chapter 13's model comparison (the MEPS analogue of the length-of-stay
models in the capstone).

Outcome: nights in hospital (NUMNIGHX) for each inpatient stay. MEPS's stay files have no
diagnosis-related group, so the diagnoses come the long way round: the condition-event link
file (CLNK) ties each stay to the conditions the household reported for it, and the
conditions file gives each condition's CCSR categories. The first three letters of a CCSR
category are its body system (CIR = circulatory, RSP = respiratory, ...), which plays the part
of the Major Diagnostic Category in hospital discharge data.

Predictors (all known at or before admission, or describing the person):
  stay:   year and month of admission, admitted through the ER (EMERROOM), stay for a specific
          condition (SPECCOND), reason for the stay (RSNINHOS: operation, treatment, tests,
          birth, pregnancy complication, other), any operation (ANYOPER), the body systems of
          the linked conditions (one 0/1 column each) and the number linked.
  person: age, sex, race and ethnicity, region, marital status, education, poverty, insurance,
          Medicare, Medicaid, usual source of care, self-rated physical and mental health,
          diagnosed chronic conditions, help with ADLs/IADLs, walking limits, PCS, MCS, K6.
Left out on purpose: payments and charges (known only after discharge, and they rise with
nights), discharge medicines (DSCHPMED), and the person's other use in the year (it includes
this stay).

Not redistributed (MEPS data use agreement): writes data/meps_stays.csv, which git ignores.

Files (MEPS public use files, Stata format; https://meps.ahrq.gov):
  2021: h229d (stays), h229if1 (condition-event links), h231 (conditions), h233 (full-year)
  2022: h239d, h239if1, h241, h243
  2023: h248d, h248if1, h249, h251

Usage:  python ml/python/ml_13a_stays_extract.py "C:/Users/YOU/folder/MEPS raw"

Eliot R. Weinstein
eliotw@uchicago.edu
erweinstein.com
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

meps_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("C:/Users/YOU/folder/MEPS raw")
out_file = Path("data/meps_stays.csv")
FILES = {2021: ("h229d", "h229if1", "h231", "h233"),
         2022: ("h239d", "h239if1", "h241", "h243"),
         2023: ("h248d", "h248if1", "h249", "h251")}
BODY = ["BLD", "CIR", "DEN", "DIG", "EAR", "END", "EXT", "EYE", "FAC", "GEN", "INF", "INJ", "MAL",
        "MBD", "MUS", "NEO", "NVS", "PNL", "PRG", "RSP", "SKN", "SYM"]


def rd(name, cols=None):
    return pd.read_stata(meps_dir / f"{name}.dta", convert_categoricals=False, columns=cols)


def neg_na(x):
    x = pd.to_numeric(x, errors="coerce").astype(float)
    return x.where(x >= 0)


def yn(x):
    x = neg_na(x)
    return (x == 1).astype(float).where(x.notna())


def lev(x, labs):
    x = neg_na(x)
    return x.map(lambda v: labs.get(int(v), "Missing") if pd.notna(v) else "Missing")


rows = []
for year, (f_ip, f_link, f_cond, f_fyc) in FILES.items():
    yy = year % 100
    ip = rd(f_ip, ["DUID", "DUPERSID", "EVNTIDX", "IPBEGYR", "IPBEGMM", "NUMNIGHX", "EMERROOM", "SPECCOND",
                   "RSNINHOS", "ANYOPER"])
    link = rd(f_link, ["DUPERSID", "CONDIDX", "EVNTIDX"])
    cond = rd(f_cond)
    ccsr = [c for c in cond.columns if c.startswith("CCSR") and c.endswith("X")]
    cl = link.merge(cond[["CONDIDX"] + ccsr], on="CONDIDX", how="inner")
    long = cl.melt(id_vars=["EVNTIDX", "CONDIDX"], value_vars=ccsr, value_name="ccsr")
    long = long[long.ccsr.astype(str).str.match(r"^[A-Z]{3}\d{3}$")]
    long["body"] = long.ccsr.str[:3]
    bs = (long.drop_duplicates(["EVNTIDX", "body"]).assign(v=1.0)
          .pivot_table(index="EVNTIDX", columns="body", values="v", fill_value=0.0))
    bs = bs.reindex(columns=BODY, fill_value=0.0).add_prefix("dx_")
    ip = ip.merge(bs, left_on="EVNTIDX", right_index=True, how="left")
    ip["n_conditions"] = ip.EVNTIDX.map(cl.groupby("EVNTIDX").CONDIDX.nunique())   # all linked conditions, coded or not

    fyc_cols = ["DUPERSID", "VARSTR", "VARPSU", f"PERWT{yy}F", f"AGE{yy}X", "SEX", "RACETHX", f"REGION{yy}",
                f"POVCAT{yy}", f"INSCOV{yy}", f"MARRY{yy}X", "HIDEG", f"MCREV{yy}", f"MCDEV{yy}", "HAVEUS42",
                "RTHLTH31", "MNHLTH31", "HIBPDX", "CHDDX", "ANGIDX", "MIDX", "OHRTDX", "STRKDX", "EMPHDX",
                "CHOLDX", "CANCERDX", "DIABDX_M18", "ARTHDX", "ASTHDX", "ADLHLP31", "IADLHP31", "WLKLIM31",
                "VPCS42", "VMCS42", "K6SUM42"]
    p = rd(f_fyc, fyc_cols)
    p = pd.DataFrame({
        "person": p.DUPERSID, "stratum": p.VARSTR, "psu": p.VARPSU, "weight": p[f"PERWT{yy}F"],
        "age": neg_na(p[f"AGE{yy}X"]), "female": (neg_na(p.SEX) == 2).astype(float),
        "race_eth": lev(p.RACETHX, {1: "Hispanic", 2: "White", 3: "Black", 4: "Asian", 5: "Other or multiple"}),
        "region": lev(p[f"REGION{yy}"], {1: "Northeast", 2: "Midwest", 3: "South", 4: "West"}),
        "marital": lev(p[f"MARRY{yy}X"], {1: "Married", 2: "Widowed", 3: "Divorced", 4: "Separated", 5: "Never married"}),
        "education": lev(p.HIDEG, {1: "No degree", 2: "GED", 3: "High school", 4: "Bachelor's", 5: "Master's",
                                   6: "Doctorate", 7: "Other degree"}),
        "poverty": lev(p[f"POVCAT{yy}"], {1: "Poor", 2: "Near poor", 3: "Low income", 4: "Middle income", 5: "High income"}),
        "insurance": lev(p[f"INSCOV{yy}"], {1: "Any private", 2: "Public only", 3: "Uninsured"}),
        "medicare": yn(p[f"MCREV{yy}"]), "medicaid": yn(p[f"MCDEV{yy}"]), "usual_source": yn(p.HAVEUS42),
        "health": neg_na(p.RTHLTH31), "mental_health": neg_na(p.MNHLTH31),
        "high_bp": yn(p.HIBPDX), "coronary": yn(p.CHDDX), "angina": yn(p.ANGIDX), "heart_attack": yn(p.MIDX),
        "other_heart": yn(p.OHRTDX), "stroke": yn(p.STRKDX), "emphysema": yn(p.EMPHDX), "high_chol": yn(p.CHOLDX),
        "cancer": yn(p.CANCERDX), "diabetes": yn(p.DIABDX_M18), "arthritis": yn(p.ARTHDX), "asthma": yn(p.ASTHDX),
        "adl_help": yn(p.ADLHLP31), "iadl_help": yn(p.IADLHP31), "walk_limit": yn(p.WLKLIM31),
        "pcs": neg_na(p.VPCS42), "mcs": neg_na(p.VMCS42), "k6": neg_na(p.K6SUM42)})
    s = ip.merge(p, left_on="DUPERSID", right_on="person", how="inner")
    s = pd.DataFrame({
        "stay": s.EVNTIDX.astype(str), "household": s.DUID, "year": neg_na(s.IPBEGYR), "file_year": year,
        **{c: s[c] for c in p.columns},
        "nights": neg_na(s.NUMNIGHX), "admit_month": neg_na(s.IPBEGMM),
        "via_er": yn(s.EMERROOM), "specific_condition": yn(s.SPECCOND), "any_operation": yn(s.ANYOPER),
        "reason": lev(s.RSNINHOS, {1: "Operation", 2: "Treatment", 3: "Tests only", 4: "Birth (mother)",
                                   5: "Born (baby)", 6: "Pregnancy complication", 91: "Other"}),
        **{c: s[c].fillna(0.0) for c in list(bs.columns) + ["n_conditions"]}})
    rows.append(s)

st = pd.concat(rows, ignore_index=True)
# A file holds the stays that ENDED in its year, so a stay that began in December and ended in January
# is in the next year's file. Count stays by the year they began: keep 2021-2023 admissions (a 2020
# admission in the 2021 file has lost its same-year partners). Only long stays begun late in 2023
# and still going in 2024 are missing (the 2024 file is not used).
st = st[(st.age >= 18) & st.nights.notna() & (st.nights >= 1) & (st.weight > 0) & (st.reason != "Born (baby)")
        & (st.year >= 2021)]
st = st.reset_index(drop=True)
st["year"] = st.year.astype(int)
st["log_nights"] = np.log(st.nights)
st["long_stay"] = (st.nights >= 7).astype(float)              # a week or more

# split by household (DUID is unique within a panel and keeps its value across years), as in ml_00
hh = st.household.astype(np.int64)
st["test"] = (((hh * 7919 + 104729) % 1000003) / 1000003 < 0.3).astype(int)
st["fold"] = np.where(st.test == 1, 0, np.floor(((hh * 15485863 + 32452843) % 999983) / 999983 * 5).astype(int) + 1)

for v in ["age", "medicare", "medicaid", "usual_source", "health", "mental_health", "high_bp", "coronary", "angina",
          "heart_attack", "other_heart", "stroke", "emphysema", "high_chol", "cancer", "diabetes", "arthritis",
          "asthma", "adl_help", "iadl_help", "walk_limit", "pcs", "mcs", "k6", "via_er", "specific_condition",
          "any_operation", "admit_month"]:
    m = st[v].isna()
    if m.mean() > 0.01:
        st[v + "_miss"] = m.astype(float)
    st.loc[m, v] = st.loc[st.test == 0, v].median()

out_file.parent.mkdir(exist_ok=True)
st.to_csv(out_file, index=False)
print(f"{out_file}: {len(st)} stays of {st.person.nunique()} adults in {st.household.nunique()} households; "
      f"{st.test.sum()} stays in the test set")
print("stays by year of admission:", st.year.value_counts().sort_index().to_dict(),
      "| begun in one year and ended in the next:", int((st.year < st.file_year).sum()))
print("nights: median", st.nights.median(), "mean", round(st.nights.mean(), 2), "max", st.nights.max(),
      "| a week or more:", round(100 * st.long_stay.mean(), 1), "%")
print("share of stays with at least one linked condition:", round(100 * (st.n_conditions > 0).mean(), 1), "%")
print(st[[c for c in st.columns if c.startswith("dx_")]].mean().sort_values(ascending=False).head(10).round(3).to_dict())

# ---- A second data set for chapter 13: high use of care in 2023 (the AIF360 MEPS example) ----------
# IBM's AI Fairness 360 toolkit ships a MEPS example (panels 19-21): "high utilization" is ten or more
# office visits + outpatient visits + ER visits + inpatient nights + home health visits in the year,
# and race (non-Hispanic White vs everyone else) is the protected attribute. The same definition on
# the 2023 full-year file, with the person predictors above (same year, as in AIF360):
p = rd("h251")
yy = 23
util = pd.DataFrame({
    "person": p.DUPERSID, "household": p.DUID, "stratum": p.VARSTR, "psu": p.VARPSU, "weight": p.PERWT23F,
    "age": neg_na(p.AGE23X), "female": (neg_na(p.SEX) == 2).astype(float),
    "race_eth": lev(p.RACETHX, {1: "Hispanic", 2: "White", 3: "Black", 4: "Asian", 5: "Other or multiple"}),
    "region": lev(p.REGION23, {1: "Northeast", 2: "Midwest", 3: "South", 4: "West"}),
    "marital": lev(p.MARRY23X, {1: "Married", 2: "Widowed", 3: "Divorced", 4: "Separated", 5: "Never married"}),
    "education": lev(p.HIDEG, {1: "No degree", 2: "GED", 3: "High school", 4: "Bachelor's", 5: "Master's",
                               6: "Doctorate", 7: "Other degree"}),
    "poverty": lev(p.POVCAT23, {1: "Poor", 2: "Near poor", 3: "Low income", 4: "Middle income", 5: "High income"}),
    "insurance": lev(p.INSCOV23, {1: "Any private", 2: "Public only", 3: "Uninsured"}),
    "employed": neg_na(p.EMPST31).isin([1, 2, 3]).astype(float),
    "usual_source": yn(p.HAVEUS42), "health": neg_na(p.RTHLTH31), "mental_health": neg_na(p.MNHLTH31),
    "high_bp": yn(p.HIBPDX), "coronary": yn(p.CHDDX), "angina": yn(p.ANGIDX), "heart_attack": yn(p.MIDX),
    "other_heart": yn(p.OHRTDX), "stroke": yn(p.STRKDX), "emphysema": yn(p.EMPHDX), "high_chol": yn(p.CHOLDX),
    "cancer": yn(p.CANCERDX), "diabetes": yn(p.DIABDX_M18), "arthritis": yn(p.ARTHDX), "asthma": yn(p.ASTHDX),
    "adl_help": yn(p.ADLHLP31), "iadl_help": yn(p.IADLHP31), "walk_limit": yn(p.WLKLIM31),
    "act_limit": yn(p.ACTLIM31), "cog_limit": yn(p.COGLIM31),
    "pcs": neg_na(p.VPCS42), "mcs": neg_na(p.VMCS42), "k6": neg_na(p.K6SUM42), "phq2": neg_na(p.PHQ242)})
use = sum(neg_na(p[v]).fillna(0) for v in ["OBTOTV23", "OPTOTV23", "ERTOT23", "IPNGTD23", "HHTOTD23"])
util["utilization"] = use
util["high_use"] = (use >= 10).astype(float)
util["white_nh"] = (util.race_eth == "White").astype(float)       # AIF360's privileged group
util = util[(util.age >= 18) & (util.weight > 0)].reset_index(drop=True)
hh = util.household.astype(np.int64)
util["test"] = (((hh * 7919 + 104729) % 1000003) / 1000003 < 0.3).astype(int)
util["fold"] = np.where(util.test == 1, 0, np.floor(((hh * 15485863 + 32452843) % 999983) / 999983 * 5).astype(int) + 1)
for v in ["usual_source", "health", "mental_health", "high_bp", "coronary", "angina", "heart_attack", "other_heart",
          "stroke", "emphysema", "high_chol", "cancer", "diabetes", "arthritis", "asthma", "adl_help", "iadl_help",
          "walk_limit", "act_limit", "cog_limit", "pcs", "mcs", "k6", "phq2"]:
    m = util[v].isna()
    if m.mean() > 0.01:
        util[v + "_miss"] = m.astype(float)
    util.loc[m, v] = util.loc[util.test == 0, v].median()
util.to_csv("data/meps_util_2023.csv", index=False)
w = util.weight
print(f"data/meps_util_2023.csv: {len(util)} adults; high use (>= 10 visits + nights) weighted "
      f"{100 * np.average(util.high_use, weights=w):.1f}%: White non-Hispanic "
      f"{100 * np.average(util.high_use[util.white_nh == 1], weights=w[util.white_nh == 1]):.1f}%, others "
      f"{100 * np.average(util.high_use[util.white_nh == 0], weights=w[util.white_nh == 0]):.1f}%")
