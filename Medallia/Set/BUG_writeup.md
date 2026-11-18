# Bug: consolidated hotel reservations fact has received no LMS73 data since 10/28

Ready to paste into a new ticket. Evidence and the "done" test are in `evidence_and_done_test.sql`.

**Title:** HOTEL_RESERVATIONS_FACT has had no LMS73 data since 10/28: the stream reads the wrong table

**What is wrong**

`DAAS_CORE_HOTEL.STREAM_LMS73_HOTEL_RESERVATIONS_FACT` is attached to `HOTEL_RESERVATIONS_FACT`. It should be attached to `LMS73_HOTEL_RESERVATIONS_FACT`. It was created that way on 2026-10-28 at 3:17 PM Pacific, the same afternoon the DAASI-3810 deployment rebuilt these tables (1:41 PM).

A stream is Snowflake's running list of the rows that changed in one table since it was last read. The step that copies LMS73 reservations into the consolidated fact (`STG_LMS73_HOTEL_RESERVATIONS_05`) reads this stream. Because the stream now watches the consolidated fact itself, that step sees only the consolidated fact's own handful of new rows and nothing from LMS73. The runs checked still ended in success, with between 0 and 10 rows, so nothing has raised an alert.

**Effect, as of 11/17**

- `HOTEL_RESERVATIONS_FACT` and `HOTEL_RESERVATIONS_VW` hold no LMS73 reservation booked or changed after 10/28. The newest reservation there was booked 10/28. In the LMS73 fact it was booked 11/17.
- None of the roughly 174,500 Loyalty values in the LMS73 fact reached the consolidated fact.
- Anything that reads those two objects is affected. That includes the Loyalty column on the VIP Hotel Guest dashboard (DAASI-3864), which is blank for every reservation.
- Not affected: the LMS73 fact itself and the older `HOTEL_GUEST_RESERVATIONS_FACT` are both current.

**Fix**

1. In Coalesce, set the source of the `STREAM_LMS73_HOTEL_RESERVATIONS_FACT` node back to `LMS73_HOTEL_RESERVATIONS_FACT` and redeploy. Check UAT for the same problem (second statement in the evidence file).
2. A new stream starts empty, so the rows changed since 10/28 will not flow on their own. Either replay them through the pipeline (every LMS73 row that is missing from the consolidated fact, older there, or carrying a Loyalty value that did not arrive), or create the stream once with show-initial-rows on, which sends every current LMS73 row through on the next run (about 29.5 million rows).

**Done when**

Query 2 in `evidence_and_done_test.sql` returns 0 in its last three columns.
