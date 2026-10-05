# frozen_string_literal: true

module Metrics
  # CYRA-341 — le due soglie che decidono il colore di una durata (verde sotto `fast`, ambra fino a
  # `slow`, rosso oltre). Erano due costanti uguali per tutti e scritte in nessuna schermata: 299ms
  # rosso in un posto e 12ms verde in un altro, senza che si potesse sapere il perché né cambiarlo.
  #
  # Gerarchia volutamente corta — progetto → valori di sistema — e non la catena progetto → org →
  # god della retention: qui il livello che serve è quello in cui la lentezza ha un significato
  # (un'API interna e una pagina pubblica non hanno lo stesso «lento»), e ogni livello in più è una
  # leva da spiegare. Blank o non positivo = non impostato, eredita.
  module Thresholds
    module_function

    # I valori di sistema, quelli che valgono finché un progetto non dice la sua.
    def system_defaults = { fast: Group::FAST_MS, slow: Group::MEDIUM_MS }

    # Soglie effettive del progetto: { fast: ms, slow: ms }. Progetto nil → valori di sistema (una
    # vista non deve rompersi per un'associazione mancante).
    def for(project)
      slow = resolve(project&.performance_slow_ms) || Group::MEDIUM_MS
      fast = resolve(project&.performance_fast_ms) || Group::FAST_MS
      # Coppia incoerente (fast ≥ slow, possibile solo aggirando la validazione del modello): la
      # fascia ambra sparisce invece di invertirsi, e il verde resta il caso migliore.
      { fast: [ fast, slow ].min, slow: slow }
    end

    # Intero positivo o nil (campo vuoto/zero → eredita il valore di sistema).
    def resolve(value)
      ms = value.to_i
      ms if ms.positive?
    end
  end
end
