/* =====================================================================
   DAASI-3640 | 07b: the bump. The one statement of the PROD replay that
   writes to raw, for the role that holds UPDATE on
   DAAS_PROD.DAAS_RAW_HETCMS.CMPRW_RAW (07's A5 names it).

   What it does: adds 1 to REPLAY_COUNTER on the latest raw row of each
   comp whose comment or remarks will change. No business column
   changes. The scheduled load then finds those rows in its stream and
   rebuilds the comps with the v1.14 procedure, under its own role.

   It is part D of DAASI-3640_07_prod_replay.sql word for word, with the
   database written into the two table names so that it does not depend
   on the worksheet's context.

   When: after 07's parts A, B and C are done and accepted, and the load
   task is suspended with no run executing (07 E1). Chris says when.
   The list it reads, DAASI3640_RP_SLICE, is built by 07 B4 just before.

   The task owner's own statements around the bump, for the one run.
   07 part E has the sequence and the reasons. The task and its schema
   come from 07 A3, the warehouse from 07 A7 (b). Templates:
     ALTER TASK DAAS_PROD.DAAS_COMMON.<task name> SUSPEND         (E1, before the bump)
     ALTER WAREHOUSE <warehouse the proc runs on> SET WAREHOUSE_SIZE = 'LARGE'
     ALTER TASK DAAS_PROD.DAAS_COMMON.<task name> SET USER_TASK_TIMEOUT_MS = 14400000
                                                                  (both while suspended, 14400000 ms is four hours)
     ALTER TASK DAAS_PROD.DAAS_COMMON.<task name> RESUME          (E3, after the bump)
   Afterwards (07 E4), with the task suspended for the moment it takes:
   the warehouse back to its size, and the limit back to what A7 showed,
     ALTER TASK DAAS_PROD.DAAS_COMMON.<task name> UNSET USER_TASK_TIMEOUT_MS
   if A7 showed the default.
   ===================================================================== */

-- 1. Before. The rows the statement will touch. It should equal RAW_ROWS_TO_BUMP from 07 (B4),
--    and it shows that this role can read the list. If it answers "does not exist or not
--    authorized", the list's owner (DAAS_TEAM) grants the read, and then this again:
--      GRANT SELECT ON TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_RP_SLICE TO ROLE <this role>
SELECT COUNT(*) AS rows_to_bump FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_RP_SLICE;

-- 2. The bump. One statement, one transaction: the stream sees all of it or none.
--    "number of rows updated" should equal ROWS_TO_BUMP: pass the number to Chris, who then
--    checks that the stream holds it (07 E2) before the task is resumed (07 E3).
--    Run it once. A second run corrupts nothing, but it rewrites the raw table again for no gain.
UPDATE DAAS_PROD.DAAS_RAW_HETCMS.CMPRW_RAW R
SET REPLAY_COUNTER = COALESCE(R.REPLAY_COUNTER, 0) + 1
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI3640_RP_SLICE S
WHERE R.CNUMRW                 = S.CNUMRW
  AND R.ISHDRW                 = S.ISHDRW
  AND R.COTLRW                 = S.COTLRW
  AND R.PROPERTY_CODE          = S.PROPERTY_CODE
  AND R.OPERATION_DATE         = S.OPERATION_DATE
  AND R.OPERATION_SEQUENCE_NBR = S.OPERATION_SEQUENCE_NBR
  AND R.CREATED_DATE IS NOT DISTINCT FROM S.CREATED_DATE;
