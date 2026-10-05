# frozen_string_literal: true

require "json"
require_relative "runtime"
require_relative "installation"
output = IO.for_fd(3, "w")
raise "Certification output must be an anonymous pipe" unless output.stat.pipe?

run_id = Certification::Runtime.boot!
input = JSON.parse($stdin.read(4096))
raise "Certification run mismatch" unless input.fetch("run_id") == run_id

module Certification
  class Bootstrap
    include Installation
    def initialize(run_id)
      @run_id = run_id
    end

    def create
      raise "Certification run already exists" if Organizations::Organization.exists?(slug: slug)

      Ops::Partitions::Ensure.call
      ApplicationRecord.transaction do
        org = Organizations::Organization.create!(name: "Certification #{@run_id}", slug:)
        environment = org.environments.create!(code: "certification", label: "Certification", color: "teal")
        project, other = %w[CERT OTHR].map do |key|
          org.projects.create!(name: "Certification #{key}", key:).tap { |item| item.environments << environment }
        end
        ingest = issue(project, environment, [ "ingest" ])
        read = issue(project, environment, [ "read" ])
        report_manage = issue(project, environment, %w[read ingest])
        other_ingest = issue(other, environment, [ "ingest" ])
        other_read = issue(other, environment, [ "read" ])
        { project_id: project.id, other_project_id: other.id, environment: environment.code,
          sentry_project_id: project.reload.sentry_project_id.to_s,
          other_sentry_project_id: other.reload.sentry_project_id.to_s,
          ingest_token: ingest.fetch(:secret), read_token: read.fetch(:secret),
          report_manage_token: report_manage.fetch(:secret),
          other_ingest_token: other_ingest.fetch(:secret), other_public_key: other_ingest.fetch(:token).public_key,
          other_read_token: other_read.fetch(:secret), public_key: ingest.fetch(:token).public_key,
          read_public_key: read.fetch(:token).public_key }.merge(artifact_credentials(org, project, other))
      end
    end

    def inspect_run
      project = organization.projects.find_by!(key: "CERT")
      jobs = SolidQueue::Job.where(class_name: %w[Errors::IngestJob Metrics::IngestJob Logs::IngestJob Usage::IngestJob])
      unfinished = jobs.where(finished_at: nil).count
      failed = SolidQueue::FailedExecution.where(job_id: jobs.select(:id)).count
      { worker: { completed: jobs.exists? && unfinished.zero? && failed.zero?, processor: "solid_queue",
                  finished_jobs: jobs.where.not(finished_at: nil).count, unfinished_jobs: unfinished },
        persistence: { errors: project.error_events.count, performance: project.metric_samples.count,
                       logs: project.logs_entries.count, usage: ::Usage::Symbol.where(project_id: project.id).count },
        failed_jobs: failed, all_failed_jobs: SolidQueue::FailedExecution.count,
        diagnostics: Diagnostics.read(Rails.root.join("tmp/certification", @run_id, "diagnostics.jsonl"), project_id: project.id) }
    end

    def cleanup
      org = Organizations::Organization.find_by(slug:)
      return { revoked: 0 } unless org

      # Preserve evidence in this isolated database; only expire this run's credentials.
      tokens = Projects::Token.where(project_id: org.projects.select(:id), revoked_at: nil)
      users = Accounts::ApiToken.where(organization_id: org.id, name: "Certification #{@run_id}", revoked_at: nil)
      { revoked: tokens.update_all(revoked_at: Time.current) + users.update_all(revoked_at: Time.current) }
    end

    def measurement_credentials
      org = organization
      project = org.projects.find_by!(key: "CERT")
      account = Accounts::Account.create!(name: "Measurement certification", email: "measurement-#{@run_id}@certification.invalid",
        handle: "measurement_#{@run_id}", password: BootstrapSupport.password)
      Connections::Membership.create!(organization: org, account: account, role: :member)
      Connections::ProjectMembership.create!(project: project, account: account)
      grant = Authorization::SetAccountPermissions.call(organization: org, account: account, allow_keys: [ "alerts.manage" ])
      raise "Certification alert permission setup failed" unless grant.ok?
      Alerting::Preference.create!(organization: org, account: account, email_enabled: false, telegram_enabled: false)
      token = Accounts::ApiTokens::Issue.call(account: account, organization: org, name: "Certification #{@run_id}", expires_at: 1.hour.from_now)
      raise "Certification alert credential creation failed" unless token.ok?
      { measurement_token: token.value.fetch(:secret), recipient_id: account.id }
    end

    def evaluate_measurements(ids)
      project = organization.projects.find_by!(key: "CERT")
      raise "Invalid certification rule selection" unless ids.is_a?(Array) && ids.size.between?(1, 10)
      rules = organization.alerting_rules.where(project_id: project.id, id: ids, event_type: :measurement_threshold)
      raise "Certification rule scope mismatch" unless rules.count == ids.uniq.size
      ending = Time.at(((Time.current - Alerting::Measurements::Evaluate::GRACE).to_i / 60) * 60).utc.iso8601
      rules.each { |rule| Alerting::Measurements::EvaluateJob.perform_later(rule_id: rule.id, window_end: ending, config_digest: Alerting::Measurements::Configuration.digest(rule)) }
      { window_end: ending, enqueued: rules.count }
    end

    def inspect_measurements
      project = organization.projects.find_by!(key: "CERT")
      rules = organization.alerting_rules.where(project_id: project.id, event_type: :measurement_threshold)
      jobs = SolidQueue::Job.where(class_name: %w[Alerting::Measurements::EvaluateJob Alerting::Measurements::DispatchJob])
      { worker: { unfinished_jobs: jobs.where(finished_at: nil).count, failed_jobs: SolidQueue::FailedExecution.where(job_id: jobs.select(:id)).count },
        rules: rules.order(:id).limit(100).map { |rule| rule.attributes.slice("id", "measurement_series_id", "measurement_state") },
        evaluations: Alerting::Evaluation.where(rule_id: rules.select(:id)).order(:created_at).limit(200).map { |row| row.attributes.slice("id", "rule_id", "series_id", "status", "dispatch_state", "result").merge("window_end_ns" => row.window_end_ns.to_i.to_s) },
        notifications: Alerting::Notification.where(organization_id: organization.id, event_type: :measurement_threshold).order(:created_at).limit(200).map { |row| row.attributes.slice("id", "rule_id", "project_id", "account_id", "via", "status") } }
    end

    def retention
      require "active_support/testing/time_helpers"
      extend ActiveSupport::Testing::TimeHelpers
      project = organization.projects.find_by!(key: "CERT")
      before = inspect_run.fetch(:persistence)
      project.update!(errors_retention_days: 1, performance_retention_days: 1, logs_retention_days: 1)
      now = Time.current
      travel_to(now + 2.days) do
        Errors::PruneEventsJob.perform_now
        Metrics::PruneSamplesJob.perform_now
        Logs::PruneJob.perform_now
      end
      travel_to(now + 401.days) { ::Usage::PruneJob.perform_now }
      { before:, after: inspect_run.fetch(:persistence), processor: "retention_jobs" }
    end

    private

    def artifact_credentials(org, project, other)
      [ [ "artifact_token", project, true ], [ "artifact_viewer_token", project, false ], [ "artifact_other_token", other, true ] ].to_h do |key, scoped, manage|
        result = Accounts::Service::Create.call(organization: org, name: "Certification #{key}", handle: "cert_#{@run_id}_#{key.delete_prefix('artifact_')}", project_ids: [ scoped.id ])
        raise "Certification account creation failed" unless result.ok?
        account = result.value
        if manage
          grants = Authorization::SetAccountPermissions.call(organization: org, account: account, allow_keys: [ "artifacts.manage" ])
          raise "Certification permission setup failed" unless grants.ok?
        end
        issued = Accounts::ApiTokens::Issue.call(account: account, organization: org, name: "Certification #{@run_id}", expires_at: 1.hour.from_now)
        raise "Certification account credential creation failed" unless issued.ok?
        [ key.to_sym, issued.value.fetch(:secret) ]
      end
    end

    def slug = "certification-#{@run_id}"

    def organization = Organizations::Organization.find_by!(slug:)

    def issue(project, environment, scopes)
      result = Projects::Tokens::Issue.call(project:, environment:, scopes:, name: "Certification #{@run_id}",
                                             host: "localhost", expires_at: 1.hour.from_now)
      raise "Certification credential creation failed" unless result.ok?

      result.value
    end
  end
end

begin
  bootstrap = Certification::Bootstrap.new(run_id)
  result = case input.fetch("action")
  when "create" then bootstrap.create
  when "create_installation_sessions" then bootstrap.create_installation_sessions
  when "cleanup_installation_sessions" then bootstrap.cleanup_installation_sessions
  when "inspect_installation_receipt" then bootstrap.inspect_installation_receipt(input)
  when "inspect" then bootstrap.inspect_run
  when "cleanup" then bootstrap.cleanup
  when "retention" then bootstrap.retention
  when "measurement_credentials" then bootstrap.measurement_credentials
  when "evaluate_measurements" then bootstrap.evaluate_measurements(input.fetch("rule_ids"))
  when "inspect_measurements" then bootstrap.inspect_measurements
  else raise "Unknown certification action"
  end
  output.write(JSON.generate(result))
rescue StandardError => error
  output.write(JSON.generate(Certification::BootstrapSupport.failure(error, input["action"])))
  exit 1
ensure
  output.close
end
