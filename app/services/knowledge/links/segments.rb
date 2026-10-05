# frozen_string_literal: true

module Knowledge
  module Links
    # Spezza un markdown in segmenti alternati prosa/codice, così che i wikilink `[[…]]` vengano
    # letti (Links::Parse) e riscritti (Links::Render) SOLO fuori dal codice: una guida che
    # documenta la sintassi scrivendo `[[Titolo]]` non deve generare un collegamento.
    #
    # INVARIANTE: `segments.map(&:text).join == text`. Render ricostruisce il corpo da qui —
    # perdere o duplicare un byte significherebbe corrompere la pagina.
    #
    # Funzione pura (Array, niente Result). Riconosce i blocchi recintati (``` / ~~~) e i code
    # span inline; i blocchi indentati a 4 spazi restano prosa (rari nella KB, dove si usano le
    # recinzioni) — un falso positivo lì produce al più un link in più, mai testo corrotto.
    class Segments < ApplicationService
      Segment = Data.define(:text, :code)

      # Un code span è una sequenza di N backtick, contenuto che non contiene quella sequenza,
      # e la chiusura con gli stessi N backtick (regola CommonMark, semplificata).
      INLINE_CODE = /(`+)(?:(?!\1)[\s\S])*\1/
      OPENING_FENCE = /\A {0,3}(`{3,}|~{3,})/

      def initialize(text:)
        @text = text.to_s
      end

      def call
        segments = []
        buffer = +""
        fence = nil

        @text.each_line do |line|
          if fence
            buffer << line
            if closing_fence?(line, fence)
              segments << Segment.new(text: buffer, code: true)
              buffer = +""
              fence = nil
            end
          elsif (opening = line[OPENING_FENCE, 1])
            segments.concat(split_inline(buffer))
            buffer = +line
            fence = opening
          else
            buffer << line
          end
        end

        # Recinzione mai chiusa: per CommonMark il blocco arriva a fine documento.
        return segments << Segment.new(text: buffer, code: true) if fence

        segments.concat(split_inline(buffer))
      end

      private

      # Chiude solo una riga fatta dello stesso carattere della recinzione, lunga almeno quanto
      # l'apertura (`~~~` non chiude un blocco aperto con ```).
      def closing_fence?(line, fence)
        stripped = line.strip
        stripped.length >= fence.length && stripped.chars.uniq == [ fence[0] ]
      end

      def split_inline(text)
        return [] if text.empty?

        segments = []
        cursor = 0
        text.to_enum(:scan, INLINE_CODE).each do
          match = Regexp.last_match
          segments << Segment.new(text: text[cursor...match.begin(0)], code: false) if match.begin(0) > cursor
          segments << Segment.new(text: match[0], code: true)
          cursor = match.end(0)
        end
        segments << Segment.new(text: text[cursor..], code: false) if cursor < text.length
        segments
      end
    end
  end
end
