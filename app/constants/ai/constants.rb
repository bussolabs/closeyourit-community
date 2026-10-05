# frozen_string_literal: true

module Ai
  # Costanti dell'integrazione AI. Nessun magic value sparso nei service (rules/constants.md).
  #
  # I parametri del modello generativo vivono in Ai::Llm::Constants: dal CYRA-765 il fornitore è il
  # server AI di casa, uno solo e di sistema, e qui restano solo i parametri di embedding/rerank.
  # I CHAT_* del revisore knowledge (CYRA-764) sono spariti col secondo client: stesso proxy, stesso
  # alias, stessi parametri — un solo posto dove leggerli (CYRA-766).
  module Constants
    # ── Servizio embeddings/rerank: server AI di casa (LiteLLM davanti a vLLM sul DGX) ──
    # Endpoint OpenAI-compatible sincroni sotto EMBED_BASE_URL (che INCLUDE il prefisso /v1):
    # POST embeddings + POST rerank, Bearer AI_API_KEY (virtual key LiteLLM dedicata a CloseYourIt).
    # Dal CYRA-758 non gira più il container closeyourit-embedding (Infinity) su sentinel: 15 GB di
    # immagine per release su un disco da 80 GB, e lo stesso modello era già servito da casa.

    # Alias LiteLLM (config del proxy sul DGX), non un nome HuggingFace: `embed-small` è
    # Qwen/Qwen3-Embedding-0.6B (verificato il 2026-09-02: stesso testo, coseno 0,99995 con il
    # container Infinity). Cambiare alias lato proxy = 400 "Invalid model name" qui, e le funzioni
    # semantiche degradano in silenzio.
    EMBEDDING_MODEL = "embed-small"

    # Il rerank (cross-encoder) è OPZIONALE: l'alias arriva da ENV `EMBED_RERANK_MODEL` (in
    # produzione `rerank` = Qwen/Qwen3-Reranker-0.6B su vLLM) e, se manca, il client si ferma prima
    # di ogni chiamata e i chiamanti tengono l'ordine coseno. ATTENZIONE: il `/rerank` di LiteLLM
    # risponde 200 anche puntato a un modello di EMBEDDING, con un coseno che mette «ricetta della
    # pasta» davanti a «il server ha esaurito lo spazio» per «disco pieno» (provato il 2026-09-02):
    # un alias sbagliato non dà errore, dà ordini a caso. Meglio nessun rerank di uno sbagliato.
    module_function

    def rerank_model = ENV.fetch("EMBED_RERANK_MODEL", "").presence

    # Rerank alias served behind a CloseYourIt AI key (Ai::Configuration, CYRA-916).
    RERANK_MODEL = "rerank"

    # Dimensione nativa di Qwen3-Embedding-0.6B: la colonna pgvector è vector(1024).
    EMBEDDING_DIMENSIONS = 1024

    # Entra nel checksum di ogni embedding persistito: cambiare modello/preprocessing = bump di
    # versione → il backfill ri-embedda tutto da solo (checksum diverso), senza migration.
    # NON è cambiata col passaggio al DGX: il modello è lo stesso, i vettori salvati restano validi.
    EMBEDDING_VERSION = "qwen3-emb-0.6b-1024-v1"

    # Clamp del testo embeddabile: oltre non aggiunge segnale e gonfia la RAM del servizio
    # (max_seq 32k di Qwen3 — il warmup OOM insegna). ~6k char ≈ 1.5-2k token.
    EMBED_MAX_CHARS = 6_000

    # Timeout dedicati: l'embed della query di ricerca avviene sync a request-time → read corto.
    EMBED_OPEN_TIMEOUT_SECONDS = 5
    EMBED_READ_TIMEOUT_SECONDS = 15

    # Tetto di attesa del rerank quando lo chiede una RICERCA, cioè una persona ferma davanti a un
    # elenco (CYRA-553). Il cross-encoder è la parte cara: misurato a 15-30 secondi con un thread
    # web occupato per tutto il tempo, a un soffio dal timeout di un proxy. Scaduto il tetto la
    # ricerca risponde comunque, con l'ordine del retrieval vettoriale: precisione in meno, non
    # risultati in meno. Il RAG in coda (Ask) non passa di qui e tiene il read timeout lungo:
    # nessuno lo sta aspettando a schermo.
    RERANK_READ_TIMEOUT_SECONDS = 5

    # Richieste AI asincrone (Ai::Request): draft effimeri, prunati oltre questa età.
    REQUESTS_RETENTION = 1.day
  end
end
