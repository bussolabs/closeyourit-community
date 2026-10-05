# frozen_string_literal: true

# Interruttore dedicato alla riscrittura delle analisi tecniche a etichette (CYRA-266).
#
# Perché una chiave NUOVA e non il riuso di ai_comment_compaction_enabled: le due migrazioni girano
# in momenti diversi — la riscrittura va lanciata DOPO la compattazione, perché quella riscrive già
# il campo di una sessantina di ticket. Un interruttore che ne ferma due è un interruttore che non si
# usa, perché chi lo tocca deve prima chiedersi cos'altro sta spegnendo.
#
# Default true come le altre: la migration non cambia il comportamento di un'istanza già viva.
class AddAiAnalysisRelabelSwitch < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :ai_analysis_relabel_enabled, :boolean, null: false, default: true
  end
end
