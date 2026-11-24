# frozen_string_literal: true

require "rails_helper"

# Le domande per corsia di /up/workers (CYRA-1273): una riga per coda, mai tutta la coda.
RSpec.describe Ops::QueueThroughput do
  def create_job(queue_name:, **attributes)
    SolidQueue::Job.create!(queue_name:, class_name: "Uptime::CheckJob", priority: 0,
                            active_job_id: SecureRandom.uuid, arguments: { "arguments" => [] }, **attributes)
  end

  def ready_execution(queue_name:, waiting_since:)
    create_job(queue_name:).ready_execution.tap { |execution| execution.update_columns(created_at: waiting_since) }
  end

  # Le domande sulle tabelle della coda fatte dentro il blocco.
  def queue_queries(&)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/solid_queue_(ready_executions|jobs)/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
    queries
  end

  let(:now) { Time.current.change(usec: 0) }

  describe ".oldest_ready_at_by_queue" do
    it "dà per ogni coda l'attesa del lavoro in testa, e lascia fuori le code vuote" do
      allow_n_plus_one do
        ready_execution(queue_name: "uptime", waiting_since: now - 20.minutes)
        ready_execution(queue_name: "uptime", waiting_since: now - 1.minute)
        ready_execution(queue_name: "ingest", waiting_since: now - 3.minutes)
      end

      expect(described_class.oldest_ready_at_by_queue([ %w[uptime alerts], %w[ingest] ]))
        .to eq("uptime" => now - 20.minutes, "ingest" => now - 3.minutes)
    end

    it "senza code non chiede nulla" do
      expect(queue_queries { expect(described_class.oldest_ready_at_by_queue([])).to eq({}) }).to be_empty
    end

    it "con un selettore `*` torna alla domanda raggruppata, perché i nomi veri sono solo nella tabella" do
      ready_execution(queue_name: "uptime", waiting_since: now - 20.minutes)

      expect(described_class.oldest_ready_at_by_queue([ %w[*] ])).to eq("uptime" => now - 20.minutes)
    end
  end

  describe ".last_finished_at_by_queue" do
    it "dà per ogni coda il suo ultimo job finito, ignorando quelli in attesa" do
      allow_n_plus_one do
        create_job(queue_name: "uptime", finished_at: now - 5.minutes)
        create_job(queue_name: "uptime", finished_at: now - 1.minute)
        create_job(queue_name: "uptime")
        create_job(queue_name: "ingest")
      end

      expect(described_class.last_finished_at_by_queue([ %w[uptime], %w[ingest] ])).to eq("uptime" => now - 1.minute)
    end
  end

  describe ".stalled_lanes" do
    it "legge la coda con una riga per coda: nessun raggruppamento e nessuna lettura senza limite" do
      ready_execution(queue_name: "ingest", waiting_since: now - 15.minutes)

      queries = queue_queries { expect(described_class.stalled_lanes(now:)).to eq([ "ingest" ]) }

      expect(queries.size).to eq(2)
      expect(queries).to all(include("LIMIT"))
      expect(queries).to all(satisfy { |sql| !sql.include?("GROUP BY") })
    end
  end
end
