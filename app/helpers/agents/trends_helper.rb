# frozen_string_literal: true

module Agents
  # CYRA-451 — la VARIAZIONE rispetto al periodo precedente. Senza una base, «21,6% respinti» non dice
  # se la macchina stia migliorando o peggiorando; e quando il confronto non esiste il risultato è
  # nessun delta, mai un delta inventato (CYRA-742).
  module TrendsHelper
    # CYRA-451 — variazione rispetto al periodo precedente. Senza una base, «21,6% respinti» non dice
    # se l'host stia migliorando o peggiorando. nil quando il confronto non esiste (periodo `all`, o
    # una metrica non misurata da una delle due parti): un delta inventato è peggio di nessun delta.
    #
    # `lower_is_better` decide il COLORE, non il segno: meno tempo e meno lavori respinti sono buone
    # notizie, più ticket lavorati no — per i conteggi il colore resta neutro, perché "di più" non è
    # né buono né cattivo senza sapere cosa si voleva.
    def agent_trend(current, previous, kind: :count, lower_is_better: nil)
      return nil if current.nil? || previous.nil?

      delta = current - previous
      { label: agent_trend_label(delta, kind), color: agent_trend_color(delta, lower_is_better) }
    end

    def agent_trend_label(delta, kind)
      return t("member.agents.performance.trend.flat") if delta.zero?

      sign = delta.positive? ? "+" : "−"
      t("member.agents.performance.trend.delta", value: "#{sign}#{agent_trend_value(delta.abs, kind)}")
    end

    def agent_trend_value(value, kind)
      case kind
      when :percent  then t("member.agents.performance.trend.points", value: number_with_precision(value, precision: 1, strip_insignificant_zeros: true, locale: I18n.locale))
      when :duration then agent_duration(value)
      when :money    then agent_money(value)
      else number_with_delimiter(value, locale: I18n.locale)
      end
    end

    # Neutro quando "di più" non è di per sé un giudizio (i conteggi): colorarlo direbbe una cosa che
    # il dato non dice.
    def agent_trend_color(delta, lower_is_better)
      return :gray if lower_is_better.nil?

      improving = lower_is_better ? delta.negative? : delta.positive?
      improving ? :emerald : :red
    end
  end
end
