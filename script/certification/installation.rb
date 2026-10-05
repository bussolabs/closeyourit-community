# frozen_string_literal: true

require_relative "bootstrap_support"

module Certification
  module Installation
    def create_installation_sessions
      org = organization
      Types::InstallDefaults.call(organization: org)
      project, other = %w[CERT OTHR].map { |key| org.projects.find_by!(key: key) }
      contexts = { "reader" => [ project, false ], "manager" => [ project, true ], "other" => [ other, true ] }.to_h do |label, (target, manage)|
        email = "installation-#{label}-#{@run_id}@certification.invalid"
        raise "Installation session already exists" if Accounts::Account.exists?(email: email)
        password = BootstrapSupport.password
        account = Accounts::Account.create!(name: "Installation certification #{label}", email: email,
          handle: "install_#{label}_#{@run_id}", password: password)
        Connections::Membership.create!(organization: org, account: account, role: :member)
        Connections::ProjectMembership.create!(project: target, account: account)
        if manage
          result = Authorization::SetAccountPermissions.call(organization: org, account: account, allow_keys: [ "tokens.manage" ])
          raise "Installation permission setup failed" unless result.ok?
        end
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! "127.0.0.1"
        session.post "/login", params: { email: email, password: password }
        raise "Installation login failed" unless session.response.status == 302
        [ label, { account_id: account.id, project_id: target.id, cookies: session.cookies.to_hash } ]
      end
      { sessions: contexts, project_id: project.id, other_project_id: other.id }
    end

    def cleanup_installation_sessions
      accounts = organization.accounts.where(email: %w[reader manager other].map { |label| "installation-#{label}-#{@run_id}@certification.invalid" })
      sessions = Accounts::Session.where(account_id: accounts.select(:id))
      count = sessions.count
      sessions.destroy_all
      { revoked_sessions: count, remaining_sessions: sessions.count }
    end

    def inspect_installation_receipt(input)
      project = organization.projects.find(input.fetch("project_id"))
      signal = input.fetch("signal")
      if signal == "errors"
        id = installation_identifier(input, "event_id", 32)
        row = project.error_events.where(event_id: id).order(:created_at, :id).limit(1).pick(:event_id, :created_at, :environment, :release)
        record = row && { project_id: project.id, event_id: row[0], created_at: row[1].utc.iso8601(6), environment: row[2], release: row[3] }
      elsif signal == "traces"
        trace, span = installation_identifier(input, "trace_id", 32), installation_identifier(input, "span_id", 16)
        row = Traces::Span.where(project_id: project.id, trace_id: trace, span_id: span).limit(1).pick(:first_received_at,
          Arel.sql("(SELECT item->'value'->>'stringValue' FROM jsonb_array_elements(resource->'attributes') item WHERE item->>'key' = 'deployment.environment.name' LIMIT 1)"),
          Arel.sql("(SELECT item->'value'->>'stringValue' FROM jsonb_array_elements(resource->'attributes') item WHERE item->>'key' = 'service.version' LIMIT 1)"))
        record = row && { project_id: project.id, trace_id: trace, span_id: span, first_received_at: row[0].utc.iso8601(6), environment: row[1], release: row[2] }
      else
        raise "Unknown installation signal"
      end
      { record: record }
    end

    private

    def installation_identifier(input, key, length)
      value = input.fetch(key)
      raise "Invalid installation identifier" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{#{length}}\z/) && value != "0" * length
      value
    end
  end
end
