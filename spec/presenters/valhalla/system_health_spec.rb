# frozen_string_literal: true

require "rails_helper"

RSpec.describe Valhalla::SystemHealth do
  include_context "valhalla service health cache"

  # SolidQueue gira sul DB queue (adapter :test → tabelle non popolate dal job runner): registriamo a
  # mano le righe, come Ops::WorkerLiveness (spec/services/ops/worker_liveness_spec.rb). DB test
  # condiviso tra worktree → azzero le tabelle SolidQueue per conteggi deterministici.
  before do
    SolidQueue::ReadyExecution.delete_all
    SolidQueue::ScheduledExecution.delete_all
    SolidQueue::ClaimedExecution.delete_all
    SolidQueue::BlockedExecution.delete_all
    SolidQueue::FailedExecution.delete_all
    SolidQueue::Semaphore.delete_all
    SolidQueue::Process.delete_all
    SolidQueue::Job.delete_all
  end

  # SolidQueue::Job ha un after_create che dispaccia da solo il job (Job::Executable#prepare_for_execution):
  # "due" (scheduled_at nil/passato, nessun concurrency limit attivo) → crea una ReadyExecution in automatico.
  # Creare ANCHE a mano la ReadyExecution/ScheduledExecution per lo stesso job viola l'indice unique su
  # job_id (o, per ScheduledExecution, viene sovrascritta da assumes_attributes_from_job comunque). Per
  # questo i test sotto non creano più le execution a mano: lasciano fare al callback del job.
  def create_job(queue_name: "default", class_name: "SomeJob", scheduled_at: nil, concurrency_key: nil)
    SolidQueue::Job.create!(queue_name:, class_name:, scheduled_at:, concurrency_key:)
  end

  describe "#ready_backlog / #ready_total" do
    it "raggruppa il backlog per coda, ordinato per conteggio decrescente" do
      create_job(queue_name: "default")
      2.times { create_job(queue_name: "maintenance") }

      backlog = described_class.new.ready_backlog

      expect(backlog.map(&:queue_name)).to eq(%w[maintenance default])
      expect(backlog.find { |row| row.queue_name == "maintenance" }.count).to eq(2)
      expect(described_class.new.ready_total).to eq(3)
    end

    it "nessun lavoro in coda → backlog vuoto, totale zero" do
      presenter = described_class.new
      expect(presenter.ready_backlog).to eq([])
      expect(presenter.ready_total).to eq(0)
    end
  end

  describe "#scheduled_total / #claimed_total / #blocked_total" do
    it "conta scheduled, claimed e blocked separatamente dal backlog ready" do
      # Scheduled: scheduled_at futuro → il job non è "due", il callback lo dispaccia da solo su
      # ScheduledExecution (scheduled_at è comunque assunto dal job, assumes_attributes_from_job).
      create_job(scheduled_at: 1.hour.from_now)

      # Claimed: nessun percorso automatico verso "claimed" nel test (richiede un worker reale che
      # reclami la riga). Il job nasce "due" → il callback lo dispaccia su Ready; la sostituiamo a mano
      # con la claim, come farebbe SolidQueue::ReadyExecution.claim in produzione.
      claimed_job = create_job
      claimed_job.ready_execution.destroy!
      process = SolidQueue::Process.create!(kind: "Worker", name: "w-claim", pid: 1, last_heartbeat_at: Time.current)
      SolidQueue::ClaimedExecution.create!(job: claimed_job, process:)

      # Blocked: serve un job la cui classe risolva davvero (limits_concurrency di Assistant::StreamReplyJob,
      # BlockedExecution#set_expires_at chiama job.concurrency_duration — su "SomeJob" non risolvibile
      # solleverebbe NoMethodError). Il semaforo pre-esaurito fa fallire l'acquisizione del lock nel
      # callback del job, che dispaccia da solo su BlockedExecution (mai a mano: assumes_attributes_from_job
      # e set_expires_at vanno rispettati dal modello, non duplicati qui).
      SolidQueue::Semaphore.create!(key: "spec-blocked-key", value: 0, expires_at: 1.hour.from_now)
      create_job(class_name: "Assistant::StreamReplyJob", concurrency_key: "spec-blocked-key")

      presenter = described_class.new
      expect(presenter.scheduled_total).to eq(1)
      expect(presenter.claimed_total).to eq(1)
      expect(presenter.blocked_total).to eq(1)
      expect(presenter.ready_total).to eq(0)
    end
  end

  describe "#workers_alive? / #workers_count / #last_worker_heartbeat_at" do
    it "riflette i processi Worker vivi (stessa soglia di Ops::WorkerLiveness)" do
      SolidQueue::Process.create!(kind: "Worker", name: "w1", pid: 1, last_heartbeat_at: Time.current)

      presenter = described_class.new
      expect(presenter.workers_alive?).to be(true)
      expect(presenter.workers_count).to eq(1)
      expect(presenter.last_worker_heartbeat_at).to be_within(1.second).of(Time.current)
    end

    it "nessun processo registrato → non vivo, conteggio zero, nessun battito" do
      presenter = described_class.new
      expect(presenter.workers_alive?).to be(false)
      expect(presenter.workers_count).to eq(0)
      expect(presenter.last_worker_heartbeat_at).to be_nil
    end

    it "solo Supervisor/Dispatcher vivi (nessun Worker) → non vivo" do
      SolidQueue::Process.create!(kind: "Supervisor(fork)", name: "sup", pid: 1, last_heartbeat_at: Time.current)

      expect(described_class.new.workers_alive?).to be(false)
    end
  end

  describe "#failed_total / #failed_breakdown" do
    def create_failed(class_name:)
      job = create_job(class_name:)
      SolidQueue::FailedExecution.create!(job:, error: "boom")
    end

    it "conta i falliti totali e li ripartisce per classe job" do
      create_failed(class_name: "Ai::AnalyzeJob")
      create_failed(class_name: "Ai::AnalyzeJob")
      create_failed(class_name: "Notifications::DigestJob")

      presenter = described_class.new
      expect(presenter.failed_total).to eq(3)
      breakdown = presenter.failed_breakdown
      expect(breakdown.map(&:class_name)).to eq(%w[Ai::AnalyzeJob Notifications::DigestJob])
      expect(breakdown.first.count).to eq(2)
    end

    it "nessun lavoro fallito → totale zero, breakdown vuoto" do
      presenter = described_class.new
      expect(presenter.failed_total).to eq(0)
      expect(presenter.failed_breakdown).to eq([])
    end
  end

  describe "#growing_tables" do
    it "legge dal PRIMARY (non dalla connessione queue) e ordina per dimensione decrescente" do
      tables = described_class.new(top_tables_limit: 5).growing_tables

      expect(tables.size).to be <= 5
      expect(tables.map(&:size_bytes)).to eq(tables.map(&:size_bytes).sort.reverse)
      row = tables.first
      expect(row.table).to be_a(String)
      expect(row.size_pretty).to be_a(String)
      expect(row.est_rows).to be >= 0
    end

    it "rispetta il limite iniettato" do
      expect(described_class.new(top_tables_limit: 2).growing_tables.size).to be <= 2
    end
  end

  describe "#service_statuses" do
    it "mappa lo snapshot cache sulle 6 chiavi attese, nell'ordine atteso" do
      checked_at = Time.current
      Rails.cache.write("valhalla:service_health", [
        { key: :embedding, status: :up, checked_at:, detail: nil },
        { key: :telegram, status: :unconfigured, checked_at:, detail: nil },
        { key: :github, status: :up, checked_at:, detail: nil },
        { key: :email, status: :up, checked_at:, detail: nil },
        { key: :llm, status: :down, checked_at:, detail: nil }
      ])

      statuses = described_class.new.service_statuses

      expect(statuses.map(&:key)).to eq(%i[embedding telegram github email llm])
      # CYRA-186: il server AI giù deve arrivare fino alla pagina, non fermarsi in cache.
      expect(statuses.find { |s| s.key == :llm }.status).to eq(:down)
    end

    it "cache vuota (job mai girato) → tutte le chiavi a :unknown, nessun errore" do
      Rails.cache.delete("valhalla:service_health")

      statuses = described_class.new.service_statuses

      expect(statuses.map(&:status).uniq).to eq([ :unknown ])
      expect(statuses.map(&:checked_at).uniq).to eq([ nil ])
    end

    # Da CYRA-765 i servizi sono tutti di sistema: lo snapshot porta solo stato, momento del controllo
    # e dettaglio. Uno snapshot con chiavi in più (scritto da una versione precedente e rimasto in
    # cache durante un deploy) non deve far esplodere la pagina.
    it "ignora le chiavi in più rimaste in uno snapshot vecchio" do
      checked_at = Time.current
      Rails.cache.write("valhalla:service_health",
                        [ { key: :telegram, status: :up, checked_at:, detail: nil, connected: 3, broken: 1 } ])

      telegram = described_class.new.service_statuses.find { |s| s.key == :telegram }

      expect(telegram.status).to eq(:up)
      expect(telegram.members).to eq(%i[key status checked_at detail])
    end
  end
end
