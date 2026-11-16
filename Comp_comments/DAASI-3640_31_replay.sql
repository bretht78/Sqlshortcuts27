/* =====================================================================
   COMP COMMENT REPLAY: the comment and remarks text that is missing from
   the comp table, added by one UPDATE. Follow-up to DAASI-3640.
   Ticket: ____________

   One script, in the order things have to happen. It replaces the two
   files of 11/11 (30 and 30b). The UPDATE statement is the same one.

   WHAT IT DOES
   The UPDATE writes the remarks (COMMENTS_EXTENDED) and, where the comp's
   own comment is not showing, the comment (COMP_COMMENTS_DESC), on the
   comps where CMS holds text that DAAS_CORE.COMP_DETAIL_FACT does not.
   About 1.32 million rows of 266 million (1,321,634 when counted on
   11/11; the count of the day is STEP 7's).
     - Every row it touches gains text. STEP 8 shows it, by kind.
     - No comment is replaced with nothing.
     - The comps whose text the v1.14 rule would only shorten or blank
       (about 6.6 million) are not touched.
   It stamps UPDATED_DTTM, UPDATED_BY and LAST_DML_CD the way the load
   stamps an update, so anything that picks up comps by update time sees
   these rows once. No other column is touched. MD5_CHECKSUM is left
   alone on purpose: the load compares it the next time it touches a
   comp. (It must never be set to NULL: the load would then skip the row
   for good.)

   THE ORDER
   STEP  WHO     WHAT
     1   Chris   The same day, before the window: the answer key
         ------  the window opens --------------------------------------
     2   Chris   Suspend the comp load; no run still executing
     3   Pete    Any other load into the comp table is held (Hexlite)
     4   Pete    Suspend trips. It has taken what the load left:
                 both streams read 0 and 0
     5   Chris   Backup of the comp table, and its check
     6   Chris   The list of rows to update
     7   Chris   The count, and four things that must hold
     8   Chris   The breakdown: why each row is in the run
     9   Pete    His own look: streams 0 and 0, and the same count
    10   Pete    THE UPDATE
    11   Pete    The streams are emptied, if they hold only the update
    12   Chris   The after-checks, all before any resume
         ------  the window closes -------------------------------------
    13   Pete    Resume trips and the loads
    14   Chris   Both tasks are started and the load loads
   UNDO and CLEAN-UP are at the bottom, commented out.

   Chris runs as DAAS_TEAM, which cannot update the comp table. Pete runs
   as the role that can.

   THREE RULES
   1. A step starts when the one before it has shown what it should.
      Where a step says stop, stop.
   2. STEPS 9 to 11 are Pete's alone: one user, one after the other.
      What a stream holds when it is emptied is gone for good, so STEP
      11 empties only what the user running it has just updated.
   3. A line that starts with two dashes is for a special case, named
      beside it. Take the dashes off only for that case.

   WHY THE STREAMS ARE EMPTIED
   Two streams on the comp table feed trips
   (COMP_DETAIL_FACT_COMP_DOMAIN_STREAM and ..._FP_DOMAIN_STREAM). The
   UPDATE puts every row it changes into both, and trips has no use for
   comment text. So trips first takes what the load left (STEP 4), the
   UPDATE runs (STEP 10), and the streams are emptied before trips is
   resumed (STEP 11). With every load held, the UPDATE is the only thing
   in them, and STEP 11 checks that before it empties. If Pete would
   rather have trips process the updated comps: leave out STEP 11.

   BEFORE PROD
   The UPDATE, the stream statement of STEP 11 and the after-checks have
   not run on Snowflake yet (STEPS 1, 5, 6 and 7 ran in PROD on 11/11).
   So: once in UAT first. Replace DAAS_PROD. with DAAS_UAT. throughout
   and run it top to bottom; there, whoever can update the UAT comp table
   runs STEPS 9 to 11.
   Use a Large for STEPS 1, 6, 8, 10, 11 and 12.
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 1   Chris   THE SAME DAY, BEFORE THE WINDOW: THE ANSWER KEY
   For every active HETCMS comp: the comment and remarks the comp table
   holds now (OLD_) and the ones the v1.14 rules give from the raw CMS
   tables (NEW_). It writes only the key table, and the load keeps
   running while it builds. A row the load changes afterwards is left out
   by STEP 6, and again by the UPDATE itself.
   The statement is the one that built the key on 11/11. It is the long
   one (it reads the bridge, 251 million rows): use a Large.
   If it cannot be run that day, the key of 11/11 still works. It then
   misses only text typed in CMS since 11/11 on comps the load has not
   touched since.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TRANSIENT TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_KEY AS
WITH comps AS (
    SELECT COMP_DETAIL_FACT_SK, COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD, GUEST_ID, ISSUE_DT,
           COMP_COMMENTS_DESC AS OLD_COMMENT,
           COMMENTS_EXTENDED  AS OLD_REMARKS,
           UPDATED_DTTM       AS OLD_UPDATED_DTTM,
           BATCH_ID           AS OLD_BATCH_ID,
           MD5_CHECKSUM       AS OLD_MD5
    FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT
    WHERE DELETE_IND = 'N'
      AND SOURCE_SYSTEM_NM = 'HETCMS'
),
comments AS (   -- v1.14 rule: own lines (the line's guest held the comp), plus bridged lines: for a
                -- comp the feed first saw after its issue date, a line whose guest never held any
                -- comp on that number, written by the same person (same primary account in the
                -- bridge) and not older than the comp. The holder's own line wins on a line number.
    SELECT CNUMRW, ISHDRW, PROPERTY_CODE,
           LISTAGG(CMNTCM, '|') WITHIN GROUP (ORDER BY CSEQCM) AS CMNTCM
    FROM (
        SELECT CNUMRW, ISHDRW, PROPERTY_CODE, CSEQCM, CMNTCM
        FROM (
            SELECT H.CNUMRW, H.ISHDRW, H.PROPERTY_CODE, L.CSEQCM, L.CMNTCM, 1 AS MATCH_RANK,
                   L.OPERATION_DATE, L.OPERATION_SEQUENCE_NBR, L.CREATED_DATE
            FROM (SELECT DISTINCT CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW
                  FROM DAAS_PROD.DAAS_RAW_HETCMS.CMPRW_RAW) H
            JOIN (SELECT SYIDCM, "CMP#CM", CSEQCM, CMNTCM, PROPERTY_CODE,
                         OPERATION_DATE, OPERATION_SEQUENCE_NBR, CREATED_DATE
                  FROM DAAS_PROD.DAAS_RAW_HETCMS.ECPCMPCM_RAW
                  QUALIFY ROW_NUMBER() OVER (PARTITION BY SYIDCM, "CMP#CM", CSEQCM, PROPERTY_CODE
                          ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1) L
              ON L.SYIDCM = H.SYIDRW AND L."CMP#CM" = H.CNUMRW AND L.PROPERTY_CODE = H.PROPERTY_CODE
            UNION ALL
            SELECT H.CNUMRW, H.ISHDRW, H.PROPERTY_CODE, L.CSEQCM, L.CMNTCM, 2 AS MATCH_RANK,
                   L.OPERATION_DATE, L.OPERATION_SEQUENCE_NBR, L.CREATED_DATE
            FROM (SELECT SYIDCM, "CMP#CM", CSEQCM, CMNTCM, PROPERTY_CODE,
                         OPERATION_DATE, OPERATION_SEQUENCE_NBR, CREATED_DATE,
                         MIN(OPERATION_DATE) OVER (PARTITION BY SYIDCM, "CMP#CM", CSEQCM, PROPERTY_CODE) AS FIRST_SEEN
                  FROM DAAS_PROD.DAAS_RAW_HETCMS.ECPCMPCM_RAW
                  QUALIFY ROW_NUMBER() OVER (PARTITION BY SYIDCM, "CMP#CM", CSEQCM, PROPERTY_CODE
                          ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1) L
            JOIN (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW
                  FROM (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW,
                               MIN(OPERATION_DATE) OVER (PARTITION BY CNUMRW, ISHDRW, PROPERTY_CODE) AS FIRST_SEEN
                        FROM DAAS_PROD.DAAS_RAW_HETCMS.CMPRW_RAW)
                  WHERE FIRST_SEEN::DATE > DATEADD(DAY, 1, DECODE(ISHDRW, 0, '1899-12-31'::DATE, ISHDRW + '1899-12-31'::DATE))
                  GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW) H
              ON L."CMP#CM" = H.CNUMRW AND L.PROPERTY_CODE = H.PROPERTY_CODE
            JOIN (SELECT PROPERTY_CD, MIN(PROPERTY_ID)::VARCHAR AS PROPERTY_ID
                  FROM DAAS_PROD.DAAS_CORE.PROPERTY_DIM GROUP BY PROPERTY_CD) P
              ON P.PROPERTY_CD = H.PROPERTY_CODE
            JOIN DAAS_PROD.DAAS_CORE.GUEST_XREF_BRIDGE_LKP BL
              ON BL.XREF_ACCOUNT_NBR = P.PROPERTY_ID || LPAD(L.SYIDCM::VARCHAR, 8, '0')
            JOIN DAAS_PROD.DAAS_CORE.GUEST_XREF_BRIDGE_LKP BH
              ON BH.XREF_ACCOUNT_NBR = P.PROPERTY_ID || LPAD(H.SYIDRW::VARCHAR, 8, '0')
             AND BH.PRIMARY_ACCOUNT_NBR = BL.PRIMARY_ACCOUNT_NBR
            WHERE NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_RAW_HETCMS.CMPRW_RAW N
                              WHERE N.CNUMRW = L."CMP#CM" AND N.PROPERTY_CODE = L.PROPERTY_CODE AND N.SYIDRW = L.SYIDCM)
              AND L.FIRST_SEEN::DATE >= DATEADD(DAY, -1, DECODE(H.ISHDRW, 0, '1899-12-31'::DATE, H.ISHDRW + '1899-12-31'::DATE))
        )
        QUALIFY ROW_NUMBER() OVER (PARTITION BY CNUMRW, ISHDRW, PROPERTY_CODE, CSEQCM
                ORDER BY MATCH_RANK, OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
    )
    GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE
),
remarks AS (    -- remarks rule: a remark line belongs to the comp live on its number when written
    SELECT CNUMRW, ISHDRW, PROPERTY_CODE,
           LEFT(LISTAGG(EXPLRM, '|') WITHIN GROUP (ORDER BY SEQNRM), 4000) AS COMMENTS_EXTENDED
    FROM (
        SELECT C.CNUMRW, C.ISHDRW, C.PROPERTY_CODE, R.SEQNRM, R.EXPLRM
        FROM (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, FIRST_SEEN,
                     LAG(FIRST_SEEN)  OVER (PARTITION BY CNUMRW, PROPERTY_CODE ORDER BY FIRST_SEEN, ISHDRW) AS PREV_FIRST_SEEN,
                     LEAD(FIRST_SEEN) OVER (PARTITION BY CNUMRW, PROPERTY_CODE ORDER BY FIRST_SEEN, ISHDRW) AS NEXT_FIRST_SEEN
              FROM (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, MIN(OPERATION_DATE) AS FIRST_SEEN
                    FROM DAAS_PROD.DAAS_RAW_HETCMS.CMPRW_RAW
                    GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE)) C
        JOIN DAAS_PROD.DAAS_RAW_HETCMS.CMPRM_RAW R
          ON R.CNUMRM = C.CNUMRW
         AND R.PROPERTY_CODE = C.PROPERTY_CODE
         AND (C.PREV_FIRST_SEEN IS NULL OR R.OPERATION_DATE >= DATEADD(SECOND, -60, C.FIRST_SEEN))
         AND (C.NEXT_FIRST_SEEN IS NULL OR R.OPERATION_DATE <  DATEADD(SECOND, -60, C.NEXT_FIRST_SEEN))
        QUALIFY ROW_NUMBER() OVER (PARTITION BY C.CNUMRW, C.ISHDRW, C.PROPERTY_CODE, R.SEQNRM
                ORDER BY R.OPERATION_DATE DESC, R.OPERATION_SEQUENCE_NBR DESC, R.CREATED_DATE DESC) = 1
    )
    GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE
)
SELECT s.*,
       c.CMNTCM            AS NEW_COMMENT,
       r.COMMENTS_EXTENDED AS NEW_REMARKS,
       (c.CMNTCM IS DISTINCT FROM s.OLD_COMMENT OR r.COMMENTS_EXTENDED IS DISTINCT FROM s.OLD_REMARKS) AS WILL_CHANGE
FROM comps s
LEFT JOIN comments c ON c.CNUMRW = s.COMP_NBR AND c.ISHDRW = s.ISHDRW AND c.PROPERTY_CODE = s.PROPERTY_CD
LEFT JOIN remarks  r ON r.CNUMRW = s.COMP_NBR AND r.ISHDRW = s.ISHDRW AND r.PROPERTY_CODE = s.PROPERTY_CD;


/* ---------------------------------------------------------------------
   STEP 2   Chris (or Pete)   THE WINDOW OPENS: SUSPEND THE COMP LOAD
   From here to STEP 13 the comp load does not run. What CMS sends in the
   meantime waits in the raw tables, and the first run after the resume
   loads it.
   --------------------------------------------------------------------- */
ALTER TASK DAAS_PROD.DAAS_COMMON.RAW2CORE_HETCMS_COMP_DETAIL_FACT_TASK SUSPEND;

-- A run that was already going finishes by itself (one to two minutes). Run this until no row
-- reads EXECUTING.
SELECT state, scheduled_time, query_start_time, completed_time
FROM TABLE(DAAS_PROD.INFORMATION_SCHEMA.TASK_HISTORY(
         TASK_NAME => 'RAW2CORE_HETCMS_COMP_DETAIL_FACT_TASK',
         SCHEDULED_TIME_RANGE_START => DATEADD(minute, -30, CURRENT_TIMESTAMP()),
         RESULT_LIMIT => 10))
ORDER BY scheduled_time DESC;


/* ---------------------------------------------------------------------
   STEP 3   Pete   ANY OTHER LOAD INTO THE COMP TABLE IS HELD
   Since 11/11 a second load writes to the comp table: HEXLITE-CMP rows
   by SYSTEM, seen at 20:05 on 11/11 and at 02:05 on 11/12 (Snowflake's
   clock, Pacific). A row it writes between STEP 9 and STEP 11 would be
   in the streams when they are emptied, and trips would never see it. So
   it is suspended like the comp load, or STEPS 9 to 11 are run well
   clear of its next run (they take a few minutes).
   --------------------------------------------------------------------- */
-- The tasks named after the comp table, with "state" and "schedule", as far as this role sees them.
SHOW TASKS LIKE '%COMP_DETAIL_FACT%' IN DATABASE DAAS_PROD;

--   Only if it is to be suspended (Pete knows the task):
--   ALTER TASK DAAS_PROD.<schema>.<the Hexlite comp load task> SUSPEND;


/* ---------------------------------------------------------------------
   STEP 4   Pete   TRIPS TAKES WHAT THE LOAD LEFT, AND IS SUSPENDED
   The last load put its rows into the two streams. Trips has to take
   them before the UPDATE, because STEP 11 empties the streams.
   --------------------------------------------------------------------- */
-- 4a. Where the task is, its state and its schedule. DAAS_COMMON in 4b is an assumption: if
--     "schema_name" reads otherwise, change it in 4b, in the EXECUTE TASK line and in STEP 13.
SHOW TASKS LIKE 'TRIP_ROOT_TASK' IN DATABASE DAAS_PROD;

-- 4b. Suspend it. A run of the task graph that is already going finishes by itself.
ALTER TASK DAAS_PROD.DAAS_COMMON.TRIP_ROOT_TASK SUSPEND;

-- 4c. No trips run is going: no row reads EXECUTING. (No rows at all is the same answer.)
SELECT ROOT_TASK_NAME, STATE, SCHEDULED_TIME, QUERY_START_TIME
FROM TABLE(DAAS_PROD.INFORMATION_SCHEMA.CURRENT_TASK_GRAPHS(ROOT_TASK_NAME => 'TRIP_ROOT_TASK'));

-- 4d. The streams named after the comp table: the two that follow, each with "mode" DEFAULT.
--     If it lists another stream on the comp table, stop: the UPDATE would fill that one too.
SHOW STREAMS LIKE '%COMP_DETAIL_FACT%' IN DATABASE DAAS_PROD;

-- 4e. Both streams read 0 and 0. A SELECT does not consume a stream.
SELECT 'COMP_DOMAIN' AS STREAM, COUNT(*) AS ROWS_WAITING
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_COMP_DOMAIN_STREAM
UNION ALL
SELECT 'FP_DOMAIN', COUNT(*)
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_FP_DOMAIN_STREAM;

--     If either reads above 0, trips has not taken the last load yet. One run by hand takes it
--     (a suspended root task runs once without being resumed):
--   EXECUTE TASK DAAS_PROD.DAAS_COMMON.TRIP_ROOT_TASK;
--     Then 4c until nothing reads EXECUTING, and 4e again. Do not go on until both read 0.


/* ---------------------------------------------------------------------
   STEP 5   Chris   THE BACKUP
   A zero-copy clone of the comp table, taken now that nothing loads, so
   it is the table exactly as the UPDATE finds it. The undo and two of
   the after-checks read it. Plain CREATE, so a rerun cannot overwrite it.
   Keep it for 90 days. (After the UPDATE it is no longer free to keep:
   it holds the old version of everything the UPDATE rewrote.)
   --------------------------------------------------------------------- */
CREATE TABLE DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY
  CLONE DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT;

--   Only if it answers "already exists": a backup from an earlier attempt at this run is there.
--   While STEP 10 has not run it protects nothing, so drop it and run the CREATE again. Never
--   after STEP 10: from then on it is the only copy of the text as it was.
--   DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY;

-- The backup is the comp table of this moment: two rows, the same two values.
SELECT '1. the fact' AS what, COUNT(*) AS rows_, MAX(UPDATED_DTTM) AS last_change
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT
UNION ALL
SELECT '2. the backup', COUNT(*), MAX(UPDATED_DTTM)
FROM DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY;


/* ---------------------------------------------------------------------
   STEP 6   Chris   THE LIST OF ROWS TO UPDATE
   One row for every comp whose text differs from the rules and whose row
   in the comp table still reads what the key saw. Texts are compared
   line by line, a line being what stands between two | marks, so "$95"
   is not found inside "$95 BASED ON PLAY".
     WRITE_REMARKS   the comp's remarks have a line the table's remarks
                     do not hold
     WRITE_COMMENT   the comp's own comment has a line the table's
                     comment does not hold
     IN_THIS_RUN     one of the two is true. A comp where neither is true
                     gains nothing and is left as it is.
     TO_COMMENT, TO_REMARKS   what the row reads after the UPDATE. A
                     column that is not written keeps today's value.
     WHAT            the kind of difference, for STEP 8
   The statement is the one that ran in PROD on 11/11. Use a Large.
   Run it once. Not again after STEP 10: the after-checks and the undo
   read this list.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TRANSIENT TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE AS
WITH differ AS (        -- text differs from the rules, and the row still reads what the key saw
    SELECT k.COMP_DETAIL_FACT_SK, k.COMP_NBR, k.ISHDRW, k.PROPERTY_CD, k.CASINO_OUTLET_CD, k.GUEST_ID, k.ISSUE_DT,
           k.OLD_COMMENT, k.OLD_REMARKS, k.NEW_COMMENT, k.NEW_REMARKS
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_KEY k
    JOIN DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT f
      ON f.COMP_DETAIL_FACT_SK = k.COMP_DETAIL_FACT_SK
    WHERE k.WILL_CHANGE
      AND f.DELETE_IND = 'N'
      AND f.COMP_COMMENTS_DESC IS NOT DISTINCT FROM k.OLD_COMMENT
      AND f.COMMENTS_EXTENDED  IS NOT DISTINCT FROM k.OLD_REMARKS
),
own_comment_lines AS (  -- lines of the comp's own comment that the fact's comment does not hold
    SELECT d.COMP_DETAIL_FACT_SK, COUNT(*) AS LINES_MISSING
    FROM differ d, LATERAL FLATTEN(INPUT => SPLIT(d.NEW_COMMENT, '|')) x
    WHERE TRIM(x.VALUE::VARCHAR) <> ''
      AND POSITION('|' || x.VALUE::VARCHAR || '|' IN '|' || COALESCE(d.OLD_COMMENT, '') || '|') = 0
    GROUP BY d.COMP_DETAIL_FACT_SK
),
shown_comment_lines AS ( -- lines the fact's comment holds that are not in the comp's own comment
    SELECT d.COMP_DETAIL_FACT_SK, COUNT(*) AS NOT_ITS_OWN
    FROM differ d, LATERAL FLATTEN(INPUT => SPLIT(d.OLD_COMMENT, '|')) x
    WHERE TRIM(x.VALUE::VARCHAR) <> ''
      AND POSITION('|' || x.VALUE::VARCHAR || '|' IN '|' || COALESCE(d.NEW_COMMENT, '') || '|') = 0
    GROUP BY d.COMP_DETAIL_FACT_SK
),
remark_lines AS (       -- lines of the comp's remarks: not in the fact's remarks, and not said by the comment it shows
    SELECT d.COMP_DETAIL_FACT_SK,
           COUNT_IF(POSITION('|' || x.VALUE::VARCHAR || '|' IN '|' || COALESCE(d.OLD_REMARKS, '') || '|') = 0) AS LINES_MISSING,
           COUNT_IF(POSITION('|' || x.VALUE::VARCHAR || '|' IN '|' || COALESCE(d.OLD_COMMENT, '') || '|') = 0) AS NOT_IN_THE_COMMENT
    FROM differ d, LATERAL FLATTEN(INPUT => SPLIT(d.NEW_REMARKS, '|')) x
    WHERE TRIM(x.VALUE::VARCHAR) <> ''
    GROUP BY d.COMP_DETAIL_FACT_SK
),
marked AS (
    SELECT d.COMP_DETAIL_FACT_SK, d.COMP_NBR, d.ISHDRW, d.PROPERTY_CD, d.CASINO_OUTLET_CD, d.GUEST_ID, d.ISSUE_DT,
           d.OLD_COMMENT, d.OLD_REMARKS, d.NEW_COMMENT, d.NEW_REMARKS,
           COALESCE(c.LINES_MISSING, 0) > 0                                 AS WRITE_COMMENT,
           COALESCE(r.LINES_MISSING, 0) > 0                                 AS WRITE_REMARKS,
           COALESCE(r.NOT_IN_THE_COMMENT, 0) > 0                            AS REMARKS_SAY_MORE,
           COALESCE(o.NOT_ITS_OWN, 0) > 0                                   AS SHOWS_LINES_NOT_ITS_OWN,
           NULLIF(TRIM(REPLACE(d.NEW_COMMENT, '|', '')), '') IS NOT NULL    AS HAS_OWN_COMMENT
    FROM differ d
    LEFT JOIN own_comment_lines   c ON c.COMP_DETAIL_FACT_SK = d.COMP_DETAIL_FACT_SK
    LEFT JOIN shown_comment_lines o ON o.COMP_DETAIL_FACT_SK = d.COMP_DETAIL_FACT_SK
    LEFT JOIN remark_lines        r ON r.COMP_DETAIL_FACT_SK = d.COMP_DETAIL_FACT_SK
)
SELECT m.COMP_DETAIL_FACT_SK, m.COMP_NBR, m.ISHDRW, m.PROPERTY_CD, m.CASINO_OUTLET_CD, m.GUEST_ID, m.ISSUE_DT,
       m.OLD_COMMENT, m.OLD_REMARKS, m.NEW_COMMENT, m.NEW_REMARKS,
       m.WRITE_COMMENT, m.WRITE_REMARKS, m.SHOWS_LINES_NOT_ITS_OWN,
       IFF(m.WRITE_COMMENT, m.NEW_COMMENT, m.OLD_COMMENT) AS TO_COMMENT,
       IFF(m.WRITE_REMARKS, m.NEW_REMARKS, m.OLD_REMARKS) AS TO_REMARKS,
       (m.WRITE_COMMENT OR m.WRITE_REMARKS)
           -- AND m.ISSUE_DT >= '2025-01-01'    -- a floor on the issue date: only if Pete asks for one
           AS IN_THIS_RUN,
       CASE WHEN m.WRITE_COMMENT AND m.SHOWS_LINES_NOT_ITS_OWN
                THEN '4. Comment missing, other text in its place: the comp''s own comment replaces it'
            WHEN m.WRITE_COMMENT
                THEN '3. Comment missing or incomplete: lines added'
            WHEN m.WRITE_REMARKS AND m.REMARKS_SAY_MORE
                THEN '1. Remarks missing: the report gains text'
            WHEN m.WRITE_REMARKS
                THEN '2. Remarks missing, same words as the comment: only the new column fills'
            WHEN m.SHOWS_LINES_NOT_ITS_OWN AND NOT m.HAS_OWN_COMMENT
                THEN '5. A note the rule does not give this comp: it would be blanked'
            WHEN m.SHOWS_LINES_NOT_ITS_OWN
                THEN '6. Lines the rule does not give this comp: they would be dropped'
            ELSE     '7. Other: nothing to add'
       END AS WHAT
FROM marked m;


/* ---------------------------------------------------------------------
   STEP 7   Chris   THE COUNT
   ROWS_THIS_RUN_UPDATES is what the UPDATE will report. Expect about
   1.32 million: a little off 11/11's 1,321,634, because the load has
   fixed some of these comps since and CMS has new text for others.
   Four things must hold, or stop here:
     COMMENTS_BLANKED       0      no row goes from a comment to none
     LONGEST_COMMENT        1000 or less    (the column's width)
     LONGEST_REMARKS        4000 or less    (the column's width)
     ROWS_WITHOUT_OWN_KEY   0      the UPDATE finds each row by its key
   --------------------------------------------------------------------- */
SELECT COUNT_IF(IN_THIS_RUN)                                                      AS rows_this_run_updates,
       COUNT_IF(NOT IN_THIS_RUN)                                                  AS left_as_they_are,
       COUNT(*)                                                                   AS all_that_differ,
       COUNT_IF(IN_THIS_RUN
                AND NULLIF(TRIM(REPLACE(OLD_COMMENT, '|', '')), '') IS NOT NULL
                AND NULLIF(TRIM(REPLACE(TO_COMMENT,  '|', '')), '') IS NULL)      AS comments_blanked,
       MAX(IFF(IN_THIS_RUN, LENGTH(TO_COMMENT), NULL))                            AS longest_comment,
       MAX(IFF(IN_THIS_RUN, LENGTH(TO_REMARKS), NULL))                            AS longest_remarks,
       COUNT(*) - COUNT(DISTINCT COMP_DETAIL_FACT_SK)                             AS rows_without_own_key
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE;


/* ---------------------------------------------------------------------
   STEP 8   Chris   THE BREAKDOWN: WHY EACH ROW IS IN THE RUN
   The rows the UPDATE would change at this moment, by kind. It reads
   the list against the comp table itself, with the UPDATE's own WHERE.
     Kinds 1 and 2   CMS has remarks for the comp and the table's remarks
                     column lacks them (the load did not read remarks
                     before DAASI-3640). In kind 1 the remarks say more
                     than the comment, so the report gains text. In kind
                     2 the remark repeats the comment word for word: the
                     new column fills, and the report reads as before.
     Kind 3          the comp's own comment has lines the table does not
                     show
     Kind 4          the table shows text that is not the comp's own
                     comment, and CMS has its own: its own is written
   ROWS_NOT_CHANGED and COMMENTS_BLANKED are 0 on every line, and the
   TOTAL line equals STEP 7's ROWS_THIS_RUN_UPDATES.
   This result is for the ticket. Take it now: after the UPDATE the
   query reads 0, because no row is left to change.
   --------------------------------------------------------------------- */
SELECT COALESCE(s.WHAT, 'TOTAL: rows the UPDATE changes')                       AS why_the_row_is_in_the_run,
       COUNT(*)                                                                  AS rows_to_update,
       COUNT_IF(s.TO_REMARKS IS DISTINCT FROM f.COMMENTS_EXTENDED)               AS remarks_written,
       COUNT_IF(s.TO_COMMENT IS DISTINCT FROM f.COMP_COMMENTS_DESC)              AS comment_written,
       COUNT_IF(s.TO_REMARKS IS NOT DISTINCT FROM f.COMMENTS_EXTENDED
            AND s.TO_COMMENT IS NOT DISTINCT FROM f.COMP_COMMENTS_DESC)          AS rows_not_changed,
       COUNT_IF(NULLIF(TRIM(REPLACE(f.COMP_COMMENTS_DESC, '|', '')), '') IS NOT NULL
            AND NULLIF(TRIM(REPLACE(s.TO_COMMENT, '|', '')), '') IS NULL)        AS comments_blanked
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE s
JOIN DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT f
  ON f.COMP_DETAIL_FACT_SK = s.COMP_DETAIL_FACT_SK
WHERE s.IN_THIS_RUN
  AND f.DELETE_IND = 'N'
  AND f.COMP_COMMENTS_DESC IS NOT DISTINCT FROM s.OLD_COMMENT
  AND f.COMMENTS_EXTENDED  IS NOT DISTINCT FROM s.OLD_REMARKS
GROUP BY ROLLUP (s.WHAT)
ORDER BY 1;

-- 8b. Optional, a second opinion on the text itself. The dynamic table is deployed code that
--     builds the same two texts from the raw CMS tables by itself, with no reference to the comp
--     table or to this list. Where this run writes a comment or remarks, the dynamic table should
--     already read the same: both DIFFER counts 0, or a handful where raw has moved since its last
--     refresh ("data_timestamp" in the first statement). NOT_ACTIVE_IN_DT counts comps the comp
--     table holds active that CMS has deleted: they get their text like the rest and stay active.
SHOW DYNAMIC TABLES LIKE 'COMP_DETAIL_FACT_DT' IN SCHEMA DAAS_PROD.DAAS_CORE_GAMING;

SELECT COUNT(*)                                                             AS rows_this_run_updates,
       COUNT_IF(d.COMP_NBR IS NULL)                                         AS not_active_in_dt,
       COUNT_IF(d.COMP_NBR IS NOT NULL AND s.WRITE_COMMENT
                AND d.COMP_COMMENTS_DESC IS DISTINCT FROM s.TO_COMMENT)     AS comment_differs,
       COUNT_IF(d.COMP_NBR IS NOT NULL AND s.WRITE_REMARKS
                AND d.COMMENTS_EXTENDED  IS DISTINCT FROM s.TO_REMARKS)     AS remarks_differ
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE s
LEFT JOIN DAAS_PROD.DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT d
  ON  d.COMP_NBR = s.COMP_NBR AND d.ISHDRW = s.ISHDRW AND d.PROPERTY_CD = s.PROPERTY_CD
  AND d.CASINO_OUTLET_CD = s.CASINO_OUTLET_CD AND d.DELETE_IND = 'N'
WHERE s.IN_THIS_RUN;


/* ---------------------------------------------------------------------
   STEP 9   Pete   HIS OWN LOOK BEFORE THE UPDATE
   STEPS 9, 10 and 11 go one after the other, without a pause, as one
   user.
   --------------------------------------------------------------------- */
-- 9a. Both streams still read 0 and 0. If either is above 0, stop: something has loaded since
--     STEP 4. Those are real changes and trips has to take them first (the EXECUTE TASK line in
--     STEP 4). Then this again.
SELECT 'COMP_DOMAIN' AS STREAM, COUNT(*) AS ROWS_WAITING
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_COMP_DOMAIN_STREAM
UNION ALL
SELECT 'FP_DOMAIN', COUNT(*)
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_FP_DOMAIN_STREAM;

-- 9b. The rows the UPDATE will change. It must equal ROWS_THIS_RUN_UPDATES of STEP 7, and it
--     shows that this role can read the list. If it answers "does not exist or not authorized",
--     the list's owner (DAAS_TEAM) grants the read:
--   GRANT SELECT ON TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE TO ROLE <this role>;
SELECT COUNT(*) AS rows_to_update
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE
WHERE IN_THIS_RUN;


/* ---------------------------------------------------------------------
   STEP 10   Pete   THE UPDATE
   One statement, one transaction. "number of rows updated" must equal
   9b. It finds each row by its own key and changes it only if it is
   still active and still reads what the list saw, so it cannot touch a
   row that has moved in between. Run a second time it changes nothing.
   Use a Large. Run it once.
   --------------------------------------------------------------------- */
UPDATE DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT f
SET COMP_COMMENTS_DESC = s.TO_COMMENT,
    COMMENTS_EXTENDED  = s.TO_REMARKS,
    UPDATED_DTTM       = CURRENT_TIMESTAMP,
    UPDATED_BY         = CURRENT_USER,
    LAST_DML_CD        = 'U'
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE s
WHERE f.COMP_DETAIL_FACT_SK = s.COMP_DETAIL_FACT_SK
  AND s.IN_THIS_RUN
  AND f.DELETE_IND = 'N'
  AND f.COMP_COMMENTS_DESC IS NOT DISTINCT FROM s.OLD_COMMENT
  AND f.COMMENTS_EXTENDED  IS NOT DISTINCT FROM s.OLD_REMARKS;


/* ---------------------------------------------------------------------
   STEP 11   Pete   THE STREAMS ARE EMPTIED, IF THEY HOLD ONLY THE UPDATE
   One statement, run by the user who ran STEP 10. It looks at both
   streams first and empties them only if every change waiting in them
   is an update written by that user, which is the UPDATE of STEP 10 and
   nothing else. (A stream shows an updated row as a pair, the row before
   and the row after, both marked as an update. The row after carries
   UPDATED_BY.) Emptying is Snowflake's own way of moving a stream past
   what it holds: a statement that reads the stream and keeps nothing.
   The stream, its owner and its grants stay as they are.
   It answers one of two things:
     EMPTIED ...       with the number of updated rows that were waiting
                       in each stream: the number STEP 10 reported.
     NOT EMPTIED ...   something else wrote to the comp table during the
                       window. Nothing was emptied. Go on to STEPS 12 and
                       13: trips takes everything on its next run (the
                       updated comps too: more work for trips, nothing
                       lost).
   It can take a few minutes: a stream compares the table before and
   after. (Any schema where this role can create a temporary table will
   do in place of DAAS_TEMP_WORK.)
   --------------------------------------------------------------------- */
-- 11a. Look, and empty only if the look is clean. One statement: run all of it, from EXECUTE to $$;
EXECUTE IMMEDIATE $$
DECLARE
    updated_comp_domain NUMBER;
    other_comp_domain   NUMBER;
    updated_fp_domain   NUMBER;
    other_fp_domain     NUMBER;
BEGIN
    SELECT COALESCE(COUNT_IF(METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE AND UPDATED_BY = CURRENT_USER()), 0),
           COALESCE(COUNT_IF(NOT METADATA$ISUPDATE
                             OR (METADATA$ACTION = 'INSERT' AND UPDATED_BY IS DISTINCT FROM CURRENT_USER())), 0)
      INTO :updated_comp_domain, :other_comp_domain
      FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_COMP_DOMAIN_STREAM;

    SELECT COALESCE(COUNT_IF(METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE AND UPDATED_BY = CURRENT_USER()), 0),
           COALESCE(COUNT_IF(NOT METADATA$ISUPDATE
                             OR (METADATA$ACTION = 'INSERT' AND UPDATED_BY IS DISTINCT FROM CURRENT_USER())), 0)
      INTO :updated_fp_domain, :other_fp_domain
      FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_FP_DOMAIN_STREAM;

    IF (other_comp_domain > 0 OR other_fp_domain > 0) THEN
        RETURN 'NOT EMPTIED. Changes waiting that are not this UPDATE: COMP_DOMAIN '
               || other_comp_domain::VARCHAR || ', FP_DOMAIN ' || other_fp_domain::VARCHAR
               || '. Nothing was emptied.';
    END IF;

    CREATE OR REPLACE TEMPORARY TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UNUSED_COMP_DOMAIN AS
    SELECT * FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_COMP_DOMAIN_STREAM WHERE 1 = 0;

    CREATE OR REPLACE TEMPORARY TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UNUSED_FP_DOMAIN AS
    SELECT * FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_FP_DOMAIN_STREAM WHERE 1 = 0;

    RETURN 'EMPTIED. Updated rows that were waiting: COMP_DOMAIN '
           || updated_comp_domain::VARCHAR || ', FP_DOMAIN ' || updated_fp_domain::VARCHAR || '.';
END;
$$;

-- 11b. After EMPTIED: both streams read 0 and 0 again.
SELECT 'COMP_DOMAIN' AS STREAM, COUNT(*) AS ROWS_WAITING
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_COMP_DOMAIN_STREAM
UNION ALL
SELECT 'FP_DOMAIN', COUNT(*)
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_FP_DOMAIN_STREAM;

--   Only if 11a fails with an error (not one of its two answers): the same by hand. These lines
--   have no check built in. They empty whatever a stream holds, under any role that can read it.
--   So first the two looks, where the second number must be 0 in both, then the two statements.
--   SELECT COUNT(*), COUNT_IF(NOT METADATA$ISUPDATE) FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_COMP_DOMAIN_STREAM;
--   SELECT COUNT(*), COUNT_IF(NOT METADATA$ISUPDATE) FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_FP_DOMAIN_STREAM;
--   CREATE OR REPLACE TEMPORARY TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UNUSED_COMP_DOMAIN AS SELECT * FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_COMP_DOMAIN_STREAM WHERE 1 = 0;
--   CREATE OR REPLACE TEMPORARY TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UNUSED_FP_DOMAIN AS SELECT * FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT_FP_DOMAIN_STREAM WHERE 1 = 0;


/* ---------------------------------------------------------------------
   STEP 12   Chris   THE AFTER-CHECKS (all of them before any resume)
   --------------------------------------------------------------------- */
-- 12a. Every comp of the run now reads what the list says. ROWS_THIS_RUN_UPDATES as in STEP 7,
--      and the other three 0.
SELECT COUNT(*)                                                       AS rows_this_run_updates,
       COUNT_IF(f.COMP_DETAIL_FACT_SK IS NULL)                        AS row_not_found,
       COUNT_IF(f.COMP_COMMENTS_DESC IS DISTINCT FROM s.TO_COMMENT)   AS comment_wrong,
       COUNT_IF(f.COMMENTS_EXTENDED  IS DISTINCT FROM s.TO_REMARKS)   AS remarks_wrong
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE s
LEFT JOIN DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT f
  ON f.COMP_DETAIL_FACT_SK = s.COMP_DETAIL_FACT_SK
WHERE s.IN_THIS_RUN;

-- 12b. Nothing else moved. The whole comp table against the backup, over every column except
--      the five the UPDATE writes. Two rows with the same two numbers: not one other value
--      changed, in any row. Use a Large. (As DAAS_TEAM the masked employee columns read as their
--      mask on both sides. For those the proof is the UPDATE itself, which does not name them.)
SELECT '1. the fact now' AS what, COUNT(*) AS rows_,
       HASH_AGG(* EXCLUDE (COMP_COMMENTS_DESC, COMMENTS_EXTENDED, UPDATED_DTTM, UPDATED_BY, LAST_DML_CD)) AS every_other_column
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT
UNION ALL
SELECT '2. the backup', COUNT(*),
       HASH_AGG(* EXCLUDE (COMP_COMMENTS_DESC, COMMENTS_EXTENDED, UPDATED_DTTM, UPDATED_BY, LAST_DML_CD))
FROM DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY;

-- 12c. The text moved only where it was meant to, and no comment was replaced with nothing. This
--      reads the comp table against the backup, not the list: the first two numbers are equal,
--      and equal to STEP 7's count, and COMMENTS_BLANKED is 0.
SELECT COUNT(*)                                                                    AS rows_whose_text_changed,
       COUNT_IF(s.IN_THIS_RUN)                                                     AS of_them_in_this_run,
       COUNT_IF(NULLIF(TRIM(REPLACE(b.COMP_COMMENTS_DESC, '|', '')), '') IS NOT NULL
                AND NULLIF(TRIM(REPLACE(f.COMP_COMMENTS_DESC, '|', '')), '') IS NULL) AS comments_blanked
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT f
JOIN DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY b
  ON b.COMP_DETAIL_FACT_SK = f.COMP_DETAIL_FACT_SK
LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE s
  ON s.COMP_DETAIL_FACT_SK = f.COMP_DETAIL_FACT_SK
WHERE f.COMP_COMMENTS_DESC IS DISTINCT FROM b.COMP_COMMENTS_DESC
   OR f.COMMENTS_EXTENDED  IS DISTINCT FROM b.COMMENTS_EXTENDED;

-- 12d. The examples from DAASI-3640. Tracy's two UTU comps now carry remarks: 7009616 remarks
--      that start "$95 BASED ON PLAY", and 4369229 remarks that start "$80 BASED ON LOSS". The
--      merge case 7613391 (UTU, issued 2022-12-11) keeps its comment. Her five from 10/4 are not
--      touched by this run and read as they did before it. Comment text can name people: this
--      result is not for the ticket.
SELECT COMP_NBR, PROPERTY_CD, GUEST_ID, ISSUE_DT, COMP_COMMENTS_DESC, COMMENTS_EXTENDED, UPDATED_DTTM, UPDATED_BY
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT
WHERE DELETE_IND = 'N'
  AND ((PROPERTY_CD = 'UTU' AND COMP_NBR IN (7009616, 4369229, 7613391))
       OR (PROPERTY_CD, COMP_NBR) IN (('GBI', 2884740), ('CLV', 5901079), ('UBA', 3254281),
                                      ('LUS', 1905058), ('NOR', 7762024)))
ORDER BY PROPERTY_CD, COMP_NBR, ISSUE_DT;


/* ---------------------------------------------------------------------
   STEP 13   Pete (or Chris for the comp load)   THE WINDOW CLOSES: RESUME
   Only after STEP 12. Trips first, then the comp load, then any load
   that was suspended in STEP 3.
   --------------------------------------------------------------------- */
ALTER TASK DAAS_PROD.DAAS_COMMON.TRIP_ROOT_TASK RESUME;

ALTER TASK DAAS_PROD.DAAS_COMMON.RAW2CORE_HETCMS_COMP_DETAIL_FACT_TASK RESUME;

--   Only if it was suspended in STEP 3:
--   ALTER TASK DAAS_PROD.<schema>.<the Hexlite comp load task> RESUME;


/* ---------------------------------------------------------------------
   STEP 14   Chris   BOTH TASKS ARE STARTED AND THE LOAD LOADS
   --------------------------------------------------------------------- */
-- 14a. "state" reads started in both. (No row means this role cannot see the task, and Pete
--      confirms it.)
SHOW TASKS LIKE 'RAW2CORE_HETCMS_COMP_DETAIL_FACT_TASK' IN SCHEMA DAAS_PROD.DAAS_COMMON;

SHOW TASKS LIKE 'TRIP_ROOT_TASK' IN DATABASE DAAS_PROD;

-- 14b. Ten minutes later: the load's runs since the resume, all SUCCEEDED (or SKIPPED when there
--      was nothing to load). The first one carries the window's backlog and takes longer.
SELECT state, scheduled_time,
       DATEDIFF(second, query_start_time, completed_time) AS seconds,
       error_message
FROM TABLE(DAAS_PROD.INFORMATION_SCHEMA.TASK_HISTORY(
         TASK_NAME => 'RAW2CORE_HETCMS_COMP_DETAIL_FACT_TASK',
         SCHEDULED_TIME_RANGE_START => DATEADD(hour, -2, CURRENT_TIMESTAMP()),
         RESULT_LIMIT => 30))
ORDER BY scheduled_time DESC;

-- 14c. Everything written to the comp table since the backup. One line by the user who ran the
--      UPDATE (HETCMS, U), then the load's own lines (SYSTEM, I and U) once it has run.
SELECT SOURCE_SYSTEM_NM, UPDATED_BY, LAST_DML_CD,
       COUNT(*)          AS rows_,
       MIN(UPDATED_DTTM) AS first_change,
       MAX(UPDATED_DTTM) AS last_change
FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT
WHERE UPDATED_DTTM > (SELECT MAX(UPDATED_DTTM)
                      FROM DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY)
GROUP BY 1, 2, 3
ORDER BY rows_ DESC;


/* ---------------------------------------------------------------------
   UNDO (only if needed, and for the role that ran the UPDATE)
   Puts the five columns back from the backup on the rows the UPDATE
   changed, and only where they still read what the UPDATE wrote, so
   nothing the load has done since is undone. It is a mass update too:
   the same window, STEPS 2 to 4 before it and STEP 13 after it. It puts
   the old UPDATED_BY back, so STEP 11 would answer NOT EMPTIED after it:
   the streams are emptied with the by-hand lines of STEP 11, or trips
   takes the rows.
   ---------------------------------------------------------------------
UPDATE DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT f
SET COMP_COMMENTS_DESC = b.COMP_COMMENTS_DESC,
    COMMENTS_EXTENDED  = b.COMMENTS_EXTENDED,
    UPDATED_DTTM       = b.UPDATED_DTTM,
    UPDATED_BY         = b.UPDATED_BY,
    LAST_DML_CD        = b.LAST_DML_CD
FROM DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY b
JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE s
  ON s.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK
WHERE f.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK
  AND s.IN_THIS_RUN
  AND f.COMP_COMMENTS_DESC IS NOT DISTINCT FROM s.TO_COMMENT
  AND f.COMMENTS_EXTENDED  IS NOT DISTINCT FROM s.TO_REMARKS;
   --------------------------------------------------------------------- */


/* ---------------------------------------------------------------------
   CLEAN-UP (nothing here is part of the run)
   The backup taken on 11/11 is out of date and protects nothing. It can
   go at any time:
     DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_UPD;
   After the 90 days, the three work tables of this run:
     DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY;
     DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_KEY;
     DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_UPD_SCOPE;
   --------------------------------------------------------------------- */
