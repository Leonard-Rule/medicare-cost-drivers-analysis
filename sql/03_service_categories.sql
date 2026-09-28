-- Step 2b: Assign every row to one of the six Peterson-Milbank topline service categories, plus the
-- spec's subcategory ("place of setting") and, for professional lines, a type of service.
-- Source: Consensus Administrative Specifications for Health Care Cost Driver Analyses (June 2025),
-- "Defining Service Categories for Measuring Spending", pp. 5-8.
--
-- Topline is set by claim form first, because the spec calls consistent topline categories the
-- most important thing and its topline table is explicit that CMS-1500 spend is Professional even
-- during an inpatient or facility stay. Subcategories then follow the appendix code tables.
--
-- Judgment calls (the spec is ambiguous or the RIF lacks the field). Each is listed in docs/METHODS.md:
--   1. Home health (bill type 32/33/34) -> Professional / Home Health. That's where the spec's code
--      table puts it, even though the topline table lists HCBS under Long-Term Care. 33 is included
--      because Medicare HHA claims in this file use it.
--   2. Bill type 81/82 appears as both "Independent lab" (outpatient) and "Hospice" (LTC). Medicare
--      uses 81x/82x for hospice, so hospice wins.
--   3. DME supplier claims -> Other / DME (not a facility, not physician services).
--   4. RBCS isn't on the RIF. BETOS (its predecessor, first letter) stands in for type of service.

CREATE OR REPLACE TABLE claim_line_cat AS
SELECT cl.*,
  CASE
    WHEN src = 'pde'                                                 THEN 'Retail Pharmacy'
    WHEN src = 'carrier'                                             THEN 'Professional'
    WHEN src = 'dme'                                                 THEN 'Other'
    WHEN bill_type2 IN ('11', '41')                                  THEN 'Inpatient Hospital'
    WHEN bill_type2 IN ('13','14','43','44','85','83','78','84','87','71','77',
                        '53','54','63','64','72','74','75','79','89','12') THEN 'Outpatient Hospital'
    WHEN bill_type2 IN ('32', '33', '34')                            THEN 'Professional'
    WHEN bill_type2 IN ('86','21','23','25','26','27','51','52','18','28','48','58','81','82',
                        '16','17','45','47','55','57','65','67')     THEN 'Long-Term Care'
    ELSE 'Other'
  END AS service_category,
  CASE
    WHEN src = 'pde' THEN 'Prescription drugs (Part D)'
    WHEN src = 'dme' THEN 'Durable medical equipment'
    WHEN src = 'carrier' THEN CASE
         WHEN pos_cd IN ('19','21','22','23')      THEN 'Inpatient/outpatient hospital setting'
         WHEN pos_cd IN ('11','02','10')           THEN 'Office (incl. telehealth)'
         WHEN pos_cd = '20'                        THEN 'Urgent care'
         WHEN pos_cd = '17'                        THEN 'Retail clinic'
         WHEN pos_cd IN ('50','72')                THEN 'FQHC/RHC'
         WHEN pos_cd IN ('12','14','65')           THEN 'Services at home'
         WHEN pos_cd IN ('13','31','32','33','34') THEN 'Nursing facility / hospice setting'
         ELSE 'Other professional' END
    WHEN bill_type2 IN ('11','41')                 THEN 'Acute care hospital'
    WHEN bill_type2 IN ('13','14','43','44','85','12') THEN 'Hospital outpatient'
    WHEN bill_type2 IN ('83','78','84','87')       THEN 'Freestanding facility'
    WHEN bill_type2 IN ('71','77')                 THEN 'FQHC/RHC'
    WHEN bill_type2 IN ('32','33','34')            THEN 'Home health'
    WHEN bill_type2 IN ('21','23','25','26','27','51','52') THEN 'Skilled nursing facility'
    WHEN bill_type2 IN ('18','28','48','58')       THEN 'Swing beds'
    WHEN bill_type2 IN ('81','82')                 THEN 'Hospice'
    WHEN bill_type2 = '86'                         THEN 'Residential facility'
    WHEN bill_type2 IN ('16','17','45','47','55','57','65','67') THEN 'Intermediate care facility'
    ELSE 'Other facility'
  END AS subcategory,
  CASE WHEN src <> 'carrier' THEN NULL
       WHEN betos_cd IS NULL THEN 'Unclassified'
       ELSE CASE left(betos_cd, 1)
            WHEN 'M' THEN 'E&M' WHEN 'P' THEN 'Procedures' WHEN 'I' THEN 'Imaging'
            WHEN 'T' THEN 'Tests' WHEN 'D' THEN 'DME' WHEN 'O' THEN 'Other'
            ELSE 'Exceptions/unclassified' END
  END AS type_of_service,
  year(svc_dt)  AS yr,
  month(svc_dt) AS mo
FROM claim_line cl;

-- Step 2c: Keep spend incurred in an eligible month. Medical categories need a Part A+B FFS month;
-- retail pharmacy also needs Part D that month. Spend outside eligibility is counted in 06_validation.
CREATE OR REPLACE TABLE spend AS
SELECT c.*, m.dual, m.age_band, m.sex
FROM claim_line_cat c
JOIN member_month m
  ON m.bene_id = c.bene_id AND m.yr = c.yr AND m.mo = c.mo
 AND m.ab_ffs AND (c.src <> 'pde' OR m.partd)
WHERE c.medicare_primary AND c.medicare_paid;
