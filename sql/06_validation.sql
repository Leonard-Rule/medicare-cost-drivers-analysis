-- Step 7: Reconciliation and data-quality checks. Each row is one check: what we expect, what we got,
-- and PASS / FLAG. FLAG is informational (a known data limitation), FAIL means the pipeline is wrong.
CREATE OR REPLACE VIEW validation AS
WITH
raw_claims AS (   -- distinct claims per institutional file, straight from the source tables
  SELECT 'inpatient' src, count(DISTINCT CLM_ID) n FROM inpatient UNION ALL
  SELECT 'outpatient', count(DISTINCT CLM_ID) FROM outpatient UNION ALL
  SELECT 'snf', count(DISTINCT CLM_ID) FROM snf UNION ALL
  SELECT 'hha', count(DISTINCT CLM_ID) FROM hha UNION ALL
  SELECT 'hospice', count(DISTINCT CLM_ID) FROM hospice UNION ALL
  SELECT 'carrier', count(*) FROM carrier UNION ALL
  SELECT 'dme', count(*) FROM dme UNION ALL
  SELECT 'pde', count(*) FROM pde),
std AS (SELECT src, count(*) n, sum(allowed) allowed FROM claim_line GROUP BY src),
elig AS (
  SELECT c.src, sum(c.allowed) total, sum(s.allowed) kept
  FROM (SELECT src, sum(allowed) allowed FROM claim_line_cat WHERE study_yr(yr) GROUP BY src) c
  LEFT JOIN (SELECT src, sum(allowed) allowed FROM spend WHERE study_yr(yr) GROUP BY src) s USING (src)
  GROUP BY c.src),
mm_check AS (
  SELECT sum(least(TRY_CAST(BENE_HI_CVRAGE_TOT_MONS AS INT), TRY_CAST(BENE_SMI_CVRAGE_TOT_MONS AS INT))) annual,
         (SELECT count(*) FROM member_month WHERE ab_ffs AND study_yr(yr)) monthly
  FROM beneficiary WHERE study_yr(CAST(BENE_ENROLLMT_REF_YR AS INT))),
pm AS (
  SELECT max(abs(p.pmpm - f.allowed / f.mm)) d
  FROM pmpm_by_category p JOIN (
    SELECT s.yr, s.service_category, sum(s.allowed) allowed,
           CASE WHEN s.service_category = 'Retail Pharmacy' THEN m.partd ELSE m.ab END mm
    FROM spend_fact s JOIN (SELECT yr, sum(ab_ffs_mm) ab, sum(partd_mm) partd FROM mm_fact GROUP BY yr) m USING (yr)
    GROUP BY s.yr, s.service_category, m.ab, m.partd) f USING (yr, service_category)),
op AS (
  SELECT sum(allowed) FILTER (WHERE clm_id IN (SELECT CLM_ID FROM outpatient WHERE HCPCS_CD = '90935')) dialysis,
         sum(allowed) total
  FROM spend WHERE src = 'outpatient' AND study_yr(yr))
SELECT * FROM (
  SELECT 1 AS id, 'Row count preserved: ' || r.src AS check_name, r.n::VARCHAR AS expected, s.n::VARCHAR AS actual,
         CASE WHEN r.n = s.n THEN 'PASS' ELSE 'FAIL' END AS status,
         'Institutional files collapse to one row per CLM_ID; line files keep every line' AS note
  FROM raw_claims r JOIN std s USING (src)
  UNION ALL
  SELECT 2, 'Every row gets a service category', '0',
         (SELECT count(*) FROM claim_line_cat WHERE service_category IS NULL OR subcategory = 'Other facility')::VARCHAR,
         CASE WHEN (SELECT count(*) FROM claim_line_cat WHERE service_category IS NULL OR subcategory = 'Other facility') = 0
              THEN 'PASS' ELSE 'FAIL' END, 'Unmapped bill types would land in Other facility'
  UNION ALL
  SELECT 3, 'Categorized $ = standardized $',
         round((SELECT sum(allowed) FROM claim_line))::VARCHAR, round((SELECT sum(allowed) FROM claim_line_cat))::VARCHAR,
         CASE WHEN abs((SELECT sum(allowed) FROM claim_line) - (SELECT sum(allowed) FROM claim_line_cat)) < 1
              THEN 'PASS' ELSE 'FAIL' END, 'Categorization must not add or drop dollars'
  UNION ALL
  SELECT 4, 'Share of $ in an eligible month: ' || src, '>= 90%', round(100 * kept / total, 1)::VARCHAR || '%',
         CASE WHEN kept / total >= 0.9 THEN 'PASS' ELSE 'FLAG' END,
         'Claims outside A+B FFS (or Part D) eligibility are excluded from PMPM'
  FROM elig
  UNION ALL
  SELECT 5, 'Monthly A+B FFS months vs annual summary fields', annual::VARCHAR, monthly::VARCHAR,
         CASE WHEN abs(monthly - annual) / annual < 0.1 THEN 'PASS' ELSE 'FLAG' END,
         'Annual fields count A and B separately (least of the two); monthly flags need both in the same month'
  FROM mm_check
  UNION ALL
  SELECT 6, 'PMPM rebuilds from the fact tables', '0.00', round(d, 2)::VARCHAR,
         CASE WHEN d < 0.01 THEN 'PASS' ELSE 'FAIL' END,
         'Dashboard/Tableau fact tables give the same PMPM as the SQL views'
  FROM pm
  UNION ALL
  SELECT 7, 'Primary care Step 5 (wellness-visit filter) applied', 'wellness visits > 0',
         (SELECT count(*) FROM pc_wellness_npi)::VARCHAR || ' NPIs with wellness visits',
         CASE WHEN (SELECT count(*) FROM pc_wellness_npi) > 0 THEN 'PASS' ELSE 'FLAG' END,
         'Synthetic carrier file has no wellness visits, so the rule would drop every physician; skipped'
  UNION ALL
  SELECT 8, 'Carrier office E&M visits (99202-99215) present', '> 0',
         (SELECT count(*) FROM spend WHERE src = 'carrier' AND hcpcs_cd BETWEEN '99202' AND '99215')::VARCHAR,
         CASE WHEN (SELECT count(*) FROM spend WHERE src = 'carrier' AND hcpcs_cd BETWEEN '99202' AND '99215') > 0
              THEN 'PASS' ELSE 'FLAG' END,
         'Real Medicare primary care is mostly office E&M; without them primary care share is understated'
  UNION ALL
  SELECT 9, 'Outpatient $ from dialysis (90935) claims', 'plausible share',
         round(100 * dialysis / total, 1)::VARCHAR || '%', 'FLAG',
         'Synthetic outpatient spend is dominated by dialysis claims, inflating Outpatient Hospital PMPM'
  FROM op
  UNION ALL
  SELECT 10, 'Primary care facility claims (G0463 split billing, FQHC 77x)', '> 0',
         ((SELECT count(*) FROM pc_facility_split) + (SELECT count(*) FROM pc_fqhc))::VARCHAR,
         CASE WHEN (SELECT count(*) FROM pc_facility_split) + (SELECT count(*) FROM pc_fqhc) > 0 THEN 'PASS' ELSE 'FLAG' END,
         'Step 6 logic runs but the synthetic outpatient file only has bill type 13x and no G0463'
) ORDER BY id, check_name;
