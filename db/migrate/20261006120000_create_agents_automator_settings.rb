# frozen_string_literal: true

# The organization chooses once who works and who reviews (CYAU-227). A machine with no choice of its own
# follows it: both engine columns null. Existing machines keep their values as their own choice.
class CreateAgentsAutomatorSettings < ActiveRecord::Migration[8.1]
  def up
    create_table :agents_automator_settings, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, index: { unique: true },
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.string :work_engine, null: false, default: "claude"
      t.string :reviewer, null: false, default: "codex"
      t.timestamps
      t.check_constraint "work_engine IN ('claude', 'codex')", name: "agents_automator_settings_work_engine_valid"
      t.check_constraint "reviewer IN ('claude', 'codex')", name: "agents_automator_settings_reviewer_valid"
    end

    change_column_null :agents_hosts, :work_engine, true
    change_column_default :agents_hosts, :work_engine, from: "claude", to: nil
    change_column_null :agents_hosts, :reviewer, true
    change_column_default :agents_hosts, :reviewer, from: "codex", to: nil
    add_check_constraint :agents_hosts, "(work_engine IS NULL) = (reviewer IS NULL)",
                         name: "agents_hosts_engine_choice_complete"
  end

  # Machines that follow the organization get its choice as their own, so the columns can be required again.
  def down
    remove_check_constraint :agents_hosts, name: "agents_hosts_engine_choice_complete"
    execute <<~SQL.squish
      UPDATE agents_hosts SET
        work_engine = COALESCE(settings.work_engine, 'claude'),
        reviewer = COALESCE(settings.reviewer, 'codex')
      FROM agents_hosts AS hosts
      LEFT JOIN agents_automator_settings AS settings ON settings.organization_id = hosts.organization_id
      WHERE agents_hosts.id = hosts.id AND agents_hosts.work_engine IS NULL
    SQL
    change_column_default :agents_hosts, :reviewer, from: nil, to: "codex"
    change_column_null :agents_hosts, :reviewer, false
    change_column_default :agents_hosts, :work_engine, from: nil, to: "claude"
    change_column_null :agents_hosts, :work_engine, false

    drop_table :agents_automator_settings
  end
end
