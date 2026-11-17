-- DAASI-3858  Missing CHECK_ATTRIBUTE_IDs in CHECK_ITEM_FACT_VW
-- Round 3.
--
-- Where round 2 left us. Access rules are ruled out: the original queries (2026-10-29, about 4:20 pm Pacific)
-- ran as DAAS_STRATEGIC_ANALYTICS_USER_PROD_PROD, a role PROPERTY_RLS_POLICY lets through for every property,
-- and both tables carry that same policy. What D4 shows instead is a late load: the check was loaded on
-- 2026-10-28 22:07:42 and its 14 lines on 2026-11-06 08:03:56. On 10/29 the lines were not there to be found.
-- This round asks what loaded them on 11/06, whether that was their first load or a reload, and how many
-- other checks got their lines late.
--
-- Every statement only reads. Run them one at a time. None depends on another.
-- If one is refused or fails, skip it and send me the error text as it appears.


-- =====================================================================================================
-- PART G. The example: how and when each piece of the check arrived
-- =====================================================================================================

-- G1. The load record on each piece of this check, from the tables: its sales row, its own record, its
--     payments and its 14 lines. BATCH_ID is the pipeline run that wrote the rows.
--     REPLAY_COUNTER above 0, or LAST_DML_CD other than I, would mean rows were written again after their
--     first load. The source sequence numbers show the order in which the POS system's changes were
--     captured: if the lines' numbers sit right next to the check's, they were captured together and the
--     delay happened inside our own pipeline.
SELECT '1 sales row'                  AS piece,
       COUNT(*)                       AS row_count,
       CREATED_DTTM,
       UPDATED_DTTM,
       CREATED_BY,
       UPDATED_BY,
       BATCH_ID,
       LAST_DML_CD,
       REPLAY_COUNTER,
       MIN(OPERATION_SEQUENCE_NBR)    AS first_source_sequence,
       MAX(OPERATION_SEQUENCE_NBR)    AS last_source_sequence
FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
WHERE CHECK_ATTRIBUTE_ID = '170818751'
  AND PROPERTY_CD = 'CLV'
GROUP BY CREATED_DTTM, UPDATED_DTTM, CREATED_BY, UPDATED_BY, BATCH_ID, LAST_DML_CD, REPLAY_COUNTER
UNION ALL
SELECT '2 check record',
       COUNT(*),
       CREATED_DTTM,
       UPDATED_DTTM,
       CREATED_BY,
       UPDATED_BY,
       BATCH_ID,
       LAST_DML_CD,
       CAST(NULL AS NUMBER),
       MIN(OPERATION_SEQUENCE_NBR),
       MAX(OPERATION_SEQUENCE_NBR)
FROM DAAS_PROD.DAAS_CORE.CHECK_ATTRIBUTE_DIM
WHERE CHECK_ATTRIBUTE_ID = '170818751'
  AND PROPERTY_CD = 'CLV'
GROUP BY CREATED_DTTM, UPDATED_DTTM, CREATED_BY, UPDATED_BY, BATCH_ID, LAST_DML_CD
UNION ALL
SELECT '3 payments',
       COUNT(*),
       CREATED_DTTM,
       UPDATED_DTTM,
       CREATED_BY,
       UPDATED_BY,
       BATCH_ID,
       LAST_DML_CD,
       REPLAY_COUNTER,
       MIN(OPERATION_SEQUENCE_NBR),
       MAX(OPERATION_SEQUENCE_NBR)
FROM DAAS_PROD.DAAS_CORE.CHECK_TENDER_FACT
WHERE CHECK_ATTRIBUTE_ID = '170818751'
  AND PROPERTY_CD = 'CLV'
GROUP BY CREATED_DTTM, UPDATED_DTTM, CREATED_BY, UPDATED_BY, BATCH_ID, LAST_DML_CD, REPLAY_COUNTER
UNION ALL
SELECT '4 lines',
       COUNT(*),
       CREATED_DTTM,
       UPDATED_DTTM,
       CREATED_BY,
       UPDATED_BY,
       BATCH_ID,
       LAST_DML_CD,
       REPLAY_COUNTER,
       MIN(OPERATION_SEQUENCE_NBR),
       MAX(OPERATION_SEQUENCE_NBR)
FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
WHERE CHECK_ATTRIBUTE_ID = '170818751'
  AND PROPERTY_CD = 'CLV'
GROUP BY CREATED_DTTM, UPDATED_DTTM, CREATED_BY, UPDATED_BY, BATCH_ID, LAST_DML_CD, REPLAY_COUNTER
ORDER BY 1, 3;


-- G2. The pipeline's own log entry for each run that wrote a piece of this check: which job, when it ran,
--     and how it ended.
SELECT b.batch_id,
       j.job_name,
       b.batch_status,
       b.batch_start_date,
       b.updated_dttm,
       DATEDIFF('second', b.batch_start_date, b.updated_dttm) AS seconds
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j
  ON j.job_id = b.job_id
WHERE b.batch_id IN (
        SELECT BATCH_ID FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
        WHERE CHECK_ATTRIBUTE_ID = '170818751' AND PROPERTY_CD = 'CLV'
        UNION
        SELECT BATCH_ID FROM DAAS_PROD.DAAS_CORE.CHECK_ATTRIBUTE_DIM
        WHERE CHECK_ATTRIBUTE_ID = '170818751' AND PROPERTY_CD = 'CLV'
        UNION
        SELECT BATCH_ID FROM DAAS_PROD.DAAS_CORE.CHECK_TENDER_FACT
        WHERE CHECK_ATTRIBUTE_ID = '170818751' AND PROPERTY_CD = 'CLV'
        UNION
        SELECT BATCH_ID FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
        WHERE CHECK_ATTRIBUTE_ID = '170818751' AND PROPERTY_CD = 'CLV')
ORDER BY b.batch_id;


-- G3. The job that loaded the lines, day by day from 2026-10-24 to 2026-11-09: how often it ran, how many
--     runs did not succeed, and its longest run. A stretch of failed or missing runs before 11/06 would
--     explain the delay. A job that only shows up on 11/06 would mean a one-off catch-up.
WITH line_job AS (
    SELECT DISTINCT job_id
    FROM DAAS_PROD.DAAS_COMMON.BATCH_S02
    WHERE batch_id IN (SELECT BATCH_ID FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
                       WHERE CHECK_ATTRIBUTE_ID = '170818751' AND PROPERTY_CD = 'CLV')
)
SELECT j.job_name,
       b.batch_start_date::DATE                                                      AS run_day,
       COUNT(*)                                                                      AS runs,
       COUNT_IF(NOT STARTSWITH(b.batch_status, 'SUCCESS'))                           AS runs_not_succeeded,
       MIN(b.batch_start_date)                                                       AS first_run,
       MAX(b.batch_start_date)                                                       AS last_run,
       ROUND(MAX(DATEDIFF('second', b.batch_start_date, b.updated_dttm)) / 60, 1)    AS longest_run_minutes
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j
  ON j.job_id = b.job_id
WHERE b.job_id IN (SELECT job_id FROM line_job)
  AND b.batch_start_date >= '2026-10-24'
  AND b.batch_start_date <  '2026-11-10'
GROUP BY 1, 2
ORDER BY 1, 2;


-- G4. The statements that put rows into CHECK_ITEM_FACT between the evening of 11/05 and noon on 11/06
--     (Pacific): who ran them, how many rows, and which objects each one names.
--     NEAR_THE_LINE_LOAD marks statements that started within 30 seconds of the lines' load time, 08:03:56,
--     read either as Pacific or as UTC. Expect the pipeline's regular loads and possibly one much larger
--     statement. Please send this one as text.
SELECT start_time,
       user_name,
       role_name,
       query_type,
       rows_inserted,
       ROUND(total_elapsed_time / 1000)     AS seconds,
       query_tag,
       IFF(ABS(DATEDIFF('second', start_time, '2026-11-06 08:03:56'::TIMESTAMP_LTZ)) <= 30
        OR ABS(DATEDIFF('second', start_time, '2026-11-06 00:03:56'::TIMESTAMP_LTZ)) <= 30, 'YES', '')
                                            AS near_the_line_load,
       ARRAY_TO_STRING(ARRAY_DISTINCT(REGEXP_SUBSTR_ALL(UPPER(query_text), '(FROM|JOIN|USING|INTO)\\s+[A-Z0-9_."$]+')), ' | ')
                                            AS objects_named,
       LEFT(query_text, 300)                AS query_text_start
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= '2026-11-05 22:00:00'
  AND start_time <  '2026-11-06 12:00:00'
  AND query_text ILIKE '%CHECK_ITEM_FACT%'
  AND rows_inserted > 0
ORDER BY start_time;


-- =====================================================================================================
-- PART H. How common is a late load?
-- =====================================================================================================

-- H1. Live checks loaded from 2026-10-15 to 2026-11-14, by the day the check was loaded: how soon its first
--     line followed. The two LATE columns and SALES_BUT_NO_LINES_YET are the ones to watch.
--     Lines are looked for from 2026-10-08 onward. If a reload deletes lines and writes them again, their
--     load time moves, so read this next to G1.
WITH checks AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MIN(CREATED_DTTM)            AS check_loaded,
           MAX(ABS(SALES_GROSS_AMT))    AS net_sales
    FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
    WHERE CREATED_DTTM >= '2026-10-15'
      AND CREATED_DTTM <  '2026-11-15'
      AND DELETE_IND = 'N'
    GROUP BY 1, 2
),
lines AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MIN(CREATED_DTTM)            AS lines_loaded
    FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
    WHERE CREATED_DTTM >= '2026-10-08'
    GROUP BY 1, 2
)
SELECT c.check_loaded::DATE                                                                AS check_load_day,
       COUNT(*)                                                                            AS checks,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) <= 60)                  AS lines_within_1_hour,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) BETWEEN 61 AND 1440)    AS lines_within_1_day,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) BETWEEN 1441 AND 4320)  AS late_1_to_3_days,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) > 4320)                 AS late_over_3_days,
       COUNT_IF(l.lines_loaded IS NULL AND c.net_sales > 0)                                AS sales_but_no_lines_yet,
       COUNT_IF(l.lines_loaded IS NULL AND COALESCE(c.net_sales, 0) = 0)                   AS no_sales_no_lines,
       MAX(DATEDIFF('day', c.check_loaded, l.lines_loaded))                                AS worst_delay_days
FROM checks c
LEFT JOIN lines l
       ON l.CHECK_ATTRIBUTE_ID = c.CHECK_ATTRIBUTE_ID
      AND l.PROPERTY_CD = c.PROPERTY_CD
GROUP BY 1
ORDER BY 1;


-- H2. The late ones only (first line more than a day after the check), grouped by the day their lines
--     arrived. One big day would mean a single catch-up load. CLV and RW2 are the example's property and
--     source code, counted to show whether the delay was particular to them.
WITH checks AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MAX(SRC_PROPERTY_CD)         AS src_property_cd,
           MIN(CREATED_DTTM)            AS check_loaded
    FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
    WHERE CREATED_DTTM >= '2026-10-15'
      AND CREATED_DTTM <  '2026-11-15'
      AND DELETE_IND = 'N'
    GROUP BY 1, 2
),
lines AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MIN(CREATED_DTTM)            AS lines_loaded
    FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
    WHERE CREATED_DTTM >= '2026-10-08'
    GROUP BY 1, 2
)
SELECT l.lines_loaded::DATE                     AS lines_arrived_on,
       COUNT(*)                                 AS late_checks,
       COUNT(DISTINCT c.PROPERTY_CD)            AS properties,
       COUNT(DISTINCT c.src_property_cd)        AS source_codes,
       MIN(c.check_loaded)::DATE                AS earliest_check_load,
       MAX(c.check_loaded)::DATE                AS latest_check_load,
       COUNT_IF(c.PROPERTY_CD = 'CLV')          AS clv_checks,
       COUNT_IF(c.src_property_cd = 'RW2')      AS rw2_checks
FROM checks c
JOIN lines l
  ON l.CHECK_ATTRIBUTE_ID = c.CHECK_ATTRIBUTE_ID
 AND l.PROPERTY_CD = c.PROPERTY_CD
WHERE DATEDIFF('minute', c.check_loaded, l.lines_loaded) > 1440
GROUP BY 1
ORDER BY 1;


-- =====================================================================================================
-- PART I. Where the lines first land
-- =====================================================================================================

-- I1. The raw InfoGenesis tables with CHECK or ITEM in the name, in the HVR and the OpenFlow schemas: size,
--     last change and column list. This is so the next step can look for the lines where they first arrive.
--     Please send this one as text.
SELECT t.table_schema,
       t.table_name,
       t.row_count,
       t.last_altered,
       c.column_count,
       c.columns
FROM DAAS_PROD.INFORMATION_SCHEMA.TABLES t
JOIN (
    SELECT table_schema,
           table_name,
           COUNT(*) AS column_count,
           LISTAGG(column_name || ' ' || data_type, ', ') WITHIN GROUP (ORDER BY ordinal_position) AS columns
    FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema IN ('DAAS_RAW_INFOGEN_ONPREM', 'DAAS_RAW_INFOG_OPENFLOW')
      AND (table_name LIKE '%CHECK%' OR table_name LIKE '%ITEM%')
    GROUP BY 1, 2
) c
  ON c.table_schema = t.table_schema
 AND c.table_name = t.table_name
WHERE t.table_schema IN ('DAAS_RAW_INFOGEN_ONPREM', 'DAAS_RAW_INFOG_OPENFLOW')
  AND (t.table_name LIKE '%CHECK%' OR t.table_name LIKE '%ITEM%')
ORDER BY 1, 2;
