-- Step 1: Member months (the PMPM denominator)
-- One row per beneficiary-month. The CGT specs build PMPM on member months, so this uses the monthly
-- enrollment arrays instead of the annual summary counts (BENE_HI_CVRAGE_TOT_MONS etc.).
--   Part A+B:      MDCR_ENTLMT_BUYIN_IND_mm in ('3','C')   (C = A+B with state buy-in)
--   FFS (not MA):  HMO_IND_mm null or '0'
--   Part D:        PTD_CNTRCT_ID_mm populated and not '0'/'N'/'X' (no-Part-D placeholders)
--   Dual:          DUAL_STUS_CD_mm in 01-06, 08 (full or partial Medicaid)
-- Months with no entitlement (including months after death) have a null buy-in flag and drop out.

CREATE OR REPLACE TABLE member_month AS
WITH arrays AS (      -- pack each set of 12 monthly columns into a list, ordered Jan..Dec
  SELECT BENE_ID, CAST(BENE_ENROLLMT_REF_YR AS INT) AS yr, SEX_IDENT_CD,
         TRY_CAST(AGE_AT_END_REF_YR AS INT)             AS age,
         [*COLUMNS('^MDCR_ENTLMT_BUYIN_IND_\d\d$')]     AS buyin,
         [*COLUMNS('^HMO_IND_\d\d$')]                   AS hmo,
         [*COLUMNS('^PTD_CNTRCT_ID_\d\d$')]             AS ptd,
         [*COLUMNS('^DUAL_STUS_CD_\d\d$')]              AS dual
  FROM beneficiary
),
months AS (
  SELECT a.*, m.mo, buyin[m.mo] AS buyin_m, hmo[m.mo] AS hmo_m, ptd[m.mo] AS ptd_m, dual[m.mo] AS dual_m
  FROM arrays a CROSS JOIN range(1, 13) AS m(mo)
)
SELECT BENE_ID                                                      AS bene_id,
       yr,
       CAST(mo AS INT)                                              AS mo,
       buyin_m IN ('3', 'C') AND coalesce(hmo_m, '0') = '0'         AS ab_ffs,
       ptd_m IS NOT NULL AND ptd_m NOT IN ('0', 'N', 'X')           AS partd,
       coalesce(dual_m IN ('01','02','03','04','05','06','08'), false) AS dual,
       CASE WHEN age < 65 THEN '<65' WHEN age < 75 THEN '65-74'
            WHEN age < 85 THEN '75-84' ELSE '85+' END               AS age_band,
       CASE SEX_IDENT_CD WHEN '1' THEN 'Male' WHEN '2' THEN 'Female' ELSE 'Unknown' END AS sex
FROM months
WHERE buyin_m IS NOT NULL;

-- Summary: A+B FFS member months and average enrolled members by year
CREATE OR REPLACE VIEW member_months_by_year AS
SELECT yr,
       count(*) FILTER (WHERE ab_ffs)                         AS ab_ffs_member_months,
       count(*) FILTER (WHERE ab_ffs AND partd)               AS ab_ffs_partd_member_months,
       round(count(*) FILTER (WHERE ab_ffs) / 12.0, 1)        AS avg_ab_ffs_members,
       round(count(*) FILTER (WHERE ab_ffs AND dual) * 100.0
             / nullif(count(*) FILTER (WHERE ab_ffs), 0), 1)  AS pct_dual
FROM member_month GROUP BY yr ORDER BY yr;
