# frozen_string_literal: true

module Assistant
  # Costanti dell'assistente help (rules/constants.md: nessun magic value nei service).
  module Constants
    # Quanti messaggi completi passati come contesto al server AI (memoria multi-turno). Cap per non far
    # crescere il prompt all'infinito: gli ultimi N in ordine cronologico.
    MAX_HISTORY_MESSAGES = 20

    # Retention delle conversazioni con l'assistente: oltre questo silenzio (ultima attività o
    # creazione) vengono potate dal job ricorrente. Sono aiuto effimero, non un archivio.
    RETENTION_DAYS = 30

    # Tetto alla lunghezza di un messaggio dell'utente: protegge DB e prompt del server AI (costi/rifiuti
    # upstream) da input abnormi. Un aiuto "come faccio X" sta in poche righe.
    MAX_MESSAGE_CHARS = 4_000

    # Ritardo prima di avviare il job di streaming. Al PRIMO invio il pannello viene rimpiazzato e il suo
    # turbo-frame deve montarsi e sottoscrivere lo stream della conversazione PRIMA che il job cominci a
    # broadcastare: senza questo margine un job veloce (o un fallimento immediato) manderebbe il replace
    # finale prima della sottoscrizione, lasciando la bolla eternamente "in scrittura" fino al reload.
    STREAM_START_DELAY = 0.5.seconds

    # Voice (CYRA-908). The browser stops at VOICE_MAX_SECONDS; 2 minutes of 16 kHz mono 16-bit WAV
    # is about 3.8 MB, so 10 MB leaves room without accepting arbitrary uploads.
    VOICE_MAX_SECONDS = 120
    MAX_AUDIO_BYTES = 10.megabytes
    AUDIO_CONTENT_TYPES = %w[audio/wav audio/x-wav audio/wave].freeze
    NOT_HEARD_CODE = "R422-ASSISTANT-005"
    NO_AUDIO_CODE = "R422-ASSISTANT-006"
    AUDIO_TOO_LARGE_CODE = "R413-ASSISTANT-001"
    AUDIO_TYPE_CODE = "R415-ASSISTANT-001"
  end
end
