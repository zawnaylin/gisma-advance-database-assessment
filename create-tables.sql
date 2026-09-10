CREATE TABLE users
(
    user_id       INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    name          VARCHAR(100)             NOT NULL,
    email         VARCHAR(255)             NOT NULL,
    password_hash VARCHAR(255)             NOT NULL,
    role          VARCHAR(20)              NOT NULL DEFAULT 'customer',
    created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_users_email UNIQUE (email),
    CONSTRAINT chk_users_role CHECK (role IN ('customer', 'admin', 'organizer'))
);

CREATE TABLE venues
(
    venue_id       INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    name           VARCHAR(150) NOT NULL,
    address        VARCHAR(255),
    city           VARCHAR(100),
    total_capacity INTEGER,
    time_zone      VARCHAR(64),
    CONSTRAINT fk_venues_time_zone FOREIGN KEY (time_zone) REFERENCES time_zones (name),
    CONSTRAINT chk_venues_capacity CHECK (total_capacity IS NULL OR total_capacity >= 0)
);

-- Timezone Lookup Table for Venues
CREATE TABLE time_zones
(
    name VARCHAR(64) PRIMARY KEY
);

CREATE TABLE seats
(
    seat_id     INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    venue_id    INTEGER     NOT NULL,
    seat_row    VARCHAR(10) NOT NULL,
    seat_number VARCHAR(10) NOT NULL,
    seat_tier   VARCHAR(30),
    CONSTRAINT fk_seats_venue FOREIGN KEY (venue_id)
        REFERENCES venues (venue_id) ON DELETE CASCADE,
    CONSTRAINT uq_seats_venue_row_number UNIQUE (venue_id, seat_row, seat_number)
);

CREATE TABLE events
(
    event_id   INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    venue_id   INTEGER                  NOT NULL,
    title      VARCHAR(200)             NOT NULL,
    starts_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    ends_at    TIMESTAMP WITH TIME ZONE,
    status     VARCHAR(20)              NOT NULL DEFAULT 'scheduled',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_events_venue FOREIGN KEY (venue_id)
        REFERENCES venues (venue_id) ON DELETE RESTRICT,
    CONSTRAINT chk_events_status
        CHECK (status IN ('scheduled', 'on_sale', 'sold_out', 'cancelled', 'completed')),
    CONSTRAINT chk_events_starts_ends_at
        CHECK (ends_at IS NULL OR ends_at > starts_at)
);

CREATE INDEX idx_events_venue ON events (venue_id);
CREATE INDEX idx_events_starts_at ON events (starts_at);

-- a physical seat made available for a specific event, with its own price / availability / optimistic-lock version

CREATE TABLE event_seats
(
    event_seat_id INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    event_id      INTEGER        NOT NULL,
    seat_id       INTEGER        NOT NULL,
    price         NUMERIC(10, 2) NOT NULL,
    status        VARCHAR(20)    NOT NULL DEFAULT 'available',
    version       INTEGER        NOT NULL DEFAULT 0,
    held_until    TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_event_seats_event FOREIGN KEY (event_id) REFERENCES events (event_id) ON DELETE CASCADE,
    CONSTRAINT fk_event_seats_seat FOREIGN KEY (seat_id) REFERENCES seats (seat_id) ON DELETE RESTRICT,
    CONSTRAINT uq_event_seats_event_seat UNIQUE (event_id, seat_id),
    CONSTRAINT chk_event_seats_price CHECK (price >= 0),
    CONSTRAINT chk_event_seats_version CHECK (version >= 0),
    CONSTRAINT chk_event_seats_status CHECK (status IN ('available', 'held', 'booked'))
);

CREATE INDEX idx_event_seats_seat ON event_seats (seat_id);
CREATE INDEX idx_event_seats_event_status ON event_seats (event_id, status);

CREATE TABLE bookings
(
    booking_id   INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id      INTEGER                  NOT NULL,
    event_id     INTEGER                  NOT NULL,
    status       VARCHAR(20)              NOT NULL DEFAULT 'pending',
    total_amount NUMERIC(10, 2)           NOT NULL DEFAULT 0,
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    confirmed_at TIMESTAMP WITH TIME ZONE,
    cancelled_at TIMESTAMP WITH TIME ZONE,
    updated_at   TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_bookings_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE RESTRICT,
    CONSTRAINT fk_bookings_event FOREIGN KEY (event_id) REFERENCES events (event_id) ON DELETE RESTRICT,
    CONSTRAINT chk_bookings_total_amount CHECK (total_amount >= 0),
    CONSTRAINT chk_bookings_status
        CHECK (status IN ('pending', 'confirmed', 'cancelled', 'expired')),
    CONSTRAINT chk_bookings_confirmed_at
        CHECK ((status = 'confirmed' AND confirmed_at IS NOT NULL) OR
               (status <> 'confirmed')),
    CONSTRAINT chk_bookings_cancelled_at
        CHECK ((status = 'cancelled' AND cancelled_at IS NOT NULL) OR status <> 'cancelled')
);

CREATE INDEX idx_bookings_user ON bookings (user_id);
CREATE INDEX idx_bookings_event ON bookings (event_id);


-- join: which event_seats a booking reserves

CREATE TABLE booking_seats
(
    booking_seat_id INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    booking_id      INTEGER NOT NULL,
    event_seat_id   INTEGER NOT NULL,
    CONSTRAINT fk_booking_seats_booking FOREIGN KEY (booking_id) REFERENCES bookings (booking_id) ON DELETE CASCADE,
    CONSTRAINT fk_booking_seats_event_seat FOREIGN KEY (event_seat_id) REFERENCES event_seats (event_seat_id) ON DELETE RESTRICT,
    -- a given event seat can only belong to one active booking row
    CONSTRAINT uq_booking_seats_event_seat UNIQUE (event_seat_id)
);

CREATE INDEX idx_booking_seats_booking ON booking_seats (booking_id);

CREATE TABLE payments
(
    payment_id     INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    booking_id     INTEGER        NOT NULL,
    amount         NUMERIC(10, 2) NOT NULL,
    payment_method VARCHAR(30)    NOT NULL,
    status         VARCHAR(20)    NOT NULL DEFAULT 'pending',
    paid_at        TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_payments_booking FOREIGN KEY (booking_id) REFERENCES bookings (booking_id) ON DELETE CASCADE,
    CONSTRAINT uq_payments_booking UNIQUE (booking_id),
    CONSTRAINT chk_payments_amount CHECK (amount >= 0),
    CONSTRAINT chk_payments_status CHECK (status IN ('pending', 'succeeded', 'failed', 'refunded'))
);

-- Auto update function to populate updated_at column in tables
CREATE OR REPLACE FUNCTION set_updated_at()
    RETURNS TRIGGER AS
$$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER users_before_update
    BEFORE UPDATE
    ON users
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE TRIGGER events_before_update
    BEFORE UPDATE
    ON events
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- For booking status, if it is confirmed or cancelled,
-- update confirmed_at and cancelled_at field respectively
-- and updated_at field is updated accordingly

CREATE OR REPLACE FUNCTION set_booking_status_timestamps()
    RETURNS TRIGGER AS
$$
BEGIN
    IF NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed' THEN
        NEW.confirmed_at = NOW();
    ELSIF NEW.status = 'cancelled' AND OLD.staus IS DISTINCT FROM 'cancelled' THEN
        NEW.cancelled_at = NOW();
    END IF;
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER booking_before_update
    BEFORE UPDATE
    ON bookings
    FOR EACH ROW
EXECUTE FUNCTION set_booking_status_timestamps();