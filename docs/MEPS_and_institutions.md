# What MEPS can and cannot tell you about hospitals, health systems, plans and facilities

Eliot R. Weinstein · eliotw@uchicago.edu · erweinstein.com
7 November 2026

MEPS is a survey of *people*. Its Household Component (HC) follows a sample of
the U.S. civilian noninstitutionalized population and records their care,
coverage and spending. Institutions (hospitals, plans, facilities) appear only
as the *places* where that care happened or the *payers* that covered it. No
public MEPS file names or identifies a specific hospital, health system, plan or
facility. The figures below are from the 2023 files (Full Year Consolidated file
HC-251 and the event files HC-248D-H), weighted to the national population.

## By institution type

| Institution type | In the public MEPS files? | What there is |
|---|---|---|
| **Hospitals** (care setting) | Yes, as a setting, not by name | Inpatient stays (HC-248D: nights, whether the stay began in the ER, reason, surgery, facility and doctor payments by payer), outpatient department visits (HC-248F) and ER visits (HC-248E). In 2023 these three settings were 37% of all spending ($930 bn of $2.5 tn), 33% for the facility part alone. 6.4% of people had a stay, 14% an ER visit and 24% an outpatient department visit. About 160 of HC-251's 1,374 variables are about these three settings. |
| **Health systems** (e.g., Banner Health, Intermountain Health), **medical centers** | No | No provider or system identifiers. The Medical Provider Component (MPC) contacts the hospitals and doctors people report, but only to improve the spending data ("not designed to yield national estimates", HC-251 documentation). Provider-level data are not public. To study systems, AHRQ's *Compendium of U.S. Health Systems* (2016-2023) lists systems and links them to their hospitals, which can then be matched to hospital-level data (e.g., CMS cost reports), but not to MEPS respondents. |
| **Managed care organizations** (HMOs, Medicare Advantage, Medicaid managed care) | Partly | About 30 managed-care variables: private HMO, Medicare managed care / Medicare Advantage (`MCRPHO`), Medicaid/CHIP HMO (`MCDHMO`), other public HMO. Weighted 2023 shares: 42% of people with Medicare in Medicare Advantage, 31% of the privately insured in an HMO, 28% of Medicaid enrollees in a Medicaid HMO. These are household reports and are lower than administrative counts (KFF puts Medicare Advantage at more than half of eligible beneficiaries from 2023; CMS publishes Medicaid managed care shares). The plan itself is not identified. |
| **ACOs** | No | No ACO variables; attribution to an ACO is not something a household can report. |
| **Skilled nursing facilities, nursing homes, LTACHs, other institutions** | Essentially no | The HC covers people only while they are not in an institution. Someone who enters a nursing home or other health care institution during the year has data only for the period when they were in scope ("data are collected for the period during which that person is classified as eligible", HC-251 documentation). Institutional care is therefore missing from MEPS spending. A long-term acute care hospital (LTACH) stay, if reported, would be an inpatient stay that cannot be told apart from others. MEPS had a separate Nursing Home Component only in 1996. |
| **Home health agencies** | Yes, as a setting | Agency and non-agency home health (HC-248H; about 30 HC-251 variables): 4.5% of 2023 spending, 2.8% of people used agency care. |
| **VA, TRICARE, Indian Health Service** | As payers or coverage | Coverage by month and payments by the VA/CHAMPVA and TRICARE for every setting; VA facilities are not separated from others. |

## What this means for the guide

- MEPS is well suited to questions about **people**: spending, use, coverage
  and outcomes, by setting and by payer. It is not suited to questions about
  **institutions**: system affiliation, hospital quality, ACO or plan effects,
  or post-acute and long-term care.
- For institution-level work, link institution data sources (AHRQ's Compendium,
  CMS cost reports and Provider of Services files, AHA survey data) at the
  institution level, or use claims data with provider identifiers. The
  Healthcare Cost and Utilization Project (HCUP, also from AHRQ) has hospital
  identifiers in some of its databases.
- Restricted MEPS files with more detail (for example, linked MPC data) can be
  used only through AHRQ's data center, under a separate agreement.

**Sources:** MEPS HC-251 documentation (2023 Full Year Consolidated file),
sections on the Medical Provider Component and person eligibility; the 2023
HC-251 and HC-248D-H public use files (our tabulation, weighted by `PERWT23F`);
AHRQ, *Compendium of U.S. Health Systems* (ahrq.gov/chsp); KFF, "Medicare
Advantage in 2023: Enrollment Update and Key Trends"; CMS, "Share of Medicaid
Enrollees in Managed Care" (data.cms.gov / catalog.data.gov).
