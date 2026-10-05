# frozen_string_literal: true

module Knowledge
  module Review
    # Mette in regola una pagina promossa dal revisore in modalità legacy (CYRA-773): scrive la riga
    # `Formato: <etichetta>` in testa al corpo e i tag minimi (area presa dal titolo + formato), così
    # il parco scritto prima delle regole diventa conforme senza cinquecento modifiche a mano.
    #
    # Scrive SOLO ciò che manca: una pagina che ha già la riga o due tag non viene toccata su quel
    # fronte. Il testo cambia davvero, quindi versione (RecordVersion, senza autore: è l'automazione)
    # e re-embed, come per una modifica qualsiasi. Il verdetto sulle colonne `ai_review_*` NON si
    # tocca: `ai_reviewed_at` viene riallineato a `updated_at` perché il giudizio vale ancora — la
    # riga aggiunta è quella che il giudizio presuppone.
    class Normalize < ApplicationService
      AREA_SEPARATOR = / — /

      def initialize(page:, format:)
        @page = page
        @format = format.to_s
      end

      def call
        return Result.ok(@page) unless Knowledge::Constants::REVIEW_FORMATS.include?(@format)

        attributes = {}
        attributes[:body] = "Formato: #{label}\n\n#{@page.body}" if Precheck.format_of(@page.body).nil?
        tags = (@page.tags + missing_tags).uniq
        attributes[:tags] = tags if tags != @page.tags
        return Result.ok(@page) if attributes.empty?

        ApplicationRecord.transaction do
          @page.update!(attributes)
          # Riallineo `ai_reviewed_at` a `updated_at`: la modifica non cambia il giudizio, e un giro
          # successivo non deve rigiudicarla.
          @page.update_columns(ai_reviewed_at: @page.updated_at) # rubocop:disable Rails/SkipsModelValidations
          Knowledge::RecordVersion.call(page: @page, author: nil) if attributes.key?(:body)
        end
        Knowledge::EmbedPageJob.perform_later(page_id: @page.id) if attributes.key?(:body)
        Result.ok(@page)
      end

      private

      def label = Knowledge::Constants::REVIEW_FORMAT_LABELS.fetch(@format)

      # Area dal prefisso del titolo («Rails — …» → `rails`, «Clubbel Flutter — …» → `clubbel-flutter`),
      # poi il formato; abbastanza per la regola K11 (due tag) senza inventare niente.
      def missing_tags
        candidates = [ area_tag, @format.tr("_", "-") ].compact
        needed = Knowledge::Constants::REVIEW_MIN_TAGS - @page.tags.size
        return [] if needed <= 0

        (candidates - @page.tags).first(needed)
      end

      def area_tag
        prefix = @page.title.to_s.split(AREA_SEPARATOR, 2).first.to_s
        return nil if prefix.blank? || prefix == @page.title.to_s

        prefix.parameterize.presence
      end
    end
  end
end
