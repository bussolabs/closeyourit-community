# frozen_string_literal: true

# Tetto ai tentativi di revisione (CYRA-218): un piano bocciato in review lasciava la fase planner
# reclamabile all'infinito (Workflow#ready_execution_phase: `triaged_at? && planned_at.nil?`), quindi
# la lavorazione rifaceva il piano finché qualcuno non se ne accorgeva — e nessuno se ne accorgeva,
# perché il ciclo non compariva da nessuna parte. Il 2026-07-30 un ticket l'ha rifatto quattro volte
# in un quarto d'ora, tutte bocciate.
#
# Raggiunto Agents::Constants::PHASE_REVIEW_LIMIT sulla stessa fase, la consegna valorizza queste
# tre colonne: la fase smette di essere offerta (guardia dentro il CASE, gemella di cancelled/completed)
# e il motivo resta scritto, così la UI può dire perché si è fermata invece di sembrare "in corso".
#
# Tutte nullable: un workflow sano non le tocca mai. Nessun indice — il CASE è valutato su un set già
# ristretto da progetto, eleggibilità e lease (Agents::TicketQueues::Next), mai in scansione.
class AddBlockedColumnsToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :blocked_at, :datetime
    add_column :agents_workflows, :blocked_phase, :string
    add_column :agents_workflows, :blocked_reason, :text
  end
end
