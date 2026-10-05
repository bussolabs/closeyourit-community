# frozen_string_literal: true

module Datasets
  # Costanti del training/predict AI dei dataset (rules/constants.md). Le immagini viaggiano base64
  # inline nei messaggi LLM → sono pesanti in token: i cap tengono il costo sotto controllo.
  module Constants
    # Righe etichettate usate come esempi few-shot per costruire il prompt.
    SAMPLE_FEWSHOT_MAX = 6
    # Righe tenute da parte per valutare l'accuratezza (holdout).
    HOLDOUT_MAX = 8
    # Iterazioni del loop di raffinamento (build → evaluate → refine sugli errori).
    MAX_ITERATIONS = 2
    # Accuratezza overall oltre cui il loop si ferma (prompt già buono).
    TARGET_ACCURACY = 0.9
    # Numero massimo di immagini inline (base64) per singola chiamata LLM (budget token).
    MAX_INLINE_IMAGES = 6
    # Righe sample minime per poter allenare.
    MIN_SAMPLE_ROWS = 3
    # CYRA-791 — oltre questo silenzio (nessun battito, o nessuna partenza per un addestramento in
    # attesa) l'addestramento è dichiarato INTERROTTO. È lo stesso numero della durata del semaforo di
    # concorrenza di Datasets::TrainJob, che lo legge da qui: scaduto quello, Solid Queue lascerebbe
    # comunque partire un secondo lavoro sullo stesso insieme di dati, quindi dichiarare morto un
    # addestramento più corto sarebbe un rischio nuovo, e dichiararlo più tardi lascerebbe il dataset
    # bloccato mentre la coda ha già smesso di proteggerlo.
    TRAINING_STALE_AFTER = 2.hours
    # Esempi/errori testuali inclusi nel prompt di costruzione (contesto contenuto).
    PROMPT_EXAMPLES_MAX = 6
    PROMPT_MISTAKES_MAX = 8

    # Immagini delle celle foto, consumate dall'LLM vision. Solo raster serviti inline → niente
    # svg/html (stored XSS, stesso rationale di App::Constants::ICON_IMAGE_CONTENT_TYPES). Limite più
    # largo dell'icona: sono dati d'ingresso, non decorazioni.
    IMAGE_MAX_SIZE = 5.megabytes
    IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  end
end
