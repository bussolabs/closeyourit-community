# frozen_string_literal: true

require "rails_helper"

# CYRA-246: le lavorazioni AI (training/predizioni, ~fino a un'ora) devono avere una corsia di worker
# separata dal monitoraggio real-time (ricezione dati, controlli siti, avvisi, notifiche). Con un solo
# pool "*" a 3 slot, tre addestramenti li occupavano tutti e il prodotto smetteva di monitorare.
RSpec.describe "config/queue.yml" do
  # Nomi delle code prodotte dal framework, non da un ApplicationJob: se non fossero coperte da nessun
  # pool i relativi job non girerebbero MAI (degrado silenzioso).
  #   default  -> ActiveStorage (analyze/purge) e fallback ActiveJob
  #   mailers  -> ActionMailer#deliver_later (reset password, inviti, avvisi, digest)
  FRAMEWORK_QUEUES = %w[default mailers].freeze

  let(:workers) do
    raw = ERB.new(File.read(Rails.root.join("config/queue.yml"))).result
    YAML.safe_load(raw, aliases: true).fetch("production").fetch("workers")
  end

  def pool_queues(pool)
    Array(pool.fetch("queues")).flat_map { |value| value.to_s.split(",") }.map(&:strip)
  end

  let(:configured_queues) { workers.flat_map { |w| pool_queues(w) } }

  let(:ai_pool) { workers.find { |w| pool_queues(w).include?("ai") } }
  let(:ai_pool_queues) { pool_queues(ai_pool) }

  let(:ingest_pool) { workers.find { |w| pool_queues(w).include?("ingest") } }
  let(:ingest_pool_queues) { pool_queues(ingest_pool) }

  let(:embeddings_pool) { workers.find { |w| pool_queues(w).include?("embeddings") } }
  let(:embeddings_pool_queues) { pool_queues(embeddings_pool) }

  let(:maintenance_pool) { workers.find { |w| pool_queues(w).include?("maintenance") } }
  let(:maintenance_pool_queues) { pool_queues(maintenance_pool) }

  # Individuato da una coda che gli appartiene e non per esclusione: con l'esclusione, ogni corsia
  # isolata nuova che ci si dimenticava di togliere da qui faceva restituire a `find` il pool
  # sbagliato, e gli spec sulle priorità finivano a guardare un'altra corsia senza dirlo.
  let(:realtime_pool) { workers.find { |w| pool_queues(w).include?("alerts") } }
  let(:realtime_queues) { pool_queues(realtime_pool) }

  let(:job_queues) do
    Rails.application.eager_load!
    ApplicationJob.descendants.map { |klass| klass.new.queue_name }.uniq
  end

  it "nessun pool usa il jolly '*': vanificherebbe l'isolamento dell'AI" do
    expect(configured_queues).not_to include("*")
  end

  # Il buco che ha fermato TUTTI i job in produzione per due giorni: la configurazione diceva
  # `queues: "alerts,uptime,…"` e questo spec, che spezzava lui la stringa sulle virgole, la leggeva
  # come sette code e passava. Solid Queue non la spezza: cerca una coda che si chiama letteralmente
  # "alerts,uptime,…", non la trova mai, e i worker restano a girare a vuoto senza un solo errore.
  # Da qui in poi la domanda la si fa a Solid Queue, non a noi stessi: uno spec che ricostruisce da sé
  # l'intenzione può solo confermarla, mai smentirla.
  describe "la configurazione è interpretabile da Solid Queue" do
    it "ogni pool dichiara le code come lista, non come stringa con virgole" do
      workers.each do |pool|
        expect(pool.fetch("queues")).to be_an(Array),
                                        "il pool #{pool.fetch('queues').inspect} è una stringa: Solid Queue la userebbe come nome di coda unico"
      end
    end

    it "il selettore di Solid Queue produce una relazione per ogni coda dichiarata" do
      workers.each do |pool|
        relations = SolidQueue::QueueSelector.new(pool.fetch("queues"), SolidQueue::ReadyExecution).scoped_relations
        expect(relations.size).to eq(pool_queues(pool).size),
                                  "il pool #{pool.fetch('queues').inspect} genera #{relations.size} relazioni invece di #{pool_queues(pool).size}"
      end
    end

    it "ogni coda dichiarata compare davvero nella query che il worker eseguirà" do
      workers.each do |pool|
        sql = SolidQueue::QueueSelector.new(pool.fetch("queues"), SolidQueue::ReadyExecution)
                                       .scoped_relations.map(&:to_sql).join(" ")
        pool_queues(pool).each do |queue|
          expect(sql).to include("'#{queue}'"), "la coda '#{queue}' non compare nella query del suo pool"
        end
      end
    end
  end

  it "ogni coda usata da un job è coperta da un pool (niente code orfane)" do
    (job_queues + FRAMEWORK_QUEUES).uniq.each do |queue|
      expect(configured_queues).to include(queue), "coda '#{queue}' non coperta da nessun pool in queue.yml"
    end
  end

  # CYRA-851 — un task di recurring.yml senza `queue:` esplicita non eredita la corsia del job: finisce
  # su `solid_queue_recurring`, che nessun pool serve. Non fallisce e non logga: i job si accumulano
  # ready per sempre. È successo a `clear_solid_queue_finished_jobs` dal 07/08 al 02/09/2026 — 628
  # lavori morti, scoperti solo guardando le code a mano. Lo spec sopra copre i job (`ApplicationJob`),
  # non i ricorrenti, che non sono sue sottoclassi: è per questo che il buco è passato.
  describe "code dei giri ricorrenti (CYRA-851)" do
    let(:recurring_tasks) do
      raw = ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result
      YAML.safe_load(raw, aliases: true).fetch("production")
    end

    it "ogni giro dichiara la sua coda" do
      senza = recurring_tasks.reject { |_, task| task["queue"].present? }.keys

      expect(senza).to be_empty,
                       "#{senza.join(', ')}: senza `queue:` finiscono su solid_queue_recurring, che nessun worker serve"
    end

    it "ogni coda dichiarata da un giro è servita da un pool" do
      recurring_tasks.each do |name, task|
        expect(configured_queues).to include(task["queue"]),
                                     "il giro '#{name}' usa la coda '#{task['queue']}', che nessun pool di queue.yml serve"
      end
    end

    it "nessun giro finisce sulla coda di default di Solid Queue" do
      orfani = recurring_tasks.select { |_, task| task["queue"] == "solid_queue_recurring" }.keys

      expect(orfani).to be_empty
    end
  end

  describe "isolamento della corsia AI" do
    it "esiste un pool dedicato che contiene la coda ai" do
      expect(ai_pool).to be_present
    end

    it "il pool AI NON condivide slot con il monitoraggio real-time" do
      expect(ai_pool_queues).not_to include("ingest", "uptime", "alerts", "notifications", "servers")
    end

    it "il pool AI ha un solo thread: un addestramento lungo non satura la macchina" do
      expect(ai_pool.fetch("threads")).to eq(1)
    end
  end

  # CYRA-301 — «ultima della lista» non bastava: l'ordine è una priorità STRETTA, quindi finché una
  # coda che sta prima ha lavoro, ingest non viene servita affatto. Dal 07/08 al 09/08 uptime e alerts
  # l'hanno affamata per ore (600k job arretrati, rate netto zero, tutti i 17 server segnati offline
  # pur essendo attivi). Una corsia riservata è l'unica forma di isolamento: più capacità sullo stesso
  # pool avrebbe solo spostato la soglia.
  describe "corsia riservata alla ricezione dati (CYRA-301)" do
    it "esiste un pool che serve SOLO la ricezione dati" do
      expect(ingest_pool).to be_present
      expect(ingest_pool_queues).to eq(%w[ingest])
    end

    it "nessun altro pool serve ingest: niente coda prioritaria davanti ai dati" do
      other_pools = workers - [ ingest_pool ]
      expect(other_pools.flat_map { |pool| pool_queues(pool) }).not_to include("ingest")
    end

    it "il pool della ricezione dati ha thread propri, non condivisi col real-time" do
      expect(ingest_pool.fetch("threads")).to be >= 1
    end
  end

  # CYRA-649 — l'embedding di una riga è una chiamata HTTP a un servizio che gira sulla stessa
  # macchina e ne consuma la CPU. Finché stava sulla coda `ingest`, i backfill notturni (quattro job
  # che accodano un embed per riga) riempivano la corsia della ricezione dati: i dati dei server
  # arrivavano con 6 minuti di ritardo e il controllo di staleness marcava giù 19 macchine sane,
  # ~76 avvisi falsi al giorno. Corsia propria, non in coda al pool AI: l'embed di un ticket appena
  # creato serve subito per la ricerca duplicati e dietro `maintenance`/`ai` aspetterebbe troppo.
  # CYRA-764 — ogni verdetto è una chiamata al modello del server AI di casa (~25 token/secondo):
  # una pagina alla volta, su una corsia che un addestramento sulla coda `ai` non può bloccare.
  describe "corsia riservata al revisore knowledge (CYRA-764)" do
    let(:review_pool) { workers.find { |w| pool_queues(w).include?("knowledge_review") } }

    it "esiste un pool che serve SOLO knowledge_review, con un thread" do
      expect(review_pool).to be_present
      expect(pool_queues(review_pool)).to eq(%w[knowledge_review])
      expect(review_pool.fetch("threads")).to eq(1)
    end

    it "nessun altro pool la serve" do
      expect((workers - [ review_pool ]).flat_map { |pool| pool_queues(pool) }).not_to include("knowledge_review")
    end

    it "Knowledge::ReviewPageJob ci gira sopra" do
      expect(Knowledge::ReviewPageJob.new.queue_name).to eq("knowledge_review")
    end
  end

  # CYRA-850 — il sample di un server è l'unico ingest il cui RITARDO produce un falso allarme, non
  # solo un dato tardivo: `Servers::CheckStaleJob` legge il silenzio a 180s come «macchina caduta».
  # Finché stava su `ingest` insieme alle metriche di ogni applicazione monitorata, il volume di un
  # tenant diventava l'avviso di un altro — il 16/09/2026 un'app a 528 metriche/min ha portato i dati
  # dei server a 16 minuti di ritardo e ha fatto suonare 8 host sani. Corsia propria e non un posto
  # nel pool real-time: lì il bulk dei sample competerebbe con gli AVVISI, che è il caso peggiore.
  describe "corsia riservata all'ingest dei server (CYRA-850)" do
    let(:servers_pool) { workers.find { |w| pool_queues(w).include?("servers_ingest") } }

    it "esiste un pool che serve SOLO l'ingest dei server" do
      expect(servers_pool).to be_present
      expect(pool_queues(servers_pool)).to eq(%w[servers_ingest])
    end

    it "Servers::IngestJob ci gira sopra, non più sulla ricezione dati generica" do
      expect(Servers::IngestJob.new.queue_name).to eq("servers_ingest")
    end

    it "nessun altro pool la serve: il ritardo di un'altra coda non può arrivare qui" do
      expect((workers - [ servers_pool ]).flat_map { |pool| pool_queues(pool) }).not_to include("servers_ingest")
    end

    it "non è finita nel pool real-time, dove competerebbe con gli avvisi" do
      expect(realtime_queues).not_to include("servers_ingest")
    end
  end

  # CYRA-850 — secondo difetto della stessa fila: dentro `ingest` l'ordine è di arrivo, quindi
  # un'applicazione monitorata rumorosa può occupare TUTTI i thread e le altre restano fuori. Il tetto
  # per progetto lascia sempre almeno uno slot libero a chi non sta facendo rumore. Il confronto è con
  # i thread della corsia e non con un numero scritto a mano: alzare i thread senza rialzare il tetto
  # renderebbe il tetto inutile, abbassarli sotto il tetto lo renderebbe una finta.
  describe "tetto per progetto sulle metriche (CYRA-850)" do
    it "Metrics::IngestJob dichiara un limite di concorrenza" do
      expect(Metrics::IngestJob.concurrency_limit).to be_present
    end

    it "il limite lascia sempre almeno uno slot della corsia agli altri progetti" do
      expect(Metrics::IngestJob.concurrency_limit).to be < ingest_pool.fetch("threads")
    end
  end

  describe "corsia riservata agli embedding (CYRA-649)" do
    let(:embed_jobs) do
      %w[Ticketing::EmbedTicketJob Errors::EmbedGroupJob Ideas::EmbedIdeaJob Knowledge::EmbedPageJob]
    end

    it "esiste un pool che serve SOLO gli embedding" do
      expect(embeddings_pool).to be_present
      expect(embeddings_pool_queues).to eq(%w[embeddings])
    end

    it "nessun job di embedding resta sulla corsia della ricezione dati" do
      Rails.application.eager_load!
      embed_jobs.each do |name|
        expect(name.constantize.new.queue_name).to eq("embeddings"),
                                                   "#{name} sta ancora sulla coda '#{name.constantize.new.queue_name}'"
      end
    end

    it "nessun altro pool serve embeddings: un backlog di embed resta confinato lì" do
      other_pools = workers - [ embeddings_pool ]
      expect(other_pools.flat_map { |pool| pool_queues(pool) }).not_to include("embeddings")
    end
  end

  # Solid Queue serve le code di una lista una alla volta, in ordine, finché hanno lavoro: l'ordine è
  # una priorità stretta. L'ordine scelto evita che una coda ad alto volume ne affami un'altra.
  describe "priorità delle code (anti-starvation)" do
    it "nel pool real-time i critici a basso volume vengono prima dei job di sistema" do
      expect(realtime_queues.index("uptime")).to be < realtime_queues.index("default")
      expect(realtime_queues.index("alerts")).to be < realtime_queues.index("default")
    end

    it "nel pool dei lavori lunghi l'addestramento sta per ultimo: non affama gli altri lavori lunghi" do
      expect(ai_pool_queues.index("batch")).to be < ai_pool_queues.index("ai")
      expect(ai_pool_queues.index("seo")).to be < ai_pool_queues.index("ai")
    end
  end

  # CYRA-714 — `maintenance`, `seo` e `ai` stavano nello STESSO pool a un thread. L'ordine è una
  # priorità stretta, quindi un addestramento (fino a un'ora) non veniva scavalcato da niente: chi
  # arrivava dopo aspettava la fine, compresi i giri che scattano ogni minuto sulle lavorazioni degli
  # agenti. Il rimedio adottato allora era spostare gli orari a mano — `backfill_log_trace_ids` alle
  # 4:30, `check_mail_sender` alle 6:30, `dispatch_seo_lab_runs` al minuto 35 — che sposta il
  # problema di un'ora invece di toglierlo, e non serve a niente contro un lavoro lungo qualunque.
  #
  # Due corsie: `maintenance` per i controlli (secondi, alta frequenza) e una per i lavori lunghi
  # (`seo`, `batch`, `ai`). La separazione è per CODA e non per thread in più, per la stessa ragione
  # di ingest ed embeddings: dentro una coda l'ordine è di arrivo, quindi i venti prune delle 3 di
  # notte precedono comunque il controllo accodato alle 3:01, e più capacità sposta la soglia senza
  # togliere l'attesa.
  describe "i controlli frequenti non aspettano i lavori lunghi (CYRA-714)" do
    let(:recurring_tasks) do
      raw = ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result
      YAML.safe_load(raw, aliases: true).fetch("production")
    end

    # La coda su cui il giro finisce davvero. La risposta la dà Ops::RecurringQueueCoverage, che la
    # chiede a Solid Queue.
    #
    # CYRA-785 — qui c'era scritto che «i task `command:` non hanno classe e restano su "default"».
    # È falso: Solid Queue li avvolge in SolidQueue::RecurringJob, che ha `queue_as
    # :solid_queue_recurring` scritto nella gemma. Quella credenza ha tenuto ferma per quattro
    # settimane la potatura oraria dei job finiti, e questo spec passava perché controllava la
    # propria versione dei fatti invece di quella di Solid Queue.
    def queue_of(task)
      Ops::RecurringQueueCoverage.queue_for(task)
    end

    it "esiste una corsia dei controlli che nessun lavoro lungo può occupare" do
      expect(maintenance_pool).to be_present
      expect(maintenance_pool_queues).to eq(%w[maintenance]),
                                         "la corsia dei controlli serve anche #{(maintenance_pool_queues - %w[maintenance]).inspect}: " \
                                         "un lavoro lungo lì dentro rimette i controlli in fila dietro di sé"
    end

    it "nessun altro pool serve maintenance: la corsia dei controlli resta sua" do
      other_pools = workers - [ maintenance_pool ]
      expect(other_pools.flat_map { |pool| pool_queues(pool) }).not_to include("maintenance")
    end

    it "il pool dei lavori lunghi non serve la corsia dei controlli" do
      expect(ai_pool_queues).not_to include("maintenance")
    end

    # Lo scenario del ticket, letto dalla configurazione vera: un giro che scatta ogni minuto non può
    # stare su una coda che un addestramento è in grado di occupare.
    it "ogni giro che scatta almeno ogni 15 minuti sta fuori dal pool dei lavori lunghi" do
      Rails.application.eager_load!

      recurring_tasks.each do |name, task|
        frequenza = Fugit.parse(task.fetch("schedule")).rough_frequency
        next if frequenza > 15.minutes

        expect(ai_pool_queues).not_to include(queue_of(task)),
                                      "'#{name}' scatta ogni #{frequenza} secondi sulla coda '#{queue_of(task)}', che il pool " \
                                      "#{ai_pool_queues.inspect} serve un lavoro alla volta: un addestramento lungo lo terrebbe fermo"
      end
    end

    # I giri che attraversano tabelle intere (potature, recuperi, aggregazioni) durano minuti e
    # partono a mucchi la notte. Su una corsia a bassa latenza mettono in fila tutto ciò che arriva
    # dopo, quindi hanno una coda propria: qui la regola vale per costruzione anche per i job che
    # verranno, che nascono con lo stesso nome.
    it "potature, recuperi e aggregazioni girano tutti sulla corsia dei lavori lunghi" do
      Rails.application.eager_load!

      lunghi = ApplicationJob.descendants.select { |klass| klass.name.to_s.match?(/(Prune|Backfill|Rollup)/) }
      expect(lunghi).not_to be_empty, "nessun job trovato: il filtro sui nomi non pesca più niente"

      lunghi.each do |klass|
        expect(klass.new.queue_name).to eq("batch"),
                                        "#{klass.name} gira su '#{klass.new.queue_name}': un giro che attraversa una tabella " \
                                        "intera su una corsia a bassa latenza mette in fila tutto ciò che arriva dopo"
      end
    end

    it "la corsia dei lavori lunghi ha un solo thread e un solo processo" do
      expect(ai_pool.fetch("threads")).to eq(1)
      expect(ai_pool.fetch("processes")).to eq(1)
    end
  end
end
