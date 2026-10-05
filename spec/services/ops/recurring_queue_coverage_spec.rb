# frozen_string_literal: true

require "rails_helper"

# CYRA-785 — un giro ricorrente può finire su una coda che nessun pool di worker serve. Non solleva
# niente: i job si accodano e restano lì per sempre.
#
# È già successo. `clear_solid_queue_finished_jobs` è un task scritto con `command:` e fino a
# CYRA-714 non aveva `queue:`. Un task `command:` NON gira su "default": Solid Queue lo avvolge in
# SolidQueue::RecurringJob, che ha `queue_as :solid_queue_recurring` scritto nella gemma. Nessun pool
# di config/queue.yml serve quella coda, quindi la potatura oraria dei job finiti non ha girato dal
# 2026-08-07 al 2026-09-02 — 628 job accumulati, zero errori, nessuno se n'è accorto.
#
# Il controllo qui NON ricostruisce l'intenzione: chiede a Solid Queue su quale coda finirebbe
# davvero ogni task, con la stessa API che usa il supervisor. Uno spec che si ricostruisce da sé la
# risposta può solo confermare la propria credenza — ed è esattamente la credenza sbagliata che ci
# è costata quattro settimane.
RSpec.describe Ops::RecurringQueueCoverage, type: :service do
  describe ".queue_for" do
    it "un task con `class:` finisce sulla coda dichiarata dal job" do
      task = { "class" => "Ops::CacheCanaryJob", "schedule" => "every minute" }

      expect(described_class.queue_for(task)).to eq(Ops::CacheCanaryJob.new.queue_name)
    end

    it "`queue:` esplicito vince sulla coda del job" do
      task = { "class" => "Ops::CacheCanaryJob", "queue" => "batch", "schedule" => "every minute" }

      expect(described_class.queue_for(task)).to eq("batch")
    end

    # Il cuore del ticket: la credenza sbagliata diceva "default".
    it "un task `command:` SENZA `queue:` finisce su solid_queue_recurring, non su default" do
      task = { "command" => "Rails.logger.info('x')", "schedule" => "every hour" }

      expect(described_class.queue_for(task)).to eq("solid_queue_recurring")
      expect(described_class.queue_for(task)).not_to eq("default")
    end

    it "un task `command:` CON `queue:` finisce dove dice il file" do
      task = { "command" => "Rails.logger.info('x')", "queue" => "batch", "schedule" => "every hour" }

      expect(described_class.queue_for(task)).to eq("batch")
    end
  end

  describe ".worker_queues" do
    it "elenca le code servite dai pool di config/queue.yml" do
      expect(described_class.worker_queues).to include("maintenance", "batch", "ingest", "embeddings")
    end

    it "non contiene la coda della gemma: è proprio il buco che cerchiamo" do
      expect(described_class.worker_queues).not_to include("solid_queue_recurring")
    end

    # Il guasto che ha fermato TUTTI i job in produzione per due giorni: `queues: "alerts,uptime"`
    # non sono due code, è UNA coda che si chiama letteralmente "alerts,uptime" e che non esiste.
    # Se spezzassimo noi sulla virgola, questo controllo direbbe che alerts e uptime sono servite
    # mentre in realtà non le serve nessuno: un falso negativo proprio nello scenario peggiore.
    it "una stringa con virgole è UN nome di coda, non due: niente falsi negativi" do
      pool = SolidQueue::Configuration::Process.new(:worker, { queues: "alerts,uptime" })
      allow(SolidQueue::Configuration).to receive(:new).and_return(
        instance_double(SolidQueue::Configuration, configured_processes: [ pool ])
      )

      expect(described_class.worker_queues).to eq([ "alerts,uptime" ])
      expect(described_class.worker_queues).not_to include("alerts", "uptime")
    end
  end

  # I selettori di Solid Queue: "*" serve TUTTE le code, "prefisso*" tutte quelle che iniziano così.
  # Trattarli come nomi letterali dichiarerebbe scoperte code che invece qualcuno serve — e, peggio,
  # renderebbe cancellabili i loro job da Ops::OrphanRecurringJobs.
  describe ".covered?" do
    def con_pool(queues)
      pool = SolidQueue::Configuration::Process.new(:worker, { queues: })
      allow(SolidQueue::Configuration).to receive(:new).and_return(
        instance_double(SolidQueue::Configuration, configured_processes: [ pool ])
      )
    end

    it "il jolly copre qualunque coda" do
      con_pool([ "*" ])

      expect(described_class.covered?("una_coda_qualunque")).to be(true)
    end

    it "il jolly vale anche se sta accanto ad altri nomi" do
      con_pool([ "alerts", "*" ])

      expect(described_class.covered?("solid_queue_recurring")).to be(true)
    end

    it "il prefisso copre le code che iniziano così" do
      con_pool([ "agents*" ])

      expect(described_class.covered?("agents_slow")).to be(true)
      expect(described_class.covered?("agents")).to be(true)
    end

    it "il prefisso non copre chi non inizia così" do
      con_pool([ "agents*" ])

      expect(described_class.covered?("batch")).to be(false)
    end

    it "un nome esatto copre solo se stesso" do
      con_pool([ "batch" ])

      expect(described_class.covered?("batch")).to be(true)
      expect(described_class.covered?("batch_lento")).to be(false)
    end
  end

  describe ".queue_for con argomenti" do
    # Solid Queue converte l'ULTIMO hash degli `args` in keyword arguments
    # (RecurringTask#arguments_with_kwargs). Senza la stessa conversione, un job che accetta kwargs
    # solleva ArgumentError — e un errore qui spegnerebbe tutta la guardia.
    it "un job con kwargs non fa saltare la risoluzione" do
      task = { "class" => "Ops::JobConKwargs", "args" => [ 1, { "modo" => "veloce" } ], "schedule" => "every hour" }
      stub_const("Ops::JobConKwargs", Class.new(ApplicationJob) do
        queue_as :batch
        def perform(_numero, modo:) = modo
      end)

      expect(described_class.queue_for(task)).to eq("batch")
    end

    it "se la coda non è calcolabile lo dice invece di far cadere tutto" do
      task = { "class" => "Ops::JobRognoso", "schedule" => "every hour" }
      stub_const("Ops::JobRognoso", Class.new(ApplicationJob) do
        queue_as { raise "non si può sapere" }
      end)

      expect(described_class.queue_for(task)).to eq(described_class::UNKNOWN_QUEUE)
    end
  end

  describe ".uncovered" do
    it "segnala un task su una coda che nessun pool serve" do
      tasks = { "un_giro_scoperto" => { "command" => "Rails.logger.info('x')", "schedule" => "every hour" } }

      expect(described_class.uncovered(tasks:)).to eq([ { key: "un_giro_scoperto", queue: "solid_queue_recurring" } ])
    end

    it "non segnala nulla quando ogni task sta su una coda servita" do
      tasks = { "un_giro_coperto" => { "command" => "Rails.logger.info('x')", "queue" => "batch", "schedule" => "every hour" } }

      expect(described_class.uncovered(tasks:)).to be_empty
    end

    # Il gate vero: la configurazione di produzione, letta com'è. Se qualcuno aggiunge un giro su una
    # coda scoperta, questo test diventa rosso prima del merge.
    it "config/recurring.yml non ha nemmeno un giro scoperto" do
      scoperti = described_class.uncovered

      expect(scoperti).to be_empty,
                          "giri su code che nessun pool di config/queue.yml serve: #{scoperti.inspect}. " \
                          "Aggiungi `queue:` al task in config/recurring.yml, oppure la coda a un pool in config/queue.yml."
    end
  end
end
