# frozen_string_literal: true

module Ticketing
  # Rimuove un allegato a livello ticket e registra `attachment_removed` (il ticket resta →
  # va in timeline). In transazione. `files.find` solleva RecordNotFound se l'id non esiste
  # (come il purge diretto che sostituisce). Result pattern.
  class RemoveAttachment < ApplicationService
    def initialize(ticket:, attachment_id:, actor: nil, true_actor: nil)
      @ticket = ticket
      @attachment_id = attachment_id
      @actor = actor
      @true_actor = true_actor
    end

    def call
      attachment = @ticket.files.find(@attachment_id)
      filename = attachment.filename.to_s
      # Log nella transazione; purge DOPO il commit: il file fisico NON è transazionale, un
      # rollback dopo il purge perderebbe il binario. Se il purge fallisse, il male minore è
      # un evento "rimosso" con file ancora presente (recuperabile), non un file perso.
      ApplicationRecord.transaction do
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                            action: "attachment_removed", data: { filename: filename })
      end
      attachment.purge
      # Il fingerprint degli allegati entra nel checksum del gate agenti (CYRA-184): togliere un
      # allegato cambia ciò che il modello vedrebbe, quindi va rivalutato. `files.reload` è
      # necessario: senza, l'associazione in memoria porta ancora l'allegato appena purgato e il
      # checksum risulterebbe invariato.
      @ticket.files.reload
      enqueue_agent_eligibility if @ticket.agent_eligibility_stale?
      Result.ok(@ticket)
    end

    private

    def enqueue_agent_eligibility
      Ticketing::AgentEligibilityQueue.enqueue(ticket: @ticket)
    end
  end
end
