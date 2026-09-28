-- Step 2a: One standardized spend table across all nine claim files.
-- Unit of analysis follows the Milbank service-category spec:
--   * institutional files (inpatient, outpatient, SNF, HHA, hospice): one row per claim (header dollars).
--     The RIF repeats the header on every revenue line, so collapse to CLM_ID first.
--     (Outpatient is a line-level unit in the spec, but in this synthetic file 99.9% of lines are the
--     0001 total line and revenue-line dollars don't sum to the header, so header dollars are used.)
--   * carrier and DME: one row per claim line (line allowed amount).
--   * PDE: one row per prescription fill.
--
-- Dollars: the specs use ALLOWED amounts.
--   carrier/DME: LINE_ALOWD_CHRG_AMT (reported directly)
--   institutional: Medicare paid + beneficiary deductible + coinsurance + blood deductible
--   PDE: TOT_RX_CST_AMT (gross drug cost: plan + patient + subsidies)
-- Primary payer paid (NCH_PRMRY_PYR_CLM_PD_AMT) is left out; see spec "claims paid as primary" below.
--
-- Primary care spec Step 1 ("claims paid as primary"): the RIF has no 01/19 claim status code, so
-- medicare_primary = the Medicare Secondary Payer code is blank (Medicare paid first).

CREATE OR REPLACE MACRO dt(x) AS TRY_STRPTIME(x, '%d-%b-%Y')::DATE;
CREATE OR REPLACE MACRO amt(x) AS coalesce(TRY_CAST(x AS DOUBLE), 0);

CREATE OR REPLACE TABLE claim_line AS
WITH inst AS (
  -- Institutional headers. any_value() is safe: header fields are identical on every line of a claim.
  SELECT 'inpatient' AS src, CLM_ID, any_value(BENE_ID) BENE_ID, any_value(CLM_FROM_DT) from_dt,
         any_value(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD) bill_type2,
         any_value(NCH_PRMRY_PYR_CD) msp_cd, any_value(CLM_MDCR_NON_PMT_RSN_CD) nonpay_cd,
         any_value(amt(CLM_PMT_AMT)) paid,
         any_value(amt(NCH_BENE_IP_DDCTBL_AMT) + amt(NCH_BENE_PTA_COINSRNC_LBLTY_AM)
                   + amt(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM)) cost_share
  FROM inpatient GROUP BY CLM_ID
  UNION ALL
  SELECT 'outpatient', CLM_ID, any_value(BENE_ID), any_value(CLM_FROM_DT),
         any_value(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD),
         any_value(NCH_PRMRY_PYR_CD), any_value(CLM_MDCR_NON_PMT_RSN_CD),
         any_value(amt(CLM_PMT_AMT)),
         any_value(amt(NCH_BENE_PTB_DDCTBL_AMT) + amt(NCH_BENE_PTB_COINSRNC_AMT)
                   + amt(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM))
  FROM outpatient GROUP BY CLM_ID
  UNION ALL
  SELECT 'snf', CLM_ID, any_value(BENE_ID), any_value(CLM_FROM_DT),
         any_value(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD),
         any_value(NCH_PRMRY_PYR_CD), any_value(CLM_MDCR_NON_PMT_RSN_CD),
         any_value(amt(CLM_PMT_AMT)),
         any_value(amt(NCH_BENE_IP_DDCTBL_AMT) + amt(NCH_BENE_PTA_COINSRNC_LBLTY_AM)
                   + amt(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM))
  FROM snf GROUP BY CLM_ID
  UNION ALL
  SELECT 'hha', CLM_ID, any_value(BENE_ID), any_value(CLM_FROM_DT),
         any_value(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD),
         any_value(NCH_PRMRY_PYR_CD), any_value(CLM_MDCR_NON_PMT_RSN_CD),
         any_value(amt(CLM_PMT_AMT)), 0            -- no beneficiary cost sharing for home health
  FROM hha GROUP BY CLM_ID
  UNION ALL
  SELECT 'hospice', CLM_ID, any_value(BENE_ID), any_value(CLM_FROM_DT),
         any_value(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD),
         any_value(NCH_PRMRY_PYR_CD), any_value(CLM_MDCR_NON_PMT_RSN_CD),
         any_value(amt(CLM_PMT_AMT)), 0            -- hospice copays aren't on the claim
  FROM hospice GROUP BY CLM_ID
)
SELECT src, BENE_ID AS bene_id, CLM_ID AS clm_id, NULL::INT AS line_num,
       dt(from_dt) AS svc_dt, bill_type2, NULL AS pos_cd, NULL AS spclty, NULL AS hcpcs_cd,
       NULL AS betos_cd, NULL AS rndrng_npi, NULL AS ndc,
       paid, paid + cost_share AS allowed,
       coalesce(trim(msp_cd), '') = '' AS medicare_primary,
       coalesce(trim(nonpay_cd), '') = '' AS medicare_paid
FROM inst
UNION ALL
SELECT 'carrier', BENE_ID, CLM_ID, TRY_CAST(LINE_NUM AS INT), dt(LINE_1ST_EXPNS_DT), NULL,
       LINE_PLACE_OF_SRVC_CD, PRVDR_SPCLTY, HCPCS_CD, BETOS_CD, PRF_PHYSN_NPI, NULL,
       amt(LINE_NCH_PMT_AMT), amt(LINE_ALOWD_CHRG_AMT),
       coalesce(trim(LINE_BENE_PRMRY_PYR_CD), '') = '',
       coalesce(LINE_PRCSG_IND_CD, 'A') = 'A'      -- A = allowed; other codes are denials/rejects
FROM carrier
UNION ALL
SELECT 'dme', BENE_ID, CLM_ID, TRY_CAST(LINE_NUM AS INT), dt(LINE_1ST_EXPNS_DT), NULL,
       LINE_PLACE_OF_SRVC_CD, PRVDR_SPCLTY, HCPCS_CD, BETOS_CD, NULL, LINE_NDC_CD,
       amt(LINE_NCH_PMT_AMT), amt(LINE_ALOWD_CHRG_AMT),
       coalesce(trim(LINE_BENE_PRMRY_PYR_CD), '') = '',
       coalesce(LINE_PRCSG_IND_CD, 'A') = 'A'
FROM dme
UNION ALL
SELECT 'pde', BENE_ID, PDE_ID, NULL, dt(SRVC_DT), NULL, NULL, NULL, NULL, NULL, NULL, PROD_SRVC_ID,
       amt(CVRD_D_PLAN_PD_AMT), amt(TOT_RX_CST_AMT), true, true
FROM pde;
