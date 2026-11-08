# Notes for the poster and paper on this project

Eliot R. Weinstein · 8 November 2026

## A pull-out box on institutions (requested for both the poster and the paper)

Both the poster and the paper should have a highlighted box that sets out what
MEPS can and cannot say about institutions, and what AHRQ's Compendium of U.S.
Health Systems adds. Source for every number: `docs/MEPS_and_institutions.md`
(scripts `R/14`-`R/18`). A first draft of the box (2023 unless noted):

**MEPS is a survey of people, not institutions**

- **Hospitals.** MEPS sees them only as settings: inpatient, outpatient and ER
  care were 37% of spending, and 6.4% of people had a stay. MEPS captures
  82-91% of the discharges hospitals report to CMS.
- **Health systems** (e.g., Banner, Intermountain). Not in MEPS at all. The
  Compendium lists 639; 76% of acute hospitals, with 97% of acute discharges,
  and 62% of physicians billing Medicare (2022) are in one.
- **Managed care.** MEPS has MA and HMO flags, but not the plan. 13% of MA
  enrollees are in a health system's plan (29% in the West, 4% in the South).
  MEPS's MA reports fell from about equal to CMS's counts (2016) to 78-92% of
  them (2023).
- **ACOs.** Not in MEPS. Most systems participated (2016-2018).
- **LTACHs, SNFs, nursing homes.** Out of MEPS's scope (it covers people only
  while they are not in an institution). One in three LTACHs, but only 6% of
  nursing homes, are in systems.
- **The only public link** between MEPS and institutions is the Census region
  and year. State or county links need restricted MEPS files.
- **Who the big systems are** (section 2.1 of the note): HCA alone has 1.9
  million discharges a year, 2.5 times the next system (CommonSpirit); Kaiser
  Permanente runs 1.9 million MA enrollees' plans, 6% of all MA enrollment.
- **Read the trends with the events in mind** (section 2.2): one spin-off
  (Quorum Health) explains half of the 2018-2020 rise in the share of acute
  hospitals in systems; one new system (ScionHealth) doubled the share of
  LTACHs in systems in 2022; one sale (ProMedica's nursing homes) explains
  about half of the fall in system-owned nursing homes.

Design notes: keep it to five or six lines on the poster (one per institution
type, with an icon or a mark for "in MEPS / Compendium only / linked"); the
paper can use the full table in `docs/MEPS_and_institutions.md`, section 1.
