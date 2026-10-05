# frozen_string_literal: true

module Projects
  module Releases
    # Fonde una release-hash (nata dall'ingest, `version` = SHA del commit) nella release-tag omologa
    # (nata dalla CI, colonna `sha` valorizzata) che il sistema non ha fatto convergere (CYRA-84). In
    # transazione con lock delle due righe: ri-etichetta la telemetria dalla version-SHA a quella-tag,
    # fonde i contatori nella riga tag e rimuove la riga hash. Il pairing lo decide il chiamante
    # (Projects::Releases::BackfillJob): qui si esegue la fusione di UNA coppia già scelta.
    class Merge < ApplicationService
      # Le tabelle di telemetria (errors_events, logs_entries) si ri-etichettano in batch per non
      # tenere lock enormi su tabelle grandi.
      BATCH_SIZE = 1_000

      # Le 4 colonne "release" di errors_groups. Nessuna ha environment (a differenza di events/logs):
      # il tag è lo stesso cross-env, quindi si filtra solo per project + release.
      GROUP_RELEASE_COLUMNS = %i[release first_seen_release regressed_in_release resolved_in_release].freeze

      def initialize(tag_release:, sha_release:)
        @tag_release = tag_release
        @sha_release = sha_release
      end

      def call
        Projects::Release.transaction do
          # Lock delle due righe. La riga hash può essere già stata fusa (idempotenza: doppio run del
          # backfill, o chiamata ripetuta) → non c'è più nulla da fondere, no-op sicuro.
          tag = Projects::Release.lock.find_by(id: @tag_release.id)
          sha = Projects::Release.lock.find_by(id: @sha_release.id)
          return Result.ok(tag) if sha.nil? || tag.nil?

          relabel_events(sha, tag)
          relabel_logs(sha, tag)
          relabel_groups(sha, tag)
          merge_counters(tag, sha)
          sha.destroy!
          Result.ok(tag)
        end
      end

      private

      # errors_events ha environment: migrano SOLO le occorrenze dello stesso ambiente del tag (lo
      # stesso commit deployato su staging e production resta separato). In batch per lock contenuti.
      def relabel_events(sha, tag)
        Errors::Event
          .where(project_id: tag.project_id, environment: tag.environment, release: sha.version)
          .in_batches(of: BATCH_SIZE) { |batch| batch.update_all(release: tag.version) }
      end

      # logs_entries ha environment: stessa logica degli eventi.
      def relabel_logs(sha, tag)
        Logs::Entry
          .where(project_id: tag.project_id, environment: tag.environment, release: sha.version)
          .in_batches(of: BATCH_SIZE) { |batch| batch.update_all(release: tag.version) }
      end

      # errors_groups NON ha environment: il tag è lo stesso cross-env → filtro solo project + release,
      # su tutte e 4 le colonne che portano una version.
      def relabel_groups(sha, tag)
        GROUP_RELEASE_COLUMNS.each do |column|
          Errors::Group
            .where(project_id: tag.project_id, column => sha.version)
            .update_all(column => tag.version)
        end
      end

      # events_count SOMMATO: gli eventi possono essere stati potati dalla retention (Errors::
      # PruneEventsJob), quindi una COUNT sottostimerebbe — il contatore no. first_event_at = min,
      # last_event_at = max, nil-safe come track_event! (COALESCE/LEAST/GREATEST).
      def merge_counters(tag, sha)
        tag.update!(
          events_count: tag.events_count + sha.events_count,
          first_event_at: [ tag.first_event_at, sha.first_event_at ].compact.min,
          last_event_at: [ tag.last_event_at, sha.last_event_at ].compact.max
        )
      end
    end
  end
end
