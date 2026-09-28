-- Step 4: Primary care claims spending, following the Peterson-Milbank primary care spec (May 2025),
-- Steps 1-6, and its "Medicare Considerations" for RIF data. Code lists live in ref/*.csv (loaded by
-- src/run_pipeline.py as pc_service_codes, pc_place_of_service, pc_medicare_specialty).
-- The spec leaves the "total spending" denominator to the analyst. Both are reported:
--   pct_of_medical = primary care / all non-pharmacy spend
--   pct_of_total   = primary care / all spend including retail pharmacy

-- Steps 1-4 on professional (carrier) lines
CREATE OR REPLACE TABLE pc_professional AS
SELECT s.*, pc.service_group
FROM spend s
JOIN pc_service_codes pc                                   -- Step 2: Appendix A service codes
  ON pc.hcpcs_cd = s.hcpcs_cd AND pc.claim_type = 'professional_or_facility'
JOIN pc_medicare_specialty sp ON sp.prvdr_spclty = s.spclty -- Step 3: RIF option 1, CMS 2-char specialty
JOIN pc_place_of_service pos ON pos.pos_cd = s.pos_cd       -- Step 4: Appendix C places of service
WHERE s.src = 'carrier'
  AND s.medicare_primary;                                   -- Step 1: paid as primary (also enforced in spend)

-- Step 5: drop physicians (not NPs/PAs) who never billed a wellness visit in the study period.
-- Guard: if the data has no wellness visits at all, this rule would remove every physician, so it is
-- skipped and the count is reported in 06_validation.sql instead. (That's the case in the synthetic file.)
CREATE OR REPLACE TABLE pc_wellness_npi AS
SELECT DISTINCT rndrng_npi FROM spend
WHERE src = 'carrier'
  AND hcpcs_cd IN ('G0402','G0438','G0439','G0468','99381','99382','99383','99384','99385','99386',
                   '99387','99391','99392','99393','99394','99395','99396','99397');

CREATE OR REPLACE TABLE pc_step5 AS
SELECT p.*
FROM pc_professional p
JOIN pc_medicare_specialty sp ON sp.prvdr_spclty = p.spclty
WHERE (SELECT count(*) FROM pc_wellness_npi) = 0            -- guard: rule not applicable
   OR sp.is_physician = 0                                   -- NPs / PAs are exempt
   OR p.rndrng_npi IN (SELECT rndrng_npi FROM pc_wellness_npi);

-- Step 6a: provider-based billing. For an office visit (99202-99215) at POS 19/22, add the matching
-- facility G0463 line: same beneficiary and date, bill type 13x. Spend only, not utilization.
CREATE OR REPLACE TABLE pc_facility_split AS
SELECT o.BENE_ID AS bene_id, dt(o.REV_CNTR_DT) AS svc_dt, amt(o.REV_CNTR_PMT_AMT_AMT)
       + amt(o.REV_CNTR_CASH_DDCTBL_AMT) + amt(o.REV_CNTR_COINSRNC_WGE_ADJSTD_C) AS allowed
FROM outpatient o
WHERE o.HCPCS_CD = 'G0463' AND o.CLM_FAC_TYPE_CD = '1' AND o.CLM_SRVC_CLSFCTN_TYPE_CD = '3'
  AND EXISTS (SELECT 1 FROM pc_step5 p
              WHERE p.bene_id = o.BENE_ID AND p.svc_dt = dt(o.REV_CNTR_DT)
                AND p.pos_cd IN ('19', '22') AND p.hcpcs_cd BETWEEN '99201' AND '99215');

-- Step 6b: FQHC visits billed on institutional claims (bill type 77x) with an Appendix A code
CREATE OR REPLACE TABLE pc_fqhc AS
SELECT o.BENE_ID AS bene_id, dt(o.REV_CNTR_DT) AS svc_dt, amt(o.REV_CNTR_PMT_AMT_AMT)
       + amt(o.REV_CNTR_CASH_DDCTBL_AMT) + amt(o.REV_CNTR_COINSRNC_WGE_ADJSTD_C) AS allowed
FROM outpatient o JOIN pc_service_codes pc ON pc.hcpcs_cd = o.HCPCS_CD
WHERE o.CLM_FAC_TYPE_CD = '7' AND o.CLM_SRVC_CLSFCTN_TYPE_CD = '7';

-- Result: primary care $ and share by year
CREATE OR REPLACE VIEW primary_care_by_year AS
WITH pc AS (
  SELECT yr, sum(allowed) AS pc_prof, count(*) AS pc_services FROM pc_step5 WHERE study_yr(yr) GROUP BY yr
),
fac AS (
  SELECT year(svc_dt) AS yr, sum(allowed) AS pc_facility
  FROM (SELECT * FROM pc_facility_split UNION ALL SELECT * FROM pc_fqhc) GROUP BY 1
),
tot AS (
  SELECT yr, sum(allowed) FILTER (WHERE service_category <> 'Retail Pharmacy') AS medical,
         sum(allowed) AS total
  FROM spend_fact GROUP BY yr
),
mm AS (SELECT yr, sum(ab_ffs_mm) AS mm FROM mm_fact GROUP BY yr)
SELECT t.yr, round(coalesce(pc_prof, 0) + coalesce(pc_facility, 0)) AS primary_care_allowed,
       coalesce(pc_services, 0) AS primary_care_services,
       round((coalesce(pc_prof, 0) + coalesce(pc_facility, 0)) / mm.mm, 2) AS primary_care_pmpm,
       round(100 * (coalesce(pc_prof, 0) + coalesce(pc_facility, 0)) / t.medical, 2) AS pct_of_medical,
       round(100 * (coalesce(pc_prof, 0) + coalesce(pc_facility, 0)) / t.total, 2) AS pct_of_total
FROM tot t JOIN mm USING (yr) LEFT JOIN pc USING (yr) LEFT JOIN fac USING (yr)
ORDER BY t.yr;

-- Mix of primary care services (for the dashboard)
CREATE OR REPLACE VIEW primary_care_by_service AS
SELECT yr, service_group, count(*) AS services, round(sum(allowed), 2) AS allowed
FROM pc_step5 WHERE study_yr(yr) GROUP BY ALL ORDER BY yr, allowed DESC;

-- Dashboard-grain primary care spend (same demographic cells as spend_fact / mm_fact)
CREATE OR REPLACE TABLE pc_fact AS
SELECT yr, service_group, dual, age_band, sex, sum(allowed) AS allowed, count(*) AS services
FROM pc_step5 WHERE study_yr(yr) GROUP BY ALL;
