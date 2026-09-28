-- Step 1: Member months (the PMPM denominator)
-- One row per beneficiary-month. The CGT specs build PMPM on member months, so this uses the monthly
-- enrollment columns (_01 through _12) instead of the annual summary counts (BENE_HI_CVRAGE_TOT_MONS etc.).
--   Part A+B:      MDCR_ENTLMT_BUYIN_IND_mm in ('3','C')   (C = A+B with state buy-in)
--   FFS (not MA):  HMO_IND_mm null or '0'
--   Part D:        PTD_CNTRCT_ID_mm populated and not '0'/'N'/'X' (no-Part-D placeholders)
--   Dual:          DUAL_STUS_CD_mm in 01-06, 08 (full or partial Medicaid)
-- Months with no entitlement (including months after death) have a null buy-in flag and drop out.
-- Source columns are loaded as text, so numbers are cast explicitly.

CREATE TABLE member_month AS
WITH months AS (      -- one row per beneficiary-year-month: pick that month's column from each set of 12
  SELECT b.BENE_ID,
         CAST(b.BENE_ENROLLMT_REF_YR AS INTEGER)            AS yr,
         m.mo,
         b.SEX_IDENT_CD,
         CAST(NULLIF(TRIM(b.AGE_AT_END_REF_YR), '') AS INTEGER) AS age,
         CASE m.mo
              WHEN 1 THEN b.MDCR_ENTLMT_BUYIN_IND_01
              WHEN 2 THEN b.MDCR_ENTLMT_BUYIN_IND_02
              WHEN 3 THEN b.MDCR_ENTLMT_BUYIN_IND_03
              WHEN 4 THEN b.MDCR_ENTLMT_BUYIN_IND_04
              WHEN 5 THEN b.MDCR_ENTLMT_BUYIN_IND_05
              WHEN 6 THEN b.MDCR_ENTLMT_BUYIN_IND_06
              WHEN 7 THEN b.MDCR_ENTLMT_BUYIN_IND_07
              WHEN 8 THEN b.MDCR_ENTLMT_BUYIN_IND_08
              WHEN 9 THEN b.MDCR_ENTLMT_BUYIN_IND_09
              WHEN 10 THEN b.MDCR_ENTLMT_BUYIN_IND_10
              WHEN 11 THEN b.MDCR_ENTLMT_BUYIN_IND_11
              WHEN 12 THEN b.MDCR_ENTLMT_BUYIN_IND_12
         END AS buyin_m,
         CASE m.mo
              WHEN 1 THEN b.HMO_IND_01
              WHEN 2 THEN b.HMO_IND_02
              WHEN 3 THEN b.HMO_IND_03
              WHEN 4 THEN b.HMO_IND_04
              WHEN 5 THEN b.HMO_IND_05
              WHEN 6 THEN b.HMO_IND_06
              WHEN 7 THEN b.HMO_IND_07
              WHEN 8 THEN b.HMO_IND_08
              WHEN 9 THEN b.HMO_IND_09
              WHEN 10 THEN b.HMO_IND_10
              WHEN 11 THEN b.HMO_IND_11
              WHEN 12 THEN b.HMO_IND_12
         END AS hmo_m,
         CASE m.mo
              WHEN 1 THEN b.PTD_CNTRCT_ID_01
              WHEN 2 THEN b.PTD_CNTRCT_ID_02
              WHEN 3 THEN b.PTD_CNTRCT_ID_03
              WHEN 4 THEN b.PTD_CNTRCT_ID_04
              WHEN 5 THEN b.PTD_CNTRCT_ID_05
              WHEN 6 THEN b.PTD_CNTRCT_ID_06
              WHEN 7 THEN b.PTD_CNTRCT_ID_07
              WHEN 8 THEN b.PTD_CNTRCT_ID_08
              WHEN 9 THEN b.PTD_CNTRCT_ID_09
              WHEN 10 THEN b.PTD_CNTRCT_ID_10
              WHEN 11 THEN b.PTD_CNTRCT_ID_11
              WHEN 12 THEN b.PTD_CNTRCT_ID_12
         END AS ptd_m,
         CASE m.mo
              WHEN 1 THEN b.DUAL_STUS_CD_01
              WHEN 2 THEN b.DUAL_STUS_CD_02
              WHEN 3 THEN b.DUAL_STUS_CD_03
              WHEN 4 THEN b.DUAL_STUS_CD_04
              WHEN 5 THEN b.DUAL_STUS_CD_05
              WHEN 6 THEN b.DUAL_STUS_CD_06
              WHEN 7 THEN b.DUAL_STUS_CD_07
              WHEN 8 THEN b.DUAL_STUS_CD_08
              WHEN 9 THEN b.DUAL_STUS_CD_09
              WHEN 10 THEN b.DUAL_STUS_CD_10
              WHEN 11 THEN b.DUAL_STUS_CD_11
              WHEN 12 THEN b.DUAL_STUS_CD_12
         END AS dual_m
  FROM beneficiary b
  CROSS JOIN (VALUES (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12)) AS m(mo)
)
SELECT BENE_ID                                                      AS bene_id,
       yr,
       mo,
       buyin_m IN ('3', 'C') AND COALESCE(hmo_m, '0') = '0'         AS ab_ffs,
       ptd_m IS NOT NULL AND ptd_m NOT IN ('0', 'N', 'X')           AS partd,
       COALESCE(dual_m IN ('01','02','03','04','05','06','08'), FALSE) AS dual,
       CASE WHEN age < 65 THEN '<65' WHEN age < 75 THEN '65-74'
            WHEN age < 85 THEN '75-84' ELSE '85+' END               AS age_band,
       CASE SEX_IDENT_CD WHEN '1' THEN 'Male' WHEN '2' THEN 'Female' ELSE 'Unknown' END AS sex
FROM months
WHERE buyin_m IS NOT NULL;

-- Summary: A+B FFS member months and average enrolled members by year
CREATE VIEW member_months_by_year AS
SELECT yr,
       SUM(CASE WHEN ab_ffs THEN 1 ELSE 0 END)                        AS ab_ffs_member_months,
       SUM(CASE WHEN ab_ffs AND partd THEN 1 ELSE 0 END)              AS ab_ffs_partd_member_months,
       ROUND(SUM(CASE WHEN ab_ffs THEN 1 ELSE 0 END) / 12.0, 1)       AS avg_ab_ffs_members,
       ROUND(SUM(CASE WHEN ab_ffs AND dual THEN 1 ELSE 0 END) * 100.0
             / NULLIF(SUM(CASE WHEN ab_ffs THEN 1 ELSE 0 END), 0), 1) AS pct_dual
FROM member_month
GROUP BY yr;
