# frozen_string_literal: true

module Replays
  module Ingest
    # Aggancia i chunk rrweb alle sessioni di replay: raggruppa per replay_session_id, fa upsert della
    # Replays::Session (idempotente su [project_id, replay_session_id]) e allega ogni chunk gzippato su
    # ActiveStorage. NON ispeziona gli eventi (opachi, masking PII già applicato dal client). I chunk
    # senza id o senza eventi vengono scartati.
    class Record < ApplicationService
      def initialize(project:, chunks:)
        @project = project
        @chunks = Array.wrap(chunks)
      end

      def call
        @chunks
          .select { |chunk| valid?(chunk) }
          .group_by { |chunk| chunk["replay_session_id"].to_s }
          .each { |session_id, group| record_group(session_id, group) }
        Result.ok
      end

      private

      def valid?(chunk)
        chunk.is_a?(Hash) && chunk["replay_session_id"].to_s.present? &&
          chunk["events"].is_a?(Array) && chunk["events"].any?
      end

      # Prima il caricamento dei byte, poi la riga: `build_entry` carica ogni finestra su
      # ActiveStorage FUORI dal lock (CYRA-793), così la sezione serializzata di append_chunks! resta
      # un aggancio e non aspetta la rete di un upload.
      #
      # Il prezzo di quell'ordine è che un lotto interrotto a metà — un caricamento che non riesce,
      # l'aggancio che solleva — lascia file già caricati che nessuna sessione nomina, e ActiveStorage
      # non li pota da sé: prima li caricava dentro il salvataggio, quindi un errore non lasciava
      # niente dietro. `entries` si riempie una finestra alla volta apposta: se il caricamento cade a
      # metà, in mano restano quelle già salite, che sono proprio quelle da buttare.
      def record_group(session_id, group)
        session = find_or_create_session(session_id, group.first)
        entries = []
        group.each { |chunk| entries << build_entry(session, chunk) }
        session.append_chunks!(entries, paths: paths_of(group), ended_at: Time.current)
        discard_orphans(entries)
      rescue Replays::LimitExceeded
        discard_orphans(entries)
        Rails.logger.info("Replay chunks discarded: session budget exceeded")
      rescue StandardError
        discard_orphans(entries)
        raise
      end

      # Butta solo i file rimasti SENZA aggancio: se l'errore arriva a collegamento già scritto quel
      # file serve alla sessione. Una pulizia che fallisce non deve coprire l'errore vero, che è
      # quello che il job deve vedere per riprovare.
      def discard_orphans(entries)
        Array(entries).each do |entry|
          blob = entry[:blob]
          blob.purge if blob && blob.attachments.none?
        end
      rescue StandardError => e
        Rails.logger.warn("[replays] pulizia dei chunk non agganciati fallita: #{e.class}: #{e.message}")
      end

      # find-first + rescue sulla race di creazione concorrente (mirror di Errors::Ingest::Record).
      # Alla create: entry_path (prima pagina) e user_hash (identità, hashata) dal primo chunk.
      def find_or_create_session(session_id, first_chunk)
        @project.replay_sessions.find_or_create_by!(replay_session_id: session_id) do |session|
          session.started_at = parse_time(first_chunk["started_at"]) || Time.current
          session.environment = first_chunk["environment"].presence
          session.entry_path = path_of(first_chunk)
          session.user_hash = user_hash_of(first_chunk)
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # La race arriva anche come RecordInvalid: la validazione di unicità del modello vede la riga
        # che l'altra lavorazione ha appena committato, prima ancora che il database rifiuti l'insert.
        # Se la sessione ora esiste è quel caso e si prosegue con lei; altrimenti l'errore è vero.
        existing = @project.replay_sessions.find_by(replay_session_id: session_id)
        raise e unless existing

        existing
      end

      # Pagine visitate del lotto, in ordine di arrivo: il merge col set già salvato (e il tetto) lo
      # fa append_chunks! sotto lock, sui valori riletti. entry_path/user_hash NON si toccano dopo la
      # create.
      def paths_of(group)
        group.filter_map { |chunk| path_of(chunk) }
      end

      # Pathname senza query string/hash (difesa in profondità: il client lo manda già stripped).
      def path_of(chunk)
        chunk["path"].to_s.presence&.then { |path| path.split(/[?#]/).first }
      end

      # Identità utente hashata (SHA-256 troncato, parità con errors_events.user_hash) — mai id in chiaro.
      def user_hash_of(chunk)
        user = chunk["user"].to_s.presence
        Digest::SHA256.hexdigest(user)[0, 16] if user
      end

      # Il blob nasce già caricato sul servizio: dentro append_chunks! resta solo l'INSERT
      # dell'aggancio, che è l'unica cosa che ha davvero bisogno di essere serializzata.
      def build_entry(session, chunk)
        events = chunk["events"]
        raw = JSON.generate(events)
        raise Replays::LimitExceeded, "Replay chunk budget exceeded" if raw.bytesize > Constants::CHUNK_MAX_DECOMPRESSED_BYTES

        gz = ActiveSupport::Gzip.compress(raw)
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(gz),
          filename: "#{session.replay_session_id}-#{chunk['seq']}.json.gz",
          content_type: "application/gzip",
          metadata: { replay_uncompressed_bytes: raw.bytesize }
        )
        { blob: blob, events_count: events.size }
      end

      def parse_time(value)
        case value
        when Numeric then Time.zone.at(value)
        when String  then (Time.zone.parse(value) rescue nil)
        end
      end
    end
  end
end
