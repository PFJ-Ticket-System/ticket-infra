#!/bin/bash
# Creates the application user and grants it ownership of the ticket database.
# Runs automatically via docker-entrypoint-initdb.d on first container start only.
# On subsequent starts the data directory already exists and this script is skipped.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER ticket WITH PASSWORD '$TICKET_DB_PASSWORD';
    GRANT ALL PRIVILEGES ON DATABASE ticket TO ticket;
    ALTER DATABASE ticket OWNER TO ticket;
EOSQL
