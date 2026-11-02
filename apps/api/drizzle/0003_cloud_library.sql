CREATE TABLE "knowledge"."ai_connections" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"provider" text DEFAULT 'chatgpt' NOT NULL,
	"label" text NOT NULL,
	"status" text DEFAULT 'active' NOT NULL,
	"client_id" text NOT NULL,
	"provider_subject" text NOT NULL,
	"encrypted_credentials" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ai_connections_owner_id" UNIQUE("user_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."ai_requests" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"connection_id" uuid,
	"funding" text NOT NULL,
	"model" text NOT NULL,
	"kind" text NOT NULL,
	"status" text NOT NULL,
	"input_tokens" integer DEFAULT 0 NOT NULL,
	"output_tokens" integer DEFAULT 0 NOT NULL,
	"lease_expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "knowledge"."library_entities" (
	"id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"record" jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "library_entities_user_id_subject_id_id_pk" PRIMARY KEY("user_id","subject_id","id"),
	CONSTRAINT "entity_kind" CHECK ("knowledge"."library_entities"."kind" IN ('concept','fact','connection','topic','placement','contribution'))
);
--> statement-breakpoint
CREATE TABLE "knowledge"."library_entity_links" (
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"from_id" uuid NOT NULL,
	"to_id" uuid NOT NULL,
	"field" text NOT NULL,
	CONSTRAINT "library_entity_links_user_id_subject_id_from_id_to_id_field_pk" PRIMARY KEY("user_id","subject_id","from_id","to_id","field")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."library_entity_versions" (
	"user_id" uuid NOT NULL,
	"hash" text NOT NULL,
	"payload" jsonb NOT NULL,
	CONSTRAINT "library_entity_versions_user_id_hash_pk" PRIMARY KEY("user_id","hash")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."resource_events" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "knowledge"."resource_events_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"user_id" uuid NOT NULL,
	"resource" text NOT NULL,
	"subject_id" uuid,
	"version" integer NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "knowledge"."source_file_cleanup" (
	"storage_key" text PRIMARY KEY NOT NULL,
	"after" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "knowledge"."imports" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"source_id" uuid NOT NULL,
	"base_revision_id" uuid NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	"status" text DEFAULT 'processing' NOT NULL,
	"draft" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"checkpoint" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"selection" jsonb NOT NULL,
	"ai_connection_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "imports_owner_subject_id" UNIQUE("user_id","subject_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."processing_jobs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"import_id" uuid,
	"kind" text NOT NULL,
	"status" text DEFAULT 'queued' NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	"input" jsonb NOT NULL,
	"checkpoint" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"progress" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"selection" jsonb,
	"ai_connection_id" uuid,
	"lease_id" uuid,
	"lease_expires_at" timestamp with time zone,
	"attempts" integer DEFAULT 0 NOT NULL,
	"available_at" timestamp with time zone DEFAULT now() NOT NULL,
	"error" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "job_status" CHECK ("knowledge"."processing_jobs"."status" IN ('queued','running','paused','blocked','failed','completed','cancelled')),
	CONSTRAINT "job_kind" CHECK ("knowledge"."processing_jobs"."kind" IN ('extract','import','prepareRecall','prepareCommit','prepareUndo'))
);
--> statement-breakpoint
CREATE TABLE "knowledge"."learning_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"session_id" uuid,
	"target_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"related_event_id" uuid,
	"payload" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "knowledge"."application_operations" (
	"user_id" uuid NOT NULL,
	"id" uuid NOT NULL,
	"fingerprint" text NOT NULL,
	"response" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "application_operations_user_id_id_pk" PRIMARY KEY("user_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."source_passages" (
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"source_id" uuid NOT NULL,
	"id" text NOT NULL,
	"ordinal" integer NOT NULL,
	"page" integer,
	"section" text,
	"text" text NOT NULL,
	CONSTRAINT "source_passages_user_id_source_id_id_pk" PRIMARY KEY("user_id","source_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."pending_library_decisions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"import_id" uuid,
	"version" integer DEFAULT 1 NOT NULL,
	"state" jsonb NOT NULL
);
--> statement-breakpoint
CREATE TABLE "knowledge"."user_preferences" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	"values" jsonb DEFAULT '{}'::jsonb NOT NULL
);
--> statement-breakpoint
CREATE TABLE "knowledge"."recall_materials" (
	"id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"entity_id" uuid NOT NULL,
	"signature" text NOT NULL,
	"status" text NOT NULL,
	"snapshot" jsonb NOT NULL,
	"bank" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"revision_id" uuid NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "recall_materials_user_id_subject_id_id_pk" PRIMARY KEY("user_id","subject_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."recall_sessions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	"finished" boolean DEFAULT false NOT NULL,
	"state" jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "recall_sessions_owner_subject_id" UNIQUE("user_id","subject_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."recall_targets" (
	"id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"material_id" uuid NOT NULL,
	"signature" text NOT NULL,
	"data" jsonb NOT NULL,
	"memory" jsonb,
	"due_at" timestamp with time zone,
	"exposed_at" timestamp with time zone,
	"retired" boolean DEFAULT false NOT NULL,
	"excluded" boolean DEFAULT false NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	CONSTRAINT "recall_targets_user_id_subject_id_id_pk" PRIMARY KEY("user_id","subject_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."subject_revisions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"parent_id" uuid,
	"operation_id" uuid NOT NULL,
	"origin" text NOT NULL,
	"title" text NOT NULL,
	"summary" text NOT NULL,
	"manifest" jsonb NOT NULL,
	"changes" jsonb NOT NULL,
	"undoes_revision_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "revisions_owner_operation" UNIQUE("user_id","operation_id"),
	CONSTRAINT "revisions_owner_subject_id" UNIQUE("user_id","subject_id","id")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."server_state" (
	"key" text PRIMARY KEY NOT NULL,
	"value" text NOT NULL
);
--> statement-breakpoint
CREATE TABLE "knowledge"."sources" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"subject_id" uuid NOT NULL,
	"title" text NOT NULL,
	"kind" text NOT NULL,
	"storage_key" text NOT NULL,
	"digest" text NOT NULL,
	"byte_count" integer NOT NULL,
	"status" text DEFAULT 'uploaded' NOT NULL,
	"error" text,
	"archived" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "sources_storage_key_unique" UNIQUE("storage_key"),
	CONSTRAINT "sources_owner_subject_id" UNIQUE("user_id","subject_id","id"),
	CONSTRAINT "source_size" CHECK ("knowledge"."sources"."byte_count" BETWEEN 0 AND 26214400),
	CONSTRAINT "source_kind" CHECK ("knowledge"."sources"."kind" IN ('pdf','text','markdown')),
	CONSTRAINT "source_status" CHECK ("knowledge"."sources"."status" IN ('uploaded','ready','failed'))
);
--> statement-breakpoint
CREATE TABLE "knowledge"."subjects" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"name" text NOT NULL,
	"normalized_name" text NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	"revision_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subjects_owner_id" UNIQUE("user_id","id"),
	CONSTRAINT "subjects_owner_name" UNIQUE("user_id","normalized_name")
);
--> statement-breakpoint
CREATE TABLE "knowledge"."worker_heartbeats" (
	"id" uuid PRIMARY KEY NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"revision" text NOT NULL
);
--> statement-breakpoint
ALTER TABLE "knowledge"."ai_connections" ADD CONSTRAINT "ai_connections_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."ai_requests" ADD CONSTRAINT "ai_requests_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."ai_requests" ADD CONSTRAINT "ai_requests_user_id_connection_id_ai_connections_user_id_id_fk" FOREIGN KEY ("user_id","connection_id") REFERENCES "knowledge"."ai_connections"("user_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."library_entities" ADD CONSTRAINT "library_entities_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."library_entities" ADD CONSTRAINT "library_entities_user_id_subject_id_subjects_user_id_id_fk" FOREIGN KEY ("user_id","subject_id") REFERENCES "knowledge"."subjects"("user_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."library_entity_links" ADD CONSTRAINT "library_entity_links_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."library_entity_links" ADD CONSTRAINT "library_entity_links_user_id_subject_id_from_id_library_entities_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","from_id") REFERENCES "knowledge"."library_entities"("user_id","subject_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."library_entity_links" ADD CONSTRAINT "library_entity_links_user_id_subject_id_to_id_library_entities_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","to_id") REFERENCES "knowledge"."library_entities"("user_id","subject_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."library_entity_versions" ADD CONSTRAINT "library_entity_versions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."resource_events" ADD CONSTRAINT "resource_events_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."imports" ADD CONSTRAINT "imports_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."imports" ADD CONSTRAINT "imports_user_id_subject_id_source_id_sources_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","source_id") REFERENCES "knowledge"."sources"("user_id","subject_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."imports" ADD CONSTRAINT "imports_user_id_subject_id_base_revision_id_subject_revisions_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","base_revision_id") REFERENCES "knowledge"."subject_revisions"("user_id","subject_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."imports" ADD CONSTRAINT "imports_user_id_ai_connection_id_ai_connections_user_id_id_fk" FOREIGN KEY ("user_id","ai_connection_id") REFERENCES "knowledge"."ai_connections"("user_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."processing_jobs" ADD CONSTRAINT "processing_jobs_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."processing_jobs" ADD CONSTRAINT "processing_jobs_user_id_subject_id_subjects_user_id_id_fk" FOREIGN KEY ("user_id","subject_id") REFERENCES "knowledge"."subjects"("user_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."processing_jobs" ADD CONSTRAINT "processing_jobs_user_id_subject_id_import_id_imports_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","import_id") REFERENCES "knowledge"."imports"("user_id","subject_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."processing_jobs" ADD CONSTRAINT "processing_jobs_user_id_ai_connection_id_ai_connections_user_id_id_fk" FOREIGN KEY ("user_id","ai_connection_id") REFERENCES "knowledge"."ai_connections"("user_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."learning_events" ADD CONSTRAINT "learning_events_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."learning_events" ADD CONSTRAINT "learning_events_user_id_subject_id_target_id_recall_targets_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","target_id") REFERENCES "knowledge"."recall_targets"("user_id","subject_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."learning_events" ADD CONSTRAINT "learning_events_user_id_subject_id_session_id_recall_sessions_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","session_id") REFERENCES "knowledge"."recall_sessions"("user_id","subject_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."application_operations" ADD CONSTRAINT "application_operations_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."source_passages" ADD CONSTRAINT "source_passages_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."source_passages" ADD CONSTRAINT "source_passages_user_id_subject_id_source_id_sources_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","source_id") REFERENCES "knowledge"."sources"("user_id","subject_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."pending_library_decisions" ADD CONSTRAINT "pending_library_decisions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."pending_library_decisions" ADD CONSTRAINT "pending_library_decisions_user_id_subject_id_subjects_user_id_id_fk" FOREIGN KEY ("user_id","subject_id") REFERENCES "knowledge"."subjects"("user_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."user_preferences" ADD CONSTRAINT "user_preferences_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."recall_materials" ADD CONSTRAINT "recall_materials_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."recall_materials" ADD CONSTRAINT "recall_materials_user_id_subject_id_entity_id_library_entities_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","entity_id") REFERENCES "knowledge"."library_entities"("user_id","subject_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."recall_sessions" ADD CONSTRAINT "recall_sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."recall_sessions" ADD CONSTRAINT "recall_sessions_user_id_subject_id_subjects_user_id_id_fk" FOREIGN KEY ("user_id","subject_id") REFERENCES "knowledge"."subjects"("user_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."recall_targets" ADD CONSTRAINT "recall_targets_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."recall_targets" ADD CONSTRAINT "recall_targets_user_id_subject_id_material_id_recall_materials_user_id_subject_id_id_fk" FOREIGN KEY ("user_id","subject_id","material_id") REFERENCES "knowledge"."recall_materials"("user_id","subject_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."subject_revisions" ADD CONSTRAINT "subject_revisions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."subject_revisions" ADD CONSTRAINT "subject_revisions_user_id_subject_id_subjects_user_id_id_fk" FOREIGN KEY ("user_id","subject_id") REFERENCES "knowledge"."subjects"("user_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."sources" ADD CONSTRAINT "sources_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."sources" ADD CONSTRAINT "sources_user_id_subject_id_subjects_user_id_id_fk" FOREIGN KEY ("user_id","subject_id") REFERENCES "knowledge"."subjects"("user_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "knowledge"."subjects" ADD CONSTRAINT "subjects_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "knowledge"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "ai_connections_owner" ON "knowledge"."ai_connections" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "ai_requests_admission" ON "knowledge"."ai_requests" USING btree ("status","lease_expires_at");--> statement-breakpoint
CREATE INDEX "ai_requests_owner_usage" ON "knowledge"."ai_requests" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "entities_kind" ON "knowledge"."library_entities" USING btree ("user_id","subject_id","kind");--> statement-breakpoint
CREATE INDEX "entity_links_target" ON "knowledge"."library_entity_links" USING btree ("user_id","subject_id","to_id");--> statement-breakpoint
CREATE INDEX "resource_events_owner_cursor" ON "knowledge"."resource_events" USING btree ("user_id","id");--> statement-breakpoint
CREATE INDEX "imports_subject" ON "knowledge"."imports" USING btree ("user_id","subject_id");--> statement-breakpoint
CREATE INDEX "jobs_claim" ON "knowledge"."processing_jobs" USING btree ("status","available_at");--> statement-breakpoint
CREATE INDEX "jobs_subject" ON "knowledge"."processing_jobs" USING btree ("user_id","subject_id");--> statement-breakpoint
CREATE INDEX "learning_events_target" ON "knowledge"."learning_events" USING btree ("user_id","subject_id","target_id","created_at");--> statement-breakpoint
CREATE INDEX "passages_order" ON "knowledge"."source_passages" USING btree ("user_id","source_id","ordinal");--> statement-breakpoint
CREATE INDEX "decisions_subject" ON "knowledge"."pending_library_decisions" USING btree ("user_id","subject_id");--> statement-breakpoint
CREATE INDEX "recall_materials_entity" ON "knowledge"."recall_materials" USING btree ("user_id","subject_id","entity_id");--> statement-breakpoint
CREATE INDEX "recall_sessions_subject" ON "knowledge"."recall_sessions" USING btree ("user_id","subject_id");--> statement-breakpoint
CREATE INDEX "recall_targets_due" ON "knowledge"."recall_targets" USING btree ("user_id","subject_id","due_at");--> statement-breakpoint
CREATE INDEX "revisions_subject_created" ON "knowledge"."subject_revisions" USING btree ("user_id","subject_id","created_at");--> statement-breakpoint
CREATE INDEX "sources_subject" ON "knowledge"."sources" USING btree ("user_id","subject_id");--> statement-breakpoint
CREATE INDEX "subjects_owner_updated" ON "knowledge"."subjects" USING btree ("user_id","updated_at");