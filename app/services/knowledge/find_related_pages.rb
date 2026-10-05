# frozen_string_literal: true

module Knowledge
  # Pagine KB semanticamente correlate a un record (ticket o gruppo errori): usa l'embedding
  # già persistito del record (zero chiamate al servizio) oppure, se assente/stale-mai-calcolato,
  # embedda al volo il testo canonico. Scope = pagine collegate al PROGETTO del record o al suo
  # GRUPPO (il contesto conta: una guida di un altro progetto non aiuta il triage qui). Le pagine
  # org-wide (senza scope) sono ESCLUSE di proposito: sporcherebbero il pannello del ticket.
  class FindRelatedPages < ApplicationService
    # Una riga del pannello: la pagina e il motivo per cui è lì (Knowledge::MatchReason::Reason).
    Row = Data.define(:page, :reason)

    # CYRA-414 — righe mostrate. Tre: il pannello vive in una colonna già affollata, e cinque voci
    # quasi identiche si leggono come rumore.
    TOP_K = 3
    # Vicini interrogati prima del filtro di pertinenza: si scarta chi non sa dire perché è lì,
    # quindi serve pescare più largo di TOP_K per non lasciare il pannello mezzo vuoto.
    CANDIDATES = 10
    # La stessa soglia della ricerca sulla knowledge base: un risultato che lì non uscirebbe non ha
    # motivo di uscire qui. Riferita alla costante condivisa, non ricopiata: le soglie della ricerca
    # semantica si tarano in un punto solo (Embeddings::Relevance).
    MAX_DISTANCE = Embeddings::Relevance::MAX_DISTANCE

    def initialize(record:, client: nil)
      @record = record
      @client = client
    end

    def call
      # CYRA-168: se il record-sorgente porta ancora un vettore di versione superata (re-embed in
      # corso), il suo embedding NON è confrontabile coi vicini di versione corrente → degradiamo a
      # vuoto invece di mescolare. Verrà riembeddato a breve dal suo EmbedJob e il pannello tornerà.
      return Result.ok([]) if stale_source?

      vector = record_vector
      return vector if vector.err?

      Result.ok(rows(neighbours(vector.value)))
    end

    private

    def neighbours(vector)
      related_scope
        .where.not(embedding: nil).current_embedding
        .nearest_neighbors(:embedding, vector, distance: "cosine")
        .limit(CANDIDATES)
        .select { |page| page.neighbor_distance <= MAX_DISTANCE }
    end

    # CYRA-414: la vicinanza da sola non basta: passa solo la pagina che ha un aggancio dimostrabile
    # col record, e quell'aggancio diventa la spiegazione mostrata sulla riga. Niente aggancio =
    # niente riga (e se non ne resta nessuna, il pannello non compare affatto).
    def rows(pages)
      pages.filter_map do |page|
        reason = ::Knowledge::MatchReason.call(page: page, text: record_text)
        Row.new(page: page, reason: reason) if reason
      end.first(TOP_K)
    end

    # Pagine collegate al progetto del record O al suo gruppo. La query vive su
    # Knowledge::Page.related_to_project (CYRA-632): la condivide con la scrittura assistita dei
    # ticket, che pesca dalla stessa conoscenza — due copie divergerebbero alla prima modifica.
    def related_scope
      ::Knowledge::Page.related_to_project(@record.project)
    end

    # Sorgente stale = ha un embedding persistito ma di una versione diversa dalla corrente. Un
    # record senza embedding NON è stale: si embedda al volo il testo canonico (vettore corrente).
    def stale_source?
      @record.embedding.present? &&
        @record.embedding_version != Ai::Configuration.current.embedding_version
    end

    def record_vector
      return Result.ok(@record.embedding.to_a) if @record.embedding.present?

      Embeddings::EmbedText.call(text: canonical_text, client: @client)
    end

    # Testo canonico per record senza vettore: stesso testo della pipeline di embedding.
    def canonical_text
      case @record
      when Ticketing::Ticket then Ticketing::EmbeddingText.call(ticket: @record)
      when Errors::Group then Errors::EmbeddingText.call(group: @record)
      else raise ArgumentError, "record non embeddabile: #{@record.class}"
      end
    end

    # Testo del record per il confronto lessicale (CYRA-414): i SOLI contenuti scritti da chi ha
    # aperto il ticket o dal monitoraggio. Niente etichette fisse ("Titolo:", "Tipo:", "Given") come
    # nel testo canonico: aggancerebbero una pagina per una parola che non ha scritto nessuno.
    def record_text
      @record_text ||= case @record
      when Ticketing::Ticket
        [ @record.title, @record.description, @record.technical_analysis, *scenario_texts ].compact_blank.join("\n")
      when Errors::Group
        [ @record.title, @record.culprit ].compact_blank.join("\n")
      end
    end

    def scenario_texts
      @record.scenarios.flat_map do |scenario|
        [ scenario.title, *Ticketing::Scenario::STEP_FIELDS.map { |field| scenario.public_send(field) } ]
      end
    end
  end
end
