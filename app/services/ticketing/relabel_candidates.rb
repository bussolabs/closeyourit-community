# frozen_string_literal: true

module Ticketing
  # Quali ticket hanno un'analisi tecnica da riscrivere a etichette (CYRA-266), e quali di questi
  # sono lavorabili adesso.
  #
  # PORO senza scritture, come Ticketing::TechnicalAnalysisCandidates: è la decisione che, sbagliata,
  # salta in silenzio dei ticket o ne riscrive di sbagliati — e sta dentro un rake, cioè nell'unico
  # posto che nessuno testa. Qui è testabile da sola.
  #
  # => { workable: [...], locked: [...] }
  #   workable = da riscrivere adesso
  #   locked   = da riscrivere, ma con l'automazione in corso: si saltano SENZA marcarli, li riprende
  #              il rilancio. Il corpo di quei ticket è la specifica che un agente sta seguendo.
  #
  # Dal CYRA-765 non esiste più la terza lista «organizzazione senza il servizio collegato»: l'AI la
  # offre il sistema, quindi o c'è per tutti o non c'è per nessuno.
  class RelabelCandidates < ApplicationService
    def initialize(limit: nil)
      @limit = limit
    end

    def call
      candidates = scope.reject { |ticket| already_labelled?(ticket) }
      candidates = candidates.first(@limit) if @limit.present?

      locked, workable = candidates.partition { |ticket| ticket.agent_workflow&.body_locked? }
      { workable: workable, locked: locked }
    end

    private

    def scope
      Ticketing::Ticket.where(analysis_relabeled_at: nil)
                       .where.not(technical_analysis: [ nil, "" ])
                       .includes(:project, :agent_workflow)
                       .order(:created_at)
    end

    # Il filtro sulle etichette vive in Ruby e non in SQL di proposito: il pattern è UNO, quello di
    # Ticketing::RelabelAnalysis, e riscriverlo come regex Postgres vorrebbe dire mantenerne due che
    # devono restare identiche — con la divergenza che si scopre solo a backfill finito.
    def already_labelled?(ticket)
      ticket.technical_analysis.match?(Ticketing::RelabelAnalysis::LABEL_PATTERN)
    end
  end
end
