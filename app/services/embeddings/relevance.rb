# frozen_string_literal: true

module Embeddings
  # Soglie della ricerca semantica in UN posto solo. I tre domini che cercano per significato
  # (ticket, conoscenza, idee) sono cloni dichiarati l'uno dell'altro: tenere le stesse costanti
  # copiate in tre file significava correggere lo stesso difetto tre volte — o due su tre.
  #
  # Le soglie rispondono a due domande diverse:
  # - QUANTO lontano può stare un candidato (distanza coseno del retrieval), e
  # - QUANTO deve valere per essere mostrato (punteggio del cross-encoder).
  # La seconda è quella che mancava: senza, una parola inventata tornava comunque una lista di
  # risultati, presentati come se fossero pertinenti (CYRA-553).
  module Relevance
    # Candidati letti dal retrieval vettoriale (recall) prima del rerank.
    TOP_K = 50

    # Quanti candidati arrivano davvero al cross-encoder. È QUI che si spendevano i mezzi minuti:
    # il rerank costa lineare nel numero di documenti e nella loro lunghezza, e 50 documenti da
    # 700 caratteri su CPU sono 15-30 secondi di attesa con un thread web fermo ad aspettare.
    # Oltre il ventesimo candidato per somiglianza vettoriale un risultato pertinente non c'è
    # quasi mai; e chi cerca l'elenco esaustivo ha la modalità «parole esatte» nella barra.
    RERANK_TOP_N = 20

    # Testo per candidato passato al cross-encoder (titolo + corpo, clampati).
    RERANK_TEXT_CHARS = 400

    # Distanza coseno pgvector ∈ [0,2]: oltre questa soglia il candidato non c'entra più nulla.
    MAX_DISTANCE = 0.6

    # Soglia per le query di UNA parola. Una parola sola produce un vettore poco specifico: a 0.6
    # passava mezzo archivio, ed è il caso in cui la ricerca restituiva ticket senza rapporto con
    # quello che era stato scritto. La rete di sicurezza è il ramo testuale del chiamante (ibrido
    # semantico + parole esatte), che sulla parola singola è proprio la ricerca che funziona meglio.
    SHORT_QUERY_MAX_DISTANCE = 0.45

    # Fin dove una query si considera "corta" (numero di parole).
    SHORT_QUERY_WORDS = 1

    # Taglio di pertinenza sul punteggio del cross-encoder. Il servizio risponde SEMPRE, anche a
    # una stringa inventata: ordina i candidati e basta. Sotto questa soglia il documento non
    # c'entra, e va tolto invece di essere mostrato come risultato.
    # Robusta rispetto alla forma del punteggio: sia che il servizio normalizzi in [0,1] (i non
    # pertinenti stanno sotto 0.01), sia che riporti il logit grezzo del cross-encoder (i non
    # pertinenti sono negativi), 0.05 taglia il rumore e lascia passare i match veri.
    MIN_SCORE = 0.05

    # Soglia di distanza per questa query: più corta è, più stretta.
    def self.max_distance(query)
      return SHORT_QUERY_MAX_DISTANCE if query.to_s.split.size <= SHORT_QUERY_WORDS

      MAX_DISTANCE
    end

    # Posizioni (indici dei documenti passati al rerank) davvero pertinenti, nell'ordine deciso
    # dal cross-encoder. Lista vuota = nessuna corrispondenza, ed è una risposta legittima.
    def self.relevant_indexes(ranking)
      ranking.select { |item| item[:score].to_f >= MIN_SCORE }.map { |item| item[:index] }
    end
  end
end
