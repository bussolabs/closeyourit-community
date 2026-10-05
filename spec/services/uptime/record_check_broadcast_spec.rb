# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime di Uptime::RecordCheck (Task C). Dopo il commit:
#  - stream uptime dell'org      → SOLO page-refresh (ogni viewer ri-fetcha le proprie pill)
#  - stream uptime PER-PROGETTO  → replace riga monitor (target dom_id): l'HTML non viaggia a chi il
#                                  progetto non lo vede (CYRA-271)
#  - stream del monitor          → prepend nuovo check (target monitor_checks_<id>)
#  - al CAMBIO di stato          → replace lista incident sul monitor (target monitor_incidents_<id>)
# Gli stream sono org-prefissati da Realtime::Streams → l'isolamento tenant è implicito nel nome-stream.
# (have_broadcasted_to su stream String legge il broadcast Turbo grezzo, niente .from_channel.)
RSpec.describe Uptime::RecordCheck, "broadcasts", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:monitor) { create(:uptime_monitor, project:, current_status: :unknown) }
  let(:uptime_stream)  { Realtime::Streams.uptime(organization) }
  let(:monitor_stream) { Realtime::Streams.monitor(monitor) }

  def result(up:, code: 200, ms: 120, error: nil)
    Uptime::Ping::Result.new(up:, status_code: code, response_time_ms: ms, error:)
  end

  def record(up: true, **opts) = described_class.call(monitor:, result: result(up:, **opts))

  describe "stream uptime — org-wide (solo refresh) vs per-progetto (riga)" do
    let(:project_uptime_stream) { Realtime::Streams.project_uptime(project) }

    it "la riga monitor (HTML) va sullo stream PER-PROGETTO, non org-wide (CYRA-271)" do
      expect { record }.to have_broadcasted_to(project_uptime_stream)
        .with(a_string_including("uptime_monitor_#{monitor.id}"))
    end

    # Sullo stream org-wide viaggia SOLO il page-refresh: né le pill (conteggi org-wide, CYRA-257) né
    # la riga renderizzata (l'HTML del monitor arriverebbe a chi il progetto non lo vede, CYRA-271).
    it "sullo stream org-wide manda solo un refresh, mai la riga né le pill renderizzate" do
      seen = []
      expect { record }.to have_broadcasted_to(uptime_stream).with { |html| seen << html }

      expect(seen).to include(a_string_including(%(action="refresh")))
      expect(seen.join).not_to include("monitors_stats")
      expect(seen.join).not_to include("uptime_monitor_#{monitor.id}")
    end
  end

  describe "stream del monitor (show)" do
    it "prepend del nuovo check con target monitor_checks_<id>" do
      expect { record }.to have_broadcasted_to(monitor_stream)
        .with(a_string_including("monitor_checks_#{monitor.id}"))
    end

    it "stato invariato (up mentre già up): SOLO il check, nessun broadcast incident" do
      monitor.status_up!
      expect { record(up: true) }.to have_broadcasted_to(monitor_stream).once
    end

    it "down dopo up (apre incident): broadcasta anche la lista incident (target monitor_incidents_<id>)" do
      # Soglia 1: qui si prova il broadcast al cambio di stato, non la conferma — che ha spec sue
      # (CYRA-776) e con due controlli falsherebbe il conteggio dei messaggi.
      monitor.update!(failure_threshold: 1)
      monitor.status_up!
      expect { record(up: false, code: 500, error: "x") }.to have_broadcasted_to(monitor_stream)
        .with(a_string_including("monitor_incidents_#{monitor.id}"))
    end

    it "recovery (up dopo down, chiude incident): broadcasta la lista incident aggiornata" do
      monitor.status_down!
      create(:uptime_incident, monitor:, resolved_at: nil)
      expect { record(up: true) }.to have_broadcasted_to(monitor_stream)
        .with(a_string_including("monitor_incidents_#{monitor.id}"))
    end
  end

  describe "isolamento tenant" do
    it "non broadcasta sullo stream uptime di un'ALTRA organizzazione" do
      other = Realtime::Streams.uptime(create(:organization))
      expect { record }.not_to have_broadcasted_to(other)
    end
  end
end
