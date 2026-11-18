-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- The two archive tasks, changed in place. PROD. Run as a role that owns the tasks, AFTER the five table scripts.
--
-- Why in place: both archive tasks sit in the middle of a chain (procedures -> archive -> export).
-- ALTER TASK ... MODIFY AS swaps only the statement a task runs. The task, its place in the chain and the
-- export tasks that run after it stay exactly as they are. Snowflake only allows a change to a task in a
-- chain while the first task of that chain is suspended, so the first task of each chain is suspended here
-- and resumed at the end. The other tasks keep their state the whole time.
--
-- When: any time the chains are idle. They start at 09:30 Pacific and finish within a few minutes.
-- If an archive insert fails, the export after it does not run and no file goes to Medallia that day,
-- so the archive tables must already have the LOYALTY column when this runs.
--
-- IF ANY STATEMENT FAILS, STILL RUN STEP 4. A chain whose first task is left suspended does not run at all.

-- 1. Before: look at the "state" column. Every Medallia task should say started.
SHOW TASKS LIKE 'MEDALLIA%' IN SCHEMA DAAS_PROD.DAAS_COMMON;

-- 2. Suspend the first task of each chain.
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_HOTEL_TASK SUSPEND;
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_TASK SUSPEND;

-- 3. Swap the statement each archive task runs (the only change is LOYALTY at the end of both column lists).
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_ARCHIVE_TASK MODIFY AS
INSERT INTO DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE(
        TRANSACTION_ID,
        TRANSACTION_DATE,
        PROPERTY_MARKET_CD,
        UNIT_ID,
        CLUBCARD_YN,
		CUSTOMER_ID,
        GUEST_ID,
        PROP_ID,
        FIRST_NAME,
        LAST_NAME,
        GENDER,
        EMAIL_ADDRESS,
        PHONE_NUMBER,
        Age,
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
		PROPERTY_WINLOSS,
		HOSP_POS_SPEND,
		ROOM_REV_AMT,
		THEO_AMT,
        D_ARRIVAL_DT,
	    D_DEPARTURE_DT,
	    I_CHECKIN_HR,
	    I_CHECKIN_MIN,
        SNOWFLAKE_CREATED_DT,
        BUSINESS_RUN_DATE,
        ORIGIN_UNIT_ID,
        LOYALTY)

        SELECT 
		TRANSACTION_ID,
        TRANSACTION_DATE,
        PROPERTY_MARKET_CD,
        UNIT_ID,
        CLUBCARD_YN,
		CUSTOMER_ID,
        GUEST_ID,
        PROP_ID,
        FIRST_NAME,
        LAST_NAME,
        GENDER,
        EMAIL_ADDRESS,
        PHONE_NUMBER,
        Age,
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
		PROPERTY_WINLOSS,
		HOSP_POS_SPEND,
		ROOM_REV_AMT,
		THEO_AMT,
        D_ARRIVAL_DT,
	    D_DEPARTURE_DT,
	    I_CHECKIN_HR,
	    I_CHECKIN_MIN, 
		CURRENT_TIMESTAMP(), 
		CURRENT_DATE() -1,
        ORIGIN_UNIT_ID,
        LOYALTY
        FROM DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE;

ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK MODIFY AS
INSERT INTO HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
    (
        TRANSACTION_ID
        ,TRANSACTION_SOURCE_SYSTEM
        ,TRANSACTION_DATE
        ,PROPERTY_MARKET_CD
        ,UNIT_ID
        ,CLUBCARD_YN
        ,PROSPECT_ID
        ,GUEST_ID 
        ,PROP_ID
        ,FIRST_NAME
        ,LAST_NAME
        ,GENDER
        ,EMAIL_ADDRESS
        ,PHONE_NUMBER
        ,AGE
        ,CITY_NAME
        ,STATE_PROVINCE_CODE
        ,ZIP_CODE
        ,ZIP_PLUS_4
        ,TIER_CODE
        ,HOTEL_FLAG
        ,CASINO_FLAG
        ,ROOM_NUMBER
        ,RESERVATION_NUMBER
        ,ROOM_TYPE_BOOKED
        ,ROOM_TYPE_RECEIVED
        ,RATE_PLAN_CD
        ,RESERVATION_DATE
        ,RESERVATION_AGENT
        ,CHECK_IN_DATE
        ,CHECK_OUT_DATE
        ,CHECKIN_AGENT_ID   
        ,CHECKOUT_AGENT_ID
        ,WING_CD
        ,ROOM_BLOCK_CD
        ,HOTEL_COMP_FLAG_YN
        ,HOST_NAME
        ,HOST_CODE
        ,HOSTED_YN
        ,ADR
        ,PROPERTY_WINLOSS
        ,HOSP_POS_SPEND
        ,ROOM_REV_AMT
        ,THEO_AMT
        ,D_ARRIVAL_DT
        ,D_DEPARTURE_DT
        ,I_CHECKIN_HR
        ,I_CHECKIN_MIN
        ,CREATED_DTTM
        ,ORIGIN_UNIT_ID
        ,LOYALTY
    )
    SELECT 
        TRANSACTION_ID
        ,TRANSACTION_SOURCE_SYSTEM
        ,TRANSACTION_DATE
        ,PROPERTY_MARKET_CD
        ,UNIT_ID
        ,CLUBCARD_YN
        ,PROSPECT_ID
        ,GUEST_ID
        ,PROP_ID
        ,FIRST_NAME
        ,LAST_NAME
        ,GENDER
        ,EMAIL_ADDRESS
        ,PHONE_NUMBER
        ,AGE
        ,CITY_NAME
        ,STATE_PROVINCE_CODE
        ,ZIP_CODE
        ,ZIP_PLUS_4
        ,TIER_CODE
        ,HOTEL_FLAG
        ,CASINO_FLAG
        ,ROOM_NUMBER
        ,RESERVATION_NUMBER
        ,ROOM_TYPE_BOOKED
        ,ROOM_TYPE_RECEIVED
        ,RATE_PLAN_CD
        ,RESERVATION_DATE
        ,RESERVATION_AGENT
        ,CHECK_IN_DATE
        ,CHECK_OUT_DATE
        ,CHECKIN_AGENT_ID
        ,CHECKOUT_AGENT_ID
        ,WING_CD
        ,ROOM_BLOCK_CD
        ,HOTEL_COMP_FLAG_YN
        ,HOST_NAME
        ,HOST_CODE
        ,HOSTED_YN
        ,ADR
        ,PROPERTY_WINLOSS
        ,HOSP_POS_SPEND
        ,ROOM_REV_AMT
        ,THEO_AMT
        ,D_ARRIVAL_DT
        ,D_DEPARTURE_DT
        ,I_CHECKIN_HR
        ,I_CHECKIN_MIN
        ,CURRENT_TIMESTAMP()
        ,ORIGIN_UNIT_ID
        ,LOYALTY
    FROM HPDB.MEDALLIA_PROSPECT_INVITATION_FILE;

-- 4. Resume the first task of each chain.
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_HOTEL_TASK RESUME;
ALTER TASK DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_TASK RESUME;

-- 5. After: every task that said started in step 1 should say started again.
--    If one does not, this switches a whole chain back on:
--    SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('DAAS_PROD.DAAS_COMMON.MEDALLIA_HOTEL_TASK');
--    SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_TASK');
SHOW TASKS LIKE 'MEDALLIA%' IN SCHEMA DAAS_PROD.DAAS_COMMON;
