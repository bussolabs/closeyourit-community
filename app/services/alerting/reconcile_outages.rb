# frozen_string_literal: true

module Alerting
  # CYRA-1228 — consegna gli avvisi di fermo rimasti senza segno: server e cluster giù, lavori
  # pianificati mancati. Il controllo cambia lo stato PRIMA di accodare l'avviso, e un fermo già
  # segnato non viene più ripreso (giudica solo chi è ancora up / non mancato): se il processo cade
  # in quel varco, senza questo giro l'avviso è perso per sempre. Stesso schema, grazia, finestra e
  # tetto di Uptime::ReconcileAlerts.
  #
  # Solo ciò che è ANCORA fermo: una macchina tornata su (l'ingest la rimette up) o un lavoro che ha
  # risposto (il check-in azzera il segno e cambia lo stato) non ha più un fermo da annunciare.
  #
  # L'ora del fermo non è scritta da nessuna parte: si ricava dall'ultimo segnale ricevuto più la
  # soglia che fa scattare il controllo — è il momento in cui il controllo ha potuto vederlo.
  class ReconcileOutages < ApplicationService
    # Sotto la grazia la consegna normale del controllo è ancora in corso.
    GRACE = Uptime::ReconcileAlerts::GRACE
    # Oltre la finestra un fermo non annunciato non è più un allarme.
    WINDOW = Uptime::ReconcileAlerts::WINDOW
    # Tetto per giro e per tipo: un arretrato non diventa una raffica. Il giro dopo prende i restanti.
    BATCH = Uptime::ReconcileAlerts::BATCH

    # Scadenza di un lavoro pianificato: lo stesso conto di Crons::Monitor#deadline, in SQL.
    CRON_DEADLINE_SQL = "crons_monitors.last_check_in_at + " \
                        "make_interval(mins => crons_monitors.expected_interval_minutes + crons_monitors.grace_minutes)"

    def initialize(at: Time.current)
      @at = at
    end

    def call
      recovered = pending_hosts.sum { |host| deliver(host) }
      recovered += pending_clusters.sum { |cluster| deliver(cluster) }
      recovered += pending_monitors.sum { |monitor| deliver(monitor) }
      Result.ok(recovered)
    end

    private

    def pending_hosts
      Servers::Host.active.status_down.where(down_alerted_at: nil)
                   .where(last_push_at: window_shifted_by(Servers::Constants::STALE_AFTER_SECONDS.seconds))
                   .order(:last_push_at).limit(BATCH).to_a
    end

    def pending_clusters
      Clusters::Cluster.active.status_down.where(down_alerted_at: nil)
                       .where(last_snapshot_at: window_shifted_by(Clusters::Constants::STALE_AFTER_SECONDS.seconds))
                       .order(:last_snapshot_at).limit(BATCH).to_a
    end

    def pending_monitors
      Crons::Monitor.enabled.status_missed.where(missed_alerted_at: nil)
                    .where("#{CRON_DEADLINE_SQL} BETWEEN ? AND ?", window.begin, window.end)
                    .order(:last_check_in_at).limit(BATCH).to_a
    end

    def window = (@at - WINDOW)..(@at - GRACE)

    # Ultimo segnale = ora del fermo meno la soglia del controllo.
    def window_shifted_by(threshold) = (window.begin - threshold)..(window.end - threshold)

    def deliver(subject)
      Alerting::AnnounceOutage.call(subject: subject, at: @at).value ? 1 : 0
    rescue StandardError => e
      # La coda può essere ancora guasta: la riga resta pendente e il giro dopo riprova. Una riga che
      # esplode non si porta dietro le altre del lotto.
      Rails.logger.error("Alerting::ReconcileOutages: #{subject.class.name} #{subject.id} #{e.class}: #{e.message}")
      0
    end
  end
end
