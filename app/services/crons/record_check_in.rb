# frozen_string_literal: true

module Crons
  # Registra un check-in del job: crea il monitor al primo ping (zero config, upsert per slug),
  # crea il CheckIn immutabile, aggiorna last_check_in_at + stato (ok/late) e chiude un eventuale
  # missed precedente. Result pattern. Idempotenza non necessaria (ogni ping È un evento distinto).
  class RecordCheckIn < ApplicationService
    def initialize(project:, slug:, status: "ok", duration_ms: nil, reason: nil, name: nil,
                   expected_interval_minutes: nil, grace_minutes: nil, environment: nil, at: Time.current)
      @project = project
      @slug = slug.to_s.strip.downcase
      @status = status.to_s == "fail" ? "fail" : "ok"
      @duration_ms = duration_ms
      # CYRA-484 — il motivo del fallimento, in parole. Tagliato alla lunghezza della colonna: un
      # messaggio di errore può essere lunghissimo e un check-in non deve fallire per questo.
      @reason = reason.to_s.strip.presence&.truncate(Crons::CheckIn::REASON_MAX_CHARS)
      @name = name
      @expected_interval_minutes = expected_interval_minutes
      @grace_minutes = grace_minutes
      @environment = environment
      @at = at
    end

    def call
      return Result.err(AppError.new("slug obbligatorio", code: "R422-CRON-001")) if @slug.blank?

      outcome = ApplicationRecord.transaction do
        monitor = @project.cron_monitors.find_or_initialize_by(slug: @slug)
        created = monitor.new_record?
        created ? configure_new_monitor(monitor) : monitor.lock!
        current = current_snapshot?(monitor)
        configure_existing_monitor(monitor) if current && !created
        unless monitor.save
          next Result.err(AppError.new(monitor.errors.full_messages.to_sentence, code: "R422-CRON-001",
                                                                               details: monitor.errors.to_hash))
        end

        check_in = monitor.check_ins.create!(status: @status, duration_ms: @duration_ms,
                                             reason: @reason, checked_in_at: @at)
        # CYRA-696 — lo stato lo decide l'ESITO del check-in, non il suo arrivo. Prima qui c'era
        # `status: :ok` fisso: un lavoro che parte puntuale e fallisce ogni volta restava verde per
        # sempre, e l'unico evento cron esistente (`cron_missed`) copre il caso opposto — il lavoro
        # che non parte. `missed_alerted_at` si azzera comunque: il check-in è arrivato, quindi il
        # ciclo del «mancato» è chiuso anche quando il lavoro è finito male.
        if current
          monitor.update!(last_check_in_at: @at, status: monitor_status, missed_alerted_at: nil)
        end
        { monitor:, check_in:, current: }
      end
      return outcome if outcome.is_a?(Result)

      monitor = outcome.fetch(:monitor)
      check_in = outcome.fetch(:check_in)
      broadcast_realtime(monitor, check_in) if outcome.fetch(:current)
      Result.ok(monitor)
    end

    private

    def monitor_status = @status == "fail" ? :failing : :ok

    # Broadcast Turbo: replace riga lista + pill org-wide, prepend check-in + replace header nella show.
    def broadcast_realtime(monitor, check_in)
      ActiveRecord.after_all_transactions_commit do
        # Il callback di un commit precedente può riprendere dopo quello successivo. Il row lock
        # serializza commit e broadcast; il reload implicito scarta lo snapshot ormai superato.
        monitor.with_lock do
          next if check_in.checked_in_at < monitor.last_check_in_at

          Crons::Broadcast.row(monitor)
          Crons::Broadcast.stats(@project.organization)
          Crons::Broadcast.check_in(monitor, check_in)
          Crons::Broadcast.labels(monitor)
        end
      end
    end

    # Primo check-in: defaults sensati. Il lock della transazione protegge poi snapshot/config dai
    # completamenti fuori ordine; gli eventi immutabili vengono comunque conservati tutti.
    def configure_new_monitor(monitor)
      monitor.name = @name.presence || @slug
      monitor.expected_interval_minutes = @expected_interval_minutes.presence || 60
      monitor.grace_minutes = @grace_minutes.presence || 5
      monitor.environment = resolved_environment
    end

    def configure_existing_monitor(monitor)
      monitor.name = @name if @name.present?
      monitor.expected_interval_minutes = @expected_interval_minutes if @expected_interval_minutes.present?
      monitor.grace_minutes = @grace_minutes if @grace_minutes.present?
    end

    def current_snapshot?(monitor)
      monitor.last_check_in_at.nil? || @at >= monitor.last_check_in_at
    end

    def resolved_environment
      return nil if @environment.blank?

      @project.organization.environments.find_by(code: @environment.to_s) ||
        @project.organization.environments.find_by(id: @environment)
    end
  end
end
