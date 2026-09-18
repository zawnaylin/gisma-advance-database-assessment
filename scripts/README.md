# scripts

| File | What it does |
|---|---|
| [`concurrency-demo.sql`](concurrency-demo.sql) | Walks through three concurrency-control techniques, using two interleaved psql sessions |
| [`sync-event-details.ts`](sync-event-details.ts) | Seeds MongoDB's `event_details` collection, resolving each event's ID from Postgres |

Run everything from the **repository root**. For the database build steps,
see the [main README](../README.md).

---

## `concurrency-demo.sql`

This script demonstrates three ways to stop two buyers from getting the same
seat. It uses the same procedures an application would call
(`book_seat`, `book_any_seat`, `cancel_booking` from
`sql-files/functions-and-procedures.sql`), not hand-written UPDATEs.

### How to run

Don't run it with `psql -f`. Each demo needs two transactions to overlap.

1. Build the database, **including** `functions-and-procedures.sql`.
2. Open two `psql` sessions on the same database: *Terminal 1* and
   *Terminal 2*.
3. Paste the **SETUP / RESET** block into either terminal.
4. For each demo, paste the `TERMINAL 1` and `TERMINAL 2` sections into
   the matching session, stopping at each `PAUSE`. The order in which you
   switch between terminals is what the demo shows.
5. Re-run SETUP / RESET before each demo.

**Why the pauses sit between statements:** a `CALL` runs start to finish,
so it can't pause halfway. Each demo therefore opens `BEGIN` and pauses
*between* statements. Any row locks a `CALL` takes inside that transaction
are held until `COMMIT`, and those held locks are what the other terminal
runs into.

### SETUP / RESET

- **Demo event:** creates *Concurrency Demo Night* at Waterfront Arena, with
  only seats **Z-98** and **Z-99**. The demo can't disturb seed data or other
  scripts' bookings, and `book_any_seat` in Demo 3 has only these two seats
  to choose from.
- **Safe to re-run:** seats and event seats use `ON CONFLICT DO NOTHING`.
  The event uses `NOT EXISTS`, because `(venue, title)` has no unique
  constraint for `ON CONFLICT` to target.
- **Reset:** calls `cancel_booking` for any active demo booking, which frees
  the seats. Cancelled bookings stay as history. The partial unique index
  `uq_booking_seats_active_event_seat` only counts *active* claims, so they
  don't block rebooking.
- **Seat versions:** `event_seats.version` goes up on every hold and release,
  so it keeps growing across runs. The exact number doesn't matter; the two
  terminals only need to read the same value.

### Demo 1: optimistic locking

Both terminals read seat Z-99's `version` (via psql's `\gset`), then both
call `book_seat(…, :read_version)`.

- **Terminal 2 blocks.** Postgres still locks the row, so the second
  update waits for Terminal 1.
- **After Terminal 1 commits,** Terminal 2's update re-checks its `WHERE`
  against the updated row, finds the version has changed, and matches
  nothing. `book_seat` raises
  `seat Z 99 was changed by another transaction` with SQLSTATE `40001`
  (`serialization_failure`) and a hint to retry.
- **What this guarantees:** not that nobody ever waits, but that a writer
  working from stale data can never overwrite the winner without anyone
  noticing.
- **Retrying** after a fresh read fails with `not available`. The seat is now
  taken, not just changed since the read.

Without `\gset` (in a GUI client, for example), replace `:read_version` with
the number the `SELECT` returned.

### Demo 2: pessimistic locking

Terminal 1 locks the seat with `SELECT … FOR UPDATE` *before* booking it,
as if the buyer were on the payment page.

- **Terminal 2's `book_seat` blocks** as soon as it touches the row, even
  though Terminal 1 hasn't written anything yet.
- **Terminal 1 books and commits.** Holding the lock guarantees it succeeds.
- **Terminal 2 then unblocks** and fails with `not available`. Had Terminal 1
  rolled back instead, Terminal 2 would have got the seat.

The lock is the one hand-written step, because a procedure can't pause
mid-call while the buyer decides.

**Compared with Demo 1:** this is simpler to reason about and the lock
holder always wins. The cost is that a slow first transaction makes everyone
else wait on that row.

### Demo 3: `SKIP LOCKED`

The ticket-queue case: "give me any seat". `book_any_seat` picks the first
available seat using `FOR UPDATE OF es SKIP LOCKED`.

- **Terminal 1** gets Z-98 and holds it, without committing.
- **Terminal 2 returns immediately with Z-99.** `SKIP LOCKED` passes over the
  seat Terminal 1 has locked instead of waiting for it.
- **A third buyer** gets `no available seat` straight away rather than
  waiting.

`OF es` matters here. A plain `FOR UPDATE` on this join would also lock the
event's row, which every seat shares. A second buyer would then skip every
seat and wrongly be told none were free.

---

## `sync-event-details.ts`

This script seeds MongoDB's `event_details` collection from
`data/event_details.json`, filling in each document's `sql_event_id` from
Postgres.

```bash
npm install
npm run sync:event-details   # after the Postgres seed load
npm run typecheck            # after editing the script
```

### Why a script

`event_details.json` identifies events by **venue name + event title**, like
`data/*.csv`. `events.event_id` is an identity column: it only exists once
Postgres assigns it during the load, and nothing guarantees it follows CSV
row order. `mongoimport` can't turn a natural key into that ID. Only a
script that connects to both databases can.

### Configuration

| Database | Setting |
|---|---|
| Postgres | Standard `PG*` variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`), read by the `pg` driver |
| MongoDB | `MONGODB_URI`, default `mongodb://localhost:27017/event_booking` |

### What it does

1. **Resolves** every entry's `(venue_name, event_title)` to an `event_id`.
   If any entry doesn't match exactly one Postgres event, or appears twice
   in the JSON, it lists every problem and exits with code 1 **before writing
   anything**.
2. **Sets up the collection:** creates `event_details` with the validator
   from `mongodb/event-details.schema.json` and the `sql_event_id` (unique),
   `category` and `tags` indexes. If the collection already exists, it
   updates the validator instead (`collMod`).
3. **Upserts** by `sql_event_id`, stored as a BSON `int`, which the validator
   requires.
   - A document whose content is unchanged is skipped, so `updated_at` only
     changes when something actually changed.
   - `created_at` is set only when a document is first inserted.
   - Re-running is safe.
4. **Reports** `N inserted, N updated, N unchanged`.

**If MongoDB rejects a document** (for example a category outside the
schema's allowed values), the error names the entry. The upserts run in
order, so entries before it are already written. Fix the entry and re-run.

### Running TypeScript without a build step

Node 22.18+ / 23.6+ runs `.ts` files directly by *stripping* the types, and
it doesn't check them. Two consequences:

- **`npm run typecheck`** runs `tsc` (with `noEmit`) to do the actual type
  checking.
- **Some TypeScript features aren't allowed:** type stripping can only
  delete type annotations, not rewrite code, so `enum`, `namespace` and
  constructor parameter properties won't run. `tsconfig.json` turns on
  `erasableSyntaxOnly`, which rejects them at typecheck time.
