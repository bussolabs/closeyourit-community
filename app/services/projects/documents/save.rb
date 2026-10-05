# frozen_string_literal: true

module Projects
  module Documents
    # Aggiorna un documento esistente (rinomina, tag, descrizione): l'upload iniziale resta in
    # Upload, questo service copre il canale di modifica così l'evento 'updated' resta dentro la
    # stessa transazione del salvataggio (audit all-or-nothing, pattern Projects::Save).
    class Save < ApplicationService
      def initialize(document:, attributes:, actor: nil, true_actor: nil)
        @document = document
        @attributes = attributes
        @actor = actor
        @true_actor = true_actor
      end

      def call
        ApplicationRecord.transaction do
          @document.assign_attributes(@attributes)
          @document.save!
          record_activity
        end
        Result.ok(@document)
      rescue ActiveRecord::RecordInvalid
        Result.err(AppError.new(@document.errors.full_messages.to_sentence,
                                code: "R422-DOCUMENT-002", details: @document.errors.to_hash))
      end

      private

      # 'updated' solo se sono cambiate colonne reali (niente evento-rumore su submit senza modifiche).
      def record_activity
        changed = @document.saved_changes.keys - %w[updated_at created_at]
        return if changed.empty?

        Activity::Record.call(subject: @document, action: "updated", data: { fields: changed },
                              actor: @actor, true_actor: @true_actor)
      end
    end
  end
end
