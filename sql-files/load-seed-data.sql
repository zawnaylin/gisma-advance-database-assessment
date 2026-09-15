-- Load synthetic demo data from data/*.csv into the schema in create-tables.sql.
--
-- Run from the repository root:
--   psql -d <your_database> -f data/load-seed-data.sql
--
-- Safe by construction:
--   * ON_ERROR_STOP aborts the whole script on the first error instead of limping on.
--   * Everything runs in one transaction: a bad row anywhere rolls back the entire load.
--   * CSVs carry natural keys (email, venue/event name, seat row+number), never surrogate
--     IDs -- those don't exist until the parent row is inserted. Child inserts resolve
--     them by JOINing staging data to the already-inserted parent table.
--   * Every INSERT ... SELECT still goes through the real tables' constraints/triggers,
--     so this is exactly as strict as a hand-written INSERT would be.

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- Staging tables: unconstrained, natural-key columns only, dropped with the
-- transaction (TEMP + no COMMIT-crossing needed since it's all one script).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE staging_users (
    name VARCHAR(100), email VARCHAR(255), role VARCHAR(20)
);

CREATE TEMP TABLE staging_venues (
    name VARCHAR(150), address VARCHAR(255), city VARCHAR(100),
    total_capacity INTEGER, time_zone VARCHAR(64)
);

CREATE TEMP TABLE staging_seats (
    venue_name VARCHAR(150), seat_row VARCHAR(10), seat_number VARCHAR(10), seat_tier VARCHAR(30)
);

CREATE TEMP TABLE staging_events (
    venue_name VARCHAR(150), title VARCHAR(200),
    starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ, status VARCHAR(20)
);

CREATE TEMP TABLE staging_event_seats (
    venue_name VARCHAR(150), event_title VARCHAR(200),
    seat_row VARCHAR(10), seat_number VARCHAR(10), price NUMERIC(10, 2)
);

CREATE TEMP TABLE staging_bookings (
    booking_reference VARCHAR(20), user_email VARCHAR(255), venue_name VARCHAR(150),
    event_title VARCHAR(200), status VARCHAR(20), total_amount NUMERIC(10, 2)
);

-- booking_reference here is a foreign reference back to staging_bookings /
-- the real bookings row, the same way venue_name is a foreign reference to
-- venues -- not itself a fresh piece of data.
CREATE TEMP TABLE staging_booking_seats (
    booking_reference VARCHAR(20), venue_name VARCHAR(150), event_title VARCHAR(200),
    seat_row VARCHAR(10), seat_number VARCHAR(10)
);

CREATE TEMP TABLE staging_payments (
    booking_reference VARCHAR(20), amount NUMERIC(10, 2),
    payment_method VARCHAR(30), status VARCHAR(20), paid_at TIMESTAMPTZ
);

-- ---------------------------------------------------------------------------
-- Client-side load. \copy streams from wherever psql is invoked -- no server
-- filesystem access needed, unlike the server-side COPY command.
-- ---------------------------------------------------------------------------
\copy staging_users         FROM 'data/users.csv'         WITH (FORMAT csv, HEADER true)
\copy staging_venues        FROM 'data/venues.csv'        WITH (FORMAT csv, HEADER true)
\copy staging_seats         FROM 'data/seats.csv'         WITH (FORMAT csv, HEADER true)
\copy staging_events        FROM 'data/events.csv'        WITH (FORMAT csv, HEADER true)
\copy staging_event_seats   FROM 'data/event_seats.csv'   WITH (FORMAT csv, HEADER true)
\copy staging_bookings      FROM 'data/bookings.csv'      WITH (FORMAT csv, HEADER true)
\copy staging_booking_seats FROM 'data/booking_seats.csv' WITH (FORMAT csv, HEADER true)
\copy staging_payments      FROM 'data/payments.csv'      WITH (FORMAT csv, HEADER true)

-- ---------------------------------------------------------------------------
-- Insert in FK dependency order. Each step resolves the parent's surrogate
-- key by joining on the natural key the CSV actually carries.
-- ---------------------------------------------------------------------------

-- Full IANA tz database, sourced live from Postgres's own catalog rather
-- than a hand-typed CSV -- always matches whatever tzdata version this
-- server actually has, and can't go stale or contain a typo the way a
-- static list of ~600 names could.
INSERT INTO time_zones (name)
SELECT name FROM pg_timezone_names
ON CONFLICT (name) DO NOTHING;

INSERT INTO user_profiles (name, email, role)
SELECT name, email, role FROM staging_users;

INSERT INTO venues (name, address, city, total_capacity, time_zone)
SELECT name, address, city, total_capacity, time_zone FROM staging_venues;

INSERT INTO seats (venue_id, seat_row, seat_number, seat_tier)
SELECT v.venue_id, s.seat_row, s.seat_number, s.seat_tier
FROM staging_seats s
JOIN venues v ON v.name = s.venue_name;

INSERT INTO events (venue_id, title, starts_at, ends_at, status)
SELECT v.venue_id, e.title, e.starts_at, e.ends_at, e.status
FROM staging_events e
JOIN venues v ON v.name = e.venue_name;

INSERT INTO event_seats (event_id, seat_id, price, status)
SELECT ev.event_id, s.seat_id, x.price, 'available'
FROM staging_event_seats x
JOIN venues v  ON v.name = x.venue_name
JOIN events ev ON ev.venue_id = v.venue_id AND ev.title = x.event_title
JOIN seats s   ON s.venue_id = v.venue_id
              AND s.seat_row = x.seat_row AND s.seat_number = x.seat_number;

-- confirmed_at / cancelled_at set explicitly here: set_booking_status_timestamps()
-- only fires on UPDATE, not on the initial INSERT, so a row seeded directly as
-- 'confirmed'/'cancelled' needs its timestamp supplied up front or the
-- chk_bookings_confirmed_at / chk_bookings_cancelled_at checks reject it.
--
-- Every row here represents a booking migrated from the pre-database
-- spreadsheet, where staff related rows across sheets by a reference like
-- "BK-0001" -- exactly the value the CSV carries. That value becomes both
-- the live booking_reference and the legacy_source_ref audit pointer: today
-- they're identical, but booking_reference is free to be edited later
-- (support correction, reformat) while legacy_source_ref is meant to stay
-- the untouched historical record. Bookings created by the app after this
-- migration never appear here -- they get booking_reference from the
-- column's own DEFAULT (a distinct 'BKE-' prefix, see create-tables.sql),
-- and legacy_source_ref stays NULL for them, as it should.
INSERT INTO bookings (user_id, event_id, status, total_amount,
                       booking_reference, legacy_source_ref, confirmed_at, cancelled_at)
SELECT u.user_id, ev.event_id, b.status, b.total_amount,
       b.booking_reference,
       b.booking_reference,
       CASE WHEN b.status = 'confirmed' THEN now() END,
       CASE WHEN b.status = 'cancelled' THEN now() END
FROM staging_bookings b
JOIN user_profiles u ON u.email = b.user_email
JOIN venues v  ON v.name = b.venue_name
JOIN events ev ON ev.venue_id = v.venue_id AND ev.title = b.event_title;

-- Once bookings exist, booking_reference (now real, unique data) is enough
-- to find the right booking directly -- no need to re-derive it through
-- user/venue/event the way the bookings insert above had to.
--
-- released_at is set here, not left for a later UPDATE: a booking that's
-- already 'cancelled' in the CSV (e.g. BK-0005) should never have occupied
-- an active claim on its seat in the first place, so its booking_seats row
-- is born already released, reusing the same cancelled_at the bookings
-- insert above just computed.
INSERT INTO booking_seats (booking_id, event_seat_id, released_at)
SELECT bk.booking_id, es.event_seat_id,
       CASE WHEN bk.status = 'cancelled' THEN bk.cancelled_at END
FROM staging_booking_seats bs
JOIN bookings bk ON bk.booking_reference = bs.booking_reference
JOIN venues v   ON v.name = bs.venue_name
JOIN events ev  ON ev.venue_id = v.venue_id AND ev.title = bs.event_title
JOIN seats s    ON s.venue_id = v.venue_id
               AND s.seat_row = bs.seat_row AND s.seat_number = bs.seat_number
JOIN event_seats es ON es.event_id = ev.event_id AND es.seat_id = s.seat_id;

-- Reflect each booking's outcome on the seat's own availability state.
-- BK-0005 (cancelled) flips its seat back to 'available' here; its
-- booking_seats row was also born released above, so
-- uq_booking_seats_active_event_seat no longer sees an active claim on
-- that seat -- it's free for a future booking to claim, unlike before this
-- fix.
UPDATE event_seats es
SET status     = CASE bk.status WHEN 'cancelled' THEN 'available'
                                 WHEN 'pending'   THEN 'held'
                                 ELSE 'booked' END,
    held_until = CASE WHEN bk.status = 'pending' THEN now() + INTERVAL '15 minutes' END,
    version    = es.version + 1
FROM booking_seats bks
JOIN bookings bk ON bk.booking_id = bks.booking_id
WHERE es.event_seat_id = bks.event_seat_id;

INSERT INTO payments (booking_id, amount, payment_method, status, paid_at)
SELECT bk.booking_id, p.amount, p.payment_method, p.status, p.paid_at
FROM staging_payments p
JOIN bookings bk ON bk.booking_reference = p.booking_reference;

COMMIT;
