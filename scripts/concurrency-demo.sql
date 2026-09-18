-- Concurrency demos: optimistic locking, FOR UPDATE, SKIP LOCKED.
-- Run in TWO psql sessions, not with -f. See scripts/README.md.
-- Requires functions-and-procedures.sql.

-- =============================================================================
-- SETUP / RESET -- run in either terminal before each demo
-- =============================================================================

-- Demo event "Concurrency Demo Night" with seats Z-98 and Z-99.
INSERT INTO seats (venue_id, seat_row, seat_number, seat_tier)
SELECT venue_id, 'Z', seat_number, 'standard'
FROM venues, unnest(ARRAY ['98', '99']) AS seat_number
WHERE venues.name = 'Waterfront Arena'
ON CONFLICT (venue_id, seat_row, seat_number) DO NOTHING;

INSERT INTO events (venue_id, title, starts_at, ends_at, status)
SELECT v.venue_id, 'Concurrency Demo Night',
       now() + INTERVAL '30 days', now() + INTERVAL '30 days 3 hours', 'on_sale'
FROM venues v
WHERE v.name = 'Waterfront Arena'
  AND NOT EXISTS (SELECT 1
                  FROM events ev
                  WHERE ev.venue_id = v.venue_id
                    AND ev.title = 'Concurrency Demo Night');

INSERT INTO event_seats (event_id, seat_id, price, status)
SELECT ev.event_id, s.seat_id, 50.00, 'available'
FROM events ev
         JOIN seats s ON s.venue_id = ev.venue_id AND s.seat_row = 'Z'
WHERE ev.title = 'Concurrency Demo Night'
ON CONFLICT (event_id, seat_id) DO NOTHING;

-- Cancel bookings from the previous run.
DO
$$
    DECLARE
        r RECORD;
    BEGIN
        FOR r IN SELECT bk.booking_reference
                 FROM bookings bk
                          JOIN events ev ON ev.event_id = bk.event_id
                 WHERE ev.title = 'Concurrency Demo Night'
                   AND bk.status NOT IN ('cancelled', 'expired')
            LOOP
                CALL cancel_booking(r.booking_reference);
            END LOOP;
    END
$$;

-- Expect: both seats 'available'.
SELECT s.seat_row, s.seat_number, es.status, es.version
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
         JOIN events ev ON ev.event_id = es.event_id
WHERE ev.title = 'Concurrency Demo Night'
ORDER BY s.seat_number;

-- =============================================================================
-- DEMO 1 -- optimistic locking (book_seat with p_expected_version)
-- =============================================================================

-- --- TERMINAL 1 ---------------------------------------------------------
SELECT es.version AS read_version
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
         JOIN events ev ON ev.event_id = es.event_id
WHERE ev.title = 'Concurrency Demo Night'
  AND s.seat_row = 'Z' AND s.seat_number = '99'
\gset

-- --- TERMINAL 2 ---------------------------------------------------------
SELECT es.version AS read_version
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
         JOIN events ev ON ev.event_id = es.event_id
WHERE ev.title = 'Concurrency Demo Night'
  AND s.seat_row = 'Z' AND s.seat_number = '99'
\gset

-- --- TERMINAL 1 ---------------------------------------------------------
BEGIN;

CALL book_seat('alice.tan@example.com', 'Concurrency Demo Night', 'Waterfront Arena',
               'Z', '99', :read_version);
-- NOTICE: booking BKE-... created (seat Z 99)
-- PAUSE -- switch to Terminal 2.

-- --- TERMINAL 2 ---------------------------------------------------------
CALL book_seat('brandon.lee@example.com', 'Concurrency Demo Night', 'Waterfront Arena',
               'Z', '99', :read_version);
-- Blocks. Switch to Terminal 1.

-- --- TERMINAL 1 ---------------------------------------------------------
COMMIT;

-- --- TERMINAL 2 ---------------------------------------------------------
-- ERROR: seat Z 99 was changed by another transaction (read version N, now N+1)

-- =============================================================================
-- DEMO 2 -- pessimistic locking (SELECT ... FOR UPDATE)
-- =============================================================================
-- Reset first.

-- --- TERMINAL 1 ---------------------------------------------------------
BEGIN;

SELECT es.event_seat_id, es.status
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
         JOIN events ev ON ev.event_id = es.event_id
WHERE ev.title = 'Concurrency Demo Night'
  AND s.seat_row = 'Z' AND s.seat_number = '99'
    FOR UPDATE OF es;
-- PAUSE -- switch to Terminal 2.

-- --- TERMINAL 2 ---------------------------------------------------------
CALL book_seat('brandon.lee@example.com', 'Concurrency Demo Night', 'Waterfront Arena', 'Z', '99');
-- Blocks. Switch to Terminal 1.

-- --- TERMINAL 1 ---------------------------------------------------------
CALL book_seat('alice.tan@example.com', 'Concurrency Demo Night', 'Waterfront Arena', 'Z', '99');
COMMIT;

-- --- TERMINAL 2 ---------------------------------------------------------
-- ERROR: seat Z 99 at Waterfront Arena for Concurrency Demo Night is not available

-- =============================================================================
-- DEMO 3 -- SKIP LOCKED (book_any_seat)
-- =============================================================================
-- Reset first.

-- --- TERMINAL 1 ---------------------------------------------------------
BEGIN;

CALL book_any_seat('alice.tan@example.com', 'Concurrency Demo Night', 'Waterfront Arena');
-- NOTICE: booking BKE-... created (seat Z 98)
-- PAUSE -- switch to Terminal 2.

-- --- TERMINAL 2 ---------------------------------------------------------
CALL book_any_seat('brandon.lee@example.com', 'Concurrency Demo Night', 'Waterfront Arena');
-- Returns immediately: NOTICE: booking BKE-... created (seat Z 99)

-- --- TERMINAL 1 ---------------------------------------------------------
COMMIT;

-- --- either terminal -----------------------------------------------------
CALL book_any_seat('chiara.rossi@example.com', 'Concurrency Demo Night', 'Waterfront Arena');
-- ERROR: no available seat at Waterfront Arena for Concurrency Demo Night
