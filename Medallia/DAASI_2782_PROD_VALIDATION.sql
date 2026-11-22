/* ---------------------------------------------------------------------------
   DAASI-2782 Prod deployment validation. Three read-only queries.

   Run query 2 once right BEFORE the deploy and again right AFTER it.
   Run queries 1 and 3 after the deploy.
--------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   1. The new fields return the right amounts.

   Two dates whose answers are known from the source system.

   Expected
                    MP_DB_PC_100   MP_DB_PC_50   PROGRESSIVE     JACKPOT
     CAC  8/7          21,090.00     10,545.00      4,518.74
     IBH  8/13          3,360.00      1,680.00                  1,000.00
     Every other new field blank or zero.
--------------------------------------------------------------------------- */
SELECT
    TRIM(PROPERTY_CD)      AS PROPERTY_CODE,
    GAMING_DT              AS GAMING_DATE,
    SUM(MP_DB_PC_100)      AS MP_DB_PC_100,
    SUM(MP_DB_PC_50)       AS MP_DB_PC_50,
    SUM(PROGRESSIVE)       AS PROGRESSIVE,
    SUM(COMP_VIGORI)       AS COMP_VIGORI,
    SUM(COUPONS)           AS COUPONS,
    SUM(JACKPOT)           AS JACKPOT
FROM DAAS_PROD.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
WHERE (TRIM(PROPERTY_CD) = 'CAC' AND GAMING_DT = DATE '2026-08-07')
   OR (TRIM(PROPERTY_CD) = 'IBH' AND GAMING_DT = DATE '2026-08-13')
GROUP BY 1, 2
ORDER BY 1;


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
   3. Every bucket dollar lands in exactly one new field.

   The same layout and dates as the dry run on 11/22, now read from the
   deployed view.

   VIEW_DOLLARS     the five stored fields added together (MP_DB_PC_50 is
                    left out, because it is half of MP_DB_PC_100)
   SOURCE_DOLLARS   the bucket amounts in CMPTST for the same property and
                    dates (latest version of each amount, deletes left out)
   DIFFERENCE       SOURCE_DOLLARS minus VIEW_DOLLARS

   Only properties with money in these buckets are listed.

   Expected
     DIFFERENCE is 0.00 on every row.
     The amounts match the dry run.
--------------------------------------------------------------------------- */
WITH V AS
(
    SELECT
        TRIM(PROPERTY_CD)      AS PROPERTY_CODE,
        SUM(MP_DB_PC_100)      AS MP_DB_PC_100,
        SUM(PROGRESSIVE)       AS PROGRESSIVE,
        SUM(COMP_VIGORI)       AS COMP_VIGORI,
        SUM(COUPONS)           AS COUPONS,
        SUM(JACKPOT)           AS JACKPOT,
        SUM(  NVL(MP_DB_PC_100, 0)
            + NVL(PROGRESSIVE, 0)
            + NVL(COMP_VIGORI, 0)
            + NVL(COUPONS, 0)
            + NVL(JACKPOT, 0)) AS VIEW_DOLLARS
    FROM DAAS_PROD.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
    WHERE GAMING_DT BETWEEN DATE '2026-05-01' AND DATE '2026-11-20'
    GROUP BY 1
),
SOURCE_AMOUNTS AS
(
    SELECT PROPERTY_CODE, TAMTST, OPERATION_TYPE
    FROM DAAS_PROD.DAAS_RAW_HETCMS.CMPTST_RAW
    WHERE TYPTST IN ('01', '03', '04', '05', '06', '07', '08')
      AND SHHTST BETWEEN DATEDIFF(DAY, DATE '1899-12-31', DATE '2026-05-01')
                     AND DATEDIFF(DAY, DATE '1899-12-31', DATE '2026-11-20')
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE, CMPTST, CLBTST, PITTST, SPITST, GAMTST, TBLTST, SHHTST, SHFTST, TYPTST
                                    ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
),
S AS
(
    SELECT
        TRIM(PROPERTY_CODE)    AS PROPERTY_CODE,
        SUM(TAMTST)            AS SOURCE_DOLLARS
    FROM SOURCE_AMOUNTS
    WHERE NVL(OPERATION_TYPE, -1) NOT IN (0, 5, 8)
    GROUP BY 1
)
SELECT
    COALESCE(V.PROPERTY_CODE, S.PROPERTY_CODE)               AS PROPERTY_CODE,
    V.MP_DB_PC_100,
    V.PROGRESSIVE,
    V.COMP_VIGORI,
    V.COUPONS,
    V.JACKPOT,
    NVL(V.VIEW_DOLLARS, 0)                                   AS VIEW_DOLLARS,
    NVL(S.SOURCE_DOLLARS, 0)                                 AS SOURCE_DOLLARS,
    NVL(S.SOURCE_DOLLARS, 0) - NVL(V.VIEW_DOLLARS, 0)        AS DIFFERENCE
FROM V
FULL OUTER JOIN S
  ON S.PROPERTY_CODE = V.PROPERTY_CODE
WHERE NVL(V.VIEW_DOLLARS, 0) <> 0
   OR NVL(S.SOURCE_DOLLARS, 0) <> 0
ORDER BY 1;
