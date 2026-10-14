USE jamii;

INSERT INTO accounts (account_number, status, balance, currency) VALUES
    ('1000000001', 'ACTIVE',        25450.75, 'KES'),
    ('1000000002', 'DORMANT',         310.00, 'KES'),
    ('1000000003', 'CLOSED',            0.00, 'KES'),
    ('1000000004', 'ACTIVE',    987654321.50, 'KES')
ON DUPLICATE KEY UPDATE status = VALUES(status), balance = VALUES(balance), currency = VALUES(currency);
