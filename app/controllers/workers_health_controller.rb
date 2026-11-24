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
#
# `queue` lo decidono SOLO le corsie (CYRA-1229): è "stalled" se almeno una corsia è ferma, e
# `stalled_lanes` dice quali. `ready_count` e `last_finished_at` sono i numeri globali, rimasti come
# informazione. `stalled_lanes` sta prima di loro perché il guardiano copia nell'avviso solo l'inizio
# della risposta: il nome della corsia ferma deve finirci dentro.
#
# `ready_count` si ferma a Ops::QueueThroughput::READY_COUNT_CAP e `ready_count_capped` dice quando
# l'ha raggiunto (CYRA-1273): contare tutta la coda a ogni chiamata pubblica costava di più proprio a
# coda piena. Per lo stesso motivo `stalled_lanes` legge una sola riga per coda, la testa, e mai tutta la
# coda. Le chiamate ripetute dallo stesso indirizzo, GET o HEAD, le frena `workers_health/ip` (rack_attack).
class WorkersHealthController < ActionController::Base
  def show
    heartbeat = Ops::WorkerLiveness.last_heartbeat_at
    workers_up = heartbeat.present?

    stalled_lanes = Ops::QueueThroughput.stalled_lanes
    queue_stalled = stalled_lanes.any?
    ready_count = Ops::QueueThroughput.ready_count

    render json: {
      workers: workers_up ? "up" : "down",
      last_heartbeat_at: heartbeat&.iso8601,
      queue: queue_stalled ? "stalled" : "up",
      stalled_lanes:,
      ready_count:,
      ready_count_capped: Ops::QueueThroughput.ready_count_capped?(ready_count),
      last_finished_at: Ops::QueueThroughput.last_finished_at&.iso8601
    }, status: workers_up && !queue_stalled ? :ok : :service_unavailable
  end
end
