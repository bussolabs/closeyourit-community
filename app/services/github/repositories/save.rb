# frozen_string_literal: true

module Github
  module Repositories
    # Aggiorna le REGOLE di binding del repo agganciato (mapping stabilità→environment, default_branch)
    # via `update` (le associazioni environment hanno validazioni). I flag booleani (sync/tag_binding/
    # autoclose) si togglano invece con update_column dal controller (auto-save, come i feature-flag del
    # progetto). Condiviso da Member e CLI. R422-GITHUB-001 su validazione.
    class Save < ApplicationService
      # CYRA-605 — `release_probe` DEVE stare qui: sotto si fa `slice`, quindi un campo non elencato
      # non arriva errore, sparisce. Il canale risponderebbe 200 e non avrebbe cambiato niente.
      # CYRA-625 — e con lui le coordinate dello scaffale: senza, la scelta «il pacchetto è
      # pubblicato» si salverebbe senza sapere dove guardare — cioè non si salverebbe affatto.
      ATTRIBUTES = %i[default_branch production_environment_id staging_environment_id
                      preview_environment_id release_probe registry package_name].freeze

      def initialize(repository:, attributes:)
        @repository = repository
        @attributes = attributes.to_h.symbolize_keys.slice(*ATTRIBUTES)
      end

      def call
        return Result.ok(@repository) if @repository.update(@attributes)

        Result.err(AppError.new(@repository.errors.full_messages.to_sentence,
                                code: "R422-GITHUB-001", details: @repository.errors.to_hash))
      end
    end
  end
end
