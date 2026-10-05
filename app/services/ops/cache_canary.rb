# frozen_string_literal: true

module Ops
  # Canarino di disponibilità della cache condivisa (Rails.cache). I freni anti-doppione degli avvisi —
  # probe/cooldown spike errori (Errors::Ingest::Record), soglia metriche (Metrics::Ingest::Record),
  # throttle canali (Alerting::Evaluate) — usano `Rails.cache.write(unless_exist:)` come lucchetto: torna
  # false sia per «già scritto» (throttle attivo, avviso davvero già partito) sia per «cache non
  # raggiungibile». I due casi sono indistinguibili dal gate, e una cache in lock durante un picco di
  # errori viene così scambiata per «già avvisato»: l'avviso tace proprio quando serve. Il degrado è
  # SILENZIOSO due volte — il gate non lo vede, e l'eccezione di lock è esclusa dal self-monitoring per
  # non richiudere il loop di ricorsione (config/initializers/closeyourit.rb).
  #
  # Il canarino NON tocca i gate: un fail-open lì vanificava i rate-limiter sotto contesa (una query e un
  # job per occorrenza — ritirato in v0.70.2). Fa una prova indipendente, fuori dai gate: scrive un
  # valore noto su una chiave dedicata e lo rilegge. Se la scrittura solleva, o la rilettura non torna lo
  # stesso valore, la cache non è affidabile → il chiamante (Ops::CacheCanaryJob) ne lascia una traccia
  # nei log, l'unico segnale che l'esclusione anti-ricorsione toglie. Sola osservazione: non cambia il
  # comportamento degli avvisi, lo rende diagnosticabile. Vedi CYRA-270.
  class CacheCanary
    # Chiave dedicata, mai un lucchetto reale: la si sovrascrive ad ogni giro, con TTL corto perché non
    # resti a sporcare la cache tra un probe e il successivo.
    KEY = "ops:cache:canary"
    TTL = 1.minute

    Result = Data.define(:available, :error) do
      def available? = available
    end

    # `token` iniettabile per i test; in esercizio è casuale ad ogni giro, così la rilettura verifica il
    # round-trip DI QUESTO probe e non un valore stantio rimasto da un giro precedente.
    def self.call(token: SecureRandom.hex(8)) = new(token: token).call

    def initialize(token: SecureRandom.hex(8))
      @token = token
    end

    # Round-trip write→read su chiave dedicata. Robusto a due modi di guasto: la write che SOLLEVA
    # (rescue → unavailable; l'eccezione non propaga né fa ritentare il job) e la write INGOIATA in
    # silenzio (null/lock → la rilettura non torna il token → mismatch → unavailable).
    def call
      Rails.cache.write(KEY, @token, expires_in: TTL)
      readback = Rails.cache.read(KEY)
      return Result.new(available: true, error: nil) if readback == @token

      Result.new(available: false,
                 error: "round-trip fallito (scritto #{@token.inspect}, riletto #{readback.inspect})")
    rescue StandardError => e
      Result.new(available: false, error: "#{e.class}: #{e.message}")
    end
  end
end
