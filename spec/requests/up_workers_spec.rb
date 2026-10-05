# frozen_string_literal: true

require "rails_helper"

# Liveness del motore dei job servita dal WEB, indipendente dal worker (CYRA-209). È l'endpoint che un
# guardiano ESTERNO interroga per accorgersi che i controlli non girano più — /up resta liveness pura.
RSpec.describe "Workers health", type: :request do
  def register_process(last_heartbeat_at:, kind: "Worker", name: "worker-1")
    SolidQueue::Process.create!(kind:, name:, pid: 1, last_heartbeat_at:)
  end

  def create_job(class_name: "Uptime::CheckJob", **attributes)
    SolidQueue::Job.create!(queue_name: "uptime", class_name:, priority: 0,
                            active_job_id: SecureRandom.uuid, arguments: { "arguments" => [] },
                            **attributes)
  end

  # `SolidQueue::Job.create!` accoda già da sé: `after_create :prepare_for_execution` crea la ready
  # execution. Crearne una seconda a mano viola l'indice unico su job_id.
  def ready_execution(class_name: "Uptime::CheckJob")
    create_job(class_name:).ready_execution
  end

  # Nel motore vero un job finito non ha più una ready execution: il worker la consuma quando lo
  # reclama. Il callback di creazione la accoda comunque, quindi qui va tolta — altrimenti ogni job
  # "finito" gonfia ready_count e la coda non risulta mai vuota.
  def finished_job(finished_at:, class_name: "Uptime::CheckJob")
    create_job(class_name:, finished_at:).tap { |job| job.ready_execution&.destroy }
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
  end
end
