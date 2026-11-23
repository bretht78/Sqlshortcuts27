"""
DAASI-3811  Medallia Files - Add Luxury Experience Tag
SAMPLE FILES FOR MARLENE, MADE FROM QUERY RESULTS COPIED OUT OF SNOWSIGHT (acceptance criterion 3).
Needs only Python: no Snowflake connector, no extension, no internet.

WHAT IT DOES
  Reads the two query results you pasted into text files, and writes the two sample files next to this program:
    invitation_paste.txt   ->  CaesarsCustomerInvitation_SAMPLE.csv
    prospect_paste.txt     ->  CaesarsProspectInvitation_SAMPLE.csv
  The files come out in the layout of the daily export: header line, | between fields, no quotes, nothing for an
  empty value, UTF-8, LF line ends, LOYALTY as the last column.
  The queries in DAASI-3811_sample_queries.sql already return every line of the file, so this program only undoes
  what copying and pasting can add (a FILE_LINE title, quotes, row numbers, Windows line ends) and checks every
  line before it writes. A file with any problem is not written. It prints counts only, never guest details.

STEPS
  1. In Snowsight, run QUERY 1 of DAASI-3811_sample_queries.sql. The result is one column, FILE_LINE.
     Note the number of rows Snowsight shows for it.
  2. Click the FILE_LINE column header to select the whole column, and press Ctrl+C.
     (If that does not select every row: click the first cell, scroll to the bottom, Shift+click the last cell.)
  3. In VS Code: File > New Text File, press Ctrl+V, and save it as invitation_paste.txt in this program's folder.
  4. Do steps 1 to 3 with QUERY 2, and save that one as prospect_paste.txt.
  5. Open this program in VS Code and select Run Python File (the triangle at the top right).
  6. An OK line means that file is ready. Its row count should be one less than the number Snowsight showed,
     because Snowsight counts the header line as a row. Anything else: it says why, and writes nothing for it.
  7. Delete invitation_paste.txt and prospect_paste.txt.

AFTERWARDS
  These files hold real guest names, email addresses and phone numbers. Send them only the way the team sends such
  files, never in the ticket, an email body or a chat, and delete them from this laptop once Marlene has them.
  What to tell Marlene: one new column, LOYALTY, at the end of both files. It holds LUX on Luxury Experience hotel
  stays and is empty on every other row, so most lines end with a | and nothing after it. No existing column moves
  or changes. The LUX rows are at the top. The files are for checking the layout and a test load, not a live load:
  these guests were already invited for these stays.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
NOT_ALLOWED = (chr(34), chr(92), chr(13), chr(10))          # double quote, backslash, carriage return, line feed
ROW_NUMBER = re.compile(r"^(?:[0-9]*|#)\t")                  # a row number and a tab, if the copy took them along
MIN_ROWS = 50

FILES = [
    dict(label="invitation", paste="invitation_paste.txt", name="CaesarsCustomerInvitation_SAMPLE.csv", lux=3,
         header=("TRANSACTION_ID|TRANSACTION_DATE|PROPERTY_MARKET_CD|UNIT_ID|ORIGIN_UNIT_ID|CLUBCARD_YN|"
                 "CUSTOMER_ID|GUEST_ID|PROP_ID|FIRST_NAME|LAST_NAME|GENDER|EMAIL_ADDRESS|PHONE_NUMBER|AGE|"
                 "CITY_NAME|STATE_PROVINCE_CODE|ZIP_CODE|ZIP_PLUS_4|TIER_CODE|HOTEL_FLAG|CASINO_FLAG|"
                 "ROOM_NUMBER|RESERVATION_NUMBER|ROOM_TYPE_BOOKED|ROOM_TYPE_RECEIVED|RATE_PLAN_CD|"
                 "RESERVATION_DATE|RESERVATION_AGENT|CHECK_IN_DATE|CHECK_OUT_DATE|CHECKIN_AGENT_ID|"
                 "CHECKOUT_AGENT_ID|WING_CD|ROOM_BLOCK_CD|HOTEL_COMP_FLAG_YN|HOST_NAME|HOST_CODE|HOSTED_YN|"
                 "ADR|PROPERTY_WINLOSS|HOSP_POS_SPEND|ROOM_REV_AMT|THEO_AMT|D_ARRIVAL_DT|D_DEPARTURE_DT|"
                 "I_CHECKIN_HR|I_CHECKIN_MIN|LOYALTY")),
    dict(label="prospect", paste="prospect_paste.txt", name="CaesarsProspectInvitation_SAMPLE.csv", lux=2,
         header=("TRANSACTION_ID|TRANSACTION_SOURCE_SYSTEM|TRANSACTION_DATE|PROPERTY_MARKET_CD|UNIT_ID|"
                 "ORIGIN_UNIT_ID|CLUBCARD_YN|PROSPECT_ID|GUEST_ID|PROP_ID|FIRST_NAME|LAST_NAME|GENDER|"
                 "EMAIL_ADDRESS|PHONE_NUMBER|AGE|CITY_NAME|STATE_PROVINCE_CODE|ZIP_CODE|ZIP_PLUS_4|TIER_CODE|"
                 "HOTEL_FLAG|CASINO_FLAG|ROOM_NUMBER|RESERVATION_NUMBER|ROOM_TYPE_BOOKED|ROOM_TYPE_RECEIVED|"
                 "RATE_PLAN_CD|RESERVATION_DATE|RESERVATION_AGENT|CHECK_IN_DATE|CHECK_OUT_DATE|"
                 "CHECKIN_AGENT_ID|CHECKOUT_AGENT_ID|WING_CD|ROOM_BLOCK_CD|HOTEL_COMP_FLAG_YN|HOST_NAME|"
                 "HOST_CODE|HOSTED_YN|ADR|PROPERTY_WINLOSS|HOSP_POS_SPEND|ROOM_REV_AMT|THEO_AMT|D_ARRIVAL_DT|"
                 "D_DEPARTURE_DT|I_CHECKIN_HR|I_CHECKIN_MIN|LOYALTY")),
]


def read_text(path):
    """The pasted file as text, and the encoding it was saved in."""
    data = path.read_bytes()
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        return data.decode("utf-16"), "UTF-16"
    try:
        return data.decode("utf-8-sig"), "UTF-8"
    except UnicodeDecodeError:
        return data.decode("cp1252"), "Windows-1252"


def unwrap(line):
    """A line without the quotes a copy may put around it."""
    if len(line) >= 2 and line.startswith(chr(34)) and line.endswith(chr(34)):
        return line[1:-1].replace(chr(34) * 2, chr(34))
    return line


def clean(text):
    """The lines of the file, from the pasted text: no title, row numbers, quotes, blank lines or trailing blanks.
    A real line never ends in a space or a tab: its last field, LOYALTY, is LUX or nothing after the last |."""
    lines = [line.rstrip(" \t") for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
             if line.strip()]
    if lines and unwrap(lines[0].split("\t")[-1]).strip() == "FILE_LINE":
        lines = lines[1:]
    if lines and all(ROW_NUMBER.match(line) for line in lines):
        lines = [line.split("\t", 1)[1] for line in lines]
    return [unwrap(line) for line in lines]


def problem_in(lines, f):
    """The first way these lines differ from the export layout, or None."""
    fields = f["header"].count("|") + 1
    if not lines:
        return "the pasted file is empty"
    if lines[0] != f["header"]:
        if lines[0].startswith("TRANSACTION_ID|") and lines[0].count("|") + 1 != fields:
            return "the first line is the header of the other file, or part of a header"
        return "the first line is not the header line. Copy the whole column, from its first row"
    if len(lines) < 2:
        return "the paste holds the header line only"
    for number, line in enumerate(lines, 1):
        if line.count("|") + 1 != fields:
            return ("line %d has %d fields, not %d. Was it cut short when copied?"
                    % (number, line.count("|") + 1, fields))
        if any(character in line for character in NOT_ALLOWED):
            return "line %d holds a double quote, a backslash or a line break" % number
        if number > 1 and not (line.endswith("|LUX") or line.endswith("|")):
            return "line %d holds something other than LUX or nothing in LOYALTY" % number
    return None


def main():
    print("DAASI-3811 sample files for Marlene, from pasted query results")
    made, failed = 0, 0
    for f in FILES:
        paste = HERE / f["paste"]
        if not paste.exists():
            print("--  %s: no %s in this folder yet. Skipped." % (f["label"], f["paste"]))
            continue
        try:
            text, encoding = read_text(paste)
        except UnicodeDecodeError:
            print("NO  %s: %s could not be read. Save it again as UTF-8." % (f["label"], f["paste"]))
            failed += 1
            continue
        lines = clean(text)
        problem = problem_in(lines, f)
        if problem:
            print("NO  %s: %s. %s was not written." % (f["paste"], problem, f["name"]))
            failed += 1
            continue
        (HERE / f["name"]).write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
        lux = sum(1 for line in lines[1:] if line.endswith("|LUX"))
        print("OK  %s: header + %d rows, %d fields each, %d tagged LUX"
              % (f["name"], len(lines) - 1, f["header"].count("|") + 1, lux))
        if lux != f["lux"]:
            print("    NOTE: expected %d rows tagged LUX. Tell me the number before you send it." % f["lux"])
        if len(lines) - 1 < MIN_ROWS:
            print("    NOTE: fewer rows than expected. Check the count against Snowsight's; the copy may be short.")
        if encoding == "Windows-1252":
            print("    NOTE: %s was saved as Windows-1252, not UTF-8. Save it as UTF-8" % f["paste"])
            print("          and run this again, so that no accented letter is lost.")
        made += 1
    if made:
        print("Done. Delete %s and %s now." % (FILES[0]["paste"], FILES[1]["paste"]))
    return 1 if failed or not made else 0


if __name__ == "__main__":
    sys.exit(main())
