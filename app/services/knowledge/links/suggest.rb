# frozen_string_literal: true

module Knowledge
  module Links
    # Alimenta l'autocomplete dei titoli mentre si scrive un wikilink `[[…]]` nel corpo di una pagina
    # (CYRA-433). Riceve GIÀ lo scope visibile a chi scrive — un suggerimento non deve rivelare il
    # titolo di una pagina che non potrebbe aprire — e ne ritorna al più LIMIT righe.
    #
    # Propone solo titoli che Links::Sync saprebbe risolvere: un titolo portato da più pagine
    # dell'organizzazione è ambiguo, resterebbe testo morto, e suggerirlo sarebbe una promessa
    # rotta. L'ambiguità si valuta su TUTTA l'org (come Sync), non sulle sole pagine visibili: una
    # pagina nascosta con lo stesso titolo rompe la risoluzione lo stesso.
    #
    # Ritorna Array<Knowledge::Page> (id/title/kind), non un Result: è un aiuto di digitazione, non
    # un'operazione che può fallire.
    class Suggest < ApplicationService
      LIMIT = 8

      def initialize(scope:, organization:, query: nil, exclude_id: nil)
        @scope = scope
        @organization = organization
        @query = query.to_s.strip
        # L'id arriva dal form: un valore che non è un uuid diventa nil col cast della colonna e
        # l'esclusione salta. Senza cast Rails genererebbe `id != NULL`, sempre falso, e
        # l'autocomplete non proporrebbe PIÙ NULLA su una richiesta storta.
        @exclude_id = ::Knowledge::Page.type_for_attribute(:id).cast(exclude_id.presence)
      end

      def call
        rows = candidates
        return [] if rows.empty?

        ambiguous = ambiguous_keys(rows.map(&:title))
        rows.reject { |row| ambiguous.include?(key(row.title)) }
      end

      private

      # Con una ricerca in corso l'ordine alfabetico è prevedibile mentre si continua a digitare; a
      # parentesi appena aperte (nessuna query) contano le pagine su cui il team sta lavorando.
      def candidates
        rows = excluded(@scope)
        return rows.order(updated_at: :desc).limit(LIMIT).to_a if @query.blank?

        rows.where("knowledge_pages.title ILIKE ?", like).order(:title).limit(LIMIT).to_a
      end

      # Titoli portati da più di una pagina dell'org: Links::Sync#pick li lascia irrisolti.
      # L'esclusione della pagina che scrive vale anche qui, esattamente come in Sync.
      def ambiguous_keys(titles)
        excluded(::Knowledge::Page.where(organization_id: @organization.id))
          .where("LOWER(BTRIM(knowledge_pages.title)) IN (?)", titles.map { |title| key(title) })
          .group(Arel.sql("LOWER(BTRIM(knowledge_pages.title))"))
          .having("COUNT(*) > 1")
          .count.keys.to_set
      end

      # Un id malformato non deve alzare un errore: il cast uuid lo rende nil e la clausola non
      # esclude nulla — un suggerimento in più, mai un 500 su un aiuto di digitazione.
      def excluded(scope)
        @exclude_id ? scope.where.not(id: @exclude_id) : scope
      end

      def key(title) = title.to_s.strip.downcase

      def like = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
    end
  end
end
