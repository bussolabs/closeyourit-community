# frozen_string_literal: true

module Replays
  # Costanti del dominio session replay (rules/constants.md).
  module Constants
    # Retention di default (giorni) dei replay (gerarchia god → org → progetto come i log; breve per
    # postura GDPR — un replay è PII pesante).
    RETENTION_DEFAULT_DAYS = 30
    # Massimo chunk per singolo POST /replays (oltre → R413). Il recorder invia poche finestre alla
    # volta (flush periodico), MAI centinaia in un colpo.
    MAX_BATCH = 50
    SESSION_MAX_CHUNKS = 120
    SESSION_MAX_EVENTS = 100_000
    SESSION_MAX_COMPRESSED_BYTES = 20.megabytes
    SESSION_MAX_DECOMPRESSED_BYTES = 40.megabytes
    CHUNK_MAX_COMPRESSED_BYTES = 3.megabytes
    CHUNK_MAX_DECOMPRESSED_BYTES = 2.megabytes
    # Massimo di pagine distinte tracciate per sessione (galleria comportamento). Il tetto vive qui e
    # non nell'ingest perché il merge delle pagine avviene sotto lock, dentro il modello (CYRA-793).
    PAGES_MAX = 50
  end
end
