-- Step 4: Primary care claims spending, following the Peterson-Milbank primary care spec (May 2025),
-- Steps 1-6, and its "Medicare Considerations" for RIF data. The code lists in reference/*.csv are loaded
-- as the tables pc_service_codes, pc_place_of_service and pc_medicare_specialty.
-- The spec leaves the "total spending" denominator to the analyst. Both are reported:
--   pct_of_medical = primary care / all non-pharmacy spend
--   pct_of_total   = primary care / all spend including retail pharmacy

-- Steps 1-4 on professional (carrier) lines
CREATE TABLE pc_professional AS
SELECT s.*, pc.service_group
FROM spend s
JOIN pc_service_codes pc                                    -- Step 2: Appendix A service codes
  ON pc.hcpcs_cd = s.hcpcs_cd AND pc.claim_type = 'professional_or_facility'
JOIN pc_medicare_specialty sp ON sp.prvdr_spclty = s.spclty -- Step 3: RIF option 1, CMS 2-char specialty
JOIN pc_place_of_service pos ON pos.pos_cd = s.pos_cd       -- Step 4: Appendix C places of service
WHERE s.src = 'carrier'
  AND s.medicare_primary;                                   -- Step 1: paid as primary (also enforced in spend)

-- Step 5: drop physicians (not NPs/PAs) who never billed a wellness visit in the study period.
-- Guard: if the data has no wellness visits at all, this rule would remove every physician, so it is
-- skipped and the count is reported in 06_validation.sql instead. (That's the case in the synthetic file.)
CREATE TABLE pc_wellness_npi AS
SELECT DISTINCT rndrng_npi FROM spend
WHERE src = 'carrier'
  AND hcpcs_cd IN ('G0402','G0438','G0439','G0468','99381','99382','99383','99384','99385','99386',
                   '99387','99391','99392','99393','99394','99395','99396','99397');

CREATE TABLE pc_step5 AS
SELECT p.*
FROM pc_professional p
JOIN pc_medicare_specialty sp ON sp.prvdr_spclty = p.spclty
WHERE (SELECT COUNT(*) FROM pc_wellness_npi) = 0            -- guard: rule not applicable
   OR sp.is_physician = '0'                                 -- NPs / PAs are exempt
   OR p.rndrng_npi IN (SELECT rndrng_npi FROM pc_wellness_npi);

-- Outpatient revenue lines needed for Step 6, with the line date parsed (DD-Mon-YYYY) and line allowed $
CREATE TABLE pc_outpatient_line AS
SELECT BENE_ID AS bene_id, HCPCS_CD AS hcpcs_cd,
       CLM_FAC_TYPE_CD || CLM_SRVC_CLSFCTN_TYPE_CD AS bill_type2,
       CAST(SUBSTRING(REV_CNTR_DT, 8, 4) || '-' ||
            CASE SUBSTRING(REV_CNTR_DT, 4, 3)
                 WHEN 'Jan' THEN '01' WHEN 'Feb' THEN '02' WHEN 'Mar' THEN '03' WHEN 'Apr' THEN '04' WHEN 'May' THEN '05' WHEN 'Jun' THEN '06'
                 WHEN 'Jul' THEN '07' WHEN 'Aug' THEN '08' WHEN 'Sep' THEN '09' WHEN 'Oct' THEN '10' WHEN 'Nov' THEN '11' WHEN 'Dec' THEN '12'
            END || '-' || SUBSTRING(REV_CNTR_DT, 1, 2) AS DATE) AS svc_dt,
         COALESCE(CAST(NULLIF(TRIM(REV_CNTR_PMT_AMT_AMT), '')           AS DOUBLE PRECISION), 0)
       + COALESCE(CAST(NULLIF(TRIM(REV_CNTR_CASH_DDCTBL_AMT), '')       AS DOUBLE PRECISION), 0)
       + COALESCE(CAST(NULLIF(TRIM(REV_CNTR_COINSRNC_WGE_ADJSTD_C), '') AS DOUBLE PRECISION), 0) AS allowed
FROM outpatient
WHERE HCPCS_CD = 'G0463' OR CLM_FAC_TYPE_CD = '7';

-- Step 6a: provider-based billing. For an office visit (99202-99215) at POS 19/22, add the matching
-- facility G0463 line: same beneficiary and date, bill type 13x. Spend only, not utilization.
CREATE TABLE pc_facility_split AS
SELECT o.bene_id, o.svc_dt, o.allowed
FROM pc_outpatient_line o
WHERE o.hcpcs_cd = 'G0463' AND o.bill_type2 = '13'
  AND EXISTS (SELECT 1 FROM pc_step5 p
              WHERE p.bene_id = o.bene_id AND p.svc_dt = o.svc_dt
                AND p.pos_cd IN ('19', '22') AND p.hcpcs_cd BETWEEN '99201' AND '99215');

-- Step 6b: FQHC visits billed on institutional claims (bill type 77x) with an Appendix A code
CREATE TABLE pc_fqhc AS
SELECT o.bene_id, o.svc_dt, o.allowed
FROM pc_outpatient_line o
JOIN pc_service_codes pc ON pc.hcpcs_cd = o.hcpcs_cd
WHERE o.bill_type2 = '77';

-- Result: primary care $ and share by year
CREATE VIEW primary_care_by_year AS
WITH pc AS (
  SELECT yr, SUM(allowed) AS pc_prof, COUNT(*) AS pc_services
  FROM pc_step5 WHERE yr BETWEEN 2016 AND 2022 GROUP BY yr
),
fac_lines AS (
  SELECT CAST(EXTRACT(YEAR FROM svc_dt) AS INTEGER) AS yr, allowed FROM pc_facility_split
  UNION ALL
  SELECT CAST(EXTRACT(YEAR FROM svc_dt) AS INTEGER), allowed FROM pc_fqhc
),
fac AS (SELECT yr, SUM(allowed) AS pc_facility FROM fac_lines GROUP BY yr),
tot AS (
  SELECT yr, SUM(CASE WHEN service_category <> 'Retail Pharmacy' THEN allowed END) AS medical,
         SUM(allowed) AS total
  FROM spend_fact GROUP BY yr
),
mm AS (SELECT yr, SUM(ab_ffs_mm) AS mm FROM mm_fact GROUP BY yr),
combined AS (
  SELECT t.yr, COALESCE(pc.pc_prof, 0) + COALESCE(fac.pc_facility, 0) AS pc_allowed,
         COALESCE(pc.pc_services, 0) AS pc_services, t.medical, t.total, mm.mm
  FROM tot t
  JOIN mm ON mm.yr = t.yr
  LEFT JOIN pc ON pc.yr = t.yr
  LEFT JOIN fac ON fac.yr = t.yr
)
SELECT yr, ROUND(pc_allowed, 0) AS primary_care_allowed,
       pc_services AS primary_care_services,
       ROUND(pc_allowed / mm, 2) AS primary_care_pmpm,
       ROUND(100 * pc_allowed / medical, 2) AS pct_of_medical,
       ROUND(100 * pc_allowed / total, 2) AS pct_of_total
FROM combined;

-- Mix of primary care services (for the dashboard)
CREATE VIEW primary_care_by_service AS
SELECT yr, service_group, COUNT(*) AS services, ROUND(SUM(allowed), 2) AS allowed
FROM pc_step5
WHERE yr BETWEEN 2016 AND 2022
GROUP BY yr, service_group;

-- Dashboard-grain primary care spend (same demographic cells as spend_fact / mm_fact)
CREATE TABLE pc_fact AS
SELECT yr, service_group, dual, age_band, sex, SUM(allowed) AS allowed, COUNT(*) AS services
FROM pc_step5
WHERE yr BETWEEN 2016 AND 2022
GROUP BY yr, service_group, dual, age_band, sex;
