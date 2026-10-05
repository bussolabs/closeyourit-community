# frozen_string_literal: true

class RebuildAuthorizedAgents < ActiveRecord::Migration[8.1]
  COMMANDS = {
    "/closeyourit-triage" => { workflow_type: 0, kind: 0, sandbox: nil, runtime: "claude",
                               description: "Analizza ticket e codebase senza produrre effetti.",
                               instruction: "Valuta se il ticket è lavorabile usando ticket, commenti e codebase. " \
                                            "Se manca una decisione essenziale, formula da una a tre domande brevi " \
                                            "in italiano semplice; non modificare ticket, file o sistemi esterni." },
    "/closeyourit-planner" => { workflow_type: 1, kind: 0, sandbox: nil, runtime: "claude",
                                description: "Prepara un piano immutabile per l'approvazione del CTO.",
                                instruction: "Prepara un piano concreto basato sullo snapshot del ticket e sulla codebase. " \
                                             "Includi passi, interfacce, test e rischi; se esistono un piano precedente " \
                                             "e feedback CTO, trattali come requisiti obbligatori. Non modificare file." },
    "/closeyourit-autopilot" => { workflow_type: 2, kind: 2, sandbox: "workspace-write", runtime: "codex",
                                  description: "Implementa il piano approvato e porta il ticket in revisione.",
                                  instruction: "Implementa esclusivamente il piano approvato nel worktree autorizzato. " \
                                               "Esegui i test pertinenti, non ampliare lo scope, non fare push o deploy " \
                                               "e riepiloga modifiche e verifiche eseguite." }
  }.freeze

  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  def up
    # Rails registra la versione una sola volta, ma il guard rende sicura anche una riesecuzione
    # esplicita della migrazione: l'assenza del vecchio campo `run` certifica che il rebuild è già avvenuto.
    return unless column_exists?(:agents_agents, :run)

    require "bcrypt"

    transaction do
      scopes = concrete_project_scopes
      execute "DELETE FROM agents_runs"
      execute "DELETE FROM connections_agent_targets"
      execute "DELETE FROM agents_agents"

      MigrationOrganization.find_each do |organization|
        project_ids = scopes.fetch(organization.id, [])
        create_organization_catalog(organization, project_ids, enabled: repositories?(project_ids))
      end

      change_column_null :agents_agents, :command_id, false
      change_column_null :agents_agents, :service_account_id, false
      remove_column :agents_agents, :run, :text
      remove_column :agents_agents, :on_failure, :jsonb
    end
  end

  def down
    add_column :agents_agents, :run, :text
    add_column :agents_agents, :on_failure, :jsonb
    change_column_null :agents_agents, :command_id, true
    change_column_null :agents_agents, :service_account_id, true
    raise ActiveRecord::IrreversibleMigration, "Le definizioni e le run legacy sono eliminate intenzionalmente"
  end

  private

  def concrete_project_scopes
    direct = select_rows(<<~SQL.squish)
      SELECT a.organization_id, t.project_id
      FROM agents_agents a
      JOIN connections_agent_targets t ON t.agent_id = a.id
      WHERE t.project_id IS NOT NULL
    SQL
    grouped = select_rows(<<~SQL.squish)
      SELECT a.organization_id, p.id
      FROM agents_agents a
      JOIN connections_agent_targets t ON t.agent_id = a.id
      JOIN projects p ON p.group_id = t.group_id
      WHERE t.group_id IS NOT NULL
    SQL
    (direct + grouped).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(organization_id, project_id), result|
      result[organization_id] << project_id unless result[organization_id].include?(project_id)
    end
  end

  def repositories?(project_ids)
    return false if project_ids.empty?

    select_value("SELECT COUNT(*) FROM github_repositories WHERE project_id IN (#{quoted_ids(project_ids)})").to_i.positive?
  end

  def create_organization_catalog(organization, project_ids, enabled:)
    now = Time.current
    COMMANDS.each do |key, config|
      command_id = insert_command(organization.id, key, config, now)
      project_ids.each { |project_id| insert_command_project(command_id, project_id, now) }
      insert_instruction(command_id, config.fetch(:instruction), now)
      service_account_id = insert_service_account(organization.id, key, now)
      agent_id = insert_agent(organization.id, command_id, service_account_id, key, config, enabled, now)
      project_ids.each do |project_id|
        insert_agent_target(agent_id, project_id, now)
        insert_project_membership(service_account_id, project_id, now)
      end
    end
  end

  def insert_command(organization_id, key, config, now)
    id = SecureRandom.uuid
    execute <<~SQL.squish
      INSERT INTO agents_commands
        (id, organization_id, key, description, workflow_type, allowed_runtimes, enabled, created_at, updated_at)
      VALUES
        (#{quote(id)}, #{quote(organization_id)}, #{quote(key)}, #{quote(config.fetch(:description))},
         #{config.fetch(:workflow_type)}, #{quote([ config.fetch(:runtime) ].to_json)}::jsonb, TRUE,
         #{quote(now)}, #{quote(now)})
    SQL
    id
  end

  def insert_command_project(command_id, project_id, now)
    execute <<~SQL.squish
      INSERT INTO connections_agent_command_projects (id, command_id, project_id, created_at, updated_at)
      VALUES (#{quote(SecureRandom.uuid)}, #{quote(command_id)}, #{quote(project_id)}, #{quote(now)}, #{quote(now)})
    SQL
  end

  def insert_instruction(command_id, body, now)
    execute <<~SQL.squish
      INSERT INTO agents_instructions (id, command_id, version, body, digest, created_at, updated_at)
      VALUES (#{quote(SecureRandom.uuid)}, #{quote(command_id)}, 1, #{quote(body)},
              #{quote(Digest::SHA256.hexdigest(body))}, #{quote(now)}, #{quote(now)})
    SQL
  end

  def insert_service_account(organization_id, key, now)
    id = SecureRandom.uuid
    suffix = "#{organization_id.to_s.delete('-').first(8)}-#{key.split('-').last}"
    digest = BCrypt::Password.create(SecureRandom.hex(32)).to_s
    execute <<~SQL.squish
      INSERT INTO accounts (id, email, password_digest, name, handle, kind, god, preferences, created_at, updated_at)
      VALUES (#{quote(id)}, #{quote("service+#{suffix}@org.cyi.local")}, #{quote(digest)}, #{quote(key)},
              #{quote("cyi_#{suffix}".first(30))}, 1, FALSE, '{}'::jsonb, #{quote(now)}, #{quote(now)})
    SQL
    execute <<~SQL.squish
      INSERT INTO connections_memberships
        (id, account_id, organization_id, role, secret_environment_codes, created_at, updated_at)
      VALUES (#{quote(SecureRandom.uuid)}, #{quote(id)}, #{quote(organization_id)}, 0, '[]'::jsonb,
              #{quote(now)}, #{quote(now)})
    SQL
    id
  end

  def insert_agent(organization_id, command_id, service_account_id, key, config, enabled, now)
    id = SecureRandom.uuid
    allowed_tools = config.fetch(:kind).zero? ? %w[Read Glob Grep] : []
    execute <<~SQL.squish
      INSERT INTO agents_agents
        (id, organization_id, command_id, service_account_id, slug, name, description, kind, run, schedule,
         timeout_seconds, permission_mode, allowed_tools, model, enabled, catch_up, ticket_queue_enabled,
         sandbox, created_at, updated_at)
      VALUES
        (#{quote(id)}, #{quote(organization_id)}, #{quote(command_id)}, #{quote(service_account_id)},
         #{quote(key.delete_prefix('/'))}, #{quote(key)}, #{quote(config.fetch(:description))}, #{config.fetch(:kind)},
         #{quote(key)}, 'every 1m', 3600, #{config.fetch(:kind).zero? ? quote("plan") : "NULL"},
         #{quote(allowed_tools.to_json)}::jsonb, NULL,
         #{enabled ? "TRUE" : "FALSE"}, FALSE, TRUE, #{quote(config[:sandbox])}, #{quote(now)}, #{quote(now)})
    SQL
    id
  end

  def insert_agent_target(agent_id, project_id, now)
    execute <<~SQL.squish
      INSERT INTO connections_agent_targets (id, agent_id, project_id, created_at, updated_at)
      VALUES (#{quote(SecureRandom.uuid)}, #{quote(agent_id)}, #{quote(project_id)}, #{quote(now)}, #{quote(now)})
    SQL
  end

  def insert_project_membership(account_id, project_id, now)
    execute <<~SQL.squish
      INSERT INTO connections_project_memberships (id, account_id, project_id, created_at, updated_at)
      VALUES (#{quote(SecureRandom.uuid)}, #{quote(account_id)}, #{quote(project_id)}, #{quote(now)}, #{quote(now)})
      ON CONFLICT DO NOTHING
    SQL
  end

  def quoted_ids(ids) = ids.map { |id| quote(id) }.join(",")
end
