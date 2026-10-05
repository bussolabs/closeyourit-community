# frozen_string_literal: true

module Agents
  module Workflows
    # La pipeline closer è "pronta" solo se esiste una macchina che il claim reale
    # (Agents::TicketQueues::Next / CandidateSnapshot) potrebbe considerare idonea a lavorare QUESTO
    # ticket. Host-first (CYAU-100): l'autorità è l'HOST e il predicato è `Eligibility.capable?`, la
    # stessa fonte del claim, così le due non possono divergere. Copre org, revoca, certificazione,
    # repo GitHub, scope, host-map (`repositories`) e runtime della fase: senza uno solo di questi
    # nessun host potrebbe reclamare, e accodare lascerebbe il ticket appeso.
    #
    # Restano fuori heartbeat e slot liberi, deliberatamente: sono liveness e capienza del momento.
    # Una macchina spenta cinque minuti, o momentaneamente piena, non deve cambiare la destinazione
    # del ticket. Entrambe le fasi closer sono richieste.
    #
    # Estratto da Ticketing::ApproveReview perché la stessa domanda la fa ora anche il sì automatico
    # (CYRA-868): due copie divergerebbero, e la seconda accoderebbe in una coda che nessuno serve.
    module CloserPipeline
      PHASES = %w[closer_staging closer_production].freeze

      module_function

      def configured?(organization:, project:)
        return false if project.nil?

        # La fleet è una manciata di Mac (come in Member::AgentsController): il ciclo per host è più
        # chiaro di una join sulla visibilità, che vive dentro Authorization::VisibleScope.
        organization.agent_hosts.active.any? do |host|
          PHASES.all? { |phase| Agents::Hosts::Eligibility.capable?(host:, project:, phase:) }
        end
      end
    end
  end
end
