-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- SAMPLE FILES FOR MARLENE: THE TWO QUERIES TO COPY FROM (acceptance criterion 3). Read only.
-- Run each one in Snowsight, copy its result into a text file, and DAASI-3811_make_sample_files.py turns the
-- two text files into the sample files. The full steps are at the top of that program.
--
-- Each query returns ONE column, FILE_LINE. Every row of it is already a finished line of the file: the header
-- line first, then the rows tagged LUX, then up to 50 hotel-stay rows and 50 other rows, with | between fields,
-- nothing for an empty value, and LOYALTY last.
--   QUERY 1: invitation file sent 11/17 (stays that checked out 11/16). Rows 2 to 4 end in |LUX.
--   QUERY 2: prospect file sent 11/07 (transactions of 11/06). Rows 2 and 3 end in |LUX.
-- These are the same two queries as in DAASI-3811_sample_files_VSCode.sql, unchanged.


-- ===========================================================================================================
-- QUERY 1. Invitation sample. Copy its result into invitation_paste.txt.
-- ===========================================================================================================

WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
SENT AS (
    SELECT IFF(LUX.LOYALTY IS NOT NULL, 1, IFF(NVL(A.RESERVATION_NUMBER, '') <> '', 2, 3)) AS ROW_GROUP,
           ROW_NUMBER() OVER (PARTITION BY IFF(NVL(A.RESERVATION_NUMBER, '') <> '', 2, 3)
                              ORDER BY A.TRANSACTION_ID, A.CUSTOMER_ID) AS PICK,
           NVL(A.TRANSACTION_ID, '') || '|' || NVL(A.TRANSACTION_DATE, '') || '|' ||
           NVL(A.PROPERTY_MARKET_CD, '') || '|' || NVL(A.UNIT_ID, '') || '|' || NVL(A.ORIGIN_UNIT_ID, '') || '|' ||
           NVL(A.CLUBCARD_YN, '') || '|' || NVL(A.CUSTOMER_ID, '') || '|' || NVL(A.GUEST_ID, '') || '|' ||
           NVL(A.PROP_ID, '') || '|' || NVL(A.FIRST_NAME, '') || '|' || NVL(A.LAST_NAME, '') || '|' ||
           NVL(A.GENDER, '') || '|' || NVL(A.EMAIL_ADDRESS, '') || '|' || NVL(A.PHONE_NUMBER, '') || '|' ||
           NVL(A.AGE, '') || '|' || NVL(A.CITY_NAME, '') || '|' || NVL(A.STATE_PROVINCE_CODE, '') || '|' ||
           NVL(A.ZIP_CODE, '') || '|' || NVL(A.ZIP_PLUS_4, '') || '|' || NVL(A.TIER_CODE, '') || '|' ||
           NVL(A.HOTEL_FLAG, '') || '|' || NVL(A.CASINO_FLAG, '') || '|' || NVL(A.ROOM_NUMBER, '') || '|' ||
           NVL(A.RESERVATION_NUMBER, '') || '|' || NVL(A.ROOM_TYPE_BOOKED, '') || '|' ||
           NVL(A.ROOM_TYPE_RECEIVED, '') || '|' || NVL(A.RATE_PLAN_CD, '') || '|' ||
           NVL(A.RESERVATION_DATE, '') || '|' || NVL(A.RESERVATION_AGENT, '') || '|' ||
           NVL(A.CHECK_IN_DATE, '') || '|' || NVL(A.CHECK_OUT_DATE, '') || '|' ||
           NVL(A.CHECKIN_AGENT_ID, '') || '|' || NVL(A.CHECKOUT_AGENT_ID, '') || '|' || NVL(A.WING_CD, '') || '|' ||
           NVL(A.ROOM_BLOCK_CD, '') || '|' || NVL(A.HOTEL_COMP_FLAG_YN, '') || '|' || NVL(A.HOST_NAME, '') || '|' ||
           NVL(A.HOST_CODE, '') || '|' || NVL(A.HOSTED_YN, '') || '|' || NVL(A.ADR, '') || '|' ||
           NVL(A.PROPERTY_WINLOSS, '') || '|' || NVL(A.HOSP_POS_SPEND, '') || '|' || NVL(A.ROOM_REV_AMT, '') || '|' ||
           NVL(A.THEO_AMT, '') || '|' || NVL(A.D_ARRIVAL_DT, '') || '|' || NVL(A.D_DEPARTURE_DT, '') || '|' ||
           NVL(A.I_CHECKIN_HR, '') || '|' || NVL(A.I_CHECKIN_MIN, '') || '|' || NVL(LUX.LOYALTY, '') AS FILE_LINE
    FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE A
    LEFT JOIN LUX
        ON LUX.PROPERTY_CD = A.UNIT_ID
        AND LUX.RESERVATION_ID = TRY_TO_NUMBER(A.RESERVATION_NUMBER)
    WHERE A.SNOWFLAKE_CREATED_DT = (
        SELECT MAX(SNOWFLAKE_CREATED_DT)
        FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE
        WHERE TO_DATE(SNOWFLAKE_CREATED_DT) = '2026-11-17'::DATE
    )
)
SELECT FILE_LINE
FROM (
    SELECT 0 AS ROW_GROUP,
           0 AS PICK,
           'TRANSACTION_ID|TRANSACTION_DATE|PROPERTY_MARKET_CD|UNIT_ID|ORIGIN_UNIT_ID|CLUBCARD_YN|CUSTOMER_ID|' ||
           'GUEST_ID|PROP_ID|FIRST_NAME|LAST_NAME|GENDER|EMAIL_ADDRESS|PHONE_NUMBER|AGE|CITY_NAME|' ||
           'STATE_PROVINCE_CODE|ZIP_CODE|ZIP_PLUS_4|TIER_CODE|HOTEL_FLAG|CASINO_FLAG|ROOM_NUMBER|' ||
           'RESERVATION_NUMBER|ROOM_TYPE_BOOKED|ROOM_TYPE_RECEIVED|RATE_PLAN_CD|RESERVATION_DATE|' ||
           'RESERVATION_AGENT|CHECK_IN_DATE|CHECK_OUT_DATE|CHECKIN_AGENT_ID|CHECKOUT_AGENT_ID|WING_CD|' ||
           'ROOM_BLOCK_CD|HOTEL_COMP_FLAG_YN|HOST_NAME|HOST_CODE|HOSTED_YN|ADR|PROPERTY_WINLOSS|HOSP_POS_SPEND|' ||
           'ROOM_REV_AMT|THEO_AMT|D_ARRIVAL_DT|D_DEPARTURE_DT|I_CHECKIN_HR|I_CHECKIN_MIN|LOYALTY' AS FILE_LINE
    UNION ALL
    SELECT ROW_GROUP, PICK, FILE_LINE
    FROM SENT
    WHERE (ROW_GROUP = 1 OR PICK <= 50)
    AND LENGTH(FILE_LINE) - LENGTH(REPLACE(FILE_LINE, '|', '')) = 48
    AND POSITION(CHAR(34) IN FILE_LINE) = 0
    AND POSITION(CHAR(92) IN FILE_LINE) = 0
    AND POSITION(CHAR(10) IN FILE_LINE) = 0
    AND POSITION(CHAR(13) IN FILE_LINE) = 0
)
ORDER BY ROW_GROUP, PICK;


-- ===========================================================================================================
-- QUERY 2. Prospect sample. Copy its result into prospect_paste.txt.
-- ===========================================================================================================

WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
SENT AS (
    SELECT IFF(LUX.LOYALTY IS NOT NULL, 1, IFF(A.TRANSACTION_SOURCE_SYSTEM = 'HOTEL', 2, 3)) AS ROW_GROUP,
           ROW_NUMBER() OVER (PARTITION BY IFF(A.TRANSACTION_SOURCE_SYSTEM = 'HOTEL', 2, 3)
                              ORDER BY A.TRANSACTION_ID, A.PROSPECT_ID) AS PICK,
           NVL(A.TRANSACTION_ID, '') || '|' || NVL(A.TRANSACTION_SOURCE_SYSTEM, '') || '|' ||
           NVL(A.TRANSACTION_DATE, '') || '|' || NVL(A.PROPERTY_MARKET_CD, '') || '|' || NVL(A.UNIT_ID, '') || '|' ||
           NVL(A.ORIGIN_UNIT_ID, '') || '|' || NVL(A.CLUBCARD_YN, '') || '|' || NVL(A.PROSPECT_ID, '') || '|' ||
           NVL(A.GUEST_ID, '') || '|' || NVL(A.PROP_ID, '') || '|' || NVL(A.FIRST_NAME, '') || '|' ||
           NVL(A.LAST_NAME, '') || '|' || NVL(A.GENDER, '') || '|' || NVL(A.EMAIL_ADDRESS, '') || '|' ||
           NVL(A.PHONE_NUMBER, '') || '|' || NVL(A.AGE, '') || '|' || NVL(A.CITY_NAME, '') || '|' ||
           NVL(A.STATE_PROVINCE_CODE, '') || '|' || NVL(A.ZIP_CODE, '') || '|' || NVL(A.ZIP_PLUS_4, '') || '|' ||
           NVL(A.TIER_CODE, '') || '|' || NVL(A.HOTEL_FLAG, '') || '|' || NVL(A.CASINO_FLAG, '') || '|' ||
           NVL(A.ROOM_NUMBER, '') || '|' || NVL(A.RESERVATION_NUMBER, '') || '|' ||
           NVL(A.ROOM_TYPE_BOOKED, '') || '|' || NVL(A.ROOM_TYPE_RECEIVED, '') || '|' ||
           NVL(A.RATE_PLAN_CD, '') || '|' || NVL(A.RESERVATION_DATE, '') || '|' ||
           NVL(A.RESERVATION_AGENT, '') || '|' || NVL(A.CHECK_IN_DATE, '') || '|' ||
           NVL(A.CHECK_OUT_DATE, '') || '|' || NVL(A.CHECKIN_AGENT_ID, '') || '|' ||
           NVL(A.CHECKOUT_AGENT_ID, '') || '|' || NVL(A.WING_CD, '') || '|' || NVL(A.ROOM_BLOCK_CD, '') || '|' ||
           NVL(A.HOTEL_COMP_FLAG_YN, '') || '|' || NVL(A.HOST_NAME, '') || '|' || NVL(A.HOST_CODE, '') || '|' ||
           NVL(A.HOSTED_YN, '') || '|' || NVL(A.ADR, '') || '|' || NVL(A.PROPERTY_WINLOSS, '') || '|' ||
           NVL(A.HOSP_POS_SPEND, '') || '|' || NVL(A.ROOM_REV_AMT, '') || '|' || NVL(A.THEO_AMT, '') || '|' ||
           NVL(A.D_ARRIVAL_DT, '') || '|' || NVL(A.D_DEPARTURE_DT, '') || '|' || NVL(A.I_CHECKIN_HR, '') || '|' ||
           NVL(A.I_CHECKIN_MIN, '') || '|' || NVL(LUX.LOYALTY, '') AS FILE_LINE
    FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE A
    LEFT JOIN LUX
        ON LUX.PROPERTY_CD = A.UNIT_ID
        AND LUX.RESERVATION_ID = TRY_TO_NUMBER(A.RESERVATION_NUMBER)
    WHERE A.CREATED_DTTM = (
        SELECT MAX(CREATED_DTTM)
        FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
        WHERE TO_DATE(CREATED_DTTM) = '2026-11-07'::DATE
    )
)
SELECT FILE_LINE
FROM (
    SELECT 0 AS ROW_GROUP,
           0 AS PICK,
           'TRANSACTION_ID|TRANSACTION_SOURCE_SYSTEM|TRANSACTION_DATE|PROPERTY_MARKET_CD|UNIT_ID|ORIGIN_UNIT_ID|' ||
           'CLUBCARD_YN|PROSPECT_ID|GUEST_ID|PROP_ID|FIRST_NAME|LAST_NAME|GENDER|EMAIL_ADDRESS|PHONE_NUMBER|AGE|' ||
           'CITY_NAME|STATE_PROVINCE_CODE|ZIP_CODE|ZIP_PLUS_4|TIER_CODE|HOTEL_FLAG|CASINO_FLAG|ROOM_NUMBER|' ||
           'RESERVATION_NUMBER|ROOM_TYPE_BOOKED|ROOM_TYPE_RECEIVED|RATE_PLAN_CD|RESERVATION_DATE|' ||
           'RESERVATION_AGENT|CHECK_IN_DATE|CHECK_OUT_DATE|CHECKIN_AGENT_ID|CHECKOUT_AGENT_ID|WING_CD|' ||
           'ROOM_BLOCK_CD|HOTEL_COMP_FLAG_YN|HOST_NAME|HOST_CODE|HOSTED_YN|ADR|PROPERTY_WINLOSS|HOSP_POS_SPEND|' ||
           'ROOM_REV_AMT|THEO_AMT|D_ARRIVAL_DT|D_DEPARTURE_DT|I_CHECKIN_HR|I_CHECKIN_MIN|LOYALTY' AS FILE_LINE
    UNION ALL
    SELECT ROW_GROUP, PICK, FILE_LINE
    FROM SENT
    WHERE (ROW_GROUP = 1 OR PICK <= 50)
    AND LENGTH(FILE_LINE) - LENGTH(REPLACE(FILE_LINE, '|', '')) = 49
    AND POSITION(CHAR(34) IN FILE_LINE) = 0
    AND POSITION(CHAR(92) IN FILE_LINE) = 0
    AND POSITION(CHAR(10) IN FILE_LINE) = 0
    AND POSITION(CHAR(13) IN FILE_LINE) = 0
)
ORDER BY ROW_GROUP, PICK;
