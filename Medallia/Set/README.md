# DAASI-3811: Medallia Files - Add Luxury Experience Tag

Adds one column, `LOYALTY`, to the end of both daily Medallia files. It holds `LUX` on Luxury Experience hotel stays and is empty on every other row: hotel stays without the tag, gaming-only rows, and prospect rows that are not hotel stays.

Built 2026-11-17 from the deployed code. **Nothing here has been run in Snowflake.** The dry runs in `validation/1_before_deploy.sql` are the first real run of the new queries.

## What is in here

| Folder | File | What it is |
|---|---|---|
| `procedures/` | `MEDALLIA_V_CUSTOMER_INVITATION_HOTEL_PROC.sql` | Full file. Looks the tag up once per reservation and loads it. 18 lines added, 2 changed. |
| | `MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC.sql` | Full file. Carries the tag on hotel rows, NULL on gaming-only rows. 5 lines added, 4 changed. |
| | `MEDALLIA_PROSPECT_INVITATION_FILE_PROC.sql` | Full file. Same lookup, tag on hotel rows only. 14 lines added, 1 changed. |
| `tables/` | five files | Pete's form: `BEGIN`, `CREATE TABLE IF NOT EXISTS` as the table stood, `ALTER TABLE ... ADD COLUMN` at the bottom, `END`. |
| `tasks/` | `MEDALLIA_ARCHIVE_TASK.sql`, `MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK.sql` | The two archive task definitions with LOYALTY added, in repo form. |
| | `change_archive_tasks_in_place_PROD.sql`, `..._UAT.sql` | The same change made with `ALTER TASK ... MODIFY AS`. See "Archive tasks" below. |
| `validation/` | `1_before_deploy.sql` | Four read-only checks to run before deploying. |
| | `2_ticket_proof.sql` | The four proof queries for the ticket. |
| `sample_for_marlene/` | `sample_files.sql` | Builds both sample files. Needs no deploy. |
| `stream_bug/` | `BUG_writeup.md`, `evidence_and_done_test.sql` | The separate defect found on the way. Not part of this ticket's deploy. |
| (top level) | `what_changed.diff` | Every line that differs from the deployed procedures and tasks, for the reviewer. |

The procedure and table files carry no database name, and the task files use `{{$ENV}}`. If these objects already have files in daas-snowflake, paste these over them; the diff should show only the LOYALTY lines.

## Order of work

1. **Now:** run PROOF 1 in `validation/2_ticket_proof.sql`, build the two sample files, get them to Marlene. Nothing has to be deployed for this, so she can validate while the code is in review.
2. Run `validation/1_before_deploy.sql`.
3. **UAT:** tables, then procedures, then tasks. Then call each procedure once to see it finish:
   ```sql
   USE DATABASE DAAS_UAT;
   CALL DAAS_COMMON.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL_PROC(CURRENT_DATE() - 1);
   CALL DAAS_COMMON.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC(CURRENT_DATE() - 1);
   CALL HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_PROC(CURRENT_DATE() - 1);
   ```
   UAT may hold few or no LUX reservations, so this shows the code runs, not that tags appear. PROOF 2 to 4 work in UAT with `DAAS_PROD` changed to `DAAS_UAT`.
4. **PROD, after Marlene's OK,** in one window away from the 09:30 Pacific run: tables, then procedures, then tasks.
5. **Next morning,** after the 09:30 run: PROOF 2, 3 and 4.

Why the order matters:

- **The file changes shape the first run after the tables get the column.** The export is `SELECT *` with a header row, so the new column appears in the file as soon as it exists in the table, whatever else has or has not been deployed. That is why the PROD tables wait for Marlene.
- **Tables before procedures and tasks.** The new procedures and archive inserts name `LOYALTY`. If they run before the tables have it, the run fails and no file goes to Medallia that day.
- **Option, if you want to split the risk:** deploy only the tables first. The next file gains an empty `LOYALTY` column and nothing else changes, because every insert names its columns. Deploy procedures and tasks a day later and the values start to flow.

Rolling back: redeploy the previous procedures and tasks. The column can stay, empty. To put the files back to the old layout as well, drop `LOYALTY` from the two file tables (`MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE`, `MEDALLIA_PROSPECT_INVITATION_FILE`).

## Archive tasks: two ways to deploy, pick one

Both archive tasks sit in the middle of a chain: procedures, then archive, then export.

- **In place (`change_archive_tasks_in_place_*.sql`).** `ALTER TASK ... MODIFY AS` swaps only the statement the task runs. The task and the export tasks behind it are untouched. This is the one I would use.
- **Repo form (`CREATE OR REPLACE TASK`).** Snowflake's documentation says a recreated task comes back suspended, and it does not say whether the tasks that run after it stay attached. A dropped task does lose them. If the 11/11 ORIGIN_UNIT_ID change to these same tasks went through the repo this way and the exports kept running, the pipeline already handles it; use that route and check afterwards that every Medallia task shows `started` and the export tasks still list the archive task as their predecessor.

## Choices made, and how to change each

1. **One column, named `LOYALTY`, last in all five tables.** The header in the file is the column name.
2. **Only approved codes pass. Today that is `LUX`.** The LMS Loyalty field is typed by hand. 174,540 reservations have something in it, under 54 different codes; 269 of those reservations are `LUX`, 171,622 are `CZR`, and 26 codes appear on three reservations or fewer. If Medallia treats "not empty" as "Luxury Experience", passing everything would mark all 174,540. With the list, not empty and Luxury Experience mean the same thing.
   - To add a code: extend `IN (''LUX'')` in the hotel and prospect procedures (one line each), and the same line in the proof queries.
   - To pass every code instead: replace that line with `AND TRIM(LOYALTY) <> ''''` in both procedures.
3. **`LOYALTY_DESC` is not sent.** It is free text. On other codes it holds membership numbers, and on a few rows what look like typed ID numbers.
4. **The tag is read from `DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT`.** It is current and has one row per reservation. The consolidated `HOTEL_RESERVATIONS_FACT` has had no LMS73 rows since 10/28 (see `stream_bug/`). Once that is fixed the lookup can point at either; nothing forces a change.
5. **The original hotel fact stays the driver** (answers Andrew's question). Switching to the Coalesce version would drop rows (it matched 100% until 10/28, then fell to 52%) and it has no `GUEST_UNIQUE_ID`. A union adds nothing: no reservation exists only in the Coalesce version. So the tag is joined on, by property and reservation, and no row is added or removed.
6. **Gaming-only rows and non-hotel prospect rows get NULL,** as the ticket asks.

Left alone on purpose: the export procedure (it is `SELECT *`), and `DAAS_CORE_SURVEY_VW.V_MEDALLIA_CUSTOMER_INVITATION`, which lists its columns and did not take ORIGIN_UNIT_ID either. Add `LOYALTY` there if analysts want it.

## To confirm

1. **Is `LUX` the only code that means Luxury Experience?** 269 reservations carry it. About 20 more, all arriving since late October, carry the same style of description as the LUX rows (starting `ACR-`) under what look like property codes instead (LAU, IWA, GBI and six others). If those are Luxury Experience stays keyed differently, the properties correct the code or we add a rule.
2. **Header name.** `LOYALTY` unless Marlene wants something else.
3. **Repo.** Do these procedures, tables and tasks already have files in daas-snowflake, and is `{{$ENV}}` written the way the task files here assume?
4. **How the archive tasks were changed on 11/11.** Use the same route (see above).
5. **CHECK 1 result for the prospect procedure.** Both pulls of it came back with a UAT header, so the new file is built on the UAT text. CHECK 1 shows whether PROD holds the same text.
6. **CHECK 2 result.** The role that owns the tasks must be able to read the LMS73 fact. The procedures do not read anything in `DAAS_CORE_HOTEL` today.

Two things outside this ticket:

- `LOYALTY_DESC` should be handled as PII wherever it is exposed: `LMS73_HOTEL_RESERVATIONS_FACT`, `HOTEL_RESERVATIONS_FACT`, `HOTEL_RESERVATIONS_VW`. The round 3 results file contains some of those values, so keep that file off the ticket.
- The table scripts leave out the governance tags that `GET_DDL` shows on the existing columns. The tables already exist in both environments, so `CREATE TABLE IF NOT EXISTS` does nothing and the tags stay as they are. `LOYALTY` holds a program code and gets no tag.

## How this was checked

- Each procedure and task was diffed against the deployed text (`what_changed.diff`). Only the LOYALTY lines and the header lines differ.
- Every `INSERT` was parsed and its column list counted against its `SELECT`: 47 and 47 (hotel), 47 and 47 and 43 and 43 (complete), 50 and 50 (prospect), 51 and 51 (both archive tasks). Every named select item sits in the same position as its column.
- The lookup and both joins were run on mock rows: a padded code, a deleted row, two rows for one reservation, a code that is not approved, the same reservation number at another property, and a non-hotel prospect row sharing a number with a tagged reservation. Row counts did not change and only the right rows were tagged.
- The four proof queries, the sample queries and the stream query were run on mock tables, including two planted errors that PROOF 3 caught.
- Not checked: anything that needs Snowflake. That is what `1_before_deploy.sql` is for.

## Ticket comment, ready to paste

> **Update 11/17**
> - Confirmed: the LMS73 reservations fact is current and holds the tag (269 reservations coded LUX). The consolidated Coalesce fact stopped receiving LMS73 rows on 10/28. Cause found; separate ticket.
> - Change: one new column, LOYALTY, at the end of both files. LUX on Luxury Experience hotel stays, empty otherwise. The original hotel fact stays the driver and the tag is joined on from the LMS73 fact. Both archive tasks updated.
> - Next: sample files to Marlene (built from a day already sent, so no deploy needed), then UAT, then PROD after her OK.
> - Open: is LUX the only code that means Luxury Experience?
