# frozen_string_literal: true

module Ingest
  # CYRA-735 — le regole di pulizia del dato in ingresso, in un punto solo: istante nel futuro,
  # epoch in secondi o millisecondi, testo da accorciare, percentuale fuori scala, lista senza tetto.
  # Prima erano copiate in Errors/Servers/Logs/Analytics::Ingest::Normalize.
  #
  # La regola è una; la MISURA arriva dal chiamante perché è una scelta del dominio, non un dettaglio
  # da uniformare: gli errori tollerano 5 minuti di scarto d'orologio, i log e i server un'ora, e la
  # soglia secondi/millisecondi differisce di un fattore dieci fra i canali. Unificare i numeri
  # cambierebbe quale dato viene considerato corrotto — unificare la regola no.
  module Normalization
    module_function

    # Un istante oltre la tolleranza di scarto d'orologio è corrotto → adesso. Senza il clamp, un
    # epoch in millisecondi o un client con l'orologio avanti avvelena l'ordinamento: la riga resta
    # in cima allo stream e nessuna pagina riesce più a scrollarla via.
    def clamp_future(time, skew:)
      return nil if time.nil?

      time > Time.current + skew ? Time.current : time
    end

    # Epoch → secondi. Sopra la soglia il numero è in millisecondi (`Date.now()` lato JS); la soglia
    # la dichiara il dominio perché dipende da quali ordini di grandezza quel canale vede passare.
    # Nessuna soglia = nessuna euristica: il canale dichiara che i suoi epoch sono in secondi e basta.
    def epoch_seconds(value, ms_threshold: nil)
      return value if ms_threshold.nil?

      value >= ms_threshold ? value / 1000.0 : value
    end

    # Epoch → istante, o nil se quel numero non è una data rappresentabile (infinito, NaN, oltre il
    # calendario). nil e non un'eccezione: chi chiama sostituisce con adesso e il dato si salva,
    # mentre un raise dentro il job farebbe perdere l'intero batch per un solo numero implausibile.
    def epoch_to_time(value, ms_threshold: nil)
      Time.zone.at(epoch_seconds(value, ms_threshold: ms_threshold))
    rescue ArgumentError, RangeError, FloatDomainError
      nil
    end

    # Testo persistibile da una sorgente qualunque: ripara i byte non validi (i log di sistema sono la
    # prima sorgente non-SDK del prodotto), toglie i byte nulli (Postgres li rifiuta in text e jsonb)
    # e accorcia al tetto. Torna sempre una stringa, mai nil: la colonna che lo ospita è di testo.
    def clean_text(value, max)
      value.to_s.scrub.delete(PayloadCleaning::NULL_BYTE)[0, max].to_s
    end

    # Percentuale persistibile: due decimali e dentro la scala. Il tetto è un argomento perché non
    # tutte le percentuali si fermano a cento (le connessioni del database possono eccedere gli slot
    # utilizzabili). Ciò che non è un numero torna nil: «non lo so» non è «zero».
    def numeric_percentage(value, max: 100)
      return nil unless value.is_a?(Numeric)

      value.to_f.round(2).clamp(0, max)
    end

    # Lista dal filo → lista persistibile: il blocco traduce (e scarta con `next`) ogni elemento, il
    # tetto difende il jsonb da un client malconcio. Torna nil se la sezione non è una lista o se dopo
    # il filtro non resta niente, così il chiamante distingue «assente» da «presente e vuota».
    def rows(list, max)
      return nil unless list.is_a?(Array)

      list.filter_map { |item| yield(item) }.first(max).presence
    end
  end
end
