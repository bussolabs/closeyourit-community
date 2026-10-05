# frozen_string_literal: true

# Wire-result clean break (CYAU-97): le colonne di `agents_plans` erano modellate sul vecchio contratto
# agent-typed (summary/steps/interfaces/tests/risks); le skill reali (`/closeyourit-planner`) emettono
# invece technical_analysis/scenarios/definition_of_done/mixed_parts/notes. Rename 1:1 (tabella dormiente:
# popolata solo a runtime da Deliver#apply_plan!, nessun seed/factory → data-safe). `mixed_parts` è
# `null | {frontend,backend,integration}` nel contratto → diventa nullable senza default array.
class RenameAgentsPlansToSkillContract < ActiveRecord::Migration[8.1]
  def up
    rename_column :agents_plans, :summary, :technical_analysis
    rename_column :agents_plans, :steps, :scenarios
    rename_column :agents_plans, :tests, :definition_of_done
    rename_column :agents_plans, :interfaces, :mixed_parts
    rename_column :agents_plans, :risks, :notes

    change_column_null :agents_plans, :mixed_parts, true
    change_column_default :agents_plans, :mixed_parts, from: [], to: nil
  end

  def down
    # Il nuovo schema può aver scritto `mixed_parts` NULL: normalizziamo prima di ripristinare il NOT NULL,
    # altrimenti PostgreSQL rifiuta il vincolo (rollback non pulito con dati conformi al nuovo schema).
    execute("UPDATE agents_plans SET mixed_parts = '[]'::jsonb WHERE mixed_parts IS NULL")
    change_column_default :agents_plans, :mixed_parts, from: nil, to: []
    change_column_null :agents_plans, :mixed_parts, false

    rename_column :agents_plans, :notes, :risks
    rename_column :agents_plans, :mixed_parts, :interfaces
    rename_column :agents_plans, :definition_of_done, :tests
    rename_column :agents_plans, :scenarios, :steps
    rename_column :agents_plans, :technical_analysis, :summary
  end
end
