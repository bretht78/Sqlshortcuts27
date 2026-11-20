-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- UAT TEST. Run in a UAT worksheet, one part at a time. If DAAS_TEAM is refused anywhere, switch the worksheet's
-- role to DAAS_UAT_DEVELOPER and repeat that statement.
--
-- THE ONE THING TO GET RIGHT. These three procedures run as caller. A procedure of that kind works in whatever
-- database the worksheet is pointed at, so the same CALL made from a worksheet on DAAS_PROD would empty and
-- reload the PROD file tables. Part 3 starts with USE DATABASE DAAS_UAT for that reason. Always run Part 3 from
-- its first line.
--
-- The parts:
--   Part 1  what the deployment left in UAT: tables, procedures, tasks. Reads only.
--   Part 2  notes the day the UAT file tables hold now, and their row counts, as the "before". Reads only.
--   Part 3  runs the new code for that same day: three procedures, then the two archive inserts.
--   Part 4  the four proofs. Read only.
--   Part 5  only if Part 4 shows no tags: finds a UAT day that has Luxury Experience stays.


-- =====================================================================================================
-- PART 1. What landed in UAT. Reads only.
-- =====================================================================================================

-- 1a. The five tables. Expect five rows with LOYALTY_POSITION equal to COLUMN_COUNT: the new column is the last one.
SELECT TABLE_SCHEMA,
       TABLE_NAME,
       COUNT(*)                                                    AS COLUMN_COUNT,
       MAX(IFF(COLUMN_NAME = 'LOYALTY', ORDINAL_POSITION, NULL))   AS LOYALTY_POSITION
FROM DAAS_UAT.INFORMATION_SCHEMA.COLUMNS
WHERE (TABLE_SCHEMA = 'DAAS_CORE' AND TABLE_NAME IN ('MEDALLIA_V_CUSTOMER_INVITATION_HOTEL',
                                                     'MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE',
                                                     'MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE'))
   OR (TABLE_SCHEMA = 'HPDB' AND TABLE_NAME IN ('MEDALLIA_PROSPECT_INVITATION_FILE',
                                                'MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE'))
GROUP BY TABLE_SCHEMA, TABLE_NAME
ORDER BY TABLE_SCHEMA, TABLE_NAME;

-- 1b. The three procedures. Expect three rows, each changed at the time of the deploy, with
--     IS_THE_REVIEWED_CODE = TRUE: UAT is running exactly the text in the pull request (spacing aside).
--     Fewer than three rows means your role cannot see a procedure: switch role and rerun.
SELECT PROCEDURE_SCHEMA,
       PROCEDURE_NAME,
       LAST_ALTERED,
       MD5(REPLACE(REPLACE(REPLACE(REPLACE(PROCEDURE_DEFINITION, ' '), CHAR(9)), CHAR(10)), CHAR(13)))
         = DECODE(PROCEDURE_NAME,
              'MEDALLIA_V_CUSTOMER_INVITATION_HOTEL_PROC', 'ef103d6188ea172932cd669d8ff93a54',
              'MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC', '49a39440631b44cbbb8ae96f99ff1857',
              'MEDALLIA_PROSPECT_INVITATION_FILE_PROC', '7a2bb10277489ae6f934402e985e658e') AS IS_THE_REVIEWED_CODE
FROM DAAS_UAT.INFORMATION_SCHEMA.PROCEDURES
WHERE PROCEDURE_SCHEMA IN ('DAAS_COMMON', 'HPDB')
AND PROCEDURE_NAME IN ('MEDALLIA_V_CUSTOMER_INVITATION_HOTEL_PROC', 'MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC', 'MEDALLIA_PROSPECT_INVITATION_FILE_PROC')
ORDER BY PROCEDURE_NAME;

-- 1c. The tasks. Run the two statements together. This is also the rehearsal for PROD's open question:
--     did replacing the two archive tasks leave the chain intact?
--     Expect: the two archive tasks show HAS_LOYALTY = TRUE, a UAT warehouse, and a "created_on" at the deploy.
--     Then look at the export tasks. In PROD, MEDALLIA_EXPORT_TASK and MEDALLIA_PROPERTY_ORG_EXPORT_TASK run after
--     MEDALLIA_ARCHIVE_TASK, and MEDALLIA_PROSPECT_EXPORT_TASK runs after
--     MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK. If those exist in UAT and now show no predecessor, the
--     replace cut them loose, and PROD should use the in-place task script instead. Send me this result either way.
SHOW TASKS LIKE 'MEDALLIA%' IN SCHEMA DAAS_UAT.DAAS_COMMON;

SELECT "name"                            AS TASK_NAME,
       "state"                           AS STATE,
       "predecessors"                    AS RUNS_AFTER,
       "warehouse"                       AS WAREHOUSE,
       "definition" ILIKE '%LOYALTY%'    AS HAS_LOYALTY,
       "created_on"                      AS CREATED_ON
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 1;


-- =====================================================================================================
-- PART 2. The "before": which day UAT holds now, and how many rows the old code loaded for it. Reads only.
-- =====================================================================================================

-- The UAT file tables still hold the last day the old code loaded. Running the new code for that same day gives
-- a like-for-like comparison. Run the three statements together and keep the result.
--   If a date comes back empty, that table is empty: go to Part 5 to pick a day instead.
SET (INV_DATE, HOTEL_BEFORE, COMPLETE_BEFORE) = (
    SELECT (SELECT MAX(TRY_TO_DATE(TRANSACTION_DATE)) FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE),
           (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL),
           (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE));

SET (PRO_DATE, PROSPECT_BEFORE) = (
    SELECT MAX(TRY_TO_DATE(TRANSACTION_DATE)), COUNT(*) FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE);

SELECT $INV_DATE        AS INVITATION_TEST_DAY,
       $HOTEL_BEFORE    AS HOTEL_ROWS_BEFORE,
       $COMPLETE_BEFORE AS INVITATION_ROWS_BEFORE,
       $PRO_DATE        AS PROSPECT_TEST_DAY,
       $PROSPECT_BEFORE AS PROSPECT_ROWS_BEFORE;


-- =====================================================================================================
-- PART 3. Run the new code in UAT. Start from the first line every time.
-- =====================================================================================================

USE DATABASE DAAS_UAT;

-- Must answer DAAS_UAT. If it says anything else, stop.
SELECT CURRENT_DATABASE() AS WORKSHEET_DATABASE;

-- 3a. The three procedures, in the order the tasks run them. Each should finish without an error.
--     An error naming LMS73_HOTEL_RESERVATIONS_FACT as missing or not authorized is worth keeping: it means the
--     role running the procedure cannot read the new source table, which is the grant PROD's task role needs too.
CALL DAAS_UAT.DAAS_COMMON.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL_PROC($INV_DATE);
CALL DAAS_UAT.DAAS_COMMON.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC($INV_DATE);
CALL DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_PROC($PRO_DATE);

-- 3b. The two archive inserts. These are the statements inside the two archive tasks, with the UAT database
--     written in. The tasks themselves are not started, so nothing is exported.
INSERT INTO DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE(
        TRANSACTION_ID,
        TRANSACTION_DATE,
        PROPERTY_MARKET_CD,
        UNIT_ID,
        CLUBCARD_YN,
		CUSTOMER_ID,
        GUEST_ID,
        PROP_ID,
        FIRST_NAME,
        LAST_NAME,
        GENDER,
        EMAIL_ADDRESS,
        PHONE_NUMBER,
        Age,
		CITY_NAME,
        STATE_PROVINCE_CODE,
        ZIP_CODE,
        ZIP_PLUS_4,
        TIER_CODE,
		HOTEL_FLAG,
		CASINO_FLAG,
		ROOM_NUMBER,
		RESERVATION_NUMBER,
		RESERVATION_AGENT,
		ROOM_TYPE_BOOKED,
		ROOM_TYPE_RECEIVED,
		RATE_PLAN_CD,
		RESERVATION_DATE,
		CHECK_IN_DATE,
		CHECK_OUT_DATE,
		CHECKIN_AGENT_ID,
		CHECKOUT_AGENT_ID,
		WING_CD,
		ROOM_BLOCK_CD,
		HOTEL_COMP_FLAG_YN,
		HOST_NAME,
		HOST_CODE,
		HOSTED_YN,
		ADR,
		PROPERTY_WINLOSS,
		HOSP_POS_SPEND,
		ROOM_REV_AMT,
		THEO_AMT,
        D_ARRIVAL_DT,
	    D_DEPARTURE_DT,
	    I_CHECKIN_HR,
	    I_CHECKIN_MIN,
        SNOWFLAKE_CREATED_DT,
        BUSINESS_RUN_DATE,
        ORIGIN_UNIT_ID,
        LOYALTY)

        SELECT 
		TRANSACTION_ID,
        TRANSACTION_DATE,
        PROPERTY_MARKET_CD,
        UNIT_ID,
        CLUBCARD_YN,
		CUSTOMER_ID,
        GUEST_ID,
        PROP_ID,
        FIRST_NAME,
        LAST_NAME,
        GENDER,
        EMAIL_ADDRESS,
        PHONE_NUMBER,
        Age,
		CITY_NAME,
        STATE_PROVINCE_CODE,
        ZIP_CODE,
        ZIP_PLUS_4,
        TIER_CODE,
		HOTEL_FLAG,
		CASINO_FLAG,
		ROOM_NUMBER,
		RESERVATION_NUMBER,
		RESERVATION_AGENT,
		ROOM_TYPE_BOOKED,
		ROOM_TYPE_RECEIVED,
		RATE_PLAN_CD,
		RESERVATION_DATE,
		CHECK_IN_DATE,
		CHECK_OUT_DATE,
		CHECKIN_AGENT_ID,
		CHECKOUT_AGENT_ID,
		WING_CD,
		ROOM_BLOCK_CD,
		HOTEL_COMP_FLAG_YN,
		HOST_NAME,
		HOST_CODE,
		HOSTED_YN,
		ADR,
		PROPERTY_WINLOSS,
		HOSP_POS_SPEND,
		ROOM_REV_AMT,
		THEO_AMT,
        D_ARRIVAL_DT,
	    D_DEPARTURE_DT,
	    I_CHECKIN_HR,
	    I_CHECKIN_MIN, 
		CURRENT_TIMESTAMP(), 
		CURRENT_DATE() -1,
        ORIGIN_UNIT_ID,
        LOYALTY
        FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE;

INSERT INTO DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
    (
        TRANSACTION_ID
        ,TRANSACTION_SOURCE_SYSTEM
        ,TRANSACTION_DATE
        ,PROPERTY_MARKET_CD
        ,UNIT_ID
        ,CLUBCARD_YN
        ,PROSPECT_ID
        ,GUEST_ID 
        ,PROP_ID
        ,FIRST_NAME
        ,LAST_NAME
        ,GENDER
        ,EMAIL_ADDRESS
        ,PHONE_NUMBER
        ,AGE
        ,CITY_NAME
        ,STATE_PROVINCE_CODE
        ,ZIP_CODE
        ,ZIP_PLUS_4
        ,TIER_CODE
        ,HOTEL_FLAG
        ,CASINO_FLAG
        ,ROOM_NUMBER
        ,RESERVATION_NUMBER
        ,ROOM_TYPE_BOOKED
        ,ROOM_TYPE_RECEIVED
        ,RATE_PLAN_CD
        ,RESERVATION_DATE
        ,RESERVATION_AGENT
        ,CHECK_IN_DATE
        ,CHECK_OUT_DATE
        ,CHECKIN_AGENT_ID   
        ,CHECKOUT_AGENT_ID
        ,WING_CD
        ,ROOM_BLOCK_CD
        ,HOTEL_COMP_FLAG_YN
        ,HOST_NAME
        ,HOST_CODE
        ,HOSTED_YN
        ,ADR
        ,PROPERTY_WINLOSS
        ,HOSP_POS_SPEND
        ,ROOM_REV_AMT
        ,THEO_AMT
        ,D_ARRIVAL_DT
        ,D_DEPARTURE_DT
        ,I_CHECKIN_HR
        ,I_CHECKIN_MIN
        ,CREATED_DTTM
        ,ORIGIN_UNIT_ID
        ,LOYALTY
    )
    SELECT 
        TRANSACTION_ID
        ,TRANSACTION_SOURCE_SYSTEM
        ,TRANSACTION_DATE
        ,PROPERTY_MARKET_CD
        ,UNIT_ID
        ,CLUBCARD_YN
        ,PROSPECT_ID
        ,GUEST_ID
        ,PROP_ID
        ,FIRST_NAME
        ,LAST_NAME
        ,GENDER
        ,EMAIL_ADDRESS
        ,PHONE_NUMBER
        ,AGE
        ,CITY_NAME
        ,STATE_PROVINCE_CODE
        ,ZIP_CODE
        ,ZIP_PLUS_4
        ,TIER_CODE
        ,HOTEL_FLAG
        ,CASINO_FLAG
        ,ROOM_NUMBER
        ,RESERVATION_NUMBER
        ,ROOM_TYPE_BOOKED
        ,ROOM_TYPE_RECEIVED
        ,RATE_PLAN_CD
        ,RESERVATION_DATE
        ,RESERVATION_AGENT
        ,CHECK_IN_DATE
        ,CHECK_OUT_DATE
        ,CHECKIN_AGENT_ID
        ,CHECKOUT_AGENT_ID
        ,WING_CD
        ,ROOM_BLOCK_CD
        ,HOTEL_COMP_FLAG_YN
        ,HOST_NAME
        ,HOST_CODE
        ,HOSTED_YN
        ,ADR
        ,PROPERTY_WINLOSS
        ,HOSP_POS_SPEND
        ,ROOM_REV_AMT
        ,THEO_AMT
        ,D_ARRIVAL_DT
        ,D_DEPARTURE_DT
        ,I_CHECKIN_HR
        ,I_CHECKIN_MIN
        ,CURRENT_TIMESTAMP()
        ,ORIGIN_UNIT_ID
        ,LOYALTY
    FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE;


-- =====================================================================================================
-- PART 4. The four proofs. Read only.
-- =====================================================================================================

-- PROOF 1. Same day, old code and new code: the row counts match.
--   Expect ROWS_NEW_CODE = ROWS_OLD_CODE on all three lines. The join that adds the tag can neither add nor
--   drop a row. (A small difference would mean UAT's source data moved since the old code last ran, not that
--   the change did it. Tell me if you see one.)
SELECT '1 Hotel table'           AS TABLE_NAME, $INV_DATE AS TEST_DAY, $HOTEL_BEFORE AS ROWS_OLD_CODE,
       COUNT(*) AS ROWS_NEW_CODE, COUNT(LOYALTY) AS ROWS_WITH_TAG
FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL
UNION ALL
SELECT '2 Invitation file table', $INV_DATE, $COMPLETE_BEFORE, COUNT(*), COUNT(LOYALTY)
FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
UNION ALL
SELECT '3 Prospect file table',   $PRO_DATE, $PROSPECT_BEFORE, COUNT(*), COUNT(LOYALTY)
FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
ORDER BY 1;

-- PROOF 2. The tag sits only where it should.
--   Expect ROWS_WITH_TAG = 0 on "Gaming only" and "Not a hotel stay". TAG_VALUES is LUX or (none).
SELECT 'Invitation file' AS FILE_NAME,
       IFF(NVL(RESERVATION_NUMBER, '') = '', 'Gaming only', 'Hotel stay') AS ROW_TYPE,
       COUNT(*)       AS ROWS_IN_FILE,
       COUNT(LOYALTY) AS ROWS_WITH_TAG,
       NVL(NULLIF(LISTAGG(DISTINCT LOYALTY, ', '), ''), '(none)') AS TAG_VALUES
FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
GROUP BY 1, 2
UNION ALL
SELECT 'Prospect file',
       IFF(TRANSACTION_SOURCE_SYSTEM = 'HOTEL', 'Hotel stay', 'Not a hotel stay'),
       COUNT(*),
       COUNT(LOYALTY),
       NVL(NULLIF(LISTAGG(DISTINCT LOYALTY, ', '), ''), '(none)')
FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
GROUP BY 1, 2
ORDER BY 1, 2;

-- PROOF 3. Every tag in the files matches UAT's LMS73 reservations fact, in both directions.
--   Expect TAGGED_IN_FILE = TAGGED_IN_LMS, and the last three columns 0.
WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_UAT.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
FILE_ROWS AS (
    SELECT 'Invitation file' AS FILE_NAME, UNIT_ID, RESERVATION_NUMBER, LOYALTY
    FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
    UNION ALL
    SELECT 'Prospect file', UNIT_ID, RESERVATION_NUMBER, LOYALTY
    FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
)
SELECT F.FILE_NAME,
       COUNT(*)                                                       AS ROWS_IN_FILE,
       COUNT(F.LOYALTY)                                               AS TAGGED_IN_FILE,
       COUNT(LUX.RESERVATION_ID)                                      AS TAGGED_IN_LMS,
       COUNT_IF(F.LOYALTY IS NOT NULL AND LUX.RESERVATION_ID IS NULL) AS IN_FILE_NOT_IN_LMS,
       COUNT_IF(F.LOYALTY IS NULL AND LUX.RESERVATION_ID IS NOT NULL) AS IN_LMS_NOT_IN_FILE,
       COUNT_IF(F.LOYALTY <> LUX.LOYALTY)                             AS DIFFERENT_VALUE
FROM FILE_ROWS F
LEFT JOIN LUX
    ON LUX.PROPERTY_CD = F.UNIT_ID
    AND LUX.RESERVATION_ID = TRY_TO_NUMBER(F.RESERVATION_NUMBER)
GROUP BY F.FILE_NAME
ORDER BY F.FILE_NAME;

-- PROOF 4. The archive inserts carried the new column.
--   Expect, for each file, the same ROW_COUNT and ROWS_WITH_TAG on both lines.
SELECT 'Invitation file' AS FILE_NAME, '1 file table' AS STORED_IN, COUNT(*) AS ROW_COUNT, COUNT(LOYALTY) AS ROWS_WITH_TAG
FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
UNION ALL
SELECT 'Invitation file', '2 archive, newest load', COUNT(*), COUNT(LOYALTY)
FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE
WHERE SNOWFLAKE_CREATED_DT = (SELECT MAX(SNOWFLAKE_CREATED_DT) FROM DAAS_UAT.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE)
UNION ALL
SELECT 'Prospect file', '1 file table', COUNT(*), COUNT(LOYALTY)
FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
UNION ALL
SELECT 'Prospect file', '2 archive, newest load', COUNT(*), COUNT(LOYALTY)
FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
WHERE CREATED_DTTM = (SELECT MAX(CREATED_DTTM) FROM DAAS_UAT.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE)
ORDER BY 1, 2;


-- =====================================================================================================
-- PART 5. Only if PROOF 1 shows ROWS_WITH_TAG = 0 on every line
-- =====================================================================================================

-- UAT's hotel data is older than PROD's, so the test day may have had no Luxury Experience stay. This lists the
-- UAT check-out days that do have one, newest first. Reads only.
--   No rows at all means UAT holds no reservation coded LUX. The code is still proven by Proofs 1 to 4 (it runs,
--   counts match, nothing is tagged that should not be), and PROD's read-only preview is the proof that tags
--   appear. Tell me and I will give you a one-reservation test instead.
SELECT R.DEPARTURE_DT          AS CHECK_OUT_DAY,
       COUNT(*)                AS GUEST_ROWS_ON_LUX_RESERVATIONS
FROM DAAS_UAT.DAAS_CORE_HOTEL_VW.HOTEL_GUEST_RESERVATIONS_FACT_VW R
JOIN (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_UAT.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
) LUX
    ON LUX.PROPERTY_CD = R.PROPERTY_CD
    AND LUX.RESERVATION_ID = R.RESERVATION_ID
WHERE R.DEPARTURE_DT <= CURRENT_DATE()
GROUP BY R.DEPARTURE_DT
ORDER BY R.DEPARTURE_DT DESC
LIMIT 20;

-- If it lists a day, put that day in both lines below, run them, then run Part 3 and Proofs 2 to 4 again.
-- (Proof 1 compares against the earlier day, so skip it on this second pass.)
-- SET INV_DATE = '2026-10-25';
-- SET PRO_DATE = '2026-10-25';
