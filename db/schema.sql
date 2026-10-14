-- Jamii Savings: accounts schema (MySQL 8)
CREATE DATABASE IF NOT EXISTS jamii;
USE jamii;

CREATE TABLE IF NOT EXISTS accounts (
    account_number VARCHAR(10)                        NOT NULL PRIMARY KEY,
    status         ENUM('ACTIVE','DORMANT','CLOSED')  NOT NULL,
    balance        DECIMAL(15,2)                      NOT NULL DEFAULT 0.00,
    currency       CHAR(3)                            NOT NULL DEFAULT 'KES',
    updated_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
