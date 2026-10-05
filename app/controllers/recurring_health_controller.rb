# frozen_string_literal: true

# Liveness dei GIRI RICORRENTI (Solid Queue Scheduler), servita dal web come le sue gemelle. NON è
# `/up`: quello resta liveness PURA dell'app (Kamal/CI/Docker HEALTHCHECK), vedi
# knowledge-base/global/health-version.md.
#
# Perché esiste (CYRA-752): su staging i job girano dentro Puma e Sablier addormenta il contenitore
# appena nessuno lo usa, quindi i giri ricorrenti non partivano mai e una regressione su di essi
# arrivava intatta fino alla produzione. Il rilascio ora tiene sveglio lo staging per una finestra e
# interroga questo endpoint: senza una risposta letta da qualcuno, la sveglia farebbe girare i giri
# senza provare niente, e un run verde a giri fermi è peggio di nessun controllo.
#
# Pubblico e senza auth come /up, /version, /up/workers e /up/embedding → eredita da
# ActionController::Base per saltare auth e org context. Non espone nulla di sensibile.
class RecurringHealthController < ActionController::Base
  # Spento di proposito (:disabled) ≠ guasto: 200, così un'installazione senza giri ricorrenti può
  # rilasciare. Chi legge distingue dal campo `recurring` — e chi PRETENDE che i giri ci siano, come
  # la sveglia post-rilascio su staging, accetta solo `up`.
  HEALTHY = %i[up disabled].freeze

  def show
    status = Ops::RecurringSchedule.status

    render json: {
      recurring: status,
      last_run_at: Ops::RecurringSchedule.last_run_at&.iso8601,
      last_run_age_seconds: Ops::RecurringSchedule.last_run_age_seconds,
      tasks: Ops::RecurringSchedule.registered_count
    }, status: HEALTHY.include?(status) ? :ok : :service_unavailable
  end
end
