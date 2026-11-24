# frozen_string_literal: true

require "rails_helper"

# Liveness del motore dei job servita dal WEB, indipendente dal worker (CYRA-209). È l'endpoint che un
# guardiano ESTERNO interroga per accorgersi che i controlli non girano più — /up resta liveness pura.
RSpec.describe "Workers health", type: :request do
  def register_process(last_heartbeat_at:, kind: "Worker", name: "worker-1")
    SolidQueue::Process.create!(kind:, name:, pid: 1, last_heartbeat_at:)
  end

  def create_job(class_name: "Uptime::CheckJob", queue_name: "uptime", **attributes)
    SolidQueue::Job.create!(queue_name:, class_name:, priority: 0,
                            active_job_id: SecureRandom.uuid, arguments: { "arguments" => [] },
                            **attributes)
  end

  # `SolidQueue::Job.create!` accoda già da sé: `after_create :prepare_for_execution` crea la ready
  # execution. Crearne una seconda a mano viola l'indice unico su job_id.
  #
  # Una corsia è ferma solo se il suo lavoro pronto ASPETTA da oltre la soglia (CYRA-1229): di default
  # la ready execution è retrodatata a un'ora, cioè oltre la soglia delle corsie rapide, così i casi
  # di stallo scritti prima delle corsie descrivono ancora un lavoro che aspetta davvero.
  def ready_execution(class_name: "Uptime::CheckJob", queue_name: "uptime", waiting_since: 1.hour.ago)
    create_job(class_name:, queue_name:).ready_execution.tap do |execution|
      execution.update_columns(created_at: waiting_since)
    end
  end

  # Nel motore vero un job finito non ha più una ready execution: il worker la consuma quando lo
  # reclama. Il callback di creazione la accoda comunque, quindi qui va tolta — altrimenti ogni job
  # "finito" gonfia ready_count e la coda non risulta mai vuota.
  def finished_job(finished_at:, class_name: "Uptime::CheckJob", queue_name: "uptime")
    create_job(class_name:, queue_name:, finished_at:).tap { |job| job.ready_execution&.destroy }
  end

  # La corsia real-time di config/queue.yml, col nome che la risposta le dà.
  let(:realtime_lane) { "alerts+uptime+notifications+servers+mailers+default" }

  # Un'altra corsia che lavora: un job finito ogni minuto dell'ultima decina. Fixture in serie nel
  # setup: le letture per job (ready execution, job) sono dei callback di Solid Queue, non della
  # richiesta sotto prova — fuori dallo scan N+1.
  def keep_realtime_lane_busy
    allow_n_plus_one { (1..10).each { |minutes| finished_job(finished_at: minutes.minutes.ago) } }
  end

  # Un lavoro in attesa su ogni corsia, fuori dallo scan N+1 per lo stesso motivo.
  def stall_every_lane(waiting_since:)
    Ops::QueueThroughput.lanes.tap do |lanes|
      allow_n_plus_one { lanes.each { |selectors| ready_execution(queue_name: selectors.first, waiting_since:) } }
    end
  end

  describe "GET /up/workers" do
    it "200 workers:up quando il motore dei job batte" do
      register_process(last_heartbeat_at: Time.current)

      get "/up/workers"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["workers"]).to eq("up")
      expect(response.parsed_body["last_heartbeat_at"]).to be_present
    end

    it "503 workers:down quando il worker è fermo (nessun battito recente)" do
      register_process(last_heartbeat_at: 10.minutes.ago)

      get "/up/workers"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["workers"]).to eq("down")
      expect(response.parsed_body["last_heartbeat_at"]).to be_nil
    end

    it "503 quando non c'è alcun processo registrato" do
      get "/up/workers"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["workers"]).to eq("down")
    end

    it "503 se batte solo il Supervisor ma nessun Worker (l'esecutore è fermo)" do
      register_process(last_heartbeat_at: Time.current, kind: "Supervisor(fork)", name: "sup")

      get "/up/workers"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["workers"]).to eq("down")
    end

    it "503 queue:stalled quando ci sono ready pronte ma nessun job finisce da oltre la soglia, anche a workers:up" do
      register_process(last_heartbeat_at: Time.current)
      ready_execution
      finished_job(finished_at: 1.hour.ago)

      get "/up/workers"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["workers"]).to eq("up")
      expect(response.parsed_body["queue"]).to eq("stalled")
      expect(response.parsed_body["ready_count"]).to eq(1)
    end

    it "200 queue:up quando la coda è vuota, anche se l'ultimo job è finito ore fa" do
      register_process(last_heartbeat_at: Time.current)
      finished_job(finished_at: 5.hours.ago)

      get "/up/workers"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["queue"]).to eq("up")
      expect(response.parsed_body["ready_count"]).to eq(0)
    end

    it "503 con workers:down e queue:stalled insieme quando entrambi i segnali sono giù" do
      register_process(last_heartbeat_at: 10.minutes.ago)
      ready_execution

      get "/up/workers"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["workers"]).to eq("down")
      expect(response.parsed_body["queue"]).to eq("stalled")
    end

    it "boundary: 200 queue:up quando l'ultimo job è finito appena dentro la soglia" do
      register_process(last_heartbeat_at: Time.current)
      ready_execution
      finished_job(finished_at: Ops::QueueThroughput::STALL_THRESHOLD.ago + 1.minute)

      get "/up/workers"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["queue"]).to eq("up")
    end

    it "boundary: 503 queue:stalled quando l'ultimo job è finito appena oltre la soglia" do
      register_process(last_heartbeat_at: Time.current)
      ready_execution
      finished_job(finished_at: Ops::QueueThroughput::STALL_THRESHOLD.ago - 1.minute)

      get "/up/workers"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["queue"]).to eq("stalled")
    end

    # -------------------------------------------------------------------------------------------
    # Una corsia alla volta (CYRA-1229)
    # -------------------------------------------------------------------------------------------
    describe "per corsia" do
      before { register_process(last_heartbeat_at: Time.current) }

      it "503 e nomina la corsia rapida ferma da 15 minuti con lavoro in attesa" do
        ready_execution(class_name: "Servers::IngestJob", queue_name: "ingest", waiting_since: 15.minutes.ago)
        keep_realtime_lane_busy

        get "/up/workers"

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["queue"]).to eq("stalled")
        expect(response.parsed_body["stalled_lanes"]).to eq([ "ingest" ])
      end

      it "503 anche se un'altra corsia finisce lavori ogni minuto" do
        ready_execution(class_name: "Embeddings::EmbedJob", queue_name: "embeddings", waiting_since: 15.minutes.ago)
        keep_realtime_lane_busy

        get "/up/workers"

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["last_finished_at"]).to be_present
        expect(response.parsed_body["stalled_lanes"]).to eq([ "embeddings" ])
      end

      it "elenca per nome la sola corsia ferma, e il nome è l'elenco delle sue code" do
        ready_execution(waiting_since: 15.minutes.ago)
        finished_job(finished_at: 1.minute.ago, class_name: "Servers::IngestJob", queue_name: "ingest")

        get "/up/workers"

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["stalled_lanes"]).to eq([ realtime_lane ])
      end

      it "200 per una corsia senza lavoro in attesa, mentre le altre lavorano" do
        finished_job(finished_at: 3.hours.ago, class_name: "Servers::IngestJob", queue_name: "ingest")
        keep_realtime_lane_busy

        get "/up/workers"

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["stalled_lanes"]).to eq([])
      end

      it "200 per una corsia vuota il cui ultimo lavoro è finito ore fa" do
        finished_job(finished_at: 5.hours.ago, class_name: "Ai::TrainJob", queue_name: "ai")
        finished_job(finished_at: 5.hours.ago)

        get "/up/workers"

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["queue"]).to eq("up")
        expect(response.parsed_body["stalled_lanes"]).to eq([])
      end

      it "200 con un lavoro lungo in attesa da 40 minuti e nient'altro che finisce" do
        ready_execution(class_name: "Ai::TrainJob", queue_name: "ai", waiting_since: 40.minutes.ago)

        get "/up/workers"

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["queue"]).to eq("up")
      end

      it "503 e nomina la corsia dei lavori lunghi quando un suo lavoro aspetta da 100 minuti" do
        ready_execution(class_name: "Ai::TrainJob", queue_name: "ai", waiting_since: 100.minutes.ago)
        keep_realtime_lane_busy

        get "/up/workers"

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["stalled_lanes"]).to eq([ "batch+ai" ])
      end

      it "200 con un giro SEO in attesa da due ore, 503 oltre i 150 minuti" do
        ready_execution(class_name: "Seo::CrawlJob", queue_name: "seo", waiting_since: 2.hours.ago)

        get "/up/workers"
        expect(response).to have_http_status(:ok)

        SolidQueue::ReadyExecution.update_all(created_at: 160.minutes.ago)

        get "/up/workers"
        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["stalled_lanes"]).to eq([ "seo" ])
      end

      it "503 quando si ferma tutto da 11 minuti, e nomina le corsie rapide" do
        lanes = stall_every_lane(waiting_since: 11.minutes.ago)
        rapide = lanes.select { |selectors| Ops::QueueThroughput.threshold_for(selectors) == Ops::QueueThroughput::STALL_THRESHOLD }
                      .map { |selectors| Ops::QueueThroughput.lane_name(selectors) }

        get "/up/workers"

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["stalled_lanes"]).to match_array(rapide)
        expect(response.parsed_body["stalled_lanes"]).to include(realtime_lane, "ingest")
        expect(response.parsed_body["stalled_lanes"]).not_to include("batch+ai", "seo")
      end

      it "200 con un arretrato di 30 minuti su una corsia rapida che ha finito un lavoro 2 minuti fa" do
        ready_execution(waiting_since: 30.minutes.ago)
        finished_job(finished_at: 2.minutes.ago)

        get "/up/workers"

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["queue"]).to eq("up")
      end

      it "con tutte le corsie ferme, i loro nomi stanno nella parte di risposta che il guardiano copia nell'avviso" do
        lanes = stall_every_lane(waiting_since: 3.hours.ago)
        limit = Rails.root.join(".github/workflows/workers-watchdog.yml").read[/\.slice\(0, (\d+)\)/, 1].to_i

        get "/up/workers"

        copied = response.body[0, limit]
        expect(response.parsed_body["stalled_lanes"].size).to eq(lanes.size)
        response.parsed_body["stalled_lanes"].each { |lane| expect(copied).to include(%("#{lane}")) }
      end
    end

    # -------------------------------------------------------------------------------------------
    # Conteggio con un tetto (CYRA-1273)
    # -------------------------------------------------------------------------------------------
    describe "conteggio dei lavori pronti" do
      let(:cap) { Ops::QueueThroughput::READY_COUNT_CAP }

      # Una coda vera oltre il tetto, scritta in blocco: diecimila create! una per una sarebbero
      # minuti di prova per un setup che il motore stesso fa con insert_all.
      def fill_queue(size, queue_name: "uptime", waiting_since: 1.minute.ago)
        jobs = Array.new(size) do
          { queue_name:, class_name: "Uptime::CheckJob", priority: 0, active_job_id: SecureRandom.uuid,
            arguments: { "arguments" => [] } }
        end
        ids = SolidQueue::Job.insert_all!(jobs, returning: %w[id]).rows.flatten
        SolidQueue::ReadyExecution.insert_all!(ids.map { |job_id| { job_id:, queue_name:, priority: 0, created_at: waiting_since } })
      end

      before { register_process(last_heartbeat_at: Time.current) }

      it "il tetto è di 10000 lavori" do
        expect(cap).to eq(10_000)
      end

      it "con più lavori del tetto riporta il tetto e dice che è stato raggiunto" do
        fill_queue(cap + 1)

        get "/up/workers"

        expect(response.parsed_body["ready_count"]).to eq(cap)
        expect(response.parsed_body["ready_count_capped"]).to be(true)
      end

      it "sotto il tetto riporta il numero esatto e il tetto non è raggiunto" do
        fill_queue(3)

        get "/up/workers"

        expect(response.parsed_body["ready_count"]).to eq(3)
        expect(response.parsed_body["ready_count_capped"]).to be(false)
      end

      it "a coda vuota il tetto non è raggiunto" do
        get "/up/workers"

        expect(response.parsed_body["ready_count"]).to eq(0)
        expect(response.parsed_body["ready_count_capped"]).to be(false)
      end

      it "con la coda oltre il tetto ferma da 11 minuti resta 503 e nomina la corsia" do
        fill_queue(cap + 1, waiting_since: 11.minutes.ago)

        get "/up/workers"

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["stalled_lanes"]).to eq([ realtime_lane ])
        expect(response.parsed_body["ready_count_capped"]).to be(true)
      end
    end
  end
end
