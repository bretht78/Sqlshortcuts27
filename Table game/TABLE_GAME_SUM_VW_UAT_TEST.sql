create or replace view DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW(
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
	MP_DB_PC_50,                        -- DAASI-2782
	MP_DB_PC_100,                       -- DAASI-2782
	PROGRESSIVE,                        -- DAASI-2782
	COMP_VIGORI,                        -- DAASI-2782
	COUPONS,                            -- DAASI-2782
	JACKPOT                             -- DAASI-2782
) as
/* ===========================================================================
   UAT TEST VERSION OF THIS VIEW (DAASI-2782). NOT FOR PROD.

   UAT has no current copy of the three source tables this view reads, so
   three FROM lines below read stand-in tables in DAAS_TEMP_WORK instead.
   Each one is marked "UAT TEST ONLY" and shows the real line next to it.
   Nothing else differs from the Prod version of this file.

   The stand-in tables exist only in UAT. If this version were ever deployed
   to Prod, the deploy would fail because those tables are not there.
=========================================================================== */
/* ---------------------------------------------------------------------------
   DAASI-2782: six Master Gaming Report drop fields (added at the end of the
   view so the position of every existing column is unchanged)
   ---------------------------------------------------------------------------
   Where the dollars come from
     CMPTST (Table Summary Trailer) holds one row per table, shift and bucket.
     TYPTST is the bucket number and TAMTST is the dollar amount.

   Why the bucket names are read from SYPCN
     Buckets 01, 03, 04 and 05 are "soft". Each property names them itself in
     its TABLEINFO record in SYPCN. Most properties keep the standard names.
     IBH renamed bucket 03 to JACKPOT and bucket 05 to PROMO CHIPS. Reading
     the name from the property's own record is what keeps IBH's jackpot
     dollars out of the Progressive column.

   How a bucket picks its column
     1. A name containing JACKPOT                    -> JACKPOT
     2. A name containing PROMO or MATCH,
        or starting with MP/                         -> MP_DB_PC_100
     3. Otherwise the bucket's standard home:
          04 -> COMP_VIGORI    03 -> PROGRESSIVE    05 -> COUPONS
          01, 06, 07, 08 -> MP_DB_PC_100
          (match play, debit card / eBuy-in, eWallet, promo chip)
     A property with no TABLEINFO record gets rule 3 for every bucket.

   MP_DB_PC_50 is half of MP_DB_PC_100, as the business defines that line.

   Rows with no bucket amounts return NULL in the six fields, which includes
   every legacy Teradata row and anything before CMPTST started loading.
--------------------------------------------------------------------------- */
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
QUALIFY ROW_NUMBER() OVER (PARTITION BY TRIM(PROPERTY_CD),TRIM(PIT_NBR),TRIM(TABLE_NBR), TRIM(PROP_GAME_CD),TRIM(GAMING_HYD),TRIM(TABLE_DAY_NBR) ORDER BY D_TIMESTAMP DESC) = 1;
