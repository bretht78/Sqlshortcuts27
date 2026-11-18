-- Consolidated hotel reservations fact: no new LMS73 data since 10/28. Evidence and "done" test.
-- Both read-only.


-- 1. The stream and the table it is attached to. Look at the table_name column.
--    A stream is Snowflake's running list of the rows that changed in one table since it was last read.
--    STREAM_LMS7_HOTEL_RESERVATIONS_FACT sits on LMS7_HOTEL_RESERVATIONS_FACT, which is the right pattern.
--    STREAM_LMS73_HOTEL_RESERVATIONS_FACT should sit on LMS73_HOTEL_RESERVATIONS_FACT. On 11/17 it showed
--    DAAS_PROD.DAAS_CORE_HOTEL.HOTEL_RESERVATIONS_FACT, created 2026-10-28 15:17:46 Pacific.
SHOW STREAMS LIKE 'STREAM_LMS7%HOTEL_RESERVATIONS_FACT' IN SCHEMA DAAS_PROD.DAAS_CORE_HOTEL;
SHOW STREAMS LIKE 'STREAM_LMS7%HOTEL_RESERVATIONS_FACT' IN SCHEMA DAAS_UAT.DAAS_CORE_HOTEL;


-- 2. How far behind the consolidated fact is. This is also the test that the fix and the replay worked.
--    Today: the last three columns are large. Done: all three are 0.
SELECT COUNT(*)                                              AS LMS73_RESERVATIONS,
       COUNT_IF(C.RESERVATION_ID IS NULL)                    AS MISSING_FROM_CONSOLIDATED,
       COUNT_IF(C.LAST_MODIFIED_DTTM < L.LAST_MODIFIED_DTTM) AS OUT_OF_DATE_IN_CONSOLIDATED,
       COUNT_IF(NULLIF(TRIM(L.LOYALTY), '') IS NOT NULL
                AND NVL(TRIM(C.LOYALTY), '') <> TRIM(L.LOYALTY)) AS LOYALTY_NOT_CARRIED
FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT L
LEFT JOIN DAAS_PROD.DAAS_CORE_HOTEL.HOTEL_RESERVATIONS_FACT C
    ON C.PROPERTY_CD = L.PROPERTY_CD
    AND C.RESERVATION_ID = L.RESERVATION_ID
    AND C.DELETE_IND = 'N'
WHERE L.DELETE_IND = 'N';
