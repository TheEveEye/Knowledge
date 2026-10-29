CREATE TABLE "knowledge"."email_delivery_limits" (
	"key" text PRIMARY KEY NOT NULL,
	"window_start" timestamp with time zone NOT NULL,
	"next_allowed_at" timestamp with time zone NOT NULL,
	"count" integer NOT NULL
);
