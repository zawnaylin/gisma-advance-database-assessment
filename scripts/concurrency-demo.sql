-- Concurrency walkthrough for the schema in create-tables.sql.
--
-- Unlike every other .sql file in this project, this one is NOT meant to be
-- run top to bottom in one session -- the whole point is two transactions
-- interleaving. To run it:
--
--   1. Open TWO separate psql sessions against the same database
--      (two terminal windows, or two panes), call them Terminal 1 and
--      Terminal 2.
--   2. Run the SETUP / RESET block once, in either terminal.
--   3. For each demo below, copy the "TERMINAL 1" statements into that
--      session and the "TERMINAL 2" statements into the other, pausing
--      exactly where marked -- the order you switch between them is the
--      entire content of the demo.
--   4. Re-run the SETUP / RESET block between demos (or before re-running
--      the same one) to restore a clean baseline. It's idempotent and safe
--      to run as many times as you like.

-- =============================================================================
-- SETUP / RESET -- run once, in either terminal, before any demo
-- =============================================================================

-- Two seats dedicated to this demo, isolated from crud-examples.sql and
-- functions-and-procedures.sql (which already claim other seats at this
-- same venue/event) -- so this file can be re-run safely regardless of
-- what else has touched the seed data.
INSERT INTO seats (venue_id, seat_row, seat_number, seat_tier)
SELECT venue_id, 'Z', seat_number, 'standard'
FROM venues, unnest(ARRAY ['98', '99']) AS seat_number
WHERE venues.name = 'Waterfront Arena'
ON CONFLICT (venue_id, seat_row, seat_number) DO NOTHING;

INSERT INTO event_seats (event_id, seat_id, price, status)
SELECT ev.event_id, s.seat_id, 50.00, 'available'
FROM events ev
         JOIN venues v ON v.venue_id = ev.venue_id
         JOIN seats s ON s.venue_id = v.venue_id AND s.seat_row = 'Z'
WHERE ev.title = 'Autumn Jazz Night' AND v.name = 'Waterfront Arena'
ON CONFLICT (event_id, seat_id) DO NOTHING;

-- Force both back to a clean baseline. booking_seats.event_seat_id is
-- UNIQUE, so a booking from a previous run of this demo has to be removed
-- (not just have its seat's status flipped) before the seat can be claimed
-- again -- the same "permanently blocked after a soft cancel" constraint
-- discussed earlier in this project, worked around here by hard-deleting
-- the demo's own throwaway bookings outright.
DELETE FROM bookings
WHERE booking_id IN (SELECT bs.booking_id
                      FROM booking_seats bs
                               JOIN event_seats es ON es.event_seat_id = bs.event_seat_id
                               JOIN seats s ON s.seat_id = es.seat_id
                      WHERE s.seat_row = 'Z' AND s.seat_number IN ('98', '99'));

UPDATE event_seats es
SET status     = 'available',
    held_until = NULL
FROM seats s
WHERE es.seat_id = s.seat_id
  AND s.seat_row = 'Z' AND s.seat_number IN ('98', '99');

-- Confirm the baseline before starting a demo:
SELECT s.seat_row, s.seat_number, es.status, es.version
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
WHERE s.seat_row = 'Z' AND s.seat_number IN ('98', '99')
ORDER BY s.seat_number;
-- expect: both rows 'available', version 0 (or whatever it settles at
-- after repeated runs -- the exact number doesn't matter, only that both
-- terminals below read the SAME value before racing)

-- =============================================================================
-- DEMO 1 -- optimistic locking: two buyers race for seat Z-99
-- =============================================================================
-- What this shows: the version check in event_seats doesn't stop the two
-- UPDATE statements from serializing at the storage level (Postgres still
-- locks the physical row) -- what it changes is what happens AFTER the
-- second one unblocks. It doesn't overwrite the first buyer's change; it
-- re-checks its WHERE clause against the now-current row, finds the
-- version has moved on, and matches zero rows instead of corrupting
-- anything. That's the actual guarantee: not "no blocking ever," but "a
-- stale writer can never silently win."

-- --- TERMINAL 1 ---------------------------------------------------------
BEGIN;

SELECT es.event_seat_id, es.status, es.version
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
WHERE s.seat_row = 'Z' AND s.seat_number = '99';
-- note the version value, e.g. 0 -- used below

UPDATE event_seats es
SET status     = 'held',
    held_until = now() + INTERVAL '15 minutes',
    version    = es.version + 1
FROM seats s
WHERE es.seat_id = s.seat_id
  AND s.seat_row = 'Z' AND s.seat_number = '99'
  AND es.version = 0 -- the version just read
  AND es.status = 'available'
RETURNING es.event_seat_id, es.version;
-- 1 row returned, version now 1

-- PAUSE HERE. Do not COMMIT or ROLLBACK yet -- switch to Terminal 2.

-- --- TERMINAL 2 ---------------------------------------------------------
-- Run this while Terminal 1 is paused, mid-transaction, above.
BEGIN;

UPDATE event_seats es
SET status     = 'held',
    held_until = now() + INTERVAL '15 minutes',
    version    = es.version + 1
FROM seats s
WHERE es.seat_id = s.seat_id
  AND s.seat_row = 'Z' AND s.seat_number = '99'
  AND es.version = 0 -- read the SAME stale version Terminal 1 started from
  AND es.status = 'available'
RETURNING es.event_seat_id, es.version;
-- This BLOCKS here -- Terminal 1 still holds the row lock, uncommitted.
-- Leave it hanging. Switch back to Terminal 1.

-- --- TERMINAL 1 ---------------------------------------------------------
COMMIT;

-- --- TERMINAL 2 ---------------------------------------------------------
-- The moment Terminal 1 commits, this unblocks on its own -- watch it
-- return immediately with 0 rows: es.version is now 1, not the 0 this
-- statement required, so the WHERE clause matches nothing. Terminal 2 has
-- cleanly lost the race -- no error, no corrupted state, just "try again."
ROLLBACK; -- nothing to commit; it updated no rows

-- =============================================================================
-- DEMO 2 -- pessimistic locking: SELECT ... FOR UPDATE blocks up front
-- =============================================================================
-- Contrast with Demo 1: here the SECOND transaction blocks at the READ,
-- long before either side attempts a write, and it blocks indefinitely
-- (no version check, no clean "I lost" signal) until the first transaction
-- ends. Simpler to reason about; the cost is that a slow first transaction
-- stalls everyone else waiting on the same row.

-- Reset Z-99 back to 'available' first (see SETUP / RESET above) if you
-- just ran Demo 1.

-- --- TERMINAL 1 ---------------------------------------------------------
BEGIN;

SELECT es.event_seat_id, es.status
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
WHERE s.seat_row = 'Z' AND s.seat_number = '99'
    FOR UPDATE;
-- Row is now locked for the rest of this transaction.
-- PAUSE HERE. Switch to Terminal 2.

-- --- TERMINAL 2 ---------------------------------------------------------
BEGIN;

SELECT es.event_seat_id, es.status
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
WHERE s.seat_row = 'Z' AND s.seat_number = '99'
    FOR UPDATE;
-- This BLOCKS here -- unlike Demo 1, it blocks on the SELECT itself, not
-- a later UPDATE. Leave it hanging. Switch back to Terminal 1.

-- --- TERMINAL 1 ---------------------------------------------------------
COMMIT; -- or ROLLBACK -- either releases the lock

-- --- TERMINAL 2 ---------------------------------------------------------
-- Unblocks the instant Terminal 1 ends, now holding the lock itself.
-- It can safely proceed to book the seat:
UPDATE event_seats
SET status = 'held', held_until = now() + INTERVAL '15 minutes', version = version + 1
WHERE seat_id = (SELECT seat_id FROM seats WHERE seat_row = 'Z' AND seat_number = '99');
COMMIT;

-- =============================================================================
-- DEMO 3 (bonus) -- SKIP LOCKED: grab any available seat without waiting
-- =============================================================================
-- Realistic for "give me any seat in this tier" rather than one specific
-- seat -- what a real ticket queue does. Two buyers can each get a DIFFERENT
-- seat with zero blocking, instead of piling up behind one lock.

-- Reset both demo seats first (SETUP / RESET above) if you just ran Demo 1/2.

-- --- TERMINAL 1 ---------------------------------------------------------
BEGIN;

SELECT es.event_seat_id, s.seat_number
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
WHERE es.status = 'available' AND s.seat_row = 'Z' AND s.seat_number IN ('98', '99')
ORDER BY es.event_seat_id
    FOR UPDATE SKIP LOCKED
LIMIT 1;
-- Locks and returns ONE seat (whichever sorts first and isn't already
-- locked by someone else). PAUSE HERE -- switch to Terminal 2.

-- --- TERMINAL 2 ---------------------------------------------------------
BEGIN;

SELECT es.event_seat_id, s.seat_number
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
WHERE es.status = 'available' AND s.seat_row = 'Z' AND s.seat_number IN ('98', '99')
ORDER BY es.event_seat_id
    FOR UPDATE SKIP LOCKED
LIMIT 1;
-- Returns IMMEDIATELY -- no blocking -- with the OTHER seat, because
-- SKIP LOCKED simply steps past the row Terminal 1 is holding instead of
-- waiting on it. Compare this to Demo 2, where the second session blocked.

-- --- either terminal -----------------------------------------------------
COMMIT; -- or ROLLBACK, in both terminals, to finish
