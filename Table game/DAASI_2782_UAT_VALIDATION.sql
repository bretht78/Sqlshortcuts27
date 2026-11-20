/* ---------------------------------------------------------------------------
   DAASI-2782 validation in UAT. Run after the view is deployed to UAT.
   Three read-only queries. Nothing is created or changed.

   UAT's view reads stand-in copies of its three source tables. They were
   copied from Prod on 2026-11-20, so UAT and Prod hold the same data for
   past dates.
--------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   1. The new fields return the right amounts.

   Two dates whose answers are known from the source system.

   Expected
     CAC  2026-08-07   MP_DB_PC_100 21,090.00   MP_DB_PC_50 10,545.00   PROGRESSIVE 4,518.74
     IBH  2026-08-13   MP_DB_PC_100  3,360.00   MP_DB_PC_50  1,680.00   JACKPOT     1,000.00
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
FROM DAAS_UAT.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
WHERE (TRIM(PROPERTY_CD) = 'CAC' AND GAMING_DT = DATE '2026-08-07')
   OR (TRIM(PROPERTY_CD) = 'IBH' AND GAMING_DT = DATE '2026-08-13')
GROUP BY 1, 2
ORDER BY 1;


/* ---------------------------------------------------------------------------
   2. Nothing that was already in the view changed.

   The current Prod view (before the change) next to the new UAT view (after
   the change), for August through October 2026, all properties.

   Expected: the two rows are identical. Same number of rows, same drop,
   same win.
--------------------------------------------------------------------------- */
SELECT
    'BEFORE: current Prod view'  AS VERSION,
    COUNT(*)                     AS ROW_COUNT,
    SUM(F_DROP)                  AS F_DROP,
    SUM(WIN)                     AS WIN
FROM DAAS_PROD.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
WHERE GAMING_DT BETWEEN DATE '2026-08-01' AND DATE '2026-10-31'
UNION ALL
SELECT
    'AFTER: new UAT view'        AS VERSION,
    COUNT(*)                     AS ROW_COUNT,
    SUM(F_DROP)                  AS F_DROP,
    SUM(WIN)                     AS WIN
FROM DAAS_UAT.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
WHERE GAMING_DT BETWEEN DATE '2026-08-01' AND DATE '2026-10-31'
ORDER BY 1 DESC;


/* ---------------------------------------------------------------------------
   3. Every bucket dollar in the source is in the view, exactly once.

   SOURCE_DOLLARS  the bucket amounts in the source table (the latest version
                   of each amount, with deleted rows left out)
   VIEW_DOLLARS    the five stored new fields in the view, added together
                   (MP_DB_PC_50 is left out because it is half of
                   MP_DB_PC_100, not money of its own)

   Same period: August through October 2026, all properties.

   Expected: DIFFERENCE = 0.00
--------------------------------------------------------------------------- */
WITH SOURCE_AMOUNTS AS
(
    SELECT
        TAMTST,
        OPERATION_TYPE
    FROM DAAS_UAT.DAAS_TEMP_WORK.CMPTST_RAW_DAASI_2782
    WHERE TYPTST IN ('01', '03', '04', '05', '06', '07', '08')
      AND SHHTST BETWEEN DATEDIFF(DAY, DATE '1899-12-31', DATE '2026-08-01')
                     AND DATEDIFF(DAY, DATE '1899-12-31', DATE '2026-10-31')
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE, CMPTST, CLBTST, PITTST, SPITST, GAMTST, TBLTST, SHHTST, SHFTST, TYPTST
                                    ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
),
S AS
(
    SELECT SUM(TAMTST) AS SOURCE_DOLLARS
    FROM SOURCE_AMOUNTS
    WHERE NVL(OPERATION_TYPE, -1) NOT IN (0, 5, 8)
),
V AS
(
    SELECT SUM(  NVL(MP_DB_PC_100, 0)
               + NVL(PROGRESSIVE, 0)
               + NVL(COMP_VIGORI, 0)
               + NVL(COUPONS, 0)
               + NVL(JACKPOT, 0)) AS VIEW_DOLLARS
    FROM DAAS_UAT.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
    WHERE GAMING_DT BETWEEN DATE '2026-08-01' AND DATE '2026-10-31'
)
SELECT
    S.SOURCE_DOLLARS,
    V.VIEW_DOLLARS,
    S.SOURCE_DOLLARS - V.VIEW_DOLLARS AS DIFFERENCE
FROM S
CROSS JOIN V;
