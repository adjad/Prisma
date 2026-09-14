CREATE TABLE IF NOT EXISTS pings (
    os_version  TEXT NOT NULL,
    mod_version TEXT NOT NULL,
    count       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (os_version, mod_version)
);
