-- Sample CRUD operations against the schema in create-tables.sql.
--
-- Written to run, top to bottom, against a database that already has
-- (run from the repository root):
--   psql -d your_database -f sql-files/create-tables.sql
--   psql -d your_database -f sql-files/create-indexes.sql
--   psql -d your_database -f sql-files/load-seed-data.sql
--   psql -d your_database -f sql-files/functions-and-procedures.sql  -- for expire_stale_holds() (UPDATE #3)
--
-- Every example resolves rows by business key (email, venue/event name,
-- booking_reference) rather than a hard-coded surrogate ID -- those IDs
-- depend on load order and aren't known ahead of time, same reasoning as
-- the natural-key joins in the seed loader.
--
-- A few statements in the DELETE section are commented as "expected to
-- fail" -- they demonstrate ON DELETE RESTRICT actually blocking a delete.
-- Running the whole file in psql (autocommit per statement) is fine: each
-- one fails or succeeds independently and the script keeps going.

-- =============================================================================
-- CREATE
-- =============================================================================

-- 1. Register a new user profile.
INSERT INTO user_profiles (name, email, role)
VALUES ('Priya Shah', 'priya.shah@example.com', 'customer')
RETURNING user_id, name, email;

-- 2. Add a new venue, referencing an already-seeded timezone.
INSERT INTO venues (name, address, city, total_capacity, time_zone)
VALUES ('Skyline Hall', '10 High St', 'Singapore', 1800, 'Asia/Singapore')
RETURNING venue_id;

-- 3. Schedule a new event at an existing venue.
INSERT INTO events (venue_id, title, starts_at, ends_at, status)
SELECT venue_id, 'Winter Gala', '2026-12-05T19:00:00+01:00', '2026-12-05T22:00:00+01:00', 'scheduled'
FROM venues WHERE name = 'Waterfront Arena'
RETURNING event_id;

-- 4. Book a seat, end to end, as one atomic statement.
-- Seat B2 at Waterfront Arena / Autumn Jazz Night is untouched by the seed
-- data, so this has a real seat to claim. The chained CTEs are the point:
--   a) hold the seat, but only if it's still 'available' AT THE VERSION WE
--      JUST READ -- the optimistic-lock check from event_seats.version.
--      If another transaction already moved it, this returns 0 rows and
--      every step after it inserts nothing, instead of double-booking.
--   b) create the booking, only if step (a) produced a held seat.
--   c) link the held seat to the new booking.
-- One statement, one transaction, no race window between the steps.
WITH target_seat AS (
    SELECT es.event_seat_id, es.version
    FROM event_seats es
    JOIN events ev ON ev.event_id = es.event_id
    JOIN seats s ON s.seat_id = es.seat_id
    JOIN venues v ON v.venue_id = s.venue_id
    WHERE ev.title = 'Autumn Jazz Night' AND v.name = 'Waterfront Arena'
      AND s.seat_row = 'B' AND s.seat_number = '2'
),
held_seat AS (
    UPDATE event_seats es
    SET status = 'held', held_until = now() + INTERVAL '15 minutes', version = es.version + 1
    FROM target_seat t
    WHERE es.event_seat_id = t.event_seat_id
      AND es.version = t.version
      AND es.status = 'available'
    RETURNING es.event_seat_id, es.price
),
new_booking AS (
    INSERT INTO bookings (user_id, event_id, status, total_amount)
    SELECT up.user_id, ev.event_id, 'pending', held_seat.price
    FROM held_seat
    JOIN events ev ON ev.title = 'Autumn Jazz Night'
    JOIN user_profiles up ON up.email = 'priya.shah@example.com'
    RETURNING booking_id, booking_reference
)
INSERT INTO booking_seats (booking_id, event_seat_id)
SELECT new_booking.booking_id, held_seat.event_seat_id
FROM new_booking, held_seat
RETURNING booking_id, event_seat_id;

-- =============================================================================
-- READ
-- =============================================================================

-- 1. Upcoming events, with each start time shown in the venue's own timezone.
SELECT ev.title, v.name AS venue, v.city,
       ev.starts_at AT TIME ZONE v.time_zone AS starts_local
FROM events ev
JOIN venues v ON v.venue_id = ev.venue_id
WHERE ev.starts_at > now()
ORDER BY ev.starts_at;

-- 2. Seat map and availability for one event.
SELECT s.seat_row, s.seat_number, s.seat_tier, es.price, es.status
FROM event_seats es
JOIN seats s ON s.seat_id = es.seat_id
JOIN events ev ON ev.event_id = es.event_id
WHERE ev.title = 'Autumn Jazz Night'
ORDER BY s.seat_row, s.seat_number;

-- 3. One customer's booking history.
SELECT bk.booking_reference, ev.title, v.name AS venue, bk.status, bk.total_amount,
       count(bs.booking_seat_id) AS seat_count
FROM bookings bk
JOIN events ev ON ev.event_id = bk.event_id
JOIN venues v ON v.venue_id = ev.venue_id
JOIN user_profiles up ON up.user_id = bk.user_id
LEFT JOIN booking_seats bs ON bs.booking_id = bk.booking_id
WHERE up.email = 'alice.tan@example.com'
GROUP BY bk.booking_id, bk.booking_reference, ev.title, v.name, bk.status, bk.total_amount
ORDER BY bk.created_at DESC;

-- 4. Full booking detail by reference -- the customer-support lookup path.
SELECT bk.booking_reference, up.name AS customer, ev.title, v.name AS venue,
       s.seat_row, s.seat_number, es.price, bk.status, p.status AS payment_status
FROM bookings bk
JOIN user_profiles up ON up.user_id = bk.user_id
JOIN events ev ON ev.event_id = bk.event_id
JOIN venues v ON v.venue_id = ev.venue_id
JOIN booking_seats bs ON bs.booking_id = bk.booking_id
JOIN event_seats es ON es.event_seat_id = bs.event_seat_id
JOIN seats s ON s.seat_id = es.seat_id
LEFT JOIN payments p ON p.booking_id = bk.booking_id
WHERE bk.booking_reference = 'BK-0001';

-- 5. Revenue collected per venue (aggregate report).
SELECT v.name AS venue, COALESCE(SUM(p.amount), 0) AS revenue_collected
FROM venues v
LEFT JOIN events ev ON ev.venue_id = v.venue_id
LEFT JOIN bookings bk ON bk.event_id = ev.event_id
LEFT JOIN payments p ON p.booking_id = bk.booking_id AND p.status = 'succeeded'
GROUP BY v.name
ORDER BY revenue_collected DESC;

-- =============================================================================
-- UPDATE
-- =============================================================================

-- 1. Confirm Priya's pending booking from the CREATE section.
-- set_booking_status_timestamps() fires automatically and sets confirmed_at.
UPDATE bookings
SET status = 'confirmed'
WHERE user_id = (SELECT user_id FROM user_profiles WHERE email = 'priya.shah@example.com')
  AND status = 'pending';

-- ...and reflect that on the seat itself: held -> booked, hold timer cleared.
UPDATE event_seats es
SET status = 'booked', held_until = NULL, version = es.version + 1
FROM booking_seats bs
JOIN bookings bk ON bk.booking_id = bs.booking_id
JOIN user_profiles up ON up.user_id = bk.user_id
WHERE es.event_seat_id = bs.event_seat_id
  AND up.email = 'priya.shah@example.com'
  AND bk.status = 'confirmed';

-- 2. Cancel a pending booking (Brandon's, BK-0002) and release its seat.
-- set_booking_status_timestamps() sets cancelled_at automatically. The
-- booking_seats row also needs released_at set explicitly -- skip this and
-- uq_booking_seats_active_event_seat still sees an active claim on the
-- seat, so nobody could ever book it again even though event_seats says
-- 'available'.
UPDATE bookings SET status = 'cancelled' WHERE booking_reference = 'BK-0002';

UPDATE booking_seats bs
SET released_at = now()
FROM bookings bk
WHERE bs.booking_id = bk.booking_id
  AND bk.booking_reference = 'BK-0002'
  AND bs.released_at IS NULL;

UPDATE event_seats es
SET status = 'available', held_until = NULL, version = es.version + 1
FROM booking_seats bs
JOIN bookings bk ON bk.booking_id = bs.booking_id
WHERE es.event_seat_id = bs.event_seat_id
  AND bk.booking_reference = 'BK-0002';

-- 3. Release any hold that's expired -- the maintenance job held_until exists
-- for. Runs safely on a schedule; does nothing while holds are current.
-- A procedure rather than a bare UPDATE on event_seats: freeing the seat
-- alone would leave its pending booking's booking_seats claim active, and
-- uq_booking_seats_active_event_seat would then block anyone from booking
-- it. expire_stale_holds() expires the booking and releases the claim too
-- (see functions-and-procedures.sql). Seeded pending bookings carry a
-- 15-minute hold, so run this 15+ minutes after seeding and it expires them.
CALL expire_stale_holds();

-- 4. Record a successful payment for Priya's now-confirmed booking.
INSERT INTO payments (booking_id, amount, payment_method, status, paid_at)
SELECT bk.booking_id, bk.total_amount, 'credit_card', 'succeeded', now()
FROM bookings bk
JOIN user_profiles up ON up.user_id = bk.user_id
WHERE up.email = 'priya.shah@example.com' AND bk.status = 'confirmed';

-- =============================================================================
-- DELETE
-- =============================================================================

-- 1. Delete a venue with nothing attached to it yet -- succeeds cleanly.
DELETE FROM venues WHERE name = 'Skyline Hall';

-- 2. EXPECTED TO FAIL: fk_bookings_event is ON DELETE RESTRICT, and this
-- event has bookings. The database refuses rather than silently orphaning
-- (or cascading through) live booking data.
DELETE FROM events WHERE title = 'Autumn Jazz Night';

-- 3. EXPECTED TO FAIL: fk_bookings_user is ON DELETE RESTRICT for the same
-- reason -- a customer with booking history can't just be removed.
DELETE FROM user_profiles WHERE email = 'alice.tan@example.com';

-- 4. Hard-delete a fully cancelled, already-refunded booking (BK-0005).
-- Its booking_seats and payments rows go with it automatically --
-- fk_booking_seats_booking and fk_payments_booking are ON DELETE CASCADE.
DELETE FROM bookings WHERE booking_reference = 'BK-0005';
