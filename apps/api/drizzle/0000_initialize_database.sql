CREATE SCHEMA IF NOT EXISTS "knowledge";
--> statement-breakpoint
REVOKE ALL ON SCHEMA knowledge FROM PUBLIC;
--> statement-breakpoint
GRANT USAGE ON SCHEMA knowledge TO knowledge_api;
--> statement-breakpoint
ALTER DEFAULT PRIVILEGES IN SCHEMA knowledge GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO knowledge_api;
--> statement-breakpoint
ALTER DEFAULT PRIVILEGES IN SCHEMA knowledge GRANT USAGE, SELECT ON SEQUENCES TO knowledge_api;
--> statement-breakpoint
GRANT USAGE ON SCHEMA drizzle TO knowledge_api;
--> statement-breakpoint
GRANT SELECT ON TABLE drizzle.__drizzle_migrations TO knowledge_api;
