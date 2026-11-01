/* =====================================================================
   DAASI-3640 | UAT prep for the v1.15 run: the bridge rescue list
   For: Chris (DAAS_TEAM), in UAT, before the architect runs 14 rev 2.

   v1.15 adds the bridge match (16 proved it in PROD: 561 comps, all
   first seen by the feed after their issue date, 0 displacements). The
   March slice has none of these comps (16 C2 = 0), so the UAT proof of
   v1.15 is a replay of UAT's own rescue list: the comps whose note the
   v1.14 rule would blank and the v1.15 rule keeps. This file builds the
   work tables for that: the list, a backup of its fact rows, the answer
   key (what v1.15 should write), and the raw rows to bump.

   Steps: 1 (run 16 B1 in UAT, then the SET line), then 2 to 5 in order.
   Tables made, all in DAAS_UAT.DAAS_TEMP_WORK:
     DAASI3640_BRIDGE_RESCUE                 one row per rescued line (16 B1, guard passed)
     COMP_DETAIL_FACT_BKP_DAASI3640_BRIDGE   the fact rows of those comps, every column
     DAASI3640_BRIDGE_EXPECTED               per active comp: old text, v1.14 text, v1.15 text
     DAASI3640_BRIDGE_SLICE                  the latest raw row of each comp, for the bump
   ===================================================================== */

USE DATABASE DAAS_UAT;


-- 1. Run 16 B1 here, as it is (it reads this database), then this line
--    straight after it with nothing in between.
SET bridge_detail = LAST_QUERY_ID();


-- 2. The rescue list. Expect lines and comps of the same order as PROD
--    (585 / 561 on 10/29; UAT raw is a copy of PROD from some date).
CREATE OR REPLACE TRANSIENT TABLE DAAS_TEMP_WORK.DAASI3640_BRIDGE_RESCUE AS
SELECT * FROM TABLE(RESULT_SCAN($bridge_detail)) WHERE PASSES_GUARD;

SELECT COUNT(*)                                                       AS lines,
       COUNT(DISTINCT PROPERTY_CODE || '-' || COMP_NBR || '-' || ISHDRW) AS comps,
       COUNT(DISTINCT PRIMARY_NBR)                                    AS people
FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_RESCUE;


-- 3. Backup: every fact row on those comps' keys, every column, as it
--    is today (active and inactive rows alike). Plain CREATE so a rerun
--    cannot overwrite it.
CREATE TRANSIENT TABLE DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_BRIDGE AS
SELECT f.*
FROM DAAS_CORE.COMP_DETAIL_FACT f
WHERE f.SOURCE_SYSTEM_NM = 'HETCMS'
  AND (f.COMP_NBR, f.ISHDRW, f.PROPERTY_CD) IN
      (SELECT DISTINCT COMP_NBR, ISHDRW, PROPERTY_CODE FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_RESCUE);

SELECT COUNT(*) AS rows_backed_up, COUNT_IF(DELETE_IND = 'N') AS active_rows
FROM DAAS_TEMP_WORK.COMP_DETAIL_FACT_BKP_DAASI3640_BRIDGE;


-- 4. The answer key, for every active row on those comps: what the fact
--    holds now, what the v1.14 rule would write (own lines only), and
--    what the v1.15 rule writes (own lines plus bridged lines). Same
--    rules as the procs, limited to these comp numbers.
CREATE OR REPLACE TRANSIENT TABLE DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED AS
WITH keys AS (
    SELECT DISTINCT COMP_NBR AS CNUMRW, PROPERTY_CODE
    FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_RESCUE
),
comps AS (
    SELECT f.COMP_NBR, f.ISHDRW, f.PROPERTY_CD, f.CASINO_OUTLET_CD, f.GUEST_ID, f.ISSUE_DT,
           f.COMP_COMMENTS_DESC AS OLD_COMMENT,
           f.COMMENTS_EXTENDED  AS OLD_REMARKS,
           f.UPDATED_DTTM       AS OLD_UPDATED_DTTM,
           f.BATCH_ID           AS OLD_BATCH_ID,
           f.MD5_CHECKSUM       AS OLD_MD5
    FROM DAAS_CORE.COMP_DETAIL_FACT f
    WHERE f.DELETE_IND = 'N' AND f.SOURCE_SYSTEM_NM = 'HETCMS'
      AND (f.COMP_NBR, f.ISHDRW, f.PROPERTY_CD) IN
          (SELECT DISTINCT COMP_NBR, ISHDRW, PROPERTY_CODE FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_RESCUE)
),
matched AS (    -- every line each comp can carry, with how it matched: 1 own, 2 bridged
    SELECT H.CNUMRW, H.ISHDRW, H.PROPERTY_CODE, L.CSEQCM, L.CMNTCM, 1 AS MATCH_RANK,
           L.OPERATION_DATE, L.OPERATION_SEQUENCE_NBR, L.CREATED_DATE
    FROM (SELECT DISTINCT R.CNUMRW, R.ISHDRW, R.PROPERTY_CODE, R.SYIDRW
          FROM DAAS_RAW_HETCMS.CMPRW_RAW R
          JOIN keys K ON K.CNUMRW = R.CNUMRW AND K.PROPERTY_CODE = R.PROPERTY_CODE) H
    JOIN (SELECT E.SYIDCM, E."CMP#CM", E.CSEQCM, E.CMNTCM, E.PROPERTY_CODE,
                 E.OPERATION_DATE, E.OPERATION_SEQUENCE_NBR, E.CREATED_DATE
          FROM DAAS_RAW_HETCMS.ECPCMPCM_RAW E
          JOIN keys K ON K.CNUMRW = E."CMP#CM" AND K.PROPERTY_CODE = E.PROPERTY_CODE
          QUALIFY ROW_NUMBER() OVER (PARTITION BY E.SYIDCM, E."CMP#CM", E.CSEQCM, E.PROPERTY_CODE
                  ORDER BY E.OPERATION_DATE DESC, E.OPERATION_SEQUENCE_NBR DESC, E.CREATED_DATE DESC) = 1) L
      ON L.SYIDCM = H.SYIDRW AND L."CMP#CM" = H.CNUMRW AND L.PROPERTY_CODE = H.PROPERTY_CODE
    UNION ALL
    SELECT H.CNUMRW, H.ISHDRW, H.PROPERTY_CODE, L.CSEQCM, L.CMNTCM, 2 AS MATCH_RANK,
           L.OPERATION_DATE, L.OPERATION_SEQUENCE_NBR, L.CREATED_DATE
    FROM (SELECT E.SYIDCM, E."CMP#CM", E.CSEQCM, E.CMNTCM, E.PROPERTY_CODE,
                 E.OPERATION_DATE, E.OPERATION_SEQUENCE_NBR, E.CREATED_DATE,
                 MIN(E.OPERATION_DATE) OVER (PARTITION BY E.SYIDCM, E."CMP#CM", E.CSEQCM, E.PROPERTY_CODE) AS FIRST_SEEN
          FROM DAAS_RAW_HETCMS.ECPCMPCM_RAW E
          JOIN keys K ON K.CNUMRW = E."CMP#CM" AND K.PROPERTY_CODE = E.PROPERTY_CODE
          QUALIFY ROW_NUMBER() OVER (PARTITION BY E.SYIDCM, E."CMP#CM", E.CSEQCM, E.PROPERTY_CODE
                  ORDER BY E.OPERATION_DATE DESC, E.OPERATION_SEQUENCE_NBR DESC, E.CREATED_DATE DESC) = 1) L
    JOIN (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, SYIDRW
          FROM (SELECT R.CNUMRW, R.ISHDRW, R.PROPERTY_CODE, R.SYIDRW,
                       MIN(R.OPERATION_DATE) OVER (PARTITION BY R.CNUMRW, R.ISHDRW, R.PROPERTY_CODE) AS FIRST_SEEN
                FROM DAAS_RAW_HETCMS.CMPRW_RAW R
                JOIN keys K ON K.CNUMRW = R.CNUMRW AND K.PROPERTY_CODE = R.PROPERTY_CODE)
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
),
v115 AS (       -- own lines first, then the latest version, one text per line number
    SELECT CNUMRW, ISHDRW, PROPERTY_CODE,
           LISTAGG(CMNTCM, '|') WITHIN GROUP (ORDER BY CSEQCM) AS CMNTCM
    FROM (SELECT * FROM matched
          QUALIFY ROW_NUMBER() OVER (PARTITION BY CNUMRW, ISHDRW, PROPERTY_CODE, CSEQCM
                  ORDER BY MATCH_RANK, OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1)
    GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE
),
v114 AS (       -- the same with own lines only
    SELECT CNUMRW, ISHDRW, PROPERTY_CODE,
           LISTAGG(CMNTCM, '|') WITHIN GROUP (ORDER BY CSEQCM) AS CMNTCM
    FROM (SELECT * FROM matched WHERE MATCH_RANK = 1
          QUALIFY ROW_NUMBER() OVER (PARTITION BY CNUMRW, ISHDRW, PROPERTY_CODE, CSEQCM
                  ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1)
    GROUP BY CNUMRW, ISHDRW, PROPERTY_CODE
),
remarks AS (    -- v1.14 rule, unchanged: a remark line belongs to the comp live on its number when written
    SELECT CNUMRW, ISHDRW, PROPERTY_CODE,
           LEFT(LISTAGG(EXPLRM, '|') WITHIN GROUP (ORDER BY SEQNRM), 4000) AS COMMENTS_EXTENDED
    FROM (
        SELECT C.CNUMRW, C.ISHDRW, C.PROPERTY_CODE, R.SEQNRM, R.EXPLRM
        FROM (SELECT CNUMRW, ISHDRW, PROPERTY_CODE, FIRST_SEEN,
                     LAG(FIRST_SEEN)  OVER (PARTITION BY CNUMRW, PROPERTY_CODE ORDER BY FIRST_SEEN, ISHDRW) AS PREV_FIRST_SEEN,
                     LEAD(FIRST_SEEN) OVER (PARTITION BY CNUMRW, PROPERTY_CODE ORDER BY FIRST_SEEN, ISHDRW) AS NEXT_FIRST_SEEN
              FROM (SELECT R.CNUMRW, R.ISHDRW, R.PROPERTY_CODE, MIN(R.OPERATION_DATE) AS FIRST_SEEN
                    FROM DAAS_RAW_HETCMS.CMPRW_RAW R
                    JOIN keys K ON K.CNUMRW = R.CNUMRW AND K.PROPERTY_CODE = R.PROPERTY_CODE
                    GROUP BY R.CNUMRW, R.ISHDRW, R.PROPERTY_CODE)) C
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
SELECT c.*,
       a.CMNTCM            AS V114_COMMENT,
       b.CMNTCM            AS NEW_COMMENT,
       r.COMMENTS_EXTENDED AS NEW_REMARKS
FROM comps c
LEFT JOIN v114    a ON a.CNUMRW = c.COMP_NBR AND a.ISHDRW = c.ISHDRW AND a.PROPERTY_CODE = c.PROPERTY_CD
LEFT JOIN v115    b ON b.CNUMRW = c.COMP_NBR AND b.ISHDRW = c.ISHDRW AND b.PROPERTY_CODE = c.PROPERTY_CD
LEFT JOIN remarks r ON r.CNUMRW = c.COMP_NBR AND r.ISHDRW = c.ISHDRW AND r.PROPERTY_CODE = c.PROPERTY_CD;

--    What the run should do to these comps. Expect: v114_would_blank
--    close to comps (that is the point of the list), v115_blank 0, and
--    comment_changes small: most of these comps show the same text today
--    through the old number-only match; the ones that change were
--    showing extra lines from other guests on the number.
SELECT COUNT(*)                                                  AS comps,
       COUNT_IF(V114_COMMENT IS NULL AND OLD_COMMENT IS NOT NULL) AS v114_would_blank,
       COUNT_IF(NEW_COMMENT IS NULL)                             AS v115_blank,
       COUNT_IF(NEW_COMMENT IS DISTINCT FROM OLD_COMMENT)        AS comment_changes,
       COUNT_IF(NEW_REMARKS IS DISTINCT FROM OLD_REMARKS)        AS remark_changes,
       COUNT_IF(NEW_REMARKS IS NOT NULL)                         AS comps_with_remarks
FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED;


-- 5. The raw rows to replay: the latest version of each active comp on
--    the list. Expect the same count as comps in step 4.
CREATE OR REPLACE TRANSIENT TABLE DAAS_TEMP_WORK.DAASI3640_BRIDGE_SLICE AS
SELECT CNUMRW, ISHDRW, COTLRW, PROPERTY_CODE, OPERATION_DATE, OPERATION_SEQUENCE_NBR, CREATED_DATE
FROM DAAS_RAW_HETCMS.CMPRW_RAW
WHERE (CNUMRW, ISHDRW, PROPERTY_CODE, COTLRW) IN
      (SELECT COMP_NBR, ISHDRW, PROPERTY_CD, CASINO_OUTLET_CD FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_EXPECTED)
QUALIFY ROW_NUMBER() OVER (PARTITION BY CNUMRW, ISHDRW, COTLRW, PROPERTY_CODE
        ORDER BY OPERATION_DATE DESC, OPERATION_SEQUENCE_NBR DESC, CREATED_DATE DESC) = 1;

SELECT COUNT(*) AS raw_rows_to_bump FROM DAAS_TEMP_WORK.DAASI3640_BRIDGE_SLICE;
