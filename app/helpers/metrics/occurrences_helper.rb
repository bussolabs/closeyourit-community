# frozen_string_literal: true

module Metrics
  # Il dettaglio di UNA occorrenza, letto dal payload del campione: bind della query, punto del
  # codice, SDK che l'ha mandata, conteggio delle query del verdetto. Tutto opt-in lato client:
  # assente finché la cattura non è attiva sul progetto, e la vista mostra il trattino (CYRA-742).
  module OccurrencesHelper
    def occurrence_payload(occ) = occ&.payload.is_a?(Hash) ? occ.payload : {}

    # Bind SQL (slow_query) o argomenti metodo (slow_method): array di { "name" =>, "value" => }.
    def occurrence_bindings(occ) = Array(occurrence_payload(occ)["bindings"] || occurrence_payload(occ)["arguments"])

    # Call-site privacy-safe: "source" diretto, oppure "file:lineno".
    def occurrence_source(occ)
      payload = occurrence_payload(occ)
      return payload["source"] if payload["source"].present?
      return nil if payload["file"].blank?

      [ payload["file"], payload["lineno"] ].compact.join(":")
    end

    def occurrence_db_system(occ) = occurrence_payload(occ)["db_system"]

    # Etichetta SDK leggibile "nome versione" dal blocco `sdk` del payload (Hash Sentry-compatibile
    # {name, version}, come lo estrae Metrics::Ingest::Normalize) — mai l'Hash grezzo via Hash#to_s.
    # Retrocompat: se è già una stringa la ritorna così com'è; Hash vuoto/assente → nil (la vista mostra "—").
    #
    # FOLLOW-UP (client): il nome dell'SDK può arrivare redatto ("[FILTERED]") dallo scrubber CLIENT-SIDE
    # della gemma, non da uno scrub server. Come Projects::Source scarta le fonti col nome redatto, qui il
    # placeholder andrebbe normalizzato/nascosto — l'intervento va fatto nel client (gemma), non lato server.
    def occurrence_sdk(occ)
      sdk = occurrence_payload(occ)["sdk"]
      return sdk.presence if sdk.is_a?(String)
      return nil unless sdk.is_a?(Hash)

      [ sdk["name"], sdk["version"] ].compact.join(" ").presence
    end

    # Conteggio query del verdetto (n_plus_one/high_query_count) dal payload del campione.
    def occurrence_query_count(occ) = occurrence_payload(occ)["query_count"]

    # Host esterno (slow_external_http) dal payload del campione.
    def occurrence_http_host(occ) = occurrence_payload(occ)["http_host"]
  end
end
