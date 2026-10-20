-- Finance tables loaded by payments-file-batch (PostgreSQL 14+).

CREATE TABLE IF NOT EXISTS payment (
    payment_id        BIGSERIAL      PRIMARY KEY,
    run_id            VARCHAR(40)    NOT NULL,
    file_name         VARCHAR(255)   NOT NULL,
    line_number       INTEGER        NOT NULL,
    payment_reference VARCHAR(35)    NOT NULL,
    payee_name        VARCHAR(140)   NOT NULL,
    payee_abn         CHAR(11)       NOT NULL,
    bsb               CHAR(7)        NOT NULL,
    account_number    VARCHAR(9)     NOT NULL,
    amount            NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
    payment_date      DATE           NOT NULL,
    description       VARCHAR(280),
    loaded_at         TIMESTAMPTZ    NOT NULL DEFAULT now(),
    -- A block that is retried must not load a line twice.
    CONSTRAINT payment_run_line_uk UNIQUE (run_id, line_number)
);

CREATE INDEX IF NOT EXISTS payment_run_idx ON payment (run_id);

-- Rows that failed validation, or failed to load, for the rejects file and for audit.
CREATE TABLE IF NOT EXISTS payment_reject (
    reject_id         BIGSERIAL      PRIMARY KEY,
    run_id            VARCHAR(40)    NOT NULL,
    file_name         VARCHAR(255)   NOT NULL,
    line_number       INTEGER        NOT NULL,
    payment_reference VARCHAR(35),
    payee_name        VARCHAR(140),
    payee_abn         VARCHAR(20),
    bsb               VARCHAR(10),
    account_number    VARCHAR(20),
    amount            VARCHAR(20),
    payment_date      VARCHAR(20),
    reasons           VARCHAR(200)   NOT NULL,
    rejected_at       TIMESTAMPTZ    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payment_reject_run_idx ON payment_reject (run_id, line_number);
