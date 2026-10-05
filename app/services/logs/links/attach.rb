# frozen_string_literal: true

module Logs
  module Links
    # Collega manualmente un log a un errore/ticket. Idempotente: ri-collegare lo stesso target è un
    # no-op (ritorna il link esistente). Il confine di tenant è applicato dal model (linkable stesso
    # progetto del log).
    class Attach < ApplicationService
      def initialize(log_entry:, linkable:, actor: nil)
        @log_entry = log_entry
        @linkable = linkable
        @actor = actor
      end

      def call
        link = Logs::Link.find_or_initialize_by(log_entry: @log_entry, linkable: @linkable)
        return Result.ok(link) if link.persisted?

        link.created_by = @actor
        return Result.ok(link) if link.save

        Result.err(AppError.new(link.errors.full_messages.to_sentence,
                                code: "R422-LOG-003", status: :unprocessable_content))
      rescue ActiveRecord::RecordNotUnique
        # Race: un'altra richiesta (doppio click / web+CLI concorrenti) ha creato lo stesso link tra il
        # find_or_initialize e il save -> no-op idempotente, non un 500.
        Result.ok(Logs::Link.find_by(log_entry: @log_entry, linkable: @linkable))
      end
    end
  end
end
