# frozen_string_literal: true

module Servers
  # Campione per-container (Docker/Podman) legato all'host: serie tipizzata per il drill-down,
  # retention corta (SERVERS_CONTAINER_RETENTION_DAYS). Immutabile come Servers::Sample.
  class ContainerSample < ApplicationRecord
    belongs_to :host, class_name: "Servers::Host", inverse_of: :container_samples

    # Health Docker riportata dall'agent (vocabolario fisso dell'API Docker) → enum legittimo.
    enum :health, { none: 0, starting: 1, healthy: 2, unhealthy: 3 }, prefix: :health

    validates :name, presence: true
    validates :recorded_at, presence: true

    # Nomi che Kamal genera e non riusa MAI: il container sostituito durante un rolling deploy e i
    # one-off `kamal app exec`. Sparire è la loro fine naturale, non un guasto — e siccome quel nome
    # non tornerà, senza questo filtro resterebbe atteso per sempre gonfiando la lista dei caduti.
    # CYRA-489 — `buildx_buildkit_*` è il builder che Docker crea per compilare e poi butta via:
    # sparire è la sua fine naturale, esattamente come per i due nomi di Kamal. Le immagini di
    # servizio delle build (database di test e simili) NON stanno qui: lo stesso nome in produzione
    # è un servizio vero, e escluderlo di default nasconderebbe un guasto — per quelle c'è
    # l'elenco per-macchina (`Servers::Host#ignored_container_patterns`).
    # CYRA-518 — quell'elenco però va compilato macchina per macchina, e sui due runner di CI nessuno
    # l'aveva compilato: 57 avvisi in 17 ore per i database che ogni lavorazione accende e spegne.
    # Il rimedio non è il nome dell'immagine (in produzione è un servizio vero) ma la FORMA del nome
    # che GitHub Actions dà ai suoi service container — `<32 esadecimali>_<immagine senza
    # punteggiatura>_<6 esadecimali>`, job e istanza — che fuori dalla CI non esiste e che nessuna
    # persona sceglierebbe. Ancorata all'intero nome e alle lunghezze fisse degli hash, così un
    # servizio vero che gli somiglia (`db_pgvectorpgvectorpg17_2b6a0f`) resta atteso e continua ad
    # avvisare. `\A`/`\Z` e non `^`/`$` perché la stessa regex gira anche in SQL (`name ~ ?`).
    ACTIONS_SERVICE_NAME = '\A[0-9a-f]{32}_[a-zA-Z0-9]+_[0-9a-f]{6}\Z'
    EPHEMERAL_NAME = /_replaced_|-exec-|buildx_buildkit|#{ACTIONS_SERVICE_NAME}/
    # CYRA-774 — nome che Kamal dà a un container versionato: `<servizio>-<ruolo>[-<destinazione>]-
    # <versione>`, dove la versione è la revisione git dell'immagine (40 esadecimali, più
    # `_uncommitted_<16>` quando si pubblica da un albero di lavoro sporco). Tutto ciò che precede
    # l'ultimo trattino è l'IDENTITÀ del servizio: sopravvive al rilascio, la versione no.
    # Il nome è l'unico posto dove quell'identità è già scritta: le etichette Docker che portano
    # servizio e ruolo NON viaggiano nel push dell'agent, e nemmeno lo stato di uscita del container
    # — senza le une né l'altro non c'è modo di distinguere «fermato per pubblicare» da «morto».
    # Ancorato all'intero nome e alla lunghezza fissa della revisione, come ACTIONS_SERVICE_NAME:
    # `db-16` e `db-17` sono due servizi che convivono, non due versioni dello stesso, e scambiarli
    # nasconderebbe un guasto vero.
    RELEASE_VERSIONED_NAME = /\A(?<prefix>.+)-[0-9a-f]{40}(?:_uncommitted_[0-9a-f]{16})?\z/
    # Quanto a lungo un container che non si vede più resta "atteso". Serve a non azzerare l'outage
    # al push successivo mentre è ancora giù; oltre la finestra si dimentica, così un nome che non
    # tornerà mai non resta appeso in eterno.
    MEMORY_WINDOW = 30.minutes

    # Set corrente dei container di un host = tutte le righe dell'ultimo recorded_at.
    def self.latest_set_for(host)
      last_at = where(host_id: host.id).maximum(:recorded_at)
      return none if last_at.nil?

      where(host_id: host.id, recorded_at: last_at).order(:name)
    end

    # Nomi la cui assenza dal push corrente va considerata un guasto. Solo campioni running: un
    # container già fermo non deve diventare atteso. Esclusi anche idle-sleep ed effimeri Kamal.
    # La finestra fa da memoria a scadenza: niente accumulo monotono.
    def self.expected_names_for(host, window: MEMORY_WINDOW, now: Time.current)
      last_seen = where(host_id: host.id, idle_managed: false, running: true)
                  .where(recorded_at: (now - window)..)
                  .where.not("name ~ ?", EPHEMERAL_NAME.source)
                  .group(:name)
                  .maximum(:recorded_at)
      # CYRA-489 — l'elenco per-macchina si applica in Ruby: sono frammenti scritti da una persona,
      # e un LIKE costruito da input libero è un'altra classe di problemi. La lista è corta per
      # validazione (20), i nomi anche.
      names = last_seen.keys.reject { |name| host.ignored_container?(name) }
      reject_superseded_releases(names, last_seen)
    end

    # CYRA-774 — di una stessa identità di rilascio resta atteso solo l'ultimo visto in piedi: le
    # versioni precedenti le ha ritirate una pubblicazione, non un guasto, e tenerle attese per tutta
    # la finestra le faceva comparire nell'avviso di un guasto successivo accanto al nome caduto
    # davvero. A parità di ultimo avvistamento restano tutte: durante il passaggio c'è un momento in
    # cui la versione nuova è già in piedi e la vecchia non è ancora stata fermata, e lì sono attese
    # entrambe per davvero.
    def self.reject_superseded_releases(names, last_seen)
      versioned, plain = names.partition { |name| release_prefix(name) }
      newest = versioned.group_by { |name| release_prefix(name) }.flat_map do |_prefix, family|
        latest = family.filter_map { |name| last_seen[name] }.max
        family.select { |name| last_seen[name] == latest }
      end
      plain + newest
    end

    # CYRA-774 — dai nomi spariti toglie quelli che un rilascio ha soltanto SOSTITUITO: stessa
    # identità di servizio, versione diversa, e il sostituto gira nel push corrente. Un rolling
    # deploy ferma il container della versione vecchia quando quello della nuova è già in piedi, e
    # senza questo filtro ogni pubblicazione produceva un «Contenitore caduto» per ogni ruolo di ogni
    # macchina — decine di avvisi falsi in cui quelli veri sparivano. Il nome vecchio resta fra i
    # caduti solo quando NESSUNA versione di quel servizio gira più: allora è un guasto.
    def self.reject_replaced_by_release(missing_names, running_names)
      live = running_names.filter_map { |name| release_prefix(name) }.to_set
      missing_names.reject { |name| live.include?(release_prefix(name)) }
    end

    # Identità di servizio di un nome versionato; nil per tutti gli altri (accessori, `kamal-proxy`,
    # container avviati a mano), che nessun rilascio può sostituire.
    def self.release_prefix(name)
      RELEASE_VERSIONED_NAME.match(name)&.[](:prefix)
    end

    # Serie per singolo container (chart drill-down): stessi bucket di Servers::Sample.
    def self.buckets_for(host, name, range, now = Time.current)
      cfg = Servers::Sample.bucket_config(range)
      since = now - (cfg[:count] * cfg[:seconds])
      conn = connection
      bin = "date_bin(#{conn.quote(cfg[:interval])}::interval, recorded_at, #{conn.quote(since)}::timestamptz)"
      rows = where(host_id: host.id, name: name, recorded_at: since...now)
             .group(Arel.sql(bin))
             .pluck(Arel.sql(bin), Arel.sql("COUNT(*)"), Arel.sql("AVG(cpu_pct)"), Arel.sql("AVG(mem_bytes)"))

      result = Array.new(cfg[:count]) { { count: 0, cpu: nil, mem_bytes: nil } }
      rows.each do |bucket_time, count, cpu, mem|
        # round, non floor: `since` ha i nanosecondi e il bin torna dal DB al microsecondo, un soffio prima.
        idx = ((bucket_time.to_time - since) / cfg[:seconds]).round
        # simplecov:disable guardia difensiva — idx sempre in range per costruzione della query (vedi Sample).
        next unless idx.between?(0, cfg[:count] - 1)

        result[idx] = { count: count, cpu: cpu&.to_f&.round(1), mem_bytes: mem&.to_i }
        # simplecov:enable
      end
      result
    end
  end
end
