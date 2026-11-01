/* =====================================================================
   DAASI-3640 | Validations that the comp fact fix works
   (rev 3, 11/1: V5a added, the bridge rule checked in the dynamic
   table, which needs no architect run; V0 says when that table is ready)
   UAT, read-only, any role (the text columns are not masked). Each
   returns one row ending in RESULT = PASS or FAIL, with the numbers
   that decide it.

   What each one needs, and so when it can run:
     V1, V2, V4  the fact as it stands. They passed on 10/28 against the
                 10/26 rebuild (v1.14) and do not need 14. After 14 they
                 must still pass; V4's host_name_pending_rerun then
                 drops to about 0.
     V3          the dynamic table refreshed. After 05 deploys, the table
                 is replaced and holds no rows until its first scheduled
                 refresh (within a day): V0 says when. Under the v1.15
                 table it must still pass against the v1.14 fact, since
                 the March slice has no bridge comps (16 C2).
     V5a         05 deployed and refreshed (V0), and 17 steps 1, 2 and 4.
                 Not 14. This is the v1.15 rule running as deployed code,
                 under the table's own role, on the rescue list.
     V5          17 and 14: the same comps, written by the proc itself.

   Reference tables, all built before the rebuilds:
     DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_UATREPLAY  the fact as it was (clone)
     DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED                     what CMS says each comp's
                                                              comment and remarks should be
     DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED                 the rescue list with its
                                                              answer key (17)
   ===================================================================== */

USE DATABASE DAAS_UAT;


/* ---------------------------------------------------------------------
   V0. IS THE DYNAMIC TABLE READY
   Not a validation; the gate for V3 and V5a. The deploy replaces the
   table with initialize = ON_SCHEDULE, so it is empty until its first
   refresh, within its one-day lag. Ready when is_v115 is TRUE and
   refreshed_since_deploy is TRUE. If the second stays FALSE past a day
   the refresh is failing, most likely because the owner role lacks
   SELECT on GUEST_XREF_BRIDGE_LKP or PROPERTY_DIM (16 C3); the second
   query shows the message, if your role can see the refresh history.
   --------------------------------------------------------------------- */
SHOW DYNAMIC TABLES LIKE 'COMP_DETAIL_FACT_DT' IN SCHEMA DAAS_UAT.DAAS_CORE_GAMING;
SELECT "name", "created_on", "data_timestamp", "scheduling_state", "target_lag",
       CONTAINS("text", 'GUEST_XREF_BRIDGE_LKP')                 AS is_v115,
       COALESCE("data_timestamp" > "created_on", FALSE)          AS refreshed_since_deploy
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT state, state_message, refresh_action, refresh_start_time, refresh_end_time
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME => 'DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT'))
ORDER BY refresh_start_time DESC
LIMIT 5;


/* ---------------------------------------------------------------------
   V1. THE MISSING TEXT IS NOW LOADED, AND IT IS CMS'S TEXT
   The ticket: hosts type the reason for a comp into the CMS "remarks"
   screen, which the fact never loaded, so the report showed a bare
   amount or nothing. PASS when: no comp had remarks before; every comp
   that has remarks in CMS has them in the fact now, identical; and
   every remark line the fact shows exists in CMS under that comp's
   number (a check that does not depend on the matching rule at all).
   Expect: 49,455 | 0 | 1,465 | 1,465 | 0 | 0 | PASS
   --------------------------------------------------------------------- */
WITH fact_lines AS (
    SELECT f.COMP_NBR, f.PROPERTY_CD, TRIM(x.VALUE::VARCHAR) AS line
    FROM DAAS_CORE.COMP_DETAIL_FACT f,
         LATERAL FLATTEN(INPUT => SPLIT(f.COMMENTS_EXTENDED, '|')) x
    WHERE f.DELETE_IND = 'N' AND f.SOURCE_SYSTEM_NM = 'HETCMS'
      AND f.PROPERTY_CD = 'UTU' AND f.ISSUE_DT BETWEEN '2026-03-01' AND '2026-03-31'
      AND f.COMMENTS_EXTENDED IS NOT NULL
),
cms_lines AS (
    SELECT DISTINCT CNUMRM, PROPERTY_CODE, TRIM(EXPLRM) AS line
    FROM DAAS_RAW_HETCMS.CMPRM_RAW
    WHERE PROPERTY_CODE = 'UTU'
),
lines_check AS (
    SELECT COUNT(*) AS lines_in_fact,
           COUNT_IF(c.line IS NULL) AS lines_not_found_in_cms
    FROM fact_lines fl
    LEFT JOIN cms_lines c ON c.CNUMRM = fl.COMP_NBR AND c.PROPERTY_CODE = fl.PROPERTY_CD AND c.line = fl.line
),
comps_check AS (
    SELECT COUNT(*)                                                    AS comps,
           COUNT_IF(b.COMMENTS_EXTENDED IS NOT NULL)                    AS had_remarks_before,
           COUNT_IF(e.NEW_REMARKS IS NOT NULL)                          AS have_remarks_in_cms,
           COUNT_IF(f.COMMENTS_EXTENDED IS NOT NULL)                    AS have_remarks_now,
           COUNT_IF(f.COMMENTS_EXTENDED IS DISTINCT FROM e.NEW_REMARKS) AS differ_from_cms
    FROM DAAS_TEMP_WORK.DAASI3640_RP_EXPECTED e
    JOIN DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_UATREPLAY b
      ON  b.COMP_NBR = e.COMP_NBR AND b.ISHDRW = e.ISHDRW AND b.PROPERTY_CD = e.PROPERTY_CD
      AND b.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND b.GUEST_ID = e.GUEST_ID AND b.DELETE_IND = 'N'
    JOIN DAAS_CORE.COMP_DETAIL_FACT f
      ON  f.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK
)
SELECT 'V1 remarks loaded' AS check_,
       comps, had_remarks_before, have_remarks_in_cms, have_remarks_now, differ_from_cms,
       lines_not_found_in_cms,
       IFF(had_remarks_before = 0 AND have_remarks_now = have_remarks_in_cms
           AND differ_from_cms = 0 AND lines_not_found_in_cms = 0, 'PASS', 'FAIL') AS result
FROM comps_check, lines_check;

--  V1, seen: ten comps the report showed as a bare amount, with the
--  reason the host had typed next to it. (Host names appear in the text.)
SELECT f.COMP_NBR, f.ISSUE_DT,
       b.COMP_COMMENTS_DESC AS report_showed_before,
       f.COMMENTS_EXTENDED  AS reason_now_available
FROM DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_UATREPLAY b
JOIN DAAS_CORE.COMP_DETAIL_FACT f ON f.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK
WHERE b.DELETE_IND = 'N' AND b.PROPERTY_CD = 'UTU' AND b.ISSUE_DT BETWEEN '2026-03-01' AND '2026-03-31'
  AND REGEXP_LIKE(b.COMP_COMMENTS_DESC, '^\\$?[0-9][0-9.,]*\\.?$')
  AND f.COMMENTS_EXTENDED IS NOT NULL
  AND LENGTH(f.COMMENTS_EXTENDED) > LENGTH(b.COMP_COMMENTS_DESC) + 5
ORDER BY f.ISSUE_DT
LIMIT 10;


/* ---------------------------------------------------------------------
   V2. NO COMP SHOWS ANOTHER GUEST'S NOTE
   CMS reuses comp numbers, and the old load matched comments by number,
   so a comp could show a note written years earlier for a different
   guest's comp on the same number. This counts, from the raw tables
   alone, the comps whose number carries comment lines written under a
   guest who never held that comp, and how many of those comps show
   such a line in the fact. PASS when the second number is 0.
   Expect: 49,246 | 17,406 | 0 | PASS
   (The same query with USE DATABASE DAAS_PROD gives the before picture:
   16,780 of 49,455 on 10/27.) Under v1.15 a line can also belong to a
   comp through the bridge, as the same person's; this slice has no
   such comp (16 C2 = 0), so the count here needs no allowance for it.
   V5a and V5 cover the comps that do.
   --------------------------------------------------------------------- */
WITH slice AS (
    SELECT COMP_NBR, ISHDRW, PROPERTY_CD, COMP_COMMENTS_DESC
    FROM DAAS_CORE.COMP_DETAIL_FACT
    WHERE DELETE_IND = 'N' AND SOURCE_SYSTEM_NM = 'HETCMS'
      AND PROPERTY_CD = 'UTU' AND ISSUE_DT BETWEEN '2026-03-01' AND '2026-03-31'
),
holders AS (     -- every guest who ever held each comp
    SELECT DISTINCT CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW
    FROM DAAS_RAW_HETCMS.CMPRW_RAW
    WHERE PROPERTY_CODE = 'UTU' AND CNUMRW IN (SELECT COMP_NBR FROM slice)
),
lines AS (       -- latest version of every comment line on these numbers, with the guest it was written under
    SELECT "CMP#CM" AS CNUMRW, PROPERTY_CODE, SYIDCM, CSEQCM, CMNTCM
    FROM DAAS_RAW_HETCMS.ECPCMPCM_RAW
    WHERE PROPERTY_CODE = 'UTU' AND "CMP#CM" IN (SELECT COMP_NBR FROM slice)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SYIDCM, "CMP#CM", CSEQCM, PROPERTY_CODE
            ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1
),
own_lines AS (   -- lines under a holder of the comp
    SELECT DISTINCT s.COMP_NBR, s.ISHDRW, l.CMNTCM
    FROM slice s
    JOIN lines l   ON l.CNUMRW = s.COMP_NBR AND l.PROPERTY_CODE = s.PROPERTY_CD
    JOIN holders h ON h.CNUMRW = s.COMP_NBR AND h.ISHDRW = s.ISHDRW AND h.PROPERTY_CODE = s.PROPERTY_CD AND h.SYIDRW = l.SYIDCM
),
foreign_lines AS (   -- lines under someone who never held the comp, and not also written by a holder
    SELECT DISTINCT s.COMP_NBR, s.ISHDRW, l.CMNTCM
    FROM slice s
    JOIN lines l ON l.CNUMRW = s.COMP_NBR AND l.PROPERTY_CODE = s.PROPERTY_CD
    WHERE NOT EXISTS (SELECT 1 FROM holders h
                      WHERE h.CNUMRW = s.COMP_NBR AND h.ISHDRW = s.ISHDRW AND h.PROPERTY_CODE = s.PROPERTY_CD AND h.SYIDRW = l.SYIDCM)
      AND NOT EXISTS (SELECT 1 FROM own_lines o
                      WHERE o.COMP_NBR = s.COMP_NBR AND o.ISHDRW = s.ISHDRW AND o.CMNTCM = l.CMNTCM)
),
fact_lines AS (  -- the comment the fact shows, one row per line
    SELECT s.COMP_NBR, s.ISHDRW, x.VALUE::VARCHAR AS line
    FROM slice s, LATERAL FLATTEN(INPUT => SPLIT(s.COMP_COMMENTS_DESC, '|')) x
    WHERE s.COMP_COMMENTS_DESC IS NOT NULL
),
showing AS (
    SELECT COUNT(DISTINCT fl.COMP_NBR || '-' || fl.ISHDRW) AS comps_showing_another_guests_line
    FROM fact_lines fl
    JOIN foreign_lines fo ON fo.COMP_NBR = fl.COMP_NBR AND fo.ISHDRW = fl.ISHDRW AND fo.CMNTCM = fl.line
)
SELECT 'V2 no borrowed comments' AS check_,
       (SELECT COUNT(*) FROM slice)                                         AS comps,
       (SELECT COUNT(DISTINCT COMP_NBR || '-' || ISHDRW) FROM foreign_lines) AS comps_exposed_to_reuse,
       comps_showing_another_guests_line,
       IFF(comps_showing_another_guests_line = 0, 'PASS', 'FAIL')           AS result
FROM showing;


/* ---------------------------------------------------------------------
   V3. TWO INDEPENDENT BUILDS AGREE
   The dynamic table DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT rebuilds from
   the raw tables with its own copy of the logic, under its own role,
   with no reference to the fact. The fact was rebuilt by the load's
   statements. If both read CMS the same way, they agree on every comp.
   PASS when no comp differs on comment or remarks. Needs V0 ready.
   Expect: 49,246 | 0 | 0 | 0 | PASS
   --------------------------------------------------------------------- */
SELECT 'V3 fact = dynamic table' AS check_,
       COUNT(*)                                                             AS comps,
       COUNT_IF(d.COMP_NBR IS NULL)                                         AS missing_in_dt,
       COUNT_IF(d.COMP_COMMENTS_DESC IS DISTINCT FROM f.COMP_COMMENTS_DESC) AS comment_differs,
       COUNT_IF(d.COMMENTS_EXTENDED  IS DISTINCT FROM f.COMMENTS_EXTENDED)  AS remarks_differ,
       IFF(COUNT_IF(d.COMP_NBR IS NULL) = 0
           AND COUNT_IF(d.COMP_COMMENTS_DESC IS DISTINCT FROM f.COMP_COMMENTS_DESC) = 0
           AND COUNT_IF(d.COMMENTS_EXTENDED  IS DISTINCT FROM f.COMMENTS_EXTENDED)  = 0, 'PASS', 'FAIL') AS result
FROM DAAS_CORE.COMP_DETAIL_FACT f
LEFT JOIN DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT d
  ON  d.COMP_NBR = f.COMP_NBR AND d.ISHDRW = f.ISHDRW AND d.PROPERTY_CD = f.PROPERTY_CD
  AND d.CASINO_OUTLET_CD = f.CASINO_OUTLET_CD AND d.DELETE_IND = 'N'
WHERE f.DELETE_IND = 'N' AND f.SOURCE_SYSTEM_NM = 'HETCMS'
  AND f.PROPERTY_CD = 'UTU' AND f.ISSUE_DT BETWEEN '2026-03-01' AND '2026-03-31';


/* ---------------------------------------------------------------------
   V4. NOTHING ELSE ON THE COMP MOVED
   Every rebuilt row against its own backup copy, by surrogate key, on
   the columns the fix must not touch: guest, dates, amounts, status,
   category, outlet. PASS when all are 0 across all 49,455 rows.
   Expect: 49,455 | 0 0 0 0 0 0 0 0 0 | PASS
   Reported alongside, not part of the pass: DELETE_IND moved on 209
   rows, which are comps CMS deleted in March that the UAT load had
   never applied (the rebuild applied them); and the host-name columns,
   which the 10/26 run wrote under a masked role and the architect's
   rerun (file 14) corrects.
   --------------------------------------------------------------------- */
SELECT 'V4 nothing else moved' AS check_,
       COUNT(*)                                                                   AS rows_,
       COUNT_IF(f.GUEST_ID               <> b.GUEST_ID)                            AS guest,
       COUNT_IF(f.ISSUE_DT               <> b.ISSUE_DT)                            AS issue_dt,
       COUNT_IF(f.ISSUE_DTTM             IS DISTINCT FROM b.ISSUE_DTTM)            AS issue_dttm,
       COUNT_IF(f.REDEEM_DTTM            IS DISTINCT FROM b.REDEEM_DTTM)           AS redeem_dttm,
       COUNT_IF(f.ISSUE_COMP_WORTH_AMT   IS DISTINCT FROM b.ISSUE_COMP_WORTH_AMT)  AS issue_worth,
       COUNT_IF(f.USED_COMP_WORTH_AMT    IS DISTINCT FROM b.USED_COMP_WORTH_AMT)   AS used_worth,
       COUNT_IF(f.COMP_STATUS_CD         IS DISTINCT FROM b.COMP_STATUS_CD)        AS status,
       COUNT_IF(f.COMP_CATEGORY          IS DISTINCT FROM b.COMP_CATEGORY)         AS category,
       COUNT_IF(f.CASINO_OUTLET_CD       <> b.CASINO_OUTLET_CD)                    AS outlet,
       IFF(COUNT_IF(f.GUEST_ID <> b.GUEST_ID) = 0
           AND COUNT_IF(f.ISSUE_DT <> b.ISSUE_DT) = 0
           AND COUNT_IF(f.ISSUE_DTTM IS DISTINCT FROM b.ISSUE_DTTM) = 0
           AND COUNT_IF(f.REDEEM_DTTM IS DISTINCT FROM b.REDEEM_DTTM) = 0
           AND COUNT_IF(f.ISSUE_COMP_WORTH_AMT IS DISTINCT FROM b.ISSUE_COMP_WORTH_AMT) = 0
           AND COUNT_IF(f.USED_COMP_WORTH_AMT IS DISTINCT FROM b.USED_COMP_WORTH_AMT) = 0
           AND COUNT_IF(f.COMP_STATUS_CD IS DISTINCT FROM b.COMP_STATUS_CD) = 0
           AND COUNT_IF(f.COMP_CATEGORY IS DISTINCT FROM b.COMP_CATEGORY) = 0
           AND COUNT_IF(f.CASINO_OUTLET_CD <> b.CASINO_OUTLET_CD) = 0, 'PASS', 'FAIL') AS result,
       COUNT_IF(f.DELETE_IND  <> b.DELETE_IND)                                    AS delete_ind_applied_from_cms,
       COUNT_IF(f.COMPOR_NAME IS DISTINCT FROM b.COMPOR_NAME)                      AS host_name_pending_rerun
FROM DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_UATREPLAY b
JOIN DAAS_CORE.COMP_DETAIL_FACT f ON f.COMP_DETAIL_FACT_SK = b.COMP_DETAIL_FACT_SK
WHERE b.DELETE_IND = 'N' AND b.SOURCE_SYSTEM_NM = 'HETCMS'
  AND b.PROPERTY_CD = 'UTU' AND b.ISSUE_DT BETWEEN '2026-03-01' AND '2026-03-31';


/* ---------------------------------------------------------------------
   V5a. NOTES FROM MERGED-AWAY ACCOUNTS ARE KEPT: THE RULE AS DEPLOYED CODE
   Runs before 14. When CMS merges two accounts it moves the comp to the
   surviving id and leaves the note under the old one. The v1.14 rule
   finds the old id in the comp's history and keeps the note; for merges
   older than the history (April 2022 for most properties) it cannot,
   and the note is dropped: 561 comps in PROD on 10/29 (16 B2). v1.15
   keeps them when the guest bridge says the two accounts are the same
   person. The dynamic table carries the same v1.15 comment block as the
   procs and rebuilds from raw under its own role, with no CALL and no
   masking in the way; once 05 is deployed and refreshed (V0) it already
   holds v1.15's answer for every comp in UAT, the rescue list included.
   This compares that answer to the key 17 built from the rule. PASS
   when every comp on the list that the table holds as active carries
   exactly the text the rule predicts, none is blank, and the remarks
   agree too. dt_marks_deleted is reported, not judged: a comp CMS
   deleted that the fact has not caught up on (the DELETE_IND defect) is
   not a failure of the comment rule; 14 applies those. The last number
   is the before picture: how many of these notes v1.14 would have dropped.
   Expect: N | 0 | small | 0 | 0 | 0 | about N | PASS   (N = comps, 17 step 4)
   --------------------------------------------------------------------- */
WITH dt_active AS (
    SELECT COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD, COMP_COMMENTS_DESC, COMMENTS_EXTENDED
    FROM DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT
    WHERE DELETE_IND = 'N'
      AND (COMP_NBR, ISHDRW, PROPERTY_CD) IN
          (SELECT COMP_NBR, ISHDRW, PROPERTY_CD FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED)
),
dt_deleted AS (
    SELECT DISTINCT COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD
    FROM DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT
    WHERE DELETE_IND = 'Y'
      AND (COMP_NBR, ISHDRW, PROPERTY_CD) IN
          (SELECT COMP_NBR, ISHDRW, PROPERTY_CD FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED)
)
SELECT 'V5a merged-away notes kept (dynamic table)' AS check_,
       COUNT(*)                                                                                  AS comps,
       COUNT_IF(d.COMP_NBR IS NULL AND x.COMP_NBR IS NULL)                                       AS missing_in_dt,
       COUNT_IF(d.COMP_NBR IS NULL AND x.COMP_NBR IS NOT NULL)                                   AS dt_marks_deleted,
       COUNT_IF(d.COMP_NBR IS NOT NULL AND d.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT)  AS comment_mismatches,
       COUNT_IF(d.COMP_NBR IS NOT NULL AND d.COMP_COMMENTS_DESC IS NULL)                         AS blank_notes,
       COUNT_IF(d.COMP_NBR IS NOT NULL AND d.COMMENTS_EXTENDED IS DISTINCT FROM e.NEW_REMARKS)   AS remark_mismatches,
       COUNT_IF(e.V114_COMMENT IS NULL AND e.OLD_COMMENT IS NOT NULL)                            AS notes_v114_would_have_dropped,
       IFF(COUNT_IF(d.COMP_NBR IS NULL AND x.COMP_NBR IS NULL) = 0
           AND COUNT_IF(d.COMP_NBR IS NOT NULL AND d.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT) = 0
           AND COUNT_IF(d.COMP_NBR IS NOT NULL AND d.COMP_COMMENTS_DESC IS NULL) = 0
           AND COUNT_IF(d.COMP_NBR IS NOT NULL AND d.COMMENTS_EXTENDED IS DISTINCT FROM e.NEW_REMARKS) = 0,
           'PASS', 'FAIL')                                                                       AS result
FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED e
LEFT JOIN dt_active d
  ON  d.COMP_NBR = e.COMP_NBR AND d.ISHDRW = e.ISHDRW AND d.PROPERTY_CD = e.PROPERTY_CD
  AND d.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD
LEFT JOIN dt_deleted x
  ON  x.COMP_NBR = e.COMP_NBR AND x.ISHDRW = e.ISHDRW AND x.PROPERTY_CD = e.PROPERTY_CD
  AND x.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD;

--  V5a, seen: ten comps from the list, the holder today, the old account
--  the note sits under, what v1.14 would show, and what the table shows.
--  (Names may appear.)
SELECT r.PROPERTY_CODE, r.COMP_NBR, r.ISSUE_DT, r.COMP_GUEST, r.NOTE_GUEST, r.PRIMARY_NBR,
       e.V114_COMMENT       AS v114_would_show,
       d.COMP_COMMENTS_DESC AS table_shows
FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_RESCUE r
JOIN DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED e
  ON  e.COMP_NBR = r.COMP_NBR AND e.ISHDRW = r.ISHDRW AND e.PROPERTY_CD = r.PROPERTY_CODE
JOIN DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT d
  ON  d.COMP_NBR = e.COMP_NBR AND d.ISHDRW = e.ISHDRW AND d.PROPERTY_CD = e.PROPERTY_CD
  AND d.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND d.DELETE_IND = 'N'
QUALIFY ROW_NUMBER() OVER (PARTITION BY r.PROPERTY_CODE, r.COMP_NBR, r.ISHDRW ORDER BY r.LINE_NBR) = 1
ORDER BY r.ISSUE_DT DESC
LIMIT 10;


/* ---------------------------------------------------------------------
   V5. NOTES FROM MERGED-AWAY ACCOUNTS ARE KEPT: WRITTEN BY THE PROC
   After 14. The same comps as V5a, this time as the fact holds them
   once the architect's run (14 rev 2) has replayed the rescue list
   through the proc itself, batch-scoped, under an unmasked role. PASS
   when every active comp on the list carries exactly the text the rule
   predicts, none is blank, and the dynamic table (refreshed under
   v1.15) agrees. The fourth number is the before picture: how many of
   these notes the v1.14 rule would have dropped.
   Expect: N | 0 | 0 | about N | 0 | PASS   (N = comps on the list)
   --------------------------------------------------------------------- */
SELECT 'V5 merged-away notes kept' AS check_,
       COUNT(*)                                                                AS comps,
       COUNT_IF(f.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT)           AS comment_mismatches,
       COUNT_IF(f.COMP_COMMENTS_DESC IS NULL)                                  AS blank_notes,
       COUNT_IF(e.V114_COMMENT IS NULL AND e.OLD_COMMENT IS NOT NULL)          AS notes_v114_would_have_dropped,
       COUNT_IF(d.COMP_NBR IS NULL OR d.COMP_COMMENTS_DESC IS DISTINCT FROM f.COMP_COMMENTS_DESC) AS dt_differs,
       IFF(COUNT_IF(f.COMP_COMMENTS_DESC IS DISTINCT FROM e.NEW_COMMENT) = 0
           AND COUNT_IF(f.COMP_COMMENTS_DESC IS NULL) = 0
           AND COUNT_IF(d.COMP_NBR IS NULL OR d.COMP_COMMENTS_DESC IS DISTINCT FROM f.COMP_COMMENTS_DESC) = 0,
           'PASS', 'FAIL')                                                     AS result
FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED e
JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_NBR = e.COMP_NBR AND f.ISHDRW = e.ISHDRW AND f.PROPERTY_CD = e.PROPERTY_CD
  AND f.CASINO_OUTLET_CD = e.CASINO_OUTLET_CD AND f.DELETE_IND = 'N'
LEFT JOIN DAAS_CORE_GAMING.COMP_DETAIL_FACT_DT d
  ON  d.COMP_NBR = f.COMP_NBR AND d.ISHDRW = f.ISHDRW AND d.PROPERTY_CD = f.PROPERTY_CD
  AND d.CASINO_OUTLET_CD = f.CASINO_OUTLET_CD AND d.DELETE_IND = 'N';

--  V5, seen: ten comps from the list, the holder today, the old account
--  the note sits under, and the note the report keeps. (Names may appear.)
SELECT r.PROPERTY_CODE, r.COMP_NBR, r.ISSUE_DT, r.COMP_GUEST, r.NOTE_GUEST, r.PRIMARY_NBR,
       f.COMP_COMMENTS_DESC AS note_kept
FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_RESCUE r
JOIN DAAS_CORE.COMP_DETAIL_FACT f
  ON  f.COMP_NBR = r.COMP_NBR AND f.ISHDRW = r.ISHDRW AND f.PROPERTY_CD = r.PROPERTY_CODE AND f.DELETE_IND = 'N'
QUALIFY ROW_NUMBER() OVER (PARTITION BY r.PROPERTY_CODE, r.COMP_NBR, r.ISHDRW ORDER BY r.LINE_NBR) = 1
ORDER BY r.ISSUE_DT DESC
LIMIT 10;
