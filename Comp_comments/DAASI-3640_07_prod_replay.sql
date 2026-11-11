/* =====================================================================
   DAASI-3640 | Step 7 of 7: PROD replay, all affected comps in one go
   (rev 6, 11/11: the architect's UAT run through the proc did not happen, so the proc's final
   form goes to PROD unexecuted and the replay run untimed. Added for that: A7 (how long a run may
   take, the warehouse the proc really uses, the stream's mode), B5 (the v1.14 load checked against
   the answer key on the comps it has already loaded), a look at the stream after the bump (E2),
   what a failed run looks like (E4), and E's sizing note corrected. The bump is now in its own
   file, 07b, for the role that runs it, and commented out here. Nothing else in rev 5's statements
   changes, apart from one more column in A3's list.
   Earlier: rev 5 11/8 who runs what, E without EXECUTE TASK; rev 4 10/29 bridge rule in the answer
   key; rev 3 10/27 five-minute task, masked roles, purge-list gate)
   Same mechanism as the UAT test: build the answer key, bump
   REPLAY_COUNTER on the latest raw row of every comp whose comment or
   remarks will change, and let the scheduled load rebuild them with the
   v1.14 procs. The answer key doubles as the preview and the rollback.

   Before this file, in PROD: 01 (fact column), 03 and 04 (both procs,
   checked by A1), 05 (DT merged to main and deployed). The UAT run in 06
   passed on 10/26 (UTU March 2026, 49,455 comps): every comp that kept
   an active row came back with the expected comment and remarks, and
   the DT agreed row for row.

   What the UAT run taught, and this file now allows for:
     1. A replayed comp is rebuilt from its latest raw row in full, so
        anything the fact had not yet taken from raw comes along: a
        deletion (DELETE_IND), a guest change, and columns whose formula
        or source moved since the row was loaded (COMPOR_NAME, which
        comes from today's host master under today's formula). B3b
        previews the deletions and guest changes before the go; F4 and
        F8 measure the rest after.
     2. Cost. On a Small, the rebuild INSERT took 333 s for 49,455 comps
        and the MERGE 264 s. The MERGE cost is a near-full rewrite of the
        fact whatever the comp count (49,455 comps spread over a 250M-row
        table touched partitions holding 230M rows), so one run is
        cheaper than several. The INSERT's split between the fixed scans
        of raw and the per-comp work is not known yet; the query profile
        of that 333 s statement (its most expensive nodes) decides the
        PROD estimate, and until it is read, size for the worse case on
        the task's warehouse and run between two load windows that leave
        room.
     3. The proc leaves nothing half done: its four statements run in one
        transaction, and a failure before COMMIT rolls back and leaves
        the stream intact for the next run.

   HOW THE PROD LOAD ACTUALLY RUNS (from its own query history, 10/13 to
   10/27): the task fires about every five minutes, 260 to 290 runs a
   day, each 17 to 120 seconds (median 30) on a Small warehouse, with
   180,000 to 260,000 comps a day and up to 34,000 in one run. The
   time does not move with the comp count (runs of 9 comps and of
   33,869 both take about 30 seconds), so the cost is the fixed scans
   of raw, and the per-comp work is small. There is no daily window to
   fit into. The replay is therefore one controlled run: suspend the
   task, bump, resume, and watch the next five-minute fire (part E).

   WHO RUNS WHAT. Parts A, B, C and F read, or write only to
   DAAS_TEMP_WORK, and run as DAAS_TEAM. Two things need other roles:
     D, the bump: UPDATE on DAAS_RAW_HETCMS.CMPRW_RAW. A5 says whether
        DAAS_TEAM has it in PROD (it did in UAT); if not, Pete runs that
        one statement at the moment part E calls for it. The statement
        is in its own file, DAASI-3640_07b_the_bump.sql.
     E, the task: OPERATE on the load task, for SUSPEND and RESUME. That
        is the owner's role, or one statement from the owner beforehand,
        GRANT OPERATE ON TASK DAAS_COMMON.<task> TO ROLE DAAS_TEAM, and a
        REVOKE afterwards. With it, DAAS_TEAM suspends before the bump and
        resumes after, and the next five-minute fire is the run. No
        EXECUTE TASK: it needs the account-level EXECUTE TASK privilege on
        top of OPERATE, and RESUME does the same job five minutes later.
        The run happens under the task owner's role whoever resumes it,
        which is the point: DAAS_TEAM is under masking policies on the
        employee columns (authorizer and host codes, host names), and a
        rebuild run by hand under it writes the mask into the fact and
        matches every comp to one host record, which is what happened in
        UAT on 10/26. Nobody runs the proc's SQL by hand in PROD.
     Owner only, for the one run: the warehouse the proc runs on put on a
        Large, and the time limit on a run raised. A7 says which
        warehouse and what limits, part E says how. The run has never
        been timed.
   So Pete's part is the bump, the grant and the revoke, and the
   warehouse and time limit. The sequence on the day is part E.

   Work tables go in DAAS_TEMP_WORK; if PROD's scratch schema is named
   differently, find-and-replace it first.
   ===================================================================== */

USE DATABASE DAAS_PROD;


/* ---------------------------------------------------------------------
   A. PRE-FLIGHT (read-only). Every answer must be right before part B.
   --------------------------------------------------------------------- */

-- A1. Both procs carry v1.14 with the bridge match (all TRUE on both rows).
SELECT procedure_name,
       CONTAINS(procedure_definition, 'COMMENTS_EXTENDED')             AS has_remarks,
       CONTAINS(procedure_definition, 'SELECT DISTINCT R.CNUMRW, R.ISHDRW') AS has_ever_held_match,
       CONTAINS(procedure_definition, 'GUEST_XREF_BRIDGE_LKP')         AS has_bridge_match
FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES
WHERE deleted IS NULL
  AND procedure_catalog = 'DAAS_PROD'
  AND procedure_name LIKE 'HETCMS_COMP_DETAIL_FACT_LOAD_PROC%';

-- A2. The fact has the column (1).
SELECT COUNT(*) AS has_column
FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
WHERE table_schema = 'DAAS_CORE' AND table_name = 'COMP_DETAIL_FACT' AND column_name = 'COMMENTS_EXTENDED';

-- A3. The task: name, owner (the role the rebuild runs under), schedule,
--     warehouse, and ALLOW_OVERLAPPING_EXECUTION, which must be FALSE
--     (if TRUE, a scheduled run could start beside the replay run and
--     both would read the stream and recreate the TMP table under each
--     other). Part E suspends it around the replay either way.
SHOW TASKS IN DATABASE DAAS_PROD;
SELECT "name", "schema_name", "owner", "schedule", "state", "warehouse", "allow_overlapping_execution",
       LEFT("definition", 300) AS definition
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "definition" ILIKE '%HETCMS_COMP_DETAIL_FACT_LOAD_PROC%';

-- A4. The task's recent runs: cadence, duration, failures. Expect runs
--     every five minutes of 20 to 60 seconds.
SELECT name, state, scheduled_time, query_start_time, completed_time,
       DATEDIFF(second, query_start_time, completed_time) AS seconds, return_value, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(hour, -6, CURRENT_TIMESTAMP()),
                                            RESULT_LIMIT => 200))
WHERE name ILIKE '%COMP_DETAIL%'
ORDER BY scheduled_time DESC;

-- A5. Who can do each step.
SHOW GRANTS ON TABLE DAAS_PROD.DAAS_RAW_HETCMS.CMPRW_RAW;        -- a role with UPDATE runs part D
--  Then, with the task name from A3:
--  SHOW GRANTS ON TASK DAAS_PROD.DAAS_COMMON.<task name>;       -- a role with OPERATE runs part E
SELECT CURRENT_AVAILABLE_ROLES() AS roles_you_can_use;

-- A6. The purge list as it stands. B3b's second result shows which
--     delete programs the replay would apply; any program that belongs
--     here (an archive or clean-up job rather than a business deletion)
--     must be added BEFORE the bump, or the replay soft-deletes its comps.
SELECT * FROM DAAS_COMMON.PURGE_PROGRAM_NM_LKP ORDER BY SOURCE_SYSTEM_NM, PROPERTY_CD, PROGRAM_NM;

-- A7. Three things that decide whether the replay run goes through.
--     (a) How long one run may take. Two limits apply and the lower one wins: the task's own
--         (USER_TASK_TIMEOUT_MS, one hour unless someone changed it) and the statement limit of
--         the warehouse (STATEMENT_TIMEOUT_IN_SECONDS, two days unless someone lowered it). A
--         run that passes the limit is cancelled and rolled back, and the next fire starts the
--         whole replay again, so the limit has to be longer than the replay run. With the task
--         from A3, and the warehouses from A3 and from (b) below if they are not the same one:
--  SHOW PARAMETERS LIKE 'USER_TASK_TIMEOUT_MS' IN TASK DAAS_PROD.DAAS_COMMON.<task name>;
--  SHOW PARAMETERS LIKE 'STATEMENT_TIMEOUT_IN_SECONDS' IN WAREHOUSE <warehouse>;
--     (b) The warehouse the proc's statements really run on, its size, and the role they run
--         under (the task's owner). The proc switches to the warehouse named in its CALL (USE
--         WAREHOUSE), so that is the one to resize for the run, whatever the task's own
--         warehouse is. (Account usage, up to 45 minutes behind.)
SELECT role_name, warehouse_name, warehouse_size, COUNT(*) AS statements, MAX(start_time) AS latest
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE database_name = 'DAAS_PROD'
  AND query_tag LIKE '%HETCMS_COMP_DETAIL_FACT_LOAD_PROC'
  AND start_time > DATEADD(hour, -6, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3;
--     (c) The stream takes updates: "mode" must read DEFAULT. An APPEND_ONLY stream never sees a
--         change to an existing row, so it would not see the bump and the replay would do nothing.
SHOW STREAMS LIKE 'CMPRW_RAW_COMP_DETAIL_STREAM' IN SCHEMA DAAS_PROD.DAAS_RAW_HETCMS;


/* ---------------------------------------------------------------------
   B. BACKUP AND ANSWER KEY (nothing in the fact changes yet)
   --------------------------------------------------------------------- */

-- B1. Zero-copy backup. Plain CREATE so a rerun cannot overwrite it.
--     Keep for 90 days.
CREATE TABLE DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY
  CLONE DAAS_CORE.COMP_DETAIL_FACT;

-- B2. The answer key for every active HETCMS comp: what the fact holds
--     now and what v1.14 produces. Same rules as the procs (the DT form,
--     unscoped). Reads the bridge (251M rows): use a Large.
CREATE OR REPLACE TRANSIENT TABLE DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED AS
WITH comps AS (
    SELECT COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD, GUEST_ID, ISSUE_DT,
           COMP_COMMENTS_DESC AS OLD_COMMENT,
           COMMENTS_EXTENDED  AS OLD_REMARKS,
           UPDATED_DTTM       AS OLD_UPDATED_DTTM,
           BATCH_ID           AS OLD_BATCH_ID,
           MD5_CHECKSUM       AS OLD_MD5
    FROM DAAS_CORE.COMP_DETAIL_FACT
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
                  FROM DAAS_RAW_HETCMS.CMPRW_RAW) H
            JOIN (SELECT SYIDCM, "CMP#CM", CSEQCM, CMNTCM, PROPERTY_CODE,
                         OPERATION_DATE, OPERATION_SEQUENCE_NBR, CREATED_DATE
                  FROM DAAS_RAW_HETCMS.ECPCMPCM_RAW
                  QUALIFY ROW_NUMBER() OVER (PARTITION BY SYIDCM, "CMP#CM", CSEQCM, PROPERTY_CODE
                          ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1) L
              ON L.SYIDCM = H.SYIDRW AND L."CMP#CM" = H.CNUMRW AND L.PROPERTY_CODE = H.PROPERTY_CODE
            UNION ALL
            SELECT H.CNUMRW, H.ISHDRW, H.PROPERTY_CODE, L.CSEQCM, L.CMNTCM, 2 AS MATCH_RANK,
                   L.OPERATION_DATE, L.OPERATION_SEQUENCE_NBR, L.CREATED_DATE
            FROM (SELECT SYIDCM, "CMP#CM", CSEQCM, CMNTCM, PROPERTY_CODE,
                         OPERATION_DATE, OPERATION_SEQUENCE_NBR, CREATED_DATE,
                         MIN(OPERATION_DATE) OVER (PARTITION BY SYIDCM, "CMP#CM", CSEQCM, PROPERTY_CODE) AS FIRST_SEEN
                  FROM DAAS_RAW_HETCMS.ECPCMPCM_RAW
                  QUALIFY ROW_NUMBER() OVER (PARTITION BY SYIDCM, "CMP#CM", CSEQCM, PROPERTY_CODE
                          ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1) L
            JOIN (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW
                  FROM (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW,
                               MIN(OPERATION_DATE) OVER (PARTITION BY CNUMRW, ISHDRW, PROPERTY_CODE) AS FIRST_SEEN
                        FROM DAAS_RAW_HETCMS.CMPRW_RAW)
                  WHERE FIRST_SEEN::DATE > DATEADD(DAY, 1, DECODE(ISHDRW, 0, '1899-12-31'::DATE, ISHDRW + '1899-12-31'::DATE))
                  GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW) H
              ON L."CMP#CM" = H.CNUMRW AND L.PROPERTY_CODE = H.PROPERTY_CODE
            JOIN (SELECT PROPERTY_CD, MIN(PROPERTY_ID)::VARCHAR AS PROPERTY_ID
                  FROM DAAS_CORE.PROPERTY_DIM GROUP BY PROPERTY_CD) P
              ON P.PROPERTY_CD = H.PROPERTY_CODE
            JOIN DAAS_CORE.GUEST_XREF_BRIDGE_LKP BL
              ON BL.XREF_ACCOUNT_NBR = P.PROPERTY_ID || LPAD(L.SYIDCM::VARCHAR, 8, '0')
            JOIN DAAS_CORE.GUEST_XREF_BRIDGE_LKP BH
              ON BH.XREF_ACCOUNT_NBR = P.PROPERTY_ID || LPAD(H.SYIDRW::VARCHAR, 8, '0')
             AND BH.PRIMARY_ACCOUNT_NBR = BL.PRIMARY_ACCOUNT_NBR
            WHERE NOT EXISTS (SELECT 1 FROM DAAS_RAW_HETCMS.CMPRW_RAW N
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
                    FROM DAAS_RAW_HETCMS.CMPRW_RAW
                    GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE)) C
        JOIN DAAS_RAW_HETCMS.CMPRM_RAW R
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

-- B3. The preview: what the replay changes. These are the numbers for
--     Pete and for Tracy. Expect comment removals near 6.5 million and
--     comps with remarks near 1.17 million.
SELECT COUNT(*)                                                               AS active_comps,
       COUNT_IF(WILL_CHANGE)                                                  AS comps_to_replay,
       COUNT_IF(NEW_COMMENT IS NULL     AND OLD_COMMENT IS NOT NULL)          AS comment_removed,
       COUNT_IF(NEW_COMMENT IS NOT NULL AND OLD_COMMENT IS NOT NULL
                AND NEW_COMMENT <> OLD_COMMENT)                               AS comment_replaced,
       COUNT_IF(NEW_COMMENT IS NOT NULL AND OLD_COMMENT IS NULL)              AS comment_added,
       COUNT_IF(NEW_REMARKS IS NOT NULL)                                      AS comps_with_remarks,
       COUNT_IF(NEW_REMARKS IS NOT NULL AND OLD_COMMENT IS NULL
                AND NEW_COMMENT IS NULL)                                      AS remarks_where_no_comment_at_all
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED;

-- B4. The raw rows to replay: the latest version of each comp that changes.
CREATE OR REPLACE TRANSIENT TABLE DAAS_TEMP_WORK.DAASI3640_RP_SLICE AS
SELECT CNUMRW, ISHDRW, COTLRW, PROPERTY_CODE, OPERATION_DATE, OPERATION_SEQUENCE_NBR, CREATED_DATE
FROM DAAS_RAW_HETCMS.CMPRW_RAW
WHERE (CNUMRW, ISHDRW, PROPERTY_CODE, COTLRW) IN
      (SELECT COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD
       FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED
       WHERE WILL_CHANGE)
QUALIFY ROW_NUMBER() OVER (PARTITION BY CNUMRW, ISHDRW, COTLRW, PROPERTY_CODE
        ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1;

SELECT COUNT(*) AS raw_rows_to_bump FROM DAAS_TEMP_WORK.DAASI3640_RP_SLICE;   -- should equal COMPS_TO_REPLAY

-- B3b. THE GATE. The rebuild takes DELETE_IND from the comp's latest raw
--      row, and the daily load has not been applying deletions since the
--      April 2024 full rebuild (DELETE_IND is not in the checksum the
--      merge compares, so a delete row with unchanged business columns
--      is a no-op). 7c in file 12 counted 3,096,212 active PROD comps
--      whose latest raw row is a delete by a program outside the purge
--      list: QQUSTRQRY 1.8M in 2025 alone, IWAOIT 1.04M across three
--      years, HCGC2000 190k, CMG0010 69k. The replay applies the rule to
--      every comp it touches, so each of those in the replay set is
--      soft-deleted and leaves the report. Whether that is a correction
--      (real voids, stuck) or a regression (archive jobs that belong on
--      PURGE_PROGRAM_NM_LKP next to CMG0009C) is a business answer per
--      program, and nothing is bumped until it is given and the list is
--      updated. This counts the overlap and shows it by program.
CREATE OR REPLACE TRANSIENT TABLE DAAS_TEMP_WORK.DAASI3640_RP_LATEST AS
SELECT s.CNUMRW, s.ISHDRW, s.COTLRW, s.PROPERTY_CODE,
       r.OPERATION_TYPE, TRIM(r.PROGRAM_NAME) AS program, r.OPERATION_DATE, r.SYIDRW,
       CASE WHEN TRIM(r.PROGRAM_NAME) = 'QRYO04' AND r.OPERATION_TYPE IN (0, 5, 8) THEN 'N'
            WHEN p.PROGRAM_NM IS NOT NULL                                           THEN 'N'
            WHEN r.OPERATION_TYPE IN (0, 5, 8)                                      THEN 'Y'
            ELSE 'N' END                                                            AS rule_delete_ind
FROM DAAS_TEMP_WORK.DAASI3640_RP_SLICE s
JOIN DAAS_RAW_HETCMS.CMPRW_RAW r
  ON  r.CNUMRW = s.CNUMRW AND r.ISHDRW = s.ISHDRW AND r.COTLRW = s.COTLRW AND r.PROPERTY_CODE = s.PROPERTY_CODE
  AND r.OPERATION_DATE = s.OPERATION_DATE AND r.OPERATION_SEQUENCE_NBR = s.OPERATION_SEQUENCE_NBR
  AND r.CREATED_DATE IS NOT DISTINCT FROM s.CREATED_DATE
LEFT JOIN DAAS_COMMON.PURGE_PROGRAM_NM_LKP p
  ON  r.SOURCE_SYSTEM_NAME = p.SOURCE_SYSTEM_NM AND r.PROPERTY_CODE = p.PROPERTY_CD
  AND UPPER(TRIM(r.PROGRAM_NAME)) = UPPER(TRIM(p.PROGRAM_NM));

SELECT COUNT(*)                                                             AS comps_to_replay,
       COUNT_IF(l.rule_delete_ind = 'Y')                                    AS will_be_soft_deleted,
       COUNT_IF(l.SYIDRW <> e.GUEST_ID)                                     AS guest_differs,
       COUNT_IF(l.rule_delete_ind = 'Y' AND e.NEW_COMMENT IS NOT NULL)      AS soft_deleted_with_comment,
       COUNT_IF(l.rule_delete_ind = 'Y' AND e.NEW_REMARKS IS NOT NULL)      AS soft_deleted_with_remarks
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
JOIN DAAS_TEMP_WORK.DAASI3640_RP_LATEST l
  ON  l.CNUMRW = e.COMP_NBR AND l.ISHDRW = e.ISHDRW AND l.COTLRW = e.CASINO_OUTLET_CD AND l.PROPERTY_CODE = e.PROPERTY_CD
WHERE e.WILL_CHANGE;

--      The soft-deletions by property, program and month, so the shape is
--      visible: a few programs and recent months is the normal trickle
--      between two loads; a long tail of old dates means the PROD fact
--      has been missing deletions, which is its own finding.
SELECT e.PROPERTY_CD, l.OPERATION_TYPE, l.program,
       DATE_TRUNC('month', l.OPERATION_DATE)::DATE AS deletion_month,
       COUNT(*)                                    AS comps
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
JOIN DAAS_TEMP_WORK.DAASI3640_RP_LATEST l
  ON  l.CNUMRW = e.COMP_NBR AND l.ISHDRW = e.ISHDRW AND l.COTLRW = e.CASINO_OUTLET_CD AND l.PROPERTY_CODE = e.PROPERTY_CD
WHERE e.WILL_CHANGE AND l.rule_delete_ind = 'Y'
GROUP BY 1, 2, 3, 4
ORDER BY comps DESC
LIMIT 100;

-- B5. The v1.14 load, checked before the replay on the comps it has already loaded. Since the
--     deploy the scheduled load has been running the v1.14 procedure every five minutes on the
--     day's comps, under its own role. The column arrived with that procedure, so every remark
--     in the fact was written by it: the earliest row carrying one marks its first load, and
--     every active row written since has been through it. For those comps the fact should
--     already say what the answer key says. This is F1b ahead of time, on a sample that costs
--     nothing: both DIFFER counts should be 0, or a handful (a line that reached raw after its
--     comp was last loaded). If they are a visible share of the two KEY_HAS counts, stop: the
--     procedure and the answer key disagree, and the replay would spread that over every comp
--     it touches. COMPS_LOADED_BY_V114 = 0 means the load has not written a comp with remarks
--     yet: give it a few runs, rebuild B2, and look again.
SELECT MIN(t.FIRST_V114_ROW)                                    AS first_v114_row,
       COUNT(e.COMP_NBR)                                        AS comps_loaded_by_v114,
       COUNT_IF(e.NEW_COMMENT IS NOT NULL)                      AS key_has_comment,
       COUNT_IF(e.NEW_COMMENT IS DISTINCT FROM e.OLD_COMMENT)   AS comments_differ,
       COUNT_IF(e.NEW_REMARKS IS NOT NULL)                      AS key_has_remarks,
       COUNT_IF(e.NEW_REMARKS IS DISTINCT FROM e.OLD_REMARKS)   AS remarks_differ
FROM (SELECT MIN(OLD_UPDATED_DTTM) AS FIRST_V114_ROW
      FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED
      WHERE OLD_REMARKS IS NOT NULL) t
LEFT JOIN DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
  ON e.OLD_UPDATED_DTTM >= t.FIRST_V114_ROW;

--      The differences themselves, if B5 shows any (comment text can name people: not for the ticket).
SELECT e.PROPERTY_CD, e.COMP_NBR, e.ISSUE_DT, e.OLD_UPDATED_DTTM AS FACT_ROW_WRITTEN,
       e.OLD_COMMENT AS FACT_COMMENT, e.NEW_COMMENT AS KEY_COMMENT,
       e.OLD_REMARKS AS FACT_REMARKS, e.NEW_REMARKS AS KEY_REMARKS
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
WHERE e.WILL_CHANGE
  AND e.OLD_UPDATED_DTTM >= (SELECT MIN(OLD_UPDATED_DTTM)
                             FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED
                             WHERE OLD_REMARKS IS NOT NULL)
ORDER BY e.OLD_UPDATED_DTTM DESC
LIMIT 50;


/* ---------------------------------------------------------------------
   C. GO / NO-GO
   Go when: A1 and A2 are right; A3 shows overlapping execution off;
   A7 is read (the stream's mode is DEFAULT, and the owner knows the
   time limit and the warehouse to set for the run);
   B3 is in the expected neighbourhood; B5's two DIFFER counts are 0 or
   a handful; 23's two purge-list rows are in
   PURGE_PROGRAM_NM_LKP (A6), with B3b rerun afterwards and its counts
   accepted by Pete; the role for D is in the room and DAAS_TEAM has
   OPERATE on the task (or its owner is in the room); the owners of
   DAAS_STRATEGIC_ANALYTICS_USER_PROD and of the raw ingestion
   (OpenFlow/HVR) have had their heads-up; the task is suspended (E1)
   and its last run has completed:
   --------------------------------------------------------------------- */
SELECT SYSTEM$STREAM_HAS_DATA('DAAS_RAW_HETCMS.CMPRW_RAW_COMP_DETAIL_STREAM') AS has_data;   -- want FALSE, or only the trickle since the last run
SELECT COUNT(*) AS rows_waiting FROM DAAS_RAW_HETCMS.CMPRW_RAW_COMP_DETAIL_STREAM;


/* ---------------------------------------------------------------------
   D. THE BUMP (E2 in the sequence): one UPDATE on the raw comp table,
   as the role from A5, after E1. Adds 1 to REPLAY_COUNTER on the latest version of each affected comp.
   No business column changes. One statement, one transaction, so the
   stream sees all of it or none. Rewrites most of the raw table's
   partitions; the ingestion only inserts, so it waits rather than
   conflicts, but its owners should know the minute it runs.
   The statement to run is in DAASI-3640_07b_the_bump.sql, for the role
   that runs it. Below is the same statement for reference, commented
   out so that it cannot be run in passing from this file.
   --------------------------------------------------------------------- */
--  UPDATE DAAS_RAW_HETCMS.CMPRW_RAW R
--  SET REPLAY_COUNTER = COALESCE(R.REPLAY_COUNTER, 0) + 1
--  FROM DAAS_TEMP_WORK.DAASI3640_RP_SLICE S
--  WHERE R.CNUMRW                 = S.CNUMRW
--    AND R.ISHDRW                 = S.ISHDRW
--    AND R.COTLRW                 = S.COTLRW
--    AND R.PROPERTY_CODE          = S.PROPERTY_CODE
--    AND R.OPERATION_DATE         = S.OPERATION_DATE
--    AND R.OPERATION_SEQUENCE_NBR = S.OPERATION_SEQUENCE_NBR
--    AND R.CREATED_DATE IS NOT DISTINCT FROM S.CREATED_DATE;

-- "number of rows updated" should equal RAW_ROWS_TO_BUMP.


/* ---------------------------------------------------------------------
   E. THE RUN, in order
   E1  ALTER TASK DAAS_COMMON.<task name from A3> SUSPEND;
       (DAAS_TEAM with OPERATE, or the owner.) Then A4 until the latest
       run shows SUCCEEDED and none EXECUTING: the schedule is stopped
       and nothing is reading the stream. While it is suspended, the
       owner makes the two settings for the run (Sizing, below).
   E2  Part D, the bump (file 07b), by the role from A5. "rows updated"
       should equal RAW_ROWS_TO_BUMP. Then the second query of part C
       again (it can take a few minutes now): the stream must hold the
       bump, about twice RAW_ROWS_TO_BUMP, because an update shows in a
       stream as a delete and an insert. If it holds only the usual
       trickle, the stream did not take the bump: resume the task and
       stop there, nothing in the fact has changed.
   E3  ALTER TASK DAAS_COMMON.<task name from A3> RESUME;
       The next fire, within five minutes, is the replay run: one call of
       the proc that drains the whole stream in one transaction. (EXECUTE
       TASK would start it at once but needs the account-level EXECUTE
       TASK privilege on top of OPERATE; RESUME needs OPERATE only.)
   E4  Watch with A4 until that run has ended. SUCCEEDED there is not
       yet the proof: the proc catches its own errors, rolls back and
       returns FAILURE, so a run can end as SUCCEEDED with nothing
       loaded. The proof is the stream: the second query of part C back
       down to the trickle means the replay was committed. If the run
       has ended and the stream still holds the bump, the run failed or
       was cancelled at a limit, and the next fire is already trying
       again: suspend the task, read the error (A4's ERROR_MESSAGE, the
       batch error log), raise the limit or the size, resume. Nothing is
       lost meanwhile, the stream keeps the bump until a run commits.
       Once the stream is back to the trickle: part F, and the owner
       puts the warehouse and the limits back.
   Sizing: the five-minute runs cost 30 seconds whatever their size,
   so the fixed scans are cheap; the replay adds the per-comp work for
   7.7 million comps (the stream join over most of raw's partitions,
   the lookups, the final window) and a merge that rewrites most of the
   fact, which the UAT merge did in 264 seconds for 49,455 comps on a
   Small. That is tens of minutes on a Small at best, and it has
   never been timed. A run is cancelled when it passes the lower of
   the two limits in A7 (a), one hour unless they say otherwise, and a
   cancelled run rolls back and starts over at the next fire, so a
   replay that needs longer than the limit never finishes. While the
   task is suspended (E1) its owner therefore makes the run faster and
   the limit longer, and reverses both after E4:
     ALTER WAREHOUSE <warehouse from A7 (b)> SET WAREHOUSE_SIZE = 'LARGE';
     ALTER TASK DAAS_COMMON.<task name> SET USER_TASK_TIMEOUT_MS = 14400000;
   (14400000 ms is four hours. If A7 (a) shows a warehouse statement
   limit below that, it needs raising for the day as well.) ALTER TASK
   ... SET WAREHOUSE does not help by itself: the proc switches to the
   warehouse named in its CALL.
   --------------------------------------------------------------------- */


/* ---------------------------------------------------------------------
   F. CHECK THE RESULT (after the load finishes)
   --------------------------------------------------------------------- */

-- F1. Fact against the answer key, over the comps that were replayed.
--     ROWS_REWRITTEN should equal COMPS less ACTIVE_ROW_MISSING, and
--     ACTIVE_ROW_MISSING should equal B3b's WILL_BE_SOFT_DELETED plus
--     GUEST_DIFFERS. Each missing comp also counts as a mismatch here
--     (no active row to compare), so the pass/fail for the text is F1b.
SELECT COUNT(*)                                                           AS comps,
       COUNT_IF(f.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT)      AS comment_mismatches,
       COUNT_IF(f.COMMENTS_EXTENDED  IS DISTINCT FROM e.NEW_REMARKS)      AS remark_mismatches,
       COUNT_IF(f.UPDATED_DTTM > e.OLD_UPDATED_DTTM)                      AS rows_rewritten,
       COUNT_IF(f.COMP_NBR IS NULL)                                       AS active_row_missing
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
LEFT JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_NBR         = e.COMP_NBR
  AND f.ISHDRW           = e.ISHDRW
  AND f.PROPERTY_CD      = e.PROPERTY_CD
  AND f.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD
  AND f.DELETE_IND       = 'N'
WHERE e.WILL_CHANGE;

-- F1b. The pass/fail for the text: the replayed comps that still have an
--      active row. Both mismatch counts must be 0.
SELECT COUNT(*)                                                           AS comps_with_active_row,
       COUNT_IF(f.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT)      AS comment_mismatches,
       COUNT_IF(f.COMMENTS_EXTENDED  IS DISTINCT FROM e.NEW_REMARKS)      AS remark_mismatches
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_NBR = e.COMP_NBR AND f.ISHDRW = e.ISHDRW AND f.PROPERTY_CD = e.PROPERTY_CD
  AND f.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND f.DELETE_IND = 'N'
WHERE e.WILL_CHANGE;

-- F1c. The replayed comps that lost their active row, matched to B3b's
--      prediction: every one should be a comp B3b flagged, and the
--      soft-deleted row should still carry the right text (the merge
--      writes the text and DELETE_IND in the same UPDATE). Both mismatch
--      counts 0; NOT_PREDICTED 0.
SELECT COUNT(*)                                                           AS lost_active_row,
       COUNT_IF(l.rule_delete_ind = 'N' AND l.SYIDRW = e.GUEST_ID)         AS not_predicted,
       COUNT_IF(f.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT)      AS comment_mismatches,
       COUNT_IF(f.COMMENTS_EXTENDED  IS DISTINCT FROM e.NEW_REMARKS)      AS remark_mismatches
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
JOIN DAAS_TEMP_WORK.DAASI3640_RP_LATEST l
  ON  l.CNUMRW = e.COMP_NBR AND l.ISHDRW = e.ISHDRW AND l.COTLRW = e.CASINO_OUTLET_CD AND l.PROPERTY_CODE = e.PROPERTY_CD
JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_NBR = e.COMP_NBR AND f.ISHDRW = e.ISHDRW AND f.PROPERTY_CD = e.PROPERTY_CD
  AND f.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND f.GUEST_ID = e.GUEST_ID AND f.DELETE_IND = 'Y'
WHERE e.WILL_CHANGE
  AND NOT EXISTS (SELECT 1 FROM DAAS_CORE.COMP_DETAIL_FACT a
                  WHERE a.COMP_NBR = e.COMP_NBR AND a.ISHDRW = e.ISHDRW AND a.PROPERTY_CD = e.PROPERTY_CD
                    AND a.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND a.DELETE_IND = 'N');

-- F2. And over the comps that were NOT replayed: nothing should have moved.
SELECT COUNT(*)                                                           AS comps,
       COUNT_IF(f.COMP_COMMENTS_DESC IS DISTINCT FROM e.OLD_COMMENT)      AS comment_moved,
       COUNT_IF(f.COMMENTS_EXTENDED  IS DISTINCT FROM e.OLD_REMARKS)      AS remarks_moved
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_NBR = e.COMP_NBR AND f.ISHDRW = e.ISHDRW AND f.PROPERTY_CD = e.PROPERTY_CD
  AND f.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND f.DELETE_IND = 'N'
WHERE NOT e.WILL_CHANGE;

-- F3. The mismatches themselves, if F1 shows any.
SELECT e.COMP_NBR, e.PROPERTY_CD, e.GUEST_ID, e.ISSUE_DT,
       e.OLD_COMMENT, e.NEW_COMMENT AS EXPECTED_COMMENT, f.COMP_COMMENTS_DESC AS FACT_COMMENT,
       e.OLD_REMARKS, e.NEW_REMARKS AS EXPECTED_REMARKS, f.COMMENTS_EXTENDED  AS FACT_REMARKS
FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
LEFT JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_NBR = e.COMP_NBR AND f.ISHDRW = e.ISHDRW AND f.PROPERTY_CD = e.PROPERTY_CD
  AND f.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND f.DELETE_IND = 'N'
WHERE e.WILL_CHANGE
  AND (f.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT
       OR f.COMMENTS_EXTENDED IS DISTINCT FROM e.NEW_REMARKS)
LIMIT 100;

-- F4. Drift on the replayed comps against the backup: what else the
--     rebuild under today's logic moved. Information, not failure.
--     DELETE_IND_CHANGED should equal B3b's WILL_BE_SOFT_DELETED;
--     GUEST_CHANGED 0 (a guest change makes a new row rather than
--     changing this one). COMPOR_NAME_CHANGED can be large: the name is
--     rebuilt from today's host master under today's formula, and rows
--     loaded under an older formula take the new one (UAT: 49,442 of
--     49,503). F8 says what kind of change it is.
SELECT COUNT(*)                                                      AS comps,
       COUNT_IF(f.GUEST_ID          <> b.GUEST_ID)                    AS guest_changed,
       COUNT_IF(f.DELETE_IND        <> b.DELETE_IND)                  AS delete_ind_changed,
       COUNT_IF(f.COMP_CATEGORY     IS DISTINCT FROM b.COMP_CATEGORY) AS comp_category_changed,
       COUNT_IF(f.COMPOR_NAME       IS DISTINCT FROM b.COMPOR_NAME)   AS compor_name_changed,
       COUNT_IF(f.ISSUE_COMP_WORTH_AMT IS DISTINCT FROM b.ISSUE_COMP_WORTH_AMT) AS worth_changed,
       COUNT_IF(f.REDEEM_DTTM       IS DISTINCT FROM b.REDEEM_DTTM)   AS redeem_dttm_changed
FROM DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY b
JOIN DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
  ON  e.COMP_NBR = b.COMP_NBR AND e.ISHDRW = b.ISHDRW AND e.PROPERTY_CD = b.PROPERTY_CD
  AND e.CASINO_OUTLET_CD = b.CASINO_OUTLET_CD AND e.WILL_CHANGE
JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK;

-- F8. What kind of change COMPOR_NAME took. Classes separate a formula
--     or spacing change (harmless) from a coverage change (names
--     appearing or vanishing) and from a different person (the host
--     record itself changed). EXAMPLE is one before -> after pair per
--     class; employee names, fine for Pete.
SELECT CASE WHEN b.COMPOR_NAME IS NULL AND f.COMPOR_NAME IS NOT NULL THEN 'blank, now a name'
            WHEN b.COMPOR_NAME IS NOT NULL AND f.COMPOR_NAME IS NULL THEN 'name, now blank'
            WHEN REGEXP_REPLACE(UPPER(b.COMPOR_NAME), '[^A-Z]', '')
               = REGEXP_REPLACE(UPPER(f.COMPOR_NAME), '[^A-Z]', '')      THEN 'same letters: spacing, case or digits'
            WHEN ARRAY_TO_STRING(ARRAY_SORT(SPLIT(UPPER(TRIM(b.COMPOR_NAME)), ' ')), ' ')
               = ARRAY_TO_STRING(ARRAY_SORT(SPLIT(UPPER(TRIM(f.COMPOR_NAME)), ' ')), ' ') THEN 'same words, new order'
            WHEN REGEXP_REPLACE(UPPER(b.COMPOR_NAME), '[^A-Z]', '') LIKE '%' || REGEXP_REPLACE(UPPER(f.COMPOR_NAME), '[^A-Z]', '') || '%'
              OR REGEXP_REPLACE(UPPER(f.COMPOR_NAME), '[^A-Z]', '') LIKE '%' || REGEXP_REPLACE(UPPER(b.COMPOR_NAME), '[^A-Z]', '') || '%'
                                                                        THEN 'one contains the other: a part dropped or added'
            ELSE 'different name' END                                   AS change_kind,
       COUNT(*)                                                         AS rows_,
       COUNT(DISTINCT b.COMPOR_NAME)                                    AS distinct_names_before,
       ANY_VALUE(COALESCE(b.COMPOR_NAME, '(blank)') || '  ->  ' || COALESCE(f.COMPOR_NAME, '(blank)')) AS example
FROM DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY b
JOIN DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
  ON  e.COMP_NBR = b.COMP_NBR AND e.ISHDRW = b.ISHDRW AND e.PROPERTY_CD = b.PROPERTY_CD
  AND e.CASINO_OUTLET_CD = b.CASINO_OUTLET_CD AND e.WILL_CHANGE
JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK
WHERE f.COMPOR_NAME IS DISTINCT FROM b.COMPOR_NAME
GROUP BY 1
ORDER BY rows_ DESC;

-- F5. Spot checks: Tracy's two UTU comps (expect "$95" with remarks
--     "$95 BASED ON PLAY|PER HUAIBI LI", and "$80" with
--     "$80 BASED ON LOSS 3/1|PER HUAIBI LI"), her five from 10/4 (comment
--     blank, remarks blank), and the merge case 7613391 UTU issued
--     2022-12-11 (comment "TP" kept).
SELECT COMP_NBR, PROPERTY_CD, GUEST_ID, ISSUE_DT, COMP_COMMENTS_DESC, COMMENTS_EXTENDED
FROM DAAS_CORE.COMP_DETAIL_FACT
WHERE DELETE_IND = 'N'
  AND ((PROPERTY_CD = 'UTU' AND COMP_NBR IN (7009616, 4369229, 7613391))
       OR (PROPERTY_CD, COMP_NBR) IN (('GBI', 2884740), ('CLV', 5901079), ('UBA', 3254281),
                                      ('LUS', 1905058), ('NOR', 7762024)))
ORDER BY PROPERTY_CD, COMP_NBR, ISSUE_DT;

-- F6. Runtime of the run, whole (A4) and by statement. The task ran
--     under its own role, so the statements are in the account usage
--     view (run as DAAS_SNOWFLAKE_ACCTUSAGE; up to 45 minutes behind).
--     ROWS_PRODUCED on the DML is partitions rewritten, not rows changed.
SELECT start_time, LEFT(LTRIM(query_text, ' \t\n\r'), 60) AS statement_start,
       warehouse_name, warehouse_size,
       ROUND(total_elapsed_time / 1000) AS seconds, rows_produced,
       ROUND(bytes_spilled_to_local_storage / POWER(1024, 3), 1) AS gb_spilled, execution_status
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE database_name = 'DAAS_PROD'
  AND query_tag LIKE '%HETCMS_COMP_DETAIL_FACT_LOAD_PROC'
  AND start_time > DATEADD(hour, -6, CURRENT_TIMESTAMP())
  AND query_type <> 'SELECT'
  AND (query_text ILIKE '%INSERT INTO DAAS_TEMP.COMP_DETAIL_FACT_TMP%'
       OR query_text ILIKE '%UPDATE DAAS_CORE.COMP_DETAIL_FACT%'
       OR query_text ILIKE '%MERGE INTO DAAS_CORE.COMP_DETAIL_FACT%')
ORDER BY start_time;


/* ---------------------------------------------------------------------
   G. ROLLBACK (only if needed; not part of the replay)
   Puts every replayed row back exactly as the backup clone holds it,
   all columns by surrogate key, and removes any row the replay inserted
   on a replayed key (a guest change). Everything the rebuild touched
   comes back: text, DELETE_IND, COMPOR_NAME, checksum, audit columns.
   Run it before the next load, since it restores the backup's state of
   those rows wholesale and a later load's changes to them would go too.
   G undoes the replay's rows and nothing else; the v1.14 procs, the
   column and the view can all stay, and G needs the column to be there.
   Going back to the v1.12 procs is a separate, bigger step, after G:
   v1.12 inserts 77 values by position into a work table built LIKE the
   fact, so it cannot run while the fact has 78 columns. In this order,
   with the task suspended throughout: the view back to its 2024 text
   if the new one is deployed (it reads the column; add COPY GRANTS),
   the column dropped (ALTER TABLE DAAS_CORE.COMP_DETAIL_FACT DROP
   COLUMN COMMENTS_EXTENDED), v1.12 redeployed with COPY GRANTS, and
   the DT from the previous main.
   RUN G AS A ROLE THE MASKING POLICIES EXEMPT. UPDATE ... SET col =
   b.col reads the backup through the policy, so a masked role would
   write the mask value into the employee columns.
   ---------------------------------------------------------------------
-- G1. Rows the replay inserted on replayed keys (new surrogate keys).
DELETE FROM DAAS_CORE.COMP_DETAIL_FACT
WHERE COMP_DETAIL_FACT_SK > (SELECT MAX(COMP_DETAIL_FACT_SK)
                             FROM DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY)
  AND (COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD) IN
      (SELECT COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD
       FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED WHERE WILL_CHANGE);

-- G2. Every column of every replayed row, back from the backup.
UPDATE DAAS_CORE.COMP_DETAIL_FACT f
SET
    GUEST_ID                                         = b.GUEST_ID,
    COMP_NBR                                         = b.COMP_NBR,
    CASINO_OUTLET_CD                                 = b.CASINO_OUTLET_CD,
    LIMIT_TYPE_CD                                    = b.LIMIT_TYPE_CD,
    AUTHORIZER_ID                                    = b.AUTHORIZER_ID,
    COMPOR_DEPARTMENT_CD                             = b.COMPOR_DEPARTMENT_CD,
    PROPERTY_CD                                      = b.PROPERTY_CD,
    REDEEM_AMT                                       = b.REDEEM_AMT,
    ISSUE_COMP_LIMIT_AMT                             = b.ISSUE_COMP_LIMIT_AMT,
    LIMIT_DESC                                       = b.LIMIT_DESC,
    LAST_CHANGE_ISSUE_DTTM                           = b.LAST_CHANGE_ISSUE_DTTM,
    PROPERTY_ID                                      = b.PROPERTY_ID,
    ISSUE_DT                                         = b.ISSUE_DT,
    SNAPSHOT_CMS_TRIP_WIN_LOSS_AMT                   = b.SNAPSHOT_CMS_TRIP_WIN_LOSS_AMT,
    SNAPSHOT_CMS_TRIP_COMP_WORTH                     = b.SNAPSHOT_CMS_TRIP_COMP_WORTH,
    SNAPSHOT_CMS_PROPERTY_COMP_WORTH                 = b.SNAPSHOT_CMS_PROPERTY_COMP_WORTH,
    SNAPSHOT_CMS_BRAND_COMP_WORTH                    = b.SNAPSHOT_CMS_BRAND_COMP_WORTH,
    COMP_AVERAGE_AMT                                 = b.COMP_AVERAGE_AMT,
    COMP_OVERAGE_PCT                                 = b.COMP_OVERAGE_PCT,
    COMPOR_AUTHOR_NBR                                = b.COMPOR_AUTHOR_NBR,
    STATUS_CD                                        = b.STATUS_CD,
    COMP_STATUS_CD                                   = b.COMP_STATUS_CD,
    LAST_CHANGE_DT                                   = b.LAST_CHANGE_DT,
    LAST_CHANGE_COMP_LIMIT_AMT                       = b.LAST_CHANGE_COMP_LIMIT_AMT,
    LAST_CHANGE_COMP_OVER_AMT                        = b.LAST_CHANGE_COMP_OVER_AMT,
    LAST_CHANGE_COMP_OVER_PCT                        = b.LAST_CHANGE_COMP_OVER_PCT,
    SNAPSHOT_CMS_COMP_WORTH_AVAILABLE_AMT            = b.SNAPSHOT_CMS_COMP_WORTH_AVAILABLE_AMT,
    SNAPSHOT_CMS_CURRENT_TRIP_THEO_AMT               = b.SNAPSHOT_CMS_CURRENT_TRIP_THEO_AMT,
    DISCRETIONARY_COMP_FLG                           = b.DISCRETIONARY_COMP_FLG,
    ISSUED_BY_CD                                     = b.ISSUED_BY_CD,
    COMP_TYPE_CD                                     = b.COMP_TYPE_CD,
    NUMBER_OF_PEOPLE_CNT                             = b.NUMBER_OF_PEOPLE_CNT,
    WINE_COMP_LIMIT_AMT                              = b.WINE_COMP_LIMIT_AMT,
    ISSUE_POINT_LIMIT_AMT                            = b.ISSUE_POINT_LIMIT_AMT,
    WINE_POINT_LIMIT_AMT                             = b.WINE_POINT_LIMIT_AMT,
    ISSUE_POINT_LIMIT                                = b.ISSUE_POINT_LIMIT,
    REDEEM_AUTHORIZATION_CD                          = b.REDEEM_AUTHORIZATION_CD,
    FOLIO_ID                                         = b.FOLIO_ID,
    EXTERNAL_TICKET_NBR                              = b.EXTERNAL_TICKET_NBR,
    REDEEM_POINT_AMT                                 = b.REDEEM_POINT_AMT,
    COMP_EXCEPTION_CD                                = b.COMP_EXCEPTION_CD,
    VOID_AUTHORIZATION_CD                            = b.VOID_AUTHORIZATION_CD,
    VOID_DTTM                                        = b.VOID_DTTM,
    CREATE_DTTM                                      = b.CREATE_DTTM,
    LAST_DTTM                                        = b.LAST_DTTM,
    NGC_EXTRACTION_PROCESSED_FLG                     = b.NGC_EXTRACTION_PROCESSED_FLG,
    ISS_REWARD_CREDIT_AMT                            = b.ISS_REWARD_CREDIT_AMT,
    ISS_REWARD_CREDIT_NBR                            = b.ISS_REWARD_CREDIT_NBR,
    USED_REWARD_CREDT_AMT                            = b.USED_REWARD_CREDT_AMT,
    USED_REWARD_CREDITS_NBR                          = b.USED_REWARD_CREDITS_NBR,
    PLAYER_DEVELOPMENT_FLG                           = b.PLAYER_DEVELOPMENT_FLG,
    SNAPSHOT_CMS_REWARD_CREDIT_BALANCE_AT_ISSUE_AMT  = b.SNAPSHOT_CMS_REWARD_CREDIT_BALANCE_AT_ISSUE_AMT,
    ISSUE_COMP_WORTH_AMT                             = b.ISSUE_COMP_WORTH_AMT,
    USED_COMP_WORTH_AMT                              = b.USED_COMP_WORTH_AMT,
    UNIQUE_REWARD_LINK_NBR                           = b.UNIQUE_REWARD_LINK_NBR,
    COMP_COMMENTS_DESC                               = b.COMP_COMMENTS_DESC,
    SOURCE_SYSTEM_NM                                 = b.SOURCE_SYSTEM_NM,
    TIME_ZONE                                        = b.TIME_ZONE,
    CREATED_DTTM                                     = b.CREATED_DTTM,
    CREATED_BY                                       = b.CREATED_BY,
    UPDATED_DTTM                                     = b.UPDATED_DTTM,
    UPDATED_BY                                       = b.UPDATED_BY,
    DELETE_IND                                       = b.DELETE_IND,
    BATCH_ID                                         = b.BATCH_ID,
    LAST_DML_CD                                      = b.LAST_DML_CD,
    OPERATION_SEQUENCE_NBR                           = b.OPERATION_SEQUENCE_NBR,
    MD5_CHECKSUM                                     = b.MD5_CHECKSUM,
    ISSUE_DTTM                                       = b.ISSUE_DTTM,
    REPLAY_COUNTER                                   = b.REPLAY_COUNTER,
    OUTLET_CATEGORY                                  = b.OUTLET_CATEGORY,
    COMPOR_NAME                                      = b.COMPOR_NAME,
    EMPLOYEE_FIRST_NM                                = b.EMPLOYEE_FIRST_NM,
    EMPLOYEE_LAST_NM                                 = b.EMPLOYEE_LAST_NM,
    COMP_CATEGORY                                    = b.COMP_CATEGORY,
    ISHDRW                                           = b.ISHDRW,
    REDEEM_DTTM                                      = b.REDEEM_DTTM,
    COMMENTS_EXTENDED                                = b.COMMENTS_EXTENDED
FROM DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_REPLAY b
WHERE f.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK
  AND (b.COMP_NBR, b.ISHDRW, b.PROPERTY_CD, b.CASINO_OUTLET_CD) IN
      (SELECT COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD
       FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED WHERE WILL_CHANGE);
--------------------------------------------------------------------- */
