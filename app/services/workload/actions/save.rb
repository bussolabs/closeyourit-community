# frozen_string_literal: true

module Workload
  module Actions
    # Salva una action (create/update) + delega i partecipanti a SetParticipants, in un'unica
    # transazione. Sincronizza completed_at con lo stato done. Result pattern. team_id va passato
    # solo alla creazione (attr_readonly sul model).
    class Save < ApplicationService
      def initialize(action:, attributes:, participant_ids: nil, actor: nil, true_actor: nil)
        @action = action
        @attributes = attributes
        @participant_ids = participant_ids
        @actor = actor
        @true_actor = true_actor
      end

      def call
        participants_result = nil
        was_new = @action.new_record?
        ActiveRecord::Base.transaction do
          assign_attributes
          @action.save!
          record_activity(was_new)
          if @participant_ids
            participants_result = SetParticipants.call(action: @action, account_ids: @participant_ids)
            raise ActiveRecord::Rollback if participants_result.err?
          end
        end
        return participants_result if participants_result&.err?

        Result.ok(@action)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(I18n.t("workload.errors.invalid"),
                                code: "R422-WORKLOAD-001", details: e.record.errors.to_hash))
      end

      private

      def assign_attributes
        @action.created_by ||= @actor if @action.new_record?
        @action.assign_attributes(@attributes)
        # completed_at vive/muore con lo stato done (mai passato dai canali).
        @action.completed_at = @action.status_done? ? (@action.completed_at || Time.current) : nil
      end

      # 'updated' solo se sono cambiate colonne reali (niente evento-rumore su submit senza modifiche).
      def record_activity(was_new)
        if was_new
          Activity::Record.call(subject: @action, action: "created", actor: @actor, true_actor: @true_actor)
        else
          changed = @action.saved_changes.keys - %w[updated_at created_at]
          return if changed.empty?

          Activity::Record.call(subject: @action, action: "updated", data: { fields: changed },
                                actor: @actor, true_actor: @true_actor)
        end
      end
    end
  end
end
