-- Functions and procedures for the schema in create-tables.sql.
-- Run after create-tables.sql and load-seed-data.sql.

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Available seats for an event.
-- SELECT * FROM get_available_seats('Autumn Jazz Night', 'Waterfront Arena');
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


-- Sum of seat prices for a booking.
-- SELECT calculate_booking_total(1);
CREATE OR REPLACE FUNCTION calculate_booking_total(p_booking_id INTEGER)
    RETURNS NUMERIC
AS
$$
SELECT COALESCE(SUM(es.price), 0)
FROM booking_seats bs
         JOIN event_seats es ON es.event_seat_id = bs.event_seat_id
WHERE bs.booking_id = p_booking_id;
$$ LANGUAGE sql STABLE;


-- Trigger: recalculates bookings.total_amount when booking_seats changes.
CREATE OR REPLACE FUNCTION sync_booking_total()
    RETURNS TRIGGER
AS
$$
BEGIN
    UPDATE bookings
    SET total_amount = calculate_booking_total(COALESCE(NEW.booking_id, OLD.booking_id))
    WHERE booking_id = COALESCE(NEW.booking_id, OLD.booking_id);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER booking_seats_sync_total
    AFTER INSERT OR DELETE
    ON booking_seats
    FOR EACH ROW
EXECUTE FUNCTION sync_booking_total();

-- =============================================================================
-- PROCEDURES
-- =============================================================================

-- Holds a seat and creates a pending booking.
-- p_expected_version: optional optimistic-lock check (SQLSTATE 40001 on mismatch).
-- CALL book_seat('grace.kim@example.com', 'Autumn Jazz Night', 'Waterfront Arena', 'B', '2');
-- CALL book_seat('grace.kim@example.com', 'Autumn Jazz Night', 'Waterfront Arena', 'B', '2', 0);

-- Remove the old 5-argument signature.
DROP PROCEDURE IF EXISTS book_seat(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);

CREATE OR REPLACE PROCEDURE book_seat(
    p_user_email VARCHAR,
    p_event_title VARCHAR,
    p_venue_name VARCHAR,
    p_seat_row VARCHAR,
    p_seat_number VARCHAR,
    p_expected_version INTEGER DEFAULT NULL
)
AS
$$
DECLARE
    v_event_seat_id   event_seats.event_seat_id%TYPE;
    v_event_id        event_seats.event_id%TYPE;
    v_price           event_seats.price%TYPE;
    v_current_version event_seats.version%TYPE;
    v_booking_id      bookings.booking_id%TYPE;
    v_reference       bookings.booking_reference%TYPE;
BEGIN
    SELECT es.event_seat_id
    INTO v_event_seat_id
    FROM event_seats es
             JOIN seats s ON s.seat_id = es.seat_id
             JOIN events ev ON ev.event_id = es.event_id
             JOIN venues v ON v.venue_id = ev.venue_id AND v.venue_id = s.venue_id
    WHERE ev.title = p_event_title
      AND v.name = p_venue_name
      AND s.seat_row = p_seat_row
      AND s.seat_number = p_seat_number;

    IF v_event_seat_id IS NULL THEN
        RAISE EXCEPTION 'no seat % % at % for %',
            p_seat_row, p_seat_number, p_venue_name, p_event_title;
    END IF;

    UPDATE event_seats
    SET status     = 'held',
        held_until = now() + INTERVAL '15 minutes',
        version    = version + 1
    WHERE event_seat_id = v_event_seat_id
      AND status = 'available'
      AND (p_expected_version IS NULL OR version = p_expected_version)
    RETURNING event_id, price
        INTO v_event_id, v_price;

    IF NOT FOUND THEN
        SELECT version INTO v_current_version
        FROM event_seats
        WHERE event_seat_id = v_event_seat_id;

        IF p_expected_version IS NOT NULL AND v_current_version <> p_expected_version THEN
            RAISE EXCEPTION 'seat % % was changed by another transaction (read version %, now %)',
                p_seat_row, p_seat_number, p_expected_version, v_current_version
                USING ERRCODE = 'serialization_failure',
                      HINT = 'Re-read the seat and retry.';
        END IF;

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


-- Books the first available, unlocked seat (FOR UPDATE SKIP LOCKED), optionally by tier.
-- CALL book_any_seat('grace.kim@example.com', 'Autumn Jazz Night', 'Waterfront Arena', 'standard');
CREATE OR REPLACE PROCEDURE book_any_seat(
    p_user_email VARCHAR,
    p_event_title VARCHAR,
    p_venue_name VARCHAR,
    p_seat_tier VARCHAR DEFAULT NULL
)
AS
$$
DECLARE
    v_seat_row    seats.seat_row%TYPE;
    v_seat_number seats.seat_number%TYPE;
BEGIN
    SELECT s.seat_row, s.seat_number
    INTO v_seat_row, v_seat_number
    FROM event_seats es
             JOIN seats s ON s.seat_id = es.seat_id
             JOIN events ev ON ev.event_id = es.event_id
             JOIN venues v ON v.venue_id = ev.venue_id
    WHERE ev.title = p_event_title
      AND v.name = p_venue_name
      AND es.status = 'available'
      AND (p_seat_tier IS NULL OR s.seat_tier = p_seat_tier)
    ORDER BY s.seat_row, s.seat_number
    LIMIT 1
    FOR UPDATE OF es SKIP LOCKED;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no available %seat at % for %',
            COALESCE(p_seat_tier || ' ', ''), p_venue_name, p_event_title;
    END IF;

    CALL book_seat(p_user_email, p_event_title, p_venue_name, v_seat_row, v_seat_number);
END;
$$ LANGUAGE plpgsql;


-- book_seat in plain SQL. Does nothing (no error) if the seat is unavailable.
-- CALL book_seat_sql('grace.kim@example.com', 'Autumn Jazz Night', 'Waterfront Arena', 'B', '2');
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


-- Cancels a booking and frees its seats. Refunds if more than 48h before the event.
-- No-op if already cancelled/expired.
-- CALL cancel_booking('BK-0001');
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


-- Expires pending bookings whose holds have lapsed and frees their seats.
-- Commits after each batch of p_batch_size.
-- CALL expire_stale_holds();
CREATE OR REPLACE PROCEDURE expire_stale_holds(p_batch_size INTEGER DEFAULT 500)
AS
$$
DECLARE
    v_booking_ids    INTEGER[];
    v_bookings       INTEGER;
    v_seats          INTEGER;
    v_orphans        INTEGER;
    v_total_bookings INTEGER := 0;
    v_total_seats    INTEGER := 0;
BEGIN
    LOOP
        -- Pending bookings with a lapsed hold.
        SELECT array_agg(booking_id)
        INTO v_booking_ids
        FROM (SELECT bk.booking_id
              FROM bookings bk
              WHERE bk.status = 'pending'
                AND EXISTS (SELECT 1
                            FROM booking_seats bs
                                     JOIN event_seats es ON es.event_seat_id = bs.event_seat_id
                            WHERE bs.booking_id = bk.booking_id
                              AND bs.released_at IS NULL
                              AND es.status = 'held'
                              AND es.held_until < now())
              LIMIT p_batch_size
              FOR UPDATE OF bk SKIP LOCKED) stale;
        v_bookings := COALESCE(cardinality(v_booking_ids), 0);

        -- Expire bookings, free seats, release claims.
        UPDATE bookings
        SET status = 'expired'
        WHERE booking_id = ANY (v_booking_ids);

        UPDATE event_seats es
        SET status     = 'available',
            held_until = NULL,
            version    = es.version + 1
        FROM booking_seats bs
        WHERE es.event_seat_id = bs.event_seat_id
          AND bs.booking_id = ANY (v_booking_ids)
          AND bs.released_at IS NULL
          AND es.status = 'held';
        GET DIAGNOSTICS v_seats = ROW_COUNT;

        UPDATE booking_seats
        SET released_at = now()
        WHERE booking_id = ANY (v_booking_ids)
          AND released_at IS NULL;

        -- Lapsed holds with no booking.
        UPDATE event_seats
        SET status     = 'available',
            held_until = NULL,
            version    = version + 1
        WHERE event_seat_id IN (SELECT es.event_seat_id
                                FROM event_seats es
                                WHERE es.status = 'held'
                                  AND es.held_until < now()
                                  AND NOT EXISTS (SELECT 1
                                                  FROM booking_seats bs
                                                  WHERE bs.event_seat_id = es.event_seat_id
                                                    AND bs.released_at IS NULL)
                                LIMIT p_batch_size
                                FOR UPDATE SKIP LOCKED);
        GET DIAGNOSTICS v_orphans = ROW_COUNT;

        COMMIT;

        v_total_bookings := v_total_bookings + v_bookings;
        v_total_seats := v_total_seats + v_seats + v_orphans;

        EXIT WHEN v_bookings < p_batch_size AND v_orphans < p_batch_size;
    END LOOP;

    RAISE NOTICE 'expired % booking(s), released % held seat(s)', v_total_bookings, v_total_seats;
END;
$$ LANGUAGE plpgsql;
