# frozen_string_literal: true

module Logs
  # CYRA-348 — la chiave che rende «lo stesso messaggio» due righe che differiscono solo per i numeri:
  # un id, un tempo di risposta, un uuid. Senza, ventimila log restano ventimila righe e non si sa
  # quanti problemi diversi ci siano davvero.
  #
  # Le regole sono poche e dichiarate, non un algoritmo di somiglianza: due messaggi finiscono insieme
  # SOLO se, tolte le parti variabili note, sono identici. Meglio due gruppi che uno sbagliato — un
  # gruppo che mescola guasti diversi nasconde proprio quello che si sta cercando.
  class Fingerprint < ApplicationService
    # L'ordine conta: uuid e date prima dei numeri nudi, che altrimenti li spezzerebbero.
    # CYRA-730 — il pattern dell'istante è insensibile alle maiuscole perché il testo arriva qui GIÀ
    # in minuscolo (vedi #normalized): senza, la `T` del formato standard `2026-01-01T10:00:00Z` non
    # combaciava mai, e due righe identiche con orari diversi restavano due gruppi. Col separatore
    # spazio funzionava, con la T no — cioè proprio nella forma che scrivono quasi tutti i log.
    PLACEHOLDERS = [
      [ /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "<uuid>" ],
      [ /\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/i, "<time>" ],
      [ /\b\d{4}-\d{2}-\d{2}\b/, "<date>" ],
      [ /\b[0-9a-f]{32,}\b/i, "<hash>" ],
      [ /\b\d+(?:\.\d+)?(?:ms|s|kb|mb|gb)\b/i, "<duration>" ],
      [ /\b\d+(?:[.,]\d+)?\b/, "<n>" ]
    ].freeze

    def initialize(message:, level: nil)
      @message = message.to_s
      @level = level.to_s
    end

    # Il livello entra nell'impronta: lo stesso testo emesso come avviso e come errore è due cose
    # diverse per chi guarda, e va contato separatamente.
    def call
      Digest::SHA256.hexdigest("#{@level}|#{normalized}")
    end

    private

    def normalized
      PLACEHOLDERS.reduce(@message.strip.downcase) { |text, (pattern, replacement)| text.gsub(pattern, replacement) }
                  .squeeze(" ")
    end
  end
end
