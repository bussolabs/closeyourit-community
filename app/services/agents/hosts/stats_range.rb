# frozen_string_literal: true

module Agents
  module Hosts
    # Finestra temporale delle statistiche di un host (CYRA-279). Sta a sé perché la condividono
    # Performance (gli aggregati) e WorkedTickets (la lista): con due copie basta che una cambi
    # default perché i numeri in cima alla pagina smettano di descrivere la tabella sotto.
    #
    # Stesso contratto dei selettori di periodo del monitoring (Errors::Group::RANGES): il param
    # è solo una chiave di lookup, un valore sconosciuto ricade sul default invece di sollevare —
    # un URL storto non deve rompere una pagina di sola lettura.
    module StatsRange
      # `all` = nessun limite inferiore. Il valore nil non è un buco: è "tutta la storia", ed è
      # legittimo perché gli attempt non vengono mai potati.
      RANGES = { "7d" => 7.days, "30d" => 30.days, "90d" => 90.days, "all" => nil }.freeze
      DEFAULT = "30d"
      KEYS = RANGES.keys.freeze

      class << self
        # Chiave valida a partire da un param grezzo (nil/malformato → default).
        def normalize(value) = RANGES.key?(value.to_s) ? value.to_s : DEFAULT

        # Range beginless-free per una `where`: un intervallo aperto a destra, o nil per "sempre"
        # (il chiamante allora non applica proprio la condizione).
        def window(value, now: Time.current)
          duration = RANGES.fetch(normalize(value))
          duration && ((now - duration)..)
        end

        # Finestra PRECEDENTE della stessa ampiezza, per dire se un numero sta migliorando o
        # peggiorando (CYRA-451). nil su `all`: "tutta la storia" non ha un prima con cui
        # confrontarsi, e inventarne uno darebbe una tendenza finta.
        def previous_window(value, now: Time.current)
          duration = RANGES.fetch(normalize(value))
          duration && ((now - (duration * 2))...(now - duration))
        end
      end
    end
  end
end
