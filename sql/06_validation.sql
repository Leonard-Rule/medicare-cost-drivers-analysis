-- Step 7: Reconciliation and data-quality checks. Each row is one check: what we expect, what we got,
-- and PASS / FLAG. FLAG is informational (a known data limitation), FAIL means the pipeline is wrong.
CREATE VIEW validation AS
WITH
raw_claims AS (   -- distinct claims per institutional file, straight from the source tables
  SELECT 'inpatient' AS src, COUNT(DISTINCT CLM_ID) AS n FROM inpatient UNION ALL
  SELECT 'outpatient', COUNT(DISTINCT CLM_ID) FROM outpatient UNION ALL
  SELECT 'snf',        COUNT(DISTINCT CLM_ID) FROM snf UNION ALL
  SELECT 'hha',        COUNT(DISTINCT CLM_ID) FROM hha UNION ALL
  SELECT 'hospice',    COUNT(DISTINCT CLM_ID) FROM hospice UNION ALL
  SELECT 'carrier',    COUNT(*) FROM carrier UNION ALL
  SELECT 'dme',        COUNT(*) FROM dme UNION ALL
  SELECT 'pde',        COUNT(*) FROM pde),
std AS (SELECT src, COUNT(*) AS n, SUM(allowed) AS allowed FROM claim_line GROUP BY src),
elig AS (
  SELECT c.src, c.allowed AS total, s.allowed AS kept
  FROM (SELECT src, SUM(allowed) AS allowed FROM claim_line_cat WHERE yr BETWEEN 2016 AND 2022 GROUP BY src) c
  LEFT JOIN (SELECT src, SUM(allowed) AS allowed FROM spend WHERE yr BETWEEN 2016 AND 2022 GROUP BY src) s
    ON s.src = c.src),
mm_check AS (
  SELECT SUM(CASE WHEN CAST(BENE_HI_CVRAGE_TOT_MONS AS INTEGER) < CAST(BENE_SMI_CVRAGE_TOT_MONS AS INTEGER)
                  THEN CAST(BENE_HI_CVRAGE_TOT_MONS AS INTEGER)
                  ELSE CAST(BENE_SMI_CVRAGE_TOT_MONS AS INTEGER) END) AS annual,
         (SELECT COUNT(*) FROM member_month WHERE ab_ffs AND yr BETWEEN 2016 AND 2022) AS monthly
  FROM beneficiary
  WHERE CAST(BENE_ENROLLMT_REF_YR AS INTEGER) BETWEEN 2016 AND 2022),
fact_pmpm AS (   -- PMPM rebuilt from the dashboard fact tables
  SELECT s.yr, s.service_category,
         SUM(s.allowed) / MAX(CASE WHEN s.service_category = 'Retail Pharmacy' THEN m.partd ELSE m.ab END) AS pmpm
  FROM spend_fact s
  JOIN (SELECT yr, SUM(ab_ffs_mm) AS ab, SUM(partd_mm) AS partd FROM mm_fact GROUP BY yr) m ON m.yr = s.yr
  GROUP BY s.yr, s.service_category),
pm AS (
  SELECT MAX(ABS(p.pmpm - f.pmpm)) AS d
  FROM pmpm_by_category p
  JOIN fact_pmpm f ON f.yr = p.yr AND f.service_category = p.service_category),
op AS (
  SELECT SUM(CASE WHEN clm_id IN (SELECT CLM_ID FROM outpatient WHERE HCPCS_CD = '90935') THEN allowed END) AS dialysis,
         SUM(allowed) AS total
  FROM spend WHERE src = 'outpatient' AND yr BETWEEN 2016 AND 2022),
counts AS (
  SELECT (SELECT COUNT(*) FROM claim_line_cat WHERE service_category IS NULL OR subcategory = 'Other facility') AS unmapped,
         (SELECT SUM(allowed) FROM claim_line)     AS std_allowed,
         (SELECT SUM(allowed) FROM claim_line_cat) AS cat_allowed,
         (SELECT COUNT(*) FROM pc_wellness_npi)    AS wellness_npis,
         (SELECT COUNT(*) FROM spend WHERE src = 'carrier' AND hcpcs_cd BETWEEN '99202' AND '99215') AS office_em,
         (SELECT COUNT(*) FROM pc_facility_split) + (SELECT COUNT(*) FROM pc_fqhc) AS pc_facility_rows)
SELECT 1 AS id, 'Row count preserved: ' || r.src AS check_name,
       CAST(r.n AS VARCHAR(30)) AS expected, CAST(s.n AS VARCHAR(30)) AS actual,
       CASE WHEN r.n = s.n THEN 'PASS' ELSE 'FAIL' END AS status,
       'Institutional files collapse to one row per CLM_ID; line files keep every line' AS note
FROM raw_claims r JOIN std s ON s.src = r.src
UNION ALL
SELECT 2, 'Every row gets a service category', '0', CAST(unmapped AS VARCHAR(30)),
       CASE WHEN unmapped = 0 THEN 'PASS' ELSE 'FAIL' END, 'Unmapped bill types would land in Other facility'
FROM counts
UNION ALL
SELECT 3, 'Categorized $ = standardized $', CAST(ROUND(std_allowed, 0) AS VARCHAR(30)), CAST(ROUND(cat_allowed, 0) AS VARCHAR(30)),
       CASE WHEN ABS(std_allowed - cat_allowed) < 1 THEN 'PASS' ELSE 'FAIL' END, 'Categorization must not add or drop dollars'
FROM counts
UNION ALL
SELECT 4, 'Share of $ in an eligible month: ' || src, '>= 90%', CAST(ROUND(100 * kept / total, 1) AS VARCHAR(30)) || '%',
       CASE WHEN kept / total >= 0.9 THEN 'PASS' ELSE 'FLAG' END,
       'Claims outside A+B FFS (or Part D) eligibility are excluded from PMPM'
FROM elig
UNION ALL
SELECT 5, 'Monthly A+B FFS months vs annual summary fields', CAST(annual AS VARCHAR(30)), CAST(monthly AS VARCHAR(30)),
       CASE WHEN ABS(monthly - annual) * 1.0 / annual < 0.1 THEN 'PASS' ELSE 'FLAG' END,
       'Annual fields count A and B separately (least of the two); monthly flags need both in the same month'
FROM mm_check
UNION ALL
SELECT 6, 'PMPM rebuilds from the fact tables', '0.00', CAST(ROUND(d, 2) AS VARCHAR(30)),
       CASE WHEN d < 0.01 THEN 'PASS' ELSE 'FAIL' END,
       'Dashboard/Tableau fact tables give the same PMPM as the SQL views'
FROM pm
UNION ALL
SELECT 7, 'Primary care Step 5 (wellness-visit filter) applied', 'wellness visits > 0',
       CAST(wellness_npis AS VARCHAR(30)) || ' NPIs with wellness visits',
       CASE WHEN wellness_npis > 0 THEN 'PASS' ELSE 'FLAG' END,
       'Synthetic carrier file has no wellness visits, so the rule would drop every physician; skipped'
FROM counts
UNION ALL
SELECT 8, 'Carrier office E&M visits (99202-99215) present', '> 0', CAST(office_em AS VARCHAR(30)),
       CASE WHEN office_em > 0 THEN 'PASS' ELSE 'FLAG' END,
       'Office E&M visits are the core of the primary care definition; without them primary care share is understated'
FROM counts
UNION ALL
SELECT 9, 'Outpatient $ from dialysis (90935) claims', 'informational',
       CAST(ROUND(100 * dialysis / total, 1) AS VARCHAR(30)) || '%', 'FLAG',
       'Dialysis claims make up a large share of outpatient spend in the synthetic file'
FROM op
UNION ALL
SELECT 10, 'Primary care facility claims (G0463 split billing, FQHC 77x)', '> 0', CAST(pc_facility_rows AS VARCHAR(30)),
       CASE WHEN pc_facility_rows > 0 THEN 'PASS' ELSE 'FLAG' END,
       'Step 6 logic runs but the synthetic outpatient file only has bill type 13x and no G0463'
FROM counts;
