-- DAASI-3858  Missing CHECK_ATTRIBUTE_IDs in CHECK_ITEM_FACT_VW
-- Round 1 of the investigation. Reported by Greg Morgan, example check 170818751.
--
-- What this round does: looks for the example check in each place it could live, and collects the facts
-- about the two views. Every statement only reads. Run them one at a time. None depends on another.
-- If a statement fails (no access, object not found), skip it and send me the error text as it appears.
--
-- Terms, as I read the object names (this round confirms them): a "check" is one bill at a restaurant,
-- bar or shop register. CHECK_ATTRIBUTE_ID identifies the check. CHECK_SALES_FACT holds the check's
-- sales, CHECK_ITEM_FACT the individual lines on the bill, CHECK_ATTRIBUTE_DIM the check's own record.


-- =====================================================================================================
-- PART A. The example check
-- =====================================================================================================

-- A1. Greg's two queries, run as you, side by side. The filter is his, unchanged.
--     Expect: the sales view shows rows and the item view shows 0, which is what Bennett saw.
--     If the item view shows rows for you, the items exist. Either the load has caught up since Bennett
--     looked, or the item view shows your role rows that it hides from his. Round 2 would tell which.
--     The square brackets show any spaces stored around the ID.
SELECT 'CHECK_SALES_FACT_VW'                    AS view_name,
       COUNT(*)                                 AS row_count,
       COUNT(DISTINCT CHECK_ATTRIBUTE_ID)       AS distinct_ids,
       '[' || MIN(CHECK_ATTRIBUTE_ID) || ']'    AS lowest_id_as_stored,
       '[' || MAX(CHECK_ATTRIBUTE_ID) || ']'    AS highest_id_as_stored,
       CURRENT_ROLE()                           AS ran_as
FROM DAAS_PROD.DAAS_CORE_POS_VW.CHECK_SALES_FACT_VW
WHERE TRIM(CHECK_ATTRIBUTE_ID) LIKE '%170818751%'
UNION ALL
SELECT 'CHECK_ITEM_FACT_VW',
       COUNT(*),
       COUNT(DISTINCT CHECK_ATTRIBUTE_ID),
       '[' || MIN(CHECK_ATTRIBUTE_ID) || ']',
       '[' || MAX(CHECK_ATTRIBUTE_ID) || ']',
       CURRENT_ROLE()
FROM DAAS_PROD.DAAS_CORE_POS_VW.CHECK_ITEM_FACT_VW
WHERE TRIM(CHECK_ATTRIBUTE_ID) LIKE '%170818751%';


-- A2. The check's own record, read from the table rather than through a view: which property it belongs
--     to, and whether it is flagged deleted (DELETE_IND = 'Y').
--       one row, DELETE_IND = 'N'  -> the ordinary case
--       DELETE_IND = 'Y'           -> answers Greg's "deleted records?" directly
--       more than one property     -> the same ID number is used by different properties
--       no rows at all             -> the check has sales but no record of its own
SELECT '[' || CHECK_ATTRIBUTE_ID || ']'   AS id_as_stored,
       PROPERTY_CD,
       SRC_PROPERTY_CD,
       DELETE_IND,
       COUNT(*)                           AS row_count
FROM DAAS_PROD.DAAS_CORE.CHECK_ATTRIBUTE_DIM
WHERE TRIM(CHECK_ATTRIBUTE_ID) LIKE '%170818751%'
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;


-- A3. The two tables I expect the views to be built on (B3 confirms that), counted directly, so the
--     views' own joins and filters are out of the picture. This is the deciding one:
--       item table = 0  -> the lines were never loaded, or the check never had any (a payment-only check, say)
--       item table > 0  -> the lines exist and the item view is leaving them out
SELECT 'DAAS_CORE.CHECK_SALES_FACT'           AS table_name,
       COUNT(*)                               AS row_count,
       COUNT(DISTINCT CHECK_ATTRIBUTE_ID)     AS distinct_ids
FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
WHERE TRIM(CHECK_ATTRIBUTE_ID) LIKE '%170818751%'
UNION ALL
SELECT 'DAAS_CORE.CHECK_ITEM_FACT',
       COUNT(*),
       COUNT(DISTINCT CHECK_ATTRIBUTE_ID)
FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
WHERE TRIM(CHECK_ATTRIBUTE_ID) LIKE '%170818751%';


-- =====================================================================================================
-- PART B. The two views
-- =====================================================================================================

-- B1. Secure or not, owning role, and when each view was last redeployed (LAST_DDL).
--     In October, CHECK_ITEM_FACT_VW was a secure view and CHECK_SALES_FACT_VW was not.
--     A LAST_DDL date close to when the gap started would point at a redeploy.
SELECT table_name AS view_name, is_secure, table_owner, created, last_ddl, last_ddl_by, last_altered
FROM DAAS_PROD.INFORMATION_SCHEMA.VIEWS
WHERE table_schema = 'DAAS_CORE_POS_VW'
  AND table_name IN ('CHECK_SALES_FACT_VW', 'CHECK_ITEM_FACT_VW', 'CHECK_ATTRIBUTE_DIM_VW')
ORDER BY 1;


-- B2. The SQL behind each view. Click the result cell, copy it from the side panel and send it as text.
--     The sales view should come back. The item view may be refused, because Snowflake shows a secure
--     view's SQL only to the role that owns it. A refusal is fine and is itself an answer.
SELECT GET_DDL('VIEW', 'DAAS_PROD.DAAS_CORE_POS_VW.CHECK_SALES_FACT_VW') AS sales_view_sql;

SELECT GET_DDL('VIEW', 'DAAS_PROD.DAAS_CORE_POS_VW.CHECK_ITEM_FACT_VW') AS item_view_sql;


-- B3. What each view reads, from Snowflake's own dependency catalog. The catalog covers secure views too,
--     so it names the tables and views behind CHECK_ITEM_FACT_VW even if B2 would not show its SQL.
--     It can run a few hours behind a change.
SELECT referencing_object_name   AS view_name,
       referenced_database,
       referenced_schema,
       referenced_object_name,
       referenced_object_domain
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE referencing_database = 'DAAS_PROD'
  AND referencing_schema = 'DAAS_CORE_POS_VW'
  AND referencing_object_name IN ('CHECK_SALES_FACT_VW', 'CHECK_ITEM_FACT_VW')
ORDER BY 1, 2, 3, 4;


-- B4. Size, clustering and column list of every object involved, so round 2 can use real column names
--     and fast filters. Please send this one as text (download the result, or copy the cells).
WITH cols AS (
    SELECT table_schema, table_name,
           COUNT(*) AS column_count,
           LISTAGG(column_name || ' ' || data_type, ', ') WITHIN GROUP (ORDER BY ordinal_position) AS columns
    FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema IN ('DAAS_CORE', 'DAAS_CORE_POS_VW')
      AND table_name IN ('CHECK_SALES_FACT', 'CHECK_ITEM_FACT', 'CHECK_ATTRIBUTE_DIM', 'CHECK_TENDER_FACT',
                         'CHECK_SALES_FACT_VW', 'CHECK_ITEM_FACT_VW', 'CHECK_ATTRIBUTE_DIM_VW', 'CHECK_TENDER_FACT_VW')
    GROUP BY 1, 2
)
SELECT t.table_schema, t.table_name, t.table_type, t.row_count,
       ROUND(t.bytes / POWER(1024, 3), 1) AS size_gb,
       t.clustering_key, t.last_altered,
       c.column_count, c.columns
FROM DAAS_PROD.INFORMATION_SCHEMA.TABLES t
JOIN cols c
  ON c.table_schema = t.table_schema
 AND c.table_name = t.table_name
WHERE t.table_schema IN ('DAAS_CORE', 'DAAS_CORE_POS_VW')
  AND t.table_name IN ('CHECK_SALES_FACT', 'CHECK_ITEM_FACT', 'CHECK_ATTRIBUTE_DIM', 'CHECK_TENDER_FACT',
                       'CHECK_SALES_FACT_VW', 'CHECK_ITEM_FACT_VW', 'CHECK_ATTRIBUTE_DIM_VW', 'CHECK_TENDER_FACT_VW')
ORDER BY 1, 2;


-- =====================================================================================================
-- PART C. Optional
-- =====================================================================================================

-- C1. The check as the sales view presents it: business date, amounts and the rest. This is the slow
--     one, because it reads every column of the sales data to find one check. Give it a few minutes or
--     skip it. Round 2 can fetch the same row quickly once B4 is in.
SELECT *
FROM DAAS_PROD.DAAS_CORE_POS_VW.CHECK_SALES_FACT_VW
WHERE TRIM(CHECK_ATTRIBUTE_ID) LIKE '%170818751%'
LIMIT 50;
