# frozen_string_literal: true

module Alerting
  # CYRA-1228 — affida alla coda l'avviso di fermo di un server, di un cluster o di un lavoro
  # pianificato e ne segna la consegna. Punto UNICO: lo chiamano sia il controllo che ha appena
  # cambiato lo stato (Servers::CheckStaleJob, Clusters::CheckStaleJob, Crons::EvaluateJob) sia il
  # giro di recupero (Alerting::ReconcileOutages). Stesso schema di Uptime::Incidents::Announce:
  #
  #   1. il segno si scrive DOPO l'accodamento — scritto prima, un accodamento saltato (riavvio,
  #      coda guasta) lascerebbe l'avviso perso per sempre: il controllo non riguarda chi è già giù;
  #   2. accodamento e segno stanno sotto lock, con rilettura della riga — controllo e recupero
  #      girano su worker diversi: chi arriva secondo trova il segno e non accoda niente.
  #
  # La rilettura serve anche a non mentire: una macchina tornata su (o un lavoro che ha risposto)
  # prima dell'avviso non è più ferma, e non si annuncia.
  #
  # I controlli entrano da `declare`, che fa anche il cambio di stato sotto lock e con rilettura: due
  # esecutori che hanno caricato la stessa riga ancora up/ok non dichiarano più il fermo due volte —
  # il secondo, azzerando il segno appena scritto dal primo, riaccodava lo stesso avviso.
  class AnnounceOutage < ApplicationService
    # Soggetto → colonna che registra la consegna. Scritta qui e in nessun altro posto.
    MARKS = {
      "Servers::Host" => :down_alerted_at,
      "Clusters::Cluster" => :down_alerted_at,
      "Crons::Monitor" => :missed_alerted_at
    }.freeze
    # Soggetto → stato che dichiara il fermo.
    OUT_STATUS = {
      "Servers::Host" => :down,
      "Clusters::Cluster" => :down,
      "Crons::Monitor" => :missed
    }.freeze

    # Il controllo: dichiara il fermo e poi lo annuncia. true = questo esecutore l'ha dichiarato;
    # false = la riga, riletta sotto lock, non era più da dichiarare (già dichiarata da un altro
    # esecutore, o tornata sana) e non si tocca niente.
    def self.declare(subject:, at: Time.current)
      announcer = new(subject:, at:)
      return Result.ok(false) unless announcer.declare_out

      announcer.call
      Result.ok(true)
    end

    def initialize(subject:, at: Time.current)
      @subject = subject
      @at = at
    end

    # Stato + segno azzerato in una transazione propria, con commit PRIMA dell'avviso: se
    # l'accodamento cade, il fermo resta scritto col segno vuoto e lo consegna il giro di recupero
    # (non lo si ridichiara a ogni minuto).
    def declare_out
      mark = MARKS.fetch(@subject.class.name)
      declared = false
      @subject.class.transaction do
        record = @subject.class.lock.find(@subject.id)
        next unless still_due?(record)

        record.update!(status: OUT_STATUS.fetch(@subject.class.name), mark => nil)
        # L'oggetto del chiamante serve ai broadcast: prende lo stato nuovo senza perdere le
        # associazioni precaricate (un reload le scarterebbe).
        @subject.assign_attributes(status: record.status, mark => nil, updated_at: record.updated_at)
        @subject.clear_changes_information
        declared = true
      end
      declared
    end

    # true = accodato adesso, false = già annunciato da qualcun altro o non più fermo.
    def call
      mark = MARKS.fetch(@subject.class.name)
      announced = false
      # Riga nuova e non `with_lock` sull'oggetto del chiamante: il reload gli toglierebbe le
      # associazioni precaricate che i broadcast usano subito dopo.
      @subject.class.transaction do
        record = @subject.class.lock.find(@subject.id)
        next if record[mark].present? || !still_out?(record)

        notify(record)
        record.update!(mark => @at)
        announced = true
      end
      Result.ok(announced)
    end

    private

    # Da dichiarare: la stessa domanda del controllo, posta alla riga riletta sotto lock.
    def still_due?(record)
      case record
      when Servers::Host then Servers::Host.stale(@at).exists?(record.id)
      when Clusters::Cluster then Clusters::Cluster.stale.exists?(record.id)
      when Crons::Monitor then !record.status_missed? && record.overdue?(@at)
      end
    end

    def still_out?(record)
      case record
      when Servers::Host then record.status_down? && record.revoked_at.nil?
      when Clusters::Cluster then record.status_down? && !record.revoked?
      when Crons::Monitor then record.status_missed? && record.enabled?
      end
    end

    def notify(record)
      case record
      when Servers::Host
        Alerting::EvaluateJob.perform_later(
          event_type: "server_down", subject_type: "Servers::Host", subject_id: record.id,
          project_id: nil, organization_id: record.organization_id
        )
      when Clusters::Cluster
        Clusters::Alerts.notify(:cluster_down, subject: record, cluster: record)
      when Crons::Monitor
        Alerting::EvaluateJob.perform_later(
          event_type: "cron_missed", subject_type: "Crons::Monitor", subject_id: record.id,
          project_id: record.project_id, environment_id: record.environment_id
        )
      end
    end
  end
end
