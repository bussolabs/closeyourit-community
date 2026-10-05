# frozen_string_literal: true

# CYRA-822 — il metro degli aggiornamenti in arrivo: quante richieste risparmia, a chi sta guardando
# un solo progetto, non ricevere più i segnali nati negli altri.
#
# PERCHÉ ESISTE: un segnale di aggiornamento non costa quasi niente a chi lo manda — è un messaggio
# senza contenuto — e costa una pagina intera a ognuno di quelli che lo ricevono. Il numero che
# conta non è quindi «quanti segnali sono partiti», ma «quante richieste sono arrivate al server», e
# quel numero si ottiene solo moltiplicando i segnali consegnati per le sessioni che li ascoltano.
# Le due colonne restano separate proprio per questo, e il numero di sessioni è dichiarato nel
# registro invece di essere nascosto dentro un totale.
#
# COSA MISURA E COSA CALCOLA, senza mescolarli: `signals` sono i segnali davvero consegnati allo
# stream di quell'osservatore (misurati sul canale, non dedotti); `sessions` è il numero di sessioni
# dichiarato dal confronto; `requests_per_minute` è il prodotto dei due, perché ogni sessione che
# riceve un segnale ri-chiede la propria pagina. `broadcasts` e `jobs` sono il lavoro del mittente —
# messaggi emessi e lavorazioni messe in coda — cioè il prezzo pagato per avere due livelli invece
# di uno.
#
# COSA NON È: un gate di prestazione. Non c'è nessun tempo di parete qui: le quantità sono conteggi
# deterministici a parità di volume, e sono quelle che il confronto asserisce.
#
# NIENTE CONTENUTI: `record` accetta soltanto numeri più un'etichetta presa da un elenco chiuso.
# Nel registro non può entrare il titolo di un errore, il nome di un progetto o un indirizzo.
module BroadcastFanout
  # Chi ascolta, nel confronto. Elenco chiuso: è anche la difesa contro i dati personali nel registro.
  OSSERVATORI = %w[
    lista_filtrata
    lista_organizzazione
    mittente
  ].freeze

  # Cosa stava succedendo mentre si misurava.
  OPERAZIONI = %w[
    raffica_estranea
    raffica_pertinente
    riconnessione
  ].freeze

  # Un ambiente reale non si misura con dati inventati (stessa regola del metro di CYRA-826).
  AMBIENTI_VIETATI = %w[production].freeze

  # Un campione: chi ascoltava, durante cosa, su quanti eventi, con quante sessioni dichiarate, e le
  # misure tenute distinte — segnali consegnati, richieste che ne derivano, lavoro del mittente.
  Sample = Data.define(:observer, :operation, :events, :sessions, :signals, :requests_per_minute,
                       :broadcasts, :jobs) do
    def to_h
      { "osservatore" => observer, "operazione" => operation, "eventi" => events,
        "sessioni" => sessions, "segnali_ricevuti" => signals,
        "richieste_al_minuto" => requests_per_minute, "messaggi_emessi" => broadcasts,
        "lavorazioni_in_coda" => jobs }
    end
  end

  # Il registro di un giro di confronto: intestazione (ambiente, revisione, costanti) più i campioni.
  class Ledger
    attr_reader :name, :setup, :environment, :samples

    def initialize(name:, setup: {}, environment: App::Version.environment)
      if AMBIENTI_VIETATI.include?(environment.to_s)
        raise ArgumentError,
              "CYRA-822: il confronto non si esegue in produzione (ambiente #{environment}): " \
              "il traffico sarebbe quello vero e i segnali finti lo inquinerebbero."
      end

      @name = name
      @setup = setup
      @environment = environment.to_s
      @samples = []
    end

    # `sessions` è dichiarato, non simulato: aprire davvero venticinque browser non cambierebbe il
    # conto (ogni sessione iscritta ri-chiede la pagina una volta per segnale) e renderebbe la prova
    # lenta e fragile. Il registro lo scrive accanto al risultato proprio perché si veda.
    def record(observer:, operation:, events:, sessions:, signals:, broadcasts: nil, jobs: nil)
      raise ArgumentError, "osservatore sconosciuto: #{observer}" unless OSSERVATORI.include?(observer.to_s)
      raise ArgumentError, "operazione sconosciuta: #{operation}" unless OPERAZIONI.include?(operation.to_s)

      Sample.new(observer: observer.to_s, operation: operation.to_s, events: Integer(events),
                 sessions: Integer(sessions), signals: Integer(signals),
                 requests_per_minute: Integer(signals) * Integer(sessions),
                 broadcasts: broadcasts&.then { |v| Integer(v) },
                 jobs: jobs&.then { |v| Integer(v) })
        .tap { |sample| @samples << sample }
    end

    def cardinality
      samples.group_by { |sample| "#{sample.operation}/#{sample.observer}" }
             .transform_values(&:size).sort.to_h
    end

    def document
      { "misura" => "aggiornamenti di lista per progetto", "registro" => name,
        "ambiente" => environment, "revisione" => App::Version.to_h.transform_keys(&:to_s),
        "impostazione" => setup.transform_keys(&:to_s), "numerosità" => cardinality,
        "avvertenza" => "I segnali sono misurati sul canale; le sessioni sono dichiarate e le " \
                        "richieste al minuto sono il prodotto dei due (una richiesta per sessione " \
                        "per segnale ricevuto).",
        "campioni" => samples.map(&:to_h) }
    end

    def path = Rails.root.join("tmp/performance/#{name}.json")

    def write!
      path.dirname.mkpath
      path.write("#{JSON.pretty_generate(document)}\n")
      path
    end
  end

  class << self
    # Un registro per nome, condiviso da tutti gli esempi di un file: `let` ne creerebbe uno nuovo a
    # ogni esempio e il confronto resterebbe senza numerosità.
    def ledger(name, setup: {})
      registry[name] ||= Ledger.new(name: name, setup: setup)
    end

    def registry = @registry ||= {}

    def write!(name) = registry[name]&.write!
  end
end

# I segnali consegnati su uno stream, e il lavoro che il mittente ha fatto per emetterli.
module BroadcastFanoutHelpers
  # Quanti segnali sono arrivati su questi stream. Si legge dal canale (l'adapter di prova conserva
  # i messaggi per stream), non dal codice che li emette: è la misura di cosa riceve chi ascolta.
  def signals_on(*streams)
    streams.flatten.sum { |stream| ActionCable.server.pubsub.broadcasts(stream).size }
  end

  def clear_signals = ActionCable.server.pubsub.clear

  # Il ramo differito del throttle: a fine finestra il segnale «stato finale» parte da una
  # lavorazione in coda. Senza eseguirla si conterebbe solo metà di ciò che arriva davvero.
  def run_pending_refresh_jobs
    pending = ActiveJob::Base.queue_adapter.enqueued_jobs
                             .select { |job| job["job_class"] == "Realtime::BroadcastRefreshJob" }
    pending.each { |job| Realtime::BroadcastRefreshJob.perform_now(*job.fetch("arguments")) }
    ActiveJob::Base.queue_adapter.enqueued_jobs.reject! { |job| pending.include?(job) }
    pending.size
  end
end

RSpec.configure do |config|
  config.include BroadcastFanoutHelpers, type: :request
end
