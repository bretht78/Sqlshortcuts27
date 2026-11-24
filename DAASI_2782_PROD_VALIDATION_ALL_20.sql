/* ---------------------------------------------------------------------------
   DAASI-2782 Prod deployment validation, all 20 properties.
   Version of 2026-11-23. It replaces the earlier Prod validation files.
   Three read-only queries.

   Before the deploy   run queries 2 and 3, and the dry run file
   After the deploy    run queries 1, 2 and 3
--------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   1. The six new fields, for all 20 properties.

   The same table as the dry run, now read from the deployed view.

   One row for each of the 20 properties whose bucket names were loaded,
   then one row that adds together every other property.
   Dates: May 1 through November 20, 2026.

   The six new fields come first, then:
   VIEW_DOLLARS     the five stored fields added together (MP_DB_PC_50 is
                    left out, because it is half of MP_DB_PC_100)
   SOURCE_DOLLARS   the bucket amounts in CMPTST for the same property and
                    dates (latest version of each amount, deletes left out)
   DIFFERENCE       SOURCE_DOLLARS minus VIEW_DOLLARS

   Blank means no bucket at that property feeds the field.
   0.00 means a bucket feeds it but holds no money.

   Expected
     21 rows, matching the dry run row for row.
     Every row    DIFFERENCE is 0.00: each dollar lands in exactly one field.
     LUS          MP_DB_PC_100 is 524,873.00 (its CHIPS bucket, as of the
                  11/22 run) and COMP_VIGORI is blank.
     TAC          COUPONS is blank. Its P CHIPS 50% dollars are in
                  MP_DB_PC_100.
     IBH          JACKPOT is filled and PROGRESSIVE is blank.
     CCR, HNE     zero or blank: their amounts in these buckets add up to
                  zero for this period.
     Last row     zero or blank: no other property books to these buckets.
--------------------------------------------------------------------------- */
SELECT
    P.PROPERTY_CODE,
    V.MP_DB_PC_50,
    V.MP_DB_PC_100,
    V.PROGRESSIVE,
    V.COMP_VIGORI,
    V.COUPONS,
    V.JACKPOT,
    NVL(V.VIEW_DOLLARS, 0)                                   AS VIEW_DOLLARS,
    NVL(S.SOURCE_DOLLARS, 0)                                 AS SOURCE_DOLLARS,
    NVL(S.SOURCE_DOLLARS, 0) - NVL(V.VIEW_DOLLARS, 0)        AS DIFFERENCE
FROM
(
    SELECT COLUMN1 AS PROPERTY_CODE, COLUMN2 AS SORT_ORDER
    FROM VALUES ('ATL',  1), ('CAC',  2), ('CCR',  3), ('CHE',  4), ('CLV',  5),
                ('CVR',  6), ('HHP',  7), ('HNE',  8), ('IBE',  9), ('IBH', 10),
                ('IBV', 11), ('ILC', 12), ('IWA', 13), ('LUS', 14), ('NKC', 15),
                ('NOR', 16), ('TAC', 17), ('UEL', 18), ('UHA', 19), ('UIN', 20),
                ('ALL OTHER PROPERTIES', 21)
) P
LEFT JOIN
(
    SELECT
        IFF(TRIM(PROPERTY_CD) IN ('ATL', 'CAC', 'CCR', 'CHE', 'CLV', 'CVR', 'HHP', 'HNE', 'IBE', 'IBH',
                                  'IBV', 'ILC', 'IWA', 'LUS', 'NKC', 'NOR', 'TAC', 'UEL', 'UHA', 'UIN'),
            TRIM(PROPERTY_CD), 'ALL OTHER PROPERTIES')
                                 AS PROPERTY_CODE,
        SUM(MP_DB_PC_50)         AS MP_DB_PC_50,
        SUM(MP_DB_PC_100)        AS MP_DB_PC_100,
        SUM(PROGRESSIVE)         AS PROGRESSIVE,
        SUM(COMP_VIGORI)         AS COMP_VIGORI,
        SUM(COUPONS)             AS COUPONS,
        SUM(JACKPOT)             AS JACKPOT,
        SUM(  NVL(MP_DB_PC_100, 0)
            + NVL(PROGRESSIVE, 0)
            + NVL(COMP_VIGORI, 0)
            + NVL(COUPONS, 0)
            + NVL(JACKPOT, 0))   AS VIEW_DOLLARS
    FROM DAAS_PROD.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
    WHERE GAMING_DT BETWEEN DATE '2026-05-01' AND DATE '2026-11-20'
    GROUP BY 1
) V
  ON V.PROPERTY_CODE = P.PROPERTY_CODE
LEFT JOIN
(
    SELECT
        IFF(TRIM(L.PROPERTY_CODE) IN ('ATL', 'CAC', 'CCR', 'CHE', 'CLV', 'CVR', 'HHP', 'HNE', 'IBE', 'IBH',
                                      'IBV', 'ILC', 'IWA', 'LUS', 'NKC', 'NOR', 'TAC', 'UEL', 'UHA', 'UIN'),
            TRIM(L.PROPERTY_CODE), 'ALL OTHER PROPERTIES')
                                 AS PROPERTY_CODE,
        SUM(L.TAMTST)            AS SOURCE_DOLLARS
    FROM
    (
        SELECT PROPERTY_CODE, TAMTST, OPERATION_TYPE
        FROM DAAS_PROD.DAAS_RAW_HETCMS.CMPTST_RAW
        WHERE TYPTST IN ('01', '03', '04', '05', '06', '07', '08')
          AND SHHTST BETWEEN DATEDIFF(DAY, DATE '1899-12-31', DATE '2026-05-01')
                         AND DATEDIFF(DAY, DATE '1899-12-31', DATE '2026-11-20')
        QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE, CMPTST, CLBTST, PITTST, SPITST, GAMTST, TBLTST, SHHTST, SHFTST, TYPTST
                                        ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
    ) L
    WHERE NVL(L.OPERATION_TYPE, -1) NOT IN (0, 5, 8)
    GROUP BY 1
) S
  ON S.PROPERTY_CODE = P.PROPERTY_CODE
ORDER BY P.SORT_ORDER;


/* ---------------------------------------------------------------------------
   2. Nothing that was already in the view changed.

   Run once right BEFORE the deploy and once right AFTER it.

   FINGERPRINT is one number calculated from every value in the 40 columns
   the view had before this change, on every row from May 1 through
   November 20, 2026. If a single value in a single row were different,
   this number would be different. D_TIMESTAMP is left out because it holds
   the time the query runs, so it changes on every run.

   The dates stop at November 20 so that new shifts arriving between the
   two runs cannot change the result.

   Expected: the BEFORE and AFTER results are identical.
   The run time Snowflake shows for each run also compares speed before and
   after.
--------------------------------------------------------------------------- */
SELECT
    COUNT(*)               AS ROW_COUNT,
    SUM(F_DROP)            AS F_DROP,
    SUM(WIN)               AS WIN,
    HASH_AGG(
        PROPERTY_CD, RECORD_CD, COMPANY, CLUB, PIT_NBR, SUB_PIT_NBR,
        PROP_GAME_CD, TABLE_NBR, TABLE_DAY_NBR, GAMING_HYD, GAMING_DT,
        SHIFT, TABLE_OPENER, FILLS_COMP_CNT, FILLS_COMP,
        FILLS_ISSUED_CNT, FILLS_ISSUED, CREDITS_COMP_CNT, CREDITS_COMP,
        CREDITS_ISSUED_CNT, CREDITS_ISSUED, MARKERS_COMP_CNT,
        MARKERS_COMP, MARKERS_ISSUED_CNT, MARKERS_ISSUED,
        MARKERS_REDEEM_CNT, MARKERS_REDEEM, SFK_COMP_CNT, SFK_COMP,
        SFK_ISSUED_CNT, SFK_ISSUED, TABLE_CLOSER, FOREIGN_HOUSE_CHECKS,
        COIN_AMT, DROP_CNT, F_DROP, POKER_RT, WIN, WIN_PCT, QUALITY_CD
    )                      AS FINGERPRINT
FROM DAAS_PROD.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
WHERE GAMING_DT BETWEEN DATE '2026-05-01' AND DATE '2026-11-20';


/* ---------------------------------------------------------------------------
   3. The three views built on this one still run.

   Run once right BEFORE the deploy and once right AFTER it.

   Snowflake's dependency records list these three views as built on
   TABLE_GAME_SUM_VW. A view written as SELECT * on top of it would stop
   working once it gains six columns, and Snowflake would return a column
   error naming that view. The BEFORE run shows whether any of them already
   fails for some other reason.

   Expected: three rows, BEFORE and AFTER. Any count is a pass.
--------------------------------------------------------------------------- */
SELECT 'DAAS_EXPORT_VW.TABLE_TRACKER_EXTRACT_VW'          AS VIEW_NAME,
       COUNT(*)                                           AS ROWS_READ
FROM (SELECT * FROM DAAS_PROD.DAAS_EXPORT_VW.TABLE_TRACKER_EXTRACT_VW LIMIT 1)
UNION ALL
SELECT 'DAAS_RAW_BRAVO_VW.GAME_HEADCOUNT_FACT_CSV_OLD_VW',
       COUNT(*)
FROM (SELECT * FROM DAAS_PROD.DAAS_RAW_BRAVO_VW.GAME_HEADCOUNT_FACT_CSV_OLD_VW LIMIT 1)
UNION ALL
SELECT 'DAAS_RAW_IGT_VW.TABLE_MANAGER_HEADCOUNT_FACT_VW',
       COUNT(*)
FROM (SELECT * FROM DAAS_PROD.DAAS_RAW_IGT_VW.TABLE_MANAGER_HEADCOUNT_FACT_VW LIMIT 1);
