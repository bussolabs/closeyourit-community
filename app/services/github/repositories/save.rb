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
      # CYRA-1055 — the issue sync: which issues, which board, column → status, label → type/priority.
      ATTRIBUTES = %i[default_branch production_environment_id staging_environment_id
                      preview_environment_id release_probe registry package_name
                      issue_sync board_node_id board_columns kind_labels priority_labels].freeze

      def initialize(repository:, attributes:, client: Github::Client.new)
        @repository = repository
        @attributes = attributes.to_h.deep_symbolize_keys.slice(*ATTRIBUTES)
        @client = client
      end

      def call
        board = resolve_board
        return board if board.is_a?(Result)

        was_syncing = @repository.issue_sync_active?
        if @repository.update(model_attributes(board))
          freeze_missing_decisions if @repository.release_probe.present?
          start_first_import(was_syncing)
          return Result.ok(@repository)
        end

        Result.err(AppError.new(@repository.errors.full_messages.to_sentence,
                                code: "R422-GITHUB-001", details: @repository.errors.to_hash))
      rescue Github::Client::Error => e
        Result.err(AppError.new(I18n.t("github.issues.errors.board_unreadable"), code: "R422-GITHUB-013",
                                details: { board_node_id: [ e.code ] }))
      end

      private

      # The pages send "this type → this label"; the repository keeps "this label → this type".
      def model_attributes(board)
        attributes = @attributes.except(:kind_labels, :priority_labels, :board_columns)
        attributes[:label_kinds] = inverted(@attributes[:kind_labels]) if @attributes.key?(:kind_labels)
        attributes[:label_priorities] = inverted(@attributes[:priority_labels]) if @attributes.key?(:priority_labels)
        attributes[:board_columns] = @attributes[:board_columns].to_h.transform_keys(&:to_s).compact_blank if @attributes.key?(:board_columns)
        attributes.merge(board || {})
      end

      def inverted(map) = map.to_h.each_with_object({}) { |(value, label), out| out[label.to_s] = value.to_s if label.present? }

      # A newly chosen board is read once: its title and the field that holds the columns. A board
      # without a single-select column cannot move tickets, and saying so beats saving it silently.
      def resolve_board
        return nil unless @attributes.key?(:board_node_id)

        node_id = @attributes[:board_node_id].presence
        return { board_node_id: nil, board_title: nil, board_status_field_id: nil, board_columns: {} } if node_id.nil?
        return nil if node_id == @repository.board_node_id

        board = @client.board(@repository.github_installation_id, node_id)
        if board.nil? || board[:field].nil?
          return Result.err(AppError.new(I18n.t("github.issues.errors.board_without_columns"), code: "R422-GITHUB-013"))
        end

        { board_node_id: node_id, board_title: board[:title], board_status_field_id: board[:field]["id"], board_columns: {} }
      end

      # Turning the sync on (or choosing another board) brings the open issues in, a page at a time.
      def start_first_import(was_syncing)
        return unless @repository.issue_sync_active?
        return if was_syncing && !@repository.saved_change_to_board_node_id? && !@repository.saved_change_to_issue_sync?

        Github::Issues::FirstImportJob.perform_later(repository_id: @repository.id)
      end

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
