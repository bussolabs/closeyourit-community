# frozen_string_literal: true

# Rework host-first (CYAU-78): un Attempt può nascere dalla FASE (skill_key + service_account host)
# invece che da un typed-agent. Rende opzionali i riferimenti legacy (agent/command/instruction),
# porta le loro FK a ON DELETE SET NULL (così la rimozione dei typed-agent in CYAU-85 non distrugge
# l'audit storico) e denormalizza un EXECUTION PROFILE immutabile leggibile senza quei record.
# Additiva e reversibile: nessun attempt host-first nasce ancora (claim ricablato in CYAU-82).
class MakeAttemptsHostFirst < ActiveRecord::Migration[8.1]
  def up
    change_column_null :agents_attempts, :agent_id, true
    change_column_null :agents_attempts, :command_id, true
    change_column_null :agents_attempts, :instruction_id, true
    change_column_null :agents_attempts, :instruction_version, true
    change_column_null :agents_attempts, :instruction_digest, true

    # restrict → nullify: cancellare un typed-agent NON deve cancellare né bloccare gli attempt storici.
    remove_foreign_key :agents_attempts, :agents_agents, column: :agent_id
    remove_foreign_key :agents_attempts, :agents_commands, column: :command_id
    remove_foreign_key :agents_attempts, :agents_instructions, column: :instruction_id
    add_foreign_key :agents_attempts, :agents_agents, column: :agent_id, on_delete: :nullify
    add_foreign_key :agents_attempts, :agents_commands, column: :command_id, on_delete: :nullify
    add_foreign_key :agents_attempts, :agents_instructions, column: :instruction_id, on_delete: :nullify

    # Execution profile immutabile: host_id/phase/runtime (già presenti) + queste colonne descrivono
    # per intero come è stato eseguito il tentativo, indipendentemente da Agent/Command/Instruction.
    # service_account_id è l'IDENTITÀ audit host-first (gemello di host_id): ON DELETE restrict, non
    # nullify — nullificarlo romperebbe il XOR host-first (skill_key senza service_account = malformato).
    add_reference :agents_attempts, :service_account, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :accounts, on_delete: :restrict }
    add_column :agents_attempts, :skill_key, :string
    add_column :agents_attempts, :sandbox, :string
    add_column :agents_attempts, :permission_mode, :string
    add_column :agents_attempts, :allowed_tools, :jsonb, null: false, default: []
    add_column :agents_attempts, :ttl, :integer
    add_column :agents_attempts, :bundle_digest, :string
    add_column :agents_attempts, :bundle_ref, :string
  end

  def down
    remove_column :agents_attempts, :bundle_ref
    remove_column :agents_attempts, :bundle_digest
    remove_column :agents_attempts, :ttl
    remove_column :agents_attempts, :allowed_tools
    remove_column :agents_attempts, :permission_mode
    remove_column :agents_attempts, :sandbox
    remove_column :agents_attempts, :skill_key
    remove_reference :agents_attempts, :service_account, foreign_key: { to_table: :accounts }

    remove_foreign_key :agents_attempts, :agents_agents, column: :agent_id
    remove_foreign_key :agents_attempts, :agents_commands, column: :command_id
    remove_foreign_key :agents_attempts, :agents_instructions, column: :instruction_id
    add_foreign_key :agents_attempts, :agents_agents, column: :agent_id, on_delete: :restrict
    add_foreign_key :agents_attempts, :agents_commands, column: :command_id, on_delete: :restrict
    add_foreign_key :agents_attempts, :agents_instructions, column: :instruction_id, on_delete: :restrict

    # Ripristinare NOT NULL è possibile solo se nessun attempt ha perso i riferimenti legacy — per
    # SET NULL (typed-agent eliminato, ora consentito dalla FK nullify) o perché host-first. In tal
    # caso il riferimento non è ricostruibile e il rollback è irreversibile per design (rework).
    if select_value("SELECT 1 FROM agents_attempts WHERE agent_id IS NULL OR command_id IS NULL OR instruction_id IS NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
            "Esistono attempt senza agent/command/instruction: il vincolo NOT NULL legacy non è ripristinabile."
    end
    change_column_null :agents_attempts, :instruction_digest, false
    change_column_null :agents_attempts, :instruction_version, false
    change_column_null :agents_attempts, :instruction_id, false
    change_column_null :agents_attempts, :command_id, false
    change_column_null :agents_attempts, :agent_id, false
  end
end
