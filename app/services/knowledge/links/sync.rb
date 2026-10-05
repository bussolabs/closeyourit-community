# frozen_string_literal: true

module Knowledge
  module Links
    # Riallinea i Connections::PageLink uscenti di una pagina ai wikilink presenti nel suo corpo.
    # Chiamato DENTRO la transazione di salvataggio (CreatePage/UpdatePage/Pages::Publish): o la
    # pagina si salva col suo grafo aggiornato, o non si salva.
    #
    # Risoluzione titolo→pagina, deterministica (org-scoped):
    #   1. se nell'organizzazione esiste ESATTAMENTE UNA pagina con quel titolo, quella;
    #   2. più di una (ambiguo) o nessuna → nessun collegamento, il testo resta com'è.
    # Con le pagine multi-progetto non esiste più "il progetto della pagina": la disambiguazione
    # per-progetto è caduta a favore dell'unicità nell'org.
    # Mai un errore: un wikilink che non risolve è testo, non un fallimento del salvataggio.
    #
    # Il collegamento è congelato per id: rinominare la destinazione NON lo rompe. Il rovescio è
    # che un wikilink rimasto irrisolto non si aggancia da solo quando più tardi nasce una pagina
    # con quel titolo — a riconciliare è Knowledge::BackfillLinksJob (o il salvataggio successivo).
    #
    # Ritorna gli id delle pagine collegate, nell'ordine di apparizione nel corpo.
    class Sync < ApplicationService
      def initialize(page:)
        @page = page
      end

      def call
        references = Parse.call(text: @page.body)
        resolved = resolve(references)

        # Il caso comune è "nessun wikilink su una pagina che non ne aveva": un EXISTS costa meno
        # di una DELETE inutile ad ogni salvataggio.
        return [] if resolved.empty? && !@page.links.exists?

        rewrite(resolved)
        resolved.map { |row| row[:related_id] }
      end

      private

      # Un'unica query per TUTTI i titoli citati: la pagina è un documento, non un grafo, e la
      # scansione è confinata alle pagine dell'organizzazione.
      def resolve(references)
        return [] if references.empty?

        candidates = candidates_by_title(references.map { |reference| reference.title.downcase })

        references.filter_map do |reference|
          target = pick(candidates[reference.title.downcase])
          next if target.nil?

          { related_id: target.id, target_title: reference.title }
        end
      end

      def candidates_by_title(keys)
        ::Knowledge::Page
          .where(organization_id: @page.organization_id)
          .where.not(id: @page.id)
          .where("LOWER(BTRIM(knowledge_pages.title)) IN (?)", keys)
          .select(:id, :title)
          .group_by { |candidate| candidate.title.strip.downcase }
      end

      # L'unica pagina dell'org con quel titolo. Ambiguo (più d'una) → nil (nessun collegamento).
      def pick(candidates)
        return nil if candidates.blank?

        candidates.one? ? candidates.first : nil
      end

      # Riscrittura completa (il corpo è la fonte di verità), non un diff: `unique_by` rende
      # l'inserimento tollerante a un sync concorrente sulla stessa pagina. Le validazioni del
      # model restano la difesa per gli altri scrittori — qui gli invarianti (no self-link, stessa
      # organizzazione) sono garantiti per costruzione dalla risoluzione.
      def rewrite(resolved)
        @page.links.delete_all
        if resolved.any?
          Connections::PageLink.insert_all(
            resolved.map { |row| row.merge(page_id: @page.id) },
            unique_by: %i[page_id related_id]
          )
        end
        # `delete_all` marca l'associazione come caricata-e-vuota e `insert_all` la scavalca:
        # senza reset il chiamante leggerebbe un grafo vuoto appena scritto.
        @page.links.reset
      end
    end
  end
end
