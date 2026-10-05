# frozen_string_literal: true

module Servers
  # In che stato è UNA macchina e cosa sta succedendo alla coda dei suoi comandi. Solo lo stato: i
  # numeri delle metriche, i grafici e i formati vivono nelle altre parti (CYRA-742).
  module StatusHelper
    STATUS_COLORS = { "pending" => :gray, "up" => :emerald, "down" => :red, "paused" => :amber }.freeze

    def server_status_color(host)
      return :gray if host.revoked?
      # CYRA-461: fra attiva e spenta c'è il caso pericoloso — raggiungibile ma muta da un po'.
      return :amber if host.silent?

      STATUS_COLORS.fetch(host.status, :gray)
    end

    def server_status_label(host)
      return t("member.servers.status.revoked") if host.revoked?
      return t("member.servers.status.silent") if host.silent?

      t("member.servers.status.#{host.status}")
    end

    # Azioni operative: lo stato grezzo dell'enum non è leggibile ("queued") e soprattutto non dice la
    # cosa che serve sapere — che l'agent ritira il comando al giro di poll successivo, quindi fino a un
    # minuto di attesa è normale e non significa che l'azione sia fallita.
    # CYRA-809 — "interrotta" in ambra e non nel grigio delle concluse: il grigio dice «archiviata,
    # non ti riguarda più», e questa è l'unica riga che chiede di guardare la macchina, perché il
    # comando può essere andato a segno come no.
    ACTION_STATUS_COLORS = {
      "queued" => :amber, "running" => :sky, "succeeded" => :emerald,
      "failed" => :red, "cancelled" => :gray, "expired" => :gray, "interrupted" => :amber
    }.freeze

    def server_action_status_color(action) = ACTION_STATUS_COLORS.fetch(action.status, :gray)

    def server_action_status_label(action) = t("member.servers.action_queue.statuses.#{action.status}")

    # Riga in chiaro sotto il nome dell'azione: dove si trova adesso e da quando. Il caso che conta è
    # `queued`, l'unico in cui l'utente vede "non sta succedendo niente" senza sapere che è previsto.
    def server_action_detail(action)
      case action.status
      when "queued"
        t("member.servers.action_queue.details.queued", time: l(action.created_at, format: :short))
      when "running"
        t("member.servers.action_queue.details.running", time: l(action.started_at || action.created_at, format: :short))
      when "succeeded"
        t("member.servers.action_queue.details.succeeded", time: server_action_finished_at(action))
      when "failed"
        t("member.servers.action_queue.details.failed", time: server_action_finished_at(action), code: action.exit_code)
      when "cancelled"
        t("member.servers.action_queue.details.cancelled", time: server_action_finished_at(action))
      when "interrupted"
        t("member.servers.action_queue.details.interrupted",
          time: l(action.started_at || action.created_at, format: :short))
      else
        t("member.servers.action_queue.details.expired")
      end
    end

    # finished_at è sempre valorizzato da Actions::Complete e dall'annullamento, ma una riga storica
    # incoerente non deve far fallire il rendering della pagina.
    def server_action_finished_at(action) = l(action.finished_at || action.updated_at, format: :short)

    # CYRA-461 — un numero senza età non è verificabile quando la sorgente può tacere. Su una macchina
    # silenziosa la scala semantica si spegne (grigio): il colore dice "questo valore è vero adesso", e
    # su una fotografia vecchia direbbe una cosa falsa con l'aria di essere sicura.
    def server_value_color(host, pct)
      return "text-gray-400 dark:text-zinc-500" if host.silent?

      server_pct_color(pct)
    end

    # L'età del dato, accanto ai numeri e non in fondo alla riga: "3 minuti fa".
    def server_data_age_text(host)
      age = host.data_age
      return nil if age.nil?

      t("member.servers.data_age", time: distance_of_time_in_words(age))
    end
  end
end
