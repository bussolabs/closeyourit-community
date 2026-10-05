# frozen_string_literal: true

module Knowledge
  module Links
    # Sostituisce i wikilink RISOLTI con veri link markdown, prima che il corpo passi a
    # Commonmarker. Un `[[Titolo]]` che non ha una riga Connections::PageLink resta testo così
    # com'è: la pagina non deve mai mostrare un link rotto.
    #
    # L'aggancio usa `target_title` (il titolo come fu scritto), non il titolo corrente della
    # destinazione: se qualcuno rinomina la pagina di arrivo, il link continua a funzionare.
    #
    # Fuori dal codice, sempre: `Links::Segments` garantisce che una guida che DOCUMENTA la
    # sintassi — con `[[Titolo]]` in un blocco o fra backtick — resti leggibile.
    #
    # `links:` permette a chi chiama di passare i SOLI collegamenti visibili al lettore: un
    # wikilink verso un progetto che non può aprire resta testo, non diventa un link morto.
    class Render < ApplicationService
      include Rails.application.routes.url_helpers

      def initialize(text:, page:, links: nil)
        @text = text.to_s
        @page = page
        @links = links
      end

      def call
        return @text if @text.blank? || links_by_title.empty?

        Segments.call(text: @text).map { |segment| segment.code ? segment.text : substitute(segment.text) }.join
      end

      private

      def links_by_title
        @links_by_title ||= (@links || @page.links.includes(:related))
                            .index_by { |link| link.target_title.strip.downcase }
      end

      def substitute(text)
        text.gsub(Parse::WIKILINK) do
          title = Regexp.last_match(1)
          label = Regexp.last_match(2)
          link = links_by_title[title.strip.downcase]
          link ? markdown_link(link, label.presence&.strip || title.strip) : Regexp.last_match(0)
        end
      end

      # Le tonde vanno neutralizzate: una label che ne contiene chiuderebbe il link a metà. Le
      # quadre non arrivano mai fin qui (Parse::WIKILINK non le ammette in titolo o label).
      def markdown_link(link, label)
        "[#{label.gsub(/([()])/) { "\\#{Regexp.last_match(1)}" }}](#{member_knowledge_page_path(link.related_id)})"
      end
    end
  end
end
