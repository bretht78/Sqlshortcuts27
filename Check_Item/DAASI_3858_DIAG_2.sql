-- DAASI-3858  Missing CHECK_ATTRIBUTE_IDs in CHECK_ITEM_FACT_VW
-- Round 2.
--
-- Where round 1 left us: the example check (170818751, property CLV, tendered 2026-10-28) is live, its 14
-- lines are in CHECK_ITEM_FACT, and CHECK_ITEM_FACT_VW returns all 14 to you. Nothing is missing, deleted or
-- archived. So the question is now why the same query returned nothing for Bennett. Three candidates:
--   1. The item view only shows a person the properties they are cleared for. The DEV copy of the view
--      carries a row access policy on PROPERTY_CD, and the sales view carries none.
--   2. He looked before the lines had loaded.
--   3. His query was not quite the one in the email.
-- Part D tells these apart. Part E asks the wider question with visibility out of the way: is any check
-- really without lines? Part F is one query for Bennett, to use only if we need it.
--
-- Every statement only reads. Run them one at a time. None depends on another.
-- If one is refused or fails, skip it and send me the error text as it appears.
--
-- Term: a row access policy is a rule attached to a table or view that decides, row by row, whether the
-- person asking may see that row. Here the rule would look at each row's property code.


-- =====================================================================================================
-- PART D. Why Bennett saw nothing
-- =====================================================================================================

-- D1. Who else has run a query naming this check: when, as whom, and how many rows came back.
--     Expect Bennett's or Greg's two queries, with the item-view one returning 0 rows.
--     ROLE_NAME is only the main role of a session. You ran A1 with PUBLIC as the main role and still saw
--     the lines, so a session's other roles count as well. SECONDARY_ROLE_STATS shows those.
--     If this comes back empty, tell me the date of Greg's email and we will look another way.
SELECT start_time,
       user_name,
       role_name,
       CASE WHEN query_text ILIKE '%CHECK_ITEM_FACT_VW%' AND query_text ILIKE '%CHECK_SALES_FACT_VW%' THEN 'both views'
            WHEN query_text ILIKE '%CHECK_ITEM_FACT_VW%'  THEN 'item view'
            WHEN query_text ILIKE '%CHECK_SALES_FACT_VW%' THEN 'sales view'
            ELSE 'something else'
       END                        AS asked_of,
       rows_written_to_result     AS rows_returned,
       rows_produced,
       execution_status,
       secondary_role_stats,
       query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= '2026-10-28'
  AND query_text ILIKE '%170818751%'
  AND user_name <> CURRENT_USER()
ORDER BY start_time;


-- D2. Which POS views, and the four check tables under them, carry a row access policy in PROD.
--     One row per object. ROW_ACCESS_POLICY is empty where none is attached.
--     POLICIES_VISIBLE_IN_PROD is how many such attachments your role can see anywhere in DAAS_PROD. If it
--     is 0, the empty cells only mean your role cannot see policies, not that there are none.
WITH rap AS (
    SELECT ref_schema_name, ref_entity_name, policy_schema, policy_name, ref_arg_column_names
    FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
    WHERE ref_database_name = 'DAAS_PROD'
      AND policy_kind ILIKE 'ROW%'
)
SELECT t.table_schema,
       t.table_name,
       t.table_type,
       rap.policy_name                  AS row_access_policy,
       rap.policy_schema,
       rap.ref_arg_column_names         AS applied_on,
       (SELECT COUNT(*) FROM rap)       AS policies_visible_in_prod
FROM DAAS_PROD.INFORMATION_SCHEMA.TABLES t
LEFT JOIN rap
       ON rap.ref_schema_name = t.table_schema
      AND rap.ref_entity_name = t.table_name
WHERE t.table_schema IN ('DAAS_CORE_POS_VW', 'DAAS_CORE')
  AND (t.table_schema = 'DAAS_CORE_POS_VW'
       OR t.table_name IN ('CHECK_SALES_FACT', 'CHECK_ITEM_FACT', 'CHECK_ATTRIBUTE_DIM', 'CHECK_TENDER_FACT'))
ORDER BY 1, 2;


-- D3. What each row access policy in PROD says. The rule itself is in POLICY_BODY. Send that cell as text.
--     Nothing here while D2 shows a policy would again mean your role cannot read policies. Then try D3b.
SELECT policy_schema, policy_name, policy_signature, policy_owner, created, last_altered, policy_body
FROM SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES
WHERE policy_catalog = 'DAAS_PROD'
  AND deleted IS NULL
ORDER BY 1, 2;


-- D3b. Only if D3 gives you nothing: the DEV copy of the rule, named in the DEV view you sent.
--      It may be refused, and that is fine.
SELECT GET_DDL('POLICY', 'DAAS_DEV.DAAS_SECURITY.PROPERTY_RLS_POLICY') AS dev_policy_sql;


-- D4. The check next to its lines, both read through the views: when each was loaded and what they add up to.
--     Lines loaded on 2026-10-28, the same evening as the check, rule out candidate 2.
--     Line amounts that add up to the check's net sales (1,116.85) show the lines are complete.
SELECT 'the check (sales view)'            AS what,
       COUNT(*)                            AS row_count,
       COUNT_IF(DELETE_IND = 'N')          AS live_rows,
       MIN(CREATED_DTTM)                   AS first_loaded,
       MAX(CREATED_DTTM)                   AS last_loaded,
       MAX(UPDATED_DTTM)                   AS last_updated,
       SUM(SALES_NET_AMT)                  AS sales_amt,
       CAST(NULL AS NUMBER(38, 2))         AS calculated_gross_amt
FROM DAAS_PROD.DAAS_CORE_POS_VW.CHECK_SALES_FACT_VW
WHERE CHECK_ATTRIBUTE_ID = '170818751'
  AND PROPERTY_CD = 'CLV'
UNION ALL
SELECT 'its lines (item view)',
       COUNT(*),
       COUNT_IF(DELETE_IND = 'N'),
       MIN(CREATED_DTTM),
       MAX(CREATED_DTTM),
       MAX(UPDATED_DTTM),
       SUM(MENU_ITEM_SALES_AMT),
       SUM(CALCULATED_GROSS_SALES_AMT)
FROM DAAS_PROD.DAAS_CORE_POS_VW.CHECK_ITEM_FACT_VW
WHERE CHECK_ATTRIBUTE_ID = '170818751'
  AND PROPERTY_CD = 'CLV';


-- =====================================================================================================
-- PART E. Is any check really without lines?
-- =====================================================================================================

-- E1. Read from the two tables, so no view and no visibility rule is involved. Of the live checks loaded in
--     the week of the example (2026-10-26 to 2026-11-01), how many have no lines at all? Lines are looked
--     for from a week before that window onward.
--     A check with no sales and no lines is ordinary (a payment-only or no-sale check). The column to watch
--     is CHECKS_WITH_SALES_BUT_NO_LINES. If it is 0 or close to it, nothing is really missing.
WITH checks AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MAX(ABS(SALES_GROSS_AMT)) AS net_sales
    FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
    WHERE CREATED_DTTM >= '2026-10-26'
      AND CREATED_DTTM <  '2026-11-02'
      AND DELETE_IND = 'N'
    GROUP BY 1, 2
),
lines AS (
    SELECT DISTINCT CHECK_ATTRIBUTE_ID, PROPERTY_CD
    FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
    WHERE CREATED_DTTM >= '2026-10-19'
)
SELECT COUNT(*)                                                         AS checks_loaded,
       COUNT(DISTINCT c.PROPERTY_CD)                                    AS properties,
       COUNT_IF(l.CHECK_ATTRIBUTE_ID IS NULL)                           AS checks_with_no_lines,
       COUNT_IF(l.CHECK_ATTRIBUTE_ID IS NULL AND c.net_sales > 0)       AS checks_with_sales_but_no_lines,
       COUNT(DISTINCT IFF(l.CHECK_ATTRIBUTE_ID IS NULL AND c.net_sales > 0, c.PROPERTY_CD, NULL))
                                                                        AS properties_with_such_checks
FROM checks c
LEFT JOIN lines l
       ON l.CHECK_ATTRIBUTE_ID = c.CHECK_ATTRIBUTE_ID
      AND l.PROPERTY_CD = c.PROPERTY_CD;


-- =====================================================================================================
-- PART F. For Bennett, only if Part D leaves room for doubt
-- =====================================================================================================

-- F1. What each view shows for the one day the example was loaded. Run it yourself first for the baseline.
--     If the item view shows him fewer properties than the sales view, and 0 rows for CLV, the cause is
--     what he is cleared to see, not missing data.
SELECT 'CHECK_SALES_FACT_VW'             AS view_name,
       COUNT(DISTINCT PROPERTY_CD)       AS properties_shown,
       COUNT_IF(PROPERTY_CD = 'CLV')     AS clv_rows,
       COUNT(*)                          AS all_rows,
       CURRENT_ROLE()                    AS ran_as
FROM DAAS_PROD.DAAS_CORE_POS_VW.CHECK_SALES_FACT_VW
WHERE CREATED_DTTM >= '2026-10-28'
  AND CREATED_DTTM <  '2026-10-29'
UNION ALL
SELECT 'CHECK_ITEM_FACT_VW',
       COUNT(DISTINCT PROPERTY_CD),
       COUNT_IF(PROPERTY_CD = 'CLV'),
       COUNT(*),
       CURRENT_ROLE()
FROM DAAS_PROD.DAAS_CORE_POS_VW.CHECK_ITEM_FACT_VW
WHERE CREATED_DTTM >= '2026-10-28'
  AND CREATED_DTTM <  '2026-10-29';
