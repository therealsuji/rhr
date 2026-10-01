-- The installation id is public; the secret is what proves a phone is itself.
-- Without this, anyone who read an id could list the accounts that phone had
-- joined and remove it from them.
ALTER TABLE installations ADD COLUMN secret_hash TEXT;
