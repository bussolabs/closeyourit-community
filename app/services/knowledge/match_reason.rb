# frozen_string_literal: true

module Knowledge
  # PERCHÉ questa pagina è collegata a questo record (CYRA-414). Funzione pura, zero query: prende i
  # termini che IDENTIFICANO la pagina (titolo + etichette) e cerca quali compaiono anche nel testo
  # del record; se nessuno aggancia, guarda i titoli di sezione del contenuto.
  #
  # Serve a due cose insieme, ed è la stessa cosa vista da due lati: dare alla riga una spiegazione
  # in poche parole, e scartare i suggerimenti che una spiegazione non ce l'hanno. La sola distanza
  # coseno lasciava passare pagine visibilmente fuori tema (una decisione sui backup proposta a un
  # ticket di tutt'altro argomento): un pannello che sbaglia in modo evidente perde credibilità in
  # fretta, meglio nessuna riga che una riga sbagliata.
  #
  # Ritorna una Reason oppure nil (nessun aggancio dimostrabile). Il confronto è per RADICE dei
  # termini, così singolare e plurale si riconoscono ("errore" ↔ "errori") senza uno stemmer.
  class MatchReason < ApplicationService
    Reason = Data.define(:terms, :section)

    # Quanti termini mostrare: oltre tre la spiegazione diventa un elenco da leggere.
    MAX_TERMS = 3
    # Sotto le 4 lettere non si identifica nulla (articoli, preposizioni, sigle).
    MIN_LENGTH = 4
    # Prefisso confrontato: taglia le desinenze italiane più comuni senza appiattire parole diverse
    # ("backup" e "backfill" restano distinti, "errore" ed "errori" no).
    ROOT_LENGTH = 5
    # Titolo di sezione mostrato fin qui: oltre, la spiegazione occuperebbe due righe.
    MAX_SECTION_CHARS = 60
    # Heading markdown del contenuto (`## Ripristino del database`).
    HEADING = /\A\s{0,3}\#{1,6}\s+(.+?)\s*\#*\s*\z/

    # Parole di servizio: comuni a qualunque testo, non dicono di cosa parla la pagina. Solo forme da
    # 4 lettere in su (le più corte cadono già per MIN_LENGTH) e senza accenti (il confronto avviene
    # sulla parola normalizzata).
    STOPWORDS = %w[
      agli alla alle allo allora anche ancora altra altre altri altro
      come cosa cose dagli dalla dalle dallo degli della delle dello deve devono dopo dove
      essere fare fatta fatto loro meno mentre molto
      negli nella nelle nello nostro ogni oltre perche pero prima puo quale quali quando
      quella quelle quelli quello questa queste questi questo quindi
      senza serve servono solo sono sopra sotto stata state stati stato sugli sulla sulle sullo
      tutta tutte tutti tutto usare usato viene vengono vostro
      about been could from have here into more must only should some such than that
      them then there these this those very what when where which will with would your their
    ].freeze

    def initialize(page:, text:)
      @page = page
      @text = text.to_s
    end

    def call
      terms = matching_terms
      return Reason.new(terms: terms.first(MAX_TERMS), section: nil) if terms.any?

      section = matching_section
      section ? Reason.new(terms: [], section: section) : nil
    end

    private

    # Radici presenti nel testo del record: l'insieme contro cui si misura ogni termine della pagina.
    def record_roots
      @record_roots ||= roots(tokenize(@text))
    end

    # Termini della pagina agganciati, nell'ordine in cui si leggono: prima quelli del titolo (è il
    # nome con cui la pagina si presenta), poi le etichette. Un termine per radice: "errore" ed
    # "errori" nello stesso titolo sono la stessa spiegazione detta due volte.
    def matching_terms
      seen = Set.new
      page_terms.select do |term|
        root = root_of(term)
        record_roots.include?(root) && seen.add?(root)
      end
    end

    def page_terms
      tokenize(@page.title.to_s) + Array(@page.tags).flat_map { |tag| tokenize(tag.to_s) }
    end

    # Prima sezione del contenuto che parla di qualcosa presente nel record. Il titolo della sezione
    # è già una spiegazione in poche parole: «ne parla la sezione Ripristino del database».
    def matching_section
      @page.body.to_s.each_line do |line|
        heading = line[HEADING, 1]
        next if heading.blank?

        return heading.truncate(MAX_SECTION_CHARS) if roots(tokenize(heading)).intersect?(record_roots)
      end
      nil
    end

    # Parole significative, nella forma in cui si leggono (accenti compresi: la spiegazione mostra
    # «attività», non «attivita»). Il filtro lavora sulla parola normalizzata.
    def tokenize(text)
      text.downcase.scan(/[[:alnum:]]+/).select do |word|
        plain = strip_accents(word)
        plain.length >= MIN_LENGTH && STOPWORDS.exclude?(plain)
      end
    end

    def roots(words) = words.to_set { |word| root_of(word) }

    def root_of(word) = strip_accents(word.downcase)[0, ROOT_LENGTH]

    def strip_accents(word) = word.unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
  end
end
