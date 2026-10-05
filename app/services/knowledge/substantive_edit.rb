# frozen_string_literal: true

module Knowledge
  # CYRA-419 — dice se il testo di una pagina è stato RISCRITTO o soltanto corretto. È la soglia che
  # fa decadere il segno «scritta da un assistente»: chi corregge una virgola non diventa l'autore
  # della pagina, chi ne riscrive un pezzo sì.
  #
  # LA REGOLA, in chiaro (la stessa che la guida racconta a chi usa il prodotto):
  #   - si contano le parole ENTRATE e USCITE dal testo — sostituirne una ne conta due;
  #   - sotto le 5 non è mai una riscrittura: è una correzione (virgola, accento, un paio di parole);
  #   - da 40 in su lo è sempre: è un paragrafo riscritto, qualunque sia la lunghezza della pagina;
  #   - in mezzo, conta la proporzione: un quinto delle parole della pagina, cioè una parola su dieci
  #     sostituita.
  # Punteggiatura, maiuscole e spazi non contano: non cambiano quello che la pagina dice.
  #
  # Puro come Knowledge::PlainLanguageCheck (niente Result, niente DB): riceve due testi, ritorna un
  # booleano. Soglie deliberatamente conservative — nel dubbio il segno resta.
  class SubstantiveEdit
    # Sotto questa quantità di parole entrate+uscite è una correzione, mai una riscrittura.
    MIN_CHANGED_WORDS = 5
    # Quota delle parole della pagina oltre cui la modifica è sostanziale (0.20 di parole
    # entrate+uscite = una parola su dieci sostituita).
    CHANGED_RATIO = 0.20
    # Un paragrafo riscritto conta sempre, anche dentro una pagina lunghissima.
    REWRITTEN_PARAGRAPH_WORDS = 40

    def self.call(before:, after:) = new(before, after).call

    def initialize(before, after)
      @before = words(before)
      @after = words(after)
    end

    def call
      changed = changed_words
      return false if changed < MIN_CHANGED_WORDS
      return true if changed >= REWRITTEN_PARAGRAPH_WORDS

      changed >= longest_text * CHANGED_RATIO
    end

    private

    # Parole entrate + parole uscite: differenza fra i due multinsiemi. Spostare un paragrafo senza
    # toccarne le parole non conta come riscrittura, ed è giusto — il testo dice le stesse cose.
    def changed_words
      before = @before.tally
      after = @after.tally
      (before.keys | after.keys).sum { |word| (before.fetch(word, 0) - after.fetch(word, 0)).abs }
    end

    def longest_text = [ @before.size, @after.size ].max

    # Solo lettere e numeri, minuscole: punteggiatura, maiuscole e spazi non spostano il significato.
    def words(text) = text.to_s.downcase.scan(/[\p{L}\p{N}]+/)
  end
end
