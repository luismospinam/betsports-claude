ALTER TABLE betting_alerts
    ADD COLUMN bet_placed BOOLEAN,
    ADD COLUMN bet_status VARCHAR(50);
