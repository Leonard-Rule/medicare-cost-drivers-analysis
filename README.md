# Medicare Cost Drivers: Where Does the Money Go?

**Question:** In a Medicare fee-for-service population, how much is spent per member per month (PMPM), which
kinds of care drive that spending and its growth, and how much of it goes to primary care?

**Approach:** I applied the published Peterson-Milbank *consensus cost-driver specifications* (June 2025), the
standard that state cost growth target programs use, to CMS's public synthetic Medicare claims for 2016–2022.
The analysis is written in SQL. The results are shown in an interactive D3 dashboard and a Tableau workbook.

This repo holds the final pieces: the SQL, the result tables and the dashboard. The full build (data loading,
Python runner, Tableau generator and the raw claims files) is in
**[medicare-cost-drivers](https://github.com/Leonard-Rule/medicare-cost-drivers)**.

> Built only from public specifications and public synthetic data. The synthetic claims are made for testing
> code, not for estimating anything, so treat the dollar amounts as a demonstration of the method rather
> than real Medicare benchmarks.

![Allowed PMPM by service category](charts/pmpm_by_category.png)

## What I found

| Year | Avg. members | Medical PMPM | Pharmacy PMPM | Total PMPM | Change | Primary care share |
|---|---|---|---|---|---|---|
| 2016 | 5,930 | $1,478 | $179 | $1,657 | | 1.94% |
| 2017 | 6,237 | $1,613 | $181 | $1,794 | +8.3% | 1.77% |
| 2018 | 6,599 | $1,616 | $191 | $1,807 | +0.7% | 1.78% |
| 2019 | 7,016 | $1,444 | $192 | $1,637 | −9.4% | 2.03% |
| 2020 | 7,386 | $1,573 | $196 | $1,769 | +8.1% | 1.84% |
| 2021 | 7,772 | $1,646 | $192 | $1,838 | +3.9% | 1.77% |
| 2022 | 8,175 | $1,782 | $205 | $1,987 | +8.1% | 1.73% |

1. **Spending per member rose $331 a month (+20%) from 2016 to 2022,** about 3.1% a year.
2. **Hospital care drove the growth.** Inpatient added $185 PMPM and outpatient added $105. Together that's
   nearly 90% of the increase, so those are the first places to look.

   ![Change in PMPM by category](charts/pmpm_change_by_category.png)
3. **Primary care is under 2% of medical spending.** That's far below published Medicare estimates, and the
   reason is the data: the synthetic file has no office visits, which make up most real primary care.
4. **Every reconciliation check passed.** Four checks are flagged as known gaps in the synthetic data rather
   than hidden (see [results/validation.csv](results/validation.csv)).

## See it

**Interactive dashboard (D3):** download this repo (green **Code** button → **Download ZIP**), unzip it and
double-click `dashboard/index.html`. It opens in any browser with no install or internet connection. Use the
filters at the top (Medicaid dual status, age, sex) and click a year's bar to see its subcategories.

**Tableau:** the workbook reads [results/tableau_data.csv](results/tableau_data.csv).

## What's here

```
sql/         the analysis, run in order 01 → 06 (DuckDB SQL)
results/     output tables (CSV)
reference/   Milbank primary care code lists (codes only)
dashboard/   D3 dashboard: index.html + its data and the D3 library
charts/      static charts used above
METHODS.md   every definition and judgment call, and the data limitations
```

### The SQL
| File | What it does |
|---|---|
| `01_member_months.sql` | Turns each person's 12 monthly enrollment flags into one row per person per month, and keeps months with Part A and B in traditional Medicare. These member months are the denominator for every PMPM. |
| `02_claim_lines.sql` | Stacks the nine claim files (inpatient, outpatient, physician, SNF, home health, hospice, DME, Part D) into one table with the same columns and one dollar definition (allowed amount). |
| `03_service_categories.sql` | Puts every claim into one of six Milbank categories (inpatient, outpatient, professional, long-term care, retail pharmacy, other) and a subcategory, then keeps only claims that fall in a month the person was enrolled. |
| `04_pmpm.sql` | PMPM by category and year, year-over-year growth, annual growth rate, and the summary tables the dashboard uses. |
| `05_primary_care.sql` | The Milbank primary care definition, Steps 1–6: which service codes, provider specialties and places of service count as primary care. |
| `06_validation.sql` | 20+ checks that nothing was lost or double counted: row counts, dollar totals, eligibility match, and a rebuild of PMPM from the summary tables. |

### The results
| File | One row per |
|---|---|
| `pmpm_total.csv` | year: medical, pharmacy and total PMPM, growth |
| `pmpm_by_category.csv` | year × service category: dollars, member months, PMPM |
| `pmpm_growth.csv` | year × service category: year-over-year change and growth rate since 2016 |
| `primary_care_by_year.csv` | year: primary care dollars, PMPM, share of medical and total spending |
| `primary_care_by_service.csv` | year × primary care service group |
| `member_months_by_year.csv` | year: member months, average members, % dual eligible |
| `spend_fact.csv`, `mm_fact.csv`, `pc_fact.csv` | detailed building blocks (by year, category and demographic group) that the dashboard adds up |
| `tableau_data.csv` | the three building-block tables stacked into one file for Tableau |
| `validation.csv` | one row per quality check, with PASS or FLAG |

**How PMPM works here:** PMPM = total allowed dollars ÷ total member months, for whatever group you pick.
Because the building-block tables keep dollars and member months separate, any filter combination gives a
correct PMPM, and check 6 confirms the dashboard numbers match the SQL exactly.

## Data and sources
- **Claims:** CMS Synthetic Medicare Enrollment, Fee-for-Service Claims and Prescription Drug Event data
  (data.cms.gov, 2023 release). 10,000 synthetic people. Study years 2016–2022.
- **Method:** Peterson-Milbank Program for Sustainable Health Care Costs, *Consensus Administrative
  Specifications for Health Care Cost Driver Analyses* and *Cost Growth Target* specifications (June 2025).

Leo Rule · [leorule.com](https://leorule.com)
