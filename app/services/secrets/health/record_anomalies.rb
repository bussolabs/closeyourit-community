# frozen_string_literal: true

module Secrets
  module Health
    # Osserva le anomalie correnti del Vault (i descrittori atomici di Secrets::HealthCheck#anomalies) e
    # ne aggiorna la memoria persistita (Secrets::HealthAnomaly), così ogni riga sa DA QUANDO esiste
    # (first_seen_at) e se qualcuno l'ha già marcata voluta (CYRA-409). Stesse transizioni di
    # Vulnerabilities::RecordFindings:
    #   - assente          → open, first_seen_at = ora (la vediamo per la prima volta);
    #   - presente          → last_seen_at = ora (e riapre se era `resolved`: è tornata vera);
    #   - sparita, era open  → resolved (non descrive più il Vault);
    #   - acknowledged        → MAI toccata dallo scan: la decisione «assenza voluta» resta, non si riapre
    #                          né si risolve da sola.
    #
    # Tutto in operazioni di BLOCCO (load + insert_all + update_all): un numero FISSO di query,
    # indipendente da quante anomalie/progetti — gira dentro la request (Member::Vault::HealthController),
    # dove il guard Prosopite sugli N+1 è bloccante. `project_ids` limita lettura e resolve ai soli
    # progetti VISIBILI passati: la visita di chi vede metà dei progetti non "risolve" le anomalie
    # dell'altra metà.
    #
    # Ritorna { identity => Secrets::HealthAnomaly } per le sole anomalie ATTIVE (open + acknowledged)
    # dei progetti passati — la mappa con cui la pagina arricchisce ogni riga corrente (first_seen +
    # stato ack), cercata con Secrets::HealthCheck::Anomaly#identity.
    class RecordAnomalies < ApplicationService
      def initialize(organization:, anomalies:, project_ids:, now: Time.current)
        @organization = organization
        @anomalies = anomalies
        @project_ids = project_ids
        @now = now
      end

      def call
        incoming = @anomalies.index_by(&:identity)
        existing = Secrets::HealthAnomaly.for_projects(@project_ids).to_a

        touch_present(existing, incoming)
        insert_new(existing, incoming)
        resolve_disappeared(existing, incoming)

        Result.ok(reload_active)
      end

      private

      def identity_of(record)
        [ record.project_id, record.environment_id, record.kind.to_sym, record.secret_name ]
      end

      # Esistenti ancora presenti: last_seen aggiornato; se erano `resolved` tornano `open`. Le
      # `acknowledged` restano tali (aggiorno solo last_seen, non lo stato).
      def touch_present(existing, incoming)
        present = existing.select { |record| incoming.key?(identity_of(record)) }
        return if present.empty?

        Secrets::HealthAnomaly.where(id: present.map(&:id))
          .update_all(last_seen_at: @now, updated_at: @now)

        reopen_ids = present.select(&:status_resolved?).map(&:id)
        return if reopen_ids.empty?

        Secrets::HealthAnomaly.where(id: reopen_ids)
          .update_all(status: Secrets::HealthAnomaly.statuses[:open], resolved_at: nil, updated_at: @now)
      end

      # Anomalie correnti senza alcun record: nuove righe `open` con first_seen = ora. unique_by
      # sull'identità: due request concorrenti non fanno doppioni (ON CONFLICT DO NOTHING).
      def insert_new(existing, incoming)
        new_identities = incoming.keys - existing.map { |record| identity_of(record) }
        return if new_identities.empty?

        rows = new_identities.map do |identity|
          anomaly = incoming.fetch(identity)
          { organization_id: @organization.id, project_id: anomaly.project.id,
            environment_id: anomaly.environment.id, kind: Secrets::HealthAnomaly.kinds[anomaly.kind.to_s],
            secret_name: anomaly.secret_name, status: Secrets::HealthAnomaly.statuses[:open],
            first_seen_at: @now, last_seen_at: @now, created_at: @now, updated_at: @now }
        end
        Secrets::HealthAnomaly.insert_all(rows, unique_by: :index_secrets_health_anomalies_on_identity)
      end

      # Era `open` e non è più tra le correnti: `resolved`. Le `acknowledged` non si toccano.
      def resolve_disappeared(existing, incoming)
        gone_ids = existing.select do |record|
          record.status_open? && !incoming.key?(identity_of(record))
        end.map(&:id)
        return if gone_ids.empty?

        Secrets::HealthAnomaly.where(id: gone_ids)
          .update_all(status: Secrets::HealthAnomaly.statuses[:resolved], resolved_at: @now, updated_at: @now)
      end

      def reload_active
        Secrets::HealthAnomaly.active.for_projects(@project_ids)
          .includes(:acknowledged_by).to_a
          .index_by { |record| identity_of(record) }
      end
    end
  end
end
