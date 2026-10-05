# frozen_string_literal: true

module Member
  # Presentazione dell'elenco delle lavorazioni in volo (CYRA-593).
  module WorkflowsHelper
    # Il colore dice CHI aspetta chi, non a che fase si è arrivati: ambra dove serve una persona,
    # indaco dove l'agente sta lavorando, grigio dove non è ancora partito niente. Legato allo
    # stato e non alla fase, così una fase nuova non nasce senza colore.
    STATE_COLORS = { "waiting" => :amber, "running" => :indigo, "idle" => :gray }.freeze

    def workflow_state_color(state) = STATE_COLORS.fetch(state.to_s, :gray)
  end
end
