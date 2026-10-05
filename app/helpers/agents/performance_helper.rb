# frozen_string_literal: true

module Agents
  # I RIQUADRI del rendimento di una macchina: quali mostrare, in che ordine e cosa scrive ciascuno
  # sotto il numero. Stanno qui e non nella vista perché sono lo stesso elenco di misure del confronto
  # fra macchine, e due elenchi separati divergerebbero alla prima aggiunta (CYRA-742).
  module PerformanceHelper
    # CYRA-499 — i riquadri del rendimento, nell'ordine, SENZA quelli che non hanno un valore da
    # mostrare. Un riquadro che dice sempre «—» occupa un quinto della riga senza rispondere a niente,
    # e chi legge conclude che il sistema non stia misurando. Stanno qui e non nella vista per la
    # stessa ragione di agent_compare_rows: è un elenco di misure solo, e due copie divergerebbero.
    def agent_performance_tiles(performance, previous)
      tiles = [ agent_tickets_tile(performance, previous), agent_rejected_tile(performance, previous) ]
      tiles << agent_host_time_tile(performance, previous) if performance.host_time?
      tiles << agent_workflow_time_tile(performance, previous) if performance.workflow_time?
      tiles << agent_cost_tile(performance, previous) if performance.cost.any?
      tiles
    end

    # La griglia si stringe sul numero di riquadri rimasti: cinque colonne con tre riquadri lascerebbero
    # due buchi in fondo alla riga. Classi LETTERALI — lo scanner Tailwind non vede le interpolate.
    def agent_tiles_grid_class(count)
      case count
      when 5 then "lg:grid-cols-5"
      when 4 then "lg:grid-cols-4"
      when 3 then "lg:grid-cols-3"
      else "lg:grid-cols-2"
      end
    end

    def agent_tickets_tile(performance, previous)
      trend = agent_trend(performance.tickets_count, previous&.tickets_count)
      { label: t("member.agents.performance.tickets"), value: performance.tickets_count, icon: "ticket",
        caption: t("member.agents.performance.attempts_caption", count: performance.attempts_count),
        delta: trend&.dig(:label), delta_color: trend&.dig(:color) || :gray,
        test_id: "perf-tickets", value_test_id: "perf-tickets-value" }
    end

    def agent_rejected_tile(performance, previous)
      trend = agent_trend(performance.outcomes.rejected_pct, previous&.outcomes&.rejected_pct,
                          kind: :percent, lower_is_better: true)
      { label: t("member.agents.performance.rejected"), value: agent_percent(performance.outcomes.rejected_pct),
        icon: "x", value_color: agent_rejection_color(performance.outcomes.rejected_pct),
        caption: t("member.agents.performance.rejected_caption",
                   count: performance.outcomes.rejected, total: performance.outcomes.total),
        delta: trend&.dig(:label), delta_color: trend&.dig(:color) || :gray,
        test_id: "perf-rejected", value_test_id: "perf-rejected-value" }
    end

    def agent_host_time_tile(performance, previous)
      trend = agent_trend(performance.host_seconds_avg, previous&.host_seconds_avg,
                          kind: :duration, lower_is_better: true)
      { label: t("member.agents.performance.host_time"), value: agent_duration(performance.host_seconds_avg),
        icon: "gauge",
        caption: t("member.agents.performance.median_caption", value: agent_duration(performance.host_seconds_median)),
        delta: trend&.dig(:label), delta_color: trend&.dig(:color) || :gray,
        test_id: "perf-host-time", value_test_id: "perf-host-time-value" }
    end

    # La caption dichiara su QUANTE lavorazioni chiuse è calcolato: la misura esiste solo per i ticket
    # arrivati alla chiusura, e una media che ne descrive due su cento non deve sembrare il totale.
    def agent_workflow_time_tile(performance, previous)
      trend = agent_trend(performance.workflow_seconds_avg, previous&.workflow_seconds_avg,
                          kind: :duration, lower_is_better: true)
      { label: t("member.agents.performance.workflow_time"), value: agent_duration(performance.workflow_seconds_avg),
        icon: "hourglass",
        caption: t("member.agents.performance.workflow_median_caption",
                   value: agent_duration(performance.workflow_seconds_median),
                   count: performance.workflow_tickets_count),
        delta: trend&.dig(:label), delta_color: trend&.dig(:color) || :gray,
        test_id: "perf-workflow-time", value_test_id: "perf-workflow-time-value" }
    end

    # Il costo è la STIMA dichiarata alla partenza, e la caption lo dice: le partenze senza costo
    # tracciato sono contate a parte invece di sparire dentro un totale che sembrerebbe pieno.
    def agent_cost_tile(performance, previous)
      trend = agent_trend(performance.cost.total, previous&.cost&.any? ? previous.cost.total : nil,
                          kind: :money, lower_is_better: true)
      { label: t("member.agents.performance.cost"), value: agent_money(performance.cost.total), icon: "coins",
        caption: cost_caption(performance.cost),
        delta: trend&.dig(:label), delta_color: trend&.dig(:color) || :gray,
        test_id: "perf-cost", value_test_id: "perf-cost-value" }
    end

    # Sotto il totale: quante partenze ci stanno dietro e quante non hanno un costo tracciato. Un
    # totale parziale spacciato per completo è il rischio dichiarato nel ticket, e questa riga lo evita.
    def cost_caption(cost)
      return t("member.agents.performance.cost_caption", count: cost.tracked) unless cost.partial?

      t("member.agents.performance.cost_partial", count: cost.tracked, untracked: cost.untracked)
    end

    # Colore della quota di bocciature: verde finché è fisiologica, ambra quando merita un'occhiata,
    # rosso quando è il problema. Le soglie sono grossolane di proposito — servono a dirigere lo
    # sguardo, non a certificare un livello di servizio.
    def agent_rejection_color(percent)
      return :neutral if percent.nil?
      return :emerald if percent < 10
      return :amber if percent < 30

      :red
    end
  end
end
