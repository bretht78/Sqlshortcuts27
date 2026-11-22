/* ---------------------------------------------------------------------------
   DAASI-2782 chips check. Two read-only queries. Nothing is created or
   changed.

   Refresh UAT's copy of the bucket names first, so UAT has all 20 properties.
--------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   1. How does the source system itself treat each bucket name?  (reads Prod)

   A property's TABLEINFO record holds two things for a bucket: the name the
   property gave it, and a percent setting stored beside it. The record
   labels that setting %CALC (MATCH PLAY % for bucket 01).

   This lists every bucket name in use, with its percent setting and the
   properties that use it. Buckets 06 and 08 have no name the property can
   change, so their fixed labels are shown (debit card and promo chip).

   What to look for
     Do CHIPS and P CHIPS 50% carry the same percent as PROMO CHIPS and as
     bucket 08, the source system's own promo chip bucket?
     If they do, the source system treats them the way it treats promo
     chips, which is what the new rule in the view assumes.
--------------------------------------------------------------------------- */
WITH TABLE_INFO AS
(
    SELECT *
    FROM DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW
    WHERE TRIM(MDLECN) = 'TABLEINFO'
      AND TRIM(MTYPCN) = 'CTL'
      AND MSEQCN = 0
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE
                                    ORDER BY CREATED_DATE DESC NULLS LAST, OPERATION_DATE DESC NULLS LAST, OPERATION_SEQUENCE_NBR DESC NULLS LAST) = 1
),
BUCKETS AS
(
    SELECT PROPERTY_CODE,
           '01'                  AS BUCKET,
           UPPER(TRIM(CDD2CN))   AS BUCKET_NAME,
           UPPER(TRIM(AMD2CN))   AS SETTING_LABEL,
           AMT2CN::NUMBER(18,2)  AS PERCENT_SETTING
    FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE,
           '03'                  AS BUCKET,
           UPPER(TRIM(CDD3CN))   AS BUCKET_NAME,
           UPPER(TRIM(NBD3CN))   AS SETTING_LABEL,
           NBR3CN::NUMBER(18,2)  AS PERCENT_SETTING
    FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE,
           '04'                  AS BUCKET,
           UPPER(TRIM(CDD1CN))   AS BUCKET_NAME,
           UPPER(TRIM(NBD1CN))   AS SETTING_LABEL,
           NBR1CN::NUMBER(18,2)  AS PERCENT_SETTING
    FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE,
           '05'                  AS BUCKET,
           UPPER(TRIM(CDD4CN))   AS BUCKET_NAME,
           UPPER(TRIM(NBD4CN))   AS SETTING_LABEL,
           NBR4CN::NUMBER(18,2)  AS PERCENT_SETTING
    FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE,
           '06'                  AS BUCKET,
           UPPER(TRIM(AMD3CN))   AS BUCKET_NAME,
           UPPER(TRIM(NBD2CN))   AS SETTING_LABEL,
           NBR2CN::NUMBER(18,2)  AS PERCENT_SETTING
    FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE,
           '08'                  AS BUCKET,
           UPPER(TRIM(AMD4CN))   AS BUCKET_NAME,
           UPPER(TRIM(NBD5CN))   AS SETTING_LABEL,
           NBR5CN::NUMBER(18,2)  AS PERCENT_SETTING
    FROM TABLE_INFO
)
SELECT
    BUCKET,
    BUCKET_NAME,
    PERCENT_SETTING,
    COUNT(*)                                                            AS PROPERTY_COUNT,
    LISTAGG(PROPERTY_CODE, ', ') WITHIN GROUP (ORDER BY PROPERTY_CODE)  AS PROPERTIES,
    MAX(SETTING_LABEL)                                                  AS SETTING_LABEL
FROM BUCKETS
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;


/* ---------------------------------------------------------------------------
   2. What the chips rule changes.  (reads UAT)

   Run with DAAS_UAT selected as the database.

   Every property gets two rows:
     1 DEPLOYED VIEW   the view as it is deployed in UAT right now
     2 NEW SQL         the SQL of the updated view, run directly (it is the
                       UAT test file, unchanged, between the two markers)
   The four properties with a chips name are listed on their own. Everyone
   else is added together as ALL OTHERS. Dates: May 2026 forward.
   TOTAL adds the five fields together.

   Expected BEFORE the updated view is deployed
     ALL OTHERS        the two rows are identical
     HNE, LUS          the COMP_VIGORI amount moves to MP_DB_PC_100
     TAC               the COUPONS amount moves to MP_DB_PC_100
     IBV               no dollars move, because its CHIPS bucket is empty.
                       PROGRESSIVE changes from 0.00 to blank.
     Every property    TOTAL is the same on both rows (money only changes
                       columns, none is gained or lost)
   A blank means no bucket at that property feeds the field any more.

   Expected AFTER the updated view is deployed
     The two rows are identical for every property.

   If it says an object does not exist or is not authorized, check that
   DAAS_UAT is the selected database. If it is, run the statement
   USE SECONDARY ROLES ALL and try again.
--------------------------------------------------------------------------- */
SELECT
    X.PROPERTY_CODE,
    X.VERSION,
    SUM(X.MP_DB_PC_100)      AS MP_DB_PC_100,
    SUM(X.PROGRESSIVE)       AS PROGRESSIVE,
    SUM(X.COMP_VIGORI)       AS COMP_VIGORI,
    SUM(X.COUPONS)           AS COUPONS,
    SUM(X.JACKPOT)           AS JACKPOT,
    SUM(  NVL(X.MP_DB_PC_100, 0)
        + NVL(X.PROGRESSIVE, 0)
        + NVL(X.COMP_VIGORI, 0)
        + NVL(X.COUPONS, 0)
        + NVL(X.JACKPOT, 0)) AS TOTAL
FROM
(
    SELECT
        IFF(TRIM(D.PROPERTY_CD) IN ('HNE', 'IBV', 'LUS', 'TAC'), TRIM(D.PROPERTY_CD), 'ALL OTHERS') AS PROPERTY_CODE,
        '1 DEPLOYED VIEW'    AS VERSION,
        D.MP_DB_PC_100,
        D.PROGRESSIVE,
        D.COMP_VIGORI,
        D.COUPONS,
        D.JACKPOT
    FROM DAAS_UAT.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW  D
    WHERE D.GAMING_DT >= DATE '2026-05-01'

    UNION ALL

    SELECT
        IFF(TRIM(V.PROPERTY_CD) IN ('HNE', 'IBV', 'LUS', 'TAC'), TRIM(V.PROPERTY_CD), 'ALL OTHERS') AS PROPERTY_CODE,
        '2 NEW SQL'          AS VERSION,
        V.MP_DB_PC_100,
        V.PROGRESSIVE,
        V.COMP_VIGORI,
        V.COUPONS,
        V.JACKPOT
    FROM
    (
/* ===== the updated view's SQL, unchanged, starts here ===== */
WITH CMPTS_RAW AS
(
    SELECT
	PROPERTY_CODE,
	RCODTS,
	CMPYTS,
	CLUBTS,
	OPNRTS,
	TABLTS,
	GAMETS,
	SHHDTS,
	SPITTS,
	SHFTTS,
	"PIT#TS",
	"FC@#TS",
	"FC@$TS",
    "FI@#TS",
    "FI@$TS",
    "CC@#TS",
    "CC@$TS",
    "CI@#TS",
    "CI@$TS",
    "MKC#TS",
    "MKC$TS",
    "MKI#TS",
    "MKI$TS",
    "MKR#TS",
    "MKR$TS",
    "SKC#TS",
    "SKC$TS",
    "SKI#TS",
    "SKI$TS",
    "CLOSTS",
    "FGN$TS",
    "CON$TS",
    "DRP#TS",
    "DRP$TS",
    "PKR$TS",
    "WIN$TS",
    "WPCTTS",
	"DAY#TS",
	OPERATION_TYPE
    FROM DAAS_TEMP_WORK.CMPTS_RAW_DAASI_2782 /* UAT TEST ONLY (DAASI-2782). Real line: FROM DAAS_RAW_HETCMS.CMPTS_RAW */
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE, "PIT#TS", TABLTS, GAMETS, SHHDTS,"DAY#TS"
                                    ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
),
TABLE_INFO AS                                                           -- DAASI-2782
(
    /* Each property's latest TABLEINFO record: the names it gave its buckets */
    SELECT
        PROPERTY_CODE,
        UPPER(TRIM(CDD1CN))             AS NAME_1,
        UPPER(TRIM(CDD2CN))             AS NAME_2,
        UPPER(TRIM(CDD3CN))             AS NAME_3,
        UPPER(TRIM(CDD4CN))             AS NAME_4
    FROM DAAS_TEMP_WORK.SYPCN_RAW_DAASI_2782 /* UAT TEST ONLY (DAASI-2782). Real line: FROM DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW */
    WHERE TRIM(MDLECN) = 'TABLEINFO'
      AND TRIM(MTYPCN) = 'CTL'
      AND MSEQCN = 0
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE
                                    ORDER BY CREATED_DATE DESC NULLS LAST, OPERATION_DATE DESC NULLS LAST, OPERATION_SEQUENCE_NBR DESC NULLS LAST) = 1
),
BUCKET_NAMES AS                                                         -- DAASI-2782
(
    /* The report program ties each name slot to a fixed bucket number */
    SELECT PROPERTY_CODE, '04' AS TYPTST, NAME_1 AS BUCKET_NAME FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE, '01' AS TYPTST, NAME_2 AS BUCKET_NAME FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE, '03' AS TYPTST, NAME_3 AS BUCKET_NAME FROM TABLE_INFO
    UNION ALL
    SELECT PROPERTY_CODE, '05' AS TYPTST, NAME_4 AS BUCKET_NAME FROM TABLE_INFO
),
CMPTST_LATEST AS                                                        -- DAASI-2782
(
    /* Latest version of every bucket amount (same pattern as CMPTS_RAW above) */
    SELECT
        PROPERTY_CODE,
        CMPTST,
        CLBTST,
        PITTST,
        SPITST,
        GAMTST,
        TBLTST,
        SHHTST,
        SHFTST,
        TYPTST,
        TAMTST,
        OPERATION_TYPE
    FROM DAAS_TEMP_WORK.CMPTST_RAW_DAASI_2782 /* UAT TEST ONLY (DAASI-2782). Real line: FROM DAAS_RAW_HETCMS.CMPTST_RAW */
    WHERE TYPTST IN ('01', '03', '04', '05', '06', '07', '08')
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE, CMPTST, CLBTST, PITTST, SPITST, GAMTST, TBLTST, SHHTST, SHFTST, TYPTST
                                    ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
),
CMPTST_FIELD AS                                                         -- DAASI-2782
(
    /* Each amount picks its column from the property's own name for that bucket */
    SELECT
        A.PROPERTY_CODE,
        A.CMPTST,
        A.CLBTST,
        A.PITTST,
        A.SPITST,
        A.GAMTST,
        A.TBLTST,
        A.SHHTST,
        A.SHFTST,
        A.TAMTST,
        CASE WHEN N.BUCKET_NAME LIKE '%JACKPOT%' THEN 'JACKPOT'
             WHEN N.BUCKET_NAME LIKE '%PROMO%'
               OR N.BUCKET_NAME LIKE '%MATCH%'
               OR N.BUCKET_NAME LIKE '%CHIP%'
               OR N.BUCKET_NAME LIKE 'MP/%'      THEN 'MP_DB_PC'
             WHEN A.TYPTST = '04'                THEN 'COMP_VIGORI'
             WHEN A.TYPTST = '03'                THEN 'PROGRESSIVE'
             WHEN A.TYPTST = '05'                THEN 'COUPONS'
             ELSE                                     'MP_DB_PC'
        END                             AS FIELD
    FROM CMPTST_LATEST  A
    LEFT JOIN BUCKET_NAMES  N
           ON  N.PROPERTY_CODE = A.PROPERTY_CODE
           AND N.TYPTST        = A.TYPTST
    WHERE NVL(A.OPERATION_TYPE, -1) NOT IN (0,5,8)      /* skip rows whose latest version is a delete */
),
CMPTST_PVT AS                                                           -- DAASI-2782
(
    /* One row per table and shift, with the fields side by side */
    SELECT
        PROPERTY_CODE,
        CMPTST,
        CLBTST,
        PITTST,
        SPITST,
        GAMTST,
        TBLTST,
        SHHTST,
        SHFTST,
        SUM(CASE WHEN FIELD = 'MP_DB_PC'    THEN TAMTST END) AS MP_DB_PC_100,
        SUM(CASE WHEN FIELD = 'PROGRESSIVE' THEN TAMTST END) AS PROGRESSIVE,
        SUM(CASE WHEN FIELD = 'COMP_VIGORI' THEN TAMTST END) AS COMP_VIGORI,
        SUM(CASE WHEN FIELD = 'COUPONS'     THEN TAMTST END) AS COUPONS,
        SUM(CASE WHEN FIELD = 'JACKPOT'     THEN TAMTST END) AS JACKPOT
    FROM CMPTST_FIELD
    GROUP BY
        PROPERTY_CODE,
        CMPTST,
        CLBTST,
        PITTST,
        SPITST,
        GAMTST,
        TBLTST,
        SHHTST,
        SHFTST
),
TABLE_GAME_SUM AS
(
SELECT
      K.PROPERTY_CODE                   AS PROPERTY_CD,
      K.RCODTS                          AS RECORD_CD ,
      CAST(K.CMPYTS AS CHAR(2))         AS COMPANY,
      CAST(K.CLUBTS AS CHAR(1))         AS CLUB,
      CAST(K."PIT#TS" AS CHAR(2))       AS PIT_NBR ,
      K.SPITTS                          AS SUB_PIT_NBR ,
      CAST(K.GAMETS AS CHAR(2))         AS PROP_GAME_CD,
      CAST(K.TABLTS AS CHAR(3))         AS TABLE_NBR  ,
      CAST(K."DAY#TS" AS CHAR(1))       AS TABLE_DAY_NBR,
      K.SHHDTS                          AS GAMING_HYD ,
     (K.SHHDTS + DATE'1900-01-01' - 1)  AS GAMING_DT ,
      CAST(K.SHFTTS AS CHAR(1))         AS SHIFT ,
      K.OPNRTS                          AS TABLE_OPENER,
      K."FC@#TS"                        AS FILLS_COMP_CNT,
      K."FC@$TS"                        AS FILLS_COMP,
      K."FI@#TS"                        AS FILLS_ISSUED_CNT,
      K."FI@$TS"                        AS FILLS_ISSUED,
      K."CC@#TS"                        AS CREDITS_COMP_CNT,
      K."CC@$TS"                        AS CREDITS_COMP,
      K."CI@#TS"                        AS CREDITS_ISSUED_CNT,
      K."CI@$TS"                        AS CREDITS_ISSUED,
      K."MKC#TS"                        AS MARKERS_COMP_CNT,
      K."MKC$TS"                        AS MARKERS_COMP,
      K."MKI#TS"                        AS MARKERS_ISSUED_CNT,
      K."MKI$TS"                        AS MARKERS_ISSUED,
      K."MKR#TS"                        AS MARKERS_REDEEM_CNT,
      K."MKR$TS"                        AS MARKERS_REDEEM,
      K."SKC#TS"                        AS SFK_COMP_CNT,
      K."SKC$TS"                        AS SFK_COMP,
      K."SKI#TS"                        AS SFK_ISSUED_CNT,
      K."SKI$TS"                        AS SFK_ISSUED,
      K."CLOSTS"                        AS TABLE_CLOSER,
      K."FGN$TS"                        AS FOREIGN_HOUSE_CHECKS,
      K."CON$TS"                        AS COIN_AMT,
      K."DRP#TS"                        AS DROP_CNT,
      K."DRP$TS"                        AS F_DROP,
      K."PKR$TS"                        AS POKER_RT,
      K."WIN$TS"                        AS WIN,
      K.WPCTTS                          AS WIN_PCT  ,
	 CASE WHEN (K.OPERATION_TYPE in (0,5,8))  THEN 'Y' ELSE 'N' END AS DELETE_IND,
      NULL                             AS QUALITY_CD ,
     to_timestamp_ntz(CURRENT_TIMESTAMP)                 AS D_TIMESTAMP,
      ROUND(P.MP_DB_PC_100 * 0.5, 2)    AS MP_DB_PC_50,                 -- DAASI-2782
      P.MP_DB_PC_100                    AS MP_DB_PC_100,                -- DAASI-2782
      P.PROGRESSIVE                     AS PROGRESSIVE,                 -- DAASI-2782
      P.COMP_VIGORI                     AS COMP_VIGORI,                 -- DAASI-2782
      P.COUPONS                         AS COUPONS,                     -- DAASI-2782
      P.JACKPOT                         AS JACKPOT                      -- DAASI-2782
    FROM
        CMPTS_RAW  K
        LEFT JOIN CMPTST_PVT  P                                         -- DAASI-2782
               ON  P.PROPERTY_CODE = K.PROPERTY_CODE                    -- DAASI-2782
               AND P.CMPTST        = K.CMPYTS                           -- DAASI-2782
               AND P.CLBTST        = K.CLUBTS                           -- DAASI-2782
               AND P.PITTST        = K."PIT#TS"                         -- DAASI-2782
               AND P.SPITST        = K.SPITTS                           -- DAASI-2782
               AND P.GAMTST        = K.GAMETS                           -- DAASI-2782
               AND P.TBLTST        = K.TABLTS                           -- DAASI-2782
               AND P.SHHTST        = K.SHHDTS                           -- DAASI-2782
               AND P.SHFTST        = K.SHFTTS                           -- DAASI-2782

UNION ALL
SELECT
	C_PROP_CD              AS PROPERTY_CD,
	C_RECORD_CD            AS RECORD_CD ,
	C_COMPANY              AS COMPANY,
	C_CLUB                 AS CLUB ,
	C_PIT_NUM              AS PIT_NBR ,
	C_SUB_PIT              AS SUB_PIT_NBR ,
	C_PROP_GAME_CD         AS PROP_GAME_CD  ,
	C_TABLE_NUM            AS TABLE_NBR  ,
	C_TABLE_DAY_NUM        AS TABLE_DAY_NBR  ,
	I_GAMING_HYD           AS GAMING_HYD   ,
	D_GAMING_DATE          AS GAMING_DT ,
	C_SHIFT                AS SHIFT  ,
	F_TABLE_OPENER         AS TABLE_OPENER  ,
	I_FILLS_COMP_CNT       AS FILLS_COMP_CNT ,
	F_FILLS_COMP           AS FILLS_COMP,
	I_FILLS_ISSUED_CNT     AS FILLS_ISSUED_CNT,
	F_FILLS_ISSUED         AS FILLS_ISSUED,
	I_CREDITS_COMP_CNT     AS CREDITS_COMP_CNT,
	F_CREDITS_COMP         AS CREDITS_COMP,
	I_CREDITS_ISSUED_CNT   AS CREDITS_ISSUED_CNT,
	F_CREDITS_ISSUED       AS CREDITS_ISSUED,
	I_MARKERS_COMP_CNT     AS MARKERS_COMP_CNT,
	F_MARKERS_COMP         AS MARKERS_COMP,
	I_MARKERS_ISSUED_CNT   AS MARKERS_ISSUED_CNT,
	F_MARKERS_ISSUED       AS MARKERS_ISSUED,
	I_MARKERS_REDEEM_CNT   AS MARKERS_REDEEM_CNT,
	F_MARKERS_REDEEM       AS MARKERS_REDEEM,
	I_SFK_COMP_CNT         AS SFK_COMP_CNT,
	F_SFK_COMP             AS SFK_COMP,
	I_SFK_ISSUED_CNT       AS SFK_ISSUED_CNT,
	F_SFK_ISSUED           AS SFK_ISSUED,
	F_TABLE_CLOSER         AS TABLE_CLOSER,
	F_FOREIGN_HOUSE_CHECKS AS FOREIGN_HOUSE_CHECKS,
	F_COIN_AMOUNT          AS COIN_AMT,
	I_DROP_CNT             AS DROP_CNT,
	F_DROP                 AS F_DROP,
	F_POKER_RATE           AS POKER_RT,
	F_WIN                  AS WIN,
	F_WIN_PCT              AS WIN_PCT  ,
	'N'                    AS DELETE_IND,
	C_QUALITY_CD           AS QUALITY_CD ,
	D_TIMESTAMP            AS D_TIMESTAMP,
	NULL                   AS MP_DB_PC_50,                              -- DAASI-2782
	NULL                   AS MP_DB_PC_100,                             -- DAASI-2782
	NULL                   AS PROGRESSIVE,                              -- DAASI-2782
	NULL                   AS COMP_VIGORI,                              -- DAASI-2782
	NULL                   AS COUPONS,                                  -- DAASI-2782
	NULL                   AS JACKPOT                                   -- DAASI-2782

FROM DAAS_TERADATA_RAW.TABLE_GAME_SUM_RAW
)
SELECT
PROPERTY_CD,
RECORD_CD,
COMPANY,
CLUB,
PIT_NBR,
SUB_PIT_NBR,
PROP_GAME_CD,
TABLE_NBR,
TABLE_DAY_NBR,
GAMING_HYD,
GAMING_DT,
SHIFT,
TABLE_OPENER,
FILLS_COMP_CNT,
FILLS_COMP,
FILLS_ISSUED_CNT,
FILLS_ISSUED,
CREDITS_COMP_CNT,
CREDITS_COMP,
CREDITS_ISSUED_CNT,
CREDITS_ISSUED,
MARKERS_COMP_CNT,
MARKERS_COMP,
MARKERS_ISSUED_CNT,
MARKERS_ISSUED,
MARKERS_REDEEM_CNT,
MARKERS_REDEEM,
SFK_COMP_CNT,
SFK_COMP,
SFK_ISSUED_CNT,
SFK_ISSUED,
TABLE_CLOSER,
FOREIGN_HOUSE_CHECKS,
COIN_AMT,
DROP_CNT,
F_DROP,
POKER_RT,
WIN,
WIN_PCT,
QUALITY_CD,
D_TIMESTAMP,
MP_DB_PC_50,                            -- DAASI-2782
MP_DB_PC_100,                           -- DAASI-2782
PROGRESSIVE,                            -- DAASI-2782
COMP_VIGORI,                            -- DAASI-2782
COUPONS,                                -- DAASI-2782
JACKPOT                                 -- DAASI-2782
FROM TABLE_GAME_SUM
QUALIFY ROW_NUMBER() OVER (PARTITION BY TRIM(PROPERTY_CD),TRIM(PIT_NBR),TRIM(TABLE_NBR), TRIM(PROP_GAME_CD),TRIM(GAMING_HYD),TRIM(TABLE_DAY_NBR) ORDER BY D_TIMESTAMP DESC) = 1
/* ===== the updated view's SQL, unchanged, ends here ===== */
    ) V
    WHERE V.GAMING_DT >= DATE '2026-05-01'
) X
GROUP BY 1, 2
ORDER BY 1, 2;
