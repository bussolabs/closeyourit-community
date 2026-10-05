# frozen_string_literal: true

module Knowledge
  # Costanti del dominio knowledge (rules/constants.md).
  module Constants
    # Tetto di lunghezza dei due campi di testo della pagina. Due ragioni, una di lettura e una
    # tecnica:
    #   - lettura: 4.000 caratteri ≈ 600 parole ≈ 3 minuti — una pagina, un'idea; quello che non ci
    #     sta va spezzato in più pagine dentro un Book (che ha già indice e ordinamento);
    #   - ricerca: Embeddings::EmbedText clampa il testo a Ai::Constants::EMBED_MAX_CHARS PRIMA di
    #     calcolare il vettore. Il testo canonico di Knowledge::EmbeddingText è
    #     titolo (≤255) + kind + BODY + TECH_SPEC + etichette (~50): con questi tetti resta sotto il
    #     budget, quindi NIENTE viene tagliato via dall'indice in silenzio. L'invariante è blindata
    #     da spec/services/knowledge/embedding_text_spec.rb: alzare un tetto senza alzare
    #     EMBED_MAX_CHARS fa fallire quel test, non la ricerca in produzione.
    BODY_MAX_CHARS = 4_000
    TECH_SPEC_MAX_CHARS = 1_500

    # Riga con cui chi propone una pagina in revisione spiega PERCHÉ la propone (CYRA-298). Si legge
    # nella coda di revisione accanto al titolo: è un'etichetta da scorrere, non un secondo corpo —
    # stesso tetto di un commento CLI. Non entra nel testo di embedding (vedi EmbeddingText).
    REVIEW_NOTE_MAX_CHARS = 240

    # "Chiedi alla KB" (CYRA-421): quante domande d'esempio il giro notturno semina per ogni progetto
    # (una per pagina, dalle più recenti) e quante se ne mostrano al massimo sopra il campo. La DoD
    # chiede "da quattro a sei": sei è il tetto, sotto le quattro si mostra comunque quello che c'è.
    SAMPLE_QUESTIONS_PER_PROJECT = 6
    SAMPLE_QUESTIONS_SHOWN = 6

    # Quante domande dello storico condiviso si mostrano in fondo alla pagina (le più recenti, senza
    # ripetere lo stesso testo): abbastanza da imparare dalle domande del team, non un archivio.
    ASK_HISTORY_SHOWN = 6

    # ── Revisore automatico delle pagine (CYRA-764) ──
    # I formati ammessi: ogni pagina ne dichiara UNO nella prima riga del corpo (`Formato: …`) e il
    # revisore la giudica con le regole di quel formato (app/prompts/knowledge/review.md, copia
    # macchina di knowledge-base/global/knowledge-formats.md). `unknown` non è un formato: è il
    # verdetto del modello quando non ne riconosce nessuno, e vale un rifiuto.
    REVIEW_FORMATS = %w[troubleshooting procedure test_access decision reference overview].freeze
    REVIEW_FORMAT_LABELS = {
      "troubleshooting" => "troubleshooting",
      "procedure" => "procedura",
      "test_access" => "accessi di test",
      "decision" => "decisione",
      "reference" => "riferimento",
      "overview" => "panoramica"
    }.freeze
    # Il kind che ogni formato pretende (regola K10): una guida che è in realtà un troubleshooting è
    # il difetto più diffuso del corpus (302 guide su 413 senza un comando, nell'analisi del 2026-09-02).
    REVIEW_FORMAT_KINDS = {
      "troubleshooting" => "note",
      "procedure" => "guide",
      "test_access" => "guide",
      "decision" => "decision",
      "reference" => "note",
      "overview" => "note"
    }.freeze
    # Il verdetto è corto (formato, esito, poche violazioni, il passaggio citato per ognuna): 900
    # token a ~25 token/secondo sono poco più di mezzo minuto. Il tetto TOTALE della chiamata
    # sincrona sta sotto i ~100 secondi dopo i quali Cloudflare chiude con un 524: oltre, chi salva
    # la pagina vedrebbe un errore muto. Era 600 prima delle citazioni (CYAU-200): con quelle un
    # verdetto lungo arrivava tagliato, e un JSON tagliato è un errore, non un giudizio.
    REVIEW_MAX_OUTPUT_TOKENS = 900
    REVIEW_DEADLINE_SECONDS = 70
    # Quanto può essere lungo il passaggio citato accanto a una violazione: una riga, quel tanto che
    # basta a ritrovarlo nella pagina.
    REVIEW_QUOTE_MAX_CHARS = 200
    # Per quanto si ricorda il giudizio di una domanda già fatta (CYAU-200). La stessa pagina,
    # inviata due volte, deve ricevere lo stesso esito: il modello non è ripetibile nemmeno a
    # temperatura zero, quindi la ripetibilità la mette qui l'applicazione. Nella chiave c'è tutto
    # ciò che determina il giudizio (regole, pagina, pagine vicine, schema): cambiata una virgola, è
    # una domanda nuova. La finestra è lunga perché non c'è ragione di richiedere lo stesso giudizio,
    # corta abbastanza da non tenere per sempre verdetti di regole nel frattempo riscritte.
    REVIEW_MEMORY_TTL = 30.days
    # Quante pagine vicine (per embedding) si mostrano al modello per il giudizio sul doppione.
    REVIEW_NEIGHBOURS = 5
    # Il minimo di tag (regola K11): 554 pagine su 598 non ne avevano nessuno.
    REVIEW_MIN_TAGS = 2
    # Quante violazioni entrano nel MESSAGGIO dell'errore: la CLI stampa solo `code: message`, e
    # tre righe bastano a capire cosa correggere; l'elenco intero viaggia nei `details`.
    REVIEW_VIOLATIONS_IN_MESSAGE = 3
    # Sopra questa soglia la parte tecnica è stata compressa per rientrare nel tetto (regola K12):
    # 49 pagine su 598 stavano entro 50 caratteri da 1.500, nessuna tagliata a metà frase.
    REVIEW_TECH_SPEC_SQUEEZED_CHARS = 1_450

    # ── Data di rilettura (CYRA-768) ──
    # Quanto vale una pagina prima che qualcuno la debba rileggere, PER TIPO. Una decisione invecchia
    # più in fretta di una guida: il sistema che descrive può essere dismesso, e la decisione resta
    # citata come se fosse ancora attuale. Una NOTA non scade affatto (nessuna voce qui): un appunto
    # non diventa falso, e riempire la coda di appunti la renderebbe inguardabile — che è il modo in
    # cui una coda smette di essere letta.
    #
    # Sono i default all'accettazione, non una regola per sempre: la data riparte a ogni riscrittura
    # del testo e a ogni conferma. Le finestre restano volutamente lunghe — la coda deve dire «questa
    # va guardata», non tenere occupata una persona.
    REVIEW_WINDOWS = { "decision" => 180.days, "guide" => 365.days }.freeze

    # Su quanti giorni Knowledge::BackfillReviewAfterJob spalma le pagine che, applicando la finestra
    # del tipo alla loro data, risulterebbero già scadute. Senza, il parco esistente entrerebbe in
    # coda tutto insieme il giorno del rilascio: centinaia di righe in un colpo, e nessuno le legge.
    REVIEW_BACKFILL_SPREAD_DAYS = 90

    # Allegati delle pagine KB (Knowledge::Attachment). Stesso tetto dei documenti di progetto: qui
    # viaggia la documentazione di supporto di una procedura (spec, export, archivi).
    ATTACHMENT_MAX_SIZE = 25.megabytes

    # Tipi "script/config" ammessi in AGGIUNTA ai documenti: una pagina KB descrive una procedura, e
    # lo script che la esegue è parte della documentazione. Sono byte inerti di solo storage — mai
    # eseguiti dal server (nessun interprete nell'immagine, vedi Dockerfile) e mai renderizzati dal
    # browser: l'initializer active_storage.rb li serve come application/octet-stream forced-download.
    #
    # Lista VERIFICATA contro Marcel 1.2.1 su file campione reali, non stimata: contiene solo tipi che
    # Marcel emette davvero. Lo shebang `#!` è un magic byte forte, quindi lo STESSO linguaggio cade in
    # due tipi diversi — un .rb/.py CON shebang è sniffato application/x-sh, SENZA shebang
    # text/x-ruby / text/x-python. Servono entrambe le forme, altrimenti metà degli script è rifiutata.
    #
    # NIENTE svg/html/xml, come App::Constants::DOCUMENT_CONTENT_TYPES e
    # App::Constants::ICON_IMAGE_CONTENT_TYPES: sono gli unici che il browser esegue da sé (stored
    # XSS). NIENTE application/octet-stream: è il tipo di fallback di Marcel per l'ignoto, ammetterlo
    # renderebbe l'allowlist un colabrodo.
    SCRIPT_CONTENT_TYPES = %w[
      application/x-sh
      text/x-ruby
      text/x-python
      text/javascript
      application/json
      text/x-yaml
      application/sql
      text/x-diff
      text/x-php
      text/x-java-source
      text/x-csrc
      application/x-tar
      application/gzip
    ].freeze

    ATTACHMENT_CONTENT_TYPES = (App::Constants::DOCUMENT_CONTENT_TYPES + SCRIPT_CONTENT_TYPES).freeze
  end
end
