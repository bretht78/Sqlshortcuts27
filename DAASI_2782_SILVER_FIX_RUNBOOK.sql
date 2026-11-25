/* ===========================================================================
   DAASI-2782: giving SYPCN a silver table, then pointing the view at it.
   Runbook. Version of 2026-11-25.

   HOW TO USE THIS FILE
     Work through the steps in order. Run one statement at a time.

     Every statement that can run in this file is read-only. Those are the
     checks.

     The statements that change something are written inside the comment
     boxes, under the word CHANGE, so they cannot run by accident. Whoever
     runs one copies it out of the box. They have no closing semicolon on
     purpose and run as they are.

   WHO DOES WHAT
     Steps 1, 2, 4, 5, 6 and 7   the developer on the ticket
     Step 3 (one statement)      Pete, or whoever runs as the role
                                 DAAS_OPENFLOW_INGESTION

   WHY THIS IS NEEDED
     The view deployed on 11/24 read the bucket names straight from the
     OpenFlow landing table (bronze), because SYPCN has no silver table.
     The view was put back to the original on 11/25 until SYPCN has one.
     This runbook builds that silver table. Then the six fields go back in.
=========================================================================== */


/* ===========================================================================
   HOW THE SILVER MERGE WORKS

   OpenFlow only delivers rows to the landing tables. A small set of
   Snowflake objects then moves new rows into the tables the views read.
   It was built as a bridge for the move from HVR to OpenFlow.

   OpenFlow table (bronze)
     DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW. Every change from the iSeries lands
     here as a new row. Nothing is cleaned up or removed.

   Stream
     A bookmark on the OpenFlow table. It remembers how far the merge has
     read and hands over only the rows that arrived since. It holds no data
     itself. Each table has one, named <TABLE>_OF2SILVER_STREAM.

   CREATE_DB2_SILVER_STREAMS (procedure)
     Creates a stream for every table in the mapped OpenFlow schemas that
     does not have one. It never touches a stream that exists. A stream it
     creates starts at the moment it is created, so rows already in the
     table are never handed over. That is why it is NOT used for SYPCN.

   Merge job: DB2_RUN_ALL_SILVER_MERGES (procedure)
     About every five minutes, going by the log, it goes through every
     table and asks its stream whether anything is new. If there is, it
     calls the load procedure for that table. It writes one line per table
     to the log.

   Load procedure: DB2_OPENFLOW2SILVER_LOAD_PROC
     Moves one table's new rows into silver. It has three rules.
       1. The silver table must already exist. It will not create one.
       2. It fills the silver table's columns by matching column names.
       3. The property gate. It inserts rows only for properties marked as
          cut over to OpenFlow in DB2_PROPERTY_CUTOVER. Rows for any other
          property are read from the stream and thrown away, because for an
          ordinary table HVR still loads them.

   Log: OPENFLOW_INGESTION.OPENFLOW_CONFIG.DB2_SILVER_MERGE_LOG
     One line per table per run. The outcomes are
       MISSING_STREAM      the table has no stream, so it was skipped
       SKIPPED_NO_DATA     the stream had nothing new
       OK rows_inserted=N  N rows were moved into silver
       ERROR               something failed. The stream is left untouched,
                           so the next run tries again by itself.

   WHY SYPCN IS STUCK
     SYPCN is a new table. Nobody created its stream, so the merge job has
     logged MISSING_STREAM for it on every run since 11/17. It has no silver
     table either. And its rows landed before any stream existed, so its
     stream has to be created with SHOW_INITIAL_ROWS, the option that starts
     the bookmark at the beginning of the table.
=========================================================================== */


/* ---------------------------------------------------------------------------
   STEP 1. Check that nothing changed since 11/25.            Read-only

   1a. The property gate.
       The load procedure only inserts rows for properties marked as cut
       over (see rule 3). This applies the same test to the rows now in the
       OpenFlow table.

       ROWS_IN_OPENFLOW   rows the property has in the OpenFlow table
       TABLEINFO_ROWS     how many of them are TABLEINFO rows, which hold
                          the bucket names the view needs
       REACHES_SILVER     YES, or NO: WOULD BE DROPPED

       Expected: YES on every row (22 rows on 11/25: the 20 properties the
       view uses, plus AKC and TGV). Any NO rows are listed first.

       If a property the view uses says NO, stop here. Do NOT fix it by
       changing CONVERT_FLAG. That flag covers every HETCMS table for the
       property, so it would start a second feed into all of them while HVR
       is still loading them.
--------------------------------------------------------------------------- */
SELECT
    S.SOURCE_SYSTEM_NAME,
    S.PROPERTY_CODE,
    S.ROWS_IN_OPENFLOW,
    S.TABLEINFO_ROWS,
    IFF(COUNT(C.CONVERT_FLAG) > 0, 'YES', 'NO: WOULD BE DROPPED')  AS REACHES_SILVER
FROM
(
    SELECT SOURCE_SYSTEM_NAME,
           PROPERTY_CODE,
           COUNT(*)                                    AS ROWS_IN_OPENFLOW,
           SUM(IFF(TRIM(MDLECN) = 'TABLEINFO', 1, 0))  AS TABLEINFO_ROWS
    FROM DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW
    GROUP BY 1, 2
) S
LEFT JOIN OPENFLOW_INGESTION.OPENFLOW_CONFIG.DB2_PROPERTY_CUTOVER C
       ON  C.CONVERT_FLAG = 'Y'
       AND C.SOURCE_SYSTEM_NAME = S.SOURCE_SYSTEM_NAME
       AND (C.ENTERPRISE_FLAG = 'Y' OR C.PROPERTY_CODE = S.PROPERTY_CODE)
GROUP BY 1, 2, 3, 4
ORDER BY 5, 2;


/* ---------------------------------------------------------------------------
   1b. What the merge job has logged for SYPCN.

       Expected before the fix: one row, MISSING_STREAM. That means nobody
       has created the stream yet.

       If any other outcome is listed, the stream already exists. Read the
       note IF THE STREAM ALREADY EXISTS at the end of this file before
       going on.
--------------------------------------------------------------------------- */
SELECT
    OUTCOME,
    ROWS_INSERTED,
    COUNT(*)        AS RUNS
FROM OPENFLOW_INGESTION.OPENFLOW_CONFIG.DB2_SILVER_MERGE_LOG
WHERE TABLE_NAME = 'SYPCN_RAW'
GROUP BY 1, 2
ORDER BY 3;


/* ---------------------------------------------------------------------------
   STEP 2. Create the silver table.                  Repo deploy, UAT then Prod

   Deploy the file SYPCN_RAW.sql through the usual flow: a branch cut from
   uat_main for the UAT deploy, then a branch cut from main for Prod.

   The file creates DAAS_RAW_HETCMS.SYPCN_RAW with the same 67 columns as
   the OpenFlow table, so the load procedure carries every column across
   (rule 2). The table starts empty. Deploying the file does not load it.

   It has to exist before the stream is created (rule 1).

   The check below is read-only.
   Expected after both deploys: 67 for DAAS_UAT and 67 for DAAS_PROD.
   A 0 means the table is not there yet.
--------------------------------------------------------------------------- */
SELECT 'DAAS_UAT'   AS DATABASE_NAME,
       COUNT(*)     AS COLUMN_COUNT
FROM DAAS_UAT.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DAAS_RAW_HETCMS'
  AND TABLE_NAME   = 'SYPCN_RAW'
UNION ALL
SELECT 'DAAS_PROD',
       COUNT(*)
FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DAAS_RAW_HETCMS'
  AND TABLE_NAME   = 'SYPCN_RAW';


/* ---------------------------------------------------------------------------
   STEP 3. Create the stream.                                    CHANGE (Prod)

   Run by Pete, or whoever runs as DAAS_OPENFLOW_INGESTION.
   Only after step 2 shows 67 for DAAS_PROD.

   CHANGE: copy the four lines below and run them.

     CREATE STREAM DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW_OF2SILVER_STREAM
       ON TABLE DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW
       APPEND_ONLY = TRUE
       SHOW_INITIAL_ROWS = TRUE

   This one statement is the whole ingestion. No snapshot loads are run
   again and CREATE_DB2_SILVER_STREAMS is not used.

   Why each part matters
     The name            The merge job looks for exactly this name.
     APPEND_ONLY         The same setting as the other streams the merge
                         uses. The stream reports new rows only.
     SHOW_INITIAL_ROWS   On its first read the stream also hands over the
                         rows already in the table. Without it, silver would
                         only ever get rows that land from now on, and the
                         bucket names loaded on 11/19 to 11/22 would never
                         arrive.
     The role            The merge job has to see and read the stream, so it
                         is created by the role that owns the other streams.

   What happens next, with nobody doing anything
     On its next run the merge job finds the stream, sees it has rows, and
     calls the load procedure. All rows in the OpenFlow table (about 58,700
     on 11/25) are copied into DAAS_RAW_HETCMS.SYPCN_RAW. From then on every
     new row follows within about five minutes.

   If the statement fails with an error saying the stream already exists,
   do not run anything else. Read the note IF THE STREAM ALREADY EXISTS at
   the end of this file.
--------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   STEP 4. Confirm the load.                                       Read-only

   Wait for one or two runs of the merge job (five to ten minutes), then
   run the query below. It is the same query as 1b.

   Expected
     One row starting with OK, whose ROWS_INSERTED is the number of rows
     that were in the OpenFlow table (about 58,700). It is listed first.
     Then SKIPPED_NO_DATA, with RUNS growing every five minutes.
     The MISSING_STREAM row stays in the log as history.

   If instead you see
     ERROR               Read the message in OUTCOME. The usual causes are
                         the silver table missing in Prod, or the ingestion
                         role not being allowed to insert into it. Fix the
                         cause. The stream is untouched, so the next run
                         loads the rows by itself.
     Only SKIPPED_NO_DATA, and no OK row
                         The merge job did not count the rows already in the
                         table as new. Pete runs the load procedure once by
                         hand. The statement is in the note TOOLS FOR PETE
                         at the end of this file.
     Still only MISSING_STREAM
                         The merge job cannot see the stream. It was most
                         likely created under another role.
--------------------------------------------------------------------------- */
SELECT
    OUTCOME,
    ROWS_INSERTED,
    COUNT(*)        AS RUNS
FROM OPENFLOW_INGESTION.OPENFLOW_CONFIG.DB2_SILVER_MERGE_LOG
WHERE TABLE_NAME = 'SYPCN_RAW'
GROUP BY 1, 2
ORDER BY 3;


/* ---------------------------------------------------------------------------
   STEP 5. Compare silver with the OpenFlow table.                  Read-only

   One row per property.

   OPENFLOW_ROWS, SILVER_ROWS     rows the property has in each table
   OPENFLOW_NAMES, SILVER_NAMES   the four bucket names from the property's
                                  latest TABLEINFO record, read the same way
                                  the view reads them, in the order
                                  bucket 04 | 01 | 03 | 05

   Expected: RESULT is MATCH on every row. Any CHECK rows are listed first.

   A CHECK where SILVER_ROWS is a few rows behind can simply be a change
   that landed in the last five minutes. Run the query again after the next
   merge run before treating it as a problem.

   Do not go on to step 6 until the 20 properties the view uses all say
   MATCH. A property missing from silver would not make the view fail. The
   view would quietly fall back to the standard bucket names for it.
--------------------------------------------------------------------------- */
WITH OPENFLOW_ROWS AS
(
    SELECT PROPERTY_CODE,
           COUNT(*)      AS ROW_COUNT
    FROM DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW
    GROUP BY 1
),
SILVER_ROWS AS
(
    SELECT PROPERTY_CODE,
           COUNT(*)      AS ROW_COUNT
    FROM DAAS_PROD.DAAS_RAW_HETCMS.SYPCN_RAW
    GROUP BY 1
),
OPENFLOW_NAMES AS
(
    SELECT PROPERTY_CODE,
           UPPER(TRIM(CDD1CN)) || ' | ' || UPPER(TRIM(CDD2CN)) || ' | ' ||
           UPPER(TRIM(CDD3CN)) || ' | ' || UPPER(TRIM(CDD4CN))  AS BUCKET_NAMES
    FROM DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW
    WHERE TRIM(MDLECN) = 'TABLEINFO'
      AND TRIM(MTYPCN) = 'CTL'
      AND MSEQCN = 0
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE
                                    ORDER BY CREATED_DATE DESC NULLS LAST, OPERATION_DATE DESC NULLS LAST, OPERATION_SEQUENCE_NBR DESC NULLS LAST) = 1
),
SILVER_NAMES AS
(
    SELECT PROPERTY_CODE,
           UPPER(TRIM(CDD1CN)) || ' | ' || UPPER(TRIM(CDD2CN)) || ' | ' ||
           UPPER(TRIM(CDD3CN)) || ' | ' || UPPER(TRIM(CDD4CN))  AS BUCKET_NAMES
    FROM DAAS_PROD.DAAS_RAW_HETCMS.SYPCN_RAW
    WHERE TRIM(MDLECN) = 'TABLEINFO'
      AND TRIM(MTYPCN) = 'CTL'
      AND MSEQCN = 0
    QUALIFY ROW_NUMBER () OVER (PARTITION BY PROPERTY_CODE
                                    ORDER BY CREATED_DATE DESC NULLS LAST, OPERATION_DATE DESC NULLS LAST, OPERATION_SEQUENCE_NBR DESC NULLS LAST) = 1
)
SELECT
    O.PROPERTY_CODE,
    O.ROW_COUNT                 AS OPENFLOW_ROWS,
    NVL(S.ROW_COUNT, 0)         AS SILVER_ROWS,
    N1.BUCKET_NAMES             AS OPENFLOW_NAMES,
    N2.BUCKET_NAMES             AS SILVER_NAMES,
    IFF(O.ROW_COUNT = NVL(S.ROW_COUNT, 0)
        AND NVL(N1.BUCKET_NAMES, '-') = NVL(N2.BUCKET_NAMES, '-'),
        'MATCH', 'CHECK')       AS RESULT
FROM OPENFLOW_ROWS  O
LEFT JOIN SILVER_ROWS     S  ON S.PROPERTY_CODE  = O.PROPERTY_CODE
LEFT JOIN OPENFLOW_NAMES  N1 ON N1.PROPERTY_CODE = O.PROPERTY_CODE
LEFT JOIN SILVER_NAMES    N2 ON N2.PROPERTY_CODE = O.PROPERTY_CODE
ORDER BY 6, 1;


/* ---------------------------------------------------------------------------
   STEP 6. Change the view.                              One line, in the repo

   Start from the view file that was deployed on 11/24 (the one with the six
   fields). In the TABLE_INFO step, one line changes.

     Before   FROM DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW
     After    FROM DAAS_RAW_HETCMS.SYPCN_RAW

   Nothing else in the view changes. CMPTS_RAW and CMPTST_RAW were already
   read from the silver schema. SYPCN was the only table read from bronze.

   The UAT test version of the view changes the same way in its comment
   only. UAT still has no table game data of its own, so the test version
   keeps reading the three copies in DAAS_UAT.DAAS_TEMP_WORK.

   Optional, so that UAT tests the rows Prod will read: rebuild the SYPCN
   copy in UAT from the silver table.

   CHANGE (UAT): copy the six lines below and run them.

     CREATE OR REPLACE TRANSIENT TABLE
       DAAS_UAT.DAAS_TEMP_WORK.SYPCN_RAW_DAASI_2782
       COPY GRANTS AS
     SELECT *
     FROM DAAS_PROD.DAAS_RAW_HETCMS.SYPCN_RAW
     WHERE TRIM(MDLECN) = 'TABLEINFO'
--------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   STEP 7. Deploy the view again and validate.               UAT, then Prod

   The same route and the same validations as 11/23 and 11/24.

     UAT    deploy the UAT test version, then run the UAT validation file
     Prod   before the deploy: the dry run, and the before side of the
            existing-columns check and the dependent-views check
            after the deploy: the three Prod validation queries

   The validation files that carry a copy of the view's SQL (the dry run)
   have to be rebuilt with the new line from step 6 before they are used.

   When Prod is validated, the six fields are back. Anyone who was told on
   11/25 that the fields were withdrawn can be told they have returned.
--------------------------------------------------------------------------- */


/* ===========================================================================
   NOTES

   THINGS NOT TO DO
     Do not run CREATE_DB2_SILVER_STREAMS to create SYPCN's stream. Its
     streams start empty (see HOW THE SILVER MERGE WORKS).
     On 11/25 one other table was waiting for a stream, CMPMGRXP_RAW. If
     that procedure is run for it before step 3, it creates SYPCN's stream
     too. Then follow IF THE STREAM ALREADY EXISTS.
     Do not change CONVERT_FLAG in DB2_PROPERTY_CUTOVER to get a property
     through the gate (see step 1a).
     Do not drop the three DAASI_2782 tables in DAAS_UAT.DAAS_TEMP_WORK. The
     UAT test version of the view reads them.

   IF THE STREAM ALREADY EXISTS
     This applies when step 1b lists an outcome other than MISSING_STREAM,
     or step 3 fails because the stream is already there. That stream was
     created without SHOW_INITIAL_ROWS, so it does not hold the rows that
     were already in the table.

     Do this before the view reads the silver table, never after.

     1. Make sure the silver table exists in Prod (step 2).
     2. Pete empties the silver table if it has any rows, so that nothing
        is loaded twice.

        CHANGE (Prod):

          TRUNCATE TABLE DAAS_PROD.DAAS_RAW_HETCMS.SYPCN_RAW

     3. Pete replaces the stream with one that starts at the beginning.

        CHANGE (Prod):

          CREATE OR REPLACE STREAM
            DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW_OF2SILVER_STREAM
            ON TABLE DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW
            APPEND_ONLY = TRUE
            SHOW_INITIAL_ROWS = TRUE

     4. Carry on from step 4.

     Run 2 and 3 one right after the other. If a merge run slips in between
     them, a few rows can be loaded twice. Step 5 shows that as CHECK, with
     SILVER_ROWS higher than OPENFLOW_ROWS, and repeating 2 and 3 clears it.

   TOOLS FOR PETE
     Both statements call the load procedure directly for SYPCN.

     Preview. Returns the INSERT the load procedure would run and does not
     touch the stream. It needs the silver table to exist. It also saves
     the column list in the cache table, which is harmless.

     CALL OPENFLOW_INGESTION.OPENFLOW_PROCEDURES.DB2_OPENFLOW2SILVER_LOAD_PROC(
         'DAAS_PROD', 'DAAS_RAW_HETCMS_OPENFLOW',
         'DAAS_PROD', 'DAAS_RAW_HETCMS',
         'SYPCN_RAW',
         'DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW_OF2SILVER_STREAM',
         NULL, TRUE)

     Load by hand. Only for the case in step 4 where the log shows
     SKIPPED_NO_DATA and no OK row. It does what the merge job would have
     done for this one table.

        CHANGE (Prod):

     CALL OPENFLOW_INGESTION.OPENFLOW_PROCEDURES.DB2_OPENFLOW2SILVER_LOAD_PROC(
         'DAAS_PROD', 'DAAS_RAW_HETCMS_OPENFLOW',
         'DAAS_PROD', 'DAAS_RAW_HETCMS',
         'SYPCN_RAW',
         'DAAS_PROD.DAAS_RAW_HETCMS_OPENFLOW.SYPCN_RAW_OF2SILVER_STREAM')
=========================================================================== */
