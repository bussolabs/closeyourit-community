# frozen_string_literal: true

module Knowledge
  module Pages
    # Segna una pagina accettata come scritta anche fra i documenti versionati (CYRA-298): chiude il
    # secondo passo del flusso, quello che la regola knowledge-publishing chiede da sempre — il file
    # nel repo è la fonte di verità, la pagina è la copia consultabile.
    #
    # source_path è il percorso relativo dentro il repo della knowledge base. Riscrivibile: un
    # documento si può spostare di sezione, e il puntatore deve poterlo seguire.
    class MarkConsolidated < ApplicationService
      include ReviewGuards

      def initialize(page:, actor:, source_path:)
        @page = page
        @actor = actor
        @source_path = source_path
      end

      def call
        return wrong_status(:not_published) unless @page.status_published?
        return forbidden unless manageable?

        path = @source_path.to_s.strip
        return blank_source_path if path.blank?

        @page.update!(consolidated_at: Time.current, source_path: path)
        Result.ok(@page)
      end

      private

      def blank_source_path
        Result.err(
          AppError.new(
            I18n.t("member.knowledge.errors.source_path_required"),
            code: "R422-KNOWLEDGE-010",
            details: { source_path: [ I18n.t("errors.messages.blank") ] }
          )
        )
      end
    end
  end
end
