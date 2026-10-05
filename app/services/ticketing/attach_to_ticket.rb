# frozen_string_literal: true

module Ticketing
  # Allega file a un ticket GIÀ persistito. Su record persistito ActiveStorage attacca subito,
  # quindi la validazione del model non bloccherebbe: qui si pre-validano tipo/dimensione
  # (stessi limiti del concern Attachable) prima dell'attach. Result pattern.
  class AttachToTicket < ApplicationService
    def initialize(ticket:, files:, actor: nil, true_actor: nil)
      @ticket = ticket
      @files = Array.wrap(files).reject(&:blank?)
      @actor = actor
      @true_actor = true_actor
    end

    def call
      return err(:no_files) if @files.empty?
      return err(:invalid_attachment) unless @files.all? { |file| allowed?(file) }

      filenames = @files.map(&:original_filename)
      ApplicationRecord.transaction do
        @ticket.files.attach(@files)
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                            action: "attached", data: { filenames: filenames })
      end
      # Il rischio può stare SOLO nell'allegato (lo screenshot di una console di produzione su un
      # ticket dal testo innocuo): allegare rivaluta il gate agenti (CYRA-184). Fuori transazione.
      enqueue_agent_eligibility if @ticket.agent_eligibility_stale?
      Result.ok(@ticket)
    end

    private

    def enqueue_agent_eligibility
      Ticketing::AgentEligibilityQueue.enqueue(ticket: @ticket)
    end

    # Tipo SNIFFATO da Marcel sui byte reali (come fa ActiveStorage al build del blob),
    # NON il content-type dichiarato dal client (spoofabile). Coerente col path commenti,
    # che valida blob.content_type. Su record persistito l'attach committa subito, quindi
    # qui è l'unico gate: deve usare la stessa sorgente di verità.
    def allowed?(file)
      sniffed = Marcel::MimeType.for(file.tempfile, name: file.original_filename, declared_type: file.content_type)
      Attachable.allowed?(content_type: sniffed, byte_size: file.size)
    end

    def err(key)
      Result.err(AppError.new(I18n.t("member.tickets.attachments.errors.#{key}"),
                              code: "R422-ATTACHMENT-001"))
    end
  end
end
