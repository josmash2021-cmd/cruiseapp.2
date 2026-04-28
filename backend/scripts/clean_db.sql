-- Clean all tables in the database
SET session_replication_role = 'replica';

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename) LOOP
        EXECUTE 'TRUNCATE TABLE "' || r.tablename || '" CASCADE';
        RAISE NOTICE 'Truncated table: %', r.tablename;
    END LOOP;
END $$;

SET session_replication_role = 'origin';

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT sequencename FROM pg_sequences WHERE schemaname = 'public') LOOP
        EXECUTE 'ALTER SEQUENCE "' || r.sequencename || '" RESTART WITH 1';
        RAISE NOTICE 'Reset sequence: %', r.sequencename;
    END LOOP;
END $$;
