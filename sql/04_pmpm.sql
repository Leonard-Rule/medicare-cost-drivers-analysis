-- Step 3: PMPM by service category and year, with year-over-year growth (the cost growth target view).
-- Study years: 2016-2022. 2015 is the first file year and 2023 claims stop in the spring.
-- Denominators: medical categories use Part A+B FFS member months. Retail pharmacy uses A+B FFS months
-- that also have Part D, because only Part D enrollees can have PDE claims. Total PMPM adds the two.

-- Dashboard-grain denominators: member months by year x demographic cell
CREATE TABLE mm_fact AS
SELECT yr, dual, age_band, sex,
       SUM(CASE WHEN ab_ffs THEN 1 ELSE 0 END)           AS ab_ffs_mm,
       SUM(CASE WHEN ab_ffs AND partd THEN 1 ELSE 0 END) AS partd_mm
FROM member_month
WHERE yr BETWEEN 2016 AND 2022
GROUP BY yr, dual, age_band, sex;

-- Dashboard-grain numerators: spend by year x category x demographic cell
CREATE TABLE spend_fact AS
SELECT yr, service_category, subcategory, COALESCE(type_of_service, 'n/a') AS type_of_service,
       dual, age_band, sex,
       SUM(allowed) AS allowed, SUM(paid) AS paid, COUNT(*) AS n_rows,
       COUNT(DISTINCT bene_id) AS n_benes
FROM spend
WHERE yr BETWEEN 2016 AND 2022
GROUP BY yr, service_category, subcategory, COALESCE(type_of_service, 'n/a'), dual, age_band, sex;

CREATE VIEW pmpm_by_category AS
WITH mm AS (
  SELECT yr, SUM(ab_ffs_mm) AS ab_ffs_mm, SUM(partd_mm) AS partd_mm
  FROM mm_fact GROUP BY yr
),
cat AS (
  SELECT yr, service_category, SUM(allowed) AS allowed
  FROM spend_fact GROUP BY yr, service_category
),
joined AS (
  SELECT c.yr, c.service_category, c.allowed,
         CASE WHEN c.service_category = 'Retail Pharmacy' THEN mm.partd_mm ELSE mm.ab_ffs_mm END AS member_months
  FROM cat c JOIN mm ON mm.yr = c.yr
)
SELECT yr, service_category, ROUND(allowed, 0) AS allowed, member_months,
       ROUND(allowed / member_months, 2) AS pmpm
FROM joined;

CREATE VIEW pmpm_total AS
WITH t AS (
  SELECT yr,
         SUM(CASE WHEN service_category <> 'Retail Pharmacy' THEN pmpm END) AS medical_pmpm,
         SUM(CASE WHEN service_category =  'Retail Pharmacy' THEN pmpm END) AS rx_pmpm
  FROM pmpm_by_category GROUP BY yr
)
SELECT yr, ROUND(medical_pmpm, 2) AS medical_pmpm, ROUND(rx_pmpm, 2) AS rx_pmpm,
       ROUND(medical_pmpm + rx_pmpm, 2) AS total_pmpm,
       ROUND(100 * ((medical_pmpm + rx_pmpm) / LAG(medical_pmpm + rx_pmpm) OVER (ORDER BY yr) - 1), 1) AS total_growth_pct
FROM t;

-- Category growth: which service categories drove the change (the "cost driver" question)
CREATE VIEW pmpm_growth AS
SELECT yr, service_category, pmpm,
       ROUND(100 * (pmpm / LAG(pmpm) OVER (PARTITION BY service_category ORDER BY yr) - 1), 1) AS yoy_growth_pct,
       ROUND(pmpm - LAG(pmpm) OVER (PARTITION BY service_category ORDER BY yr), 2)          AS yoy_change_pmpm,
       CASE WHEN yr > 2016 THEN
            ROUND(100 * (POWER(pmpm / FIRST_VALUE(pmpm) OVER (PARTITION BY service_category ORDER BY yr),
                               1.0 / (yr - 2016)) - 1), 1)
       END AS cagr_since_2016_pct
FROM pmpm_by_category;
