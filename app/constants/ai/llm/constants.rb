# frozen_string_literal: true

module Ai
  module Llm
    # Parametri del fornitore generativo: LiteLLM davanti a vLLM sul server AI di casa (CYRA-765).
    # Nessun magic value nei service (rules/constants.md).
    module Constants
      # Alias LiteLLM (config del proxy sul DGX), non un nome HuggingFace. `vlm-fast` è Qwen3.8-27B
      # SENZA ragionamento: con `vlm` il modello spende il budget di token a pensare e risponde vuoto
      # (misurato il 2026-09-02: 1200 token di reasoning, zero testo). Un alias sbagliato dà
      # 400 "Invalid model name", non un errore di rete.
      MODEL = "vlm-fast"

      # Whisper alias on the gateway; it accepts only 16 kHz mono PCM WAV (verified 2026-10-01). CYRA-908
      TRANSCRIPTION_MODEL = "whisper"

      # Prosa per un umano (assistente): un po' di varietà. Estrazioni strutturate: nessuna.
      TEMPERATURE = 0.2
      STRUCTURED_TEMPERATURE = 0.0

      MAX_OUTPUT_TOKENS = 1024
      STRUCTURED_MAX_OUTPUT_TOKENS = 2048

      # Il DGX genera ~18 token/s per richiesta e ne serve 4 in parallelo, poi mette in coda: una
      # bozza da 3000 token può volerci 3 minuti. Il tetto è alto di proposito, ed è per questo che le
      # funzioni lunghe girano in coda e non in una richiesta web.
      #
      # L'apertura è larga (CYRA-766, era 5 s): è una macchina di casa, e se è spenta il primo
      # sintomo è l'handshake che non parte — non un handshake lento. Il read è l'attesa fra un pezzo
      # e l'altro dello stream, non la durata totale: il tetto TOTALE lo mette chi chiama, con
      # `deadline_seconds` (Knowledge::Constants::REVIEW_DEADLINE_SECONDS).
      OPEN_TIMEOUT_SECONDS = 10
      READ_TIMEOUT_SECONDS = 300
    end
  end
end
