# Event Booking Database — Advanced Database Assessment

A PostgreSQL schema for an event ticket-booking system (venues, seats, events,
bookings, payments), with synthetic seed data, indexes, views, functions and
procedures, CRUD and aggregate query examples, and a two-session concurrency
walkthrough. A small MongoDB companion (`mongodb/event-details.js`) holds
category-specific event content that doesn't fit a fixed relational shape.

## Repository layout

| Path | What it is |
|---|---|
| `docs/erd.mmd` | Entity-relationship diagram (Mermaid), including the MongoDB `event_details` collection |
| `sql-files/create-tables.sql` | Tables, constraints, sequences and `updated_at` / booking-status triggers |
| `sql-files/create-indexes.sql` | Secondary indexes (PK/UNIQUE indexes are created by the table script) |
| `sql-files/load-seed-data.sql` | Loads `data/*.csv` via client-side `\copy`, in one transaction |
| `sql-files/functions-and-procedures.sql` | `get_available_seats`, `calculate_booking_total`, `sync_booking_total` trigger, `book_seat`, `book_any_seat`, `book_seat_sql`, `cancel_booking`, `expire_stale_holds` |
| `sql-files/create-views.sql` | `v_event_seat_availability`, `v_booking_details`, `v_customer_directory`, `v_bookable_events`, materialized `mv_venue_sales_summary` |
| `sql-files/crud-examples.sql` | Example INSERT / SELECT / UPDATE / DELETE statements (changes data) |
| `sql-files/aggregate-queries.sql` | GROUP BY, HAVING, FILTER and window-function examples (read-only) |
| `scripts/concurrency-demo.sql` | Optimistic locking, `FOR UPDATE` and `SKIP LOCKED` demos, run across **two** psql sessions |
| `mongodb/event-details.schema.json` | `$jsonSchema` validator for the `event_details` collection (shared by the two files below) |
| `mongodb/event-details.js` | mongosh walkthrough: collection setup, CRUD and aggregations |
| `scripts/sync-event-details.ts` | TypeScript script that seeds MongoDB from `data/event_details.json`, resolving each event's ID from Postgres |
| `data/*.csv` | Synthetic Postgres seed data keyed by natural keys (email, venue/event name, seat row+number) |
| `data/event_details.json` | MongoDB seed data, keyed by venue name + event title |

## Prerequisites

- **PostgreSQL 14 or newer.** The scripts use `CREATE OR REPLACE TRIGGER`, which
  was added in 14. They were tested on 17.
- **`psql`**, the Postgres command-line client. The seed loader uses psql
  meta-commands (`\copy`, `\set`), so it will **not** run in pgAdmin's query
  tool or other GUI editors that don't understand them. The other scripts are
  plain SQL and run in any client.
- *(Optional, for the MongoDB part)* **MongoDB 6+**, **`mongosh`**, and
  **Node.js 22.18+** (or 23.6+) for the seeding script. It's TypeScript, run
  directly by Node's built-in type stripping, so there's no build step.
- *(Optional)* **Docker** if you'd rather not install Postgres locally.

## 1. Set up PostgreSQL

Choose **one** of the options below.

### Option A: Docker (no local install)

From the repository root, start a Postgres 17 container with the repo mounted
at `/work` so `psql` inside the container can read the scripts and CSVs:

```bash
# bash / zsh (macOS, Linux)
docker run -d --name event-booking-pg \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=event_booking \
  -p 5432:5432 \
  -v "$(pwd):/work" \
  postgres:17
```

```powershell
# PowerShell (Windows)
docker run -d --name event-booking-pg `
  -e POSTGRES_PASSWORD=postgres `
  -e POSTGRES_DB=event_booking `
  -p 5432:5432 `
  -v "${PWD}:/work" `
  postgres:17
```

> **Git Bash on Windows:** prefix Docker commands with `MSYS_NO_PATHCONV=1`.
> Otherwise Git Bash rewrites `/work` into a Windows path and Docker fails with
> `Cwd must be an absolute path`.

The container creates the `event_booking` database on first start. For the
steps below, use this `psql` command:

```bash
docker exec -it -w /work event-booking-pg psql -U postgres -d event_booking
```

If port 5432 is already taken by a local Postgres, change `-p 5432:5432` to
`-p 5433:5432`. The port mapping only matters if you also want to connect from
a GUI or a host-installed `psql`.

### Option B: Native install

**Windows**

1. Install PostgreSQL 17 from the
   [EDB installer](https://www.postgresql.org/download/windows/), or run
   `winget install PostgreSQL.PostgreSQL.17`. Keep the default port `5432` and
   note the password you set for the `postgres` superuser.
2. Add the client tools to your `PATH` so `psql` works in any terminal:
   `C:\Program Files\PostgreSQL\17\bin` (then open a new terminal).
3. Check the install: `psql --version`

**macOS (Homebrew)**

```bash
brew install postgresql@17
brew services start postgresql@17
echo 'export PATH="$(brew --prefix postgresql@17)/bin:$PATH"' >> ~/.zshrc
```

Homebrew creates a superuser named after your macOS account, not `postgres`.
Use `-U "$USER"` (or omit `-U`) in the commands below.

**Linux (Debian/Ubuntu)**

```bash
sudo apt install postgresql postgresql-client
sudo systemctl enable --now postgresql
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"
```

**Create the database** (all platforms):

```bash
createdb -h localhost -U postgres event_booking
# or: psql -h localhost -U postgres -c "CREATE DATABASE event_booking;"
```

**Optional: set connection environment variables** so you don't need to repeat
`-h/-U/-d` or type the password each time:

```bash
# bash / zsh
export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=event_booking
```

```powershell
# PowerShell
$env:PGHOST="localhost"; $env:PGPORT="5432"; $env:PGUSER="postgres"
$env:PGPASSWORD="postgres"; $env:PGDATABASE="event_booking"
```

With these set, `psql -f <file>` is enough. The examples below spell out the
flags anyway.

## 2. Build the database

> **Run every command from the repository root.** `load-seed-data.sql` reads the
> CSVs with relative paths (`data/users.csv`, …), which `\copy` resolves against
> psql's working directory.

Run the scripts **in this order**. `-v ON_ERROR_STOP=1` makes psql stop at the
first error instead of continuing past it.

| # | Script | Needs |
|---|---|---|
| 1 | `sql-files/create-tables.sql` | empty database |
| 2 | `sql-files/create-indexes.sql` | 1 |
| 3 | `sql-files/load-seed-data.sql` | 1 |
| 4 | `sql-files/functions-and-procedures.sql` | 1 (examples in it need 3) |
| 5 | `sql-files/create-views.sql` | 1 (the materialized view is populated from what's loaded at this point, so run it after 3) |

**Native psql** (bash / zsh / PowerShell):

```bash
psql -h localhost -U postgres -d event_booking -v ON_ERROR_STOP=1 -f sql-files/create-tables.sql
psql -h localhost -U postgres -d event_booking -v ON_ERROR_STOP=1 -f sql-files/create-indexes.sql
psql -h localhost -U postgres -d event_booking -v ON_ERROR_STOP=1 -f sql-files/load-seed-data.sql
psql -h localhost -U postgres -d event_booking -v ON_ERROR_STOP=1 -f sql-files/functions-and-procedures.sql
psql -h localhost -U postgres -d event_booking -v ON_ERROR_STOP=1 -f sql-files/create-views.sql
```

**Docker** (replace the `psql …` prefix):

```bash
docker exec -w /work event-booking-pg psql -U postgres -d event_booking -v ON_ERROR_STOP=1 -f sql-files/create-tables.sql
# …repeat for the remaining four files, in order
```

The first run of `create-views.sql` prints
`NOTICE: materialized view "mv_venue_sales_summary" does not exist, skipping`.
This is expected: the script drops and recreates that view so it can be re-run.

### Verify the load

```sql
SELECT 'user_profiles' AS table_name, count(*) FROM user_profiles
UNION ALL SELECT 'venues',        count(*) FROM venues
UNION ALL SELECT 'seats',         count(*) FROM seats
UNION ALL SELECT 'events',        count(*) FROM events
UNION ALL SELECT 'event_seats',   count(*) FROM event_seats
UNION ALL SELECT 'bookings',      count(*) FROM bookings
UNION ALL SELECT 'booking_seats', count(*) FROM booking_seats
UNION ALL SELECT 'payments',      count(*) FROM payments;
```

Expected counts:

| user_profiles | venues | seats | events | event_seats | bookings | booking_seats | payments |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 30 | 14 | 100 | 43 | 367 | 108 | 133 | 87 |

`time_zones` is filled from Postgres's own `pg_timezone_names`, so its count
depends on the server's tzdata version (several hundred rows; 487 on the
`postgres:17` Docker image).

Some quick checks against the views and functions:

```sql
SELECT * FROM v_booking_details WHERE booking_reference = 'BK-0001';
SELECT * FROM get_available_seats('Autumn Jazz Night', 'Waterfront Arena');
SELECT venue, confirmed_bookings, revenue FROM mv_venue_sales_summary ORDER BY revenue DESC;
```

## 3. Run the examples

### Aggregate queries (read-only)

```bash
psql -h localhost -U postgres -d event_booking -f sql-files/aggregate-queries.sql
```

Safe to run as often as you like.

### CRUD examples (changes data)

```bash
psql -h localhost -U postgres -d event_booking -f sql-files/crud-examples.sql
```

- Run it **without** `ON_ERROR_STOP`. Two DELETEs are *expected to fail*: they
  show `ON DELETE RESTRICT` blocking the delete of an event and a user that
  still have bookings. psql reports the error and continues with the next
  statement.
- The script inserts a fixed user (`priya.shah@example.com`), cancels
  `BK-0002` and deletes `BK-0005`. It is designed for a freshly seeded
  database. A second run reports extra duplicate-key errors, so
  [reset](#reset--rebuild-from-scratch) before running it again.

### Functions, procedures and views

The callable examples live in comments at the bottom of each section in
`functions-and-procedures.sql` and `create-views.sql`. Copy them into a `psql`
session, for example:

```sql
CALL book_seat('grace.kim@example.com', 'Autumn Jazz Night', 'Waterfront Arena', 'B', '2');
CALL cancel_booking('BK-0001');                       -- refund issued if > 48h before the event
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_venue_sales_summary;
CALL expire_stale_holds();
```

### Concurrency demo (two sessions)

`scripts/concurrency-demo.sql` must **not** be run with `-f`. Each demo
interleaves two transactions. The demos book seats by calling the procedures
from `functions-and-procedures.sql`, so that script must be loaded first
(step 4 of the build).

| Demo | What it shows | Procedure |
|---|---|---|
| 1. Optimistic locking | Two buyers read the same seat version. The slower one's booking fails with `seat Z 99 was changed by another transaction` (SQLSTATE `40001`). | `book_seat(…, p_expected_version)` |
| 2. Pessimistic locking | Terminal 1 locks the seat with `FOR UPDATE`. Terminal 2's booking waits, then fails with `not available`. | `book_seat` |
| 3. `SKIP LOCKED` | Two "any seat" bookings each get a different seat at once, with no waiting. | `book_any_seat` |

1. Open two terminals and start an interactive `psql` in each, against the
   same database:
   ```bash
   psql -h localhost -U postgres -d event_booking
   # Docker: docker exec -it event-booking-pg psql -U postgres -d event_booking
   ```
2. In either terminal, paste the **SETUP / RESET** block. On first run it
   creates a dedicated event, *Concurrency Demo Night*, with two seats
   (`Z-98`, `Z-99`). On later runs it calls `cancel_booking` for any active
   demo bookings, which puts both seats back to `available`.
3. For each demo, paste the `TERMINAL 1` and `TERMINAL 2` sections into the
   matching session, pausing where the script says to.
4. Re-run the SETUP / RESET block between demos.

Demo 1 uses psql's `\gset` to store the version each terminal read. In a
client without `\gset`, replace `:read_version` with the number the `SELECT`
returned.

## 4. MongoDB companion (optional)

Each `event_details` document stores `sql_event_id`, a reference to
`events.event_id` in Postgres. That ID only exists after the Postgres load, so
`data/event_details.json` identifies events by venue name + title (like the
CSVs). `scripts/sync-event-details.ts` looks up the real IDs in Postgres
before writing to MongoDB.

**1. Start MongoDB** (skip if you have it installed locally):

```bash
docker run -d --name event-booking-mongo -p 27017:27017 -v "$(pwd):/work" mongo:7
```

**2. Seed it from Postgres.** Run this after [step 2](#2-build-the-database),
from the repository root:

```bash
npm install
npm run sync:event-details
```

If you edit the script, `npm run typecheck` checks it with `tsc`. Node strips
the types at runtime without checking them.

The script reads Postgres connection settings from the standard `PG*`
environment variables (see [Option B](#option-b-native-install)) and MongoDB
from `MONGODB_URI` (default `mongodb://localhost:27017/event_booking`).
Expected output:

```text
event_details: 3 inserted, 0 updated, 0 unchanged
```

What the script does:

- Creates the collection with the validator from
  `mongodb/event-details.schema.json` and its indexes. If the collection
  already exists, it updates the validator instead.
- Upserts one document per JSON entry, matched on `sql_event_id`. Re-running is
  safe: unchanged documents are skipped, and `updated_at` only changes when
  the content does.
- Checks every entry against Postgres before writing anything. If a venue +
  title doesn't match a Postgres event, it lists the mismatches, writes
  nothing, and exits with code 1.

**3. (Optional) Run the mongosh walkthrough:**

```bash
mongosh "mongodb://localhost:27017/event_booking" mongodb/event-details.js
# Docker:
docker exec -w /work event-booking-mongo mongosh --quiet "mongodb://localhost:27017/event_booking" mongodb/event-details.js
```

> The walkthrough is meant for an **empty** collection
> (`db.event_details.drop()` first). If you run it after the sync, its two
> CREATE inserts hit IDs that are already seeded. Each one prints
> `warning: event_details already has sql_event_id …` and is skipped, and the
> rest of the walkthrough still runs. Its UPDATE steps change the seeded
> Autumn Jazz Night document. Re-run `npm run sync:event-details` afterwards to
> restore the seeded content.

## Reset / rebuild from scratch

The seed loader is not idempotent (unique emails and booking references reject
a second load). To start over, drop and recreate the `public` schema, then run
the five build scripts again:

```bash
psql -h localhost -U postgres -d event_booking -c "DROP SCHEMA public CASCADE;" -c "CREATE SCHEMA public;"
```

Or drop the whole database:

```bash
dropdb -h localhost -U postgres event_booking && createdb -h localhost -U postgres event_booking
```

With Docker, `docker rm -f event-booking-pg` and re-running the
`docker run` command gives you a fresh, empty database.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `psql: command not found` / not recognized | The Postgres `bin` directory isn't on `PATH`. Add it (see [Option B](#option-b-native-install)) and open a new terminal. |
| `could not open file "data/users.csv"` | psql isn't running from the repository root. `cd` there first. |
| `ERROR: unquoted carriage return found in data` | A CSV has **mixed** line endings (some LF, some CRLF), usually after an editor on Windows saved part of it with CRLF. `.gitattributes` makes git check CSVs out as LF, so re-checking them out fixes it: `rm data/*.csv` then `git checkout -- "data/*.csv"`. This discards any uncommitted CSV edits, so check `git status` first. If you've edited a CSV on purpose, re-save it with LF line endings instead. |
| `syntax error at or near "OR"` on `CREATE OR REPLACE TRIGGER` | The server is older than PostgreSQL 14. Upgrade. |
| `relation "…" already exists` / `duplicate key value` on the build scripts | The database isn't empty. [Reset](#reset--rebuild-from-scratch) first. |
| `invalid command \copy` or `\set` | The seed loader was run in a GUI query tool. Run it with `psql -f` instead. |
| `no Postgres event "…" at "…"` from `npm run sync:event-details` | A venue name or title in `data/event_details.json` doesn't exactly match Postgres, or the Postgres seed data hasn't been loaded yet. |
| `MongoDB rejected "…": Document failed validation` | The entry breaks `event-details.schema.json`, for example a `category` outside the allowed values. |
| `password authentication failed for user "postgres"` | Wrong password, or on Homebrew the superuser is your macOS username. Pass `-U` accordingly or set `PGUSER` / `PGPASSWORD`. |
