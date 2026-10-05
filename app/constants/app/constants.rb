# frozen_string_literal: true

module App
  # Costanti applicative non-secret (rules/constants.md). I valori per-ambiente vanno su CloseYourIt.
  #
  # Qui sta SOLTANTO ciò che non appartiene a nessun dominio: le lingue dell'interfaccia, le densità
  # di pagina e i tetti degli allegati, che i concern Attachable e Iconable applicano a oggetti di
  # domini diversi. Tutto il resto vive nel file del proprio dominio — Accounts::Constants,
  # Servers::Constants, Analytics::Constants e così via (CYRA-743) — e ci torna anche quello che
  # nascesse qui per comodità: un file che raccoglie le costanti di dodici domini si legge scorrendo
  # quelle degli altri undici.
  module Constants
    # Lingue dell'interfaccia (preferenza utente; default en). Whitelist condivisa da validazione
    # account, switch_locale dell'area member e selettore preferenze. Allineata a config.i18n (en + it).
    LOCALES = %w[en it].freeze

    # Righe per pagina nelle tabelle-lista della UI (paginazione offset nativa, vedi Pagination).
    TABLE_PER_PAGE = 12

    # Page-size di default del contratto API/CLI (read non paginata: ultimi N). Scollegato dalla UI
    # (TABLE_PER_PAGE) così cambiare la densità delle tabelle web non altera il contratto macchina.
    API_PAGE_SIZE = 25

    # Contatore caratteri dei campi di testo lunghi (Stimulus char-counter): quota del massimo oltre
    # cui l'indicatore avvisa (ambra). Sta qui e non in un dominio perché la soglia è una scelta di
    # interfaccia condivisa — la usano il form Knowledge e il form Ticket con tetti diversi. Il tetto
    # per campo vive invece nel dominio (Knowledge::Constants, Ticketing::Constants).
    LENGTH_WARN_RATIO = 0.8

    # Allegati (ticket, commenti, chat): dimensione massima per file. I video hanno VIDEO_MAX_SIZE.
    ATTACHMENT_MAX_SIZE = 10.megabytes

    # Content-type ammessi per gli allegati (immagini + PDF + testo). Vedi concern Attachable.
    #
    # text/markdown accanto a text/plain e non al suo posto: Marcel sniffa un .md come text/markdown,
    # ma lo STESSO contenuto salvato .txt arriva come text/plain, e un'allowlist che ne accetta uno
    # solo rifiuta il file a seconda di come chi lo manda l'ha chiamato. È il canale con cui un
    # ticket porta l'analisi tecnica lunga senza sfondare il tetto del campo (CYRA-260).
    #
    # Niente stored XSS come per svg/html: gli allegati non-immagine sono serviti con
    # `disposition: :attachment` sia dal web (member/tickets/_attachments.html.erb) sia dalla CLI
    # (cli/v1/tickets/attachments_controller.rb) — il browser li scarica, non li esegue.
    # Video (screen recording di un bug, clip da telefono): tetto proprio, più alto di quello
    # generale, perché anche pochi secondi di .mov pesano più di 10 MB. Lista VERIFICATA contro
    # Marcel: .mov → video/quicktime, .mp4/.m4v → video/mp4, .webm/.mkv/.avi i rispettivi.
    # Sono serviti inline (initializer active_storage.rb) perché il tag <video> non riproduce un
    # file forced-download; un video non è un vettore di script, quindi non riapre lo stored XSS.
    # L'upload passa dal server Rails, non diretto su S3: il tetto tiene occupato un processo.
    VIDEO_MAX_SIZE = 20.megabytes
    VIDEO_CONTENT_TYPES = %w[
      video/mp4 video/quicktime video/webm video/x-matroska video/x-msvideo
    ].freeze

    ATTACHMENT_CONTENT_TYPES = (%w[
      image/png image/jpeg image/gif image/webp application/pdf text/plain text/markdown
    ] + VIDEO_CONTENT_TYPES).freeze

    # Documenti di progetto (Projects::Document): limite più largo degli allegati ticket —
    # qui viaggiano spec, contratti, export, zip. È anche la base degli allegati delle pagine KB
    # (Knowledge::Constants::ATTACHMENT_CONTENT_TYPES), che vi aggiunge i tipi script.
    DOCUMENT_MAX_SIZE = 25.megabytes

    # Content-type ammessi per i documenti: allowlist ampia (pdf, office OOXML/ODF, testo, immagini,
    # zip). text/plain resta: Marcel a volte risolve csv/md così. application/zip assorbe gli sniff
    # edge dei formati office zip-based. NIENTE svg/html (stored XSS, stesso rationale di ICON_IMAGE).
    DOCUMENT_CONTENT_TYPES = (%w[
      application/pdf
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
      application/vnd.openxmlformats-officedocument.presentationml.presentation
      application/vnd.oasis.opendocument.text
      application/vnd.oasis.opendocument.spreadsheet
      application/vnd.oasis.opendocument.presentation
      text/plain text/csv text/markdown
      image/png image/jpeg image/gif image/webp
      application/zip
    ] + VIDEO_CONTENT_TYPES).freeze

    # Icona-immagine di progetto/gruppo (concern Iconable): limite più stretto degli allegati.
    # SOLO raster: l'icona è servita inline same-origin (EntityMarkComponent) e un SVG può contenere
    # <script> → stored XSS. Niente image/svg+xml senza sanitizzazione + Content-Disposition attachment.
    ICON_IMAGE_MAX_SIZE = 1.megabyte
    ICON_IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  end
end
