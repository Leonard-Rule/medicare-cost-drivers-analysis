-- Step 3: PMPM by service category and year, with year-over-year growth (the cost growth target view).
-- Study years: 2016-2022. 2015 is the first file year and 2023 claims stop in the spring.
-- Denominators: medical categories use Part A+B FFS member months. Retail pharmacy uses A+B FFS months
-- that also have Part D, because only Part D enrollees can have PDE claims. Total PMPM adds the two.

CREATE OR REPLACE MACRO study_yr(y) AS y BETWEEN 2016 AND 2022;

-- Dashboard-grain denominators: member months by year x demographic cell
CREATE OR REPLACE TABLE mm_fact AS
SELECT yr, dual, age_band, sex,
       count(*) FILTER (WHERE ab_ffs)           AS ab_ffs_mm,
       count(*) FILTER (WHERE ab_ffs AND partd) AS partd_mm
FROM member_month WHERE study_yr(yr)
GROUP BY ALL;

-- Dashboard-grain numerators: spend by year x category x demographic cell
CREATE OR REPLACE TABLE spend_fact AS
SELECT yr, service_category, subcategory, coalesce(type_of_service, 'n/a') AS type_of_service,
       dual, age_band, sex,
       sum(allowed) AS allowed, sum(paid) AS paid, count(*) AS n_rows,
       count(DISTINCT bene_id) AS n_benes
FROM spend WHERE study_yr(yr)
GROUP BY ALL;

CREATE OR REPLACE VIEW pmpm_by_category AS
WITH mm AS (SELECT yr, sum(ab_ffs_mm) ab_ffs_mm, sum(partd_mm) partd_mm FROM mm_fact GROUP BY yr),
cat AS (SELECT yr, service_category, sum(allowed) allowed FROM spend_fact GROUP BY ALL)
SELECT c.yr, c.service_category, round(c.allowed, 0) AS allowed,
       CASE WHEN c.service_category = 'Retail Pharmacy' THEN mm.partd_mm ELSE mm.ab_ffs_mm END AS member_months,
       round(c.allowed / CASE WHEN c.service_category = 'Retail Pharmacy' THEN mm.partd_mm ELSE mm.ab_ffs_mm END, 2) AS pmpm
FROM cat c JOIN mm USING (yr);

CREATE OR REPLACE VIEW pmpm_total AS
WITH t AS (
  SELECT yr,
         sum(pmpm) FILTER (WHERE service_category <> 'Retail Pharmacy') AS medical_pmpm,
         sum(pmpm) FILTER (WHERE service_category =  'Retail Pharmacy') AS rx_pmpm
  FROM pmpm_by_category GROUP BY yr
)
SELECT yr, round(medical_pmpm, 2) AS medical_pmpm, round(rx_pmpm, 2) AS rx_pmpm,
       round(medical_pmpm + rx_pmpm, 2) AS total_pmpm,
       round(100 * ((medical_pmpm + rx_pmpm) / lag(medical_pmpm + rx_pmpm) OVER (ORDER BY yr) - 1), 1) AS total_growth_pct
FROM t ORDER BY yr;

-- Category growth: which service categories drove the change (the "cost driver" question)
CREATE OR REPLACE VIEW pmpm_growth AS
SELECT yr, service_category, pmpm,
       round(100 * (pmpm / lag(pmpm) OVER w - 1), 1)       AS yoy_growth_pct,
       round(pmpm - lag(pmpm) OVER w, 2)                    AS yoy_change_pmpm,
       CASE WHEN yr > 2016 THEN round(100 * (pow(pmpm / first_value(pmpm) OVER w, 1.0 / (yr - 2016)) - 1), 1) END AS cagr_since_2016_pct
FROM pmpm_by_category
WINDOW w AS (PARTITION BY service_category ORDER BY yr);
