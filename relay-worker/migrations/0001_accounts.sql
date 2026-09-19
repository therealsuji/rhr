-- Accounts, the installations that join them, and the memberships between.
--
-- A device never signs in: it redeems an invite and holds a membership, not an
-- identity. So there is no user row for a tester — only the installation their
-- phone generated on first run.

CREATE TABLE accounts (
  id            TEXT PRIMARY KEY,
  auth_user_id  TEXT NOT NULL UNIQUE,   -- WorkOS user id
  email         TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);

CREATE TABLE installations (
  id          TEXT PRIMARY KEY,          -- public, generated on the phone
  created_at  INTEGER NOT NULL
);

-- Many-to-many on purpose: a QA phone serves a whole team, and each developer
-- joined it separately. Either side can delete the row without the other.
CREATE TABLE memberships (
  account_id       TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  installation_id  TEXT NOT NULL REFERENCES installations(id) ON DELETE CASCADE,
  label            TEXT NOT NULL,        -- what the developer calls this phone
  joined_at        INTEGER NOT NULL,
  PRIMARY KEY (account_id, installation_id)
);

CREATE INDEX memberships_by_installation
  ON memberships(installation_id);

-- Single-use, short-lived. Redeeming is the only way a phone joins, so an
-- invite that could be replayed would be a way onto someone's account.
CREATE TABLE invites (
  token       TEXT PRIMARY KEY,
  account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at  INTEGER NOT NULL,
  -- Set on redemption rather than deleting the row, so a phone that retries
  -- after a lost response lands on the same membership instead of a second.
  redeemed_by TEXT
);
