# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_06_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"
  enable_extension "vector"

  create_table "accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.boolean "god", default: false, null: false
    t.string "handle", null: false
    t.integer "kind", default: 0, null: false
    t.string "name", null: false
    t.datetime "otp_enabled_at"
    t.datetime "otp_last_step_at"
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.jsonb "preferences", default: {}, null: false
    t.string "telegram_chat_id"
    t.datetime "telegram_linked_at"
    t.string "telegram_username"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_accounts_on_email", unique: true
    t.index ["handle"], name: "index_accounts_on_handle", unique: true
    t.index ["telegram_chat_id"], name: "index_accounts_on_telegram_chat_id", unique: true, where: "(telegram_chat_id IS NOT NULL)"
  end

  create_table "accounts_api_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "revoked_at"], name: "index_accounts_api_tokens_on_account_id_and_revoked_at"
    t.index ["account_id"], name: "index_accounts_api_tokens_on_account_id"
    t.index ["organization_id", "revoked_at"], name: "index_accounts_api_tokens_on_organization_id_and_revoked_at"
    t.index ["organization_id"], name: "index_accounts_api_tokens_on_organization_id"
    t.index ["token_digest"], name: "index_accounts_api_tokens_on_token_digest", unique: true
  end

  create_table "accounts_device_grants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.uuid "api_token_id"
    t.datetime "approved_at"
    t.string "client_name"
    t.datetime "created_at", null: false
    t.string "device_code_digest", null: false
    t.datetime "expires_at", null: false
    t.integer "interval", default: 5, null: false
    t.datetime "last_polled_at"
    t.uuid "organization_id"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "user_code", null: false
    t.index ["account_id"], name: "index_accounts_device_grants_on_account_id"
    t.index ["api_token_id"], name: "index_accounts_device_grants_on_api_token_id"
    t.index ["device_code_digest"], name: "index_accounts_device_grants_on_device_code_digest", unique: true
    t.index ["expires_at"], name: "index_accounts_device_grants_on_expires_at"
    t.index ["organization_id"], name: "index_accounts_device_grants_on_organization_id"
    t.index ["user_code"], name: "index_accounts_device_grants_on_user_code", unique: true
  end

  create_table "accounts_impersonation_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.uuid "god_id", null: false
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_accounts_impersonation_events_on_account_id"
    t.index ["god_id"], name: "index_accounts_impersonation_events_on_god_id"
  end

  create_table "accounts_otp_recovery_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "code_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.index ["account_id", "code_digest"], name: "idx_on_account_id_code_digest_e2e9f3ec1a", unique: true
    t.index ["account_id"], name: "index_accounts_otp_recovery_codes_on_account_id"
  end

  create_table "accounts_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.uuid "impersonated_account_id"
    t.string "ip_address"
    t.datetime "last_active_at"
    t.datetime "two_factor_verified_at"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["account_id"], name: "index_accounts_sessions_on_account_id"
    t.index ["expires_at"], name: "index_accounts_sessions_on_expires_at"
    t.index ["impersonated_account_id"], name: "index_accounts_sessions_on_impersonated_account_id"
  end

  create_table "accounts_telegram_link_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.uuid "organization_id", comment: "Presente = il codice collega il gruppo con argomenti di questa organizzazione"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_accounts_telegram_link_codes_on_account_id"
    t.index ["code"], name: "index_accounts_telegram_link_codes_on_code", unique: true
    t.index ["expires_at"], name: "index_accounts_telegram_link_codes_on_expires_at"
    t.index ["organization_id"], name: "index_accounts_telegram_link_codes_on_organization_id"
  end

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activity_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "actor_name"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.uuid "organization_id", null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.uuid "true_actor_id"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_activity_events_on_actor_id"
    t.index ["organization_id", "created_at"], name: "index_activity_events_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_activity_events_on_organization_id"
    t.index ["subject_type", "subject_id", "created_at"], name: "idx_on_subject_type_subject_id_created_at_6ac9fdbec3"
    t.index ["subject_type", "subject_id"], name: "index_activity_events_on_subject"
    t.index ["true_actor_id"], name: "index_activity_events_on_true_actor_id"
  end

  create_table "agents_attempts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.jsonb "allowed_tools", default: [], null: false
    t.string "bundle_digest"
    t.string "bundle_ref"
    t.uuid "command_id"
    t.decimal "cost_usd", precision: 14, scale: 6
    t.datetime "created_at", null: false
    t.string "delivery_digest"
    t.string "expected_reviewer"
    t.string "expected_reviewer_model"
    t.string "external_run_id", null: false
    t.text "failure_reason"
    t.datetime "finished_at"
    t.uuid "host_id", null: false
    t.string "idempotency_key", null: false
    t.string "instruction_digest"
    t.uuid "instruction_id"
    t.integer "instruction_version"
    t.string "model"
    t.string "observed_head_sha"
    t.uuid "organization_id", null: false
    t.string "permission_mode"
    t.string "phase", null: false
    t.jsonb "result", default: {}, null: false
    t.jsonb "review", default: {}, null: false
    t.integer "review_cycles", default: 0, null: false
    t.integer "review_status"
    t.string "reviewer_runtime"
    t.uuid "run_id"
    t.string "runtime", null: false
    t.string "sandbox"
    t.uuid "service_account_id"
    t.string "skill_key"
    t.datetime "started_at", null: false
    t.integer "status", default: 0, null: false
    t.integer "ttl"
    t.datetime "updated_at", null: false
    t.uuid "workflow_id", null: false
    t.index ["agent_id"], name: "index_agents_attempts_on_agent_id"
    t.index ["command_id"], name: "index_agents_attempts_on_command_id"
    t.index ["finished_at", "status"], name: "idx_agents_attempts_finished_at_status"
    t.index ["host_id", "started_at"], name: "index_agents_attempts_on_host_id_and_started_at"
    t.index ["host_id"], name: "index_agents_attempts_on_host_id"
    t.index ["instruction_id"], name: "index_agents_attempts_on_instruction_id"
    t.index ["organization_id", "idempotency_key"], name: "index_agent_attempts_idempotency", unique: true
    t.index ["organization_id"], name: "index_agents_attempts_on_organization_id"
    t.index ["run_id"], name: "index_agents_attempts_on_run_id"
    t.index ["service_account_id"], name: "index_agents_attempts_on_service_account_id"
    t.index ["workflow_id", "created_at"], name: "index_agents_attempts_on_workflow_id_and_created_at"
    t.index ["workflow_id"], name: "index_agents_attempts_on_workflow_id"
    t.check_constraint "cost_usd IS NULL OR cost_usd >= 0::numeric", name: "agents_attempts_cost_nonnegative"
    t.check_constraint "expected_reviewer::text = ANY (ARRAY['claude'::character varying::text, 'codex'::character varying::text, 'opencode'::character varying::text])", name: "agents_attempts_expected_reviewer_valid"
    t.check_constraint "observed_head_sha IS NULL OR observed_head_sha::text ~ '^[0-9a-f]{40}$'::text", name: "agents_attempts_observed_head_sha_shape"
  end

  create_table "agents_automator_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "opencode_model"
    t.uuid "organization_id", null: false
    t.string "reviewer", default: "codex", null: false
    t.string "supporter", default: "codex", null: false
    t.text "supporter_reserved_topics"
    t.datetime "updated_at", null: false
    t.string "work_engine", default: "claude", null: false
    t.index ["organization_id"], name: "index_agents_automator_settings_on_organization_id", unique: true
    t.check_constraint "reviewer::text = ANY (ARRAY['claude'::character varying::text, 'codex'::character varying::text, 'opencode'::character varying::text])", name: "agents_automator_settings_reviewer_valid"
    t.check_constraint "supporter::text = ANY (ARRAY['claude'::character varying, 'codex'::character varying, 'opencode'::character varying]::text[])", name: "agents_automator_settings_supporter_valid"
    t.check_constraint "work_engine::text = ANY (ARRAY['claude'::character varying::text, 'codex'::character varying::text])", name: "agents_automator_settings_work_engine_valid"
  end

  create_table "agents_clarifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "answered_at"
    t.uuid "attempt_id", null: false
    t.datetime "created_at", null: false
    t.uuid "question_comment_id"
    t.uuid "response_comment_id"
    t.text "response_snapshot"
    t.datetime "updated_at", null: false
    t.uuid "workflow_id", null: false
    t.index ["attempt_id"], name: "index_agents_clarifications_on_attempt_id"
    t.index ["question_comment_id"], name: "index_agents_clarifications_on_question_comment_id"
    t.index ["response_comment_id"], name: "index_agents_clarifications_on_response_comment_id"
    t.index ["workflow_id"], name: "index_agents_clarifications_on_workflow_id"
  end

  create_table "agents_claude_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.uuid "organization_id", null: false
    t.uuid "set_by_id"
    t.text "token", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_agents_claude_credentials_on_organization_id", unique: true
    t.index ["set_by_id"], name: "index_agents_claude_credentials_on_set_by_id"
  end

  create_table "agents_delivery_candidates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "attempt_id", null: false
    t.string "base_ref"
    t.integer "checks_count", default: 0, null: false
    t.jsonb "checks_payload"
    t.datetime "created_at", null: false
    t.string "head_sha"
    t.datetime "last_checked_at"
    t.string "last_error_code"
    t.datetime "next_check_at"
    t.integer "number", null: false
    t.string "repository_full_name", null: false
    t.uuid "repository_id"
    t.integer "state", default: 0, null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.uuid "workflow_id", null: false
    t.index ["attempt_id"], name: "index_agents_delivery_candidates_on_attempt_id"
    t.index ["next_check_at"], name: "index_agents_delivery_candidates_due", where: "(state = ANY (ARRAY[0, 4, 5]))"
    t.index ["repository_id"], name: "index_agents_delivery_candidates_on_repository_id"
    t.index ["workflow_id", "repository_full_name", "number", "head_sha"], name: "index_agents_delivery_candidates_identity", unique: true, nulls_not_distinct: true
    t.index ["workflow_id"], name: "index_agents_delivery_candidates_on_workflow_id"
    t.check_constraint "NOT (state = ANY (ARRAY[1, 2, 3])) OR head_sha IS NOT NULL AND base_ref IS NOT NULL AND verified_at IS NOT NULL AND checks_payload IS NOT NULL", name: "agents_delivery_candidates_verified_complete"
  end

  create_table "agents_host_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "host_id", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["host_id"], name: "index_agents_host_tokens_active_host", unique: true, where: "(revoked_at IS NULL)"
    t.index ["host_id"], name: "index_agents_host_tokens_on_host_id"
    t.index ["token_digest"], name: "index_agents_host_tokens_on_token_digest", unique: true
  end

  create_table "agents_hosts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "active_runs", default: [], null: false
    t.string "arch", null: false
    t.string "automator_version"
    t.datetime "certified_at"
    t.uuid "certified_by_id"
    t.datetime "created_at", null: false
    t.string "fingerprint", null: false
    t.integer "heartbeat_expected_interval_minutes", default: 60, null: false
    t.integer "heartbeat_grace_minutes", default: 5, null: false
    t.uuid "heartbeat_project_id"
    t.string "host_status", default: "idle", null: false
    t.string "hostname", null: false
    t.datetime "last_heartbeat_at"
    t.jsonb "last_stops", default: [], null: false
    t.uuid "organization_id", null: false
    t.string "platform", null: false
    t.jsonb "repositories", default: [], null: false
    t.string "reviewer"
    t.datetime "revoked_at"
    t.integer "running", default: 0, null: false
    t.jsonb "runtimes", default: [], null: false
    t.uuid "service_account_id"
    t.integer "slots", default: 1, null: false
    t.string "supporter"
    t.datetime "updated_at", null: false
    t.string "work_engine"
    t.index ["certified_by_id"], name: "index_agents_hosts_on_certified_by_id"
    t.index ["heartbeat_project_id"], name: "index_agents_hosts_on_heartbeat_project_id"
    t.index ["organization_id", "fingerprint"], name: "index_agents_hosts_on_organization_id_and_fingerprint", unique: true
    t.index ["organization_id", "last_heartbeat_at"], name: "index_agents_hosts_on_org_heartbeat"
    t.index ["organization_id"], name: "index_agents_hosts_on_organization_id"
    t.index ["service_account_id"], name: "index_agents_hosts_on_service_account_id", unique: true
    t.check_constraint "(work_engine IS NULL) = (reviewer IS NULL)", name: "agents_hosts_engine_choice_complete"
    t.check_constraint "heartbeat_expected_interval_minutes > 0", name: "agents_hosts_heartbeat_interval_positive"
    t.check_constraint "heartbeat_grace_minutes >= 0", name: "agents_hosts_heartbeat_grace_nonnegative"
    t.check_constraint "host_status::text = ANY (ARRAY['idle'::character varying::text, 'busy'::character varying::text, 'waiting'::character varying::text, 'recovery_required'::character varying::text])", name: "agents_hosts_status"
    t.check_constraint "jsonb_typeof(active_runs) = 'array'::text", name: "agents_hosts_active_runs_array"
    t.check_constraint "jsonb_typeof(last_stops) = 'array'::text", name: "agents_hosts_last_stops_array"
    t.check_constraint "jsonb_typeof(repositories) = 'array'::text", name: "agents_hosts_repositories_array"
    t.check_constraint "jsonb_typeof(runtimes) = 'array'::text", name: "agents_hosts_runtimes_array"
    t.check_constraint "reviewer::text = ANY (ARRAY['claude'::character varying::text, 'codex'::character varying::text, 'opencode'::character varying::text])", name: "agents_hosts_reviewer_valid"
    t.check_constraint "running >= 0", name: "agents_hosts_running_nonnegative"
    t.check_constraint "slots > 0", name: "agents_hosts_slots_positive"
    t.check_constraint "supporter IS NULL OR (supporter::text = ANY (ARRAY['claude'::character varying, 'codex'::character varying, 'opencode'::character varying]::text[]))", name: "agents_hosts_supporter_valid"
    t.check_constraint "work_engine::text = ANY (ARRAY['claude'::character varying::text, 'codex'::character varying::text])", name: "agents_hosts_work_engine_valid"
  end

  create_table "agents_leases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.string "agent"
    t.integer "authoritative_ttl_seconds"
    t.datetime "created_at", null: false
    t.string "execution_phase"
    t.datetime "expires_at", null: false
    t.uuid "host_id"
    t.uuid "organization_id", null: false
    t.string "profile_digest"
    t.string "run_id", null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_agents_leases_on_account_id"
    t.index ["host_id", "expires_at"], name: "index_agents_leases_on_host_id_and_expires_at"
    t.index ["host_id"], name: "index_agents_leases_on_host_id"
    t.index ["organization_id", "expires_at"], name: "index_agents_leases_on_organization_id_and_expires_at"
    t.index ["organization_id"], name: "index_agents_leases_on_organization_id"
    t.index ["ticket_id"], name: "index_agents_leases_unique_ticket", unique: true
    t.check_constraint "(host_id IS NOT NULL) <> (account_id IS NOT NULL)", name: "agents_leases_holder"
    t.check_constraint "account_id IS NOT NULL AND execution_phase IS NULL AND profile_digest IS NULL AND agent IS NULL OR account_id IS NULL AND (execution_phase IS NOT NULL AND profile_digest IS NOT NULL OR execution_phase IS NULL AND profile_digest IS NULL AND agent IS NOT NULL)", name: "agents_leases_work_identity"
    t.check_constraint "authoritative_ttl_seconds IS NULL OR authoritative_ttl_seconds >= 1 AND authoritative_ttl_seconds <= 2592000", name: "agents_leases_authoritative_ttl_range"
  end

  create_table "agents_leases_tombstones", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.datetime "created_at", null: false
    t.uuid "host_id"
    t.uuid "organization_id", null: false
    t.datetime "released_at", null: false
    t.string "run_id", null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_agents_leases_tombstones_on_account_id"
    t.index ["host_id"], name: "index_agents_leases_tombstones_on_host_id"
    t.index ["organization_id"], name: "index_agents_leases_tombstones_on_organization_id"
    t.index ["ticket_id", "account_id", "run_id"], name: "index_agents_lease_tombstones_account_idempotency", unique: true, where: "(account_id IS NOT NULL)"
    t.index ["ticket_id", "host_id", "run_id"], name: "index_agents_lease_tombstones_idempotency", unique: true
    t.check_constraint "(host_id IS NOT NULL) <> (account_id IS NOT NULL)", name: "agents_leases_tombstones_holder"
  end

  create_table "agents_limit_policies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "max_age_seconds", default: 60, null: false
    t.decimal "max_daily_cost", precision: 14, scale: 4
    t.integer "max_daily_runs"
    t.integer "max_parallel"
    t.integer "max_runtime_seconds"
    t.uuid "organization_id", null: false
    t.uuid "project_id"
    t.string "runtime"
    t.boolean "stop_dispatch", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "project_id", "runtime"], name: "index_agents_limit_policies_scope", unique: true, nulls_not_distinct: true
    t.index ["organization_id"], name: "index_agents_limit_policies_on_organization_id"
    t.index ["project_id"], name: "index_agents_limit_policies_on_project_id"
    t.check_constraint "max_age_seconds > 0", name: "agents_limit_policy_age_positive"
    t.check_constraint "max_daily_cost IS NULL OR max_daily_cost >= 0::numeric", name: "agents_limit_policy_cost_nonnegative"
    t.check_constraint "max_daily_runs IS NULL OR max_daily_runs >= 0", name: "agents_limit_policy_runs_nonnegative"
    t.check_constraint "max_parallel IS NULL OR max_parallel >= 0", name: "agents_limit_policy_parallel_nonnegative"
    t.check_constraint "max_runtime_seconds IS NULL OR max_runtime_seconds > 0", name: "agents_limit_policy_runtime_positive"
  end

  create_table "agents_limit_reservations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.datetime "created_at", null: false
    t.string "denial_reason"
    t.decimal "estimated_cost", precision: 14, scale: 4
    t.datetime "expires_at"
    t.uuid "host_id"
    t.string "idempotency_key", null: false
    t.uuid "organization_id", null: false
    t.string "outcome", null: false
    t.string "phase"
    t.uuid "project_id"
    t.integer "requested_ttl_seconds", null: false
    t.string "runtime", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_agents_limit_reservations_on_agent_id"
    t.index ["host_id"], name: "index_agents_limit_reservations_on_host_id"
    t.index ["organization_id", "expires_at"], name: "index_agents_limit_reservations_active_organization", where: "((outcome)::text = 'granted'::text)"
    t.index ["organization_id", "idempotency_key"], name: "index_agents_limit_reservations_idempotency", unique: true
    t.index ["organization_id", "project_id", "runtime", "expires_at"], name: "index_agents_limit_reservations_active_scope"
    t.index ["organization_id"], name: "index_agents_limit_reservations_on_organization_id"
    t.index ["project_id"], name: "index_agents_limit_reservations_on_project_id"
    t.check_constraint "estimated_cost IS NULL OR estimated_cost >= 0::numeric", name: "agents_limit_reservation_cost_nonnegative"
    t.check_constraint "outcome::text = 'granted'::text AND expires_at IS NOT NULL AND denial_reason IS NULL OR outcome::text = 'denied'::text AND expires_at IS NULL AND denial_reason IS NOT NULL", name: "agents_limit_reservation_decision_shape"
    t.check_constraint "outcome::text = ANY (ARRAY['granted'::character varying::text, 'denied'::character varying::text])", name: "agents_limit_reservation_outcome"
    t.check_constraint "requested_ttl_seconds > 0", name: "agents_limit_reservation_ttl_positive"
  end

  create_table "agents_limit_usages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "cost", precision: 14, scale: 4, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.date "period_on", null: false
    t.uuid "policy_id", null: false
    t.integer "runs", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["policy_id", "period_on"], name: "index_agents_limit_usages_on_policy_id_and_period_on", unique: true
    t.index ["policy_id"], name: "index_agents_limit_usages_on_policy_id"
    t.check_constraint "cost >= 0::numeric", name: "agents_limit_usage_cost_nonnegative"
    t.check_constraint "runs >= 0", name: "agents_limit_usage_runs_nonnegative"
  end

  create_table "agents_openrouter_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.uuid "set_by_id"
    t.text "token", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_agents_openrouter_credentials_on_organization_id", unique: true
    t.index ["set_by_id"], name: "index_agents_openrouter_credentials_on_set_by_id"
  end

  create_table "agents_plans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "approved_at"
    t.uuid "approved_by_id"
    t.uuid "attempt_id", null: false
    t.jsonb "candidate_items"
    t.text "change_request"
    t.jsonb "completion_probe"
    t.jsonb "content", default: {}, null: false
    t.integer "contract_version", default: 1, null: false
    t.datetime "created_at", null: false
    t.text "decision_brief"
    t.jsonb "definition_of_done", default: [], null: false
    t.jsonb "mixed_parts"
    t.jsonb "notes", default: [], null: false
    t.jsonb "scenarios", default: [], null: false
    t.text "technical_analysis", null: false
    t.string "ticket_snapshot_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.uuid "workflow_id", null: false
    t.index ["approved_by_id"], name: "index_agents_plans_on_approved_by_id"
    t.index ["attempt_id"], name: "index_agents_plans_on_attempt_id"
    t.index ["workflow_id", "version"], name: "index_agents_plans_on_workflow_id_and_version", unique: true
    t.index ["workflow_id"], name: "index_agents_plans_on_workflow_id"
    t.check_constraint "(candidate_items IS NULL) = (completion_probe IS NULL)", name: "agents_plans_frozen_decision_together"
    t.check_constraint "candidate_items IS NULL OR jsonb_typeof(candidate_items) = 'array'::text AND jsonb_array_length(candidate_items) > 0", name: "agents_plans_candidate_items_non_empty_array"
    t.check_constraint "completion_probe IS NULL OR jsonb_typeof(completion_probe) = 'object'::text", name: "agents_plans_completion_probe_object"
    t.check_constraint "contract_version = ANY (ARRAY[1, 2])", name: "agents_plans_contract_version_supported"
    t.check_constraint "jsonb_typeof(content) = 'object'::text", name: "agents_plans_content_object"
  end

  create_table "agents_release_assignments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "baseline_tag"
    t.datetime "created_at", null: false
    t.string "execution_phase", null: false
    t.uuid "github_repository_id", null: false
    t.string "sha"
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.uuid "workflow_id", null: false
    t.index ["github_repository_id", "version"], name: "index_agents_release_assignments_version", unique: true
    t.index ["github_repository_id"], name: "index_agents_release_assignments_on_github_repository_id"
    t.index ["workflow_id", "execution_phase"], name: "index_agents_release_assignments_identity", unique: true
    t.index ["workflow_id"], name: "index_agents_release_assignments_on_workflow_id"
    t.check_constraint "execution_phase::text = ANY (ARRAY['closer_staging'::character varying::text, 'closer_production'::character varying::text])", name: "agents_release_assignments_phase_valida"
    t.check_constraint "sha IS NULL OR sha::text ~ '^[0-9a-f]{40}$'::text", name: "agents_release_assignments_sha_shape"
  end

  create_table "agents_skill_bundles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.uuid "organization_id", null: false
    t.string "ref", null: false
    t.string "repo", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["organization_id"], name: "index_agents_skill_bundles_singleton", unique: true
  end

  create_table "agents_supporter_decisions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "engine", null: false
    t.jsonb "evidence", default: {}, null: false
    t.uuid "organization_id", null: false
    t.string "outcome", null: false
    t.integer "risk_score", null: false
    t.datetime "seen_at"
    t.uuid "seen_by_id"
    t.string "target_digest", null: false
    t.uuid "target_id", null: false
    t.string "target_type", null: false
    t.datetime "updated_at", null: false
    t.uuid "workflow_id", null: false
    t.index ["organization_id", "seen_at"], name: "index_agents_supporter_decisions_to_review"
    t.index ["organization_id"], name: "index_agents_supporter_decisions_on_organization_id"
    t.index ["seen_by_id"], name: "index_agents_supporter_decisions_on_seen_by_id"
    t.index ["target_type", "target_id", "target_digest"], name: "index_agents_supporter_decisions_on_target", unique: true
    t.index ["workflow_id"], name: "index_agents_supporter_decisions_on_workflow_id"
    t.check_constraint "engine::text = ANY (ARRAY['claude'::character varying, 'codex'::character varying, 'opencode'::character varying]::text[])", name: "agents_supporter_decisions_engine_valid"
    t.check_constraint "outcome::text = ANY (ARRAY['answered'::character varying, 'approved'::character varying, 'escalated'::character varying]::text[])", name: "agents_supporter_decisions_outcome_valid"
    t.check_constraint "risk_score >= 1 AND risk_score <= 10", name: "agents_supporter_decisions_risk_score_range"
    t.check_constraint "target_type::text = ANY (ARRAY['question'::character varying, 'plan'::character varying]::text[])", name: "agents_supporter_decisions_target_type_valid"
  end

  create_table "agents_ticket_queue_deferrals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.string "candidate_version", limit: 64, null: false
    t.datetime "created_at", null: false
    t.string "execution_phase"
    t.uuid "host_id"
    t.uuid "organization_id", null: false
    t.string "reason", null: false
    t.string "repository_fingerprint", limit: 64, null: false
    t.datetime "retry_at", null: false
    t.string "selection_digest", limit: 64, null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_agents_ticket_queue_deferrals_on_agent_id"
    t.index ["host_id", "ticket_id", "execution_phase", "retry_at"], name: "index_agent_queue_deferrals_eligibility"
    t.index ["host_id"], name: "index_agents_ticket_queue_deferrals_on_host_id"
    t.index ["organization_id", "selection_digest", "host_id"], name: "index_agent_queue_deferrals_selection", unique: true
    t.index ["organization_id"], name: "index_agents_ticket_queue_deferrals_on_organization_id"
    t.check_constraint "length(candidate_version::text) = 64", name: "agents_ticket_queue_deferrals_version_length"
    t.check_constraint "length(repository_fingerprint::text) = 64", name: "agents_ticket_queue_deferrals_repository_length"
    t.check_constraint "length(selection_digest::text) = 64", name: "agents_ticket_queue_deferrals_digest_length"
    t.check_constraint "reason::text = ANY (ARRAY['temporary_failure'::character varying::text, 'preflight_blocked'::character varying::text, 'needs_clarification'::character varying::text])", name: "agents_ticket_queue_deferrals_reason"
    t.check_constraint "retry_at > created_at", name: "agents_ticket_queue_deferrals_positive_backoff"
  end

  create_table "agents_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_agents_tokens_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_agents_tokens_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_agents_tokens_on_organization_id"
    t.index ["token_digest"], name: "index_agents_tokens_on_token_digest", unique: true
  end

  create_table "agents_workflow_probes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "bound_at", null: false
    t.integer "checks_count", default: 0, null: false
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.jsonb "evidence", default: {}, null: false
    t.jsonb "expected", default: {}, null: false
    t.string "kind", null: false
    t.string "last_error_code"
    t.datetime "next_check_at"
    t.datetime "updated_at", null: false
    t.uuid "workflow_id", null: false
    t.index ["next_check_at"], name: "index_agents_workflow_probes_due", where: "(closed_at IS NULL)"
    t.index ["workflow_id"], name: "index_agents_workflow_probes_live", unique: true, where: "(closed_at IS NULL)"
    t.check_constraint "checks_count >= 0", name: "agents_workflow_probes_checks_non_negative"
    t.check_constraint "jsonb_typeof(expected) = 'object'::text", name: "agents_workflow_probes_expected_object"
  end

  create_table "agents_workflows", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "approved_at"
    t.uuid "approved_by_id"
    t.datetime "autopilot_approved_at"
    t.uuid "autopilot_approved_by_id"
    t.uuid "autopilot_by_agent_id"
    t.uuid "autopilot_by_host_id"
    t.uuid "autopilot_by_service_account_id"
    t.datetime "autopilot_completed_at"
    t.datetime "autopilot_started_at"
    t.datetime "blocked_at"
    t.string "blocked_kind"
    t.string "blocked_phase"
    t.text "blocked_reason"
    t.text "cancellation_reason"
    t.datetime "cancelled_at"
    t.uuid "cancelled_by_id"
    t.integer "candidate_rejections_count", default: 0, null: false
    t.datetime "candidate_verified_at"
    t.datetime "closer_production_approved_at"
    t.uuid "closer_production_approved_by_id"
    t.uuid "closer_production_by_agent_id"
    t.uuid "closer_production_by_host_id"
    t.uuid "closer_production_by_service_account_id"
    t.datetime "closer_production_completed_at"
    t.datetime "closer_production_started_at"
    t.uuid "closer_staging_by_agent_id"
    t.uuid "closer_staging_by_host_id"
    t.uuid "closer_staging_by_service_account_id"
    t.integer "closer_staging_checks_count", default: 0, null: false
    t.datetime "closer_staging_completed_at"
    t.string "closer_staging_last_error_code"
    t.datetime "closer_staging_next_check_at"
    t.datetime "closer_staging_started_at"
    t.datetime "closer_staging_verified_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "escalated_at"
    t.integer "escalated_cycle"
    t.text "escalation_reason"
    t.uuid "frozen_plan_id"
    t.datetime "plan_frozen_at"
    t.datetime "planned_at"
    t.uuid "planned_by_agent_id"
    t.uuid "planned_by_host_id"
    t.uuid "planned_by_service_account_id"
    t.datetime "review_budget_from"
    t.uuid "review_candidate_id"
    t.uuid "ticket_id", null: false
    t.string "ticket_snapshot_digest"
    t.integer "ticket_snapshot_version", default: 1, null: false
    t.uuid "triage_by_agent_id"
    t.uuid "triage_by_host_id"
    t.uuid "triage_by_service_account_id"
    t.datetime "triage_requested_at"
    t.datetime "triage_started_at"
    t.datetime "triaged_at"
    t.integer "unreachable_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_agents_workflows_on_approved_by_id"
    t.index ["autopilot_approved_by_id"], name: "index_agents_workflows_on_autopilot_approved_by_id"
    t.index ["autopilot_by_agent_id"], name: "index_agents_workflows_on_autopilot_by_agent_id"
    t.index ["autopilot_by_host_id"], name: "idx_agents_workflows_autopilot_by_host"
    t.index ["autopilot_by_service_account_id"], name: "idx_agents_workflows_autopilot_by_sa"
    t.index ["cancelled_by_id"], name: "index_agents_workflows_on_cancelled_by_id"
    t.index ["closer_production_approved_by_id"], name: "idx_agents_workflows_closer_production_approved_by"
    t.index ["closer_production_by_agent_id"], name: "index_agents_workflows_on_closer_production_by_agent_id"
    t.index ["closer_production_by_host_id"], name: "idx_agents_workflows_closer_production_by_host"
    t.index ["closer_production_by_service_account_id"], name: "idx_agents_workflows_closer_production_by_sa"
    t.index ["closer_staging_by_agent_id"], name: "index_agents_workflows_on_closer_staging_by_agent_id"
    t.index ["closer_staging_by_host_id"], name: "idx_agents_workflows_closer_staging_by_host"
    t.index ["closer_staging_by_service_account_id"], name: "idx_agents_workflows_closer_staging_by_sa"
    t.index ["closer_staging_next_check_at"], name: "index_agents_workflows_staging_proof_due", where: "((closer_staging_completed_at IS NOT NULL) AND (closer_staging_verified_at IS NULL))"
    t.index ["frozen_plan_id"], name: "index_agents_workflows_on_frozen_plan_id"
    t.index ["planned_by_agent_id"], name: "index_agents_workflows_on_planned_by_agent_id"
    t.index ["planned_by_host_id"], name: "idx_agents_workflows_planned_by_host"
    t.index ["planned_by_service_account_id"], name: "idx_agents_workflows_planned_by_sa"
    t.index ["review_candidate_id"], name: "index_agents_workflows_on_review_candidate_id"
    t.index ["ticket_id"], name: "index_agents_workflows_on_ticket_id", unique: true
    t.index ["triage_by_agent_id"], name: "index_agents_workflows_on_triage_by_agent_id"
    t.index ["triage_by_host_id"], name: "idx_agents_workflows_triage_by_host"
    t.index ["triage_by_service_account_id"], name: "idx_agents_workflows_triage_by_sa"
    t.check_constraint "blocked_at IS NULL OR blocked_kind IS NOT NULL", name: "agents_workflows_blocco_ha_un_autore"
    t.check_constraint "blocked_kind IS NULL OR (blocked_kind::text = ANY (ARRAY['attempt_limit'::character varying::text, 'agent_blocked'::character varying::text, 'candidate_check'::character varying::text, 'release_probe'::character varying::text, 'held_by_person'::character varying::text]))", name: "agents_workflows_blocked_kind_valido"
    t.check_constraint "candidate_rejections_count >= 0", name: "agents_workflows_candidate_rejections_count_non_negative"
    t.check_constraint "closer_staging_checks_count >= 0", name: "agents_workflows_staging_checks_count_non_negative"
  end

  create_table "ai_gateway_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "contact_email"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.datetime "last_used_at"
    t.bigint "monthly_token_limit", null: false
    t.string "name", null: false
    t.datetime "revoked_at"
    t.datetime "suspended_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_ai_gateway_keys_on_created_by_id"
    t.index ["token_digest"], name: "index_ai_gateway_keys_on_token_digest", unique: true
  end

  create_table "ai_gateway_usages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "key_id", null: false
    t.date "month", null: false
    t.integer "requests", default: 0, null: false
    t.bigint "tokens_input", default: 0, null: false
    t.bigint "tokens_output", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["key_id", "month"], name: "index_ai_gateway_usages_on_key_id_and_month", unique: true
    t.index ["key_id"], name: "index_ai_gateway_usages_on_key_id"
  end

  create_table "ai_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "args", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "error_code"
    t.string "error_message"
    t.string "kind", null: false
    t.uuid "organization_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_ai_requests_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_ai_requests_on_account_id"
    t.index ["organization_id"], name: "index_ai_requests_on_organization_id"
  end

  create_table "ai_usage_months", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "month", null: false
    t.uuid "organization_id", null: false
    t.bigint "tokens", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "month"], name: "index_ai_usage_months_on_organization_id_and_month", unique: true
  end

  create_table "alerting_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.boolean "enabled", default: true, null: false
    t.integer "kind", default: 0, null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.text "webhook_secret"
    t.index ["created_by_id"], name: "index_alerting_channels_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_alerting_channels_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_alerting_channels_on_organization_id"
  end

  create_table "alerting_evaluations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "config_digest", limit: 64, null: false
    t.datetime "created_at", null: false
    t.string "dispatch_state", default: "none", null: false
    t.datetime "dispatch_until"
    t.uuid "project_id", null: false
    t.jsonb "result", default: {}, null: false
    t.datetime "retry_at"
    t.uuid "rule_id", null: false
    t.uuid "series_id", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.decimal "window_end_ns", precision: 20, null: false
    t.index ["dispatch_state", "retry_at"], name: "index_alerting_evaluations_on_dispatch_state_and_retry_at"
    t.index ["project_id"], name: "index_alerting_evaluations_on_project_id"
    t.index ["rule_id", "config_digest", "series_id", "window_end_ns"], name: "measurement_evaluation_identity", unique: true
    t.index ["rule_id"], name: "index_alerting_evaluations_on_rule_id"
    t.check_constraint "dispatch_state::text = ANY (ARRAY['none'::character varying::text, 'pending'::character varying::text, 'delivering'::character varying::text, 'delivered'::character varying::text, 'cancelled'::character varying::text])", name: "measurement_evaluation_dispatch"
    t.check_constraint "octet_length(result::text) <= 16384", name: "measurement_evaluation_budget"
    t.check_constraint "status::text = ANY (ARRAY['unknown'::character varying::text, 'firing'::character varying::text, 'safe'::character varying::text])", name: "measurement_evaluation_status"
    t.check_constraint "window_end_ns >= 0::numeric AND window_end_ns <= '18446744073709551615'::numeric", name: "measurement_evaluation_time"
  end

  create_table "alerting_notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "dedup_key", null: false
    t.datetime "delivered_at"
    t.jsonb "details"
    t.integer "digest_bucket"
    t.integer "event_type", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id"
    t.datetime "read_at"
    t.uuid "rule_id"
    t.integer "status", default: 0, null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.integer "via", null: false
    t.index ["account_id", "dedup_key"], name: "idx_alerting_notifications_ticket_idem", unique: true, where: "(rule_id IS NULL)"
    t.index ["account_id", "read_at"], name: "index_alerting_notifications_on_account_id_and_read_at"
    t.index ["account_id"], name: "index_alerting_notifications_on_account_id"
    t.index ["organization_id", "created_at"], name: "index_alerting_notifications_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_alerting_notifications_on_organization_id"
    t.index ["project_id"], name: "index_alerting_notifications_on_project_id"
    t.index ["rule_id", "dedup_key"], name: "index_alerting_notifications_on_rule_id_and_dedup_key", unique: true
    t.index ["rule_id"], name: "index_alerting_notifications_on_rule_id"
    t.index ["subject_type", "subject_id"], name: "index_alerting_notifications_on_subject"
    t.index ["via", "digest_bucket"], name: "idx_alerting_notifications_digest_queue", where: "(status = 4)"
    t.index ["via"], name: "idx_alerting_notifications_held_release", where: "(status = 5)"
  end

  create_table "alerting_preferences", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "chat_enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "digest", default: 0, null: false
    t.jsonb "email_cadences", default: {}, null: false
    t.boolean "email_enabled", default: true, null: false
    t.boolean "errors_enabled", default: true, null: false
    t.boolean "in_app_enabled", default: true, null: false
    t.integer "min_level"
    t.uuid "organization_id", null: false
    t.boolean "performance_enabled", default: true, null: false
    t.integer "quiet_hours_end"
    t.integer "quiet_hours_start"
    t.string "quiet_hours_tz"
    t.integer "report_cadence", default: 0, null: false, comment: "Riepilogo periodico dei dati: 0 off · 1 giornaliero · 2 settimanale · 3 mensile"
    t.datetime "report_last_sent_at", comment: "Ultimo riepilogo dati spedito: guardia anti-doppione del giro ricorrente"
    t.boolean "servers_enabled", default: true, null: false
    t.jsonb "telegram_cadences", default: {}, null: false
    t.boolean "telegram_enabled", default: false, null: false
    t.boolean "tickets_enabled", default: true, null: false
    t.datetime "updated_at", null: false
    t.boolean "uptime_enabled", default: true, null: false
    t.index ["account_id"], name: "index_alerting_preferences_on_account_id"
    t.index ["organization_id", "account_id"], name: "index_alerting_preferences_on_organization_id_and_account_id", unique: true
    t.index ["organization_id"], name: "index_alerting_preferences_on_organization_id"
  end

  create_table "alerting_rule_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.datetime "created_at", null: false
    t.uuid "rule_id", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_alerting_rule_channels_on_channel_id"
    t.index ["rule_id", "channel_id"], name: "index_alerting_rule_channels_on_rule_id_and_channel_id", unique: true
    t.index ["rule_id"], name: "index_alerting_rule_channels_on_rule_id"
  end

  create_table "alerting_rule_host_exclusions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "host_id", null: false
    t.uuid "rule_id", null: false
    t.datetime "updated_at", null: false
    t.index ["host_id"], name: "index_alerting_rule_host_exclusions_on_host_id"
    t.index ["rule_id", "host_id"], name: "idx_alerting_rule_host_exclusions_unique", unique: true
    t.index ["rule_id"], name: "index_alerting_rule_host_exclusions_on_rule_id"
  end

  create_table "alerting_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.boolean "enabled", default: true, null: false
    t.uuid "environment_id"
    t.integer "event_type", null: false
    t.jsonb "measurement_config", default: {}, null: false
    t.uuid "measurement_series_id"
    t.jsonb "measurement_state", default: {}, null: false
    t.integer "min_level"
    t.datetime "muted_until"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id"
    t.decimal "threshold"
    t.decimal "threshold_ms"
    t.integer "throttle_seconds", default: 300, null: false
    t.boolean "unhandled_only", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_alerting_rules_on_created_by_id"
    t.index ["environment_id"], name: "index_alerting_rules_on_environment_id"
    t.index ["id", "project_id"], name: "measurement_rule_tenant_identity", unique: true
    t.index ["measurement_series_id"], name: "index_alerting_rules_on_measurement_series_id"
    t.index ["organization_id", "event_type", "enabled"], name: "idx_on_organization_id_event_type_enabled_3464af0c2c"
    t.index ["organization_id"], name: "index_alerting_rules_on_organization_id"
    t.index ["project_id"], name: "index_alerting_rules_on_project_id"
    t.check_constraint "event_type <> 59 OR project_id IS NOT NULL", name: "measurement_rule_project"
    t.check_constraint "octet_length(measurement_config::text) <= 4096", name: "measurement_config_budget"
  end

  create_table "alerting_telegram_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false, comment: "L'owner che ha collegato il gruppo: riceve lì i suoi avvisi"
    t.string "chat_id", null: false
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.string "title"
    t.jsonb "topics", default: {}, null: false, comment: "Chiave dell'argomento (critical o gruppo del catalogo) → message_thread_id"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_alerting_telegram_groups_on_account_id"
    t.index ["organization_id"], name: "index_alerting_telegram_groups_on_organization_id", unique: true
  end

  create_table "analytics_goals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "event_name"
    t.integer "kind", default: 0, null: false
    t.string "path_pattern"
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "event_name"], name: "idx_analytics_goals_event", unique: true, where: "(kind = 1)"
    t.index ["project_id", "path_pattern"], name: "idx_analytics_goals_path", unique: true, where: "(kind = 0)"
    t.index ["project_id"], name: "index_analytics_goals_on_project_id"
  end

  create_table "analytics_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.boolean "enabled", default: true, null: false
    t.string "password_digest"
    t.uuid "project_id", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_analytics_links_on_created_by_id"
    t.index ["project_id"], name: "index_analytics_links_on_project_id"
    t.index ["slug"], name: "index_analytics_links_on_slug", unique: true
  end

  create_table "analytics_pageviews", primary_key: ["id", "created_at"], options: "PARTITION BY RANGE (created_at)", force: :cascade do |t|
    t.string "browser"
    t.string "browser_version"
    t.string "country_code"
    t.datetime "created_at", null: false
    t.string "device_type"
    t.string "environment"
    t.string "event_id", null: false
    t.string "hostname", null: false
    t.uuid "id", default: -> { "gen_random_uuid()" }, null: false
    t.string "name", default: "pageview", null: false
    t.datetime "occurred_at", null: false
    t.string "os"
    t.string "os_version"
    t.string "path", null: false
    t.uuid "project_id", null: false
    t.string "referrer_host"
    t.string "screen_class"
    t.string "utm_campaign"
    t.string "utm_content"
    t.string "utm_medium"
    t.string "utm_source"
    t.string "utm_term"
    t.string "visitor_hash", null: false
    t.index ["project_id", "name", "occurred_at"], name: "idx_analytics_pageviews_goal", order: { occurred_at: :desc }
    t.index ["project_id", "occurred_at"], name: "index_analytics_pageviews_on_project_id_and_occurred_at", order: { occurred_at: :desc }
  end

  create_table "analytics_salts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false
    t.index ["date"], name: "index_analytics_salts_on_date", unique: true
  end

  create_table "analytics_web_vitals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "browser"
    t.string "country_code"
    t.datetime "created_at", null: false
    t.string "device_type", comment: "desktop | mobile | tablet — dallo user-agent, come i pageview"
    t.string "environment"
    t.string "event_id", null: false, comment: "Idempotenza (project_id, event_id), come i pageview"
    t.string "hostname", null: false
    t.string "metric", null: false, comment: "lcp | inp | cls | ttfb | fcp — allowlist server-side"
    t.string "navigation_type", comment: "navigate | reload | back-forward | prerender: un back-forward è cache e falserebbe il confronto"
    t.datetime "occurred_at", null: false
    t.string "os"
    t.string "path", null: false
    t.uuid "project_id", null: false
    t.string "rating", comment: "good | needs-improvement | poor — RICALCOLATO qui, mai preso dal client"
    t.float "value", null: false, comment: "ms per lcp/inp/ttfb/fcp; adimensionale per cls"
    t.index ["project_id", "event_id"], name: "index_analytics_web_vitals_on_project_id_and_event_id", unique: true
    t.index ["project_id", "hostname", "metric", "occurred_at"], name: "index_analytics_web_vitals_site_lookup", order: { occurred_at: :desc }
    t.index ["project_id", "metric", "occurred_at"], name: "idx_on_project_id_metric_occurred_at_1f3573bd44", order: { occurred_at: :desc }
  end

  create_table "artifacts_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.uuid "project_id", null: false
    t.datetime "reserved_until", null: false
    t.string "service_name", null: false
    t.string "sha256", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["id", "project_id"], name: "index_artifacts_blobs_on_id_and_project_id", unique: true
    t.index ["key"], name: "index_artifacts_blobs_on_key", unique: true
    t.index ["project_id"], name: "index_artifacts_blobs_on_project_id"
    t.check_constraint "byte_size >= 0 AND byte_size <= 20971520", name: "artifacts_blob_size"
  end

  create_table "artifacts_native_symbols", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "architecture", limit: 32, null: false
    t.uuid "blob_id", null: false
    t.string "code_id", limit: 256
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "debug_id", limit: 45, null: false
    t.string "format", limit: 16, null: false
    t.string "identity_sha256", limit: 64, null: false
    t.uuid "project_id", null: false
    t.datetime "unreferenced_since"
    t.datetime "updated_at", null: false
    t.index ["blob_id"], name: "index_artifacts_native_symbols_on_blob_id", unique: true
    t.index ["created_by_id"], name: "index_artifacts_native_symbols_on_created_by_id"
    t.index ["id", "project_id"], name: "index_artifacts_native_symbols_on_id_and_project_id", unique: true
    t.index ["project_id", "debug_id"], name: "index_artifacts_native_symbols_on_project_id_and_debug_id"
    t.index ["project_id", "identity_sha256"], name: "artifacts_native_symbol_identity", unique: true
    t.index ["project_id"], name: "index_artifacts_native_symbols_on_project_id"
  end

  create_table "artifacts_proguard_maps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "debug_id", limit: 36, null: false
    t.string "dist"
    t.string "identity_sha256", limit: 64, null: false
    t.uuid "project_id", null: false
    t.string "release", null: false
    t.datetime "unreferenced_since"
    t.datetime "updated_at", null: false
    t.index ["blob_id"], name: "index_artifacts_proguard_maps_on_blob_id", unique: true
    t.index ["created_by_id"], name: "index_artifacts_proguard_maps_on_created_by_id"
    t.index ["id", "project_id"], name: "index_artifacts_proguard_maps_on_id_and_project_id", unique: true
    t.index ["project_id", "identity_sha256"], name: "artifacts_proguard_map_identity", unique: true
    t.index ["project_id", "release"], name: "index_artifacts_proguard_maps_on_project_id_and_release"
    t.index ["project_id"], name: "index_artifacts_proguard_maps_on_project_id"
  end

  create_table "artifacts_references", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "native_symbol_id"
    t.uuid "proguard_map_id"
    t.uuid "project_id", null: false
    t.uuid "source_map_id"
    t.uuid "symbolication_id", null: false
    t.datetime "updated_at", null: false
    t.index ["native_symbol_id", "symbolication_id"], name: "artifacts_unique_native_reference", unique: true
    t.index ["proguard_map_id", "symbolication_id"], name: "artifacts_unique_proguard_reference", unique: true
    t.index ["project_id"], name: "index_artifacts_references_on_project_id"
    t.index ["source_map_id", "symbolication_id"], name: "artifacts_unique_reference", unique: true
    t.index ["symbolication_id"], name: "index_artifacts_references_on_symbolication_id"
    t.check_constraint "num_nonnulls(source_map_id, proguard_map_id, native_symbol_id) = 1", name: "artifacts_reference_one_kind"
  end

  create_table "artifacts_source_maps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "debug_id", limit: 36
    t.string "dist"
    t.text "generated_file", null: false
    t.string "identity_sha256", limit: 64, null: false
    t.uuid "project_id", null: false
    t.string "release", null: false
    t.datetime "unreferenced_since"
    t.datetime "updated_at", null: false
    t.index ["blob_id"], name: "index_artifacts_source_maps_on_blob_id", unique: true
    t.index ["created_by_id"], name: "index_artifacts_source_maps_on_created_by_id"
    t.index ["id", "project_id"], name: "index_artifacts_source_maps_on_id_and_project_id", unique: true
    t.index ["project_id", "identity_sha256"], name: "artifacts_source_map_identity", unique: true
    t.index ["project_id", "release"], name: "index_artifacts_source_maps_on_project_id_and_release"
    t.index ["project_id"], name: "index_artifacts_source_maps_on_project_id"
  end

  create_table "assistant_conversations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.integer "kind", default: 0, null: false
    t.datetime "last_message_at"
    t.uuid "organization_id", null: false
    t.uuid "project_id"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id", "kind"], name: "index_assistant_conversations_on_owner_and_kind"
    t.index ["account_id", "organization_id", "last_message_at"], name: "idx_on_account_id_organization_id_last_message_at_6fa055439f"
    t.index ["account_id"], name: "index_assistant_conversations_on_account_id"
    t.index ["organization_id"], name: "index_assistant_conversations_on_organization_id"
    t.index ["project_id"], name: "index_assistant_conversations_on_project_id"
  end

  create_table "assistant_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "content"
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "error_code"
    t.uuid "organization_id", null: false
    t.integer "role", null: false
    t.integer "status", default: 0, null: false
    t.jsonb "tools_used", default: [], null: false
    t.boolean "transcribed", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "created_at"], name: "index_assistant_messages_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_assistant_messages_on_conversation_id"
    t.index ["organization_id"], name: "index_assistant_messages_on_organization_id"
  end

  create_table "assistant_proposals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "error_code"
    t.integer "kind", null: false
    t.uuid "message_id", null: false
    t.uuid "organization_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.uuid "result_id"
    t.string "result_type"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_assistant_proposals_on_account_id"
    t.index ["message_id"], name: "index_assistant_proposals_on_message_id"
    t.index ["organization_id"], name: "index_assistant_proposals_on_organization_id"
  end

  create_table "authorization_account_permissions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.integer "effect", null: false
    t.uuid "organization_id", null: false
    t.string "permission_key", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id", "permission_key"], name: "index_account_permissions_on_account_org_and_key", unique: true
    t.index ["account_id"], name: "index_authorization_account_permissions_on_account_id"
    t.index ["organization_id"], name: "index_authorization_account_permissions_on_organization_id"
  end

  create_table "authorization_account_roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.uuid "role_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "role_id"], name: "index_account_roles_on_account_and_role", unique: true
    t.index ["account_id"], name: "index_authorization_account_roles_on_account_id"
    t.index ["organization_id"], name: "index_authorization_account_roles_on_organization_id"
    t.index ["role_id"], name: "index_authorization_account_roles_on_role_id"
  end

  create_table "authorization_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "actor_name"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.uuid "organization_id", null: false
    t.uuid "true_actor_id"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_authorization_events_on_actor_id"
    t.index ["organization_id", "created_at"], name: "index_authorization_events_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_authorization_events_on_organization_id"
    t.index ["true_actor_id"], name: "index_authorization_events_on_true_actor_id"
  end

  create_table "authorization_role_permissions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "permission_key", null: false
    t.uuid "role_id", null: false
    t.datetime "updated_at", null: false
    t.index ["role_id", "permission_key"], name: "index_role_permissions_on_role_and_key", unique: true
    t.index ["role_id"], name: "index_authorization_role_permissions_on_role_id"
  end

  create_table "authorization_roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_authorization_roles_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_authorization_roles_on_organization_and_name", unique: true
    t.index ["organization_id"], name: "index_authorization_roles_on_organization_id"
  end

  create_table "authorization_team_roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "role_id", null: false
    t.uuid "team_id", null: false
    t.datetime "updated_at", null: false
    t.index ["role_id"], name: "index_authorization_team_roles_on_role_id"
    t.index ["team_id", "role_id"], name: "index_team_roles_on_team_and_role", unique: true
    t.index ["team_id"], name: "index_authorization_team_roles_on_team_id"
  end

  create_table "chat_conversations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "contextable_id"
    t.string "contextable_type"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "direct_key"
    t.integer "kind", default: 0, null: false
    t.datetime "last_message_at"
    t.uuid "organization_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_chat_conversations_on_created_by_id"
    t.index ["organization_id", "contextable_type", "contextable_id"], name: "index_chat_conversations_on_context", unique: true, where: "(contextable_id IS NOT NULL)"
    t.index ["organization_id", "direct_key"], name: "index_chat_conversations_on_direct_key", unique: true, where: "(direct_key IS NOT NULL)"
    t.index ["organization_id", "last_message_at"], name: "idx_on_organization_id_last_message_at_0f24ab8ee7"
    t.index ["organization_id"], name: "index_chat_conversations_on_organization_id"
  end

  create_table "chat_message_references", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "message_id", null: false
    t.uuid "organization_id", null: false
    t.uuid "referable_id", null: false
    t.string "referable_type", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "referable_type", "referable_id"], name: "index_chat_message_references_unique", unique: true
    t.index ["message_id"], name: "index_chat_message_references_on_message_id"
    t.index ["organization_id"], name: "index_chat_message_references_on_organization_id"
    t.index ["referable_type", "referable_id"], name: "idx_on_referable_type_referable_id_d1c5449232"
  end

  create_table "chat_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id"
    t.text "body"
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_chat_messages_on_author_id"
    t.index ["conversation_id", "created_at"], name: "index_chat_messages_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_chat_messages_on_conversation_id"
    t.index ["organization_id"], name: "index_chat_messages_on_organization_id"
  end

  create_table "chat_participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_read_at"
    t.datetime "muted_at"
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_chat_participants_on_account_id"
    t.index ["conversation_id", "account_id"], name: "index_chat_participants_on_conversation_id_and_account_id", unique: true
    t.index ["conversation_id"], name: "index_chat_participants_on_conversation_id"
    t.index ["organization_id"], name: "index_chat_participants_on_organization_id"
  end

  create_table "clusters_clusters", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "kubernetes_version"
    t.datetime "last_snapshot_at"
    t.string "last_snapshot_id"
    t.boolean "metrics_available", default: false, null: false
    t.string "name", null: false
    t.string "observer_version"
    t.uuid "organization_id", null: false
    t.string "provider"
    t.datetime "revoked_at"
    t.integer "status", default: 0, null: false
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.boolean "truncated", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_clusters_clusters_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_clusters_clusters_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_clusters_clusters_on_organization_id"
    t.index ["token_digest"], name: "index_clusters_clusters_on_token_digest", unique: true
  end

  create_table "clusters_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "cluster_id", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "last_seen_at", null: false
    t.string "message"
    t.string "namespace_name"
    t.string "object_kind"
    t.string "object_name"
    t.string "reason", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id", "last_seen_at"], name: "index_clusters_events_on_cluster_id_and_last_seen_at"
    t.index ["cluster_id", "reason", "object_kind", "object_name", "last_seen_at"], name: "index_clusters_events_identity", unique: true
  end

  create_table "clusters_namespaces", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "cluster_id", null: false
    t.datetime "created_at", null: false
    t.uuid "environment_id"
    t.datetime "gone_at"
    t.string "name", null: false
    t.uuid "project_id"
    t.datetime "updated_at", null: false
    t.index ["cluster_id", "name"], name: "index_clusters_namespaces_on_cluster_id_and_name", unique: true
    t.index ["environment_id"], name: "index_clusters_namespaces_on_environment_id"
    t.index ["project_id"], name: "index_clusters_namespaces_on_project_id"
  end

  create_table "clusters_nodes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "being_removed", default: false, null: false
    t.uuid "cluster_id", null: false
    t.bigint "cpu_capacity_millicores"
    t.bigint "cpu_usage_millicores"
    t.datetime "created_at", null: false
    t.datetime "gone_at"
    t.bigint "memory_capacity_bytes"
    t.bigint "memory_usage_bytes"
    t.string "name", null: false
    t.datetime "node_created_at"
    t.datetime "not_ready_alerted_at"
    t.datetime "not_ready_since"
    t.integer "pods", default: 0, null: false
    t.jsonb "pressure", default: {}, null: false
    t.datetime "pressure_alerted_at"
    t.string "provider_id"
    t.boolean "ready", default: false, null: false
    t.boolean "unschedulable", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id", "name"], name: "index_clusters_nodes_on_cluster_id_and_name", unique: true
  end

  create_table "clusters_workloads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "available", default: 0, null: false
    t.uuid "cluster_id", null: false
    t.datetime "crashloop_alerted_at"
    t.datetime "created_at", null: false
    t.datetime "degraded_alerted_at"
    t.datetime "degraded_since"
    t.integer "desired", default: 0, null: false
    t.datetime "gone_at"
    t.string "image"
    t.string "kind", null: false
    t.string "last_reason"
    t.string "name", null: false
    t.uuid "namespace_id", null: false
    t.integer "ready", default: 0, null: false
    t.jsonb "restart_marks", default: [], null: false
    t.integer "restarts_total", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["cluster_id", "namespace_id", "kind", "name"], name: "index_clusters_workloads_identity", unique: true
    t.index ["namespace_id"], name: "index_clusters_workloads_on_namespace_id"
  end

  create_table "connections_account_secret_accesses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "environment_codes", default: [], null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "project_id"], name: "idx_on_account_id_project_id_d232b07222", unique: true
    t.index ["account_id"], name: "index_connections_account_secret_accesses_on_account_id"
    t.index ["organization_id"], name: "index_connections_account_secret_accesses_on_organization_id"
    t.index ["project_id"], name: "index_connections_account_secret_accesses_on_project_id"
  end

  create_table "connections_book_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "book_id", null: false
    t.datetime "created_at", null: false
    t.uuid "group_id", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "group_id"], name: "index_connections_book_groups_on_book_id_and_group_id", unique: true
    t.index ["book_id"], name: "index_connections_book_groups_on_book_id"
    t.index ["group_id"], name: "index_connections_book_groups_on_group_id"
  end

  create_table "connections_book_projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "book_id", null: false
    t.datetime "created_at", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "project_id"], name: "index_connections_book_projects_on_book_id_and_project_id", unique: true
    t.index ["book_id"], name: "index_connections_book_projects_on_book_id"
    t.index ["project_id"], name: "index_connections_book_projects_on_project_id"
  end

  create_table "connections_environment_hosts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "environment_id", null: false
    t.uuid "host_id", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_connections_environment_hosts_on_created_by_id"
    t.index ["environment_id"], name: "index_connections_environment_hosts_on_environment_id"
    t.index ["host_id"], name: "index_connections_environment_hosts_on_host_id"
    t.index ["project_id", "environment_id", "host_id"], name: "index_connections_environment_hosts_unique", unique: true
    t.index ["project_id"], name: "index_connections_environment_hosts_on_project_id"
  end

  create_table "connections_feature_platforms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "feature_id", null: false
    t.uuid "platform_id", null: false
    t.uuid "release_id"
    t.uuid "status_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_connections_feature_platforms_on_created_by_id"
    t.index ["feature_id", "platform_id"], name: "idx_on_feature_id_platform_id_494bd53785", unique: true
    t.index ["feature_id"], name: "index_connections_feature_platforms_on_feature_id"
    t.index ["platform_id"], name: "index_connections_feature_platforms_on_platform_id"
    t.index ["release_id"], name: "index_connections_feature_platforms_on_release_id"
    t.index ["status_id"], name: "index_connections_feature_platforms_on_status_id"
  end

  create_table "connections_group_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "group_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "group_id"], name: "index_group_memberships_on_account_and_group", unique: true
    t.index ["account_id"], name: "index_connections_group_memberships_on_account_id"
    t.index ["group_id"], name: "index_connections_group_memberships_on_group_id"
  end

  create_table "connections_idea_votes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "idea_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idea_id"], name: "index_connections_idea_votes_on_account_id_and_idea_id", unique: true
    t.index ["account_id"], name: "index_connections_idea_votes_on_account_id"
    t.index ["idea_id"], name: "index_connections_idea_votes_on_idea_id"
  end

  create_table "connections_invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.uuid "invited_by_id"
    t.uuid "organization_id", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_connections_invitations_on_invited_by_id"
    t.index ["organization_id", "email"], name: "index_invitations_pending_per_org_email", unique: true, where: "(accepted_at IS NULL)"
    t.index ["organization_id"], name: "index_connections_invitations_on_organization_id"
  end

  create_table "connections_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.integer "role", default: 0, null: false
    t.jsonb "secret_environment_codes", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id"], name: "index_memberships_on_account_and_organization", unique: true
    t.index ["account_id"], name: "index_connections_memberships_on_account_id"
    t.index ["organization_id"], name: "index_connections_memberships_on_organization_id"
    t.index ["organization_id"], name: "index_one_owner_per_organization", unique: true, where: "(role = 2)"
  end

  create_table "connections_page_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "group_id", null: false
    t.uuid "page_id", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_connections_page_groups_on_group_id"
    t.index ["page_id", "group_id"], name: "index_connections_page_groups_on_page_id_and_group_id", unique: true
    t.index ["page_id"], name: "index_connections_page_groups_on_page_id"
  end

  create_table "connections_page_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "page_id", null: false
    t.uuid "related_id", null: false
    t.string "target_title", null: false
    t.datetime "updated_at", null: false
    t.index ["page_id", "related_id"], name: "index_connections_page_links_on_page_id_and_related_id", unique: true
    t.index ["page_id"], name: "index_connections_page_links_on_page_id"
    t.index ["related_id"], name: "index_connections_page_links_on_related_id"
  end

  create_table "connections_page_projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "page_id", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["page_id", "project_id"], name: "index_connections_page_projects_on_page_id_and_project_id", unique: true
    t.index ["page_id"], name: "index_connections_page_projects_on_page_id"
    t.index ["project_id"], name: "index_connections_page_projects_on_project_id"
  end

  create_table "connections_project_environments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "approval_required"
    t.datetime "created_at", null: false
    t.uuid "environment_id", null: false
    t.uuid "project_id", null: false
    t.boolean "secrets_enabled"
    t.boolean "servers_enabled"
    t.datetime "updated_at", null: false
    t.boolean "uptime_enabled"
    t.index ["environment_id"], name: "index_connections_project_environments_on_environment_id"
    t.index ["project_id", "environment_id"], name: "idx_on_project_id_environment_id_41b6e1a131", unique: true
    t.index ["project_id"], name: "index_connections_project_environments_on_project_id"
  end

  create_table "connections_project_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "project_id"], name: "index_project_memberships_on_account_and_project", unique: true
    t.index ["account_id"], name: "index_connections_project_memberships_on_account_id"
    t.index ["project_id"], name: "index_connections_project_memberships_on_project_id"
  end

  create_table "connections_project_platforms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "platform_id", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["platform_id"], name: "index_connections_project_platforms_on_platform_id"
    t.index ["project_id", "platform_id"], name: "idx_on_project_id_platform_id_ea7620c615", unique: true
    t.index ["project_id"], name: "index_connections_project_platforms_on_project_id"
  end

  create_table "connections_team_group_accesses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "group_id", null: false
    t.uuid "team_id", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_connections_team_group_accesses_on_group_id"
    t.index ["team_id", "group_id"], name: "index_team_group_accesses_on_team_and_group", unique: true
    t.index ["team_id"], name: "index_connections_team_group_accesses_on_team_id"
  end

  create_table "connections_team_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "team_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "team_id"], name: "index_team_memberships_on_account_and_team", unique: true
    t.index ["account_id"], name: "index_connections_team_memberships_on_account_id"
    t.index ["team_id"], name: "index_connections_team_memberships_on_team_id"
  end

  create_table "connections_team_project_accesses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "project_id", null: false
    t.uuid "team_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_connections_team_project_accesses_on_project_id"
    t.index ["team_id", "project_id"], name: "index_team_project_accesses_on_team_and_project", unique: true
    t.index ["team_id"], name: "index_connections_team_project_accesses_on_team_id"
  end

  create_table "connections_ticket_dependencies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blocker_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["blocker_id"], name: "index_connections_ticket_dependencies_on_blocker_id"
    t.index ["created_by_id"], name: "index_connections_ticket_dependencies_on_created_by_id"
    t.index ["ticket_id", "blocker_id"], name: "idx_on_ticket_id_blocker_id_f85027f070", unique: true
    t.index ["ticket_id"], name: "index_connections_ticket_dependencies_on_ticket_id"
    t.check_constraint "ticket_id <> blocker_id", name: "connections_ticket_dependencies_not_self"
  end

  create_table "connections_ticket_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.integer "kind", default: 0, null: false
    t.uuid "related_id", null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_connections_ticket_links_on_created_by_id"
    t.index ["related_id"], name: "index_connections_ticket_links_on_related_id"
    t.index ["ticket_id", "related_id"], name: "index_connections_ticket_links_on_ticket_id_and_related_id", unique: true
    t.index ["ticket_id"], name: "index_connections_ticket_links_on_ticket_id"
  end

  create_table "connections_ticket_platforms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "platform_id", null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["platform_id"], name: "index_connections_ticket_platforms_on_platform_id"
    t.index ["ticket_id", "platform_id"], name: "idx_on_ticket_id_platform_id_f2845da258", unique: true
    t.index ["ticket_id"], name: "index_connections_ticket_platforms_on_ticket_id"
  end

  create_table "connections_ticket_votes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "ticket_id"], name: "index_connections_ticket_votes_on_account_id_and_ticket_id", unique: true
    t.index ["account_id"], name: "index_connections_ticket_votes_on_account_id"
    t.index ["ticket_id"], name: "index_connections_ticket_votes_on_ticket_id"
  end

  create_table "connections_workload_participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "action_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_connections_workload_participants_on_account_id"
    t.index ["action_id", "account_id"], name: "index_workload_participants_on_action_and_account", unique: true
    t.index ["action_id"], name: "index_connections_workload_participants_on_action_id"
  end

  create_table "coworkers_puckies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "instructions", null: false
    t.integer "lock_version", default: 0, null: false
    t.text "memory", default: "", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_coworkers_puckies_on_account_id"
    t.index ["organization_id"], name: "index_coworkers_puckies_on_organization_id"
  end

  create_table "coworkers_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.string "error_code"
    t.text "input", null: false
    t.string "kind", null: false
    t.datetime "lease_expires_at"
    t.text "output", default: "", null: false
    t.uuid "proposal_run_id"
    t.boolean "proposal_superseded", default: false, null: false
    t.jsonb "proposed_task", default: {}, null: false
    t.uuid "puck_id", null: false
    t.datetime "runtime_deadline_at"
    t.jsonb "runtime_state", default: {}, null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.boolean "stop_requested", default: false, null: false
    t.jsonb "tools", default: [], null: false
    t.datetime "updated_at", null: false
    t.uuid "worker_lease_id"
    t.integer "worker_sequence", default: 0, null: false
    t.index ["lease_expires_at"], name: "index_coworkers_runs_on_lease_expires_at"
    t.index ["proposal_run_id"], name: "index_coworkers_runs_on_proposal_run_id", unique: true
    t.index ["puck_id", "kind"], name: "coworkers_active_lane", unique: true, where: "((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text]))"
    t.index ["puck_id"], name: "index_coworkers_runs_on_puck_id"
  end

  create_table "crashes_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "kind", null: false
    t.uuid "project_id", null: false
    t.uuid "report_id", null: false
    t.datetime "updated_at", null: false
    t.index ["blob_id"], name: "crashes_unique_blob_attachment", unique: true
    t.index ["blob_id"], name: "index_crashes_attachments_on_blob_id"
    t.index ["project_id"], name: "index_crashes_attachments_on_project_id"
    t.index ["report_id", "filename"], name: "index_crashes_attachments_on_report_id_and_filename", unique: true
    t.check_constraint "kind::text = ANY (ARRAY['text'::character varying::text, 'report'::character varying::text])", name: "crashes_valid_attachment_kind"
  end

  create_table "crashes_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.uuid "project_id", null: false
    t.datetime "reserved_until", null: false
    t.string "service_name", null: false
    t.string "sha256", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["id", "project_id"], name: "index_crashes_blobs_on_id_and_project_id", unique: true
    t.index ["key"], name: "index_crashes_blobs_on_key", unique: true
    t.index ["project_id"], name: "index_crashes_blobs_on_project_id"
    t.index ["reserved_until"], name: "index_crashes_blobs_on_reserved_until"
    t.check_constraint "byte_size >= 0 AND byte_size <= 10485760", name: "crashes_valid_blob_size"
    t.check_constraint "sha256::text ~ '^[0-9a-f]{64}$'::text", name: "crashes_valid_blob_digest"
  end

  create_table "crashes_reports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "dist"
    t.string "environment"
    t.string "event_id", limit: 32, null: false
    t.jsonb "manifest", default: {}, null: false
    t.uuid "project_id", null: false
    t.string "release"
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_crashes_reports_on_created_at"
    t.index ["id", "project_id"], name: "index_crashes_reports_on_id_and_project_id", unique: true
    t.index ["project_id", "event_id"], name: "index_crashes_reports_on_project_id_and_event_id", unique: true
    t.index ["project_id"], name: "index_crashes_reports_on_project_id"
    t.check_constraint "event_id::text ~ '^[0-9a-f]{32}$'::text", name: "crashes_valid_event_id"
  end

  create_table "crons_check_ins", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "checked_in_at", null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.uuid "monitor_id", null: false
    t.string "reason", limit: 500
    t.integer "status", default: 0, null: false
    t.index ["monitor_id", "checked_in_at"], name: "index_crons_check_ins_on_monitor_id_and_checked_in_at"
    t.index ["monitor_id"], name: "index_crons_check_ins_on_monitor_id"
  end

  create_table "crons_monitors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "environment_id"
    t.integer "expected_interval_minutes", null: false
    t.integer "grace_minutes", default: 5, null: false
    t.datetime "last_check_in_at"
    t.datetime "missed_alerted_at"
    t.string "name", null: false
    t.uuid "project_id", null: false
    t.string "slug", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["environment_id"], name: "index_crons_monitors_on_environment_id"
    t.index ["project_id", "slug"], name: "index_crons_monitors_on_project_id_and_slug", unique: true
    t.index ["project_id"], name: "index_crons_monitors_on_project_id"
    t.index ["status", "enabled"], name: "index_crons_monitors_on_status_and_enabled"
  end

  create_table "datasets_cells", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "column_id", null: false
    t.datetime "created_at", null: false
    t.uuid "row_id", null: false
    t.datetime "updated_at", null: false
    t.index ["column_id"], name: "index_datasets_cells_on_column_id"
    t.index ["row_id", "column_id"], name: "index_datasets_cells_on_row_id_and_column_id", unique: true
    t.index ["row_id"], name: "index_datasets_cells_on_row_id"
  end

  create_table "datasets_columns", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.uuid "dataset_id", null: false
    t.integer "kind", default: 0, null: false
    t.string "label", null: false
    t.jsonb "options", default: [], null: false
    t.integer "position", default: 0, null: false
    t.boolean "required", default: false, null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["dataset_id", "code"], name: "index_datasets_columns_on_dataset_id_and_code", unique: true
    t.index ["dataset_id", "position"], name: "index_datasets_columns_on_dataset_id_and_position"
    t.index ["dataset_id", "role"], name: "index_datasets_columns_on_dataset_id_and_role"
    t.index ["dataset_id"], name: "index_datasets_columns_on_dataset_id"
  end

  create_table "datasets_datasets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.string "name", null: false
    t.uuid "project_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_datasets_datasets_on_created_by_id"
    t.index ["project_id", "status"], name: "index_datasets_datasets_on_project_id_and_status"
    t.index ["project_id"], name: "index_datasets_datasets_on_project_id"
  end

  create_table "datasets_predictions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "dataset_id", null: false
    t.string "error_code"
    t.string "error_message"
    t.uuid "input_row_id", null: false
    t.jsonb "predicted_values", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.uuid "training_id"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_datasets_predictions_on_created_by_id"
    t.index ["dataset_id", "created_at"], name: "index_datasets_predictions_on_dataset_id_and_created_at"
    t.index ["dataset_id"], name: "index_datasets_predictions_on_dataset_id"
    t.index ["input_row_id"], name: "index_datasets_predictions_on_input_row_id"
    t.index ["training_id"], name: "index_datasets_predictions_on_training_id"
  end

  create_table "datasets_rows", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "cell_values", default: {}, null: false
    t.datetime "created_at", null: false
    t.uuid "dataset_id", null: false
    t.integer "position", default: 0, null: false
    t.integer "purpose", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["dataset_id", "purpose"], name: "index_datasets_rows_on_dataset_id_and_purpose"
    t.index ["dataset_id"], name: "index_datasets_rows_on_dataset_id"
  end

  create_table "datasets_trainings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "dataset_id", null: false
    t.string "error_code"
    t.string "error_message"
    t.datetime "heartbeat_at"
    t.jsonb "metrics", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.text "system_prompt"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_datasets_trainings_on_created_by_id"
    t.index ["dataset_id", "status"], name: "index_datasets_trainings_on_dataset_id_and_status"
    t.index ["dataset_id"], name: "index_datasets_trainings_on_dataset_id"
  end

  create_table "errors_events", primary_key: ["id", "created_at"], options: "PARTITION BY RANGE (created_at)", force: :cascade do |t|
    t.string "app_version"
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "environment"
    t.string "event_id", null: false
    t.uuid "group_id", null: false
    t.boolean "handled"
    t.uuid "id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "level"
    t.datetime "occurred_at", null: false
    t.string "os_name"
    t.string "os_version"
    t.jsonb "payload", default: {}, null: false
    t.uuid "project_id", null: false
    t.string "release"
    t.string "replay_session_id"
    t.string "runtime"
    t.string "server_name"
    t.string "span_id", limit: 16
    t.jsonb "stacktrace", default: {}, null: false
    t.string "trace_id"
    t.string "user_hash"
    t.index ["group_id", "occurred_at"], name: "index_errors_events_on_group_id_and_occurred_at"
    t.index ["group_id", "user_hash"], name: "index_errors_events_on_group_id_and_user_hash"
    t.index ["project_id", "created_at"], name: "index_errors_events_on_project_id_and_created_at"
    t.index ["project_id", "replay_session_id"], name: "index_errors_events_on_project_id_and_replay_session_id"
    t.index ["project_id", "trace_id", "span_id"], name: "errors_events_span_correlation"
    t.index ["project_id", "trace_id"], name: "index_errors_events_on_project_id_and_trace_id"
  end

  create_table "errors_grouping_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "field", default: 0, null: false
    t.string "fingerprint_key", null: false, comment: "Chiave logica: occorrenze con la stessa confluiscono nello stesso gruppo"
    t.integer "operator", default: 0, null: false
    t.integer "position", default: 0, null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false, comment: "Pattern cercato nel campo osservato"
    t.index ["project_id", "position"], name: "index_errors_grouping_rules_on_project_id_and_position"
    t.index ["project_id"], name: "index_errors_grouping_rules_on_project_id"
  end

  create_table "errors_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "assignee_id"
    t.datetime "created_at", null: false
    t.string "culprit"
    t.datetime "embedded_at"
    t.vector "embedding", limit: 1024
    t.string "embedding_checksum"
    t.string "embedding_version"
    t.bigint "events_count", default: 0, null: false
    t.string "fingerprint", null: false
    t.datetime "first_seen_at"
    t.string "first_seen_release"
    t.boolean "has_unhandled", default: false, null: false
    t.datetime "last_seen_at"
    t.integer "level", default: 3, null: false
    t.text "merged_fingerprints", default: [], null: false, comment: "Fingerprint dei gruppi assorbiti da una fusione: l'ingest li risolve a questo gruppo", array: true
    t.uuid "project_id", null: false
    t.string "regressed_in_release", comment: "Release che ha causato il reopen su regressione confermata"
    t.string "release"
    t.text "resolution_cause", comment: "Cosa provocava l'errore (compilato alla risoluzione)"
    t.text "resolution_fix", comment: "Cosa è stato fatto per risolverlo"
    t.string "resolved_in_release", comment: "Release live quando il gruppo è stato risolto (audit di regressione)"
    t.integer "status", default: 0, null: false
    t.uuid "ticket_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.boolean "user_context_seen", default: false, null: false
    t.bigint "users_count", default: 0, null: false
    t.index ["assignee_id"], name: "index_errors_groups_on_assignee_id"
    t.index ["embedding"], name: "index_errors_groups_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["embedding_version"], name: "index_errors_groups_on_embedding_version"
    t.index ["merged_fingerprints"], name: "index_errors_groups_on_merged_fingerprints", using: :gin
    t.index ["project_id", "fingerprint"], name: "index_errors_groups_on_project_id_and_fingerprint", unique: true
    t.index ["project_id", "status", "last_seen_at"], name: "index_errors_groups_on_project_id_and_status_and_last_seen_at"
    t.index ["project_id"], name: "index_errors_groups_on_project_id"
    t.index ["ticket_id"], name: "index_errors_groups_on_ticket_id", unique: true, where: "(ticket_id IS NOT NULL)"
  end

  create_table "errors_ingest_payloads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.uuid "project_id", null: false
    t.string "user_hash", limit: 16
    t.index ["created_at"], name: "index_errors_ingest_payloads_on_created_at"
    t.index ["project_id"], name: "index_errors_ingest_payloads_on_project_id"
    t.check_constraint "user_hash IS NULL OR user_hash::text ~ '^[0-9a-f]{16}$'::text", name: "errors_ingest_payloads_user_hash_format"
  end

  create_table "errors_symbolications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "crash_report_id"
    t.datetime "created_at", null: false
    t.datetime "event_created_at", null: false
    t.uuid "event_id", null: false
    t.string "manifest_sha256", limit: 64
    t.uuid "project_id", null: false
    t.jsonb "result", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["crash_report_id"], name: "index_errors_symbolications_on_crash_report_id"
    t.index ["id", "project_id"], name: "index_errors_symbolications_on_id_and_project_id", unique: true
    t.index ["project_id", "event_id", "event_created_at"], name: "errors_symbolication_event", unique: true
    t.index ["project_id"], name: "index_errors_symbolications_on_project_id"
  end

  create_table "github_branches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "html_url"
    t.string "name", null: false
    t.uuid "repository_id", null: false
    t.uuid "ticket_id"
    t.datetime "updated_at", null: false
    t.index ["repository_id", "name"], name: "index_github_branches_on_repository_id_and_name", unique: true
    t.index ["repository_id"], name: "index_github_branches_on_repository_id"
    t.index ["ticket_id"], name: "index_github_branches_on_ticket_id"
  end

  create_table "github_installations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "account_login", null: false
    t.datetime "created_at", null: false
    t.bigint "installation_id", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["installation_id"], name: "index_github_installations_on_installation_id", unique: true
    t.index ["organization_id"], name: "index_github_installations_on_organization_id", unique: true
  end

  create_table "github_pull_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "author_login"
    t.string "base_ref"
    t.datetime "created_at", null: false
    t.bigint "github_id"
    t.datetime "github_updated_at", comment: "Orologio della consegna GitHub, per scartare gli webhook fuori ordine. Non è updated_at."
    t.string "head_ref"
    t.string "head_sha", comment: "Ultimo SHA noto della testa della proposta: cache dell'ultima consegna GitHub, mai una prova."
    t.string "html_url", null: false
    t.datetime "merged_at"
    t.integer "number", null: false
    t.uuid "repository_id", null: false
    t.integer "state", default: 0, null: false
    t.uuid "ticket_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["repository_id", "number"], name: "index_github_pull_requests_on_repository_id_and_number", unique: true
    t.index ["repository_id"], name: "index_github_pull_requests_on_repository_id"
    t.index ["ticket_id"], name: "index_github_pull_requests_on_ticket_id"
  end

  create_table "github_repositories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "autoclose_on_merge", default: false, null: false
    t.datetime "created_at", null: false
    t.string "default_branch", default: "main", null: false
    t.string "full_name", null: false
    t.uuid "installation_id", null: false
    t.datetime "last_sync_at"
    t.jsonb "last_sync_error", default: {}, null: false
    t.string "last_sync_status"
    t.string "package_name"
    t.uuid "preview_environment_id"
    t.uuid "production_environment_id"
    t.uuid "project_id", null: false
    t.integer "registry"
    t.integer "release_probe"
    t.bigint "repo_id", null: false
    t.uuid "staging_environment_id"
    t.boolean "sync_enabled", default: true, null: false
    t.boolean "sync_secrets", default: false, null: false
    t.jsonb "synced_secret_names", default: {}, null: false
    t.boolean "tag_binding_enabled", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["installation_id", "repo_id"], name: "index_github_repositories_on_installation_id_and_repo_id", unique: true
    t.index ["installation_id"], name: "index_github_repositories_on_installation_id"
    t.index ["preview_environment_id"], name: "index_github_repositories_on_preview_environment_id"
    t.index ["production_environment_id"], name: "index_github_repositories_on_production_environment_id"
    t.index ["project_id"], name: "index_github_repositories_on_project_id", unique: true
    t.index ["staging_environment_id"], name: "index_github_repositories_on_staging_environment_id"
    t.check_constraint "registry IS NULL OR (registry = ANY (ARRAY[0, 1, 2, 3, 4]))", name: "github_repositories_registry_known"
    t.check_constraint "release_probe <> 0 OR production_environment_id IS NOT NULL", name: "github_repositories_deploy_smoke_needs_production"
    t.check_constraint "release_probe <> 1 OR registry IS NOT NULL AND package_name IS NOT NULL", name: "github_repositories_publish_needs_registry"
    t.check_constraint "release_probe IS NULL OR (release_probe = ANY (ARRAY[0, 1, 2]))", name: "github_repositories_release_probe_known"
  end

  create_table "guidance_procedures", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "application_mode", default: 0, null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.boolean "enabled", default: true, null: false
    t.string "key", null: false
    t.integer "merge_strategy", default: 0, null: false
    t.uuid "organization_id", null: false
    t.uuid "owner_id", null: false
    t.string "owner_type", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_guidance_procedures_on_created_by_id"
    t.index ["organization_id"], name: "index_guidance_procedures_on_organization_id"
    t.index ["owner_type", "owner_id", "key"], name: "index_guidance_procedures_unique", unique: true
  end

  create_table "guidance_references", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.boolean "enabled", default: true, null: false
    t.text "instructions"
    t.string "key", null: false
    t.integer "kind", default: 0, null: false
    t.string "location"
    t.uuid "organization_id", null: false
    t.uuid "owner_id", null: false
    t.string "owner_type", null: false
    t.integer "position", default: 0, null: false
    t.boolean "required", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_guidance_references_on_created_by_id"
    t.index ["organization_id"], name: "index_guidance_references_on_organization_id"
    t.index ["owner_type", "owner_id", "key"], name: "index_guidance_references_unique", unique: true
  end

  create_table "helpdesk_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.integer "direction", default: 0, null: false, comment: "0 inbound (visitor) · 1 outbound (team)"
    t.uuid "request_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_helpdesk_messages_on_author_id"
    t.index ["request_id"], name: "index_helpdesk_messages_on_request_id"
  end

  create_table "helpdesk_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "browser"
    t.datetime "created_at", null: false
    t.string "device_type"
    t.datetime "discarded_at"
    t.uuid "discarded_by_id"
    t.text "email", comment: "Encrypted. The visitor's address: personal data, erased on request or by retention"
    t.datetime "email_erased_at"
    t.datetime "embedded_at"
    t.vector "embedding", limit: 1024
    t.string "embedding_checksum"
    t.string "embedding_version"
    t.string "os"
    t.text "page_url"
    t.uuid "project_id", null: false
    t.string "session_id", comment: "The SDK visit id, shared with errors and replays of the same visit"
    t.integer "status", default: 0, null: false, comment: "0 received · 1 discarded · 2 converted · 3 linked · 4 answered"
    t.string "summary", null: false
    t.uuid "ticket_id"
    t.datetime "updated_at", null: false
    t.index ["discarded_by_id"], name: "index_helpdesk_requests_on_discarded_by_id"
    t.index ["embedding"], name: "index_helpdesk_requests_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["embedding_version"], name: "index_helpdesk_requests_on_embedding_version"
    t.index ["project_id", "status", "created_at"], name: "idx_on_project_id_status_created_at_9c5b40f205"
    t.index ["project_id"], name: "index_helpdesk_requests_on_project_id"
    t.index ["ticket_id"], name: "index_helpdesk_requests_on_ticket_id"
  end

  create_table "home_deferrals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "card_key", null: false
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.datetime "until_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "card_key"], name: "index_home_deferrals_on_account_and_card", unique: true
    t.index ["account_id", "until_at"], name: "index_home_deferrals_live"
    t.index ["organization_id"], name: "index_home_deferrals_on_organization_id"
  end

  create_table "ideas_cases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "idea_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["idea_id", "created_at"], name: "index_ideas_cases_on_idea_id_and_created_at"
  end

  create_table "ideas_comments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.uuid "idea_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_ideas_comments_on_author_id"
    t.index ["idea_id"], name: "index_ideas_comments_on_idea_id"
  end

  create_table "ideas_ideas", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id"
    t.integer "cases_count", default: 0, null: false
    t.integer "comments_count", default: 0, null: false
    t.datetime "converted_at"
    t.datetime "created_at", null: false
    t.datetime "embedded_at"
    t.vector "embedding", limit: 1024
    t.string "embedding_checksum"
    t.string "embedding_version"
    t.text "monetization", comment: "Come l'idea si ripaga (Markdown). Fatto dell'idea, non un commento"
    t.text "problem", null: false
    t.uuid "project_id", null: false
    t.text "risks", comment: "Rischi e vincoli noti (Markdown). Fatto dell'idea, non un commento"
    t.text "solution"
    t.text "stakeholders", default: [], null: false, array: true
    t.integer "status", default: 0, null: false
    t.uuid "ticket_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "votes_count", default: 0, null: false
    t.index ["author_id"], name: "index_ideas_ideas_on_author_id"
    t.index ["embedding"], name: "index_ideas_ideas_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["embedding_version"], name: "index_ideas_ideas_on_embedding_version"
    t.index ["project_id", "status"], name: "index_ideas_ideas_on_project_id_and_status"
    t.index ["project_id"], name: "index_ideas_ideas_on_project_id"
    t.index ["stakeholders"], name: "index_ideas_ideas_on_stakeholders", using: :gin
    t.index ["ticket_id"], name: "index_ideas_ideas_on_ticket_id", unique: true, where: "(ticket_id IS NOT NULL)"
    t.index ["votes_count"], name: "index_ideas_ideas_on_votes_count"
  end

  create_table "ideas_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "kind", default: 0, null: false, comment: "0 evolution: source evolve target (un solo livello) · 1 related: parenti alla pari"
    t.uuid "source_id", null: false
    t.uuid "target_id", null: false
    t.datetime "updated_at", null: false
    t.index ["source_id", "target_id"], name: "index_ideas_links_on_source_id_and_target_id", unique: true
    t.index ["source_id"], name: "index_ideas_links_on_source_id"
    t.index ["source_id"], name: "index_ideas_links_one_parent_per_source", unique: true, where: "(kind = 0)"
    t.index ["target_id"], name: "index_ideas_links_on_target_id"
  end

  create_table "integrations_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_key", null: false
    t.uuid "connected_by_id"
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.string "provider", null: false, comment: "Chiave del registro Integrations::Providers"
    t.datetime "updated_at", null: false
    t.string "verification_error"
    t.datetime "verified_at"
    t.index ["connected_by_id"], name: "index_integrations_credentials_on_connected_by_id"
    t.index ["organization_id", "provider"], name: "index_integrations_credentials_on_organization_id_and_provider", unique: true
    t.index ["organization_id"], name: "index_integrations_credentials_on_organization_id"
  end

  create_table "knowledge_ask_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.text "answer", comment: "Risposta generata; nil quando la KB non aveva abbastanza informazioni"
    t.jsonb "citations", default: [], null: false, comment: "Pagine citate {id,title,kind,kind_label,url} per riaprire la risposta"
    t.datetime "created_at", null: false
    t.boolean "full_access", default: false, null: false
    t.uuid "group_ids", default: [], null: false, array: true
    t.boolean "insufficient", default: false, null: false
    t.uuid "organization_id", null: false
    t.uuid "project_ids", default: [], null: false, array: true
    t.text "question", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_knowledge_ask_logs_on_account_id"
    t.index ["group_ids"], name: "index_knowledge_ask_logs_on_group_ids", using: :gin
    t.index ["organization_id", "created_at"], name: "index_knowledge_ask_logs_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_knowledge_ask_logs_on_organization_id"
    t.index ["project_ids"], name: "index_knowledge_ask_logs_on_project_ids", using: :gin
  end

  create_table "knowledge_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.uuid "page_id", null: false
    t.integer "position", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_knowledge_attachments_on_created_by_id"
    t.index ["page_id", "created_at"], name: "index_knowledge_attachments_on_page_id_and_created_at"
    t.index ["page_id"], name: "index_knowledge_attachments_on_page_id"
  end

  create_table "knowledge_books", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.text "description"
    t.uuid "organization_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_knowledge_books_on_created_by_id"
    t.index ["organization_id"], name: "index_knowledge_books_on_organization_id"
  end

  create_table "knowledge_pages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "ai_review_format"
    t.string "ai_review_model"
    t.integer "ai_review_verdict"
    t.jsonb "ai_review_violations", default: [], null: false
    t.datetime "ai_reviewed_at"
    t.integer "author_kind"
    t.string "author_origin"
    t.text "body", null: false
    t.uuid "book_id"
    t.datetime "consolidated_at"
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.datetime "embedded_at"
    t.vector "embedding", limit: 1024
    t.string "embedding_checksum"
    t.string "embedding_version"
    t.integer "kind", default: 0, null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.string "publication_key"
    t.datetime "review_after"
    t.text "review_note"
    t.datetime "reviewed_at"
    t.uuid "reviewed_by_id"
    t.string "source_path"
    t.integer "status", default: 0, null: false
    t.text "tags", default: [], null: false, array: true
    t.text "tech_spec"
    t.boolean "technical_body", default: false, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id"], name: "index_knowledge_pages_on_book_id"
    t.index ["created_by_id"], name: "index_knowledge_pages_on_created_by_id"
    t.index ["embedding"], name: "index_knowledge_pages_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["embedding_version"], name: "index_knowledge_pages_on_embedding_version"
    t.index ["kind"], name: "index_knowledge_pages_on_kind"
    t.index ["organization_id", "ai_review_verdict"], name: "index_knowledge_pages_on_organization_id_and_ai_review_verdict"
    t.index ["organization_id", "author_kind"], name: "index_knowledge_pages_on_organization_id_and_author_kind"
    t.index ["organization_id", "publication_key"], name: "index_knowledge_pages_publication_identity", unique: true, where: "(publication_key IS NOT NULL)"
    t.index ["organization_id", "review_after"], name: "index_knowledge_pages_on_organization_id_and_review_after"
    t.index ["organization_id", "status"], name: "index_knowledge_pages_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_knowledge_pages_on_organization_id"
    t.index ["reviewed_by_id"], name: "index_knowledge_pages_on_reviewed_by_id"
    t.index ["tags"], name: "index_knowledge_pages_on_tags", using: :gin
  end

  create_table "knowledge_sample_questions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "kind", null: false, comment: "Tipo pagina (note/decision/guide): sceglie il template della domanda"
    t.uuid "knowledge_page_id"
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.uuid "project_id", null: false
    t.string "title", null: false, comment: "Snapshot del titolo pagina: la domanda si compone a display via i18n"
    t.datetime "updated_at", null: false
    t.index ["knowledge_page_id"], name: "index_knowledge_sample_questions_on_knowledge_page_id"
    t.index ["organization_id", "project_id"], name: "idx_on_organization_id_project_id_2d99bc13fa"
    t.index ["organization_id"], name: "index_knowledge_sample_questions_on_organization_id"
    t.index ["project_id"], name: "index_knowledge_sample_questions_on_project_id"
  end

  create_table "knowledge_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "author_name"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.integer "kind", default: 0, null: false
    t.integer "number", null: false
    t.uuid "organization_id", null: false
    t.uuid "page_id", null: false
    t.text "tech_spec"
    t.string "title", null: false
    t.index ["created_by_id"], name: "index_knowledge_versions_on_created_by_id"
    t.index ["organization_id"], name: "index_knowledge_versions_on_organization_id"
    t.index ["page_id", "created_at"], name: "index_knowledge_versions_on_page_id_and_created_at"
    t.index ["page_id", "number"], name: "index_knowledge_versions_on_page_id_and_number", unique: true
    t.index ["page_id"], name: "index_knowledge_versions_on_page_id"
  end

  create_table "logs_entries", primary_key: ["id", "created_at"], options: "PARTITION BY RANGE (created_at)", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.string "environment"
    t.string "error_event_id"
    t.string "event_id", null: false
    t.decimal "event_time_unix_nano", precision: 20
    t.string "fingerprint"
    t.uuid "id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "level", default: 1, null: false
    t.string "logger_name"
    t.text "message", null: false
    t.decimal "observed_time_unix_nano", precision: 20
    t.datetime "occurred_at", null: false
    t.jsonb "otlp_payload", default: {}, null: false
    t.string "payload_digest", limit: 64
    t.uuid "project_id", null: false
    t.string "release"
    t.integer "severity_number"
    t.string "severity_text"
    t.string "signal_source", default: "native", null: false
    t.string "span_id", limit: 16
    t.string "trace_id"
    t.boolean "trace_id_extracted", default: false, null: false
    t.index ["project_id", "created_at"], name: "index_logs_entries_on_project_id_and_created_at"
    t.index ["project_id", "environment"], name: "index_logs_entries_on_project_id_and_environment"
    t.index ["project_id", "error_event_id"], name: "logs_entries_error_identity"
    t.index ["project_id", "fingerprint"], name: "index_logs_entries_on_project_id_and_fingerprint", where: "(fingerprint IS NOT NULL)"
    t.index ["project_id", "level"], name: "index_logs_entries_on_project_id_and_level"
    t.index ["project_id", "occurred_at"], name: "index_logs_entries_on_project_id_and_occurred_at", order: { occurred_at: :desc }
    t.index ["project_id", "trace_id", "span_id"], name: "logs_entries_span_correlation"
    t.index ["project_id", "trace_id"], name: "index_logs_entries_on_project_id_and_trace_id"
    t.check_constraint "event_time_unix_nano IS NULL OR event_time_unix_nano >= 0::numeric AND event_time_unix_nano <= '18446744073709551615'::numeric", name: "logs_valid_event_time_unix_nano"
    t.check_constraint "observed_time_unix_nano IS NULL OR observed_time_unix_nano >= 0::numeric AND observed_time_unix_nano <= '18446744073709551615'::numeric", name: "logs_valid_observed_time_unix_nano"
    t.check_constraint "severity_number IS NULL OR severity_number >= 0 AND severity_number <= 24", name: "logs_valid_otlp_severity"
  end

  create_table "logs_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "linkable_id", null: false
    t.string "linkable_type", null: false
    t.uuid "log_entry_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_logs_links_on_created_by_id"
    t.index ["linkable_type", "linkable_id"], name: "index_logs_links_on_linkable"
    t.index ["log_entry_id", "linkable_type", "linkable_id"], name: "index_logs_links_unique", unique: true
    t.index ["log_entry_id"], name: "index_logs_links_on_log_entry_id"
  end

  create_table "measurements_points", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "first_received_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "payload_digest", limit: 64, null: false
    t.uuid "project_id", null: false
    t.uuid "series_id", null: false
    t.decimal "start_time_unix_nano", precision: 20, null: false
    t.decimal "time_unix_nano", precision: 20, null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "first_received_at"], name: "measurements_points_retention"
    t.index ["project_id"], name: "index_measurements_points_on_project_id"
    t.index ["series_id", "start_time_unix_nano", "time_unix_nano"], name: "measurements_points_identity", unique: true
    t.index ["series_id", "time_unix_nano", "id"], name: "measurements_points_order"
    t.check_constraint "start_time_unix_nano >= 0::numeric AND time_unix_nano > 0::numeric AND start_time_unix_nano <= time_unix_nano AND time_unix_nano <= '18446744073709551615'::numeric", name: "measurements_points_valid_time"
  end

  create_table "measurements_series", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description", default: "", null: false
    t.datetime "first_received_at", null: false
    t.string "identity_digest", limit: 64, null: false
    t.jsonb "instrumentation_scope", default: {}, null: false
    t.datetime "last_admitted_at", null: false
    t.string "metric_type", null: false
    t.boolean "monotonic", default: false, null: false
    t.string "name", null: false
    t.jsonb "point_attributes", default: [], null: false
    t.uuid "project_id", null: false
    t.jsonb "resource", default: {}, null: false
    t.string "resource_schema_url", default: "", null: false
    t.string "scope_schema_url", default: "", null: false
    t.integer "temporality", default: 0, null: false
    t.string "unit", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["id", "project_id"], name: "measurements_series_tenant_identity", unique: true
    t.index ["project_id", "identity_digest"], name: "measurements_series_identity", unique: true
    t.index ["project_id", "last_admitted_at", "id"], name: "measurements_series_activity"
    t.index ["project_id"], name: "index_measurements_series_on_project_id"
    t.check_constraint "metric_type::text = 'gauge'::text AND temporality = 0 AND NOT monotonic OR metric_type::text <> 'gauge'::text AND (temporality = ANY (ARRAY[1, 2]))", name: "measurements_series_valid_temporality"
    t.check_constraint "metric_type::text = ANY (ARRAY['gauge'::character varying::text, 'sum'::character varying::text, 'histogram'::character varying::text, 'exponentialHistogram'::character varying::text])", name: "measurements_series_valid_type"
  end

  create_table "metrics_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_max_ms"
    t.float "duration_min_ms"
    t.float "duration_total_ms", default: 0.0, null: false
    t.string "fingerprint", null: false
    t.datetime "first_seen_at"
    t.integer "kind", null: false
    t.datetime "last_seen_at"
    t.uuid "project_id", null: false
    t.bigint "samples_count", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.string "subtype"
    t.uuid "ticket_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "fingerprint"], name: "index_metrics_groups_on_project_id_and_fingerprint", unique: true
    t.index ["project_id", "kind", "last_seen_at"], name: "index_metrics_groups_on_project_id_and_kind_and_last_seen_at"
    t.index ["project_id", "kind", "subtype", "last_seen_at"], name: "index_metrics_groups_on_project_kind_subtype_last_seen"
    t.index ["project_id", "status", "last_seen_at"], name: "index_metrics_groups_on_project_id_and_status_and_last_seen_at"
    t.index ["project_id"], name: "index_metrics_groups_on_project_id"
    t.index ["ticket_id"], name: "index_metrics_groups_on_ticket_id", unique: true, where: "(ticket_id IS NOT NULL)"
  end

  create_table "metrics_samples", primary_key: ["id", "created_at"], options: "PARTITION BY RANGE (created_at)", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_ms", null: false
    t.string "environment"
    t.uuid "group_id", null: false
    t.uuid "id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "kind", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.uuid "project_id", null: false
    t.string "sample_id", null: false
    t.string "subtype"
    t.string "trace_id"
    t.index ["group_id", "occurred_at"], name: "index_metrics_samples_on_group_id_and_occurred_at"
    t.index ["project_id", "created_at"], name: "index_metrics_samples_on_project_id_and_created_at"
    t.index ["project_id", "trace_id"], name: "index_metrics_samples_on_project_id_and_trace_id"
  end

  create_table "organization_ai_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_key"
    t.string "base_url"
    t.string "chat_model"
    t.datetime "created_at", null: false
    t.string "embedding_model"
    t.string "mode", default: "platform", null: false
    t.bigint "monthly_token_cap"
    t.uuid "organization_id", null: false
    t.text "rerank_api_key"
    t.string "rerank_base_url"
    t.string "rerank_model"
    t.string "transcription_model"
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_organization_ai_settings_on_organization_id", unique: true
  end

  create_table "organizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "cto_id"
    t.uuid "default_assignee_id"
    t.string "name", null: false
    t.jsonb "preferences", default: {}, null: false
    t.string "slug", null: false
    t.datetime "suspended_at"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_organizations_on_created_by_id"
    t.index ["cto_id"], name: "index_organizations_on_cto_id"
    t.index ["default_assignee_id"], name: "index_organizations_on_default_assignee_id"
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "product_categories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "group_id", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index "group_id, lower((name)::text)", name: "index_product_categories_on_group_and_lower_name", unique: true
    t.index ["created_by_id"], name: "index_product_categories_on_created_by_id"
    t.index ["group_id", "position"], name: "index_product_categories_on_group_id_and_position"
    t.index ["group_id"], name: "index_product_categories_on_group_id"
    t.index ["organization_id"], name: "index_product_categories_on_organization_id"
  end

  create_table "product_features", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "category_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.uuid "knowledge_page_id"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index "category_id, lower((name)::text)", name: "index_product_features_on_category_and_lower_name", unique: true
    t.index ["category_id", "position"], name: "index_product_features_on_category_id_and_position"
    t.index ["category_id"], name: "index_product_features_on_category_id"
    t.index ["created_by_id"], name: "index_product_features_on_created_by_id"
    t.index ["knowledge_page_id"], name: "index_product_features_on_knowledge_page_id"
    t.index ["organization_id"], name: "index_product_features_on_organization_id"
  end

  create_table "projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "allowed_origins", default: [], null: false
    t.boolean "analytics_enabled", default: false, null: false
    t.string "color"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "cto_id"
    t.uuid "default_assignee_id"
    t.text "description"
    t.uuid "group_id"
    t.boolean "helpdesk_enabled", default: false, null: false
    t.string "icon"
    t.string "key", null: false
    t.integer "last_ticket_number", default: 0, null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.jsonb "preferences", default: {}, null: false
    t.boolean "quick_bug_report_enabled", default: false, null: false
    t.boolean "secret_approval_enabled", default: false, null: false
    t.bigserial "sentry_project_id", null: false
    t.boolean "session_replay_enabled", default: false, null: false
    t.boolean "supporter_enabled", default: false, null: false
    t.text "supporter_reserved_topics"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_projects_on_created_by_id"
    t.index ["cto_id"], name: "index_projects_on_cto_id"
    t.index ["default_assignee_id"], name: "index_projects_on_default_assignee_id"
    t.index ["group_id"], name: "index_projects_on_group_id"
    t.index ["organization_id", "key"], name: "index_projects_on_organization_id_and_key", unique: true
    t.index ["organization_id"], name: "index_projects_on_organization_id"
    t.index ["sentry_project_id"], name: "index_projects_on_sentry_project_id", unique: true
    t.check_constraint "sentry_project_id > 0 AND sentry_project_id <= '9007199254740991'::bigint", name: "projects_sentry_id_safe_integer"
  end

  create_table "projects_coverage_reports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "branch", null: false
    t.decimal "branch_covered_percent", precision: 5, scale: 2
    t.datetime "captured_at", null: false
    t.datetime "created_at", null: false
    t.integer "files_count", default: 0, null: false
    t.decimal "line_covered_percent", precision: 5, scale: 2
    t.integer "never_loaded_count", default: 0, null: false
    t.jsonb "payload", default: {}, null: false
    t.uuid "project_id", null: false
    t.string "sha"
    t.datetime "updated_at", null: false
    t.index ["project_id", "branch"], name: "index_projects_coverage_reports_on_project_id_and_branch", unique: true
  end

  create_table "projects_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.uuid "project_id", null: false
    t.text "tags", default: [], null: false, array: true
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_projects_documents_on_created_by_id"
    t.index ["project_id", "created_at"], name: "index_projects_documents_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_projects_documents_on_project_id"
    t.index ["tags"], name: "index_projects_documents_on_tags", using: :gin
  end

  create_table "projects_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "icon"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_projects_groups_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_projects_groups_on_organization_id_and_name"
    t.index ["organization_id"], name: "index_projects_groups_on_organization_id"
  end

  create_table "projects_milestones", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.string "color", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.date "due_on"
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_projects_milestones_on_created_by_id"
    t.index ["project_id", "active", "position"], name: "idx_on_project_id_active_position_e7605732ff"
    t.index ["project_id", "code"], name: "index_projects_milestones_on_project_id_and_code", unique: true
    t.index ["project_id"], name: "index_projects_milestones_on_project_id"
  end

  create_table "projects_moves", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "destination_organization_id", null: false
    t.string "error_message"
    t.datetime "finished_at"
    t.jsonb "plan", default: {}, null: false
    t.uuid "requested_by_id"
    t.uuid "source_organization_id", null: false
    t.integer "status", default: 0, null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["destination_organization_id"], name: "index_projects_moves_on_destination_organization_id"
    t.index ["requested_by_id"], name: "index_projects_moves_on_requested_by_id"
    t.index ["source_organization_id"], name: "index_projects_moves_on_source_organization_id"
    t.index ["subject_type", "subject_id"], name: "index_projects_moves_one_active_per_subject", unique: true, where: "(status = ANY (ARRAY[0, 1]))"
  end

  create_table "projects_releases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "build_time"
    t.datetime "created_at", null: false
    t.boolean "current", default: false, null: false
    t.datetime "deployed_at"
    t.string "environment", null: false
    t.integer "events_count", default: 0, null: false
    t.datetime "first_event_at"
    t.string "git_tag_url"
    t.datetime "last_event_at"
    t.uuid "project_id", null: false
    t.datetime "proved_at"
    t.string "sha"
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["project_id", "created_at"], name: "index_projects_releases_on_project_id_and_created_at"
    t.index ["project_id", "environment"], name: "index_projects_releases_live_per_environment", unique: true, where: "current"
    t.index ["project_id", "version", "environment"], name: "index_projects_releases_on_project_version_environment", unique: true
    t.index ["project_id"], name: "index_projects_releases_on_project_id"
  end

  create_table "projects_source_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.uuid "source_id", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["source_id", "first_seen_at"], name: "index_projects_source_versions_on_source_id_and_first_seen_at"
    t.index ["source_id", "version"], name: "index_projects_source_versions_on_source_id_and_version", unique: true
    t.index ["source_id"], name: "index_projects_source_versions_on_source_id"
  end

  create_table "projects_sources", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "events_count", default: 0, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.uuid "project_id", null: false
    t.string "tool_code", null: false
    t.datetime "updated_at", null: false
    t.string "version"
    t.index ["project_id", "tool_code"], name: "index_projects_sources_on_project_id_and_tool_code", unique: true
    t.index ["project_id"], name: "index_projects_sources_on_project_id"
  end

  create_table "projects_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "environment_id"
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.uuid "project_id", null: false
    t.string "public_key", null: false
    t.datetime "revoked_at"
    t.jsonb "scopes", default: ["ingest"], null: false
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_projects_tokens_on_created_by_id"
    t.index ["environment_id"], name: "index_projects_tokens_on_environment_id"
    t.index ["expires_at"], name: "index_projects_tokens_on_expires_at"
    t.index ["project_id", "revoked_at"], name: "index_projects_tokens_on_project_id_and_revoked_at"
    t.index ["project_id"], name: "index_projects_tokens_on_project_id"
    t.index ["public_key"], name: "index_projects_tokens_on_public_key", unique: true
    t.index ["token_digest"], name: "index_projects_tokens_on_token_digest", unique: true
  end

  create_table "replays_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.datetime "ended_at"
    t.string "entry_path"
    t.string "environment"
    t.integer "events_count", default: 0, null: false
    t.string "last_path"
    t.jsonb "pages", default: [], null: false
    t.uuid "project_id", null: false
    t.string "replay_session_id", null: false
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_hash"
    t.index ["project_id", "created_at"], name: "index_replays_sessions_on_project_id_and_created_at"
    t.index ["project_id", "entry_path"], name: "index_replays_sessions_on_project_id_and_entry_path"
    t.index ["project_id", "replay_session_id"], name: "index_replays_sessions_on_project_id_and_replay_session_id", unique: true
    t.index ["project_id", "user_hash"], name: "index_replays_sessions_on_project_id_and_user_hash"
    t.index ["project_id"], name: "index_replays_sessions_on_project_id"
  end

  create_table "saved_views", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "filters", default: {}, null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.string "resource_type", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id", "resource_type", "name"], name: "idx_on_account_id_organization_id_resource_type_nam_4139e1d0c5", unique: true
    t.index ["account_id"], name: "index_saved_views_on_account_id"
    t.index ["organization_id"], name: "index_saved_views_on_organization_id"
  end

  create_table "secrets_asset_delegations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "asset_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["asset_id", "project_id"], name: "index_secrets_asset_delegations_on_asset_id_and_project_id", unique: true
    t.index ["asset_id"], name: "index_secrets_asset_delegations_on_asset_id"
    t.index ["created_by_id"], name: "index_secrets_asset_delegations_on_created_by_id"
    t.index ["project_id"], name: "index_secrets_asset_delegations_on_project_id"
  end

  create_table "secrets_asset_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.uuid "asset_id"
    t.datetime "created_at", null: false
    t.uuid "environment_id"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_secrets_asset_events_on_actor_id"
    t.index ["asset_id"], name: "index_secrets_asset_events_on_asset_id"
    t.index ["environment_id"], name: "index_secrets_asset_events_on_environment_id"
    t.index ["organization_id", "created_at"], name: "index_secrets_asset_events_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_secrets_asset_events_on_organization_id"
    t.index ["project_id"], name: "index_secrets_asset_events_on_project_id"
  end

  create_table "secrets_asset_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "asset_id", null: false
    t.bigint "byte_size", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "fingerprint", null: false
    t.string "key_iv", null: false
    t.string "key_tag", null: false
    t.integer "number", null: false
    t.string "original_filename", null: false
    t.string "payload_iv", null: false
    t.string "payload_tag", null: false
    t.datetime "updated_at", null: false
    t.text "wrapped_key", null: false
    t.index ["asset_id", "number"], name: "index_secrets_asset_versions_on_asset_id_and_number", unique: true
    t.index ["asset_id"], name: "index_secrets_asset_versions_on_asset_id"
    t.index ["created_by_id"], name: "index_secrets_asset_versions_on_created_by_id"
  end

  create_table "secrets_assets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "archived_at"
    t.string "asset_type", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.uuid "environment_id"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_secrets_assets_on_created_by_id"
    t.index ["environment_id"], name: "index_secrets_assets_on_environment_id"
    t.index ["organization_id", "project_id", "environment_id", "name"], name: "index_secret_assets_scope_name", unique: true, nulls_not_distinct: true
    t.index ["organization_id"], name: "index_secrets_assets_on_organization_id"
    t.index ["project_id"], name: "index_secrets_assets_on_project_id"
  end

  create_table "secrets_change_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.datetime "decided_at"
    t.uuid "decided_by_id"
    t.text "description"
    t.boolean "description_only", default: false, null: false
    t.uuid "environment_id", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.text "reason"
    t.uuid "requested_by_id"
    t.uuid "source_version_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["decided_by_id"], name: "index_secrets_change_requests_on_decided_by_id"
    t.index ["environment_id"], name: "index_secrets_change_requests_on_environment_id"
    t.index ["organization_id"], name: "index_secrets_change_requests_on_organization_id"
    t.index ["project_id", "status"], name: "index_secrets_change_requests_on_project_id_and_status"
    t.index ["project_id"], name: "index_secrets_change_requests_on_project_id"
    t.index ["requested_by_id"], name: "index_secrets_change_requests_on_requested_by_id"
    t.index ["source_version_id"], name: "index_secrets_change_requests_on_source_version_id"
  end

  create_table "secrets_consolidation_suggestions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "dismissed_at"
    t.uuid "dismissed_by_id"
    t.uuid "environment_id", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.uuid "organization_id", null: false
    t.integer "projects_count", default: 0, null: false
    t.datetime "promoted_at"
    t.uuid "promoted_by_id"
    t.uuid "shared_variable_id"
    t.integer "status", default: 0, null: false
    t.string "suggested_name", null: false
    t.datetime "updated_at", null: false
    t.string "value_fingerprint", null: false
    t.index ["dismissed_by_id"], name: "index_secrets_consolidation_suggestions_on_dismissed_by_id"
    t.index ["environment_id"], name: "index_secrets_consolidation_suggestions_on_environment_id"
    t.index ["organization_id", "environment_id", "value_fingerprint"], name: "index_secrets_consolidation_suggestions_on_identity", unique: true
    t.index ["organization_id"], name: "index_secrets_consolidation_suggestions_on_organization_id"
    t.index ["promoted_by_id"], name: "index_secrets_consolidation_suggestions_on_promoted_by_id"
    t.index ["shared_variable_id"], name: "index_secrets_consolidation_suggestions_on_shared_variable_id"
  end

  create_table "secrets_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "channel"
    t.datetime "created_at", null: false
    t.uuid "environment_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "name"
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_secrets_events_on_actor_id"
    t.index ["environment_id"], name: "index_secrets_events_on_environment_id"
    t.index ["organization_id"], name: "index_secrets_events_on_organization_id"
    t.index ["project_id", "action", "created_at"], name: "index_secrets_events_on_project_id_and_action_and_created_at"
    t.index ["project_id", "created_at"], name: "index_secrets_events_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_secrets_events_on_project_id"
  end

  create_table "secrets_health_anomalies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "acknowledged_at"
    t.uuid "acknowledged_by_id"
    t.text "acknowledgement_reason"
    t.datetime "created_at", null: false
    t.uuid "environment_id", null: false
    t.datetime "first_seen_at", null: false
    t.integer "kind", null: false
    t.datetime "last_seen_at", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.datetime "resolved_at"
    t.string "secret_name", default: "", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["acknowledged_by_id"], name: "index_secrets_health_anomalies_on_acknowledged_by_id"
    t.index ["environment_id"], name: "index_secrets_health_anomalies_on_environment_id"
    t.index ["organization_id", "status"], name: "index_secrets_health_anomalies_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_secrets_health_anomalies_on_organization_id"
    t.index ["project_id", "environment_id", "kind", "secret_name"], name: "index_secrets_health_anomalies_on_identity", unique: true
    t.index ["project_id"], name: "index_secrets_health_anomalies_on_project_id"
  end

  create_table "secrets_overrides", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.uuid "environment_id", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["account_id", "project_id", "environment_id", "name"], name: "index_secrets_overrides_on_account_project_env_name", unique: true
    t.index ["account_id"], name: "index_secrets_overrides_on_account_id"
    t.index ["created_by_id"], name: "index_secrets_overrides_on_created_by_id"
    t.index ["environment_id"], name: "index_secrets_overrides_on_environment_id"
    t.index ["organization_id"], name: "index_secrets_overrides_on_organization_id"
    t.index ["project_id", "environment_id"], name: "index_secrets_overrides_on_project_id_and_environment_id"
    t.index ["project_id"], name: "index_secrets_overrides_on_project_id"
  end

  create_table "secrets_personal_asset_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "action", null: false
    t.uuid "asset_id"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id", "created_at"], name: "index_personal_secret_asset_events_scope"
    t.index ["account_id"], name: "index_secrets_personal_asset_events_on_account_id"
    t.index ["asset_id"], name: "index_secrets_personal_asset_events_on_asset_id"
    t.index ["organization_id"], name: "index_secrets_personal_asset_events_on_organization_id"
  end

  create_table "secrets_personal_asset_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "asset_id", null: false
    t.bigint "byte_size", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.string "fingerprint", null: false
    t.string "key_iv", null: false
    t.string "key_tag", null: false
    t.integer "number", null: false
    t.string "original_filename", null: false
    t.string "payload_iv", null: false
    t.string "payload_tag", null: false
    t.datetime "updated_at", null: false
    t.text "wrapped_key", null: false
    t.index ["asset_id", "number"], name: "index_personal_secret_asset_versions_number", unique: true
    t.index ["asset_id"], name: "index_secrets_personal_asset_versions_on_asset_id"
  end

  create_table "secrets_personal_assets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "archived_at"
    t.string "asset_type", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id", "name"], name: "index_personal_secret_assets_scope_name", unique: true
    t.index ["account_id"], name: "index_secrets_personal_assets_on_account_id"
    t.index ["organization_id"], name: "index_secrets_personal_assets_on_organization_id"
  end

  create_table "secrets_personal_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name"
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id", "created_at"], name: "idx_on_account_id_organization_id_created_at_8690cece99"
    t.index ["account_id"], name: "index_secrets_personal_events_on_account_id"
    t.index ["organization_id"], name: "index_secrets_personal_events_on_organization_id"
  end

  create_table "secrets_personal_variables", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["account_id", "organization_id", "name"], name: "index_secrets_personal_variables_on_account_org_name", unique: true
    t.index ["account_id"], name: "index_secrets_personal_variables_on_account_id"
    t.index ["organization_id"], name: "index_secrets_personal_variables_on_organization_id"
  end

  create_table "secrets_personal_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "number", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.uuid "variable_id", null: false
    t.index ["variable_id", "number"], name: "index_secrets_personal_versions_on_variable_id_and_number", unique: true
    t.index ["variable_id"], name: "index_secrets_personal_versions_on_variable_id"
  end

  create_table "secrets_provisions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "destination_environment_id", null: false
    t.uuid "destination_project_id", null: false
    t.string "error_code"
    t.string "error_message"
    t.string "idempotency_key", null: false
    t.uuid "organization_id", null: false
    t.string "request_fingerprint", null: false
    t.string "secret_name", null: false
    t.uuid "secret_variable_id", null: false
    t.uuid "source_environment_id", null: false
    t.uuid "source_project_id", null: false
    t.integer "status", default: 0, null: false
    t.boolean "sync_github", default: true, null: false
    t.datetime "synced_at"
    t.uuid "token_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_secrets_provisions_on_created_by_id"
    t.index ["destination_environment_id"], name: "index_secrets_provisions_on_destination_environment_id"
    t.index ["destination_project_id"], name: "index_secrets_provisions_on_destination_project_id"
    t.index ["organization_id", "idempotency_key"], name: "idx_on_organization_id_idempotency_key_13a6ef4a17", unique: true
    t.index ["organization_id"], name: "index_secrets_provisions_on_organization_id"
    t.index ["secret_variable_id"], name: "index_secrets_provisions_on_secret_variable_id"
    t.index ["source_environment_id"], name: "index_secrets_provisions_on_source_environment_id"
    t.index ["source_project_id"], name: "index_secrets_provisions_on_source_project_id"
    t.index ["token_id"], name: "index_secrets_provisions_on_token_id"
  end

  create_table "secrets_shared_delegations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "local_name"
    t.uuid "project_id", null: false
    t.uuid "shared_value_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_secrets_shared_delegations_on_project_id"
    t.index ["shared_value_id", "project_id"], name: "idx_shared_delegations_identity", unique: true
    t.index ["shared_value_id"], name: "index_secrets_shared_delegations_on_shared_value_id"
  end

  create_table "secrets_shared_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.datetime "created_at", null: false
    t.uuid "environment_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id"
    t.uuid "shared_variable_id"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_secrets_shared_events_on_actor_id"
    t.index ["environment_id"], name: "index_secrets_shared_events_on_environment_id"
    t.index ["organization_id", "created_at"], name: "index_secrets_shared_events_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_secrets_shared_events_on_organization_id"
    t.index ["project_id"], name: "index_secrets_shared_events_on_project_id"
    t.index ["shared_variable_id"], name: "index_secrets_shared_events_on_shared_variable_id"
  end

  create_table "secrets_shared_values", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "environment_id", null: false
    t.uuid "shared_variable_id", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.string "value_fingerprint"
    t.integer "version_number", default: 0, null: false
    t.index ["environment_id", "value_fingerprint"], name: "index_secrets_shared_values_on_value_fingerprint", where: "(value_fingerprint IS NOT NULL)"
    t.index ["environment_id"], name: "index_secrets_shared_values_on_environment_id"
    t.index ["shared_variable_id", "environment_id"], name: "idx_shared_values_identity", unique: true
    t.index ["shared_variable_id"], name: "index_secrets_shared_values_on_shared_variable_id"
  end

  create_table "secrets_shared_variables", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "description", default: "", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_secrets_shared_variables_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_secrets_shared_variables_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_secrets_shared_variables_on_organization_id"
  end

  create_table "secrets_shared_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.integer "number", null: false
    t.uuid "shared_value_id", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["created_by_id"], name: "index_secrets_shared_versions_on_created_by_id"
    t.index ["shared_value_id", "number"], name: "index_secrets_shared_versions_on_shared_value_id_and_number", unique: true
    t.index ["shared_value_id"], name: "index_secrets_shared_versions_on_shared_value_id"
  end

  create_table "secrets_variables", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.uuid "environment_id", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.datetime "rotated_at"
    t.integer "rotation_interval_days"
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.string "value_fingerprint"
    t.index ["created_by_id"], name: "index_secrets_variables_on_created_by_id"
    t.index ["environment_id"], name: "index_secrets_variables_on_environment_id"
    t.index ["organization_id", "environment_id", "value_fingerprint"], name: "index_secrets_variables_on_value_fingerprint", where: "(value_fingerprint IS NOT NULL)"
    t.index ["organization_id"], name: "index_secrets_variables_on_organization_id"
    t.index ["project_id", "environment_id", "name"], name: "index_secrets_variables_on_project_env_name", unique: true
    t.index ["project_id"], name: "index_secrets_variables_on_project_id"
  end

  create_table "secrets_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.integer "number", null: false
    t.uuid "secret_variable_id", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["created_by_id"], name: "index_secrets_versions_on_created_by_id"
    t.index ["secret_variable_id", "number"], name: "index_secrets_versions_on_secret_variable_id_and_number", unique: true
    t.index ["secret_variable_id"], name: "index_secrets_versions_on_secret_variable_id"
  end

  create_table "seo_audits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error"
    t.datetime "finished_at"
    t.integer "issues_open_count", default: 0, null: false
    t.integer "pages_count", default: 0, null: false
    t.integer "pages_unverified_count", default: 0, null: false, comment: "Pagine tentate ma non lette in questo giro: senza, un controllo cieco somiglia a uno riuscito"
    t.uuid "site_id", null: false
    t.datetime "started_at", null: false
    t.integer "status", default: 0, null: false, comment: "0 running, 1 completed, 2 failed"
    t.datetime "updated_at", null: false
    t.index ["site_id", "started_at"], name: "index_seo_audits_on_site_id_and_started_at"
    t.index ["site_id"], name: "index_seo_audits_on_site_id"
  end

  create_table "seo_issues", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "check_key", null: false
    t.datetime "created_at", null: false
    t.jsonb "evidence", default: {}, null: false, comment: "La prova: URL coinvolta, valore trovato, valore atteso. Senza, è un'opinione"
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.uuid "page_id"
    t.datetime "resolved_at"
    t.integer "severity", default: 0, null: false, comment: "0 low, 1 medium, 2 high, 3 critical"
    t.uuid "site_id", null: false
    t.integer "status", default: 0, null: false, comment: "0 open, 1 resolved, 2 ignored"
    t.uuid "ticket_id"
    t.text "triage_note"
    t.datetime "updated_at", null: false
    t.index ["page_id"], name: "index_seo_issues_on_page_id"
    t.index ["site_id", "check_key", "page_id"], name: "index_seo_issues_on_site_id_and_check_key_and_page_id", unique: true, nulls_not_distinct: true
    t.index ["site_id", "status", "severity"], name: "index_seo_issues_on_site_id_and_status_and_severity"
    t.index ["site_id"], name: "index_seo_issues_on_site_id"
    t.index ["ticket_id"], name: "index_seo_issues_on_ticket_id"
  end

  create_table "seo_lab_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "accessibility_score"
    t.integer "best_practices_score"
    t.datetime "created_at", null: false
    t.string "error", comment: "no_api_key | quota_exceeded | unauthorized | invalid_url | lighthouse_error | timeout | upstream_error | unreadable"
    t.decimal "field_cls", precision: 6, scale: 4
    t.jsonb "field_distributions", default: {}, null: false, comment: "Le tre fasce per metrica come le manda Google: è la prova sotto il p75"
    t.integer "field_fcp_ms"
    t.integer "field_inp_ms"
    t.integer "field_lcp_ms"
    t.boolean "field_origin_fallback", default: false, null: false, comment: "true = i numeri sono dell'ORIGINE, non di questa URL: va detto, non fuso in silenzio"
    t.string "field_overall_category", comment: "FAST | AVERAGE | SLOW | NONE, come lo dice Google"
    t.integer "field_ttfb_ms"
    t.string "final_url", comment: "La URL canonica dopo i redirect, come la riporta Google"
    t.datetime "finished_at"
    t.decimal "lab_cls", precision: 6, scale: 4
    t.integer "lab_fcp_ms"
    t.integer "lab_lcp_ms"
    t.integer "lab_speed_index_ms"
    t.integer "lab_tbt_ms", comment: "Total Blocking Time: il proxy di laboratorio dell'INP, che in laboratorio non esiste"
    t.integer "lab_ttfb_ms"
    t.string "lighthouse_version"
    t.integer "performance_score"
    t.integer "seo_score"
    t.uuid "site_id", null: false
    t.datetime "started_at", null: false
    t.integer "status", default: 0, null: false, comment: "0 running, 1 completed, 2 failed"
    t.integer "strategy", null: false, comment: "0 mobile, 1 desktop — mobile prima: è quella con cui Google indicizza"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["site_id", "strategy", "started_at"], name: "index_seo_lab_runs_on_site_id_and_strategy_and_started_at", order: { started_at: :desc }
    t.index ["site_id"], name: "index_seo_lab_runs_on_site_id"
  end

  create_table "seo_pages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "canonical_url"
    t.datetime "created_at", null: false
    t.string "discovered_from", comment: "URL che l'ha linkata, oppure 'sitemap': è ciò che spiega una pagina orfana"
    t.integer "external_links_count", default: 0, null: false
    t.datetime "first_seen_at", null: false
    t.jsonb "h1s", default: [], null: false
    t.integer "h2_count", default: 0, null: false
    t.jsonb "hreflangs", default: {}, null: false, comment: "locale => url dichiarata"
    t.integer "html_bytes", default: 0, null: false
    t.integer "images_total", default: 0, null: false
    t.integer "images_without_alt", default: 0, null: false
    t.boolean "in_sitemap", default: false, null: false
    t.integer "internal_links_count", default: 0, null: false
    t.jsonb "jsonld_types", default: [], null: false
    t.string "lang"
    t.datetime "last_seen_at", null: false
    t.text "meta_description"
    t.string "path"
    t.jsonb "redirect_chain", default: [], null: false, comment: "Le tappe intermedie: una catena di due salti è un rilievo, non un dettaglio"
    t.integer "response_time_ms"
    t.string "robots_directives"
    t.uuid "site_id", null: false
    t.integer "status_code"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.integer "word_count", default: 0, null: false
    t.index ["site_id", "last_seen_at"], name: "index_seo_pages_on_site_id_and_last_seen_at"
    t.index ["site_id", "url"], name: "index_seo_pages_on_site_id_and_url", unique: true
    t.index ["site_id"], name: "index_seo_pages_on_site_id"
  end

  create_table "seo_sites", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "base_url", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.boolean "enabled", default: true, null: false
    t.uuid "environment_id", null: false
    t.boolean "follow_sitemap", default: true, null: false
    t.integer "frequency", default: 0, null: false, comment: "0 = ogni giorno, 1 = ogni settimana"
    t.datetime "last_audited_at"
    t.string "last_error", comment: "Motivo dell'ultimo giro fallito: il sito resta in elenco invece di tacere"
    t.string "last_lab_error", comment: "Motivo dell'ultima misura fallita: la scheda mostra i numeri buoni precedenti dicendo che sono vecchi"
    t.datetime "last_lab_run_at"
    t.integer "max_pages", default: 100, null: false, comment: "Tetto di pagine per giro: un crawler senza tetto è un attacco al sito di qualcun altro"
    t.datetime "next_audit_at"
    t.datetime "next_lab_run_at"
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_seo_sites_on_created_by_id"
    t.index ["enabled", "next_audit_at"], name: "index_seo_sites_on_enabled_and_next_audit_at"
    t.index ["enabled", "next_lab_run_at"], name: "index_seo_sites_on_enabled_and_next_lab_run_at"
    t.index ["environment_id"], name: "index_seo_sites_on_environment_id"
    t.index ["project_id", "environment_id"], name: "index_seo_sites_on_project_id_and_environment_id", unique: true
    t.index ["project_id"], name: "index_seo_sites_on_project_id"
  end

  create_table "servers_actions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.integer "exit_code"
    t.datetime "expires_at", null: false
    t.datetime "finished_at"
    t.uuid "host_id", null: false
    t.string "idempotency_key", null: false
    t.string "kind", null: false
    t.datetime "lease_expires_at"
    t.uuid "organization_id", null: false
    t.text "output"
    t.uuid "requested_by_id"
    t.jsonb "result", default: {}, null: false
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["host_id", "idempotency_key"], name: "index_servers_actions_on_host_id_and_idempotency_key", unique: true
    t.index ["host_id", "status", "created_at"], name: "index_servers_actions_on_host_id_and_status_and_created_at"
    t.index ["host_id"], name: "index_servers_actions_on_host_id"
    t.index ["host_id"], name: "index_servers_actions_one_active_per_host", unique: true, where: "(status = ANY (ARRAY[0, 1]))"
    t.index ["organization_id"], name: "index_servers_actions_on_organization_id"
    t.index ["requested_by_id"], name: "index_servers_actions_on_requested_by_id"
  end

  create_table "servers_container_samples", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "container_id"
    t.decimal "cpu_pct", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.integer "health"
    t.uuid "host_id", null: false
    t.boolean "idle_managed", default: false, null: false
    t.string "image"
    t.bigint "mem_bytes"
    t.string "name", null: false
    t.bigint "net_recv_bytes"
    t.bigint "net_sent_bytes"
    t.boolean "oom_killed", default: false, null: false
    t.datetime "recorded_at", null: false
    t.integer "restart_count", default: 0, null: false
    t.boolean "running", default: true, null: false
    t.datetime "started_at"
    t.string "status"
    t.index ["host_id", "name", "recorded_at"], name: "idx_on_host_id_name_recorded_at_3886dbaff4"
    t.index ["host_id", "recorded_at"], name: "index_servers_container_samples_on_host_id_and_recorded_at"
    t.index ["recorded_at"], name: "index_servers_container_samples_on_recorded_at"
  end

  create_table "servers_enrollment_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_servers_enrollment_tokens_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_servers_enrollment_tokens_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_servers_enrollment_tokens_on_organization_id"
    t.index ["token_digest"], name: "index_servers_enrollment_tokens_on_token_digest", unique: true
  end

  create_table "servers_host_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "host_id", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["host_id"], name: "index_servers_host_tokens_active_host", unique: true, where: "(revoked_at IS NULL)"
    t.index ["host_id"], name: "index_servers_host_tokens_on_host_id"
    t.index ["token_digest"], name: "index_servers_host_tokens_on_token_digest", unique: true
  end

  create_table "servers_hosts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "agent_version"
    t.string "arch"
    t.jsonb "container_outage", default: {}, null: false
    t.jsonb "container_restart_outage", default: {}, null: false
    t.integer "containers_count"
    t.integer "cores"
    t.string "cpu_model"
    t.decimal "cpu_pct", precision: 5, scale: 2
    t.decimal "cpu_threshold", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.jsonb "database_snapshot", default: {}, null: false
    t.string "db_role"
    t.jsonb "details", default: {}, null: false
    t.jsonb "disk_forecast_state", default: {}, null: false
    t.decimal "disk_pct", precision: 5, scale: 2
    t.decimal "disk_threshold", precision: 5, scale: 2
    t.datetime "enrollment_conflict_at"
    t.uuid "enrollment_token_id"
    t.jsonb "failed_services", default: [], null: false
    t.string "fingerprint", null: false
    t.jsonb "groups", default: [], null: false
    t.string "hostname"
    t.jsonb "ignored_container_patterns", default: [], null: false
    t.jsonb "ignored_service_patterns", default: [], null: false
    t.jsonb "journal_snapshots", default: {}, null: false
    t.string "kernel"
    t.datetime "last_push_at"
    t.datetime "last_seen_at"
    t.decimal "load_1", precision: 8, scale: 2
    t.decimal "load_15", precision: 8, scale: 2
    t.decimal "load_5", precision: 8, scale: 2
    t.decimal "mem_pct", precision: 5, scale: 2
    t.decimal "mem_threshold", precision: 5, scale: 2
    t.bigint "memory_total_bytes"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.string "os_name"
    t.boolean "reboot_required", default: false, null: false
    t.datetime "reenrollment_requested_at"
    t.jsonb "replication_outage", default: {}, null: false
    t.jsonb "resource_pressure", default: {}, null: false
    t.datetime "revoked_at"
    t.integer "security_updates_available"
    t.integer "services_failed"
    t.integer "services_total"
    t.datetime "silent_alerted_at"
    t.jsonb "smart_data", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.jsonb "systemd_services", default: [], null: false
    t.decimal "temp_max", precision: 6, scale: 2
    t.integer "threads"
    t.datetime "updated_at", null: false
    t.integer "updates_available"
    t.bigint "uptime_seconds"
    t.index ["enrollment_token_id"], name: "index_servers_hosts_on_enrollment_token_id"
    t.index ["organization_id", "fingerprint"], name: "index_servers_hosts_on_organization_id_and_fingerprint", unique: true
    t.index ["organization_id", "status"], name: "index_servers_hosts_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_servers_hosts_on_organization_id"
    t.index ["status", "last_push_at"], name: "index_servers_hosts_on_status_and_last_push_at"
    t.index ["status", "last_seen_at"], name: "index_servers_hosts_on_status_and_last_seen_at"
  end

  create_table "servers_journal_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "cursor", null: false
    t.uuid "host_id", null: false
    t.text "message", null: false
    t.datetime "occurred_at", null: false
    t.uuid "organization_id", null: false
    t.integer "priority", null: false
    t.string "unit"
    t.index ["host_id", "cursor"], name: "index_servers_journal_entries_on_host_id_and_cursor", unique: true
    t.index ["host_id", "occurred_at"], name: "index_servers_journal_entries_on_host_id_and_occurred_at"
    t.index ["host_id"], name: "index_servers_journal_entries_on_host_id"
    t.index ["occurred_at"], name: "index_servers_journal_entries_on_occurred_at"
    t.index ["organization_id"], name: "index_servers_journal_entries_on_organization_id"
  end

  create_table "servers_sample_rollups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "bucket_at", null: false
    t.decimal "cpu_pct", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.decimal "data_volume_disk_pct", precision: 5, scale: 2
    t.integer "db_connections_max"
    t.decimal "disk_pct", precision: 5, scale: 2
    t.uuid "host_id", null: false
    t.decimal "inode_pct", precision: 5, scale: 2
    t.decimal "mem_pct", precision: 5, scale: 2
    t.bigint "net_recv_bytes"
    t.bigint "net_sent_bytes"
    t.uuid "organization_id", null: false
    t.integer "samples_count", default: 0, null: false
    t.float "temp_max"
    t.index ["host_id", "bucket_at"], name: "index_servers_sample_rollups_on_host_id_and_bucket_at", unique: true
    t.index ["organization_id", "bucket_at"], name: "index_servers_sample_rollups_on_organization_id_and_bucket_at"
  end

  create_table "servers_samples", primary_key: ["id", "recorded_at"], options: "PARTITION BY RANGE (recorded_at)", force: :cascade do |t|
    t.decimal "cpu_pct", precision: 5, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.decimal "data_volume_disk_pct", precision: 5, scale: 2
    t.decimal "db_connection_usage_pct", precision: 5, scale: 2
    t.integer "db_connections"
    t.float "db_replication_lag_seconds"
    t.boolean "db_up"
    t.decimal "disk_pct", precision: 5, scale: 2
    t.bigint "disk_read_bytes"
    t.bigint "disk_write_bytes"
    t.decimal "gpu_pct", precision: 5, scale: 2
    t.decimal "gpu_watt", precision: 8, scale: 2
    t.uuid "host_id", null: false
    t.uuid "id", default: -> { "gen_random_uuid()" }, null: false
    t.decimal "inode_pct", precision: 5, scale: 2
    t.decimal "load_1", precision: 8, scale: 2
    t.decimal "load_15", precision: 8, scale: 2
    t.decimal "load_5", precision: 8, scale: 2
    t.decimal "mem_pct", precision: 5, scale: 2
    t.bigint "net_recv_bytes"
    t.bigint "net_sent_bytes"
    t.uuid "organization_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "recorded_at", null: false
    t.integer "services_failed"
    t.integer "services_total"
    t.decimal "temp_max", precision: 6, scale: 2
    t.bigint "uptime_seconds"
    t.index ["host_id", "recorded_at"], name: "index_servers_samples_on_host_id_and_recorded_at", unique: true
    t.index ["organization_id"], name: "index_servers_samples_on_organization_id"
    t.index ["organization_id"], name: "index_servers_samples_temp_reported", where: "(temp_max IS NOT NULL)"
    t.index ["recorded_at"], name: "index_servers_samples_on_recorded_at"
  end

  create_table "session_health_aggregates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "abnormal", precision: 20, default: "0", null: false
    t.decimal "crashed", precision: 20, default: "0", null: false
    t.datetime "created_at", null: false
    t.string "environment"
    t.decimal "errored", precision: 20, default: "0", null: false
    t.decimal "exited", precision: 20, default: "0", null: false
    t.uuid "project_id", null: false
    t.string "release", null: false
    t.datetime "started_at", null: false
    t.decimal "unhandled", precision: 20, default: "0", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_session_health_aggregates_on_created_at"
    t.index ["project_id", "release", "environment", "started_at"], name: "session_health_aggregates_summary"
    t.index ["project_id"], name: "index_session_health_aggregates_on_project_id"
    t.check_constraint "abnormal >= 0::numeric AND abnormal <= '18446744073709551615'::numeric", name: "session_health_valid_aggregate_abnormal"
    t.check_constraint "crashed >= 0::numeric AND crashed <= '18446744073709551615'::numeric", name: "session_health_valid_aggregate_crashed"
    t.check_constraint "errored >= 0::numeric AND errored <= '18446744073709551615'::numeric", name: "session_health_valid_aggregate_errored"
    t.check_constraint "exited >= 0::numeric AND exited <= '18446744073709551615'::numeric", name: "session_health_valid_aggregate_exited"
    t.check_constraint "unhandled >= 0::numeric AND unhandled <= '18446744073709551615'::numeric", name: "session_health_valid_aggregate_unhandled"
  end

  create_table "session_health_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "abnormal_mechanism"
    t.datetime "created_at", null: false
    t.float "duration"
    t.string "environment"
    t.decimal "errors_count", precision: 20, default: "0", null: false
    t.boolean "initialization_seen", default: false, null: false
    t.integer "observed_update_count", default: 1, null: false
    t.string "payload_digest", limit: 64, null: false
    t.boolean "producer_identity", default: true, null: false
    t.uuid "project_id", null: false
    t.string "release", null: false
    t.decimal "sequence", precision: 20, null: false
    t.uuid "sid", null: false
    t.datetime "started_at", null: false
    t.decimal "started_unix_nano", precision: 20, null: false
    t.string "status", null: false
    t.decimal "update_unix_nano", precision: 20, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_session_health_sessions_on_created_at"
    t.index ["project_id", "release", "environment", "started_at"], name: "session_health_sessions_summary"
    t.index ["project_id", "sid"], name: "index_session_health_sessions_on_project_id_and_sid", unique: true
    t.index ["project_id"], name: "index_session_health_sessions_on_project_id"
    t.check_constraint "duration IS NULL OR duration >= 0::double precision AND duration < 'Infinity'::double precision", name: "session_health_valid_duration"
    t.check_constraint "errors_count >= 0::numeric AND errors_count <= '18446744073709551615'::numeric", name: "session_health_valid_errors"
    t.check_constraint "observed_update_count > 0", name: "session_health_valid_update_count"
    t.check_constraint "sequence >= 0::numeric AND sequence <= '18446744073709551615'::numeric", name: "session_health_valid_sequence"
    t.check_constraint "started_unix_nano >= 0::numeric AND started_unix_nano <= '18446744073709551615'::numeric", name: "session_health_valid_started_unix_nano"
    t.check_constraint "status::text = ANY (ARRAY['ok'::character varying::text, 'exited'::character varying::text, 'crashed'::character varying::text, 'abnormal'::character varying::text, 'unhandled'::character varying::text])", name: "session_health_valid_status"
    t.check_constraint "update_unix_nano >= 0::numeric AND update_unix_nano <= '18446744073709551615'::numeric", name: "session_health_valid_update_unix_nano"
  end

  create_table "settings_global", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "ai_agent_gate_enabled", default: true, null: false
    t.boolean "ai_analysis_relabel_enabled", default: true, null: false
    t.text "ai_api_key"
    t.boolean "ai_assistant_chat_enabled", default: true, null: false
    t.boolean "ai_assistant_tools_enabled", default: true, null: false
    t.boolean "ai_assistant_voice_enabled", default: true, null: false
    t.string "ai_base_url"
    t.string "ai_chat_model"
    t.boolean "ai_comment_compaction_enabled", default: true, null: false
    t.boolean "ai_dataset_predictions_enabled", default: true, null: false
    t.integer "ai_embedding_dimensions"
    t.string "ai_embedding_model"
    t.boolean "ai_embeddings_enabled", default: true, null: false
    t.boolean "ai_knowledge_review_enabled", default: false, null: false
    t.bigint "ai_org_monthly_token_cap"
    t.string "ai_provider"
    t.text "ai_rerank_api_key"
    t.string "ai_rerank_base_url"
    t.string "ai_rerank_model"
    t.boolean "ai_ticket_composition_enabled", default: true, null: false
    t.string "ai_transcription_model"
    t.boolean "ai_triage_enabled", default: true, null: false
    t.integer "analytics_retention_days"
    t.integer "artifacts_retention_days", default: 30, null: false
    t.integer "crashes_retention_days", default: 30, null: false
    t.datetime "created_at", null: false
    t.integer "errors_retention_days"
    t.string "gh_app_client_id"
    t.text "gh_app_client_secret"
    t.string "gh_app_id"
    t.text "gh_app_private_key"
    t.string "gh_app_slug"
    t.text "gh_webhook_secret"
    t.integer "logs_retention_days"
    t.integer "measurements_retention_days", default: 14, null: false
    t.integer "performance_retention_days"
    t.integer "servers_retention_days"
    t.integer "session_health_retention_days", default: 30, null: false
    t.text "telegram_bot_token"
    t.string "telegram_bot_username"
    t.text "telegram_webhook_secret"
    t.integer "traces_retention_days", default: 14, null: false
    t.datetime "updated_at", null: false
    t.integer "uptime_retention_days"
    t.check_constraint "artifacts_retention_days >= 1 AND artifacts_retention_days <= 365", name: "settings_artifacts_retention"
    t.check_constraint "crashes_retention_days >= 1 AND crashes_retention_days <= 365", name: "settings_crashes_retention_range"
    t.check_constraint "measurements_retention_days >= 1 AND measurements_retention_days <= 365", name: "settings_valid_measurement_retention"
    t.check_constraint "session_health_retention_days >= 1 AND session_health_retention_days <= 365", name: "settings_session_health_retention_range"
    t.check_constraint "traces_retention_days >= 1 AND traces_retention_days <= 365", name: "settings_valid_trace_retention"
  end

  create_table "support_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.text "body", null: false
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "handled_at"
    t.uuid "handled_by_id"
    t.uuid "organization_id"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_support_requests_on_account_id"
    t.index ["handled_at", "created_at"], name: "index_support_requests_on_handled_at_and_created_at"
    t.index ["handled_by_id"], name: "index_support_requests_on_handled_by_id"
    t.index ["organization_id"], name: "index_support_requests_on_organization_id"
  end

  create_table "teams_teams", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "default_assignee_id"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_teams_teams_on_created_by_id"
    t.index ["default_assignee_id"], name: "index_teams_teams_on_default_assignee_id"
    t.index ["organization_id", "name"], name: "index_teams_teams_on_organization_and_name", unique: true
    t.index ["organization_id"], name: "index_teams_teams_on_organization_id"
  end

  create_table "ticketing_answers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.text "body", null: false
    t.integer "choice_index"
    t.boolean "covers_round", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "origin", default: 0, null: false
    t.uuid "question_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_ticketing_answers_on_author_id"
    t.index ["question_id", "created_at"], name: "index_ticketing_answers_on_question_id_and_created_at"
    t.index ["question_id"], name: "index_ticketing_answers_on_question_id"
  end

  create_table "ticketing_comments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.text "body", null: false
    t.datetime "compacted_at"
    t.datetime "created_at", null: false
    t.integer "kind", default: 0, null: false
    t.text "original_body"
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_ticketing_comments_on_author_id"
    t.index ["compacted_at"], name: "index_ticketing_comments_on_compacted_at", where: "(compacted_at IS NULL)"
    t.index ["ticket_id"], name: "index_ticketing_comments_on_ticket_id"
  end

  create_table "ticketing_conditions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "position", default: 0, null: false
    t.text "text", null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["ticket_id", "position"], name: "index_ticketing_conditions_on_ticket_id_and_position"
    t.index ["ticket_id"], name: "index_ticketing_conditions_on_ticket_id"
  end

  create_table "ticketing_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "actor_name"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.uuid "organization_id", null: false
    t.uuid "ticket_id", null: false
    t.uuid "true_actor_id"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_ticketing_events_on_actor_id"
    t.index ["organization_id", "created_at"], name: "index_ticketing_events_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_ticketing_events_on_organization_id"
    t.index ["ticket_id", "created_at"], name: "index_ticketing_events_on_ticket_id_and_created_at"
    t.index ["ticket_id"], name: "index_ticketing_events_on_ticket_id"
    t.index ["true_actor_id"], name: "index_ticketing_events_on_true_actor_id"
  end

  create_table "ticketing_questions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "answered_at"
    t.integer "audience", default: 0, null: false
    t.uuid "author_id", null: false
    t.boolean "blocking", default: false, null: false
    t.text "body", null: false
    t.datetime "closed_at"
    t.uuid "closed_by_id"
    t.datetime "created_at", null: false
    t.jsonb "options"
    t.integer "origin", default: 0, null: false
    t.integer "position", default: 0, null: false
    t.uuid "resolved_answer_id"
    t.uuid "round_id"
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_ticketing_questions_on_author_id"
    t.index ["closed_by_id"], name: "index_ticketing_questions_on_closed_by_id"
    t.index ["resolved_answer_id"], name: "index_ticketing_questions_on_resolved_answer_id"
    t.index ["round_id", "position"], name: "index_ticketing_questions_on_round_id_and_position"
    t.index ["round_id"], name: "index_ticketing_questions_on_round_id"
    t.index ["ticket_id", "created_at"], name: "index_ticketing_questions_on_ticket_id_and_created_at"
    t.index ["ticket_id"], name: "index_ticketing_questions_blocking_open", where: "(blocking AND (answered_at IS NULL) AND (closed_at IS NULL))"
    t.index ["ticket_id"], name: "index_ticketing_questions_on_ticket_id"
  end

  create_table "ticketing_reports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id"
    t.string "author_name"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.integer "source", default: 0, null: false
    t.uuid "source_comment_id"
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["author_id"], name: "index_ticketing_reports_on_author_id"
    t.index ["source_comment_id"], name: "index_ticketing_reports_on_source_comment_id", unique: true, where: "(source_comment_id IS NOT NULL)"
    t.index ["ticket_id", "version"], name: "index_ticketing_reports_on_ticket_id_and_version", unique: true
    t.index ["ticket_id"], name: "index_ticketing_reports_on_ticket_id"
  end

  create_table "ticketing_scenarios", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "position", default: 0, null: false
    t.text "step_expected"
    t.text "step_given"
    t.text "step_then"
    t.text "step_when"
    t.uuid "ticket_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["ticket_id", "position"], name: "index_ticketing_scenarios_on_ticket_id_and_position"
    t.index ["ticket_id"], name: "index_ticketing_scenarios_on_ticket_id"
  end

  create_table "ticketing_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.integer "source", default: 0, null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_ticketing_subscriptions_on_account_id"
    t.index ["organization_id", "account_id"], name: "idx_on_organization_id_account_id_036337808a"
    t.index ["organization_id"], name: "index_ticketing_subscriptions_on_organization_id"
    t.index ["ticket_id", "account_id"], name: "index_ticketing_subscriptions_on_ticket_id_and_account_id", unique: true
    t.index ["ticket_id"], name: "index_ticketing_subscriptions_on_ticket_id"
  end

  create_table "ticketing_tickets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "agent_eligibility", default: 0, null: false
    t.integer "agent_eligibility_advice", default: 0, null: false
    t.text "agent_eligibility_advice_reason"
    t.string "agent_eligibility_checksum"
    t.datetime "agent_eligibility_decided_at"
    t.uuid "agent_eligibility_decided_by_id"
    t.datetime "agent_eligibility_evaluated_at"
    t.text "agent_eligibility_reason"
    t.integer "agent_eligibility_source", default: 0, null: false
    t.datetime "analysis_recomposed_at"
    t.datetime "analysis_relabeled_at"
    t.uuid "assignee_id"
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "due_at"
    t.datetime "embedded_at"
    t.vector "embedding", limit: 1024
    t.string "embedding_checksum"
    t.string "embedding_version"
    t.integer "kind", default: 0, null: false
    t.uuid "milestone_id"
    t.integer "number", null: false
    t.uuid "parent_id"
    t.uuid "priority_id", null: false
    t.uuid "project_id", null: false
    t.uuid "reporter_id", null: false
    t.uuid "reviewer_id"
    t.uuid "status_id", null: false
    t.text "technical_analysis"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "votes_count", default: 0, null: false
    t.integer "weight"
    t.index ["agent_eligibility_decided_by_id"], name: "index_ticketing_tickets_on_agent_eligibility_decided_by"
    t.index ["assignee_id"], name: "index_ticketing_tickets_on_assignee_id"
    t.index ["closed_at"], name: "index_ticketing_tickets_on_closed_at"
    t.index ["due_at"], name: "index_ticketing_tickets_on_due_at"
    t.index ["embedding"], name: "index_ticketing_tickets_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["embedding_version"], name: "index_ticketing_tickets_on_embedding_version"
    t.index ["milestone_id"], name: "index_ticketing_tickets_on_milestone_id"
    t.index ["parent_id"], name: "index_ticketing_tickets_on_parent_id"
    t.index ["priority_id"], name: "index_ticketing_tickets_on_priority_id"
    t.index ["project_id", "agent_eligibility"], name: "index_ticketing_tickets_on_project_id_and_agent_eligibility"
    t.index ["project_id", "number"], name: "index_ticketing_tickets_on_project_id_and_number", unique: true
    t.index ["project_id"], name: "index_ticketing_tickets_on_project_id"
    t.index ["reporter_id"], name: "index_ticketing_tickets_on_reporter_id"
    t.index ["reviewer_id"], name: "index_ticketing_tickets_on_reviewer_id"
    t.index ["status_id"], name: "index_ticketing_tickets_on_status_id"
  end

  create_table "ticketing_work_context_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_id"
    t.string "actor_name"
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.datetime "generated_at", null: false
    t.uuid "organization_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.integer "payload_version", default: 1, null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_ticketing_work_context_snapshots_on_actor_id"
    t.index ["organization_id"], name: "index_ticketing_work_context_snapshots_on_organization_id"
    t.index ["ticket_id"], name: "index_ticketing_work_context_snapshots_on_ticket_id", unique: true
  end

  create_table "todos_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.boolean "done", default: false, null: false
    t.uuid "list_id", null: false
    t.integer "position", default: 0, null: false
    t.uuid "ticket_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id", "position"], name: "index_todos_items_on_list_id_and_position"
    t.index ["list_id"], name: "index_todos_items_on_list_id"
    t.index ["ticket_id"], name: "index_todos_items_on_ticket_id"
  end

  create_table "todos_lists", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "color"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "organization_id", "name"], name: "index_todos_lists_on_account_id_and_organization_id_and_name", unique: true
    t.index ["account_id", "organization_id", "position"], name: "idx_on_account_id_organization_id_position_9cc21a5630"
    t.index ["account_id"], name: "index_todos_lists_on_account_id"
    t.index ["organization_id"], name: "index_todos_lists_on_organization_id"
  end

  create_table "todos_shares", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "list_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_todos_shares_on_account_id"
    t.index ["list_id", "account_id"], name: "index_todos_shares_on_list_id_and_account_id", unique: true
    t.index ["list_id"], name: "index_todos_shares_on_list_id"
  end

  create_table "traces", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "expired_spans_count", default: 0, null: false
    t.datetime "first_received_at", null: false
    t.datetime "last_received_at", null: false
    t.uuid "project_id", null: false
    t.bigint "retained_spans_count", default: 0, null: false
    t.string "trace_id", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["id", "project_id", "trace_id"], name: "traces_tenant_identity", unique: true
    t.index ["project_id", "last_received_at", "id"], name: "traces_project_arrival"
    t.index ["project_id", "trace_id"], name: "index_traces_on_project_id_and_trace_id", unique: true
    t.index ["project_id"], name: "index_traces_on_project_id"
    t.check_constraint "retained_spans_count >= 0 AND expired_spans_count >= 0", name: "traces_valid_counts"
    t.check_constraint "trace_id::text ~ '^[0-9a-f]{32}$'::text AND trace_id::text <> repeat('0'::text, 32)", name: "traces_valid_identifier"
  end

  create_table "traces_spans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "end_time_unix_nano", precision: 20, null: false
    t.datetime "ended_at", null: false
    t.datetime "first_received_at", null: false
    t.jsonb "instrumentation_scope", default: {}, null: false
    t.integer "kind", default: 0, null: false
    t.string "name", null: false
    t.string "parent_span_id", limit: 16
    t.jsonb "payload", default: {}, null: false
    t.string "payload_digest", limit: 64, null: false
    t.uuid "project_id", null: false
    t.jsonb "resource", default: {}, null: false
    t.string "resource_schema_url"
    t.string "scope_schema_url"
    t.string "service_name"
    t.string "span_id", limit: 16, null: false
    t.decimal "start_time_unix_nano", precision: 20, null: false
    t.datetime "started_at", null: false
    t.integer "status_code", default: 0, null: false
    t.string "trace_id", limit: 32, null: false
    t.uuid "trace_record_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "first_received_at"], name: "traces_spans_retention"
    t.index ["project_id", "trace_id", "span_id"], name: "traces_spans_identity", unique: true
    t.index ["project_id", "trace_id", "start_time_unix_nano", "span_id"], name: "traces_spans_order"
    t.index ["project_id"], name: "index_traces_spans_on_project_id"
    t.index ["trace_record_id", "parent_span_id"], name: "traces_spans_parent"
    t.check_constraint "parent_span_id IS NULL OR parent_span_id::text ~ '^[0-9a-f]{16}$'::text AND parent_span_id::text <> repeat('0'::text, 16) AND parent_span_id::text <> span_id::text", name: "traces_spans_valid_parent"
    t.check_constraint "span_id::text ~ '^[0-9a-f]{16}$'::text AND span_id::text <> repeat('0'::text, 16)", name: "traces_spans_valid_identifier"
    t.check_constraint "start_time_unix_nano > 0::numeric AND end_time_unix_nano >= start_time_unix_nano AND end_time_unix_nano <= '18446744073709551615'::numeric", name: "traces_spans_valid_time"
  end

  create_table "types_environments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "approval_required", default: false, null: false
    t.string "code", null: false
    t.string "color", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "label", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.boolean "secrets_enabled", default: true, null: false
    t.boolean "servers_enabled", default: true, null: false
    t.datetime "updated_at", null: false
    t.boolean "uptime_enabled", default: true, null: false
    t.index ["created_by_id"], name: "index_types_environments_on_created_by_id"
    t.index ["organization_id", "active", "position"], name: "idx_on_organization_id_active_position_6171a9f3d3"
    t.index ["organization_id", "code"], name: "index_types_environments_on_organization_id_and_code", unique: true
    t.index ["organization_id"], name: "index_types_environments_on_organization_id"
  end

  create_table "types_feature_statuses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "category", default: 0, null: false
    t.string "code", null: false
    t.string "color", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "label", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_types_feature_statuses_on_created_by_id"
    t.index ["organization_id", "active", "position"], name: "idx_on_organization_id_active_position_0cad20f482"
    t.index ["organization_id", "code"], name: "index_types_feature_statuses_on_organization_id_and_code", unique: true
    t.index ["organization_id"], name: "index_types_feature_statuses_on_organization_id"
  end

  create_table "types_platforms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.string "color", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "label", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.boolean "supports_analytics", default: false, null: false
    t.boolean "supports_session_replay", default: false, null: false
    t.boolean "supports_uptime", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_types_platforms_on_created_by_id"
    t.index ["organization_id", "active", "position"], name: "idx_on_organization_id_active_position_e65acd3b0e"
    t.index ["organization_id", "code"], name: "index_types_platforms_on_organization_id_and_code", unique: true
    t.index ["organization_id"], name: "index_types_platforms_on_organization_id"
  end

  create_table "types_ticket_priorities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.string "color", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "label", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_types_ticket_priorities_on_created_by_id"
    t.index ["organization_id", "active", "position"], name: "idx_on_organization_id_active_position_8c2eee6ad1"
    t.index ["organization_id", "code"], name: "index_types_ticket_priorities_on_organization_id_and_code", unique: true
    t.index ["organization_id"], name: "index_types_ticket_priorities_on_organization_id"
  end

  create_table "types_ticket_statuses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "animated", default: false, null: false
    t.integer "category", default: 0, null: false
    t.string "code", null: false
    t.string "color", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.string "label", null: false
    t.uuid "organization_id", null: false
    t.integer "position", default: 0, null: false
    t.boolean "review_gate", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_types_ticket_statuses_on_created_by_id"
    t.index ["organization_id", "active", "position"], name: "idx_on_organization_id_active_position_f2e0c9f44d"
    t.index ["organization_id", "code"], name: "index_types_ticket_statuses_on_organization_id_and_code", unique: true
    t.index ["organization_id"], name: "index_types_ticket_statuses_on_organization_id"
  end

  create_table "uptime_announcements", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.datetime "ends_at"
    t.integer "level", default: 0, null: false
    t.text "message", null: false
    t.uuid "monitor_id", null: false
    t.datetime "starts_at"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_uptime_announcements_on_created_by_id"
    t.index ["monitor_id"], name: "index_uptime_announcements_on_monitor_id", unique: true
  end

  create_table "uptime_checks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "avg_response_ms"
    t.datetime "checked_at", null: false
    t.integer "checks_total"
    t.integer "checks_up"
    t.datetime "created_at", null: false
    t.integer "downtime_seconds"
    t.string "error"
    t.integer "granularity", default: 0, null: false
    t.integer "incidents_count"
    t.uuid "monitor_id", null: false
    t.integer "response_time_ms"
    t.integer "status_code"
    t.boolean "up"
    t.datetime "updated_at"
    t.index ["checked_at"], name: "idx_uptime_checks_raw_checked_at", where: "(granularity = 0)"
    t.index ["monitor_id", "granularity", "checked_at"], name: "index_uptime_checks_on_monitor_granularity_checked_at"
    t.index ["monitor_id", "granularity", "checked_at"], name: "index_uptime_rollups_unique", unique: true, where: "(granularity <> 0)"
    t.index ["monitor_id"], name: "index_uptime_checks_on_monitor_id"
  end

  create_table "uptime_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.string "icon"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.boolean "public_status_enabled", default: false, null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_uptime_groups_on_created_by_id"
    t.index ["organization_id", "name"], name: "index_uptime_groups_on_organization_id_and_name"
    t.index ["organization_id", "slug"], name: "index_uptime_groups_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_uptime_groups_on_organization_id"
  end

  create_table "uptime_incident_updates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "incident_id", null: false
    t.integer "phase", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_uptime_incident_updates_on_created_by_id"
    t.index ["incident_id"], name: "index_uptime_incident_updates_on_incident_id"
  end

  create_table "uptime_incidents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "down_alerted_at"
    t.uuid "monitor_id", null: false
    t.uuid "parent_id"
    t.integer "phase"
    t.datetime "resolved_at"
    t.datetime "started_at", null: false
    t.string "title"
    t.datetime "up_alerted_at"
    t.datetime "updated_at", null: false
    t.index ["monitor_id", "resolved_at"], name: "index_uptime_incidents_on_monitor_id_and_resolved_at"
    t.index ["monitor_id"], name: "index_uptime_incidents_on_monitor_id"
    t.index ["parent_id"], name: "index_uptime_incidents_on_parent_id"
    t.index ["resolved_at"], name: "index_uptime_incidents_pending_up_alert", where: "((up_alerted_at IS NULL) AND (resolved_at IS NOT NULL))"
    t.index ["started_at"], name: "index_uptime_incidents_pending_down_alert", where: "(down_alerted_at IS NULL)"
  end

  create_table "uptime_monitors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "check_type", default: 0, null: false
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.integer "current_status", default: 0, null: false
    t.uuid "environment_id", null: false
    t.string "expected_body_keyword"
    t.integer "expected_status", default: 200, null: false
    t.integer "failure_threshold", default: 2, null: false
    t.uuid "group_id"
    t.string "host"
    t.string "http_method", default: "GET", null: false
    t.integer "interval_seconds", default: 60, null: false
    t.datetime "last_checked_at"
    t.date "latency_alerted_on"
    t.integer "latency_threshold_ms"
    t.string "name", null: false
    t.integer "port"
    t.uuid "project_id", null: false
    t.boolean "public_status_enabled", default: false, null: false
    t.date "ssl_alerted_on"
    t.datetime "ssl_expires_at"
    t.integer "ssl_expiry_warn_days"
    t.integer "timeout_seconds", default: 5, null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["created_by_id"], name: "index_uptime_monitors_on_created_by_id"
    t.index ["environment_id"], name: "index_uptime_monitors_on_environment_id"
    t.index ["group_id"], name: "index_uptime_monitors_on_group_id"
    t.index ["project_id", "active"], name: "index_uptime_monitors_on_project_id_and_active"
    t.index ["project_id", "environment_id"], name: "index_uptime_monitors_on_project_id_and_environment_id", unique: true
    t.index ["project_id"], name: "index_uptime_monitors_on_project_id"
  end

  create_table "usage_reporters", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "environment", null: false
    t.datetime "first_reported_at", null: false
    t.string "kind", null: false
    t.datetime "last_reported_at", null: false
    t.uuid "project_id", null: false
    t.string "release"
    t.string "sdk_name", null: false
    t.string "sdk_version"
    t.boolean "truncated_last_window", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "environment", "kind", "sdk_name"], name: "idx_usage_reporters_identity", unique: true
  end

  create_table "usage_symbols", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "environment", null: false
    t.datetime "first_seen_at", null: false
    t.bigint "hits_count", default: 0, null: false
    t.string "kind", null: false
    t.string "last_release"
    t.string "last_sdk_version"
    t.datetime "last_seen_at", null: false
    t.uuid "project_id", null: false
    t.string "symbol", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "environment", "kind", "symbol"], name: "idx_usage_symbols_identity", unique: true
    t.index ["project_id", "last_seen_at"], name: "index_usage_symbols_on_project_id_and_last_seen_at"
  end

  create_table "vulnerabilities_advisories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "affected", default: [], null: false
    t.text "aliases", default: [], null: false, comment: "Identificatori equivalenti (CVE-…, GHSA-…): è il campo con cui un umano cerca", array: true
    t.datetime "created_at", null: false
    t.string "cvss"
    t.text "cwe_ids", default: [], null: false, array: true
    t.text "details"
    t.datetime "modified_at"
    t.string "osv_id", null: false
    t.datetime "published_at"
    t.datetime "refreshed_at", comment: "Ultima rilettura da OSV: un advisory viene rivisto, la severity può cambiare"
    t.integer "severity", default: 0, null: false
    t.string "summary"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["aliases"], name: "index_vulnerabilities_advisories_on_aliases", using: :gin
    t.index ["osv_id"], name: "index_vulnerabilities_advisories_on_osv_id", unique: true
    t.index ["severity"], name: "index_vulnerabilities_advisories_on_severity"
  end

  create_table "vulnerabilities_findings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "advisory_id", null: false
    t.datetime "created_at", null: false
    t.datetime "first_seen_at", null: false
    t.string "fixed_version", comment: "Prima versione che risolve, se OSV la dichiara: senza, non c'è un aggiornamento da suggerire"
    t.datetime "last_seen_at", null: false
    t.uuid "package_id", null: false
    t.uuid "project_id", null: false
    t.datetime "resolved_at"
    t.integer "status", default: 0, null: false
    t.uuid "ticket_id"
    t.text "triage_note"
    t.datetime "updated_at", null: false
    t.index ["advisory_id"], name: "index_vulnerabilities_findings_on_advisory_id"
    t.index ["package_id", "advisory_id"], name: "index_vulnerabilities_findings_on_package_id_and_advisory_id", unique: true
    t.index ["package_id"], name: "index_vulnerabilities_findings_on_package_id"
    t.index ["project_id", "status"], name: "index_vulnerabilities_findings_on_project_id_and_status"
    t.index ["project_id"], name: "index_vulnerabilities_findings_on_project_id"
    t.index ["ticket_id"], name: "index_vulnerabilities_findings_on_ticket_id", unique: true, where: "(ticket_id IS NOT NULL)"
  end

  create_table "vulnerabilities_manifests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "blob_sha"
    t.string "content_digest"
    t.datetime "created_at", null: false
    t.string "ecosystem", null: false
    t.integer "packages_count", default: 0, null: false
    t.string "parse_error", comment: "Ultimo motivo di parse fallito: il manifest resta visibile invece di sparire in silenzio"
    t.string "path", null: false
    t.uuid "project_id", null: false
    t.datetime "scanned_at"
    t.datetime "updated_at", null: false
    t.index ["project_id", "path"], name: "index_vulnerabilities_manifests_on_project_id_and_path", unique: true
    t.index ["project_id"], name: "index_vulnerabilities_manifests_on_project_id"
  end

  create_table "vulnerabilities_packages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "direct", default: false, null: false
    t.string "ecosystem", null: false
    t.uuid "manifest_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["ecosystem", "name", "version"], name: "idx_on_ecosystem_name_version_a938b5d724"
    t.index ["manifest_id", "name", "version"], name: "idx_on_manifest_id_name_version_91a8005bcb", unique: true
    t.index ["manifest_id"], name: "index_vulnerabilities_packages_on_manifest_id"
  end

  create_table "vulnerabilities_runtime_statuses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "checked_at"
    t.datetime "created_at", null: false
    t.string "cycle"
    t.date "eol_on"
    t.string "latest"
    t.string "name", null: false
    t.uuid "project_id", null: false
    t.string "source_path"
    t.integer "state", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["project_id", "name"], name: "index_vulnerabilities_runtime_statuses_on_project_id_and_name", unique: true
    t.index ["project_id", "state"], name: "index_vulnerabilities_runtime_statuses_on_project_id_and_state"
    t.index ["project_id"], name: "index_vulnerabilities_runtime_statuses_on_project_id"
  end

  create_table "website_access_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "context", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "locale", default: "en", null: false
    t.string "name", null: false
    t.string "status", default: "pending", null: false
    t.string "team", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_website_access_requests_on_email"
    t.index ["status"], name: "index_website_access_requests_on_status"
  end

  create_table "workload_actions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.text "description"
    t.datetime "due_at"
    t.datetime "scheduled_at"
    t.integer "status", default: 0, null: false
    t.uuid "team_id", null: false
    t.uuid "ticket_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_workload_actions_on_created_by_id"
    t.index ["scheduled_at"], name: "index_workload_actions_on_scheduled_at"
    t.index ["team_id", "status"], name: "index_workload_actions_on_team_id_and_status"
    t.index ["team_id"], name: "index_workload_actions_on_team_id"
    t.index ["ticket_id"], name: "index_workload_actions_on_ticket_id"
  end

  add_foreign_key "accounts_api_tokens", "accounts", on_delete: :cascade
  add_foreign_key "accounts_api_tokens", "organizations", on_delete: :cascade
  add_foreign_key "accounts_device_grants", "accounts", on_delete: :cascade
  add_foreign_key "accounts_device_grants", "accounts_api_tokens", column: "api_token_id", on_delete: :nullify
  add_foreign_key "accounts_device_grants", "organizations", on_delete: :cascade
  add_foreign_key "accounts_impersonation_events", "accounts"
  add_foreign_key "accounts_impersonation_events", "accounts", column: "god_id"
  add_foreign_key "accounts_otp_recovery_codes", "accounts", on_delete: :cascade
  add_foreign_key "accounts_sessions", "accounts"
  add_foreign_key "accounts_sessions", "accounts", column: "impersonated_account_id", on_delete: :nullify
  add_foreign_key "accounts_telegram_link_codes", "accounts", on_delete: :cascade
  add_foreign_key "accounts_telegram_link_codes", "organizations", on_delete: :cascade
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activity_events", "accounts", column: "actor_id"
  add_foreign_key "activity_events", "accounts", column: "true_actor_id"
  add_foreign_key "activity_events", "organizations"
  add_foreign_key "agents_attempts", "accounts", column: "service_account_id", on_delete: :restrict
  add_foreign_key "agents_attempts", "agents_hosts", column: "host_id", on_delete: :restrict
  add_foreign_key "agents_attempts", "agents_workflows", column: "workflow_id", on_delete: :cascade
  add_foreign_key "agents_attempts", "organizations", on_delete: :cascade
  add_foreign_key "agents_automator_settings", "organizations", on_delete: :cascade
  add_foreign_key "agents_clarifications", "agents_attempts", column: "attempt_id", on_delete: :restrict
  add_foreign_key "agents_clarifications", "agents_workflows", column: "workflow_id", on_delete: :cascade
  add_foreign_key "agents_clarifications", "ticketing_comments", column: "question_comment_id", on_delete: :nullify
  add_foreign_key "agents_clarifications", "ticketing_comments", column: "response_comment_id", on_delete: :nullify
  add_foreign_key "agents_claude_credentials", "accounts", column: "set_by_id", on_delete: :nullify
  add_foreign_key "agents_claude_credentials", "organizations", on_delete: :cascade
  add_foreign_key "agents_delivery_candidates", "agents_attempts", column: "attempt_id"
  add_foreign_key "agents_delivery_candidates", "agents_workflows", column: "workflow_id"
  add_foreign_key "agents_delivery_candidates", "github_repositories", column: "repository_id"
  add_foreign_key "agents_host_tokens", "agents_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "agents_hosts", "accounts", column: "certified_by_id", on_delete: :nullify
  add_foreign_key "agents_hosts", "accounts", column: "service_account_id", on_delete: :nullify
  add_foreign_key "agents_hosts", "organizations", on_delete: :cascade
  add_foreign_key "agents_hosts", "projects", column: "heartbeat_project_id", on_delete: :nullify
  add_foreign_key "agents_leases", "accounts", on_delete: :cascade
  add_foreign_key "agents_leases", "agents_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "agents_leases", "organizations", on_delete: :cascade
  add_foreign_key "agents_leases", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "agents_leases_tombstones", "accounts", on_delete: :cascade
  add_foreign_key "agents_leases_tombstones", "agents_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "agents_leases_tombstones", "organizations", on_delete: :cascade
  add_foreign_key "agents_leases_tombstones", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "agents_limit_policies", "organizations", on_delete: :cascade
  add_foreign_key "agents_limit_policies", "projects", on_delete: :cascade
  add_foreign_key "agents_limit_reservations", "agents_hosts", column: "host_id", on_delete: :nullify
  add_foreign_key "agents_limit_reservations", "organizations", on_delete: :cascade
  add_foreign_key "agents_limit_reservations", "projects", on_delete: :nullify
  add_foreign_key "agents_limit_usages", "agents_limit_policies", column: "policy_id", on_delete: :cascade
  add_foreign_key "agents_openrouter_credentials", "accounts", column: "set_by_id", on_delete: :nullify
  add_foreign_key "agents_openrouter_credentials", "organizations", on_delete: :cascade
  add_foreign_key "agents_plans", "accounts", column: "approved_by_id", on_delete: :nullify
  add_foreign_key "agents_plans", "agents_attempts", column: "attempt_id", on_delete: :restrict
  add_foreign_key "agents_plans", "agents_workflows", column: "workflow_id", on_delete: :cascade
  add_foreign_key "agents_release_assignments", "agents_workflows", column: "workflow_id"
  add_foreign_key "agents_release_assignments", "github_repositories"
  add_foreign_key "agents_skill_bundles", "organizations", on_delete: :cascade
  add_foreign_key "agents_supporter_decisions", "accounts", column: "seen_by_id", on_delete: :nullify
  add_foreign_key "agents_supporter_decisions", "agents_workflows", column: "workflow_id", on_delete: :cascade
  add_foreign_key "agents_supporter_decisions", "organizations", on_delete: :cascade
  add_foreign_key "agents_ticket_queue_deferrals", "agents_hosts", column: "host_id", on_delete: :nullify
  add_foreign_key "agents_ticket_queue_deferrals", "organizations", on_delete: :cascade
  add_foreign_key "agents_ticket_queue_deferrals", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "agents_tokens", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "agents_tokens", "organizations", on_delete: :cascade
  add_foreign_key "agents_workflow_probes", "agents_workflows", column: "workflow_id"
  add_foreign_key "agents_workflows", "accounts", column: "approved_by_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "autopilot_approved_by_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "autopilot_by_service_account_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "cancelled_by_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "closer_production_approved_by_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "closer_production_by_service_account_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "closer_staging_by_service_account_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "planned_by_service_account_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "accounts", column: "triage_by_service_account_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "agents_delivery_candidates", column: "review_candidate_id"
  add_foreign_key "agents_workflows", "agents_hosts", column: "autopilot_by_host_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "agents_hosts", column: "closer_production_by_host_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "agents_hosts", column: "closer_staging_by_host_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "agents_hosts", column: "planned_by_host_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "agents_hosts", column: "triage_by_host_id", on_delete: :nullify
  add_foreign_key "agents_workflows", "agents_plans", column: "frozen_plan_id"
  add_foreign_key "agents_workflows", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "ai_gateway_keys", "accounts", column: "created_by_id"
  add_foreign_key "ai_gateway_usages", "ai_gateway_keys", column: "key_id"
  add_foreign_key "ai_requests", "accounts", on_delete: :cascade
  add_foreign_key "ai_requests", "organizations", on_delete: :cascade
  add_foreign_key "ai_usage_months", "organizations"
  add_foreign_key "alerting_channels", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "alerting_channels", "organizations", on_delete: :cascade
  add_foreign_key "alerting_evaluations", "alerting_rules", column: "rule_id", on_delete: :cascade
  add_foreign_key "alerting_evaluations", "alerting_rules", column: ["rule_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :cascade
  add_foreign_key "alerting_evaluations", "projects", on_delete: :cascade
  add_foreign_key "alerting_notifications", "accounts", on_delete: :cascade
  add_foreign_key "alerting_notifications", "alerting_rules", column: "rule_id", on_delete: :nullify
  add_foreign_key "alerting_notifications", "organizations", on_delete: :cascade
  add_foreign_key "alerting_notifications", "projects", on_delete: :nullify
  add_foreign_key "alerting_preferences", "accounts", on_delete: :cascade
  add_foreign_key "alerting_preferences", "organizations", on_delete: :cascade
  add_foreign_key "alerting_rule_channels", "alerting_channels", column: "channel_id", on_delete: :cascade
  add_foreign_key "alerting_rule_channels", "alerting_rules", column: "rule_id", on_delete: :cascade
  add_foreign_key "alerting_rule_host_exclusions", "alerting_rules", column: "rule_id"
  add_foreign_key "alerting_rule_host_exclusions", "servers_hosts", column: "host_id"
  add_foreign_key "alerting_rules", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "alerting_rules", "measurements_series", column: "measurement_series_id", on_delete: :nullify
  add_foreign_key "alerting_rules", "measurements_series", column: ["measurement_series_id", "project_id"], primary_key: ["id", "project_id"], deferrable: :deferred
  add_foreign_key "alerting_rules", "organizations", on_delete: :cascade
  add_foreign_key "alerting_rules", "projects", on_delete: :cascade
  add_foreign_key "alerting_rules", "types_environments", column: "environment_id", on_delete: :nullify
  add_foreign_key "alerting_telegram_groups", "accounts", on_delete: :cascade
  add_foreign_key "alerting_telegram_groups", "organizations", on_delete: :cascade
  add_foreign_key "analytics_goals", "projects", on_delete: :cascade
  add_foreign_key "analytics_links", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "analytics_links", "projects", on_delete: :cascade
  add_foreign_key "analytics_pageviews", "projects", on_delete: :cascade
  add_foreign_key "analytics_web_vitals", "projects", on_delete: :cascade
  add_foreign_key "artifacts_native_symbols", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "artifacts_native_symbols", "artifacts_blobs", column: ["blob_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "artifacts_native_symbols", "projects", on_delete: :cascade
  add_foreign_key "artifacts_proguard_maps", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "artifacts_proguard_maps", "artifacts_blobs", column: ["blob_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "artifacts_proguard_maps", "projects", on_delete: :cascade
  add_foreign_key "artifacts_references", "artifacts_native_symbols", column: ["native_symbol_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :cascade
  add_foreign_key "artifacts_references", "artifacts_proguard_maps", column: ["proguard_map_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :cascade
  add_foreign_key "artifacts_references", "artifacts_source_maps", column: ["source_map_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :cascade
  add_foreign_key "artifacts_references", "errors_symbolications", column: ["symbolication_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :cascade
  add_foreign_key "artifacts_references", "projects", on_delete: :cascade
  add_foreign_key "artifacts_source_maps", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "artifacts_source_maps", "artifacts_blobs", column: ["blob_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "artifacts_source_maps", "projects", on_delete: :cascade
  add_foreign_key "assistant_conversations", "accounts", on_delete: :cascade
  add_foreign_key "assistant_conversations", "organizations", on_delete: :cascade
  add_foreign_key "assistant_conversations", "projects", on_delete: :nullify
  add_foreign_key "assistant_messages", "assistant_conversations", column: "conversation_id", on_delete: :cascade
  add_foreign_key "assistant_messages", "organizations", on_delete: :cascade
  add_foreign_key "assistant_proposals", "accounts", on_delete: :cascade
  add_foreign_key "assistant_proposals", "assistant_messages", column: "message_id", on_delete: :cascade
  add_foreign_key "assistant_proposals", "organizations", on_delete: :cascade
  add_foreign_key "authorization_account_permissions", "accounts", on_delete: :cascade
  add_foreign_key "authorization_account_permissions", "organizations", on_delete: :cascade
  add_foreign_key "authorization_account_roles", "accounts", on_delete: :cascade
  add_foreign_key "authorization_account_roles", "authorization_roles", column: "role_id", on_delete: :cascade
  add_foreign_key "authorization_account_roles", "organizations", on_delete: :cascade
  add_foreign_key "authorization_events", "accounts", column: "actor_id", on_delete: :nullify
  add_foreign_key "authorization_events", "accounts", column: "true_actor_id", on_delete: :nullify
  add_foreign_key "authorization_events", "organizations", on_delete: :cascade
  add_foreign_key "authorization_role_permissions", "authorization_roles", column: "role_id", on_delete: :cascade
  add_foreign_key "authorization_roles", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "authorization_roles", "organizations", on_delete: :cascade
  add_foreign_key "authorization_team_roles", "authorization_roles", column: "role_id", on_delete: :cascade
  add_foreign_key "authorization_team_roles", "teams_teams", column: "team_id", on_delete: :cascade
  add_foreign_key "chat_conversations", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "chat_conversations", "organizations", on_delete: :cascade
  add_foreign_key "chat_message_references", "chat_messages", column: "message_id", on_delete: :cascade
  add_foreign_key "chat_message_references", "organizations", on_delete: :cascade
  add_foreign_key "chat_messages", "accounts", column: "author_id", on_delete: :nullify
  add_foreign_key "chat_messages", "chat_conversations", column: "conversation_id", on_delete: :cascade
  add_foreign_key "chat_messages", "organizations", on_delete: :cascade
  add_foreign_key "chat_participants", "accounts", on_delete: :cascade
  add_foreign_key "chat_participants", "chat_conversations", column: "conversation_id", on_delete: :cascade
  add_foreign_key "chat_participants", "organizations", on_delete: :cascade
  add_foreign_key "clusters_clusters", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "clusters_clusters", "organizations", on_delete: :cascade
  add_foreign_key "clusters_events", "clusters_clusters", column: "cluster_id", on_delete: :cascade
  add_foreign_key "clusters_namespaces", "clusters_clusters", column: "cluster_id", on_delete: :cascade
  add_foreign_key "clusters_namespaces", "projects", on_delete: :nullify
  add_foreign_key "clusters_namespaces", "types_environments", column: "environment_id", on_delete: :nullify
  add_foreign_key "clusters_nodes", "clusters_clusters", column: "cluster_id", on_delete: :cascade
  add_foreign_key "clusters_workloads", "clusters_clusters", column: "cluster_id", on_delete: :cascade
  add_foreign_key "clusters_workloads", "clusters_namespaces", column: "namespace_id", on_delete: :cascade
  add_foreign_key "connections_account_secret_accesses", "accounts", on_delete: :cascade
  add_foreign_key "connections_account_secret_accesses", "organizations", on_delete: :cascade
  add_foreign_key "connections_account_secret_accesses", "projects", on_delete: :cascade
  add_foreign_key "connections_book_groups", "knowledge_books", column: "book_id"
  add_foreign_key "connections_book_groups", "projects_groups", column: "group_id"
  add_foreign_key "connections_book_projects", "knowledge_books", column: "book_id"
  add_foreign_key "connections_book_projects", "projects"
  add_foreign_key "connections_environment_hosts", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "connections_environment_hosts", "projects", on_delete: :cascade
  add_foreign_key "connections_environment_hosts", "servers_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "connections_environment_hosts", "types_environments", column: "environment_id", on_delete: :restrict
  add_foreign_key "connections_feature_platforms", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "connections_feature_platforms", "product_features", column: "feature_id", on_delete: :cascade
  add_foreign_key "connections_feature_platforms", "projects_releases", column: "release_id", on_delete: :nullify
  add_foreign_key "connections_feature_platforms", "types_feature_statuses", column: "status_id", on_delete: :restrict
  add_foreign_key "connections_feature_platforms", "types_platforms", column: "platform_id", on_delete: :restrict
  add_foreign_key "connections_group_memberships", "accounts"
  add_foreign_key "connections_group_memberships", "projects_groups", column: "group_id"
  add_foreign_key "connections_idea_votes", "accounts", on_delete: :cascade
  add_foreign_key "connections_idea_votes", "ideas_ideas", column: "idea_id", on_delete: :cascade
  add_foreign_key "connections_invitations", "accounts", column: "invited_by_id", on_delete: :nullify
  add_foreign_key "connections_invitations", "organizations"
  add_foreign_key "connections_memberships", "accounts"
  add_foreign_key "connections_memberships", "organizations"
  add_foreign_key "connections_page_groups", "knowledge_pages", column: "page_id"
  add_foreign_key "connections_page_groups", "projects_groups", column: "group_id"
  add_foreign_key "connections_page_links", "knowledge_pages", column: "page_id", on_delete: :cascade
  add_foreign_key "connections_page_links", "knowledge_pages", column: "related_id", on_delete: :cascade
  add_foreign_key "connections_page_projects", "knowledge_pages", column: "page_id"
  add_foreign_key "connections_page_projects", "projects"
  add_foreign_key "connections_project_environments", "projects"
  add_foreign_key "connections_project_environments", "types_environments", column: "environment_id"
  add_foreign_key "connections_project_memberships", "accounts"
  add_foreign_key "connections_project_memberships", "projects"
  add_foreign_key "connections_project_platforms", "projects"
  add_foreign_key "connections_project_platforms", "types_platforms", column: "platform_id"
  add_foreign_key "connections_team_group_accesses", "projects_groups", column: "group_id", on_delete: :cascade
  add_foreign_key "connections_team_group_accesses", "teams_teams", column: "team_id", on_delete: :cascade
  add_foreign_key "connections_team_memberships", "accounts", on_delete: :cascade
  add_foreign_key "connections_team_memberships", "teams_teams", column: "team_id", on_delete: :cascade
  add_foreign_key "connections_team_project_accesses", "projects", on_delete: :cascade
  add_foreign_key "connections_team_project_accesses", "teams_teams", column: "team_id", on_delete: :cascade
  add_foreign_key "connections_ticket_dependencies", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "connections_ticket_dependencies", "ticketing_tickets", column: "blocker_id", on_delete: :cascade
  add_foreign_key "connections_ticket_dependencies", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "connections_ticket_links", "accounts", column: "created_by_id"
  add_foreign_key "connections_ticket_links", "ticketing_tickets", column: "related_id"
  add_foreign_key "connections_ticket_links", "ticketing_tickets", column: "ticket_id"
  add_foreign_key "connections_ticket_platforms", "ticketing_tickets", column: "ticket_id"
  add_foreign_key "connections_ticket_platforms", "types_platforms", column: "platform_id"
  add_foreign_key "connections_ticket_votes", "accounts", on_delete: :cascade
  add_foreign_key "connections_ticket_votes", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "connections_workload_participants", "accounts", on_delete: :cascade
  add_foreign_key "connections_workload_participants", "workload_actions", column: "action_id", on_delete: :cascade
  add_foreign_key "coworkers_puckies", "accounts"
  add_foreign_key "coworkers_puckies", "organizations"
  add_foreign_key "coworkers_runs", "coworkers_puckies", column: "puck_id"
  add_foreign_key "coworkers_runs", "coworkers_runs", column: "proposal_run_id"
  add_foreign_key "crashes_attachments", "crashes_blobs", column: "blob_id"
  add_foreign_key "crashes_attachments", "crashes_blobs", column: ["blob_id", "project_id"], primary_key: ["id", "project_id"]
  add_foreign_key "crashes_attachments", "crashes_reports", column: ["report_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :cascade
  add_foreign_key "crashes_attachments", "projects", on_delete: :cascade
  add_foreign_key "crashes_reports", "projects", on_delete: :cascade
  add_foreign_key "crons_check_ins", "crons_monitors", column: "monitor_id", on_delete: :cascade
  add_foreign_key "crons_monitors", "projects", on_delete: :cascade
  add_foreign_key "crons_monitors", "types_environments", column: "environment_id", on_delete: :nullify
  add_foreign_key "datasets_cells", "datasets_columns", column: "column_id", on_delete: :cascade
  add_foreign_key "datasets_cells", "datasets_rows", column: "row_id", on_delete: :cascade
  add_foreign_key "datasets_columns", "datasets_datasets", column: "dataset_id", on_delete: :cascade
  add_foreign_key "datasets_datasets", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "datasets_datasets", "projects", on_delete: :cascade
  add_foreign_key "datasets_predictions", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "datasets_predictions", "datasets_datasets", column: "dataset_id", on_delete: :cascade
  add_foreign_key "datasets_predictions", "datasets_rows", column: "input_row_id", on_delete: :cascade
  add_foreign_key "datasets_predictions", "datasets_trainings", column: "training_id", on_delete: :nullify
  add_foreign_key "datasets_rows", "datasets_datasets", column: "dataset_id", on_delete: :cascade
  add_foreign_key "datasets_trainings", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "datasets_trainings", "datasets_datasets", column: "dataset_id", on_delete: :cascade
  add_foreign_key "errors_events", "errors_groups", column: "group_id", on_delete: :cascade
  add_foreign_key "errors_events", "projects", on_delete: :cascade
  add_foreign_key "errors_grouping_rules", "projects", on_delete: :cascade
  add_foreign_key "errors_groups", "accounts", column: "assignee_id", on_delete: :nullify
  add_foreign_key "errors_groups", "projects", on_delete: :cascade
  add_foreign_key "errors_groups", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
  add_foreign_key "errors_ingest_payloads", "projects", on_delete: :cascade
  add_foreign_key "errors_symbolications", "crashes_reports", column: ["crash_report_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :cascade
  add_foreign_key "errors_symbolications", "projects", on_delete: :cascade
  add_foreign_key "github_branches", "github_repositories", column: "repository_id"
  add_foreign_key "github_branches", "ticketing_tickets", column: "ticket_id"
  add_foreign_key "github_installations", "organizations"
  add_foreign_key "github_pull_requests", "github_repositories", column: "repository_id"
  add_foreign_key "github_pull_requests", "ticketing_tickets", column: "ticket_id"
  add_foreign_key "github_repositories", "github_installations", column: "installation_id"
  add_foreign_key "github_repositories", "projects"
  add_foreign_key "github_repositories", "types_environments", column: "preview_environment_id"
  add_foreign_key "github_repositories", "types_environments", column: "production_environment_id"
  add_foreign_key "github_repositories", "types_environments", column: "staging_environment_id"
  add_foreign_key "guidance_procedures", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "guidance_procedures", "organizations", on_delete: :cascade
  add_foreign_key "guidance_references", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "guidance_references", "organizations", on_delete: :cascade
  add_foreign_key "helpdesk_messages", "accounts", column: "author_id", on_delete: :nullify
  add_foreign_key "helpdesk_messages", "helpdesk_requests", column: "request_id", on_delete: :cascade
  add_foreign_key "helpdesk_requests", "accounts", column: "discarded_by_id", on_delete: :nullify
  add_foreign_key "helpdesk_requests", "projects"
  add_foreign_key "helpdesk_requests", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
  add_foreign_key "home_deferrals", "accounts", on_delete: :cascade
  add_foreign_key "home_deferrals", "organizations", on_delete: :cascade
  add_foreign_key "ideas_cases", "ideas_ideas", column: "idea_id", on_delete: :cascade
  add_foreign_key "ideas_comments", "accounts", column: "author_id"
  add_foreign_key "ideas_comments", "ideas_ideas", column: "idea_id"
  add_foreign_key "ideas_ideas", "accounts", column: "author_id", on_delete: :nullify
  add_foreign_key "ideas_ideas", "projects", on_delete: :cascade
  add_foreign_key "ideas_ideas", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
  add_foreign_key "ideas_links", "ideas_ideas", column: "source_id", on_delete: :cascade
  add_foreign_key "ideas_links", "ideas_ideas", column: "target_id", on_delete: :cascade
  add_foreign_key "integrations_credentials", "accounts", column: "connected_by_id", on_delete: :nullify
  add_foreign_key "integrations_credentials", "organizations", on_delete: :cascade
  add_foreign_key "knowledge_ask_logs", "accounts", on_delete: :cascade
  add_foreign_key "knowledge_ask_logs", "organizations", on_delete: :cascade
  add_foreign_key "knowledge_attachments", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "knowledge_attachments", "knowledge_pages", column: "page_id", on_delete: :cascade
  add_foreign_key "knowledge_books", "accounts", column: "created_by_id"
  add_foreign_key "knowledge_books", "organizations"
  add_foreign_key "knowledge_pages", "accounts", column: "created_by_id"
  add_foreign_key "knowledge_pages", "accounts", column: "reviewed_by_id"
  add_foreign_key "knowledge_pages", "knowledge_books", column: "book_id", on_delete: :nullify
  add_foreign_key "knowledge_pages", "organizations"
  add_foreign_key "knowledge_sample_questions", "knowledge_pages", on_delete: :nullify
  add_foreign_key "knowledge_sample_questions", "organizations", on_delete: :cascade
  add_foreign_key "knowledge_sample_questions", "projects", on_delete: :cascade
  add_foreign_key "knowledge_versions", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "knowledge_versions", "knowledge_pages", column: "page_id", on_delete: :cascade
  add_foreign_key "knowledge_versions", "organizations", on_delete: :cascade
  add_foreign_key "logs_entries", "projects", on_delete: :cascade
  add_foreign_key "logs_links", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "measurements_points", "measurements_series", column: ["series_id", "project_id"], primary_key: ["id", "project_id"], name: "measurements_points_tenant_identity", on_delete: :cascade
  add_foreign_key "measurements_points", "projects", on_delete: :cascade
  add_foreign_key "measurements_series", "projects", on_delete: :cascade
  add_foreign_key "metrics_groups", "projects", on_delete: :cascade
  add_foreign_key "metrics_groups", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
  add_foreign_key "metrics_samples", "metrics_groups", column: "group_id", on_delete: :cascade
  add_foreign_key "metrics_samples", "projects", on_delete: :cascade
  add_foreign_key "organization_ai_settings", "organizations"
  add_foreign_key "organizations", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "organizations", "accounts", column: "cto_id", on_delete: :nullify
  add_foreign_key "organizations", "accounts", column: "default_assignee_id", on_delete: :nullify
  add_foreign_key "product_categories", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "product_categories", "organizations", on_delete: :cascade
  add_foreign_key "product_categories", "projects_groups", column: "group_id", on_delete: :cascade
  add_foreign_key "product_features", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "product_features", "knowledge_pages", on_delete: :nullify
  add_foreign_key "product_features", "organizations", on_delete: :cascade
  add_foreign_key "product_features", "product_categories", column: "category_id", on_delete: :cascade
  add_foreign_key "projects", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "projects", "accounts", column: "cto_id", on_delete: :nullify
  add_foreign_key "projects", "accounts", column: "default_assignee_id", on_delete: :nullify
  add_foreign_key "projects", "organizations"
  add_foreign_key "projects", "projects_groups", column: "group_id"
  add_foreign_key "projects_coverage_reports", "projects", on_delete: :cascade
  add_foreign_key "projects_documents", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "projects_documents", "projects"
  add_foreign_key "projects_groups", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "projects_groups", "organizations"
  add_foreign_key "projects_milestones", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "projects_milestones", "projects"
  add_foreign_key "projects_moves", "accounts", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "projects_moves", "organizations", column: "destination_organization_id", on_delete: :cascade
  add_foreign_key "projects_moves", "organizations", column: "source_organization_id", on_delete: :cascade
  add_foreign_key "projects_releases", "projects", on_delete: :cascade
  add_foreign_key "projects_source_versions", "projects_sources", column: "source_id", on_delete: :cascade
  add_foreign_key "projects_sources", "projects", on_delete: :cascade
  add_foreign_key "projects_tokens", "accounts", column: "created_by_id"
  add_foreign_key "projects_tokens", "projects"
  add_foreign_key "projects_tokens", "types_environments", column: "environment_id"
  add_foreign_key "replays_sessions", "projects"
  add_foreign_key "saved_views", "accounts", on_delete: :cascade
  add_foreign_key "saved_views", "organizations", on_delete: :cascade
  add_foreign_key "secrets_asset_delegations", "accounts", column: "created_by_id"
  add_foreign_key "secrets_asset_delegations", "projects", on_delete: :cascade
  add_foreign_key "secrets_asset_delegations", "secrets_assets", column: "asset_id", on_delete: :cascade
  add_foreign_key "secrets_asset_events", "accounts", column: "actor_id"
  add_foreign_key "secrets_asset_events", "organizations"
  add_foreign_key "secrets_asset_events", "projects"
  add_foreign_key "secrets_asset_events", "secrets_assets", column: "asset_id", on_delete: :nullify
  add_foreign_key "secrets_asset_events", "types_environments", column: "environment_id"
  add_foreign_key "secrets_asset_versions", "accounts", column: "created_by_id"
  add_foreign_key "secrets_asset_versions", "secrets_assets", column: "asset_id", on_delete: :cascade
  add_foreign_key "secrets_assets", "accounts", column: "created_by_id"
  add_foreign_key "secrets_assets", "organizations"
  add_foreign_key "secrets_assets", "projects"
  add_foreign_key "secrets_assets", "types_environments", column: "environment_id"
  add_foreign_key "secrets_change_requests", "accounts", column: "decided_by_id", on_delete: :nullify
  add_foreign_key "secrets_change_requests", "accounts", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "secrets_change_requests", "organizations", on_delete: :cascade
  add_foreign_key "secrets_change_requests", "projects", on_delete: :cascade
  add_foreign_key "secrets_change_requests", "secrets_versions", column: "source_version_id", on_delete: :nullify
  add_foreign_key "secrets_change_requests", "types_environments", column: "environment_id", on_delete: :cascade
  add_foreign_key "secrets_consolidation_suggestions", "accounts", column: "dismissed_by_id", on_delete: :nullify
  add_foreign_key "secrets_consolidation_suggestions", "accounts", column: "promoted_by_id", on_delete: :nullify
  add_foreign_key "secrets_consolidation_suggestions", "organizations", on_delete: :cascade
  add_foreign_key "secrets_consolidation_suggestions", "secrets_shared_variables", column: "shared_variable_id", on_delete: :nullify
  add_foreign_key "secrets_consolidation_suggestions", "types_environments", column: "environment_id", on_delete: :cascade
  add_foreign_key "secrets_events", "accounts", column: "actor_id", on_delete: :nullify
  add_foreign_key "secrets_events", "organizations"
  add_foreign_key "secrets_events", "projects"
  add_foreign_key "secrets_events", "types_environments", column: "environment_id"
  add_foreign_key "secrets_health_anomalies", "accounts", column: "acknowledged_by_id", on_delete: :nullify
  add_foreign_key "secrets_health_anomalies", "organizations", on_delete: :cascade
  add_foreign_key "secrets_health_anomalies", "projects", on_delete: :cascade
  add_foreign_key "secrets_health_anomalies", "types_environments", column: "environment_id", on_delete: :cascade
  add_foreign_key "secrets_overrides", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "secrets_overrides", "accounts", on_delete: :cascade
  add_foreign_key "secrets_overrides", "organizations", on_delete: :cascade
  add_foreign_key "secrets_overrides", "projects", on_delete: :cascade
  add_foreign_key "secrets_overrides", "types_environments", column: "environment_id", on_delete: :cascade
  add_foreign_key "secrets_personal_asset_events", "accounts", on_delete: :cascade
  add_foreign_key "secrets_personal_asset_events", "organizations", on_delete: :cascade
  add_foreign_key "secrets_personal_asset_events", "secrets_personal_assets", column: "asset_id", on_delete: :nullify
  add_foreign_key "secrets_personal_asset_versions", "secrets_personal_assets", column: "asset_id", on_delete: :cascade
  add_foreign_key "secrets_personal_assets", "accounts", on_delete: :cascade
  add_foreign_key "secrets_personal_assets", "organizations", on_delete: :cascade
  add_foreign_key "secrets_personal_events", "accounts", on_delete: :cascade
  add_foreign_key "secrets_personal_events", "organizations", on_delete: :cascade
  add_foreign_key "secrets_personal_variables", "accounts", on_delete: :cascade
  add_foreign_key "secrets_personal_variables", "organizations", on_delete: :cascade
  add_foreign_key "secrets_personal_versions", "secrets_personal_variables", column: "variable_id", on_delete: :cascade
  add_foreign_key "secrets_provisions", "accounts", column: "created_by_id"
  add_foreign_key "secrets_provisions", "organizations", on_delete: :cascade
  add_foreign_key "secrets_provisions", "projects", column: "destination_project_id", on_delete: :cascade
  add_foreign_key "secrets_provisions", "projects", column: "source_project_id", on_delete: :cascade
  add_foreign_key "secrets_provisions", "projects_tokens", column: "token_id", on_delete: :cascade
  add_foreign_key "secrets_provisions", "secrets_variables", column: "secret_variable_id", on_delete: :cascade
  add_foreign_key "secrets_provisions", "types_environments", column: "destination_environment_id", on_delete: :restrict
  add_foreign_key "secrets_provisions", "types_environments", column: "source_environment_id", on_delete: :restrict
  add_foreign_key "secrets_shared_delegations", "projects", on_delete: :cascade
  add_foreign_key "secrets_shared_delegations", "secrets_shared_values", column: "shared_value_id", on_delete: :cascade
  add_foreign_key "secrets_shared_events", "accounts", column: "actor_id", on_delete: :nullify
  add_foreign_key "secrets_shared_events", "organizations", on_delete: :cascade
  add_foreign_key "secrets_shared_events", "projects", on_delete: :nullify
  add_foreign_key "secrets_shared_events", "secrets_shared_variables", column: "shared_variable_id", on_delete: :nullify
  add_foreign_key "secrets_shared_events", "types_environments", column: "environment_id", on_delete: :nullify
  add_foreign_key "secrets_shared_values", "secrets_shared_variables", column: "shared_variable_id", on_delete: :cascade
  add_foreign_key "secrets_shared_values", "types_environments", column: "environment_id", on_delete: :restrict
  add_foreign_key "secrets_shared_variables", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "secrets_shared_variables", "organizations", on_delete: :cascade
  add_foreign_key "secrets_shared_versions", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "secrets_shared_versions", "secrets_shared_values", column: "shared_value_id", on_delete: :cascade
  add_foreign_key "secrets_variables", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "secrets_variables", "organizations"
  add_foreign_key "secrets_variables", "projects"
  add_foreign_key "secrets_variables", "types_environments", column: "environment_id"
  add_foreign_key "secrets_versions", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "secrets_versions", "secrets_variables", column: "secret_variable_id", on_delete: :cascade
  add_foreign_key "seo_audits", "seo_sites", column: "site_id", on_delete: :cascade
  add_foreign_key "seo_issues", "seo_pages", column: "page_id", on_delete: :nullify
  add_foreign_key "seo_issues", "seo_sites", column: "site_id", on_delete: :cascade
  add_foreign_key "seo_issues", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
  add_foreign_key "seo_lab_runs", "seo_sites", column: "site_id", on_delete: :cascade
  add_foreign_key "seo_pages", "seo_sites", column: "site_id", on_delete: :cascade
  add_foreign_key "seo_sites", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "seo_sites", "projects", on_delete: :cascade
  add_foreign_key "seo_sites", "types_environments", column: "environment_id", on_delete: :restrict
  add_foreign_key "servers_actions", "accounts", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "servers_actions", "organizations"
  add_foreign_key "servers_actions", "servers_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "servers_container_samples", "servers_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "servers_enrollment_tokens", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "servers_enrollment_tokens", "organizations", on_delete: :cascade
  add_foreign_key "servers_host_tokens", "servers_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "servers_hosts", "organizations", on_delete: :cascade
  add_foreign_key "servers_hosts", "servers_enrollment_tokens", column: "enrollment_token_id", on_delete: :nullify
  add_foreign_key "servers_journal_entries", "organizations", on_delete: :cascade
  add_foreign_key "servers_journal_entries", "servers_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "servers_sample_rollups", "servers_hosts", column: "host_id"
  add_foreign_key "servers_samples", "organizations", on_delete: :cascade
  add_foreign_key "servers_samples", "servers_hosts", column: "host_id", on_delete: :cascade
  add_foreign_key "session_health_aggregates", "projects", on_delete: :cascade
  add_foreign_key "session_health_sessions", "projects", on_delete: :cascade
  add_foreign_key "support_requests", "accounts"
  add_foreign_key "support_requests", "accounts", column: "handled_by_id"
  add_foreign_key "support_requests", "organizations"
  add_foreign_key "teams_teams", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "teams_teams", "accounts", column: "default_assignee_id", on_delete: :nullify
  add_foreign_key "teams_teams", "organizations", on_delete: :cascade
  add_foreign_key "ticketing_answers", "accounts", column: "author_id"
  add_foreign_key "ticketing_answers", "ticketing_questions", column: "question_id", on_delete: :cascade
  add_foreign_key "ticketing_comments", "accounts", column: "author_id"
  add_foreign_key "ticketing_comments", "ticketing_tickets", column: "ticket_id"
  add_foreign_key "ticketing_conditions", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "ticketing_events", "accounts", column: "actor_id", on_delete: :nullify
  add_foreign_key "ticketing_events", "accounts", column: "true_actor_id", on_delete: :nullify
  add_foreign_key "ticketing_events", "organizations"
  add_foreign_key "ticketing_events", "ticketing_tickets", column: "ticket_id"
  add_foreign_key "ticketing_questions", "accounts", column: "author_id"
  add_foreign_key "ticketing_questions", "accounts", column: "closed_by_id", on_delete: :nullify
  add_foreign_key "ticketing_questions", "agents_clarifications", column: "round_id", on_delete: :nullify
  add_foreign_key "ticketing_questions", "ticketing_answers", column: "resolved_answer_id", on_delete: :nullify
  add_foreign_key "ticketing_questions", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "ticketing_reports", "accounts", column: "author_id", on_delete: :nullify
  add_foreign_key "ticketing_reports", "ticketing_comments", column: "source_comment_id", on_delete: :nullify
  add_foreign_key "ticketing_reports", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "ticketing_scenarios", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "ticketing_subscriptions", "accounts", on_delete: :cascade
  add_foreign_key "ticketing_subscriptions", "organizations", on_delete: :cascade
  add_foreign_key "ticketing_subscriptions", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "ticketing_tickets", "accounts", column: "agent_eligibility_decided_by_id", on_delete: :nullify
  add_foreign_key "ticketing_tickets", "accounts", column: "assignee_id"
  add_foreign_key "ticketing_tickets", "accounts", column: "reporter_id"
  add_foreign_key "ticketing_tickets", "accounts", column: "reviewer_id", on_delete: :nullify
  add_foreign_key "ticketing_tickets", "projects"
  add_foreign_key "ticketing_tickets", "projects_milestones", column: "milestone_id", on_delete: :nullify
  add_foreign_key "ticketing_tickets", "ticketing_tickets", column: "parent_id", on_delete: :nullify
  add_foreign_key "ticketing_tickets", "types_ticket_priorities", column: "priority_id"
  add_foreign_key "ticketing_tickets", "types_ticket_statuses", column: "status_id"
  add_foreign_key "ticketing_work_context_snapshots", "accounts", column: "actor_id", on_delete: :nullify
  add_foreign_key "ticketing_work_context_snapshots", "organizations", on_delete: :cascade
  add_foreign_key "ticketing_work_context_snapshots", "ticketing_tickets", column: "ticket_id", on_delete: :cascade
  add_foreign_key "todos_items", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
  add_foreign_key "todos_items", "todos_lists", column: "list_id", on_delete: :cascade
  add_foreign_key "todos_lists", "accounts", on_delete: :cascade
  add_foreign_key "todos_lists", "organizations", on_delete: :cascade
  add_foreign_key "todos_shares", "accounts", on_delete: :cascade
  add_foreign_key "todos_shares", "todos_lists", column: "list_id", on_delete: :cascade
  add_foreign_key "traces", "projects", on_delete: :cascade
  add_foreign_key "traces_spans", "projects", on_delete: :cascade
  add_foreign_key "traces_spans", "traces", column: ["trace_record_id", "project_id", "trace_id"], primary_key: ["id", "project_id", "trace_id"], name: "traces_spans_tenant_identity", on_delete: :cascade
  add_foreign_key "types_environments", "accounts", column: "created_by_id"
  add_foreign_key "types_environments", "organizations"
  add_foreign_key "types_feature_statuses", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "types_feature_statuses", "organizations", on_delete: :cascade
  add_foreign_key "types_platforms", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "types_platforms", "organizations"
  add_foreign_key "types_ticket_priorities", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "types_ticket_priorities", "organizations"
  add_foreign_key "types_ticket_statuses", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "types_ticket_statuses", "organizations"
  add_foreign_key "uptime_announcements", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "uptime_announcements", "uptime_monitors", column: "monitor_id", on_delete: :cascade
  add_foreign_key "uptime_checks", "uptime_monitors", column: "monitor_id", on_delete: :cascade
  add_foreign_key "uptime_groups", "accounts", column: "created_by_id"
  add_foreign_key "uptime_groups", "organizations"
  add_foreign_key "uptime_incident_updates", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "uptime_incident_updates", "uptime_incidents", column: "incident_id", on_delete: :cascade
  add_foreign_key "uptime_incidents", "uptime_incidents", column: "parent_id", on_delete: :nullify
  add_foreign_key "uptime_incidents", "uptime_monitors", column: "monitor_id", on_delete: :cascade
  add_foreign_key "uptime_monitors", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "uptime_monitors", "projects", on_delete: :cascade
  add_foreign_key "uptime_monitors", "types_environments", column: "environment_id", on_delete: :restrict
  add_foreign_key "uptime_monitors", "uptime_groups", column: "group_id", on_delete: :nullify
  add_foreign_key "usage_reporters", "projects", on_delete: :cascade
  add_foreign_key "usage_symbols", "projects", on_delete: :cascade
  add_foreign_key "vulnerabilities_findings", "projects", on_delete: :cascade
  add_foreign_key "vulnerabilities_findings", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
  add_foreign_key "vulnerabilities_findings", "vulnerabilities_advisories", column: "advisory_id", on_delete: :cascade
  add_foreign_key "vulnerabilities_findings", "vulnerabilities_packages", column: "package_id", on_delete: :cascade
  add_foreign_key "vulnerabilities_manifests", "projects", on_delete: :cascade
  add_foreign_key "vulnerabilities_packages", "vulnerabilities_manifests", column: "manifest_id", on_delete: :cascade
  add_foreign_key "vulnerabilities_runtime_statuses", "projects", on_delete: :cascade
  add_foreign_key "workload_actions", "accounts", column: "created_by_id", on_delete: :nullify
  add_foreign_key "workload_actions", "teams_teams", column: "team_id", on_delete: :cascade
  add_foreign_key "workload_actions", "ticketing_tickets", column: "ticket_id", on_delete: :nullify
end
