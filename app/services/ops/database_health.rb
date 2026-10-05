# frozen_string_literal: true

module Ops
  # Il database primary risponde? Quarto segnale di esercizio accanto a Ops::WorkerLiveness (i
  # processi battono), Ops::QueueThroughput (la coda smaltisce) e Ops::RecurringSchedule (i giri
  # ricorrenti partono).
  #
  # Perché serve (CYRA-754): il rilascio decideva che il contenitore nuovo era pronto guardando
  # `/up`, che per contratto è liveness PURA — 200 appena il processo è su, senza toccare niente
  # (knowledge-base/global/health-version.md). Un contenitore che boota con il primary irraggiungibile
  # passa quel controllo: kamal-proxy gli devia sopra il traffico, ferma il contenitore precedente
  # (quello sano) e il sito serve errori a tutti, mentre il rilascio risulta riuscito.
  #
  # Il primary e non gli altri tre database: senza di lui non si serve NIENTE — nessuna pagina,
  # nessuna API, nessun login. Coda, cache e cable degradano funzioni singole e hanno già i loro
  # segnali; metterli qui vorrebbe dire far fallire il rilascio del sito per un guasto che il sito
  # non ha.
  class DatabaseHealth
    # Una domanda che non legge nessuna tabella: il verdetto è "il server risponde", non "lo schema è
    # quello giusto". Le migration pendenti sono un altro problema, con un altro rimedio.
    PROBE_SQL = "SELECT 1"

    Result = Data.define(:available, :error) do
      def available? = available
    end

    def self.call = new.call

    def call
      ApplicationRecord.connection.select_value(PROBE_SQL)
      Result.new(available: true, error: nil)
    rescue StandardError => e
      # Il messaggio del driver nomina host, porta e nome del database: resta nei log, dove serve a
      # chi ripara. Fuori esce il solo TIPO di guasto, perché l'endpoint che lo espone è pubblico e
      # senza auth come le sue gemelle.
      Rails.logger.error("[ops] database primary non raggiungibile: #{e.class}: #{e.message}")
      Result.new(available: false, error: e.class.name)
    end
  end
end
