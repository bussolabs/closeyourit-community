# frozen_string_literal: true

module Knowledge
  module Links
    # Estrae i riferimenti wikilink `[[Titolo]]` / `[[Titolo|testo mostrato]]` dal markdown di una
    # pagina. Funzione pura (Array<Reference>, niente Result e nessun accesso al DB): la
    # risoluzione titolo→pagina è compito di Links::Sync.
    #
    # Il codice è escluso (Links::Segments), i titoli sono deduplicati case-insensitive e il
    # numero di riferimenti è limitato: una pagina è un documento, non un grafo.
    class Parse < ApplicationService
      Reference = Data.define(:title, :anchor_text)

      # Titolo e label su una sola riga: un `[[` orfano non deve inghiottire mezzo documento.
      WIKILINK = /\[\[([^\[\]|\n]{1,255})(?:\|([^\[\]\n]{1,255}))?\]\]/
      MAX_LINKS = 50

      def initialize(text:)
        @text = text.to_s
      end

      def call
        seen = Set.new
        references = []

        Segments.call(text: @text).each do |segment|
          next if segment.code

          segment.text.scan(WIKILINK) do |title, label|
            title = title.strip
            next if title.blank? || !seen.add?(title.downcase)

            references << Reference.new(title: title, anchor_text: label&.strip.presence || title)
            # Uscita anticipata dal metodo: `break` romperebbe solo lo scan del segmento corrente.
            return references if references.size >= MAX_LINKS
          end
        end

        references
      end
    end
  end
end
