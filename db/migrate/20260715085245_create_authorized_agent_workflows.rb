# frozen_string_literal: true

class CreateAuthorizedAgentWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_commands, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :key, null: false
      t.text :description, null: false
      t.integer :workflow_type, null: false
      t.jsonb :allowed_runtimes, null: false, default: []
      t.boolean :enabled, null: false, default: true
      t.timestamps

      t.index %i[organization_id key], unique: true
    end

    create_table :connections_agent_command_projects, id: :uuid do |t|
      t.references :command, type: :uuid, null: false,
                             foreign_key: { to_table: :agents_commands, on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps

      t.index %i[command_id project_id], unique: true, name: "index_agent_command_projects_unique"
    end

    create_table :agents_instructions, id: :uuid do |t|
      t.references :command, type: :uuid, null: false,
                             foreign_key: { to_table: :agents_commands, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.integer :version, null: false
      t.text :body, null: false
      t.string :digest, null: false
      t.timestamps

      t.index %i[command_id version], unique: true
      t.index :digest
    end

    add_reference :agents_agents, :command, type: :uuid, null: true,
                   foreign_key: { to_table: :agents_commands, on_delete: :restrict }
    add_reference :agents_agents, :service_account, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :restrict }

    create_table :agents_workflows, id: :uuid do |t|
      t.references :ticket, type: :uuid, null: false, index: { unique: true },
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :triage_by_agent, type: :uuid, null: true,
                                      foreign_key: { to_table: :agents_agents, on_delete: :nullify }
      t.references :planned_by_agent, type: :uuid, null: true,
                                       foreign_key: { to_table: :agents_agents, on_delete: :nullify }
      t.references :autopilot_by_agent, type: :uuid, null: true,
                                         foreign_key: { to_table: :agents_agents, on_delete: :nullify }
      t.references :approved_by, type: :uuid, null: true,
                                 foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :cancelled_by, type: :uuid, null: true,
                                  foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.datetime :triage_requested_at
      t.datetime :triage_started_at
      t.datetime :triaged_at
      t.datetime :planned_at
      t.datetime :approved_at
      t.datetime :autopilot_started_at
      t.datetime :completed_at
      t.datetime :cancelled_at
      t.text :cancellation_reason
      t.string :ticket_snapshot_digest
      t.integer :ticket_snapshot_version, null: false, default: 1
      t.timestamps
    end

    create_table :agents_attempts, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :workflow, type: :uuid, null: false,
                              foreign_key: { to_table: :agents_workflows, on_delete: :cascade }
      t.references :command, type: :uuid, null: false,
                             foreign_key: { to_table: :agents_commands, on_delete: :restrict }
      t.references :instruction, type: :uuid, null: false,
                                 foreign_key: { to_table: :agents_instructions, on_delete: :restrict }
      t.references :agent, type: :uuid, null: false,
                           foreign_key: { to_table: :agents_agents, on_delete: :restrict }
      t.references :host, type: :uuid, null: false,
                          foreign_key: { to_table: :agents_hosts, on_delete: :restrict }
      t.references :run, type: :uuid, null: true,
                         foreign_key: { to_table: :agents_runs, on_delete: :nullify }
      t.string :phase, null: false
      t.string :runtime, null: false
      t.integer :instruction_version, null: false
      t.string :instruction_digest, null: false
      t.string :idempotency_key, null: false
      t.integer :status, null: false, default: 0
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.jsonb :result, null: false, default: {}
      t.string :reviewer_runtime
      t.integer :review_status
      t.jsonb :review, null: false, default: {}
      t.integer :review_cycles, null: false, default: 0
      t.timestamps

      t.index %i[organization_id idempotency_key], unique: true, name: "index_agent_attempts_idempotency"
      t.index %i[workflow_id created_at]
    end

    create_table :agents_clarifications, id: :uuid do |t|
      t.references :workflow, type: :uuid, null: false,
                              foreign_key: { to_table: :agents_workflows, on_delete: :cascade }
      t.references :attempt, type: :uuid, null: false,
                             foreign_key: { to_table: :agents_attempts, on_delete: :restrict }
      t.references :question_comment, type: :uuid, null: true,
                                     foreign_key: { to_table: :ticketing_comments, on_delete: :nullify }
      t.references :response_comment, type: :uuid, null: true,
                                     foreign_key: { to_table: :ticketing_comments, on_delete: :nullify }
      t.jsonb :questions, null: false, default: []
      t.text :response_snapshot
      t.datetime :answered_at
      t.timestamps
    end

    create_table :agents_plans, id: :uuid do |t|
      t.references :workflow, type: :uuid, null: false,
                              foreign_key: { to_table: :agents_workflows, on_delete: :cascade }
      t.references :attempt, type: :uuid, null: false,
                             foreign_key: { to_table: :agents_attempts, on_delete: :restrict }
      t.references :approved_by, type: :uuid, null: true,
                                 foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.integer :version, null: false
      t.text :summary, null: false
      t.jsonb :steps, null: false, default: []
      t.jsonb :interfaces, null: false, default: []
      t.jsonb :tests, null: false, default: []
      t.jsonb :risks, null: false, default: []
      t.string :ticket_snapshot_digest, null: false
      t.text :change_request
      t.datetime :approved_at
      t.timestamps

      t.index %i[workflow_id version], unique: true
    end

    add_reference :organizations, :cto, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
    add_reference :projects, :cto, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
