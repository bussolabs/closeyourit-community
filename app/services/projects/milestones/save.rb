# frozen_string_literal: true

module Projects
  module Milestones
    # Crea o aggiorna una milestone di un progetto: attributi base, salvataggio + evento di
    # attività atomici (audit all-or-nothing), pattern Projects::Save. Sostituisce il
    # @milestone.save/update inline che viveva nel controller.
    class Save < ApplicationService
      def initialize(milestone:, attributes:, actor: nil, true_actor: nil)
        @milestone = milestone
        @attributes = attributes
        @actor = actor
        @true_actor = true_actor
      end

      def call
        was_new = @milestone.new_record?
        ApplicationRecord.transaction do
          @milestone.assign_attributes(@attributes)
          @milestone.created_by ||= @actor if was_new
          @milestone.save!
          record_activity(was_new)
        end
        Result.ok(@milestone)
      rescue ActiveRecord::RecordInvalid
        Result.err(AppError.new(@milestone.errors.full_messages.to_sentence,
                                code: "R422-MILESTONE-001", details: @milestone.errors.to_hash))
      end

      private

      def record_activity(was_new)
        if was_new
          Activity::Record.call(subject: @milestone, action: "created", actor: @actor, true_actor: @true_actor)
        else
          changed = @milestone.saved_changes.keys - %w[updated_at created_at]
          return if changed.empty?

          Activity::Record.call(subject: @milestone, action: "updated", data: { fields: changed },
                                actor: @actor, true_actor: @true_actor)
        end
      end
    end
  end
end
