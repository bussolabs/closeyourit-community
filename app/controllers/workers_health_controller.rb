# frozen_string_literal: true

# Liveness del MOTORE DEI JOB (Solid Queue), SERVITA DAL WEB (Puma) e perciò indipendente dal processo
# worker: se il worker si ferma il sito web risponde ancora, ma qui viriamo a 503 così un guardiano
# ESTERNO che interroga questo endpoint se ne accorge e allarma (CYRA-209 — il canale che non dipende
# dal processo fermo). NON è `/up`: quello resta liveness PURA dell'app (Kamal/CI/Docker HEALTHCHECK),
# vedi knowledge-base/global/health-version.md. Pubblico e senza auth come /up e /version → eredita da
# ActionController::Base per saltare auth e org context.
#
# `workers` e `queue` sono segnali INDIPENDENTI (CYRA-299): il worker può battere l'heartbeat e
# comunque non smaltire nulla (vedi Ops::QueueThroughput) — vanno riportati entrambi, 503 se uno solo
# dei due è giù.
class WorkersHealthController < ActionController::Base
  def show
    heartbeat = Ops::WorkerLiveness.last_heartbeat_at
    workers_up = heartbeat.present?

    ready_count = Ops::QueueThroughput.ready_count
    last_finished_at = Ops::QueueThroughput.last_finished_at
    queue_stalled = Ops::QueueThroughput.stalled?(ready_count:, last_finished_at:)

    render json: {
      workers: workers_up ? "up" : "down",
      last_heartbeat_at: heartbeat&.iso8601,
      queue: queue_stalled ? "stalled" : "up",
      ready_count:,
      last_finished_at: last_finished_at&.iso8601
    }, status: workers_up && !queue_stalled ? :ok : :service_unavailable
  end
end
