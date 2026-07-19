-- ============================================================
-- V001__init.sql
-- Flyway baseline migration — single source of truth for the
-- entire ticket system database schema. Applied automatically
-- by Flyway on first container start via docker-compose.
-- Manages: events, orders, payments schemas.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS events;
CREATE SCHEMA IF NOT EXISTS orders;
CREATE SCHEMA IF NOT EXISTS payments;

-- ============================================================
-- EVENTS SCHEMA
-- ============================================================

-- Shared trigger function used by all events.* tables that
-- carry an updated_at column.
CREATE OR REPLACE FUNCTION events.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─── Enum types ───────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'space_type_enum') THEN
        CREATE TYPE events.space_type_enum AS ENUM ('SEATED', 'GENERAL_ADMISSION');
    END IF;
END$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'seat_status_enum') THEN
        CREATE TYPE events.seat_status_enum AS ENUM ('AVAILABLE', 'HELD', 'SOLD');
    END IF;
END$$;

-- ─── events.venues ────────────────────────────────────────────
-- Parent of events, spaces; required for FK chain → spaces → sessions → session_seats.
-- Must be created before events.events (which carries fk_events_venue).
CREATE TABLE events.venues (
    id         UUID      NOT NULL,
    name       TEXT      NOT NULL,
    address    TEXT      NOT NULL,
    city       TEXT      NOT NULL,
    state      TEXT      NOT NULL,
    country    TEXT      NOT NULL,
    metadata   JSONB,
    active     BOOLEAN   NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_venues PRIMARY KEY (id)
);

CREATE INDEX idx_venues_city       ON events.venues (city);
CREATE INDEX idx_venues_city_state ON events.venues (city, state);

CREATE TRIGGER trg_venues_set_updated_at
BEFORE UPDATE ON events.venues
FOR EACH ROW EXECUTE FUNCTION events.set_updated_at();

-- ─── events.events ────────────────────────────────────────────
-- Rewritten to match EventRepository.cs and EventQueryRepository.cs.
-- Removed: title, duration_minutes, age_rating, is_national, metadata, active.
-- Added:   name, created_by, status, occurred_at, created_source.
CREATE TABLE events.events (
    id             UUID         NOT NULL,
    name           TEXT         NOT NULL,
    description    TEXT,
    created_by     TEXT         NOT NULL,
    created_source VARCHAR(20)  NOT NULL,
    venue_id       UUID         NOT NULL,
    status         TEXT         NOT NULL DEFAULT 'ACTIVE',
    created_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    occurred_at    TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_events       PRIMARY KEY (id),
    CONSTRAINT fk_events_venue FOREIGN KEY (venue_id) REFERENCES events.venues (id),
    CONSTRAINT chk_events_created_source CHECK (created_source IN ('SEED', 'ADMIN'))
);

-- EventQueryRepository: ORDER BY occurred_at DESC
CREATE INDEX idx_events_occurred_at ON events.events (occurred_at DESC);
-- EventQueryRepository: status filter (list)
CREATE INDEX idx_events_status ON events.events (status);

CREATE TRIGGER trg_events_set_updated_at
BEFORE UPDATE ON events.events
FOR EACH ROW EXECUTE FUNCTION events.set_updated_at();

-- ─── events.spaces ────────────────────────────────────────────
-- Parent of sessions and space_seats.
CREATE TABLE events.spaces (
    id         UUID                    NOT NULL,
    venue_id   UUID                    NOT NULL,
    name       TEXT                    NOT NULL,
    space_type events.space_type_enum  NOT NULL,
    metadata   JSONB,
    active     BOOLEAN                 NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP               NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP               NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_spaces      PRIMARY KEY (id),
    CONSTRAINT fk_spaces_venue FOREIGN KEY (venue_id) REFERENCES events.venues (id)
);

CREATE INDEX idx_spaces_venue        ON events.spaces (venue_id);
CREATE INDEX idx_spaces_venue_active ON events.spaces (venue_id, active);

CREATE TRIGGER trg_spaces_set_updated_at
BEFORE UPDATE ON events.spaces
FOR EACH ROW EXECUTE FUNCTION events.set_updated_at();

-- ─── events.space_seats ───────────────────────────────────────
-- Physical seats in a SEATED space; referenced by session_seats.
CREATE TABLE events.space_seats (
    id          UUID    NOT NULL,
    space_id    UUID    NOT NULL,
    row         TEXT    NOT NULL,
    seat_column INT     NOT NULL,
    label       TEXT    NOT NULL,
    active      BOOLEAN NOT NULL DEFAULT TRUE,
    metadata    JSONB,
    CONSTRAINT pk_space_seats       PRIMARY KEY (id),
    CONSTRAINT fk_space_seats_space FOREIGN KEY (space_id) REFERENCES events.spaces (id),
    CONSTRAINT uq_space_seats_position UNIQUE (space_id, row, seat_column)
);

CREATE INDEX idx_space_seats_space ON events.space_seats (space_id);

CREATE OR REPLACE FUNCTION events.validate_space_type_seated()
RETURNS TRIGGER AS $$
DECLARE
    v_space_type events.space_type_enum;
BEGIN
    SELECT space_type INTO v_space_type FROM events.spaces WHERE id = NEW.space_id;
    IF v_space_type IS NULL THEN
        RAISE EXCEPTION 'Space not found';
    END IF;
    IF v_space_type <> 'SEATED' THEN
        RAISE EXCEPTION 'Cannot insert seat into non-SEATED space';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_space_seats_validate_space_type
BEFORE INSERT OR UPDATE ON events.space_seats
FOR EACH ROW EXECUTE FUNCTION events.validate_space_type_seated();

-- ─── events.sessions ──────────────────────────────────────────
-- Parent of session_seats and session_ticket_types.
CREATE TABLE events.sessions (
    id             UUID                   NOT NULL,
    event_id       UUID                   NOT NULL,
    space_id       UUID                   NOT NULL,
    space_type     events.space_type_enum NOT NULL,
    starts_at      TIMESTAMP              NOT NULL,
    ends_at        TIMESTAMP              NOT NULL,
    status         TEXT                   NOT NULL,
    created_source VARCHAR(20)            NOT NULL,
    created_by     VARCHAR(100),
    metadata       JSONB,
    attributes     JSONB,
    created_at     TIMESTAMP              NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMP              NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_sessions        PRIMARY KEY (id),
    CONSTRAINT fk_sessions_event  FOREIGN KEY (event_id)  REFERENCES events.events (id),
    CONSTRAINT fk_sessions_space  FOREIGN KEY (space_id)  REFERENCES events.spaces (id),
    CONSTRAINT chk_sessions_time  CHECK (starts_at < ends_at),
    CONSTRAINT chk_sessions_created_source CHECK (created_source IN ('SEED', 'ADMIN'))
);

CREATE INDEX idx_sessions_event     ON events.sessions (event_id);
CREATE INDEX idx_sessions_space     ON events.sessions (space_id);
CREATE INDEX idx_sessions_starts_at ON events.sessions (starts_at);
CREATE INDEX idx_sessions_attributes_gin ON events.sessions USING GIN (attributes);

CREATE TRIGGER trg_sessions_set_updated_at
BEFORE UPDATE ON events.sessions
FOR EACH ROW EXECUTE FUNCTION events.set_updated_at();

CREATE OR REPLACE FUNCTION events.validate_session_space_type()
RETURNS TRIGGER AS $$
DECLARE
    v_space_type events.space_type_enum;
BEGIN
    SELECT space_type INTO v_space_type FROM events.spaces WHERE id = NEW.space_id;
    IF v_space_type IS NULL THEN
        RAISE EXCEPTION 'Space not found';
    END IF;
    IF NEW.space_type <> v_space_type THEN
        RAISE EXCEPTION 'Session space_type does not match space';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sessions_validate_space_type
BEFORE INSERT OR UPDATE ON events.sessions
FOR EACH ROW EXECUTE FUNCTION events.validate_session_space_type();

-- ─── events.session_seats ─────────────────────────────────────
-- Seat inventory for SEATED sessions.
-- Queried by SessionRepository: HoldSeatsByIdAsync, ReleaseSeatsByIdAsync.
-- PK (session_id, seat_id) serves the compound WHERE filters efficiently.
CREATE TABLE events.session_seats (
    session_id       UUID                   NOT NULL,
    seat_id          UUID                   NOT NULL,
    status           events.seat_status_enum NOT NULL,
    updated_at       TIMESTAMP              NOT NULL DEFAULT NOW(),
    held_by_order_id UUID,
    CONSTRAINT pk_session_seats         PRIMARY KEY (session_id, seat_id),
    CONSTRAINT fk_session_seats_session FOREIGN KEY (session_id) REFERENCES events.sessions (id),
    CONSTRAINT fk_session_seats_seat    FOREIGN KEY (seat_id)    REFERENCES events.space_seats (id)
);

-- Supports status-based lookups and status filtering in hold/release queries.
CREATE INDEX idx_session_seats_status ON events.session_seats (session_id, status);

CREATE OR REPLACE FUNCTION events.validate_session_seated()
RETURNS TRIGGER AS $$
DECLARE
    v_space_type events.space_type_enum;
BEGIN
    SELECT space_type INTO v_space_type FROM events.sessions WHERE id = NEW.session_id;
    IF v_space_type IS NULL THEN
        RAISE EXCEPTION 'Session not found';
    END IF;
    IF v_space_type <> 'SEATED' THEN
        RAISE EXCEPTION 'Session must be SEATED';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION events.validate_seat_belongs_to_space()
RETURNS TRIGGER AS $$
DECLARE
    v_space_id      UUID;
    v_seat_space_id UUID;
BEGIN
    SELECT space_id INTO v_space_id     FROM events.sessions    WHERE id = NEW.session_id;
    SELECT space_id INTO v_seat_space_id FROM events.space_seats WHERE id = NEW.seat_id;
    IF v_space_id IS NULL OR v_seat_space_id IS NULL THEN
        RAISE EXCEPTION 'Invalid session or seat';
    END IF;
    IF v_space_id <> v_seat_space_id THEN
        RAISE EXCEPTION 'Seat does not belong to session space';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_session_seats_validate_session
BEFORE INSERT OR UPDATE ON events.session_seats
FOR EACH ROW EXECUTE FUNCTION events.validate_session_seated();

CREATE TRIGGER trg_session_seats_validate_seat
BEFORE INSERT OR UPDATE ON events.session_seats
FOR EACH ROW EXECUTE FUNCTION events.validate_seat_belongs_to_space();

-- ─── events.session_ticket_types ──────────────────────────────
-- GA and SEATED ticket categories per session.
-- Queried by SessionRepository: IsSalesEnabledAsync, TryDecreaseInventoryAsync,
-- RestoreInventoryAsync.
CREATE TABLE events.session_ticket_types (
    id              UUID          NOT NULL,
    session_id      UUID          NOT NULL,
    name            TEXT          NOT NULL,
    description     TEXT,
    price           NUMERIC(10,2) NOT NULL,
    quota           INT           NOT NULL,
    quota_available INT           NOT NULL,
    sales_enabled   BOOLEAN       NOT NULL DEFAULT FALSE,
    created_source  VARCHAR(20)   NOT NULL,
    created_by      VARCHAR(100),
    metadata        JSONB,
    active          BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP     NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_session_ticket_types         PRIMARY KEY (id),
    CONSTRAINT fk_session_ticket_types_session FOREIGN KEY (session_id) REFERENCES events.sessions (id),
    CONSTRAINT chk_price_non_negative          CHECK (price >= 0),
    CONSTRAINT chk_quota_positive              CHECK (quota > 0),
    CONSTRAINT chk_quota_available_non_negative CHECK (quota_available >= 0),
    CONSTRAINT chk_quota_available_within_quota CHECK (quota_available <= quota),
    CONSTRAINT chk_ticket_types_created_source  CHECK (created_source IN ('SEED', 'ADMIN'))
);

CREATE INDEX idx_ticket_types_session      ON events.session_ticket_types (session_id);
CREATE INDEX idx_ticket_types_active       ON events.session_ticket_types (session_id) WHERE active = TRUE;
CREATE INDEX idx_ticket_types_sales_enabled ON events.session_ticket_types (session_id) WHERE sales_enabled = TRUE;

CREATE TRIGGER trg_session_ticket_types_set_updated_at
BEFORE UPDATE ON events.session_ticket_types
FOR EACH ROW EXECUTE FUNCTION events.set_updated_at();

-- ─── events.seat_holds ────────────────────────────────────────
-- GA idempotency guard for inventory holds.
-- ON CONFLICT (order_id, session_id, ticket_type_id) DO NOTHING
-- relies on the PRIMARY KEY below.
CREATE TABLE events.seat_holds (
    order_id       UUID        NOT NULL,
    session_id     UUID        NOT NULL,
    ticket_type_id UUID        NOT NULL,
    quantity       INT         NOT NULL,
    held_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (order_id, session_id, ticket_type_id)
);

-- ─── events.seat_releases ─────────────────────────────────────
-- GA idempotency guard for inventory releases.
-- ON CONFLICT (order_id, session_id, ticket_type_id) DO NOTHING
-- relies on the PRIMARY KEY below.
CREATE TABLE events.seat_releases (
    order_id       UUID        NOT NULL,
    session_id     UUID        NOT NULL,
    ticket_type_id UUID        NOT NULL,
    released_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (order_id, session_id, ticket_type_id)
);

-- ─── events.seat_sales ────────────────────────────────────────
-- Idempotency guard for seat sold transitions.
-- ON CONFLICT (order_id, session_id, ticket_type_id) DO NOTHING prevents
-- double-processing even under at-least-once gRPC / Kafka delivery.
-- Uses Guid.Empty as ticket_type_id placeholder for numbered-seat sessions.
CREATE TABLE IF NOT EXISTS events.seat_sales (
    order_id       UUID        NOT NULL,
    session_id     UUID        NOT NULL,
    ticket_type_id UUID        NOT NULL,
    quantity       INT         NOT NULL,
    sold_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (order_id, session_id, ticket_type_id)
);

-- ─── events.inbox_messages ────────────────────────────────────
-- Deduplication table for Kafka consumers in ticket-event-service.
-- ON CONFLICT (message_id) DO NOTHING relies on the PRIMARY KEY.
CREATE TABLE IF NOT EXISTS events.inbox_messages (
    message_id   TEXT        NOT NULL,
    topic        TEXT        NOT NULL DEFAULT '',
    status       TEXT        NOT NULL DEFAULT 'RECEIVED',
    received_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    PRIMARY KEY (message_id)
);

-- ─── events.idempotency_keys ──────────────────────────────────
-- Per-request idempotency store for HoldSeats and ReleaseSeats gRPC calls.
-- ON CONFLICT (key) DO NOTHING relies on the UNIQUE constraint below.
CREATE TABLE events.idempotency_keys (
    id          UUID      NOT NULL DEFAULT gen_random_uuid(),
    key         TEXT      NOT NULL,
    operation   TEXT      NOT NULL,
    status      TEXT      NOT NULL DEFAULT 'IN_PROGRESS',
    response    JSONB,
    created_at  TIMESTAMP NOT NULL,
    expires_at  TIMESTAMP NOT NULL,
    CONSTRAINT pk_idempotency_keys     PRIMARY KEY (id),
    CONSTRAINT uq_idempotency_keys_key UNIQUE (key)
);

-- ─── events.outbox_messages ───────────────────────────────────
-- Outbox table for ticket-event-service domain events.
-- Polled by ticket-event-worker with FOR UPDATE SKIP LOCKED.
CREATE TABLE events.outbox_messages (
    id                 UUID      NOT NULL,
    aggregate_type     TEXT      NOT NULL,
    aggregate_id       UUID      NOT NULL,
    event_type         TEXT      NOT NULL,
    payload            JSONB     NOT NULL,
    correlation_id     TEXT,
    status             TEXT      NOT NULL DEFAULT 'PENDING',
    attempts           INT       NOT NULL DEFAULT 0,
    next_attempt_at    TIMESTAMP NOT NULL,
    occurred_at        TIMESTAMP NOT NULL,
    dead_letter_reason TEXT,
    CONSTRAINT pk_events_outbox PRIMARY KEY (id)
);

-- Critical: worker polls WHERE (status='PENDING' OR status='FAILED')
-- AND next_attempt_at <= now() FOR UPDATE SKIP LOCKED.
CREATE INDEX idx_events_outbox_polling  ON events.outbox_messages (status, next_attempt_at);
-- Worker subquery ORDER BY occurred_at for FIFO delivery.
CREATE INDEX idx_events_outbox_occurred ON events.outbox_messages (occurred_at);

-- ============================================================
-- ORDERS SCHEMA
-- ============================================================

-- ─── orders.orders ────────────────────────────────────────────
-- Core order aggregate.
-- Written by OrderRepository; polled by OrderExpirationRepository
-- (FOR UPDATE SKIP LOCKED); read by OrderQueryRepository (admin).
CREATE TABLE orders.orders (
    id           UUID          NOT NULL,
    event_id     UUID          NOT NULL,
    user_id      TEXT          NOT NULL,
    status       TEXT          NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL,
    currency     TEXT          NOT NULL,
    expires_at   TIMESTAMPTZ   NOT NULL,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ,
    CONSTRAINT pk_orders PRIMARY KEY (id)
);

-- Expiration worker: WHERE status='AWAITING_PAYMENT' AND expires_at <= now()
-- ORDER BY expires_at FOR UPDATE SKIP LOCKED.
CREATE INDEX idx_orders_expiration   ON orders.orders (status, expires_at);
-- GetAwaitingPaymentByEventIdAsync: WHERE event_id = @EventId AND status = 'AWAITING_PAYMENT'
-- FOR UPDATE SKIP LOCKED.
CREATE INDEX idx_orders_event_status ON orders.orders (event_id, status);
-- Admin list: ORDER BY created_at DESC.
CREATE INDEX idx_orders_created_at   ON orders.orders (created_at DESC);

-- ─── orders.order_items ───────────────────────────────────────
-- Line items for an order (one per session × ticket-type combination).
-- session_snapshot and ticket_type_snapshot are JSONB: repositories
-- use the ::jsonb cast on INSERT.
CREATE TABLE orders.order_items (
    id                   UUID          NOT NULL,
    order_id             UUID          NOT NULL,
    session_id           UUID          NOT NULL,
    ticket_type_id       UUID          NOT NULL,
    session_snapshot     JSONB         NOT NULL,
    ticket_type_snapshot JSONB         NOT NULL,
    quantity             INT           NOT NULL,
    unit_price           NUMERIC(12,2) NOT NULL,
    total_price          NUMERIC(12,2) NOT NULL,
    CONSTRAINT pk_order_items        PRIMARY KEY (id),
    CONSTRAINT fk_order_items_order  FOREIGN KEY (order_id) REFERENCES orders.orders (id)
);

-- All queries filter or group by order_id.
CREATE INDEX idx_order_items_order ON orders.order_items (order_id);

-- ─── orders.order_seats ───────────────────────────────────────
-- Seat references for SEATED orders.
-- Queried by the expiration worker to build the gRPC ReleaseSeats payload.
CREATE TABLE orders.order_seats (
    id              UUID NOT NULL,
    order_id        UUID NOT NULL,
    session_seat_id UUID NOT NULL,
    seat_label      TEXT NOT NULL,
    CONSTRAINT pk_order_seats       PRIMARY KEY (id),
    CONSTRAINT fk_order_seats_order FOREIGN KEY (order_id) REFERENCES orders.orders (id)
);

CREATE INDEX idx_order_seats_order ON orders.order_seats (order_id);

-- ─── orders.order_holds ───────────────────────────────────────
-- Records each gRPC HoldSeats reference for an order.
-- Write-only audit trail; no SELECT queries observed.
CREATE TABLE orders.order_holds (
    id         UUID      NOT NULL,
    order_id   UUID      NOT NULL,
    hold_id    UUID      NOT NULL,
    session_id UUID      NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT pk_order_holds       PRIMARY KEY (id),
    CONSTRAINT fk_order_holds_order FOREIGN KEY (order_id) REFERENCES orders.orders (id)
);

-- ─── orders.order_payments ────────────────────────────────────
-- Records the payment linked to an order.
-- Write-only audit trail; no SELECT queries observed.
CREATE TABLE orders.order_payments (
    id         UUID          NOT NULL,
    order_id   UUID          NOT NULL,
    payment_id UUID          NOT NULL,
    status     TEXT          NOT NULL,
    amount     NUMERIC(12,2) NOT NULL,
    currency   TEXT          NOT NULL,
    created_at TIMESTAMPTZ   NOT NULL,
    CONSTRAINT pk_order_payments       PRIMARY KEY (id),
    CONSTRAINT fk_order_payments_order FOREIGN KEY (order_id) REFERENCES orders.orders (id)
);

-- ─── orders.order_status_history ──────────────────────────────
-- Append-only status transition log for an order.
-- Read by admin OrderQueryRepository detail view.
CREATE TABLE orders.order_status_history (
    id          UUID      NOT NULL,
    order_id    UUID      NOT NULL,
    from_status TEXT      NOT NULL,
    to_status   TEXT      NOT NULL,
    reason      TEXT,
    occurred_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT pk_order_status_history       PRIMARY KEY (id),
    CONSTRAINT fk_order_status_history_order FOREIGN KEY (order_id) REFERENCES orders.orders (id)
);

-- Admin detail query and future service queries filter by order_id.
CREATE INDEX idx_order_status_history_order ON orders.order_status_history (order_id);

-- ─── orders.order_events ──────────────────────────────────────
-- Outbox table for ticket-order-service and ticket-order-worker
-- (expiration events). Polled by ticket-order-worker.
CREATE TABLE orders.order_events (
    id                 UUID      NOT NULL,
    aggregate_type     TEXT      NOT NULL,
    aggregate_id       UUID      NOT NULL,
    event_type         TEXT      NOT NULL,
    payload            JSONB     NOT NULL,
    correlation_id     TEXT,
    status             TEXT      NOT NULL DEFAULT 'PENDING',
    attempts           INT       NOT NULL DEFAULT 0,
    next_attempt_at    TIMESTAMPTZ NOT NULL,
    occurred_at        TIMESTAMPTZ NOT NULL,
    dead_letter_reason TEXT,
    CONSTRAINT pk_order_events PRIMARY KEY (id)
);

-- Critical: worker polls WHERE (status='PENDING' OR status='FAILED')
-- AND next_attempt_at <= now() FOR UPDATE SKIP LOCKED.
CREATE INDEX idx_order_events_polling  ON orders.order_events (status, next_attempt_at);
-- Worker subquery ORDER BY occurred_at for FIFO delivery.
CREATE INDEX idx_order_events_occurred ON orders.order_events (occurred_at);

-- ─── orders.inbox_messages ────────────────────────────────────
-- Kafka consumer inbox for ticket-order-service (OrderCreatedConsumer).
-- ON CONFLICT (message_id) DO NOTHING requires UNIQUE (message_id).
CREATE TABLE orders.inbox_messages (
    id           UUID      NOT NULL DEFAULT gen_random_uuid(),
    message_id   TEXT      NOT NULL,
    topic        TEXT      NOT NULL,
    status       TEXT      NOT NULL DEFAULT 'RECEIVED',
    received_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    CONSTRAINT pk_orders_inbox              PRIMARY KEY (id),
    CONSTRAINT uq_orders_inbox_message_id   UNIQUE (message_id)
);

-- ============================================================
-- PAYMENTS SCHEMA
-- ============================================================

-- ─── payments.payments ────────────────────────────────────────
-- Core payment aggregate.
-- Written by PaymentRepository; polled by PaymentExpirationRepository
-- (FOR UPDATE SKIP LOCKED) and PaymentAttemptRepository (JOIN).
-- correlation_id: read by payment-worker; not written by PaymentRepository.AddAsync.
-- Declared nullable; always NULL under current service implementation.
CREATE TABLE payments.payments (
    id                 UUID          NOT NULL,
    order_id           UUID          NOT NULL,
    user_id            TEXT          NOT NULL,
    amount             NUMERIC(12,2) NOT NULL,
    currency           TEXT          NOT NULL,
    status             TEXT          NOT NULL,
    provider_reference TEXT,
    attempt_count      INT           NOT NULL DEFAULT 0,
    correlation_id     TEXT,
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ,
    CONSTRAINT pk_payments PRIMARY KEY (id)
);

-- PaymentRepository.GetByOrderIdAsync: WHERE order_id = @OrderId.
CREATE INDEX idx_payments_order      ON payments.payments (order_id);
-- PaymentExpirationRepository: WHERE status='PROCESSING' AND updated_at <= now() - interval
-- FOR UPDATE SKIP LOCKED.
CREATE INDEX idx_payments_expiration ON payments.payments (status, updated_at);

-- ─── payments.payment_attempts ────────────────────────────────
-- Individual payment attempts against a payment.
-- Polled by PaymentAttemptRepository with FOR UPDATE OF pa SKIP LOCKED.
CREATE TABLE payments.payment_attempts (
    id                 UUID      NOT NULL,
    payment_id         UUID      NOT NULL,
    attempt_number     INT       NOT NULL,
    status             TEXT      NOT NULL,
    provider_reference TEXT,
    error_code         TEXT,
    error_message      TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ,
    CONSTRAINT pk_payment_attempts        PRIMARY KEY (id),
    CONSTRAINT fk_payment_attempts_payment FOREIGN KEY (payment_id) REFERENCES payments.payments (id)
);

-- PaymentRepository.GetLatestAttemptByPaymentIdAsync:
-- WHERE payment_id = @PaymentId ORDER BY attempt_number DESC LIMIT 1.
CREATE INDEX idx_payment_attempts_payment ON payments.payment_attempts (payment_id);
-- PaymentAttemptRepository: WHERE pa.status='PENDING' ORDER BY pa.created_at
-- FOR UPDATE OF pa SKIP LOCKED.
CREATE INDEX idx_payment_attempts_polling ON payments.payment_attempts (status, created_at);

-- ─── payments.payment_methods ─────────────────────────────────
-- Card/payment method details associated with a payment.
-- Write-only; no SELECT queries observed.
CREATE TABLE payments.payment_methods (
    id          UUID      NOT NULL,
    payment_id  UUID      NOT NULL,
    brand       TEXT      NOT NULL,
    last4       TEXT      NOT NULL,
    holder_name TEXT      NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_payment_methods        PRIMARY KEY (id),
    CONSTRAINT fk_payment_methods_payment FOREIGN KEY (payment_id) REFERENCES payments.payments (id)
);

-- ─── payments.payment_provider_responses ──────────────────────
-- Raw webhook and provider response payloads.
-- payment_attempt_id is nullable (webhook may arrive before an attempt exists).
CREATE TABLE payments.payment_provider_responses (
    id                 UUID      NOT NULL,
    payment_id         UUID      NOT NULL,
    payment_attempt_id UUID,
    response_type      TEXT      NOT NULL,
    raw_payload        JSONB     NOT NULL,
    received_at        TIMESTAMPTZ NOT NULL,
    CONSTRAINT pk_payment_provider_responses          PRIMARY KEY (id),
    CONSTRAINT fk_ppr_payment  FOREIGN KEY (payment_id)         REFERENCES payments.payments (id),
    CONSTRAINT fk_ppr_attempt  FOREIGN KEY (payment_attempt_id) REFERENCES payments.payment_attempts (id)
);

-- ─── payments.payment_status_history ──────────────────────────
-- Append-only status transition log for a payment.
CREATE TABLE payments.payment_status_history (
    id          UUID      NOT NULL,
    payment_id  UUID      NOT NULL,
    from_status TEXT      NOT NULL,
    to_status   TEXT      NOT NULL,
    reason      TEXT,
    occurred_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT pk_payment_status_history        PRIMARY KEY (id),
    CONSTRAINT fk_payment_status_history_payment FOREIGN KEY (payment_id) REFERENCES payments.payments (id)
);

-- ─── payments.payment_events ──────────────────────────────────
-- Outbox table for ticket-payment-service and ticket-payment-worker
-- (attempt completion and expiration events). Polled by ticket-payment-worker.
CREATE TABLE payments.payment_events (
    id                 UUID      NOT NULL,
    aggregate_type     TEXT      NOT NULL,
    aggregate_id       UUID      NOT NULL,
    event_type         TEXT      NOT NULL,
    payload            JSONB     NOT NULL,
    correlation_id     TEXT,
    status             TEXT      NOT NULL DEFAULT 'PENDING',
    attempts           INT       NOT NULL DEFAULT 0,
    next_attempt_at    TIMESTAMPTZ NOT NULL,
    occurred_at        TIMESTAMPTZ NOT NULL,
    dead_letter_reason TEXT,
    CONSTRAINT pk_payment_events PRIMARY KEY (id)
);

-- Critical: worker polls WHERE (status='PENDING' OR status='FAILED')
-- AND next_attempt_at <= now() FOR UPDATE SKIP LOCKED.
CREATE INDEX idx_payment_events_polling  ON payments.payment_events (status, next_attempt_at);
-- Worker subquery ORDER BY occurred_at for FIFO delivery.
CREATE INDEX idx_payment_events_occurred ON payments.payment_events (occurred_at);

-- ─── payments.inbox_messages ──────────────────────────────────
-- Kafka consumer inbox for ticket-payment-service (OrderCreatedConsumer).
-- ON CONFLICT (message_id) DO NOTHING requires UNIQUE (message_id).
CREATE TABLE payments.inbox_messages (
    id           UUID      NOT NULL DEFAULT gen_random_uuid(),
    message_id   TEXT      NOT NULL,
    topic        TEXT      NOT NULL,
    status       TEXT      NOT NULL DEFAULT 'RECEIVED',
    received_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    CONSTRAINT pk_payments_inbox            PRIMARY KEY (id),
    CONSTRAINT uq_payments_inbox_message_id UNIQUE (message_id)
);

-- ============================================================
-- LISTEN/NOTIFY TRIGGERS
-- Workers use pg_notify to wake immediately on new outbox rows
-- instead of sleeping the full polling interval.
-- These require a direct Postgres connection (not PgBouncer in
-- transaction-pooling mode, which does not support LISTEN).
-- ============================================================

CREATE OR REPLACE FUNCTION orders.notify_outbox_insert()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify('outbox_orders_ready', '');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_events_notify
AFTER INSERT ON orders.order_events
FOR EACH STATEMENT
EXECUTE FUNCTION orders.notify_outbox_insert();

CREATE OR REPLACE FUNCTION payments.notify_outbox_insert()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify('outbox_payments_ready', '');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_events_notify
AFTER INSERT ON payments.payment_events
FOR EACH STATEMENT
EXECUTE FUNCTION payments.notify_outbox_insert();

-- ============================================================
-- ADMIN SCHEMA
-- Stores operational metadata owned by ticket-admin-api.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS admin;

-- Seed execution history.
-- The UNIQUE constraint on (seed_name, seed_version) is the primary
-- idempotency guard: a second INSERT with the same pair is silently
-- ignored (ON CONFLICT DO NOTHING) so concurrent requests cannot
-- record the same seed version twice.
CREATE TABLE admin.seed_history (
    id                    UUID         NOT NULL DEFAULT gen_random_uuid(),
    seed_name             VARCHAR(100) NOT NULL,
    seed_version          VARCHAR(50)  NOT NULL,
    executed_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    executed_by           VARCHAR(255),
    correlation_id        VARCHAR(255),
    venues_created        INT          NOT NULL DEFAULT 0,
    events_created        INT          NOT NULL DEFAULT 0,
    sessions_created      INT          NOT NULL DEFAULT 0,
    failure_count         INT          NOT NULL DEFAULT 0,
    completed_successfully BOOLEAN     NOT NULL,
    CONSTRAINT pk_seed_history PRIMARY KEY (id),
    CONSTRAINT uq_seed_history_name_version UNIQUE (seed_name, seed_version)
);

-- ============================================================
-- COVERING INDEXES FOR ADMIN-API REPORT QUERIES
-- ============================================================

-- GetOrdersByStatus: SELECT status, COUNT(*) FROM orders.orders
-- WHERE created_at >= NOW() - INTERVAL '30 days' GROUP BY status
CREATE INDEX idx_orders_report_status_date
    ON orders.orders (created_at DESC, status);

-- GetOrdersPerDay: SELECT DATE(created_at), COUNT(*) FROM orders.orders
-- WHERE created_at >= NOW() - INTERVAL '30 days' GROUP BY DATE(created_at)
-- idx_orders_created_at already covers this; no extra index needed.

-- GetRevenueByEvent: SELECT o.event_id, SUM(p.amount), COUNT(p.id)
-- FROM payments.payments p JOIN orders.orders o ON p.order_id = o.id
-- WHERE p.status = 'CAPTURED' GROUP BY o.event_id
-- Covering index lets Postgres resolve (status → order_id, amount) without heap fetch.
CREATE INDEX idx_payments_report_captured
    ON payments.payments (status) INCLUDE (order_id, amount)
    WHERE status = 'CAPTURED';

-- GetTopEvents: SELECT o.event_id, SUM(oi.quantity)
-- FROM orders.order_items oi JOIN orders.orders o ON oi.order_id = o.id
-- WHERE o.status IN ('CONFIRMED', 'AWAITING_PAYMENT') GROUP BY o.event_id
CREATE INDEX idx_orders_report_status_event
    ON orders.orders (status, event_id, id)
    WHERE status IN ('CONFIRMED', 'AWAITING_PAYMENT');
CREATE INDEX idx_order_items_report_qty
    ON orders.order_items (order_id) INCLUDE (quantity);

-- GetFailedPayments: SELECT error_code, COUNT(*) FROM payments.payment_attempts
-- WHERE status = 'FAILED' AND created_at >= NOW() - INTERVAL '30 days'
-- GROUP BY error_code
CREATE INDEX idx_payment_attempts_report_failed
    ON payments.payment_attempts (status, created_at DESC) INCLUDE (error_code)
    WHERE status = 'FAILED';
