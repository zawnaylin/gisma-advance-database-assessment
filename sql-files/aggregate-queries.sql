-- Aggregate query examples against the schema in create-tables.sql.
-- Run after data/load-seed-data.sql so there's real data to aggregate over.

-- =============================================================================
-- COUNT / SUM / AVG / MIN / MAX with GROUP BY
-- =============================================================================

-- Booking count by status.
SELECT status, COUNT(*) AS booking_count
FROM bookings
GROUP BY status
ORDER BY booking_count DESC;

-- Bookings and revenue per venue. LEFT JOINs + COALESCE so a venue with no
-- events/bookings/payments yet still shows up with zeros instead of
-- disappearing from the result.
SELECT v.name                          AS venue,
       COUNT(DISTINCT bk.booking_id)   AS bookings,
       COALESCE(SUM(p.amount), 0)      AS revenue
FROM venues v
         LEFT JOIN events ev ON ev.venue_id = v.venue_id
         LEFT JOIN bookings bk ON bk.event_id = ev.event_id
         LEFT JOIN payments p ON p.booking_id = bk.booking_id AND p.status = 'succeeded'
GROUP BY v.name
ORDER BY revenue DESC;

-- Average ticket price by seat tier.
SELECT s.seat_tier, ROUND(AVG(es.price), 2) AS avg_price, COUNT(*) AS seat_count
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
GROUP BY s.seat_tier
ORDER BY avg_price DESC;

-- Earliest and latest scheduled event per venue.
SELECT v.name AS venue, MIN(ev.starts_at) AS first_event, MAX(ev.starts_at) AS last_event,
       COUNT(*) AS event_count
FROM events ev
         JOIN venues v ON v.venue_id = ev.venue_id
GROUP BY v.name
ORDER BY first_event;

-- Seat inventory by venue and tier (two-column GROUP BY).
SELECT v.name AS venue, s.seat_tier, COUNT(*) AS seat_count
FROM seats s
         JOIN venues v ON v.venue_id = s.venue_id
GROUP BY v.name, s.seat_tier
ORDER BY v.name, s.seat_tier;

-- =============================================================================
-- HAVING -- filtering on the aggregate itself, not the raw rows
-- =============================================================================

-- Venues hosting more than one event.
SELECT v.name AS venue, COUNT(*) AS event_count
FROM events ev
         JOIN venues v ON v.venue_id = ev.venue_id
GROUP BY v.name
HAVING COUNT(*) > 1
ORDER BY event_count DESC;

-- Repeat customers -- more than one booking each. With the current seed
-- data every customer has exactly one booking, so this legitimately
-- returns zero rows; it'll start populating once someone books twice
-- (e.g. after running scripts/concurrency-demo.sql-style bookings, or
-- crud-examples.sql's Priya flow followed by a second booking for her).
SELECT up.name, up.email, COUNT(*) AS booking_count
FROM bookings bk
         JOIN user_profiles up ON up.user_id = bk.user_id
GROUP BY up.name, up.email
HAVING COUNT(*) > 1
ORDER BY booking_count DESC;

-- =============================================================================
-- Multi-dimensional GROUP BY
-- =============================================================================

-- Revenue by venue AND payment method.
SELECT v.name AS venue, p.payment_method, SUM(p.amount) AS revenue
FROM payments p
         JOIN bookings bk ON bk.booking_id = p.booking_id
         JOIN events ev ON ev.event_id = bk.event_id
         JOIN venues v ON v.venue_id = ev.venue_id
WHERE p.status = 'succeeded'
GROUP BY v.name, p.payment_method
ORDER BY v.name, revenue DESC;

-- =============================================================================
-- FILTER -- conditional aggregates without repeating the GROUP BY per condition
-- =============================================================================

-- Booking status breakdown per event, one row per event instead of one row
-- per (event, status) pair.
SELECT ev.title,
       COUNT(*) FILTER (WHERE bk.status = 'confirmed') AS confirmed,
       COUNT(*) FILTER (WHERE bk.status = 'pending')   AS pending,
       COUNT(*) FILTER (WHERE bk.status = 'cancelled') AS cancelled
FROM bookings bk
         JOIN events ev ON ev.event_id = bk.event_id
GROUP BY ev.title
ORDER BY ev.title;

-- Seat occupancy percentage per event: claimed (held or booked) vs total.
SELECT ev.title,
       v.name                                                                AS venue,
       COUNT(*)                                                              AS total_seats,
       COUNT(*) FILTER (WHERE es.status IN ('booked', 'held'))               AS claimed_seats,
       ROUND(100.0 * COUNT(*) FILTER (WHERE es.status IN ('booked', 'held'))
                 / NULLIF(COUNT(*), 0), 1)                                   AS occupancy_pct
FROM event_seats es
         JOIN events ev ON ev.event_id = es.event_id
         JOIN venues v ON v.venue_id = ev.venue_id
GROUP BY ev.title, v.name
ORDER BY occupancy_pct DESC;

-- =============================================================================
-- Window functions (bonus -- beyond plain GROUP BY: keep the individual
-- rows AND an aggregate computed across a window of them)
-- =============================================================================

-- Rank each event's revenue against other events at the SAME venue.
SELECT v.name AS venue, ev.title,
       COALESCE(SUM(p.amount), 0) AS revenue,
       RANK() OVER (PARTITION BY v.venue_id ORDER BY COALESCE(SUM(p.amount), 0) DESC) AS rank_in_venue
FROM venues v
         JOIN events ev ON ev.venue_id = v.venue_id
         LEFT JOIN bookings bk ON bk.event_id = ev.event_id
         LEFT JOIN payments p ON p.booking_id = bk.booking_id AND p.status = 'succeeded'
GROUP BY v.venue_id, v.name, ev.event_id, ev.title
ORDER BY v.name, rank_in_venue;

-- Running total of revenue over time -- each row keeps its own amount AND
-- shows the cumulative sum up to that point, ordered by when the booking
-- was made.
SELECT bk.booking_reference, bk.created_at, p.amount,
       SUM(p.amount) OVER (ORDER BY bk.created_at) AS running_total
FROM bookings bk
         JOIN payments p ON p.booking_id = bk.booking_id AND p.status = 'succeeded'
ORDER BY bk.created_at;
