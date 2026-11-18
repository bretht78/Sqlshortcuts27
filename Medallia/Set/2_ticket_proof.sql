-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- TICKET PROOF: four queries. All read-only, all against PROD.
-- PROOF 1 can be run today, before anything is deployed. PROOF 2 to 4 are for the morning after the
-- PROD deploy, once the 09:30 Pacific run has finished.
--
-- Terms: the invitation file is the daily survey list of Caesars Rewards members. The prospect file is
-- the same list for guests with no Caesars Rewards account. LMS is the hotel reservations system. Its
-- "Loyalty" field is typed by hand on a reservation, and LUX is the code this change treats as the
-- Luxury Experience tag.


-- =====================================================================================================
-- PROOF 1.  Adding the tag changes no row counts, and this is how many rows it would have marked.
--
-- Takes the rows already sent to Medallia each day since 10/21 (the earliest arrival coded LUX) and
-- applies the same lookup the procedures use, with the tags as they stand in LMS today.
--
-- Expect: ROWS_AFTER_ADDING_TAG equals ROWS_SENT on every line, so the join neither adds nor drops rows.
-- ROWS_THAT_GET_LUX is a small number on some days and 0 on most.
-- Also use this to pick the day for Marlene's sample: the newest FILE_DATE with a LUX row in each file.
-- =====================================================================================================
WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
SENT AS (
    SELECT 'Invitation file' AS FILE_NAME, TO_DATE(SNOWFLAKE_CREATED_DT) AS FILE_DATE, UNIT_ID, RESERVATION_NUMBER
    FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE
    WHERE SNOWFLAKE_CREATED_DT >= '2026-10-21'
    UNION ALL
    SELECT 'Prospect file', TO_DATE(CREATED_DTTM), UNIT_ID, RESERVATION_NUMBER
    FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
    WHERE CREATED_DTTM >= '2026-10-21'
),
COUNTED AS (
    SELECT SENT.*, COUNT(*) OVER (PARTITION BY FILE_NAME, FILE_DATE) AS ROWS_SENT
    FROM SENT
)
SELECT C.FILE_NAME,
       C.FILE_DATE,
       MAX(C.ROWS_SENT)   AS ROWS_SENT,
       COUNT(*)           AS ROWS_AFTER_ADDING_TAG,
       COUNT(LUX.LOYALTY) AS ROWS_THAT_GET_LUX
FROM COUNTED C
LEFT JOIN LUX
    ON LUX.PROPERTY_CD = C.UNIT_ID
    AND LUX.RESERVATION_ID = TRY_TO_NUMBER(C.RESERVATION_NUMBER)
GROUP BY C.FILE_NAME, C.FILE_DATE
ORDER BY C.FILE_DATE DESC, C.FILE_NAME;


-- =====================================================================================================
-- PROOF 2.  After deploy: the tag sits only where it should.
--
-- Expect: "Gaming only" rows and prospect rows that are not hotel stays have ROWS_WITH_TAG = 0.
-- Hotel rows show a small number (0 is possible on a quiet day), and TAG_VALUES is LUX or (none).
-- =====================================================================================================
SELECT 'Invitation file' AS FILE_NAME,
       IFF(NVL(RESERVATION_NUMBER, '') = '', 'Gaming only', 'Hotel stay') AS ROW_TYPE,
       COUNT(*)       AS ROWS_IN_FILE,
       COUNT(LOYALTY) AS ROWS_WITH_TAG,
       NVL(NULLIF(LISTAGG(DISTINCT LOYALTY, ', '), ''), '(none)') AS TAG_VALUES
FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
GROUP BY 1, 2
UNION ALL
SELECT 'Prospect file',
       IFF(TRANSACTION_SOURCE_SYSTEM = 'HOTEL', 'Hotel stay', 'Not a hotel stay'),
       COUNT(*),
       COUNT(LOYALTY),
       NVL(NULLIF(LISTAGG(DISTINCT LOYALTY, ', '), ''), '(none)')
FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
GROUP BY 1, 2
ORDER BY 1, 2;


-- =====================================================================================================
-- PROOF 3.  After deploy: every tag in the files matches LMS, in both directions.
--
-- Looks each file row up in the LMS73 reservations fact again, on its own.
--
-- Expect: TAGGED_IN_FILE equals TAGGED_IN_LMS, and the last three columns are 0.
-- (A tag keyed into LMS after the 09:30 run can show as 1 in IN_LMS_NOT_IN_FILE.)
-- =====================================================================================================
WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
FILE_ROWS AS (
    SELECT 'Invitation file' AS FILE_NAME, UNIT_ID, RESERVATION_NUMBER, LOYALTY
    FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
    UNION ALL
    SELECT 'Prospect file', UNIT_ID, RESERVATION_NUMBER, LOYALTY
    FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
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


-- =====================================================================================================
-- PROOF 4.  After deploy: the archive tasks carried the new column.
--
-- Compares each file table with the newest load in its archive.
--
-- Expect: for each file, both lines show the same ROW_COUNT and the same ROWS_WITH_TAG.
-- =====================================================================================================
SELECT 'Invitation file' AS FILE_NAME, '1 file table' AS STORED_IN, COUNT(*) AS ROW_COUNT, COUNT(LOYALTY) AS ROWS_WITH_TAG
FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
UNION ALL
SELECT 'Invitation file', '2 archive, newest load', COUNT(*), COUNT(LOYALTY)
FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE
WHERE SNOWFLAKE_CREATED_DT = (SELECT MAX(SNOWFLAKE_CREATED_DT) FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE)
UNION ALL
SELECT 'Prospect file', '1 file table', COUNT(*), COUNT(LOYALTY)
FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
UNION ALL
SELECT 'Prospect file', '2 archive, newest load', COUNT(*), COUNT(LOYALTY)
FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
WHERE CREATED_DTTM = (SELECT MAX(CREATED_DTTM) FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE)
ORDER BY 1, 2;
