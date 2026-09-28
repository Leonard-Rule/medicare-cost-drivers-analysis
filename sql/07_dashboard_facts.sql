-- Step 8: Extra facts for the dashboard story.

-- Inpatient price vs. volume. Inpatient PMPM = (stays per member month) x (allowed $ per stay), so its
-- growth splits into "more stays" and "costlier stays". One inpatient claim = one stay.
CREATE TABLE ip_fact AS
SELECT yr, dual, age_band, sex,
       COUNT(*)     AS stays,
       SUM(allowed) AS allowed
FROM spend
WHERE service_category = 'Inpatient Hospital'
  AND yr BETWEEN 2016 AND 2022
GROUP BY yr, dual, age_band, sex;

-- Distinct people with at least one Part A+B FFS month, for every filter combination.
-- People can move between cells during a year (dual status changes month to month), so distinct counts
-- don't add up across cells. CUBE computes each combination directly; a NULL in a filter column
-- (GROUPING() = 1) means "all".
CREATE TABLE members_fact AS
SELECT yr,
       CASE WHEN GROUPING(dual) = 1 THEN 'all' WHEN dual THEN 'true' ELSE 'false' END AS dual,
       CASE WHEN GROUPING(age_band) = 1 THEN 'all' ELSE age_band END                  AS age_band,
       CASE WHEN GROUPING(sex) = 1 THEN 'all' ELSE sex END                            AS sex,
       COUNT(DISTINCT bene_id) AS members
FROM member_month
WHERE ab_ffs
  AND yr BETWEEN 2016 AND 2022
GROUP BY yr, CUBE (dual, age_band, sex);
