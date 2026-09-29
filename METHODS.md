# Methods

This project applies the Peterson-Milbank *Consensus Administrative Specifications for Health Care Cost
Driver Analyses* (June 2025) to CMS's synthetic Medicare FFS claims. The data is fully synthetic: no real
patients, providers or payments.

The SQL in `sql/01`–`06` runs in order. It expects each CMS file loaded as a table with its original column
names (`beneficiary`, `inpatient`, `outpatient`, `carrier`, `snf`, `hha`, `hospice`, `dme`, `pde`), with
every column as text, plus the three code lists in `reference/` loaded as tables of the same name. The SQL
casts numbers and dates itself and sticks to standard SQL.

## Study population and period
- **Years:** 2016–2022. 2015 is the first file year, and 2023 claims stop in the spring.
- **Denominator:** member months from the monthly enrollment arrays (`sql/01_member_months.sql`). A month
  counts when the beneficiary has Part A **and** Part B (`MDCR_ENTLMT_BUYIN_IND` = 3 or C) and is not in
  Medicare Advantage (`HMO_IND` null or 0). Retail pharmacy uses the subset of those months that also have
  Part D.
- **Why monthly and not the annual counts:** the annual `BENE_HI/SMI_CVRAGE_TOT_MONS` fields count A and B
  separately. Taking the smaller of the two overstates A+B months by about 6% (625K vs 589K), because it
  can't tell whether A and B overlapped in the same month.
- Claims only count if they fall in an eligible month for that beneficiary. That keeps 93–100% of dollars,
  depending on the file (validation check 4).

## Dollars
The specs measure **allowed** amounts. The RIF reports allowed amounts directly only on carrier and DME
lines, so the other files approximate it:

| File | Allowed amount used |
|---|---|
| Carrier, DME | `LINE_ALOWD_CHRG_AMT` |
| Inpatient, SNF | Medicare paid + Part A deductible + coinsurance + blood deductible |
| Outpatient | Medicare paid + Part B deductible + coinsurance + blood deductible |
| HHA, hospice | Medicare paid (no beneficiary cost sharing on the claim) |
| PDE | `TOT_RX_CST_AMT` (gross drug cost) |

Primary payer paid amounts are excluded. Only claims where Medicare paid as primary are kept (blank MSP
code), which is how the primary care spec's Step 1 "paid as primary" rule maps onto the RIF.

## Service categories (`sql/03_service_categories.sql`)
There are six topline categories: Inpatient Hospital, Outpatient Hospital, Professional, Long-Term Care,
Retail Pharmacy and Other. Each row gets one topline category plus the spec's subcategory
("place of setting"). The first two characters of the bill type come from `CLM_FAC_TYPE_CD` +
`CLM_SRVC_CLSFCTN_TYPE_CD`. Professional lines are split out by place of service.

The spec says consistent topline categories matter most. Its topline table puts all CMS-1500 spend in
Professional, including professional services during a facility stay, so the topline category is set by
claim form first.

**Judgment calls.** In each case the spec is ambiguous or the RIF lacks the field:
1. **Home health (bill type 32/33/34) goes to Professional / Home health.** That's where the spec's
   code table puts it, even though its topline table lists HCBS under Long-Term Care. A state could
   reasonably decide the other way.
2. **Bill type 81/82 is treated as hospice.** The spec lists it as both "independent lab" and "hospice".
   In Medicare, 81x/82x is hospice.
3. **DME goes to Other.** DME suppliers aren't facilities or physician services.


## Primary care (`sql/05_primary_care.sql`)
This follows the spec's Steps 1–6 and its Medicare RIF guidance:
1. The claim was paid as primary (see Dollars).
2. The HCPCS/CPT code is in Appendix A (`reference/pc_service_codes.csv`, 133 codes; code lists only, no AMA
   descriptors).
3. The provider has a primary care specialty. This uses the spec's RIF option 1, the as-reported CMS
   2-character specialty codes 01, 08, 11, 37, 50 and 97.
4. The place of service is in Appendix C.
5. Drop physicians with no wellness visits. This step is implemented with a guard: the synthetic
   carrier file has **no** wellness visits, so the rule would drop every physician. It's skipped, and
   validation check 7 reports that it was skipped.
6. Add provider-based-billing facility lines (G0463 on 13x the same day as an office visit at POS 19/22)
   and FQHC 77x claims. The logic runs, but the synthetic outpatient file has neither, so this step
   returns 0 rows.

The spec leaves the "total spending" denominator to the analyst, so the output reports both versions:
share of medical (non-pharmacy) spend, and share of total spend including pharmacy.

## Inpatient: volume vs. price (`sql/07_dashboard_facts.sql`)
Inpatient PMPM = stays per member month × allowed dollars per stay, so its change splits into a volume part
and a price part. The dashboard uses the midpoint split, which adds up exactly:
- volume = (change in stays per member month) × (average of the two years' cost per stay)
- price = (change in cost per stay) × (average of the two years' stays per member month)

For 2016 to 2022, that's +$46 PMPM from more stays and +$139 from a higher allowed cost per stay. One inpatient
claim is counted as one stay. "Price" here means allowed dollars per stay, so it includes case mix and length
of stay as well as payment rates. Separating those would take DRG weights and length of stay, the next layer
of the analysis.

## Results (synthetic data)

| Year | A+B FFS member months | Medical PMPM | Rx PMPM | Total PMPM | Growth | Primary care % of medical |
|---|---|---|---|---|---|---|
| 2016 | 71,160 | $1,478 | $179 | $1,657 | | 1.94% |
| 2017 | 74,844 | $1,613 | $181 | $1,794 | +8.3% | 1.77% |
| 2018 | 79,188 | $1,616 | $191 | $1,807 | +0.7% | 1.78% |
| 2019 | 84,192 | $1,444 | $192 | $1,637 | −9.4% | 2.03% |
| 2020 | 88,632 | $1,573 | $196 | $1,769 | +8.1% | 1.84% |
| 2021 | 93,264 | $1,646 | $192 | $1,838 | +3.9% | 1.77% |
| 2022 | 98,100 | $1,782 | $205 | $1,987 | +8.1% | 1.73% |

From 2016 to 2022, total PMPM rose $331. Inpatient added $185 of that and outpatient added $105.

## What the validation checks flagged
These are features of the synthetic file, reported rather than hidden:
- **Dialysis is a large share of outpatient.** Dialysis claims (90935) make up 31% of outpatient dollars,
  and outpatient is the largest category.
- **No office E&M visits (99202–99215) on carrier lines,** and every carrier line has specialty 01. Office
  visits are the core of the primary care definition, so primary care share (~1.8%) mostly reflects
  transitional care management and screening codes.
- **No wellness visits, G0463 facility lines or FQHC claims,** so Steps 5 and 6 run but don't change
  anything.
- **The population is 47% under 65** by member months.
