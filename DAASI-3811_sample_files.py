"""
DAASI-3811  Medallia Files - Add Luxury Experience Tag
SAMPLE FILES FOR MARLENE, MADE IN VS CODE WITHOUT THE SNOWFLAKE EXTENSION (acceptance criterion 3).

WHAT IT DOES
  Signs in to Snowflake as you, by single sign-on in your browser, runs two read-only queries, and writes two files
  in the same folder as this script:
    CaesarsCustomerInvitation_SAMPLE.csv   from the file sent 11/17 (stays that checked out 11/16), 3 rows tagged LUX
    CaesarsProspectInvitation_SAMPLE.csv   from the file sent 11/07 (transactions of 11/06), 2 rows tagged LUX
  Each holds the header line, that day's LUX rows at the top, and up to 100 ordinary rows, laid out like the
  daily export: | between fields, no quotes, nothing for an empty value, UTF-8, LF line ends, LOYALTY last.
  The queries are the two in DAASI-3811_sample_files_VSCode.sql, unchanged. It changes nothing in Snowflake, and
  it prints counts only, never guest details. Its queries carry this tag in Snowflake's query history, so the pull
  is on record with its purpose:  DAASI-3811 sample files for Medallia (layout check)

BEFORE THE FIRST RUN
  1. In Snowsight, run this and keep the result open:
       SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS ACCOUNT,
              CURRENT_WAREHOUSE() AS WAREHOUSE,
              (SELECT MAX(LOGIN_NAME) FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
               WHERE NAME = CURRENT_USER() AND DELETED_ON IS NULL) AS LOGIN_NAME;
     If Snowflake says the USERS view does not exist or is not authorized, run it without the LOGIN_NAME part.
     Your login name is then the one your Snowflake user was set up with, often your work email.
  2. Copy ACCOUNT and WAREHOUSE into the two settings below, between the quotes. The script asks for LOGIN_NAME
     when it runs, so your login is not saved in this file.

RUN
  3. Open this file in VS Code and select Run Python File (the triangle at the top right of the editor).
     Or open Terminal > New Terminal, go to this folder, and run:  python DAASI-3811_sample_files.py
     (If python is not recognized, use py instead.)
  4. Type LOGIN_NAME when asked. A browser tab opens for single sign-on: finish there, then come back.
     No tab within two minutes means the laptop cannot reach Snowflake at that address: press Ctrl+C.
  5. Two lines starting with OK mean both files are ready. Anything else: it says why, and writes no file.

AFTERWARDS
  These files hold real guest names, email addresses and phone numbers. Send them only the way the team sends such
  files, never in the ticket, an email body or a chat, and delete them from this laptop once Marlene has them.
  What to tell Marlene: one new column, LOYALTY, at the end of both files. It holds LUX on Luxury Experience hotel
  stays and is empty on every other row, so most lines end with a | and nothing after it. No existing column moves
  or changes. The LUX rows are at the top. The files are for checking the layout and a test load, not a live load:
  these guests were already invited for these stays.
"""
import socket
import sys
import warnings
from pathlib import Path

# ---- SETTINGS (step 2) ------------------------------------------------------------------------------------------
ACCOUNT = ""            # ACCOUNT from step 1, for example MYORG-MYACCOUNT
WAREHOUSE = ""          # WAREHOUSE from step 1
ROLE = "DAAS_TEAM"
# -----------------------------------------------------------------------------------------------------------------

QUERY_TAG = "DAASI-3811 sample files for Medallia (layout check)"
HERE = Path(__file__).resolve().parent
NOT_ALLOWED = (chr(34), chr(92), chr(10), chr(13))          # double quote, backslash, line feed, carriage return

INVITATION_SQL = """
WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
SENT AS (
    SELECT IFF(LUX.LOYALTY IS NOT NULL, 1, IFF(NVL(A.RESERVATION_NUMBER, '') <> '', 2, 3)) AS ROW_GROUP,
           ROW_NUMBER() OVER (PARTITION BY IFF(NVL(A.RESERVATION_NUMBER, '') <> '', 2, 3)
                              ORDER BY A.TRANSACTION_ID, A.CUSTOMER_ID) AS PICK,
           NVL(A.TRANSACTION_ID, '') || '|' || NVL(A.TRANSACTION_DATE, '') || '|' ||
           NVL(A.PROPERTY_MARKET_CD, '') || '|' || NVL(A.UNIT_ID, '') || '|' || NVL(A.ORIGIN_UNIT_ID, '') || '|' ||
           NVL(A.CLUBCARD_YN, '') || '|' || NVL(A.CUSTOMER_ID, '') || '|' || NVL(A.GUEST_ID, '') || '|' ||
           NVL(A.PROP_ID, '') || '|' || NVL(A.FIRST_NAME, '') || '|' || NVL(A.LAST_NAME, '') || '|' ||
           NVL(A.GENDER, '') || '|' || NVL(A.EMAIL_ADDRESS, '') || '|' || NVL(A.PHONE_NUMBER, '') || '|' ||
           NVL(A.AGE, '') || '|' || NVL(A.CITY_NAME, '') || '|' || NVL(A.STATE_PROVINCE_CODE, '') || '|' ||
           NVL(A.ZIP_CODE, '') || '|' || NVL(A.ZIP_PLUS_4, '') || '|' || NVL(A.TIER_CODE, '') || '|' ||
           NVL(A.HOTEL_FLAG, '') || '|' || NVL(A.CASINO_FLAG, '') || '|' || NVL(A.ROOM_NUMBER, '') || '|' ||
           NVL(A.RESERVATION_NUMBER, '') || '|' || NVL(A.ROOM_TYPE_BOOKED, '') || '|' ||
           NVL(A.ROOM_TYPE_RECEIVED, '') || '|' || NVL(A.RATE_PLAN_CD, '') || '|' ||
           NVL(A.RESERVATION_DATE, '') || '|' || NVL(A.RESERVATION_AGENT, '') || '|' ||
           NVL(A.CHECK_IN_DATE, '') || '|' || NVL(A.CHECK_OUT_DATE, '') || '|' ||
           NVL(A.CHECKIN_AGENT_ID, '') || '|' || NVL(A.CHECKOUT_AGENT_ID, '') || '|' || NVL(A.WING_CD, '') || '|' ||
           NVL(A.ROOM_BLOCK_CD, '') || '|' || NVL(A.HOTEL_COMP_FLAG_YN, '') || '|' || NVL(A.HOST_NAME, '') || '|' ||
           NVL(A.HOST_CODE, '') || '|' || NVL(A.HOSTED_YN, '') || '|' || NVL(A.ADR, '') || '|' ||
           NVL(A.PROPERTY_WINLOSS, '') || '|' || NVL(A.HOSP_POS_SPEND, '') || '|' || NVL(A.ROOM_REV_AMT, '') || '|' ||
           NVL(A.THEO_AMT, '') || '|' || NVL(A.D_ARRIVAL_DT, '') || '|' || NVL(A.D_DEPARTURE_DT, '') || '|' ||
           NVL(A.I_CHECKIN_HR, '') || '|' || NVL(A.I_CHECKIN_MIN, '') || '|' || NVL(LUX.LOYALTY, '') AS FILE_LINE
    FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE A
    LEFT JOIN LUX
        ON LUX.PROPERTY_CD = A.UNIT_ID
        AND LUX.RESERVATION_ID = TRY_TO_NUMBER(A.RESERVATION_NUMBER)
    WHERE A.SNOWFLAKE_CREATED_DT = (
        SELECT MAX(SNOWFLAKE_CREATED_DT)
        FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE
        WHERE TO_DATE(SNOWFLAKE_CREATED_DT) = '2026-11-17'::DATE
    )
)
SELECT FILE_LINE
FROM (
    SELECT 0 AS ROW_GROUP,
           0 AS PICK,
           'TRANSACTION_ID|TRANSACTION_DATE|PROPERTY_MARKET_CD|UNIT_ID|ORIGIN_UNIT_ID|CLUBCARD_YN|CUSTOMER_ID|' ||
           'GUEST_ID|PROP_ID|FIRST_NAME|LAST_NAME|GENDER|EMAIL_ADDRESS|PHONE_NUMBER|AGE|CITY_NAME|' ||
           'STATE_PROVINCE_CODE|ZIP_CODE|ZIP_PLUS_4|TIER_CODE|HOTEL_FLAG|CASINO_FLAG|ROOM_NUMBER|' ||
           'RESERVATION_NUMBER|ROOM_TYPE_BOOKED|ROOM_TYPE_RECEIVED|RATE_PLAN_CD|RESERVATION_DATE|' ||
           'RESERVATION_AGENT|CHECK_IN_DATE|CHECK_OUT_DATE|CHECKIN_AGENT_ID|CHECKOUT_AGENT_ID|WING_CD|' ||
           'ROOM_BLOCK_CD|HOTEL_COMP_FLAG_YN|HOST_NAME|HOST_CODE|HOSTED_YN|ADR|PROPERTY_WINLOSS|HOSP_POS_SPEND|' ||
           'ROOM_REV_AMT|THEO_AMT|D_ARRIVAL_DT|D_DEPARTURE_DT|I_CHECKIN_HR|I_CHECKIN_MIN|LOYALTY' AS FILE_LINE
    UNION ALL
    SELECT ROW_GROUP, PICK, FILE_LINE
    FROM SENT
    WHERE (ROW_GROUP = 1 OR PICK <= 50)
    AND LENGTH(FILE_LINE) - LENGTH(REPLACE(FILE_LINE, '|', '')) = 48
    AND POSITION(CHAR(34) IN FILE_LINE) = 0
    AND POSITION(CHAR(92) IN FILE_LINE) = 0
    AND POSITION(CHAR(10) IN FILE_LINE) = 0
    AND POSITION(CHAR(13) IN FILE_LINE) = 0
)
ORDER BY ROW_GROUP, PICK
"""

PROSPECT_SQL = """
WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
SENT AS (
    SELECT IFF(LUX.LOYALTY IS NOT NULL, 1, IFF(A.TRANSACTION_SOURCE_SYSTEM = 'HOTEL', 2, 3)) AS ROW_GROUP,
           ROW_NUMBER() OVER (PARTITION BY IFF(A.TRANSACTION_SOURCE_SYSTEM = 'HOTEL', 2, 3)
                              ORDER BY A.TRANSACTION_ID, A.PROSPECT_ID) AS PICK,
           NVL(A.TRANSACTION_ID, '') || '|' || NVL(A.TRANSACTION_SOURCE_SYSTEM, '') || '|' ||
           NVL(A.TRANSACTION_DATE, '') || '|' || NVL(A.PROPERTY_MARKET_CD, '') || '|' || NVL(A.UNIT_ID, '') || '|' ||
           NVL(A.ORIGIN_UNIT_ID, '') || '|' || NVL(A.CLUBCARD_YN, '') || '|' || NVL(A.PROSPECT_ID, '') || '|' ||
           NVL(A.GUEST_ID, '') || '|' || NVL(A.PROP_ID, '') || '|' || NVL(A.FIRST_NAME, '') || '|' ||
           NVL(A.LAST_NAME, '') || '|' || NVL(A.GENDER, '') || '|' || NVL(A.EMAIL_ADDRESS, '') || '|' ||
           NVL(A.PHONE_NUMBER, '') || '|' || NVL(A.AGE, '') || '|' || NVL(A.CITY_NAME, '') || '|' ||
           NVL(A.STATE_PROVINCE_CODE, '') || '|' || NVL(A.ZIP_CODE, '') || '|' || NVL(A.ZIP_PLUS_4, '') || '|' ||
           NVL(A.TIER_CODE, '') || '|' || NVL(A.HOTEL_FLAG, '') || '|' || NVL(A.CASINO_FLAG, '') || '|' ||
           NVL(A.ROOM_NUMBER, '') || '|' || NVL(A.RESERVATION_NUMBER, '') || '|' ||
           NVL(A.ROOM_TYPE_BOOKED, '') || '|' || NVL(A.ROOM_TYPE_RECEIVED, '') || '|' ||
           NVL(A.RATE_PLAN_CD, '') || '|' || NVL(A.RESERVATION_DATE, '') || '|' ||
           NVL(A.RESERVATION_AGENT, '') || '|' || NVL(A.CHECK_IN_DATE, '') || '|' ||
           NVL(A.CHECK_OUT_DATE, '') || '|' || NVL(A.CHECKIN_AGENT_ID, '') || '|' ||
           NVL(A.CHECKOUT_AGENT_ID, '') || '|' || NVL(A.WING_CD, '') || '|' || NVL(A.ROOM_BLOCK_CD, '') || '|' ||
           NVL(A.HOTEL_COMP_FLAG_YN, '') || '|' || NVL(A.HOST_NAME, '') || '|' || NVL(A.HOST_CODE, '') || '|' ||
           NVL(A.HOSTED_YN, '') || '|' || NVL(A.ADR, '') || '|' || NVL(A.PROPERTY_WINLOSS, '') || '|' ||
           NVL(A.HOSP_POS_SPEND, '') || '|' || NVL(A.ROOM_REV_AMT, '') || '|' || NVL(A.THEO_AMT, '') || '|' ||
           NVL(A.D_ARRIVAL_DT, '') || '|' || NVL(A.D_DEPARTURE_DT, '') || '|' || NVL(A.I_CHECKIN_HR, '') || '|' ||
           NVL(A.I_CHECKIN_MIN, '') || '|' || NVL(LUX.LOYALTY, '') AS FILE_LINE
    FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE A
    LEFT JOIN LUX
        ON LUX.PROPERTY_CD = A.UNIT_ID
        AND LUX.RESERVATION_ID = TRY_TO_NUMBER(A.RESERVATION_NUMBER)
    WHERE A.CREATED_DTTM = (
        SELECT MAX(CREATED_DTTM)
        FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
        WHERE TO_DATE(CREATED_DTTM) = '2026-11-07'::DATE
    )
)
SELECT FILE_LINE
FROM (
    SELECT 0 AS ROW_GROUP,
           0 AS PICK,
           'TRANSACTION_ID|TRANSACTION_SOURCE_SYSTEM|TRANSACTION_DATE|PROPERTY_MARKET_CD|UNIT_ID|ORIGIN_UNIT_ID|' ||
           'CLUBCARD_YN|PROSPECT_ID|GUEST_ID|PROP_ID|FIRST_NAME|LAST_NAME|GENDER|EMAIL_ADDRESS|PHONE_NUMBER|AGE|' ||
           'CITY_NAME|STATE_PROVINCE_CODE|ZIP_CODE|ZIP_PLUS_4|TIER_CODE|HOTEL_FLAG|CASINO_FLAG|ROOM_NUMBER|' ||
           'RESERVATION_NUMBER|ROOM_TYPE_BOOKED|ROOM_TYPE_RECEIVED|RATE_PLAN_CD|RESERVATION_DATE|' ||
           'RESERVATION_AGENT|CHECK_IN_DATE|CHECK_OUT_DATE|CHECKIN_AGENT_ID|CHECKOUT_AGENT_ID|WING_CD|' ||
           'ROOM_BLOCK_CD|HOTEL_COMP_FLAG_YN|HOST_NAME|HOST_CODE|HOSTED_YN|ADR|PROPERTY_WINLOSS|HOSP_POS_SPEND|' ||
           'ROOM_REV_AMT|THEO_AMT|D_ARRIVAL_DT|D_DEPARTURE_DT|I_CHECKIN_HR|I_CHECKIN_MIN|LOYALTY' AS FILE_LINE
    UNION ALL
    SELECT ROW_GROUP, PICK, FILE_LINE
    FROM SENT
    WHERE (ROW_GROUP = 1 OR PICK <= 50)
    AND LENGTH(FILE_LINE) - LENGTH(REPLACE(FILE_LINE, '|', '')) = 49
    AND POSITION(CHAR(34) IN FILE_LINE) = 0
    AND POSITION(CHAR(92) IN FILE_LINE) = 0
    AND POSITION(CHAR(10) IN FILE_LINE) = 0
    AND POSITION(CHAR(13) IN FILE_LINE) = 0
)
ORDER BY ROW_GROUP, PICK
"""

FILES = [
    dict(label="invitation", name="CaesarsCustomerInvitation_SAMPLE.csv", sql=INVITATION_SQL, fields=49, lux=3),
    dict(label="prospect", name="CaesarsProspectInvitation_SAMPLE.csv", sql=PROSPECT_SQL, fields=50, lux=2),
]

NOT_INSTALLED = """Snowflake's connector for Python is not installed for the Python running this script:
    {python}
Nothing was changed. Two options:
  - If VS Code has another Python, pick it (Ctrl+Shift+P, then Python: Select Interpreter) and run this again.
  - Installing the connector downloads it from the internet (pip install snowflake-connector-python).
    Check with your team or IT that this is allowed before you do it."""

SIGN_IN_HELP = """Common causes:
  - "differs from the user currently logged in": the login name is wrong. Use LOGIN_NAME from step 1.
  - could not connect, or a name that does not resolve: check ACCOUNT, and that you are on the company network.
  - "certificate verify failed": the network is inspecting the connection. Ask IT; do not switch the check off."""

QUERY_HELP = """Common causes:
  - "No active warehouse": check WAREHOUSE.
  - "does not exist or not authorized": check that ROLE is DAAS_TEAM."""


def account_for(value):
    """The account to connect to, through the company's private link when that address resolves on this network."""
    name = value.strip().lower()
    for prefix in ("https://", "http://"):
        if name.startswith(prefix):
            name = name[len(prefix):]
    name = name.split("/")[0]
    suffix = ".snowflakecomputing.com"
    if name.endswith(suffix):
        name = name[:-len(suffix)]
    if name.endswith(".privatelink"):
        return name
    for candidate in dict.fromkeys((name, name.replace("_", "-"))):
        try:
            socket.getaddrinfo(candidate + ".privatelink" + suffix, 443)
            return candidate + ".privatelink"
        except OSError:
            pass
    return name


def one_line(error):
    return " ".join(str(error).split())


def problem_in(lines, f):
    """The first way these lines differ from the export layout, or None."""
    if not lines or not isinstance(lines[0], str):
        return "the query returned nothing"
    if not (lines[0].startswith("TRANSACTION_ID|") and lines[0].endswith("|LOYALTY")):
        return "the first line is not the header line"
    if len(lines) < 2:
        return "the query found no rows for that day"
    for number, line in enumerate(lines, 1):
        if not isinstance(line, str):
            return "line %d is empty" % number
        if line.count("|") + 1 != f["fields"]:
            return "line %d has %d fields, not %d" % (number, line.count("|") + 1, f["fields"])
        if any(character in line for character in NOT_ALLOWED):
            return "line %d holds a double quote, a backslash or a line break" % number
        if number > 1 and not (line.endswith("|LUX") or line.endswith("|")):
            return "line %d holds something other than LUX or nothing in LOYALTY" % number
    return None


def main():
    print("DAASI-3811 sample files for Marlene")
    try:
        import snowflake.connector
    except ImportError:
        print(NOT_INSTALLED.format(python=sys.executable))
        return 1
    if not ACCOUNT.strip() or not WAREHOUSE.strip():
        print("Fill in ACCOUNT and WAREHOUSE at the top of this file (step 2), save it, and run it again.")
        return 1
    account = account_for(ACCOUNT)
    login = input("LOGIN_NAME from step 1: ").strip()
    if not login:
        print("No login name given. Run it again and type LOGIN_NAME from step 1.")
        return 1
    warnings.filterwarnings("ignore", category=FutureWarning)      # a notice from newer connectors; no effect here
    print("Signing in to %s.snowflakecomputing.com as role %s." % (account, ROLE))
    print("Finish the sign-in in the browser tab that opens. No tab within two minutes: press Ctrl+C.")
    try:
        connection = snowflake.connector.connect(
            account=account,
            user=login,
            authenticator="externalbrowser",
            role=ROLE,
            warehouse=WAREHOUSE.strip(),
            session_parameters={"QUERY_TAG": QUERY_TAG},
        )
    except Exception as error:
        print("Could not sign in: " + one_line(error))
        print(SIGN_IN_HELP)
        return 1
    results = []
    try:
        for f in FILES:
            print("Running the %s query..." % f["label"])
            try:
                cursor = connection.cursor()
                cursor.execute(f["sql"])
                lines = [row[0] for row in cursor.fetchall()]
            except Exception as error:
                print("The %s query failed: %s" % (f["label"], one_line(error)))
                print(QUERY_HELP)
                return 1
            problem = problem_in(lines, f)
            if problem:
                print("STOPPED. The %s sample is not in the export layout: %s." % (f["label"], problem))
                print("No file was written. Send me this line.")
                return 1
            results.append((f, lines))
    finally:
        connection.close()
    for f, lines in results:
        (HERE / f["name"]).write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
        lux = sum(1 for line in lines[1:] if line.endswith("|LUX"))
        print("OK  %s: header + %d rows, %d fields each, %d tagged LUX"
              % (f["name"], len(lines) - 1, f["fields"], lux))
        if lux != f["lux"]:
            print("    NOTE: expected %d rows tagged LUX. The file is fine; tell me the number before you send it."
                  % f["lux"])
    print("Both files are in the same folder as this script.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        print("Stopped. If it stopped while signing in, send me what it printed above.")
        sys.exit(1)
