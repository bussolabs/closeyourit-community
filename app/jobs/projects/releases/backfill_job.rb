# frozen_string_literal: true

module Projects
  module Releases
    # Cleanup storico one-shot (CYRA-84): fonde le release-hash (create dall'ingest errori, `version` =
    # SHA del commit) nelle release-tag omologhe (create dalla CI, colonna `sha` valorizzata) che il
    # sistema non ha fatto convergere, così la lista Release di un progetto torna pulita. Itera SOLO le
    # coppie con match sicuro (stesso project+environment, `sha` del tag che inizia per la version
    # SHA-shaped della hash); un match ambiguo (una version su più tag) viene saltato e loggato, mai
    # fuso arbitrariamente. Idempotente e ri-eseguibile: a fusione avvenuta la riga hash sparisce e la
    # coppia non si ripresenta → va rilanciato a fine rollout per assorbire le app aggiornate dopo.
    # Data-op distruttiva → si lancia a mano (`bin/rails runner`), MAI da migration o recurring.yml.
    class BackfillJob < ApplicationJob
      queue_as :batch

      # Il match sicuro richiede una version di almeno 7 char (una version SHA-shaped ne garantisce ≥7,
      # ma il guard resta esplicito: 6 char di prefisso sarebbero troppo pochi per identificare il commit).
      MIN_VERSION_LENGTH = 7

      # dry_run: true elenca le coppie e i conteggi che verrebbero spostati SENZA mutare nulla.
      def perform(dry_run: false)
        stats = { merged: 0, ambiguous: 0, moved_events: 0 }

        project_ids_with_tags.each do |project_id|
          process_project(project_id, dry_run:, stats:)
        end

        Rails.logger.info(
          "[Projects::Releases::BackfillJob] dry_run=#{dry_run} " \
          "merged=#{stats[:merged]} ambiguous=#{stats[:ambiguous]} moved_events=#{stats[:moved_events]}"
        )
        stats
      end

      private

      # Solo i progetti con almeno una release-tag (sha valorizzato) hanno coppie da fondere.
      def project_ids_with_tags
        Projects::Release.where.not(sha: nil).distinct.pluck(:project_id)
      end

      def process_project(project_id, dry_run:, stats:)
        releases = Projects::Release.where(project_id: project_id).to_a
        tags = releases.select { |release| release.sha.present? }
        hashes = releases.select { |release| release.sha.blank? && release.version_sha_shaped? }
        return if tags.empty? || hashes.empty?

        hashes.each do |sha_release|
          candidates = matching_tags(tags, sha_release)
          next if candidates.empty?

          # Una version che inizia per più di uno sha di tag è ambigua: non c'è un pairing certo,
          # meglio lasciarla osservabile che fondere nel tag sbagliato.
          if candidates.size > 1
            stats[:ambiguous] += 1
            log_ambiguous(sha_release, candidates)
            next
          end

          apply_merge(candidates.first, sha_release, dry_run:, stats:)
        end
      end

      # Un tag matcha quando: stesso environment, e il suo `sha` inizia per la version SHA-shaped della
      # release-hash (≥7 char) — equivalente a LOWER(tag.sha) LIKE version || '%'.
      def matching_tags(tags, sha_release)
        version = sha_release.version.to_s.downcase
        return [] if version.length < MIN_VERSION_LENGTH

        tags.select do |tag|
          tag.id != sha_release.id &&
            tag.environment == sha_release.environment &&
            tag.sha.to_s.downcase.start_with?(version)
        end
      end

      def apply_merge(tag_release, sha_release, dry_run:, stats:)
        stats[:merged] += 1
        stats[:moved_events] += sha_release.events_count

        if dry_run
          Rails.logger.info(
            "[Projects::Releases::BackfillJob] dry_run would merge project=#{sha_release.project_id} " \
            "#{sha_release.version} → #{tag_release.version} " \
            "(#{sha_release.events_count} events, env=#{sha_release.environment})"
          )
        else
          Projects::Releases::Merge.call(tag_release: tag_release, sha_release: sha_release)
        end
      end

      def log_ambiguous(sha_release, candidates)
        Rails.logger.warn(
          "[Projects::Releases::BackfillJob] ambiguous match project=#{sha_release.project_id} " \
          "version=#{sha_release.version} matches tags=#{candidates.map(&:version).join(',')} — skipped"
        )
      end
    end
  end
end
