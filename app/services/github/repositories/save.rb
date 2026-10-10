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
        if @repository.update(@attributes)
          freeze_missing_decisions if @repository.release_probe.present?
          return Result.ok(@repository)
        end

        Result.err(AppError.new(@repository.errors.full_messages.to_sentence,
                                code: "R422-GITHUB-001", details: @repository.errors.to_hash))
      end

      private

      # CYRA-1072 — plans approved before the project had a release proof froze nothing and never
      # entered the queue. Setting the proof fills what they miss; a frozen decision is never rewritten.
      def freeze_missing_decisions
        decision = Agents::Plan.decision_for_repository(@repository)
        return unless decision.frozen?

        # Through the model, so the written-once guard still applies; each row is locked and re-read, so
        # a plan frozen meanwhile by an approval is left as it is.
        Agents::Plan.joins(:workflow)
                    .where(candidate_items: nil).where.not(approved_at: nil)
                    .where(agents_workflows: { cancelled_at: nil, completed_at: nil })
                    .where("agents_workflows.frozen_plan_id = agents_plans.id")
                    .where(agents_workflows: { ticket_id: @repository.project.tickets.select(:id) })
                    .find_each do |plan|
          plan.with_lock do
            next if plan.candidate_items.present?

            plan.update!(candidate_items: decision.candidate_items, completion_probe: decision.completion_probe)
          end
        end
      end
    end
  end
end
