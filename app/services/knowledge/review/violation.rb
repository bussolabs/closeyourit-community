# frozen_string_literal: true

module Knowledge
  module Review
    # Una regola violata: `code` è la sigla della regola (K02, T01, …), `message` la frase per chi
    # deve correggere. `blocking: false` è l'avviso che non ferma il salvataggio (la parte di una
    # guida che ancora non c'è, regola P05).
    #
    # `quote` è il passaggio della pagina che motiva la violazione (CYAU-200): c'è solo per le regole
    # di sostanza, e solo quando il testo lo contiene davvero — una regola su qualcosa che MANCA non
    # ha niente da citare.
    Violation = Data.define(:code, :message, :blocking, :quote) do
      def initialize(code:, message:, blocking: true, quote: nil) = super

      def blocking? = blocking

      def to_h = { code: code, message: message, blocking: blocking, quote: quote }

      # La riga che leggono la CLI e il registro: regola, frase, e il passaggio quando c'è.
      def to_line = quote.present? ? "#{code} — #{message} «#{quote}»" : "#{code} — #{message}"
    end
  end
end
