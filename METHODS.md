# Methods

This project applies the Peterson-Milbank *Consensus Administrative Specifications for Health Care Cost
Driver Analyses* (June 2025) to CMS's synthetic Medicare FFS claims. The synthetic file is built for
testing code, not for estimating anything, so the output below demonstrates the method. The dollar levels
aren't real-world benchmarks.

The SQL in `sql/01`–`06` runs in order against DuckDB. The loader and runner scripts live in the [full build repo](https://github.com/Leonard-Rule/medicare-cost-drivers).

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
4. **BETOS stands in for RBCS.** The RIF doesn't carry RBCS, so type of service for professional lines
   uses the first letter of BETOS, which RBCS replaced.
5. **Unit of analysis:** institutional files are counted at the claim level, because the RIF repeats
   header dollars on every revenue line. The spec wants line-level outpatient, but in this synthetic file
   99.9% of outpatient lines are the 0001 total line, so header dollars are more complete.

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

## Data limitations found (validation checks flagged FLAG)
- **Outpatient is inflated.** It runs about $1,000 PMPM, versus roughly $150–250 in real Medicare FFS.
  Dialysis claims (90935) make up 31% of outpatient dollars.
- **No office E&M visits (99202–99215) on carrier lines,** and every carrier line has specialty 01. Real
  Medicare primary care is mostly office visits, so primary care share (~1.8%) is well below most published
  estimates for Medicare. The primary care spend that does show up is mostly transitional care
  management and screening codes.
- **No wellness visits, G0463 facility lines or FQHC claims,** so Steps 5 and 6 run but don't change
  anything.
- **The population skews under 65:** 47% of member months, versus roughly 12% in real Medicare. This comes
  from how the synthetic file was generated.

Each of these would be the first thing to recheck on real RIF or APCD data. The SQL doesn't need to
change for that.
