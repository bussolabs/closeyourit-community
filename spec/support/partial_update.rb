# frozen_string_literal: true

# CYRA-826 — il metro degli aggiornamenti parziali: quanto lavoro EVITA davvero chiedere solo un
# pezzo di pagina invece della pagina intera.
#
# PERCHÉ ESISTE: «sembra più veloce» non è una misura. Un turbo-frame salta il layout — sidebar,
# menu, intestazione — e quindi consegna molti byte in meno; ma la stessa action gira per intero,
# quindi le LETTURE del database possono restare identiche a quelle della pagina intera. Le due cose
# si vedono solo tenendole separate, ed è esattamente ciò che qui viene registrato: richieste, byte
# consegnati, letture (query e righe) e tempo, quattro numeri distinti per ogni campione.
#
# COSA NON È: un gate di prestazione. Il tempo di parete in CI dipende dalla macchina, dal carico
# degli altri shard e dal riscaldamento del primo giro; asserirlo produrrebbe rossi che non parlano
# di codice. Le prove che usano questo metro asseriscono solo ciò che è deterministico — byte e
# letture a parità di dati — e il tempo resta un numero registrato, da leggere, non un limite.
#
# NIENTE CONTENUTI: `record` accetta soltanto numeri più due etichette prese da elenchi chiusi
# (`OPERAZIONI`, `CANALI`). Non c'è modo di far entrare nel registro il titolo di un ticket, un
# indirizzo email o un corpo di risposta: la garanzia è nella forma del metodo, non nella buona
# volontà di chi lo chiama.
module PartialUpdate
  # I tre modi in cui una pagina di questo prodotto si aggiorna. Restano tre nomi e non una stringa
  # libera perché il confronto ha senso solo fra canali confrontabili.
  CANALI = %w[
    drive
    frame
    stream
  ].freeze

  # Le operazioni misurabili. Elenco chiuso: è anche la difesa contro i dati personali nel registro.
  OPERAZIONI = %w[
    filtro
    filtri_combinati
    cambio_scheda
    aggiornamento_in_arrivo
    volume_zero
    volume_uno
    volume_molti
    errore_filtro
    riconnessione
    permessi_ridotti
    navigazione_pagina
    telefono
    indietro
  ].freeze

  # Un ambiente reale non si misura con dati inventati: il registro nasce con l'ambiente inciso e si
  # rifiuta di partire dove i dati sono quelli veri.
  AMBIENTI_VIETATI = %w[production].freeze

  # Di cosa si può dichiarare il volume. Chiuso come le operazioni, e per la stessa ragione: il
  # volume viaggia nel registro e deve restare un numero, non una descrizione libera.
  #
  # CYRA-821 aggiunge le due misure dell'area di controllo. Non si riusa `eventi` per tutto: un
  # gruppo d'errore non è un evento — ne raccoglie migliaia — e leggere «eventi: 12» dove i dodici
  # erano gruppi attribuirebbe alla misura una quantità che non è la sua, che è esattamente ciò che
  # CYRA-826 aveva tolto dal registro.
  MISURE_DI_VOLUME = %w[
    ticket
    eventi
    gruppi
    registri
  ].freeze

  # Un campione: cosa è stato chiesto, su quale canale, su QUANTI dati, e le misure tenute distinte.
  #
  # `volume` sta sul campione e non solo sull'intestazione perché non tutti i campioni di un giro
  # nascono sulla stessa quantità di righe: dichiararne uno solo in testa al registro vorrebbe dire
  # attribuire a una misura presa su tre ticket il volume di un'altra presa su ventiquattro.
  # `queries`/`writes`/`rows` sono nil quando la misura arriva dal browser e non da chi serve.
  Sample = Data.define(:operation, :channel, :volume, :requests, :bytes, :queries, :writes, :rows,
                       :milliseconds) do
    def to_h
      { "operazione" => operation, "canale" => channel, "volume" => volume, "richieste" => requests,
        "byte" => bytes, "letture" => queries, "scritture" => writes, "righe_lette" => rows,
        "millisecondi" => milliseconds }
    end
  end

  # Il registro di un giro di confronto: intestazione (ambiente, revisione, costanti del confronto)
  # più i campioni raccolti. Vive per l'intero file di prova che lo usa e si scrive alla fine.
  class Ledger
    attr_reader :name, :setup, :environment, :samples

    # `setup` sono le costanti del confronto — righe per pagina, card per colonna, misure della
    # finestra: ciò che vale per tutti i campioni. Il volume dei dati NON sta qui: è del campione.
    def initialize(name:, setup: {}, environment: App::Version.environment)
      if AMBIENTI_VIETATI.include?(environment.to_s)
        raise ArgumentError,
              "CYRA-826: il confronto non si esegue in produzione (ambiente #{environment}): " \
              "i dati sarebbero quelli veri e i campioni finti li inquinerebbero."
      end

      @name = name
      @setup = setup
      @environment = environment.to_s
      @samples = []
    end

    def record(operation:, channel:, volume:, requests:, bytes:, milliseconds:,
               queries: nil, writes: nil, rows: nil)
      raise ArgumentError, "operazione sconosciuta: #{operation}" unless OPERAZIONI.include?(operation.to_s)
      raise ArgumentError, "canale sconosciuto: #{channel}" unless CANALI.include?(channel.to_s)

      Sample.new(operation: operation.to_s, channel: channel.to_s, volume: normalize_volume(volume),
                 requests: Integer(requests), bytes: Integer(bytes),
                 queries: queries&.then { |v| Integer(v) }, writes: writes&.then { |v| Integer(v) },
                 rows: rows&.then { |v| Integer(v) },
                 milliseconds: Float(milliseconds)).tap { |sample| @samples << sample }
    end

    # Quanti campioni per ogni coppia operazione/canale: la numerosità che il confronto dichiara.
    def cardinality
      samples.group_by { |sample| "#{sample.operation}/#{sample.channel}" }
             .transform_values(&:size)
             .sort
             .to_h
    end

    # I volumi su cui il giro è stato preso davvero, letti dai campioni: da quanti a quanti.
    def observed_volumes
      MISURE_DI_VOLUME.filter_map do |chiave|
        valori = samples.filter_map { |sample| sample.volume[chiave] }
        next if valori.empty?

        [ chiave, { "min" => valori.min, "max" => valori.max } ]
      end.to_h
    end

    def document
      { "misura" => "aggiornamenti parziali", "registro" => name, "ambiente" => environment,
        "revisione" => App::Version.to_h.transform_keys(&:to_s),
        "impostazione" => setup.transform_keys(&:to_s), "volumi_osservati" => observed_volumes,
        "numerosità" => cardinality,
        "avvertenza" => "I millisecondi sono indicativi (primo giro a freddo, macchina condivisa): " \
                        "il confronto vincolante è su byte e letture, a parità di dati.",
        "campioni" => samples.map(&:to_h) }
    end

    def path = Rails.root.join("tmp/performance/#{name}.json")

    def write!
      path.dirname.mkpath
      path.write("#{JSON.pretty_generate(document)}\n")
      path
    end

    private

    def normalize_volume(volume)
      volume.to_h do |chiave, valore|
        unless MISURE_DI_VOLUME.include?(chiave.to_s)
          raise ArgumentError, "misura di volume sconosciuta: #{chiave}"
        end

        [ chiave.to_s, Integer(valore) ]
      end
    end
  end

  class << self
    # Un registro per nome, condiviso da tutti gli esempi di un file: `let` ne creerebbe uno nuovo a
    # ogni esempio e il confronto resterebbe senza numerosità.
    def ledger(name, setup: {})
      registry[name] ||= Ledger.new(name: name, setup: setup)
    end

    def registry = @registry ||= {}

    # Scrive il registro se qualcuno l'ha davvero riempito (un file di prova filtrato non ne ha uno).
    def write!(name) = registry[name]&.write!
  end
end

# Misura di UNA richiesta HTTP nei request spec.
module PartialUpdateRequestHelpers
  # Letture e scritture non si sommano in un numero solo. Un GET di questo prodotto scrive: la lista
  # ricorda i filtri scelti, la sessione si rinfresca. Contarle insieme alle SELECT gonfierebbe la
  # colonna «letture» con lavoro che non è quello di leggere la pagina, e il confronto fra due
  # canali diventerebbe illeggibile proprio dove serve. `WITH` conta come lettura: è una SELECT che
  # comincia dalla sua tabella temporanea.
  LETTURA = /\A\s*(SELECT|WITH)\b/i

  def measure_partial_update(ledger, operation:, channel:, volume:, &)
    inizio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    queries = captured_queries(&)
    trascorso = Process.clock_gettime(Process::CLOCK_MONOTONIC) - inizio
    letture = queries.select { |query| query.sql.match?(LETTURA) }
    ledger.record(operation: operation, channel: channel, volume: volume, requests: 1,
                  bytes: response.body.bytesize, queries: letture.size,
                  writes: queries.size - letture.size,
                  rows: letture.sum { |query| query.rows.to_i },
                  milliseconds: (trascorso * 1000).round(1))
  end
end

# Misura di un'operazione nel browser.
#
# Le richieste che Turbo fa — sia la navigazione Drive sia il caricamento di un frame — passano da
# `fetch`, quindi si contano dai resource timing filtrando su `initiatorType`. `decodedBodySize` è
# il corpo dopo la decompressione: è il numero confrontabile con i byte del request spec, mentre
# `transferSize` dipende da come il server ha compresso ed è 0 quando la risposta arriva dalla cache.
module PartialUpdateBrowserHelpers
  TRAFFICO_JS = <<~JS
    (() => {
      const voci = performance.getEntriesByType('resource')
        .filter((voce) => voce.initiatorType === 'fetch' && voce.name.startsWith(window.location.origin));
      return {
        richieste: voci.length,
        byte: voci.reduce((somma, voce) => somma + (voce.decodedBodySize || voce.transferSize || 0), 0)
      };
    })()
  JS

  # Finish the sidebar's independent lazy request before measuring navigation traffic.
  def wait_for_sidebar_counter
    frame = "turbo-frame#member-nav-approvals-count"
    return unless page.has_css?(frame, visible: :all, wait: 0)

    expect(page).to have_css("#{frame}[complete]", visible: :all)
  end

  def measure_browser_update(ledger, operation:, channel:, volume:)
    page.execute_script("performance.clearResourceTimings()")
    inizio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    trascorso = Process.clock_gettime(Process::CLOCK_MONOTONIC) - inizio
    traffico = page.evaluate_script(TRAFFICO_JS)
    ledger.record(operation: operation, channel: channel, volume: volume,
                  requests: traffico["richieste"], bytes: traffico["byte"],
                  milliseconds: (trascorso * 1000).round(1))
  end

  # La posizione nel contenuto dell'area member. NON basta `window.scrollY` e non basta nemmeno il
  # solo `#main-content`: quel pannello ha `overflow-y-auto` e scorre per conto suo quando il layout
  # gli dà un'altezza, ma su una finestra più bassa del contenuto a scorrere è il documento e il
  # pannello resta fermo a zero. Misurato dal vivo (CYRA-826): a 1280x520 il pannello ha
  # `scrollHeight == clientHeight` e scorre il body. Guardarne uno solo vuol dire leggere zero e
  # chiamare «conservata» una posizione che si era persa.
  POSIZIONE_JS = <<~JS
    (() => {
      const pannello = document.getElementById('main-content');
      return Math.max(pannello ? pannello.scrollTop : 0, window.scrollY,
                      document.documentElement.scrollTop);
    })()
  JS

  def posizione_nel_contenuto = page.evaluate_script(POSIZIONE_JS)

  def scorri_contenuto(quanto)
    page.execute_script(<<~JS)
      (() => {
        const pannello = document.getElementById('main-content');
        if (pannello && pannello.scrollHeight > pannello.clientHeight) {
          pannello.scrollTop = #{Integer(quanto)};
          return;
        }
        window.scrollTo(0, #{Integer(quanto)});
      })()
    JS
  end
end

RSpec.configure do |config|
  config.include PartialUpdateRequestHelpers, type: :request
  config.include PartialUpdateBrowserHelpers, type: :system
end
