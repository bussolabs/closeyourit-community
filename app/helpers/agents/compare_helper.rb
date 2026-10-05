# frozen_string_literal: true

module Agents
  # Il CONFRONTO fra macchine (CYRA-451): una riga per misura, i valori già formattati per host. È la
  # stessa lista di misure dei riquadri del rendimento, scritta una volta sola (CYRA-742).
  module CompareHelper
    # Righe del confronto fra macchine (CYRA-451): una per misura, i valori già formattati per host.
    # Sta qui e non nella vista perché è la stessa lista di misure delle tile, e due elenchi separati
    # divergerebbero alla prima aggiunta.
    def agent_compare_rows(reports)
      rows = [
        compare_row("tickets", reports) { |r| r.tickets_count },
        compare_row("attempts", reports) { |r| r.attempts_count },
        compare_row("rejected", reports) { |r| agent_percent(r.rejected_pct) },
        compare_row("interrupted", reports) { |r| agent_percent(r.interrupted_pct) },
        compare_row("host_time", reports) { |r| agent_duration(r.host_seconds_median) }
      ]
      # CYRA-499 — stessa regola dei riquadri: una riga che dice «—» sotto ogni macchina non è un
      # confronto. Compare solo se almeno una delle macchine confrontate ha misurato quel tempo.
      if reports.values.any? { |report| report.workflow_seconds_median }
        rows << compare_row("workflow_time", reports) { |r| agent_duration(r.workflow_seconds_median) }
      end
      rows << compare_row("cost", reports) { |r| r.cost.any? ? agent_money(r.cost.total) : "—" }
      rows
    end

    def compare_row(key, reports)
      label = case key
      when "attempts" then t("member.agents.performance.col_attempts")
      when "interrupted" then t("member.agents.performance.col_interrupted")
      when "host_time", "workflow_time"
        t("member.agents.performance.compare.median", label: t("member.agents.performance.#{key}"))
      else t("member.agents.performance.#{key}")
      end
      { key:, label:, values: reports.transform_values { |report| yield(report) } }
    end

    # Conteggio in una cella di tabella densa: gli zeri si spengono perché l'occhio deve cadere
    # sulle righe dove è successo qualcosa. Classi letterali (Tailwind non vede le interpolate).
    def agent_count_class(value, color)
      return "font-mono text-[12px] text-gray-300 dark:text-zinc-600" if value.to_i.zero?

      case color
      when :emerald then "font-mono text-[12px] text-green-600 dark:text-green-400"
      when :red then "font-mono text-[12px] text-red-600 dark:text-red-400"
      when :amber then "font-mono text-[12px] text-amber-600 dark:text-amber-400"
      else "font-mono text-[12px] text-gray-500 dark:text-zinc-400"
      end
    end
  end
end
