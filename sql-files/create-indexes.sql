-- Indexes for the schema in create-tables.sql.
-- Indexes already created implicitly by a PRIMARY KEY or UNIQUE constraint
-- in create-tables.sql are not repeated here.

-- events
CREATE INDEX idx_events_venue ON events (venue_id);
CREATE INDEX idx_events_starts_at ON events (starts_at);

-- event_seats
CREATE INDEX idx_event_seats_seat ON event_seats (seat_id);
CREATE INDEX idx_event_seats_event_status ON event_seats (event_id, status);

-- bookings
CREATE INDEX idx_bookings_user ON bookings (user_id);
CREATE INDEX idx_bookings_event ON bookings (event_id);

-- booking_seats
CREATE INDEX idx_booking_seats_booking ON booking_seats (booking_id);
