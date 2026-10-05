# frozen_string_literal: true

module Agents
  # In che stato è UNA macchina che lavora i ticket e cosa sta facendo adesso: online, ferma da troppo,
  # occupata, in attesa. Colori Tailwind LITERAL (mai interpolati), come nel resto della sezione
  # (CYRA-742).
  module StatusHelper
    # Mappa lo stato osservabile (Agents::Host#activity_status) sul colore del design system, valido sia
    # per Ui::BadgeComponent (riga lista) sia per Ui::StatLabelComponent (chip show).
    HOST_STATUS_COLORS = {
      "online" => :emerald,
      "offline" => :gray,
      "busy" => :indigo,
      "waiting" => :amber,
      "recovery_required" => :red
    }.freeze

    # CYRA-450 — un host fermo (offline oltre la soglia di allarme) sale a rosso "Fermo": il grigio offline
    # non distingueva un host a riposo da uno rotto. Lo stale prevale sull'activity_status (già "offline").
    def agent_host_status_color(host)
      return :red if agent_host_stale?(host)

      HOST_STATUS_COLORS.fetch(host.activity_status, :gray)
    end

    def agent_host_status_label(host)
      return t("member.agents.status.stale") if agent_host_stale?(host)

      t("member.agents.status.#{host.activity_status}")
    end

    # CYRA-450 — l'host tace da oltre la soglia di allarme: riga evidenziata, badge "Fermo", avviso. Diverso
    # da #agent_host_stalled? (una singola run dichiarata mentre l'host è offline). La soglia vive nel model.
    def agent_host_stale?(host)
      host.heartbeat_stale?
    end


    # Il dot "respira" solo quando l'host sta davvero eseguendo (busy): stato semantico, motion-safe.
    def agent_host_status_pulse?(host)
      host.activity_status == "busy"
    end

    # Timestamp relativo ("3 minuti fa") — nil → trattino. Gemello di servers_helper#server_time_ago.
    def agent_host_time_ago(time)
      return "—" if time.blank?

      t("member.agents.time_ago", time: time_ago_in_words(time))
    end

    # Riepilogo compatto dell'attività per la riga: "CYRA-31 · autopilot" (+N se più run). CYRA-450: senza
    # run dichiarate ripiega su "In attesa di lavoro" — la cella non è MAI vuota, così un host a riposo non
    # si confonde con uno rotto. Legge observable_active_runs (host offline → run marcate stalled, gestite dal
    # partial). Niente N+1: active_runs è una colonna jsonb dell'host.
    def agent_host_activity_summary(host)
      runs = host.observable_active_runs
      return t("member.review_fixes.agent_unavailable") if runs.empty? && host.activity_status == "offline"
      return t("member.agents.activity.idle") if runs.empty?

      first = runs.first
      label = [ first["ticket"], first["phase"] ].reject(&:blank?).join(" · ")
      extra = runs.size - 1
      extra.positive? ? "#{label} +#{extra}" : label
    end

    # CYRA-999 — why the machine last stopped before taking work; the Automator lists stops oldest first.
    def agent_host_last_stop_reason(host)
      host.last_stops.last&.dig("reason")
    end

    # Almeno una run dichiarata dall'host è stalled (host offline) → marker ambra nella lista.
    def agent_host_stalled?(host)
      host.observable_active_runs.any? { |run| run["stalled"] }
    end

    # Etichetta "avviata N fa" per una run (sezione Attività della show). `started_at` è una stringa
    # iso8601 dichiarata dall'host: parse difensivo → nil se assente o malformata.
    def agent_run_started_label(run)
      raw = run["started_at"]
      return nil if raw.blank?

      time = raw.is_a?(Time) ? raw : Time.zone.parse(raw.to_s)
      return nil if time.nil?

      t("member.agents.activity.started_ago", time: time_ago_in_words(time))
    rescue ArgumentError, TypeError
      nil
    end
  end
end
