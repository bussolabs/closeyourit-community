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
      @ticket.with_lock do
        attachment = @ticket.files.find(@attachment_id)
        filename = attachment.filename.to_s
        blob = attachment.blob
        attachment.destroy!
        SetAgentEligibility.call(ticket: @ticket, source: :invalidate, locked: true)
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                            action: "attachment_removed", data: { filename: filename })
        # Detach and withdraw atomically; physical storage is touched only after commit. CYRA-1219.
        ActiveRecord.after_all_transactions_commit { blob.purge_later }
      end
      # Il fingerprint degli allegati entra nel checksum del gate agenti (CYRA-184): togliere un
      # allegato cambia ciò che il modello vedrebbe, quindi va rivalutato. `files.reload` è
      # necessario: senza, l'associazione in memoria porta ancora l'allegato appena purgato e il
      # checksum risulterebbe invariato.
      @ticket.files.reload
      enqueue_agent_eligibility if @ticket.agent_eligibility_stale?
      # Its link leaves the text of a linked issue (CYRA-1055).
      ::Github::Issues::Outbound.ticket_changed(@ticket)
      Result.ok(@ticket)
    end

    private

    def enqueue_agent_eligibility
      Ticketing::AgentEligibilityQueue.enqueue(ticket: @ticket)
    end
  end
end
