# frozen_string_literal: true

module CronsHelper
  # Chiavi della palette di Ui::BadgeComponent: un colore fuori palette diventa grigio in silenzio.
  CRON_STATUS_COLORS = { "ok" => "emerald", "late" => "amber", "missed" => "red", "failing" => "red",
                         "unknown" => "gray" }.freeze

  def cron_status_color(status) = CRON_STATUS_COLORS.fetch(status.to_s, "gray")

  # Cadenza nell'unità più grande che la divide: «ogni giorno», non «ogni 1440 min».
  def cron_interval_label(minutes)
    return t("member.crons.every_days", count: minutes / 1_440) if minutes.positive? && (minutes % 1_440).zero?
    return t("member.crons.every_hours", count: minutes / 60) if minutes.positive? && (minutes % 60).zero?

    t("member.crons.every_minutes", n: minutes)
  end
  # CYRA-485 — l'indirizzo a cui un lavoro batte. `request.base_url` e non una costante: chi legge la
  # pagina la sta guardando dall'host giusto, e un indirizzo scritto a mano invecchia al primo cambio
  # di dominio. Nell'indirizzo NON c'è nessun segreto: il progetto è un identificativo pubblico e
  # l'autorizzazione viaggia nell'intestazione, col token di ingest del progetto.
  def cron_check_in_url(project, slug)
    "#{request.base_url}/api/v1/projects/#{project.id}/crons/#{slug}/check_in"
  end

  # Il comando pronto da copiare. Il token resta un segnaposto: qui dentro non si stampa mai il
  # valore di una credenziale, nemmeno di una che chi guarda potrebbe già vedere altrove.
  def cron_check_in_curl(project, slug, failing: false)
    body = failing ? %( -d 'status=fail' -d 'reason=Backup fallito: disco pieno') : ""
    [ "curl -X POST #{cron_check_in_url(project, slug)} \\",
      "  -H 'Authorization: Bearer <token di ingest del progetto>'#{body}" ]
  end
end
