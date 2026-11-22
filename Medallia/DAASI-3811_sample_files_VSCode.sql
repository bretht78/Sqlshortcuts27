-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- SAMPLE FILES FOR MARLENE, MADE FROM VS CODE (acceptance criterion 3). Two queries. Read only.
-- This replaces the earlier sample_files.sql, which wrote to a Snowflake stage and cannot be used on this account.
--
-- WHAT YOU GET. Two small files in the layout of the daily files, with the new column at the end:
--   CaesarsCustomerInvitation_SAMPLE.csv   from the file sent 11/17 (stays that checked out 11/16)
--   CaesarsProspectInvitation_SAMPLE.csv   from the file sent 11/07 (transactions of 11/06)
-- Each holds the header line, every row of that day that gets LUX (3 and 2), and about 100 ordinary rows.
--
-- HOW IT WORKS. The Snowflake extension saves a result as a comma-separated file with quotes, which is not how
-- the daily files look. So each query returns one column, FILE_LINE, and every row of it is already a finished
-- line of the file: fields separated by |, nothing for an empty field, header line first. The steps below save
-- that column and strip what the save adds.
--
-- THESE FILES HOLD REAL GUEST NAMES, EMAIL ADDRESSES AND PHONE NUMBERS.
-- Send them only the way your team sends such files, never in the ticket, an email body or a chat, and delete
-- the copies on the laptop afterwards. These guests were already invited for these stays, so tell Marlene the
-- files are for checking the layout and a test load, not for a live load.
--
-- WHAT TO TELL MARLENE. One new column, LOYALTY, at the end of both files. It holds LUX on Luxury Experience
-- hotel stays and is empty on every other row, so most lines end with a | and nothing after it. No existing
-- column moves or changes. The LUX rows are at the top of each sample.
--
--
-- STEPS
--
-- A. Sign in (first time only)
--   1. In VS Code, select the Snowflake icon in the Activity Bar, the strip of icons down the left edge.
--      No Snowflake icon: open Extensions (Ctrl+Shift+X), search for Snowflake, pick the one published by
--      Snowflake, select Install.
--   2. Account Identifier/URL: enter the address your team uses for VS Code, then select Continue.
--      If you do not have it: in Snowsight open the account selector (bottom left), select View account
--      details, and copy Account/Server URL. You reach Snowsight through a private link address, so the one
--      that works is most likely https://czr-czrdaasprd.privatelink.snowflakecomputing.com
--   3. Auth Method: Single sign-on. Enter your user name, select Sign in with single sign-on, finish in the
--      browser, and come back to VS Code.
--   4. In the Account section of the Snowflake side bar, set the role to DAAS_TEAM and choose the warehouse
--      you use in Snowsight.
--
-- B. Make the invitation sample
--   5. File > Open File, and open this file.
--   6. Select all of QUERY 1, from its WITH down to its semicolon, and press Ctrl+Enter.
--   7. The result opens in the SNOWFLAKE pane at the bottom: one column, FILE_LINE.
--      Row 1 is the header line. Rows 2 to 4 end in |LUX. Fewer LUX rows than that: stop and tell me.
--   8. In that pane select Save (the Save results button) and save as invitation_raw.csv
--      No Save button in the pane: stop and send me a photo of the pane.
--   9. File > Open File, open invitation_raw.csv and tidy it:
--        a. If line 1 reads FILE_LINE, with or without quotes, delete that whole line.
--        b. Press Ctrl+H. In the Find box switch on Use Regular Expression (the .* button).
--           Find:     ^"(.*)"$
--           Replace:  $1
--           Select Replace All (Ctrl+Alt+Enter). This removes the quotes the save put around each line.
--        c. Bottom right corner of the window: if it says CRLF, click it and choose LF.
--        d. File > Save As, and name it CaesarsCustomerInvitation_SAMPLE.csv
--        e. Bottom right corner again: it should say UTF-8. If it says anything else (UTF-8 with BOM, for
--           example), click it, choose Save with Encoding, then UTF-8.
--  10. Check the finished file:
--        - line 1 starts with TRANSACTION_ID| and ends with |LOYALTY
--        - lines 2 to 4 end with |LUX, and most other lines end with |
--        - Ctrl+F for a double quote finds nothing
--        - the bottom right corner says LF and UTF-8
--
-- C. Make the prospect sample
--  11. Do steps 6 to 10 again with QUERY 2. Save as prospect_raw.csv, then as
--      CaesarsProspectInvitation_SAMPLE.csv. Rows 2 and 3 end in |LUX.
--
-- D. Afterwards
--  12. Delete invitation_raw.csv and prospect_raw.csv. Send the two SAMPLE files the way your team sends
--      such files, then delete them from the laptop too.
--
-- WHY LF AND UTF-8. Snowflake writes its export files with LF line ends and always in UTF-8. The export tasks
-- name ENCODING = 'iso-8859-1', but that option only applies when loading files, so the daily files are UTF-8.
-- A file saved on Windows gets CRLF line ends unless it is switched to LF, and the extra character would land
-- on the end of the last column, which is the new one.
--
-- WHAT IS LEFT OUT. A row whose text holds a double quote, a backslash, a line break or a | inside a field is
-- skipped, because the save or the real export would write it differently. That is rare.
-- For a bigger sample, change the 50 in the line PICK <= 50 of the query. A whole day of the invitation file
-- is about 36,000 rows.


-- ===========================================================================================================
-- QUERY 1. Invitation sample. Expect the header line, 3 lines ending in |LUX, then up to 50 hotel-stay and 50 gaming-only rows.
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
-- QUERY 2. Prospect sample. Expect the header line, 2 lines ending in |LUX, then up to 50 hotel-stay and 50 other rows.
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
