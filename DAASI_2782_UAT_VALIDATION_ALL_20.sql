/* ---------------------------------------------------------------------------
   DAASI-2782 UAT validation, all 20 properties. Version of 2026-11-23.
   Three read-only queries. Run them after the updated view is deployed to UAT.

   UAT's view reads copies of its source tables kept in DAAS_TEMP_WORK. The
   amounts were copied from Prod on 11/20, so UAT's numbers stop there.
--------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   1. The six new fields, for all 20 properties.

   One row for each of the 20 properties whose bucket names were loaded,
   then one row that adds together every other property.
   Dates: May 1 through November 20, 2026.

   The six new fields come first, then:
   VIEW_DOLLARS     the five stored fields added together (MP_DB_PC_50 is
                    left out, because it is half of MP_DB_PC_100)
   SOURCE_DOLLARS   the bucket amounts in UAT's copy of CMPTST for the same
                    property and dates (latest version of each amount,
                    deletes left out)
   DIFFERENCE       SOURCE_DOLLARS minus VIEW_DOLLARS

   Blank means no bucket at that property feeds the field.
   0.00 means a bucket feeds it but holds no money.

   Expected
     21 rows.
     Every row    DIFFERENCE is 0.00: each dollar lands in exactly one field.
     LUS          COMP_VIGORI is blank. Its CHIPS dollars are under
                  MP_DB_PC_100 (a little under Prod's 524,873.00, because
                  UAT's copy stops at 11/20).
     TAC          COUPONS is blank. Its P CHIPS 50% dollars are in
                  MP_DB_PC_100.
     IBH          JACKPOT is filled and PROGRESSIVE is blank.
     Last row     zero or blank: no other property books to these buckets.

   If LUS shows an amount under COMP_VIGORI, one of two things is true:
   UAT's copy of the bucket names is out of date (refresh
   SYPCN_RAW_DAASI_2782 and run this again), or the view deployed in UAT is
   still the 11/20 version, from before the chips rule.
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
    FROM DAAS_UAT.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
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
        FROM DAAS_UAT.DAAS_TEMP_WORK.CMPTST_RAW_DAASI_2782
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

   The current Prod view (before the change) next to the UAT view (after the
   change), for August through October 2026, all properties.

   Expected: both rows show the 11/20 result.
     ROW_COUNT 250,542   F_DROP 1,660,766,533.50   WIN 422,719,682.87

   The UAT row is the one that has to match. If only the Prod row has moved,
   Prod received late changes after UAT's copy was taken.
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
   3. Two dates whose answers are known from the source system.

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
FROM DAAS_UAT.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
WHERE (TRIM(PROPERTY_CD) = 'CAC' AND GAMING_DT = DATE '2026-08-07')
   OR (TRIM(PROPERTY_CD) = 'IBH' AND GAMING_DT = DATE '2026-08-13')
GROUP BY 1, 2
ORDER BY 1;
