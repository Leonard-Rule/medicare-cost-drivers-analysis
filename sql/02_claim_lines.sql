-- Step 2a: One standardized spend table across all nine claim files.
-- Unit of analysis follows the Milbank service-category spec:
--   * institutional files (inpatient, outpatient, SNF, HHA, hospice): one row per claim (header dollars).
--     The RIF repeats the header on every revenue line, so collapse to CLM_ID first. MAX() just picks the
--     header value, which is identical on every line of a claim.
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
--
-- Source columns are text. Blank dollar fields count as 0. Dates arrive as DD-Mon-YYYY (e.g. 25-Mar-2015)
-- and are rebuilt as YYYY-MM-DD before casting to DATE.

CREATE TABLE claim_line AS
WITH inst AS (
  SELECT 'inpatient' AS src, CLM_ID, MAX(BENE_ID) AS BENE_ID, MAX(CLM_FROM_DT) AS from_dt,
         MAX(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD) AS bill_type2,
         MAX(NCH_PRMRY_PYR_CD) AS msp_cd, MAX(CLM_MDCR_NON_PMT_RSN_CD) AS nonpay_cd,
         MAX(COALESCE(CAST(NULLIF(TRIM(CLM_PMT_AMT), '') AS DOUBLE PRECISION), 0)) AS paid,
         MAX(  COALESCE(CAST(NULLIF(TRIM(NCH_BENE_IP_DDCTBL_AMT), '')         AS DOUBLE PRECISION), 0)
             + COALESCE(CAST(NULLIF(TRIM(NCH_BENE_PTA_COINSRNC_LBLTY_AM), '') AS DOUBLE PRECISION), 0)
             + COALESCE(CAST(NULLIF(TRIM(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM), '') AS DOUBLE PRECISION), 0)) AS cost_share
  FROM inpatient GROUP BY CLM_ID
  UNION ALL
  SELECT 'outpatient' AS src, CLM_ID, MAX(BENE_ID) AS BENE_ID, MAX(CLM_FROM_DT) AS from_dt,
         MAX(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD) AS bill_type2,
         MAX(NCH_PRMRY_PYR_CD) AS msp_cd, MAX(CLM_MDCR_NON_PMT_RSN_CD) AS nonpay_cd,
         MAX(COALESCE(CAST(NULLIF(TRIM(CLM_PMT_AMT), '') AS DOUBLE PRECISION), 0)) AS paid,
         MAX(  COALESCE(CAST(NULLIF(TRIM(NCH_BENE_PTB_DDCTBL_AMT), '')        AS DOUBLE PRECISION), 0)
             + COALESCE(CAST(NULLIF(TRIM(NCH_BENE_PTB_COINSRNC_AMT), '')      AS DOUBLE PRECISION), 0)
             + COALESCE(CAST(NULLIF(TRIM(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM), '') AS DOUBLE PRECISION), 0)) AS cost_share
  FROM outpatient GROUP BY CLM_ID
  UNION ALL
  SELECT 'snf' AS src, CLM_ID, MAX(BENE_ID) AS BENE_ID, MAX(CLM_FROM_DT) AS from_dt,
         MAX(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD) AS bill_type2,
         MAX(NCH_PRMRY_PYR_CD) AS msp_cd, MAX(CLM_MDCR_NON_PMT_RSN_CD) AS nonpay_cd,
         MAX(COALESCE(CAST(NULLIF(TRIM(CLM_PMT_AMT), '') AS DOUBLE PRECISION), 0)) AS paid,
         MAX(  COALESCE(CAST(NULLIF(TRIM(NCH_BENE_IP_DDCTBL_AMT), '')         AS DOUBLE PRECISION), 0)
             + COALESCE(CAST(NULLIF(TRIM(NCH_BENE_PTA_COINSRNC_LBLTY_AM), '') AS DOUBLE PRECISION), 0)
             + COALESCE(CAST(NULLIF(TRIM(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM), '') AS DOUBLE PRECISION), 0)) AS cost_share
  FROM snf GROUP BY CLM_ID
  UNION ALL
  SELECT 'hha' AS src, CLM_ID, MAX(BENE_ID) AS BENE_ID, MAX(CLM_FROM_DT) AS from_dt,
         MAX(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD) AS bill_type2,
         MAX(NCH_PRMRY_PYR_CD) AS msp_cd, MAX(CLM_MDCR_NON_PMT_RSN_CD) AS nonpay_cd,
         MAX(COALESCE(CAST(NULLIF(TRIM(CLM_PMT_AMT), '') AS DOUBLE PRECISION), 0)) AS paid,
         0 AS cost_share   -- no beneficiary cost sharing for home health
  FROM hha GROUP BY CLM_ID
  UNION ALL
  SELECT 'hospice' AS src, CLM_ID, MAX(BENE_ID) AS BENE_ID, MAX(CLM_FROM_DT) AS from_dt,
         MAX(CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD) AS bill_type2,
         MAX(NCH_PRMRY_PYR_CD) AS msp_cd, MAX(CLM_MDCR_NON_PMT_RSN_CD) AS nonpay_cd,
         MAX(COALESCE(CAST(NULLIF(TRIM(CLM_PMT_AMT), '') AS DOUBLE PRECISION), 0)) AS paid,
         0 AS cost_share   -- hospice copays aren't on the claim
  FROM hospice GROUP BY CLM_ID
),
all_rows AS (
  SELECT src, BENE_ID AS bene_id, CLM_ID AS clm_id, CAST(NULL AS INTEGER) AS line_num, from_dt AS svc_dt_txt,
         bill_type2, CAST(NULL AS VARCHAR(2)) AS pos_cd, CAST(NULL AS VARCHAR(2)) AS spclty,
         CAST(NULL AS VARCHAR(5)) AS hcpcs_cd, CAST(NULL AS VARCHAR(3)) AS betos_cd,
         CAST(NULL AS VARCHAR(10)) AS rndrng_npi, CAST(NULL AS VARCHAR(11)) AS ndc,
         paid, paid + cost_share AS allowed,
         COALESCE(TRIM(msp_cd), '') = ''    AS medicare_primary,
         COALESCE(TRIM(nonpay_cd), '') = '' AS medicare_paid
  FROM inst
  UNION ALL
  SELECT 'carrier', BENE_ID, CLM_ID, CAST(LINE_NUM AS INTEGER), LINE_1ST_EXPNS_DT, NULL,
         LINE_PLACE_OF_SRVC_CD, PRVDR_SPCLTY, HCPCS_CD, BETOS_CD, PRF_PHYSN_NPI, NULL,
         COALESCE(CAST(NULLIF(TRIM(LINE_NCH_PMT_AMT), '') AS DOUBLE PRECISION), 0), COALESCE(CAST(NULLIF(TRIM(LINE_ALOWD_CHRG_AMT), '') AS DOUBLE PRECISION), 0),
         COALESCE(TRIM(LINE_BENE_PRMRY_PYR_CD), '') = '',
         COALESCE(LINE_PRCSG_IND_CD, 'A') = 'A'      -- A = allowed; other codes are denials/rejects
  FROM carrier
  UNION ALL
  SELECT 'dme', BENE_ID, CLM_ID, CAST(LINE_NUM AS INTEGER), LINE_1ST_EXPNS_DT, NULL,
         LINE_PLACE_OF_SRVC_CD, PRVDR_SPCLTY, HCPCS_CD, BETOS_CD, NULL, LINE_NDC_CD,
         COALESCE(CAST(NULLIF(TRIM(LINE_NCH_PMT_AMT), '') AS DOUBLE PRECISION), 0), COALESCE(CAST(NULLIF(TRIM(LINE_ALOWD_CHRG_AMT), '') AS DOUBLE PRECISION), 0),
         COALESCE(TRIM(LINE_BENE_PRMRY_PYR_CD), '') = '',
         COALESCE(LINE_PRCSG_IND_CD, 'A') = 'A'
  FROM dme
  UNION ALL
  SELECT 'pde', BENE_ID, PDE_ID, NULL, SRVC_DT, NULL, NULL, NULL, NULL, NULL, NULL, PROD_SRVC_ID,
         COALESCE(CAST(NULLIF(TRIM(CVRD_D_PLAN_PD_AMT), '') AS DOUBLE PRECISION), 0), COALESCE(CAST(NULLIF(TRIM(TOT_RX_CST_AMT), '') AS DOUBLE PRECISION), 0), TRUE, TRUE
  FROM pde
)
SELECT src, bene_id, clm_id, line_num,
       CAST(SUBSTRING(svc_dt_txt, 8, 4) || '-' ||
            CASE SUBSTRING(svc_dt_txt, 4, 3)
                 WHEN 'Jan' THEN '01' WHEN 'Feb' THEN '02' WHEN 'Mar' THEN '03' WHEN 'Apr' THEN '04' WHEN 'May' THEN '05' WHEN 'Jun' THEN '06'
                 WHEN 'Jul' THEN '07' WHEN 'Aug' THEN '08' WHEN 'Sep' THEN '09' WHEN 'Oct' THEN '10' WHEN 'Nov' THEN '11' WHEN 'Dec' THEN '12'
            END || '-' || SUBSTRING(svc_dt_txt, 1, 2) AS DATE) AS svc_dt,
       bill_type2, pos_cd, spclty, hcpcs_cd, betos_cd, rndrng_npi, ndc,
       paid, allowed, medicare_primary, medicare_paid
FROM all_rows;
