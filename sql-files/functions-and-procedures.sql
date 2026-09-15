-- Worked examples contrasting FUNCTION and PROCEDURE for the schema in
-- create-tables.sql. Run after create-tables.sql (and data/load-seed-data.sql
-- if you want the example calls at the bottom to have real rows to act on).
--
-- The difference is structural, not just a naming convention:
--   FUNCTION  - called from inside a query (SELECT / WHERE / JOIN), must
--               RETURN a value, and runs inside the CALLER's transaction --
--               it cannot COMMIT or ROLLBACK on its own.
--   PROCEDURE - invoked with CALL as its own statement, no RETURN required,
--               and -- the capability a function structurally cannot have --
--               it MAY COMMIT/ROLLBACK internally. That matters for a
--               workflow that should make progress in batches rather than
--               as one giant transaction.
-- Rule of thumb used below: read logic that plugs into a query -> FUNCTION.
-- A multi-step write workflow the app deliberately invokes -> PROCEDURE.

-- =============================================================================
-- FUNCTIONS -- reusable logic, plugged straight into a query
-- =============================================================================

-- Set-returning function: seat availability for one event, by natural key.
-- Called exactly like a table.
CREATE OR REPLACE FUNCTION get_available_seats(p_event_title VARCHAR, p_venue_name VARCHAR)
    RETURNS TABLE
            (
                seat_row    VARCHAR,
                seat_number VARCHAR,
                seat_tier   VARCHAR,
                price       NUMERIC
            )
AS
$$
SELECT s.seat_row, s.seat_number, s.seat_tier, es.price
FROM event_seats es
         JOIN seats s ON s.seat_id = es.seat_id
         JOIN events ev ON ev.event_id = es.event_id
         JOIN venues v ON v.venue_id = ev.venue_id
WHERE ev.title = p_event_title
  AND v.name = p_venue_name
  AND es.status = 'available'
ORDER BY s.seat_row, s.seat_number;
$$ LANGUAGE sql STABLE;

-- Example:
-- SELECT * FROM get_available_seats('Autumn Jazz Night', 'Waterfront Arena');


-- Scalar function: what a booking's seats actually add up to right now.
-- Used directly, and also from the trigger function below, so the sum logic
-- lives in exactly one place instead of being duplicated.
CREATE OR REPLACE FUNCTION calculate_booking_total(p_booking_id INTEGER)
    RETURNS NUMERIC
AS
$$
SELECT COALESCE(SUM(es.price), 0)
FROM booking_seats bs
         JOIN event_seats es ON es.event_seat_id = bs.event_seat_id
WHERE bs.booking_id = p_booking_id;
$$ LANGUAGE sql STABLE;

-- Example:
-- SELECT calculate_booking_total(1);


-- A trigger function IS a function -- RETURNS TRIGGER, reads NEW/OLD, and
-- (unlike the two above) must be PL/pgSQL: plain SQL-language functions
-- cannot be bound as triggers in Postgres. Keeps bookings.total_amount from
-- ever drifting from what's actually in booking_seats.
CREATE OR REPLACE FUNCTION sync_booking_total()
    RETURNS TRIGGER
AS
$$
BEGIN
    UPDATE bookings
    SET total_amount = calculate_booking_total(COALESCE(NEW.booking_id, OLD.booking_id))
    WHERE booking_id = COALESCE(NEW.booking_id, OLD.booking_id);
    RETURN NULL; -- AFTER trigger: return value is ignored either way
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER booking_seats_sync_total
    AFTER INSERT OR DELETE
    ON booking_seats
    FOR EACH ROW
EXECUTE FUNCTION sync_booking_total();

-- Note: once this trigger exists, a booking's total_amount is recomputed
-- automatically the moment its seats change -- an explicit total_amount
-- supplied at booking-insert time (as crud-examples.sql and the loader do)
-- gets overwritten to the same correct value the instant booking_seats is
-- populated. Harmless, but it's why you'd normally pick one mechanism, not
-- both, in a real app.

-- =============================================================================
-- PROCEDURES -- multi-step workflows the app invokes with CALL
-- =============================================================================

-- Wraps the "book a seat" flow from crud-examples.sql into one reusable
-- call. This is exactly the shape a FUNCTION can't cleanly take: several
-- chained DML statements for a side effect (create a booking), not a value
-- to plug into a SELECT. RAISE NOTICE stands in for what an app would read
-- back as a result/log line.
CREATE OR REPLACE PROCEDURE book_seat(
    p_user_email VARCHAR,
    p_event_title VARCHAR,
    p_venue_name VARCHAR,
    p_seat_row VARCHAR,
    p_seat_number VARCHAR
)
AS
$$
DECLARE
    v_event_seat_id event_seats.event_seat_id%TYPE;
    v_event_id      event_seats.event_id%TYPE;
    v_price         event_seats.price%TYPE;
    v_booking_id    bookings.booking_id%TYPE;
    v_reference     bookings.booking_reference%TYPE;
BEGIN
    -- Hold the seat, but only if it's still available -- same optimistic-lock
    -- shape as the raw-SQL version in crud-examples.sql, just named now.
    -- The join chain (seat -> its venue -> events at that venue) also means
    -- this can never match a seat against an event at a different venue.
    UPDATE event_seats es
    SET status     = 'held',
        held_until = now() + INTERVAL '15 minutes',
        version    = es.version + 1
    FROM seats s
             JOIN venues v ON v.venue_id = s.venue_id
             JOIN events ev ON ev.venue_id = v.venue_id
    WHERE es.seat_id = s.seat_id
      AND es.event_id = ev.event_id
      AND ev.title = p_event_title
      AND v.name = p_venue_name
      AND s.seat_row = p_seat_row
      AND s.seat_number = p_seat_number
      AND es.status = 'available'
    RETURNING es.event_seat_id, es.event_id, es.price
        INTO v_event_seat_id, v_event_id, v_price;

    IF v_event_seat_id IS NULL THEN
        RAISE EXCEPTION 'seat % % at % for % is not available',
            p_seat_row, p_seat_number, p_venue_name, p_event_title;
    END IF;

    INSERT INTO bookings (user_id, event_id, status, total_amount)
    SELECT up.user_id, v_event_id, 'pending', v_price
    FROM user_profiles up
    WHERE up.email = p_user_email
    RETURNING booking_id, booking_reference INTO v_booking_id, v_reference;

    INSERT INTO booking_seats (booking_id, event_seat_id)
    VALUES (v_booking_id, v_event_seat_id);

    RAISE NOTICE 'booking % created for % (seat % %)',
        v_reference, p_user_email, p_seat_row, p_seat_number;
END;
$$ LANGUAGE plpgsql;

-- Example:
-- CALL book_seat('grace.kim@example.com', 'Autumn Jazz Night', 'Waterfront Arena', 'B', '2');


-- The same workflow, written as plain LANGUAGE sql instead of plpgsql --
-- possible here because the whole thing collapses into ONE statement via
-- chained CTEs (same technique as the book-a-seat example in
-- crud-examples.sql), so there's no DECLARE/INTO or branching needed.
-- The real trade-off: if the seat isn't available, held_seat returns 0
-- rows, so new_booking and the final INSERT also produce 0 rows -- this
-- version just silently does nothing. There's no RAISE EXCEPTION available
-- in plain SQL, so the caller gets no error, no notice, no signal that the
-- booking didn't happen. That's the real reason book_seat above is
-- PL/pgSQL: not because the logic needs it, but because reporting failure
-- clearly does.
CREATE OR REPLACE PROCEDURE book_seat_sql(
    p_user_email VARCHAR,
    p_event_title VARCHAR,
    p_venue_name VARCHAR,
    p_seat_row VARCHAR,
    p_seat_number VARCHAR
)
AS
$$
WITH held_seat AS (
    UPDATE event_seats es
    SET status     = 'held',
        held_until = now() + INTERVAL '15 minutes',
        version    = es.version + 1
    FROM seats s
             JOIN venues v ON v.venue_id = s.venue_id
             JOIN events ev ON ev.venue_id = v.venue_id
    WHERE es.seat_id = s.seat_id
      AND es.event_id = ev.event_id
      AND ev.title = p_event_title
      AND v.name = p_venue_name
      AND s.seat_row = p_seat_row
      AND s.seat_number = p_seat_number
      AND es.status = 'available'
    RETURNING es.event_seat_id, es.event_id, es.price
),
     new_booking AS (
         INSERT INTO bookings (user_id, event_id, status, total_amount)
             SELECT up.user_id, held_seat.event_id, 'pending', held_seat.price
             FROM held_seat
                      JOIN user_profiles up ON up.email = p_user_email
             RETURNING booking_id
     )
INSERT INTO booking_seats (booking_id, event_seat_id)
SELECT new_booking.booking_id, held_seat.event_seat_id
FROM new_booking, held_seat;
$$ LANGUAGE sql;

-- Example:
-- CALL book_seat_sql('grace.kim@example.com', 'Autumn Jazz Night', 'Waterfront Arena', 'B', '2');


-- book_seat's counterpart: the three coordinated writes a cancellation
-- needs -- bookings.status, booking_seats.released_at, event_seats back to
-- 'available' -- wrapped into one call instead of hand-written each time
-- (see the manual version in crud-examples.sql). Idempotent by design: an
-- already-cancelled/expired booking is a no-op, not an error, since a
-- caller retrying a cancel shouldn't be punished for it. An unknown
-- reference IS a real error -- that one means the caller passed something
-- wrong, not something already handled.
--
-- Cancellation policy: a full refund only applies more than v_refund_window
-- before the event starts. Inside that window -- a "close cancellation" --
-- the booking is still released like any other, but any payment already
-- made is kept, not refunded. This is a policy DECISION the procedure
-- makes, not a choice exposed to the caller: if refund-vs-not were two
-- separately named procedures, nothing would stop an app from always
-- calling the refund one, which defeats having a policy at all.
CREATE OR REPLACE PROCEDURE cancel_booking(p_booking_reference VARCHAR)
AS
$$
DECLARE
    v_refund_window   CONSTANT INTERVAL := '48 hours';
    v_booking_id      bookings.booking_id%TYPE;
    v_status          bookings.status%TYPE;
    v_starts_at       events.starts_at%TYPE;
    v_refund_eligible BOOLEAN;
    v_released_count  INTEGER;
    v_refunded_count  INTEGER;
BEGIN
    SELECT bk.booking_id, bk.status, ev.starts_at
    INTO v_booking_id, v_status, v_starts_at
    FROM bookings bk
             JOIN events ev ON ev.event_id = bk.event_id
    WHERE bk.booking_reference = p_booking_reference;

    IF v_booking_id IS NULL THEN
        RAISE EXCEPTION 'no booking found with reference %', p_booking_reference;
    END IF;

    IF v_status IN ('cancelled', 'expired') THEN
        RAISE NOTICE 'booking % is already % -- nothing to do', p_booking_reference, v_status;
        RETURN;
    END IF;

    v_refund_eligible := now() <= v_starts_at - v_refund_window;

    UPDATE bookings
    SET status = 'cancelled'
    WHERE booking_id = v_booking_id;
    -- set_booking_status_timestamps() sets cancelled_at automatically

    UPDATE booking_seats
    SET released_at = now()
    WHERE booking_id = v_booking_id
      AND released_at IS NULL;
    GET DIAGNOSTICS v_released_count = ROW_COUNT;

    UPDATE event_seats es
    SET status     = 'available',
        held_until = NULL,
        version    = es.version + 1
    FROM booking_seats bs
    WHERE es.event_seat_id = bs.event_seat_id
      AND bs.booking_id = v_booking_id;

    v_refunded_count := 0;
    IF v_refund_eligible THEN
        UPDATE payments
        SET status = 'refunded'
        WHERE booking_id = v_booking_id
          AND status = 'succeeded';
        GET DIAGNOSTICS v_refunded_count = ROW_COUNT;
    END IF;

    RAISE NOTICE 'booking % cancelled, % seat(s) released, refund %',
        p_booking_reference, v_released_count,
        CASE
            WHEN NOT v_refund_eligible THEN 'not issued (close cancellation, inside ' || v_refund_window || ')'
            WHEN v_refunded_count > 0 THEN 'issued'
            ELSE 'not applicable (nothing was paid)'
            END;
END;
$$ LANGUAGE plpgsql;

-- Examples:
-- CALL cancel_booking('BK-0002');  -- pending, unpaid -- released, refund question doesn't apply
-- CALL cancel_booking('BK-0001');  -- confirmed + paid, event weeks out -- released AND refunded
--
-- Every event in the current seed data is weeks or months out from "today,"
-- so no existing booking actually lands inside the 48-hour window -- there's
-- nothing to CALL right now that demonstrates the no-refund path. To see it:
-- UPDATE events SET starts_at = now() + interval '1 hour' WHERE title = 'Broadway Night';
-- CALL cancel_booking('BK-0006');  -- now inside the window -- released, refund withheld


-- The clearest case for a procedure over a function: this one COMMITs
-- between batches, releasing locks and making progress durable as it goes,
-- instead of holding one giant transaction open for every stale hold in the
-- system at once. A function structurally cannot do this -- it always runs
-- inside whatever transaction called it. Meant to be invoked periodically
-- (pg_cron, or an external scheduler calling CALL), not from inside a query.
CREATE OR REPLACE PROCEDURE expire_stale_holds(p_batch_size INTEGER DEFAULT 500)
AS
$$
DECLARE
    v_rows INTEGER;
BEGIN
    LOOP
        UPDATE event_seats
        SET status     = 'available',
            held_until = NULL,
            version    = version + 1
        WHERE event_seat_id IN (
            SELECT event_seat_id
            FROM event_seats
            WHERE status = 'held'
              AND held_until < now()
            LIMIT p_batch_size
        );

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        COMMIT; -- only legal here because this is a PROCEDURE, not a FUNCTION

        EXIT WHEN v_rows < p_batch_size;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Example:
-- CALL expire_stale_holds();
