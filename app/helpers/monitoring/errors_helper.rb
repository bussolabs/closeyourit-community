# frozen_string_literal: true

module Monitoring
  # Come si legge UN errore in pagina: il livello, lo stato di triage, quando è successo l'ultima
  # volta e i valori che non cambiano mai nella pagina che si sta guardando. I grafici stanno in
  # ChartsHelper, i valori oscurati in ScrubbingHelper (CYRA-742).
  module ErrorsHelper
    # Livello Sentry → colore BadgeComponent (palette nativa). Valore ignoto → gray.
    LEVEL_COLORS = {
      "debug" => :gray, "info" => :sky, "warning" => :amber, "error" => :orange, "fatal" => :red
    }.freeze

    # Stato di triage → colore BadgeComponent.
    STATUS_COLORS = { "unresolved" => :amber, "resolved" => :emerald, "ignored" => :gray }.freeze

    def error_level_color(level) = LEVEL_COLORS.fetch(level.to_s, :gray)

    # CYRA-388 — il livello si LEGGE in italiano accanto a stati italiani («error» accanto a «Non
    # risolto» era metà inglese e metà no), ma il VALORE resta quello dell'SDK: è la chiave che
    # viaggia nei filtri in URL e che i client mandano, e tradurla romperebbe entrambi. Un livello
    # fuori vocabolario si mostra com'è arrivato, senza inventare una traduzione.
    def error_level_label(level) = t("member.monitoring.levels.#{level}", default: level.to_s)
    def error_status_color(status) = STATUS_COLORS.fetch(status.to_s, :gray)

    def error_time_ago(time)
      return "—" if time.blank?

      t("member.monitoring.time_ago", time: time_ago_in_words(time))
    end

    # CYRA-883 — the list's short form ("35d ago"): the column stays narrow, the exact time goes in
    # the tooltip. Whole minutes, hours or days, never zero.
    def error_time_ago_short(time)
      return "—" if time.blank?

      seconds = Time.current - time
      unit, size = if seconds < 1.hour then [ :minutes, 1.minute ]
      elsif seconds < 1.day then [ :hours, 1.hour ]
      else [ :days, 1.day ]
      end
      t("member.monitoring.list.ago_short.#{unit}", count: [ (seconds / size).floor, 1 ].max)
    end

    # CYRA-380: dicitura «non tracciato» per la colonna/chip "Utenti" quando il gruppo non ha MAI ricevuto
    # il contesto utente (Errors::Group#user_context_tracked? falso). Un "0"/"—" farebbe leggere «nessuno
    # colpito» quando invece il dato non è mai stato inviato: è un link alla guida errori, dove si spiega
    # come popolarlo. Muted e corsivo come error_scrubbed_tag — non è un conteggio reale.
    # CYRA-821 — `_top`: nella lista questo link sta dentro il frame dei risultati, e la guida
    # aprirebbe una pagina intera al posto delle righe. Fuori dai frame l'attributo è inerte.
    def error_users_untracked_link(test_id: nil, classes: nil)
      link_to t("member.monitoring.users_untracked"), member_guides_errors_path,
              class: [ "italic text-gray-400 dark:text-zinc-500 hover:text-indigo-600 dark:hover:text-indigo-400 hover:underline", classes ].compact.join(" "),
              title: t("member.monitoring.users_untracked_tip"),
              data: { test: test_id, turbo_frame: "_top" }.compact
    end

    # CYRA-986 — the tabs of one occurrence, in order. A tab exists only when it has something to
    # show; the stack trace, the replay and the logs always do (the last two say why when empty).
    def error_occurrence_tabs(event)
      context = event.context
      user = event.payload["user"]
      keys = [ :stack ]
      keys << :details if error_occurrence_rows(event).any?
      keys << :user if user.is_a?(Hash) && user["id"].present?
      keys << :tags if context["tags"].is_a?(Hash) && context["tags"].any?
      keys << :context if [ context["extra"], context["contexts"]&.except("runtime") ].any? { it.is_a?(Hash) && it.any? }
      (keys + %i[replay logs]).map { |key| { key:, label: t("member.monitoring.occurrence_tabs.#{key}") } }
    end

    # Transaction, server, runtime, OS, app and SDK of one occurrence: only the rows it has.
    # CYRA-379: a scrubbed SDK name makes the version alone meaningless, so only the token is shown.
    def error_occurrence_rows(event)
      sdk = event.payload["sdk"]
      sdk_label = if sdk.is_a?(Hash)
        error_scrubbed?(sdk["name"]) ? sdk["name"] : [ sdk["name"], sdk["version"] ].compact.join(" ").presence
      end
      {
        t("member.monitoring.env_transaction") => event.payload["transaction"].presence,
        t("member.monitoring.env_server") => event.server_name.presence,
        t("member.monitoring.env_runtime") => event.runtime.presence,
        t("member.monitoring.env_os") => [ event.os_name, event.os_version ].compact.join(" ").presence,
        t("member.monitoring.env_app") => event.app_version.presence,
        t("member.monitoring.env_sdk") => sdk_label
      }.compact
    end

    # CYRA-400 — i valori che non cambiano MAI nella pagina di occorrenze che si sta guardando:
    # si dicono una volta sola in cima e la loro colonna sparisce dalla tabella, invece di ripetere
    # quindici volte lo stesso ambiente e lo stesso rilascio da quaranta caratteri.
    #
    # Si guarda la PAGINA, mai l'intero gruppo: un gruppo può avere ottantatré pagine e cambiare
    # ambiente o rilascio fuori da qui — un riepilogo che parlasse a nome di tutte direbbe il falso.
    # E si guarda la pagina INTERA, non le sole cinque righe mostrate: la riga che smentisce il
    # riepilogo può essere una di quelle ancora chiuse dietro il comando.
    #
    # Un valore assente su tutte (release mai dichiarata) non è un'informazione: resta fuori dal
    # riepilogo e la sua colonna resta al suo posto, col trattino. Sotto le due occorrenze non c'è
    # niente da riassumere.
    OCCURRENCE_CONSTANT_ATTRIBUTES = %i[environment release level].freeze

    def error_occurrence_constants(events)
      events = Array(events)
      return {} if events.size < 2

      OCCURRENCE_CONSTANT_ATTRIBUTES.filter_map { |attribute|
        values = events.map { |event| event.public_send(attribute) }.uniq
        [ attribute, values.first ] if values.size == 1 && values.first.present?
      }.to_h
    end
  end
end
