# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime di Servers::Ingest::Record. Dopo il commit (snapshot host + sample):
#  - stream servers dell'org → replace riga host (target dom_id(host)) + replace pill (target servers_stats)
#  - stream dell'host        → page-refresh Turbo (action="refresh"): il viewer ri-fetcha la show e morpha
# Gli stream sono org-prefissati da Realtime::Streams → l'isolamento tenant è implicito nel nome-stream.
# (have_broadcasted_to su stream String legge il broadcast Turbo grezzo, niente .from_channel.)
RSpec.describe Servers::Ingest::Record, "broadcasts", type: :service do
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/servers/agent_payload.json").read) }
  let(:organization) { create(:organization) }
  let(:host) { create(:server_host, organization:, fingerprint: payload["fingerprint"]) }
  let(:servers_stream) { Realtime::Streams.servers(organization) }
  let(:host_stream) { Realtime::Streams.server_host(host) }

  # Il recorded_at della fixture è fisso: congela il tempo poco dopo, o il clamp anti-skew scatta.
  before { travel_to Time.zone.parse("2026-07-02T10:05:00Z") }

  def record = described_class.call(host:, payload:)

  describe "stream servers (fleet org)" do
    it "esattamente 2 broadcast (riga host + pill header)" do
      expect { record }.to have_broadcasted_to(servers_stream).twice
    end

    it "replace della riga host con target dom_id(host)" do
      expect { record }.to have_broadcasted_to(servers_stream)
        .with(a_string_including("servers_host_#{host.id}"))
    end

    it "replace delle pill con target servers_stats" do
      expect { record }.to have_broadcasted_to(servers_stream)
        .with(a_string_including("servers_stats"))
    end
  end

  describe "stream dell'host (show)" do
    it "page-refresh Turbo (action=refresh): il viewer ri-fetcha la show col proprio range e morpha" do
      expect { record }.to have_broadcasted_to(host_stream)
        .with(a_string_including('action="refresh"'))
    end

    it "esattamente 1 broadcast sullo stream dell'host" do
      expect { record }.to have_broadcasted_to(host_stream).once
    end
  end

  describe "transizioni di stato" do
    it "down→up (recovery al push): la riga broadcastata mostra lo stato fresco" do
      host.update!(status: :down)
      expect { record }.to have_broadcasted_to(servers_stream)
        .with(a_string_including("servers_host_#{host.id}"))
      expect(host.reload.status_up?).to be(true)
    end

    it "push duplicato (stesso recorded_at): broadcasta comunque (lo snapshot host è aggiornato)" do
      record
      expect { record }.to have_broadcasted_to(servers_stream).twice
    end
  end

  describe "isolamento tenant" do
    it "non broadcasta sullo stream servers di un'ALTRA organizzazione" do
      other = Realtime::Streams.servers(create(:organization))
      expect { record }.not_to have_broadcasted_to(other)
    end
  end
end
