# frozen_string_literal: true

require "digest"

module Ticketing
  # Testo canonico sottoposto al server AI per la valutazione di eleggibilità agenti (CYRA-184) +
  # checksum di staleness. Funzione pura come Ticketing::EmbeddingText, di cui è il gemello, con tre
  # differenze VOLUTE:
  #
  # 1. include le CONDIZIONI DoD. L'embedding le esclude per non diluire la semantica del problema;
  #    qui invece "il DoD dice: droppa la tabella" è esattamente il segnale che stiamo cercando.
  # 2. include un fingerprint degli ALLEGATI. Il rischio può stare solo nell'immagine (lo screenshot
  #    di una console di produzione), quindi aggiungere o togliere un allegato deve rendere stale la
  #    valutazione. Il fingerprint NON scarica i byte: il checksum MD5 del blob è già in
  #    active_storage_blobs, calcolato all'upload.
  # 3. porta il proprio PROMPT_VERSION dentro il digest, così cambiare il prompt di sistema fa
  #    divergere tutti i checksum e rivaluta il parco senza migration (leva gemella di
  #    Ai::Constants::EMBEDDING_VERSION).
  #
  # Etichette FISSE non-i18n: il verdetto non deve dipendere dalla lingua di chi ha aperto il ticket.
  class AgentEligibilityText
    # Bump = rivalutazione dell'intero parco. Da alzare ogni volta che cambia il SYSTEM_PROMPT di
    # Ticketing::EvaluateAgentEligibility o la forma di questo testo — con l'eccezione delle regole
    # che governano solo COME è scritta la motivazione e non il verdetto: la regola ortografica di
    # CYRA-411 non può cambiare un allowed in un blocked, e rivalutare l'intero parco per un accento
    # sarebbe una chiamata LLM per ticket senza nessun verdetto diverso in fondo.
    # Il nome cita il fornitore di allora e col CYRA-765 il fornitore è cambiato: la stringa resta
    # com'è di proposito. Alzarla è una rivalutazione dell'INTERO parco, cioè una chiamata al modello
    # per ogni ticket già valutato, e il cambio di motore da solo non è una richiesta di rifarlo.
    PROMPT_VERSION = "gemini-eligibility-v2"

    def self.call(ticket:)
      scenarios = Ticketing::BodyText.scenarios(ticket.scenarios)
      conditions = Ticketing::BodyText.conditions(ticket.conditions)
      [
        "Titolo: #{ticket.title}",
        "Tipo: #{ticket.kind}",
        ("Descrizione: #{ticket.description}" if ticket.description.present?),
        ("Scenari:\n#{scenarios}" if scenarios.present?),
        ("Condizioni di completamento:\n#{conditions}" if conditions.present?),
        ("Analisi tecnica: #{ticket.technical_analysis}" if ticket.technical_analysis.present?)
      ].compact.join("\n")
    end

    # Identità stabile del set di allegati. Ordine deterministico (created_at, id) così due ticket
    # con gli stessi file caricati in ordine diverso non divergono per caso; `blob.checksum` fa da
    # identità del contenuto, quindi ri-caricare lo stesso file con un nome nuovo cambia il
    # fingerprint (giusto: il nome è un indizio che il modello legge).
    def self.attachments_fingerprint(ticket:)
      ticket.files.includes(:blob).sort_by { |file| [ file.created_at, file.id ] }.map do |file|
        blob = file.blob
        [ blob&.filename.to_s, blob&.content_type.to_s, blob&.byte_size.to_i, blob&.checksum.to_s ].join("\0")
      end.join("\n")
    end

    def self.checksum(ticket:)
      Digest::SHA256.hexdigest(
        "#{PROMPT_VERSION}\n#{call(ticket: ticket)}\n#{attachments_fingerprint(ticket: ticket)}"
      )
    end
  end
end
