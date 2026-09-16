-- Views for the schema in create-tables.sql.
-- Run after create-tables.sql (and sql-files/load-seed-data.sql if you want
-- the example queries at the bottom of each section to return real rows):
--   psql -d your_database -f sql-files/create-views.sql
--
-- A VIEW is a named, stored SELECT -- not stored data. Every time a view is
-- queried, Postgres expands its definition into the outer query and plans
-- the whole thing together, so a view is always exactly as current as the
-- tables underneath it and costs nothing to keep in sync. What it buys:
--   * Abstraction   - a 4-table join written once, queried like a table.
--   * Security      - grant access to the view, not the base table, and
--                     expose only the columns/rows that caller should see.
--   * Consistency   - "what counts as revenue" is defined in one place,
--                     not re-derived (slightly differently) in every report.
-- A MATERIALIZED VIEW is the opposite trade-off: the SELECT's result IS
-- stored, so reads are cheap, but it's only as fresh as its last REFRESH.
--
-- Re-runnable: plain views use CREATE OR REPLACE. Materialized views have no
-- OR REPLACE form, so that one is dropped and recreated instead.

-- =============================================================================
-- 1. Simple view -- hiding a join behind a name
-- =============================================================================

-- The seat map for any event. The same seat -> event -> venue join chain is
-- hand-written in crud-examples.sql (READ #2) and inside get_available_seats();
-- with this view, callers just filter it like a table.
-- starts_local is computed per row from the venue's own time zone, so no
-- caller has to remember to do the AT TIME ZONE conversion themselves.
CREATE OR REPLACE VIEW v_event_seat_availability AS
SELECT es.event_seat_id,
       ev.event_id,
       ev.title                              AS event_title,
       v.name                                AS venue,
       v.city,
       ev.starts_at AT TIME ZONE v.time_zone AS starts_local,
       s.seat_row,
       s.seat_number,
       s.seat_tier,
       es.price,
       es.status                             AS seat_status,
       es.held_until
FROM event_seats es
         JOIN events ev ON ev.event_id = es.event_id
         JOIN venues v ON v.venue_id = ev.venue_id
         JOIN seats s ON s.seat_id = es.seat_id;

-- Examples:
-- SELECT seat_row, seat_number, seat_tier, price
-- FROM v_event_seat_availability
-- WHERE event_title = 'Autumn Jazz Night' AND venue = 'Waterfront Arena'
--   AND seat_status = 'available'
-- ORDER BY seat_row, seat_number;
--
-- The view isn't a black box to the planner: EXPLAIN shows the WHERE pushed
-- straight down into the underlying tables, same plan as the hand-written join.
-- EXPLAIN SELECT * FROM v_event_seat_availability WHERE event_title = 'Broadway Night';


-- =============================================================================
-- 2. Reporting view -- one row per booking, fan-out handled once
-- =============================================================================

-- The customer-support lookup from crud-examples.sql (READ #4) returns one
-- row PER SEAT, so a 2-seat booking shows up twice. Collapsing that correctly
-- (GROUP BY + string_agg, without double-counting anything) is easy to get
-- subtly wrong, which is exactly why it's worth defining once here.
-- payments is 1:1 with bookings (uq_payments_booking), so joining it
-- alongside booking_seats can't multiply any amounts.
CREATE OR REPLACE VIEW v_booking_details AS
SELECT bk.booking_id,
       bk.booking_reference,
       up.name                                                AS customer,
       up.email                                               AS customer_email,
       ev.title                                               AS event_title,
       v.name                                                 AS venue,
       ev.starts_at,
       bk.status                                              AS booking_status,
       bk.total_amount,
       COUNT(bs.booking_seat_id)                              AS seat_count,
       string_agg(s.seat_row || s.seat_number, ', '
                  ORDER BY s.seat_row, s.seat_number)         AS seats,
       p.status                                               AS payment_status,
       p.paid_at,
       bk.created_at
FROM bookings bk
         JOIN user_profiles up ON up.user_id = bk.user_id
         JOIN events ev ON ev.event_id = bk.event_id
         JOIN venues v ON v.venue_id = ev.venue_id
         LEFT JOIN booking_seats bs ON bs.booking_id = bk.booking_id
         LEFT JOIN event_seats es ON es.event_seat_id = bs.event_seat_id
         LEFT JOIN seats s ON s.seat_id = es.seat_id
         LEFT JOIN payments p ON p.booking_id = bk.booking_id
GROUP BY bk.booking_id, up.user_id, ev.event_id, v.venue_id, p.payment_id;
-- GROUP BY on each table's primary key is enough: Postgres knows every other
-- column from that table is functionally dependent on it.

-- Examples:
-- SELECT * FROM v_booking_details WHERE booking_reference = 'BK-0001';
-- SELECT booking_reference, event_title, booking_status, seats
-- FROM v_booking_details WHERE customer_email = 'alice.tan@example.com'
-- ORDER BY created_at DESC;


-- =============================================================================
-- 3. Security view -- column masking + row filtering
-- =============================================================================

-- A customer list for support staff that never exposes a full email address
-- and never lists admin/organizer accounts. The idea is to GRANT SELECT on
-- this view to a restricted role while granting nothing on user_profiles
-- itself: a view runs with its OWNER's privileges on the base table, so the
-- restricted role can read through the view without being able to query the
-- table directly.
--
-- security_barrier = true matters for the row filter. Without it, the planner
-- is free to evaluate a caller's own WHERE condition before the view's
-- role = 'customer' filter -- so a caller could pass a function that RAISEs
-- NOTICE on every value it sees and watch admin rows leak through, even though
-- the view never returns them. With it, the view's own filter always runs
-- first. (The cost: the planner can push fewer conditions down, so reserve it
-- for views that actually exist to hide rows.)
CREATE OR REPLACE VIEW v_customer_directory
    WITH (security_barrier = true)
AS
SELECT user_id,
       name,
       left(email, 1) || '***@' || split_part(email, '@', 2) AS email_masked,
       created_at
FROM user_profiles
WHERE role = 'customer';

-- Examples:
-- SELECT * FROM v_customer_directory ORDER BY name;
--
-- The access-control half, shown with a throwaway role:
-- CREATE ROLE support_staff NOLOGIN;
-- GRANT SELECT ON v_customer_directory TO support_staff;
-- SET ROLE support_staff;
-- SELECT * FROM v_customer_directory LIMIT 3;   -- works, emails masked
-- SELECT * FROM user_profiles LIMIT 3;          -- EXPECTED TO FAIL: permission denied
-- RESET ROLE;


-- =============================================================================
-- 4. Updatable view -- WITH CHECK OPTION
-- =============================================================================

-- A view over a single table, with no aggregates/DISTINCT/GROUP BY/joins, is
-- automatically updatable in Postgres: INSERT/UPDATE/DELETE against it are
-- rewritten onto events directly, and events' own constraints and triggers
-- (chk_events_status, events_before_update -> updated_at) still fire.
--
-- The catch without CHECK OPTION: an UPDATE through the view could move a row
-- OUT of the view -- e.g. set status = 'cancelled' -- and the view would
-- happily allow a change whose result it can no longer even see.
-- WITH CHECK OPTION rejects any INSERT/UPDATE whose resulting row wouldn't
-- satisfy the view's WHERE, so a client that only has access to this view
-- can manage bookable events but can't cancel or complete one through it.
CREATE OR REPLACE VIEW v_bookable_events AS
SELECT event_id,
       venue_id,
       title,
       starts_at,
       ends_at,
       status
FROM events
WHERE status IN ('scheduled', 'on_sale')
WITH CHECK OPTION;

-- Examples:
-- Allowed -- the row is still bookable afterwards, so it stays in the view:
-- UPDATE v_bookable_events SET status = 'on_sale' WHERE title = 'Comedy Gala';
--
-- EXPECTED TO FAIL: "new row violates check option for view v_bookable_events"
-- UPDATE v_bookable_events SET status = 'cancelled' WHERE title = 'Indie Rock Showcase';
--
-- Rows outside the view are simply invisible to it -- this matches 0 rows
-- rather than erroring, even though 'Autumn Jazz Night' exists in events:
-- UPDATE events SET status = 'completed' WHERE title = 'Autumn Jazz Night';
-- DELETE FROM v_bookable_events WHERE title = 'Autumn Jazz Night';  -- DELETE 0


-- =============================================================================
-- 5. Materialized view -- stored results, explicit refresh
-- =============================================================================

-- Per-venue sales dashboard. Aggregating every booking and payment in the
-- system is the kind of query you don't want to re-run on every dashboard
-- page load, and a dashboard doesn't need to-the-second freshness -- so the
-- result is stored and refreshed on a schedule instead.
--
-- Fan-out check: payments is 1:1 with bookings, and booking_seats isn't
-- joined at all, so SUM(p.amount) counts each payment exactly once.
-- refreshed_at records when the stored snapshot was taken, so a reader can
-- tell how stale the numbers are.
DROP MATERIALIZED VIEW IF EXISTS mv_venue_sales_summary;

CREATE MATERIALIZED VIEW mv_venue_sales_summary AS
SELECT v.venue_id,
       v.name                                                        AS venue,
       v.city,
       COUNT(DISTINCT ev.event_id)                                   AS event_count,
       COUNT(bk.booking_id)                                          AS total_bookings,
       COUNT(bk.booking_id) FILTER (WHERE bk.status = 'confirmed')   AS confirmed_bookings,
       COUNT(bk.booking_id) FILTER (WHERE bk.status = 'cancelled')   AS cancelled_bookings,
       COALESCE(SUM(p.amount) FILTER (WHERE p.status = 'succeeded'), 0) AS revenue,
       COALESCE(SUM(p.amount) FILTER (WHERE p.status = 'refunded'), 0)  AS refunded,
       now()                                                         AS refreshed_at
FROM venues v
         LEFT JOIN events ev ON ev.venue_id = v.venue_id
         LEFT JOIN bookings bk ON bk.event_id = ev.event_id
         LEFT JOIN payments p ON p.booking_id = bk.booking_id
GROUP BY v.venue_id, v.name, v.city;

-- A materialized view is a real relation on disk, so unlike a plain view it
-- can be indexed. This UNIQUE index is also what makes REFRESH ... CONCURRENTLY
-- possible: Postgres needs a unique key to diff the old snapshot against the
-- new one row by row.
CREATE UNIQUE INDEX uq_mv_venue_sales_summary_venue
    ON mv_venue_sales_summary (venue_id);

-- Examples:
-- SELECT venue, city, confirmed_bookings, revenue, refreshed_at
-- FROM mv_venue_sales_summary
-- ORDER BY revenue DESC;
--
-- Staleness in action: new data doesn't show up until a refresh.
-- CALL cancel_booking('BK-0001');              -- from functions-and-procedures.sql
-- SELECT revenue FROM mv_venue_sales_summary WHERE venue = 'Waterfront Arena';  -- unchanged
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_venue_sales_summary;
-- SELECT revenue FROM mv_venue_sales_summary WHERE venue = 'Waterfront Arena';  -- now reflects the refund
--
-- Plain REFRESH takes an ACCESS EXCLUSIVE lock -- dashboard readers block
-- until it finishes. CONCURRENTLY builds the new result on the side and
-- swaps changes in, so readers keep seeing the old snapshot meanwhile; it's
-- slower, and can't be used on a never-populated view (WITH NO DATA).
