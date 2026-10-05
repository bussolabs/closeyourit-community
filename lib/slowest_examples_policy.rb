# frozen_string_literal: true

# Politica della classifica delle prove più lente (CYRA-711).
#
# Come quella della copertura, questo file viene caricato da `spec_helper` prima che Rails esista:
# niente ActiveSupport qui dentro (`present?` e amici non ci sono ancora) e nessuna dipendenza da
# altro. La decisione è una funzione pura su un hash d'ambiente, così si può verificare senza
# riconfigurare l'RSpec del processo che sta eseguendo le prove.
#
# Perché la scelta stia QUI e non nel comando: il comando che i controlli automatici eseguono arriva
# dal template condiviso di rilascio, che è un altro repository. La configurazione di RSpec invece è
# nostra e vale per qualunque comando — suite intera, shard, singolo file.
module SlowestExamplesPolicy
  # Dieci sono quelle che si leggono davvero: bastano a riconoscere il collo di bottiglia di un
  # gruppo e non trasformano la coda del run in un tabellone che nessuno scorre.
  COUNT = 10

  # Una variabile lasciata a vuoto o a zero è un no, non un sì: `CI=` dimenticato in una shell
  # appiccicherebbe la classifica in fondo a ogni run locale.
  OFF_VALUES = [ "", "0", "false", "no", "off" ].freeze

  class << self
    # Quante prove lente stampare, o `nil` per non stamparne nessuna — che è anche il valore che
    # RSpec legge come "profilo spento".
    def count_for(env = ENV)
      on?(env["CI"]) ? COUNT : nil
    end

    private

    def on?(value)
      normalized = value.to_s.strip.downcase

      !OFF_VALUES.include?(normalized)
    end
  end
end
