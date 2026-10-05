# frozen_string_literal: true

module Agents
  # I FORMATI dei numeri della sezione: quanto è durato un lavoro, quanto è costato, che percentuale
  # è. Fonte unica delle durate — ci passa anche la tab Automazione del ticket — e nessun giudizio:
  # dire se un numero è buono o cattivo tocca a chi lo mostra (CYRA-742).
  module DurationsHelper
    # Durata in forma compatta e a due sole unità: "45s", "12m 30s", "3h 05m", "2g 4h". Le due unità
    # sono una scelta di leggibilità — "2g 4h 13m 07s" è preciso e illeggibile, e a quella scala i
    # secondi non cambiano nessuna decisione. nil (durata sconosciuta) → trattino, MAI "0s": un lavoro
    # senza istante di fine non è durato zero, non si sa quanto è durato.
    # Fonte unica di formattazione delle durate: ci passa anche la tab Automazione del ticket.
    #
    # Le sigle passano dall'i18n perché il giorno NON è la stessa lettera in ogni lingua (g/d):
    # scriverle nel codice fa comparire un "2g 4h" italiano in mezzo a una pagina inglese.
    def agent_duration(seconds)
      total = seconds&.round
      return "—" if total.nil?
      return "#{total}#{agent_duration_unit(:seconds)}" if total < 60
      return agent_duration_pair(total / 60, :minutes, total % 60, :seconds, pad: true) if total < 3600
      return agent_duration_pair(total / 3600, :hours, (total % 3600) / 60, :minutes, pad: true) if total < 86_400

      agent_duration_pair(total / 86_400, :days, (total % 86_400) / 3600, :hours)
    end

    def agent_duration_unit(key) = t("member.agents.duration.#{key}")

    # Lo zero davanti all'unità minore tiene le durate incolonnate in tabella (12m 07s sopra 12m 30s);
    # a giorni+ore non serve, l'unità è troppo grossa perché il disallineamento si noti.
    def agent_duration_pair(major, major_unit, minor, minor_unit, pad: false)
      format("%d%s %#{pad ? '02' : ''}d%s",
             major, agent_duration_unit(major_unit), minor, agent_duration_unit(minor_unit))
    end

    # Costo in valuta. Il costo è una STIMA dichiarata alla partenza: la vista lo scrive accanto,
    # qui si formatta soltanto.
    def agent_money(value)
      return "—" if value.nil?

      number_to_currency(value, unit: "$", precision: 2, locale: :en)
    end

    # Percentuale già arrotondata → testo. nil = non c'è denominatore, e "—" lo dice; "0%" direbbe
    # invece che è stato misurato e vale zero.
    def agent_percent(value)
      return "—" if value.nil?

      "#{number_with_precision(value, precision: 1, strip_insignificant_zeros: true, locale: I18n.locale)}%"
    end
  end
end
