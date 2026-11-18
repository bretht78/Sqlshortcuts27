CREATE OR REPLACE PROCEDURE DAAS_COMMON.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC("RUNDATE" DATE)
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS CALLER
AS 'BEGIN

--Author: Andrew King
--Date Created: 2023-06-23
--Description: Replicates the macro m_CreateMedalliaInvitationFile from Teradata edw_main to generate complete medallia file results based on date passed in.
--Updates:
--2024-01-10 - added GUEST_ID and PROP_ID for host joins
--2024-01-19 - added TRIM to the rep_id where clause in the update host statement
--2024-01-19 - added N instead of empty string to HOSTED_YN column
--2024-08-22 - fixing TIER_CD bug that is giving subtier precedence over tier
--2024-09-05 - adding new subtier logic per medallia request
--2024-09-10 - switching source table for hosted data and revising joins
--2024-10-09 - adding DIA tier logic to coalesce if guest subtier is null
--2025-02-11 - changing 30 day future reservation window to 45 day
--2025-05-29 - changing host_dim join logic to include records with blank host_active_flag
--2025-08-14 - adding join condition to property market lookup to filter out secondary markets
--2026-10-20 - fixing gaming only casino/hotel flags
--2026-10-30 - adding ORIGIN_UNIT_ID for HLT/TAH distinction
--2026-11-17 - DAASI-3811 adding LOYALTY (Luxury Experience tag), carried on hotel rows and NULL on gaming only rows

TRUNCATE TABLE IF EXISTS DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE;

-- HOTEL STAYS ONLY

	INSERT INTO DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE (
		TRANSACTION_ID,
		TRANSACTION_DATE, 
		PROPERTY_MARKET_CD, 
		UNIT_ID, 
		ORIGIN_UNIT_ID,
		CLUBCARD_YN,
		CUSTOMER_ID, 
		GUEST_ID, 
		PROP_ID, 
		FIRST_NAME, 
		LAST_NAME, 
		GENDER, 
		EMAIL_ADDRESS, 
		PHONE_NUMBER, 
		AGE,
		CITY_NAME, 
		STATE_PROVINCE_CODE, 
		ZIP_CODE, 
		ZIP_PLUS_4, 
		TIER_CODE,
		HOTEL_FLAG,
		CASINO_FLAG,
		ROOM_NUMBER,
		RESERVATION_NUMBER,
		ROOM_TYPE_BOOKED,
		ROOM_TYPE_RECEIVED,
		RATE_PLAN_CD,
		RESERVATION_DATE,
		RESERVATION_AGENT,
		CHECK_IN_DATE,
		CHECK_OUT_DATE,
		CHECKIN_AGENT_ID,
		CHECKOUT_AGENT_ID,
		WING_CD,
		ROOM_BLOCK_CD,
		HOTEL_COMP_FLAG_YN,
		HOST_NAME,
		HOST_CODE,
		HOSTED_YN,
		ADR,
		--PROPERTY_WINLOSS,
		HOSP_POS_SPEND,
		ROOM_REV_AMT,
		--THEO_AMT,
        d_arrival_dt,
        d_departure_dt,
        i_checkin_hr,
        i_checkin_min,
        LOYALTY
	)
	WITH hotel_phase1 (
		CUSTOMER_ID, GUEST_ID, PROP_ID, UNIT_ID, TRANSACTION_ID, d_arrival_dt, d_departure_dt, i_checkin_hr, i_checkin_min, RESERVATION_NUMBER, checkinOrder
	)
	AS (
		SELECT INVITE.CUSTOMER_ID, INVITE.GUEST_ID, INVITE.PROP_ID, INVITE.UNIT_ID, INVITE.TRANSACTION_ID,
			INVITE.d_arrival_dt, INVITE.d_departure_dt, INVITE.i_checkin_hr, INVITE.i_checkin_min, RESERVATION_NUMBER,
			ROW_NUMBER() OVER (PARTITION BY INVITE.CUSTOMER_ID ORDER BY INVITE.d_arrival_dt, INVITE.i_checkin_hr, INVITE.i_checkin_min, INVITE.RESERVATION_NUMBER) AS checkinOrder
		FROM DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL INVITE
		WHERE INVITE.check_out_date = :RUNDATE
	),
	hotel_stays (CUSTOMER_ID, GUEST_ID, PROP_ID, UNIT_ID, TRANSACTION_ID, d_arrival_dt, d_departure_dt, i_checkin_hr, i_checkin_min, RESERVATION_NUMBER)
	AS (
		SELECT CUSTOMER_ID, GUEST_ID, PROP_ID, UNIT_ID, TRANSACTION_ID, d_arrival_dt, d_departure_dt, i_checkin_hr, i_checkin_min, RESERVATION_NUMBER
		FROM hotel_phase1
		WHERE checkinOrder = 1
	)
	SELECT
		INV.TRANSACTION_ID,
		INV.TRANSACTION_DATE, 
		INV.PROPERTY_MARKET_CD, 
		INV.UNIT_ID, 
		INV.ORIGIN_UNIT_ID,
		INV.CLUBCARD_YN,
		INV.CUSTOMER_ID, 
		INV.GUEST_ID, 
		INV.PROP_ID, 
		INV.FIRST_NAME, 
		INV.LAST_NAME, 
		INV.GENDER, 
		INV.EMAIL_ADDRESS, 
		INV.PHONE_NUMBER, 
		INV.Age,
		INV.CITY_NAME, 
		INV.STATE_PROVINCE_CODE, 
		INV.ZIP_CODE, 
		INV.ZIP_PLUS_4, 
		INV.TIER_CODE,
		INV.HOTEL_FLAG,
		INV.CASINO_FLAG,
		INV.ROOM_NUMBER,
		INV.RESERVATION_NUMBER,
		INV.ROOM_TYPE_BOOKED,
		INV.ROOM_TYPE_RECEIVED,
		INV.RATE_PLAN_CD,
		INV.RESERVATION_DATE,
		INV.RESERVATION_AGENT,
		INV.CHECK_IN_DATE,
		INV.CHECK_OUT_DATE,
		INV.CHECKIN_AGENT_ID,
		INV.CHECKOUT_AGENT_ID,
		INV.WING_CD,
		INV.ROOM_BLOCK_CD,
		INV.HOTEL_COMP_FLAG_YN,
		INV.HOST_NAME,
		INV.HOST_CODE,
		INV.HOSTED_YN,
		INV.ADR,
		--INV.PROPERTY_WINLOSS,
		INV.HOSP_POS_SPEND,
		INV.ROOM_REV_AMT,
		--INV.THEO_AMT,
        INV.d_arrival_dt,
        INV.d_departure_dt,
        INV.i_checkin_hr,
        INV.i_checkin_min,
        INV.LOYALTY
	FROM hotel_stays HS
	INNER JOIN DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL INV ON HS.CUSTOMER_ID = INV.CUSTOMER_ID
		AND HS.UNIT_ID = INV.UNIT_ID
		AND HS.TRANSACTION_ID = INV.TRANSACTION_ID
		AND HS.d_arrival_dt = INV.d_arrival_dt
		AND HS.d_departure_dt = INV.d_departure_dt
		AND HS.i_checkin_hr = INV.i_checkin_hr
		AND HS.i_checkin_min = INV.i_checkin_min
		AND HS.RESERVATION_NUMBER = INV.RESERVATION_NUMBER
		AND INV.check_out_date = :RUNDATE;

-- GAMING ONLY FOR CUSTOMERS NOT IN THE HOTEL SECTION

	INSERT INTO DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE (
		TRANSACTION_ID,
		TRANSACTION_DATE, 
		PROPERTY_MARKET_CD, 
		UNIT_ID, 
		ORIGIN_UNIT_ID,
		CLUBCARD_YN,
		CUSTOMER_ID, 
		GUEST_ID, 
		PROP_ID, 
		FIRST_NAME, 
		LAST_NAME, 
		GENDER, 
		EMAIL_ADDRESS, 
		PHONE_NUMBER, 
		AGE,
		CITY_NAME, 
		STATE_PROVINCE_CODE, 
		ZIP_CODE, 
		ZIP_PLUS_4, 
		TIER_CODE,
		HOTEL_FLAG,
		CASINO_FLAG,
		ROOM_NUMBER,
		RESERVATION_NUMBER,
		RESERVATION_AGENT,
		ROOM_TYPE_BOOKED,
		ROOM_TYPE_RECEIVED,
		RATE_PLAN_CD,
		RESERVATION_DATE,
		CHECK_IN_DATE,
		CHECK_OUT_DATE,
		CHECKIN_AGENT_ID,
		CHECKOUT_AGENT_ID,
		WING_CD,
		ROOM_BLOCK_CD,
		HOTEL_COMP_FLAG_YN,
		HOST_NAME,
		HOST_CODE,
		HOSTED_YN,
		ADR,
		--PROPERTY_WINLOSS,
		HOSP_POS_SPEND,
		ROOM_REV_AMT,
		--THEO_AMT
		LOYALTY
		)

	WITH hotel_stays (i_dmid)
	AS (
		-- filter out customers that already are in the hotel
		-- and customers that may be checking in w/in the next 45 days
		-- (Medallia rule) so the hotel stay will take precedence
		SELECT CUSTOMER_ID AS i_dmid
		FROM DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
		GROUP BY CUSTOMER_ID
		UNION
		-- are they already checked in?
		SELECT GUEST_UNIQUE_ID AS i_dmid
		FROM DAAS_CORE_HOTEL_VW.HOTEL_GUEST_RESERVATIONS_FACT_VW
        WHERE :RUNDATE BETWEEN CHECK_IN_DTTM AND DEPARTURE_DT
        AND CHECK_IN_DTTM != ''1899-12-31''
		GROUP BY i_dmid
		UNION
		-- do they have a future reservation within 45 days?
		SELECT GUEST_UNIQUE_ID AS i_dmid
		FROM DAAS_CORE_HOTEL_VW.HOTEL_GUEST_RESERVATIONS_FACT_VW
		WHERE ARRIVAL_DT BETWEEN :RUNDATE AND (DATEADD(DAY, +45, :RUNDATE))
		GROUP BY i_dmid
	),
	casino1 (d_date, i_dmid, guest_id, c_prop_cd, f_theoretical, property_id, slot_machine_nbr, game_type_cd, table_pit_nbr, rNumber)
		AS (
			SELECT dtl.BUSINESS_DT AS d_date, dtl.GUEST_UNIQUE_ID AS i_dmid, dtl.guest_id,
                   dtl.PROPERTY_CD AS c_prop_cd, dtl.THEO_WIN_AMT AS f_theoretical, dtl.property_id, 
			       dtl.slot_machine_nbr, dtl.game_type_cd, dtl.table_pit_nbr,
            ROW_NUMBER() OVER (PARTITION BY dtl.GUEST_UNIQUE_ID ORDER BY dtl.THEO_WIN_AMT DESC ) AS rNumber

			FROM DAAS_CORE_GAMING_VW.RATINGS_FACT_VW dtl
			LEFT OUTER JOIN hotel_stays hs ON dtl.GUEST_UNIQUE_ID = hs.i_dmid
			WHERE hs.i_dmid IS NULL
			AND dtl.BUSINESS_DT = :RUNDATE
		),
	casino_players (d_date, i_dmid, guest_id, c_prop_cd, property_id, slot_machine_nbr, game_type_cd, table_pit_nbr)
		AS (
			SELECT c.d_date, c.i_dmid, c.guest_id, c.c_prop_cd, c.property_id, 
				   slot_machine_nbr, game_type_cd, table_pit_nbr
			FROM casino1 c
			WHERE c.rNumber = 1
            --ERI PROPS
            --AND c_prop_cd NOT IN (''TGV'', ''IBV'', ''ILU'', ''IWA'')
		),
	casino_ids (tranid, d_date, i_dmid, guest_id, c_prop_cd, property_id, slot_machine_nbr, game_type_cd, table_pit_nbr)
	AS (
		SELECT ROW_NUMBER() OVER (PARTITION BY d_date ORDER BY i_dmid) AS tranid,
			d_date, i_dmid, guest_id, c_prop_cd, property_id, slot_machine_nbr, game_type_cd, table_pit_nbr
		FROM casino_players
	),
    hosted_cust
    AS
    (
		SELECT GUEST_UNIQUE_ID, PROPERTY_CD, HOST_CD 
        FROM DAAS_CORE_CUSTOMER_VW.GUEST_XREF_PROP_LOCAL_ACCOUNT_VW
    ),
    casdtl
    AS
    (
        SELECT GUEST_UNIQUE_ID, PROPERTY_CD, HOST_CD
		FROM hosted_cust
		WHERE COALESCE(HOST_CD, '''') <> ''''
		--AND CAST(OPERATION_DATE AS DATE) = :RUNDATE
		GROUP BY GUEST_UNIQUE_ID, PROPERTY_CD, HOST_CD
    )

	SELECT DISTINCT
		''9'' || RIGHT( ''00000000'' || CAST(CASIDS.tranid AS VARCHAR(20)), 8) AS TRANSACTION_ID
	    --CAST(''9'' || RIGHT(CAST(CAST(G.i_dmid AS BIGINT) AS VARCHAR(20)),8) AS VARCHAR(20)) AS TRANSACTION_ID
	    ,CAS.d_date AS TRANSACTION_DATE
		,PROPLKP.MARKET_CD AS PROPERTY_MARKET_CD
		,CAS.c_prop_cd AS UNIT_ID
		,CASE WHEN (TRIM(CAS.c_prop_cd) = ''TAH'' AND CAS.game_type_cd = ''S'' AND DATE(CAS.d_date) >= ''2026-05-14'' AND TRY_TO_NUMBER(LEFT(MACH.SYSTEM_LOCATION, 2)) >= 10)
    		THEN ''HLT''
			WHEN (TRIM(CAS.c_prop_cd) = ''TAH'' AND CAS.game_type_cd = ''P'' AND DATE(CAS.d_date) >= ''2026-05-14'' AND TRY_TO_NUMBER(CAS.table_pit_nbr) >= 10)
			THEN ''HLT''
			ELSE NULL END AS ORIGIN_UNIT_ID
		,CASE WHEN G.GUEST_ACCOUNT_TYPE_CD = ''TRV'' THEN ''Y'' ELSE ''N'' END AS CLUBCARD_YN
		,CAS.I_DMID AS CUSTOMER_ID
        ,G.GUEST_ID AS GUEST_ID
        ,G.PROPERTY_ID AS PROP_ID
		,G.GUEST_FIRST_NM AS FIRST_NAME
		,G.GUEST_LAST_NM AS LAST_NAME
		,COALESCE(G.GUEST_GENDER,'''') AS GENDER
		,COALESCE(EMAIL.GUEST_EMAIL,'''') AS EMAIL_ADDRESS
		,CASE WHEN COALESCE(TEL.TELEPHONE_NBR, ''0'') = ''0'' THEN '''' ELSE CAST(TEL.TELEPHONE_NBR AS VARCHAR(20)) END AS PHONE_NUMBER
        ,CASE WHEN G.GUEST_DATE_OF_BIRTH = ''12/31/1899'' THEN ''N/A'' ELSE CAST(DATEDIFF(DAY, G.GUEST_DATE_OF_BIRTH::DATE, CURRENT_DATE())/365.25 AS INT)::VARCHAR(5) END AS Age
		,COALESCE(ADDR.GUEST_CITY,'''') AS CITY_NAME
		,COALESCE(ADDR.GUEST_STATE_CD,'''') AS STATE_PROVINCE_CODE
		,COALESCE(SUBSTR(ADDR.GUEST_ZIP_CD, 1, 5), '''') AS ZIP_CODE
        ,COALESCE(SUBSTR(ADDR.GUEST_ZIP_CD, 6, 4), '''') AS ZIP_PLUS_4
		,CASE WHEN TIER.TIER_CD = ''DIA'' THEN COALESCE(CONCAT(TIER.TIER_CD, ''-'', SUBTIER.SUBTIER_CD), TIER.TIER_CD) ELSE TIER.TIER_CD END AS TIER_CODE
		,''N'' AS HOTEL_FLAG
		,''Y'' AS CASINO_FLAG
		,'''' AS ROOM_NUMBER
		,'''' AS RESERVATION_NUMBER
		,'''' AS RESERVATION_AGENT
		,'''' AS ROOM_TYPE_BOOKED
		,'''' AS ROOM_TYPE_RECEIVED
		,'''' AS RATE_PLAN_CD
		,'''' AS RESERVATION_DATE
		,'''' AS CHECK_IN_DATE
		,'''' AS CHECK_OUT_DATE
		,'''' AS CHECKIN_AGENT_ID
		,'''' AS CHECKOUT_AGENT_ID
		,'''' AS WING_CD
		,'''' AS ROOM_BLOCK_CD
		,'''' AS HOTEL_COMP_FLAG_YN
		,TRIM(COALESCE(REPS.HOST_NAME,'''')) AS HOST_NAME
		,CASE WHEN COALESCE(REPS.HOST_ID,'''') <> ''''
			THEN TRIM(REPS.PROPERTY_CD) || TRIM(REPS.HOST_ID)
			ELSE '''' END AS HOST_CODE
		,CASE WHEN COALESCE(REPS.HOST_ID,'''') <> ''''
			THEN ''Y''
			ELSE ''N'' END AS HOSTED_YN
		,0 AS ADR
		--,0 AS PROPERTY_WINLOSS
		,0 AS HOSP_POS_SPEND
		,0 AS ROOM_REV_AMT
		--,0 AS THEO_AMT
		,NULL AS LOYALTY
	FROM casino_players CAS
	INNER JOIN casino_ids CASIDS
        ON CAS.i_dmid = CASIDS.i_dmid
        AND CAS.c_prop_cd = CASIDS.c_prop_cd
        AND CAS.d_date = CASIDS.d_date
	INNER JOIN DAAS_CORE.GUEST_DIM AS G
        ON CAS.I_DMID = G.GUEST_UNIQUE_ID
		--AND G.ACTIVE_FLG = ''Y'' --NOT PRESENT IN DEV, CANT DEPLOY WITH THIS FLAG
        AND G.DELETE_IND = ''N''
	--LEFT OUTER JOIN edw_main.gst_personal PERS ON CAS.i_dmid = PERS.i_dmid
	LEFT JOIN DAAS_CORE.GUEST_ADDRESS_DIM ADDR
        ON G.GUEST_UNIQUE_ID = ADDR.GUEST_UNIQUE_ID
        AND G.GUEST_ADDRESS_TYPE = ADDR.GUEST_ADDRESS_TYPE
        AND ADDR.ACTIVE_FLG = ''Y''
        AND ADDR.DELETE_IND = ''N''
	LEFT JOIN DAAS_CORE.GUEST_EMAIL_DIM EMAIL
        ON G.GUEST_UNIQUE_ID = EMAIL.GUEST_UNIQUE_ID
        AND EMAIL.ACTIVE_FLG = ''Y''
		AND EMAIL.DELETE_IND = ''N''
	LEFT JOIN DAAS_CORE.GUEST_TIER_DIM TIER
        ON G.GUEST_UNIQUE_ID = TIER.GUEST_UNIQUE_ID
		AND TIER.DELETE_IND = ''N''
	LEFT JOIN DAAS_CORE.GUEST_SUBTIER_DIM SUBTIER
        ON G.GUEST_UNIQUE_ID = SUBTIER.GUEST_UNIQUE_ID
		AND SUBTIER.DELETE_IND = ''N''
	LEFT JOIN DAAS_CORE.PROPERTY_DIM PROP
        ON CAS.PROPERTY_ID = PROP.PROPERTY_ID
		AND PROP.PROPERTY_ACTIVE_FLAG = ''Y''
		AND PROP.DELETE_IND = ''N''
		--ON CAS.c_prop_cd = PROP.PROPERTY_CD
        --AND PROP.i_prop_market_type_id = 2
	LEFT JOIN DAAS_CORE.GUEST_PROPERTY_MAIL_CODE_DIM MAILCODES
        ON G.GUEST_UNIQUE_ID = MAILCODES.GUEST_UNIQUE_ID
        AND MAILCODES.ACTIVE_FLG = ''Y''
		AND MAILCODES.DELETE_IND = ''N''
    LEFT JOIN DAAS_COMMON.PROPERTY_MARKET_LKP PROPLKP
        ON CAS.c_prop_cd = PROPLKP.PROPERTY_CD
		AND PROPLKP.SECONDARY_MARKET_FLG = ''N''
    LEFT JOIN DAAS_CORE.GUEST_TELEPHONE_DIM TEL
        ON CAS.i_dmid = TEL.GUEST_UNIQUE_ID
        AND G.GUEST_ADDRESS_TYPE = TEL.PHONE_TYPE
        AND TEL.ACTIVE_FLG = ''Y''
        AND TEL.TELEPHONE_NBR != ''''
		AND TEL.DELETE_IND = ''N''
	LEFT JOIN casdtl
        ON CASIDS.i_dmid = casdtl.GUEST_UNIQUE_ID
        AND CASIDS.c_prop_cd = casdtl.PROPERTY_CD
	LEFT JOIN DAAS_CORE.HOST_DIM REPS
        ON casdtl.HOST_CD = REPS.HOST_ID
        AND casdtl.PROPERTY_CD = REPS.PROPERTY_CD
        AND REPS.ACTIVE_FLG = ''Y''
        AND REPS.HOST_ACTIVE_FLG <> ''N''
        AND REPS.DELETE_IND = ''N''
	LEFT JOIN DAAS_CORE_UNRATED_GAMING.MACHINE_DETAILS_DIM_VW MACH
		ON CAS.c_prop_cd = MACH.PROPERTY_CD
		AND CAS.slot_machine_nbr = MACH.MACHINE_NBR
		AND MACH.ACTIVE_FLG = ''Y''


	WHERE ADDR.GUEST_COUNTRY_CD IN (''USA'', ''CAN'')
	AND COALESCE(EMAIL.EMAIL_OPT_IN_FLAG, ''Y'') = ''Y''
	AND COALESCE(MAILCODES.PROPERTY_MAIL_CD, ''100'') < ''300''
    AND COALESCE(PROP.PROPERTY_ACTIVE_FLAG, ''Y'') = ''Y'';


    --WITH hosted_cust
    --AS
    --(
    --    SELECT ROW_NUMBER() OVER (PARTITION BY i_guest_id, i_prop_id, c_prop_cd ORDER BY operation_date desc) AS ROW_NUM,
    --    ROW_ID, I_PROP_ID, I_GUEST_ID, C_PROP_CD, C_REP_ID, OPERATION_DATE, reps.HOST_NAME
    --    FROM DAAS_RAW_PDB.GST_REP_RAW pdb
    --    LEFT JOIN DAAS_CORE.HOST_DIM  reps
    --        ON pdb.c_rep_id = reps.host_id
    --        AND pdb.c_rep_id = reps.HOST_ID
	--        AND pdb.c_prop_cd = reps.PROPERTY_CD
    --        --AND pdb.c_rep_id <> ''''
	--        --AND pdb.c_rep_id IS NOT NULL
    --    WHERE pdb.DELETE_IND != ''Y''
    --)


	--UPDATE med
	--FROM DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE med,
	--hosted_cust dtl, --TODO
	--DAAS_CORE.HOST_DIM REPS
	--SET HOST_CODE = (dtl.c_prop_cd || dtl.c_rep_id),
    --HOSTED_YN = ''Y'',
    --HOST_NAME = REPS.HOST_NAME
	--WHERE med.CUSTOMER_ID = dtl.i_dmid
	--AND med.UNIT_ID = dtl.c_prop_cd
	--AND dtl.c_rep_id = REPS.HOST_ID
	--AND dtl.c_prop_cd = REPS.PROPERTY_CD
	--AND dtl.c_rep_id <> ''''
	--AND dtl.c_rep_id IS NOT NULL
    --AND dtl.ROW_NUM = 1
	--AND med.RESERVATION_NUMBER = '''';

    UPDATE DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE med
    SET med.HOST_CODE = (dtl.PROPERTY_CD || dtl.HOST_CD),
        med.HOSTED_YN = ''Y'',
        med.HOST_NAME = dtl.HOST_NAME
    FROM
    (   SELECT local.GUEST_UNIQUE_ID, local.PROPERTY_CD, local.HOST_CD, reps.HOST_NAME,
        FROM DAAS_CORE_CUSTOMER_VW.GUEST_XREF_PROP_LOCAL_ACCOUNT_VW local
        LEFT JOIN DAAS_CORE.HOST_DIM reps
            ON local.HOST_CD = reps.HOST_ID
	        AND local.PROPERTY_CD = reps.PROPERTY_CD
        WHERE local.HOST_CD <> ''''
	    AND local.HOST_CD IS NOT NULL
    ) dtl
    WHERE med.CUSTOMER_ID = dtl.GUEST_UNIQUE_ID
	AND med.UNIT_ID = dtl.PROPERTY_CD
    AND TRIM(dtl.HOST_CD) != ''''
	AND dtl.HOST_CD IS NOT NULL
	AND med.RESERVATION_NUMBER = '''';
    RETURN ''Updated '' || SQLROWCOUNT || '' rows.'';



--RETURN ''Finished Calling Stored Procedure'';
END';
