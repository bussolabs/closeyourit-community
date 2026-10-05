# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime di Errors::Ingest::Record (CYRA-41). Dopo il commit l'ingest NON ricalcola più le
# stats org-wide per-occorrenza (il vecchio Errors::Broadcast.group = group(:status).count su tutti i
# gruppi dell'org saturava la coda :ingest sotto burst). Emette invece un page-refresh Turbo
# (action="refresh") sui due stream toccati — lista org (errors) e show del gruppo (error_group) —
# throttlato per finestra: ogni viewer ri-fetcha il PROPRIO URL e morpha. Gli stream sono org-prefissati
# da Realtime::Streams → isolamento tenant implicito nel nome-stream.
RSpec.describe Errors::Ingest::Record, "broadcasts", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:errors_stream) { Realtime::Streams.errors(organization) }

  def payload(event_id: "e1", type: "RuntimeError", value: "boom", func: "call", level: "error")
    {
      "event_id" => event_id, "level" => level, "timestamp" => Time.current.to_f,
      "exception" => { "values" => [ {
        "type" => type, "value" => value,
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => func, "in_app" => true } ] }
      } ] }
    }
  end

  def record(p = payload) = described_class.call(project:, payload: p)

  describe "page-refresh Turbo (throttlato, no aggregazioni org-wide)" do
    it "emette un page-refresh sullo stream errors della lista org" do
      expect { record }.to have_broadcasted_to(errors_stream)
        .with(a_string_including('action="refresh"'))
    end

    it "emette un page-refresh sullo stream della show del gruppo" do
      record   # crea il gruppo
      group = project.error_groups.sole
      group_stream = Realtime::Streams.error_group(group)

      expect { record(payload(event_id: "e2")) }.to have_broadcasted_to(group_stream)
        .with(a_string_including('action="refresh"'))
    end

    # DoD: "Sotto burst l'ingest non esegue aggregazioni org-wide per-campione".
    it "NON esegue aggregazioni org-wide per-occorrenza (nessun GROUP BY status)" do
      create(:error_group, project:, status: :resolved)   # popola l'org: un group(:status) avrebbe da contare
      queries = captured_sql { record }

      expect(queries).not_to include(a_string_matching(/group by[^;]*status/i))
    end

    # Scenario 1: burst di occorrenze ravvicinate → il realtime resta aggiornato ma coalescente.
    it "coalescing sotto burst: N occorrenze ravvicinate = un solo leading immediato (throttle per-org)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        3.times { |i| record(payload(event_id: "burst-#{i}")) }   # stesso fingerprint → stesso gruppo
      end.to have_broadcasted_to(errors_stream).once
    end

    # Il trailing garantisce che lo stato di FINE burst sia mostrato anche se le occorrenze si esauriscono
    # dentro la finestra (un leading-edge puro lascerebbe la UI ferma alla prima occorrenza).
    it "coalescing sotto burst: le occorrenze dopo il leading schedulano un refresh trailing" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      record(payload(event_id: "lead"))   # leading immediato

      expect { record(payload(event_id: "tail")) }   # trailing a fine finestra
        .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(errors_stream)
    end
  end

  describe "idempotenza" do
    it "non broadcasta di nuovo su event_id già registrato" do
      described_class.call(project:, payload: payload(event_id: "dup"))
      expect { described_class.call(project:, payload: payload(event_id: "dup")) }
        .not_to have_broadcasted_to(errors_stream)
    end
  end

  describe "isolamento tenant" do
    it "non broadcasta sullo stream errors di un'ALTRA organizzazione" do
      other = Realtime::Streams.errors(create(:organization))
      expect { record }.not_to have_broadcasted_to(other)
    end

    it "non broadcasta sullo stream gruppo di un'ALTRA org (gruppo estraneo)" do
      foreign_group = create(:error_group)   # progetto/org di default, diversa
      foreign_stream = Realtime::Streams.error_group(foreign_group)
      expect { record }.not_to have_broadcasted_to(foreign_stream)
    end
  end
end
