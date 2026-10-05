# frozen_string_literal: true

module Knowledge
  # Euristica NON bloccante ("linguaggio semplice") sul corpo di una pagina KB. NON è un gate né
  # analisi semantica: è un aiuto UX che suggerisce quando conviene spostare il gergo nella sezione
  # tecnica (tech_spec). Puro (niente Result/DB): riceve testo, ritorna un verdetto con i motivi
  # (simboli → chiavi i18n nella view). Soglie deliberatamente conservative e tarabili.
  class PlainLanguageCheck
    Verdict = Data.define(:reasons) do
      def simple? = reasons.empty?
      def complex? = reasons.any?
    end

    LONG_SENTENCE_WORDS = 25 # media parole/frase oltre cui il testo "pesa"
    LONG_WORD_CHARS = 13     # una parola oltre questa lunghezza è "difficile"
    LONG_WORD_RATIO = 0.12   # quota di parole difficili che fa scattare il segnale
    JARGON_THRESHOLD = 3     # oltre N termini gergali distinti → segnale
    # Gergo tecnico comune (IT/EN): lista breve e tarabile, non esaustiva.
    JARGON = %w[
      endpoint middleware webhook deploy deployment async asincrono backend frontend query
      migration runtime kubernetes cache token payload schema serializer fingerprint embedding
      pgvector idempotente commit rollback boolean nullable timestamp jsonb
    ].freeze

    def self.call(text:)
      new(text).call
    end

    def initialize(text)
      @text = text.to_s
    end

    def call
      reasons = []
      reasons << :code_block if code_block?
      reasons << :long_sentences if long_sentences?
      reasons << :long_words if long_words?
      reasons << :jargon if jargon?
      Verdict.new(reasons: reasons)
    end

    private

    def code_block? = @text.include?("```") || @text.match?(/`[^`]+`/)

    def long_sentences?
      sentences = @text.split(/[.!?]+/).map(&:strip).reject(&:empty?)
      return false if sentences.empty?

      average = sentences.sum { |sentence| word_count(sentence) }.to_f / sentences.size
      average > LONG_SENTENCE_WORDS
    end

    def long_words?
      words = @text.scan(/\p{L}+/)
      return false if words.empty?

      difficult = words.count { |word| word.length > LONG_WORD_CHARS }
      difficult.to_f / words.size > LONG_WORD_RATIO
    end

    def jargon?
      hits = JARGON.count { |term| @text.match?(/\b#{Regexp.escape(term)}\b/i) }
      hits > JARGON_THRESHOLD
    end

    def word_count(string) = string.scan(/\S+/).size
  end
end
