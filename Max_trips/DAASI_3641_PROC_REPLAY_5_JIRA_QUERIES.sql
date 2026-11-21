-- DAASI-3641: four queries for the Jira comment. Read-only, each short enough to paste with its result.
--
--   1  the reporting view: the longest BEM and WLM market trip without a hotel stay (Tracy's measure)
--   2  the trip tables: the same, every trip counted by its length
--   3  nothing lost: every transaction that sat on the long trips, and where it is today
--   4  the record: every call made for the ticket, from the replay procedure's own log
--
-- Max trip days are 1 in BEM and 3 in WLM. A trip with a hotel night is outside the cap, so 1 and 2 leave those
-- out, as Tracy's query does.
-- 1, 2 and 4 read permanent objects and can be run again at any time. 3 reads the list of trips and the
-- before-picture, so run it before Z (the drops); after that its screenshot is the record.
--
-- Large warehouse. 2 and 3 take a few minutes each. Run each on its own and send me the four results: I will
-- write the comment around them.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- 1. Tracy's query from DAASI-3376, by market: the longest market trip without a hotel stay in the reporting view.
--    Expect BEM 1 and WLM 3.
SELECT market_cd,
       MAX(trip_days) AS longest_trip_days
FROM daas_prod.daas_core_marketing_vw.trip_summary_vw
WHERE market_cd IN ('BEM', 'WLM')
  AND trip_type = 'MARKET'
  AND hotel_flg = 'N'
GROUP BY market_cd
ORDER BY market_cd;


-- 2. The same in the trip tables themselves: every live BEM/WLM market trip with no hotel night, counted by its
--    length in days. Expect one BEM line (1 day) and three WLM lines (1, 2 and 3 days), and nothing longer.
SELECT m.MARKET_CD                          AS market,
       m.TRIP_END_DT - m.TRIP_START_DT + 1  AS trip_days,
       COUNT(*)                             AS trips
FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER m
WHERE m.DELETE_IND = 'N'
  AND m.TRIP_TYPE = 'MARKET'
  AND m.MARKET_CD IN ('BEM', 'WLM')
  AND NOT EXISTS (SELECT 1
                  FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                  WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID
                    AND d.DELETE_IND = 'N'
                    AND d.TRANSACTION_TYPE = 'HOTEL')
GROUP BY 1, 2
ORDER BY 1, 2;


-- 3. Nothing lost, by SK. Every transaction that sat on the 378,798 long trips before the replay, and where it is
--    today: about 9.9 million in BEM and 3.6 million in WLM. Expect lost 0 and on_two_trips_of_one_guest 0.
--    gone_from_property_trips_too will be about 110: those are on no trip of any kind today, the property trips
--    included, so there is nothing for a market trip to carry.
WITH was AS (       /* every transaction on the long trips before the replay, one row per business date */
    SELECT DISTINCT l.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS l
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d
      ON d.TRIP_MASTER_ID = l.TRIP_MASTER_ID
    WHERE d.DELETE_IND = 'N'
      AND d.TRANSACTION_SUB_TYPE = 'OPENED'
),
now_on AS (         /* the live trips each one sits on today: market trips, and trips of the other kinds */
    SELECT w.MARKET_CD, w.TRANSACTION_TABLE, w.TRANSACTION_TABLE_SK, w.BUSINESS_START_DT,
           COUNT(DISTINCT IFF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = w.MARKET_CD,
                              m.TRIP_MASTER_ID, NULL))   AS MARKET_TRIPS,
           COUNT(DISTINCT IFF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = w.MARKET_CD,
                              m.GUEST_UNIQUE_ID, NULL))  AS GUESTS,
           COUNT_IF(m.TRIP_TYPE <> 'MARKET')             AS OTHER_TRIPS
    FROM was w
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
           ON d.TRANSACTION_TABLE = w.TRANSACTION_TABLE
          AND d.TRANSACTION_TABLE_SK = w.TRANSACTION_TABLE_SK
          AND d.BUSINESS_START_DT = w.BUSINESS_START_DT
          AND d.DELETE_IND = 'N'
          AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m
           ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID
          AND m.DELETE_IND = 'N'
    GROUP BY w.MARKET_CD, w.TRANSACTION_TABLE, w.TRANSACTION_TABLE_SK, w.BUSINESS_START_DT
)
SELECT MARKET_CD                                       AS market,
       COUNT(*)                                        AS transactions_on_the_long_trips,
       COUNT_IF(MARKET_TRIPS > 0)                      AS on_a_market_trip_today,
       COUNT_IF(MARKET_TRIPS = 0 AND OTHER_TRIPS = 0)  AS gone_from_property_trips_too,
       COUNT_IF(MARKET_TRIPS = 0 AND OTHER_TRIPS > 0)  AS lost,
       COUNT_IF(MARKET_TRIPS > 1 AND GUESTS = 1)       AS on_two_trips_of_one_guest
FROM now_on
GROUP BY MARKET_CD
ORDER BY MARKET_CD;


-- 4. The record: one row per call that updated rows, from the procedure's log. Two calls a batch (the rating
--    rows, then the trips) and the repair calls, the last of them the 282 rows of 20 Nov. QUERY_ID is the update
--    itself, as Query History has it.
SELECT CREATED_DTTM, CREATED_BY, TABLE_NAME, ROWS_UPDATED, THRESHOLD, THRESHOLD_OVERRIDE, QUERY_ID
FROM DAAS_PROD.DAAS_COMMON.DATA_REPLAY_LOG
WHERE TICKET_ID = 'DAASI-3641'
  AND CREATED_DTTM >= '2026-11-13'
  AND ROWS_UPDATED > 0
ORDER BY CREATED_DTTM;
