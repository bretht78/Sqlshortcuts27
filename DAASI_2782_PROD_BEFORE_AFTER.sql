/* ---------------------------------------------------------------------------
   DAASI-2782 Prod: nothing that was already in the view changed.
   Read-only. One query. It can be run any time after the deploy.

   The view was replaced on 11/24, so the old view can no longer be queried.
   This runs the old view's SQL directly, next to the view that is deployed
   now, on the same data at the same moment.

   BEFORE   the previous view's SQL, as it was pulled from Prod on 11/17.
            It is unchanged except that DAAS_PROD is written in front of its
            two table names, so it reads Prod whichever database is selected.
   AFTER    the view deployed in Prod now

   FINGERPRINT is one number calculated from every value in the 40 columns
   the view had before this change, on every row from May 1 through
   November 20, 2026. If a single value in a single row were different,
   this number would be different. D_TIMESTAMP is left out because it holds
   the time the query runs.

   Expected: the two rows are identical.
--------------------------------------------------------------------------- */
SELECT
    'BEFORE: the previous view'  AS VERSION,
    COUNT(*)                     AS ROW_COUNT,
    SUM(F_DROP)                  AS F_DROP,
    SUM(WIN)                     AS WIN,
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
    )                            AS FINGERPRINT
FROM
(
/* ===== the previous view's SQL starts here ===== */
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
    FROM DAAS_PROD.DAAS_RAW_HETCMS.CMPTS_RAW /* NEW TABLE ADDED IN HVR JUST FOR DATA VALIDATION PURPOSE, USE ACTUAL TABLE NOT WITHOUT "2" */
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE, "PIT#TS", TABLTS, GAMETS, SHHDTS,"DAY#TS"
                                    ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
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
     to_timestamp_ntz(CURRENT_TIMESTAMP)                 AS D_TIMESTAMP
    FROM 
        CMPTS_RAW  K
    
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
	D_TIMESTAMP            AS D_TIMESTAMP  
	
FROM DAAS_PROD.DAAS_TERADATA_RAW.TABLE_GAME_SUM_RAW
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
D_TIMESTAMP             
FROM TABLE_GAME_SUM
QUALIFY ROW_NUMBER() OVER (PARTITION BY TRIM(PROPERTY_CD),TRIM(PIT_NBR),TRIM(TABLE_NBR), TRIM(PROP_GAME_CD),TRIM(GAMING_HYD),TRIM(TABLE_DAY_NBR) ORDER BY D_TIMESTAMP DESC) = 1
/* ===== the previous view's SQL ends here ===== */
) PREVIOUS_VIEW
WHERE GAMING_DT BETWEEN DATE '2026-05-01' AND DATE '2026-11-20'
UNION ALL
SELECT
    'AFTER: the deployed view'   AS VERSION,
    COUNT(*)                     AS ROW_COUNT,
    SUM(F_DROP)                  AS F_DROP,
    SUM(WIN)                     AS WIN,
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
    )                            AS FINGERPRINT
FROM DAAS_PROD.DAAS_CORE_UNRATED_GAMING_VW.TABLE_GAME_SUM_VW
WHERE GAMING_DT BETWEEN DATE '2026-05-01' AND DATE '2026-11-20'
ORDER BY 1 DESC;
