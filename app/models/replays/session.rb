# frozen_string_literal: true

module Replays
  # Una sessione di session replay: metadati + chunk rrweb (ActiveStorage, gzip). I
  # byte del replay stanno negli attachment; qui solo ciò che serve a lista/scoping/
  # retention. project_id denormalizzato (come Errors::Event) per query e prune per
  # progetto. Idempotente su [project_id, replay_session_id]: i chunk successivi si
  # agganciano alla stessa sessione. Join agli errori via replay_session_id (no FK).
  class Session < ApplicationRecord
    self.table_name = "replays_sessions"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :replay_sessions

    has_many_attached :chunks

    validates :replay_session_id, presence: true, uniqueness: { scope: :project_id }
    validates :started_at, presence: true

    scope :recent, -> { order(created_at: :desc) }
    scope :for_environment, ->(env) { where(environment: env) }
    scope :for_user, ->(hash) { where(user_hash: hash) }
    # Sessioni con almeno un errore correlato (EXISTS sull'indice [project_id, replay_session_id]).
    scope :with_errors, lambda {
      where(
        "EXISTS (SELECT 1 FROM errors_events e " \
        "WHERE e.project_id = replays_sessions.project_id " \
        "AND e.replay_session_id = replays_sessions.replay_session_id)"
      )
    }

    # Numero di pagine distinte visitate nella sessione.
    def pages_count = Array(pages).size

    # Errori correlati alla sessione (via replay_session_id, indice composito). Per la show; nell'index
    # usare un conteggio batch per evitare N+1.
    def errors_count
      Errors::Event.where(project_id: project_id, replay_session_id: replay_session_id).count
    end

    # Aggancia una o più finestre di eventi in UN solo attach + save (evita l'N+1 sugli
    # attachment quando arrivano più chunk in un batch) e aggiorna i metadati aggregati.
    # Ogni entry: { blob:, events_count: } — il blob arriva GIÀ caricato (CYRA-793: il
    # trasferimento dei byte sta fuori dal lock, qui resta solo la riga di collegamento).
    #
    # Tutto dentro `with_lock`: la coda :ingest lavora in parallelo le finestre della stessa
    # registrazione e ogni lavorazione ha in mano una COPIA della riga. `events_count +=` sulla
    # copia, il set delle pagine e perfino l'elenco degli allegati (che `attach` riscrive per
    # intero a partire da quello che ha letto) si calcolano su dati vecchi: l'ultimo salvataggio
    # cancellava il contributo dell'altro, chunk compresi. `with_lock` rilegge la riga
    # bloccandola, quindi il totale che si somma è quello vero e l'elenco allegati è completo.
    def append_chunks!(entries, paths: [], ended_at: nil)
      with_lock do
        existing = chunks.includes(:blob).limit(Constants::SESSION_MAX_CHUNKS + 1).to_a
        filenames = existing.map { |attachment| attachment.blob.filename.to_s }.to_set
        entries = entries.select { |entry| filenames.add?(entry.fetch(:blob).filename.to_s) }
        enforce_budget!(existing, entries)
        apply_pages(paths)
        self.events_count += entries.sum { |entry| entry[:events_count].to_i }
        if ended_at
          self.ended_at = ended_at
          self.duration_ms = ((ended_at - started_at) * 1000).to_i if started_at
        end
        # Dopo gli attributi, di proposito: il record risulta già modificato, così `attach` non
        # apre un secondo UPDATE per conto suo e tutto entra nel `save!` qui sotto.
        blobs = entries.filter_map { |entry| entry[:blob] }
        chunks.attach(blobs) if blobs.any?
        save!
      end
    end

    private

    def enforce_budget!(existing, entries)
      bytes = existing.sum { |attachment| attachment.blob.byte_size } + entries.sum { |entry| entry.fetch(:blob).byte_size }
      raw_bytes = (existing.map(&:blob) + entries.map { |entry| entry.fetch(:blob) }).sum do |blob|
        blob.metadata.fetch("replay_uncompressed_bytes", Constants::CHUNK_MAX_DECOMPRESSED_BYTES).to_i
      end
      count = events_count + entries.sum { |entry| entry[:events_count].to_i }
      return if existing.size + entries.size <= Constants::SESSION_MAX_CHUNKS &&
                count <= Constants::SESSION_MAX_EVENTS && bytes <= Constants::SESSION_MAX_COMPRESSED_BYTES &&
                raw_bytes <= Constants::SESSION_MAX_DECOMPRESSED_BYTES

      raise Replays::LimitExceeded, "Replay session budget exceeded"
    end

    # Set distinto delle pagine visitate (con tetto) e ultima pagina, calcolati sui valori RILETTI
    # sotto lock — è la lettura fresca a rendere il merge additivo invece che sostitutivo.
    def apply_pages(paths)
      paths = Array(paths).compact_blank
      return if paths.empty?

      self.pages = (Array(pages) + paths).uniq.first(Constants::PAGES_MAX)
      self.last_path = paths.last
    end
  end
end
