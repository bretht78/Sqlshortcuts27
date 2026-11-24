-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- PROD: the steps around the deploy of the two archive task files. For the role that owns the Medallia tasks.
--
-- WHY. The two task files in the pull request are CREATE OR REPLACE TASK. Snowflake has two rules for that:
--   1. A task that sits in a chain can only be recreated while the first task of the chain is suspended.
--      UAT could not show this, because the first tasks of UAT's two chains are suspended already.
--   2. A recreated task comes back suspended. UAT showed this on 11/19: both archive tasks came back suspended.
-- A suspended task in the middle of a chain is skipped. Snowflake's documentation says the chain then carries
-- on as though that task had succeeded, which in PROD would mean both files still going out every morning
-- while the two archive tables quietly stopped being loaded, with nothing failing and nothing alerting.
-- (Were the tasks behind it skipped as well, no file would go out at all.) Either way, the two archive tasks
-- have to be resumed after the deploy.
--
-- WHAT UAT ALSO SHOWED. The three export tasks kept their link to the recreated archive tasks, and the
-- warehouse and "after" lines came out with the right environment. Nothing needs re-linking.
--
-- WHEN. After the day's 09:30 Pacific runs have finished. Step 3 has to be done before the next 09:30 Pacific.
--
-- IF THE DEPLOY FAILS PART WAY, STILL RUN STEP 3. A chain whose first task is left suspended does not run at all.
-- If the task files are left out of the PROD deploy, use change_archive_tasks_in_place_PROD.sql instead. It
-- changes the two archive tasks without recreating them.


-- 1. BEFORE THE DEPLOY. Keep this result: it is the state every task has to be back in at the end.
--    Run the two statements together.
SHOW TASKS LIKE 'MEDALLIA%' IN SCHEMA DAAS_PROD.DAAS_COMMON;

SELECT "name"                            AS TASK_NAME,
       "state"                           AS STATE,
       "predecessors"                    AS RUNS_AFTER,
       "definition" ILIKE '%LOYALTY%'    AS HAS_LOYALTY,
       "created_on"                      AS CREATED_ON
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 1;

--    Then suspend the first task of each chain.
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_HOTEL_TASK SUSPEND;
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_TASK SUSPEND;


-- 2. DEPLOY from main with the GitHub workflow: the five tables, the three procedures, the two tasks.


-- 3. AFTER THE DEPLOY. The two archive tasks first, then the first task of each chain.
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_ARCHIVE_TASK RESUME;
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK RESUME;
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_HOTEL_TASK RESUME;
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_TASK RESUME;


-- 4. CHECK. Run the two statements together.
--    Expect: every task has the STATE and RUNS_AFTER it had in step 1, and the two archive tasks now show
--    HAS_LOYALTY = TRUE with a CREATED_ON at the time of the deploy.
SHOW TASKS LIKE 'MEDALLIA%' IN SCHEMA DAAS_PROD.DAAS_COMMON;

SELECT "name"                            AS TASK_NAME,
       "state"                           AS STATE,
       "predecessors"                    AS RUNS_AFTER,
       "definition" ILIKE '%LOYALTY%'    AS HAS_LOYALTY,
       "created_on"                      AS CREATED_ON
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 1;
