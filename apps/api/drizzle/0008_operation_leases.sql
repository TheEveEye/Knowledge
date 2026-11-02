ALTER TABLE "knowledge"."application_operations" ADD COLUMN "lease_id" uuid;--> statement-breakpoint
ALTER TABLE "knowledge"."application_operations" ADD COLUMN "lease_expires_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "knowledge"."application_operations" ADD COLUMN "subject_id" uuid;--> statement-breakpoint
ALTER TABLE "knowledge"."application_operations" ADD CONSTRAINT "operation_owned_subject" FOREIGN KEY ("user_id","subject_id") REFERENCES "knowledge"."subjects"("user_id","id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "operations_subject" ON "knowledge"."application_operations" USING btree ("user_id","subject_id");