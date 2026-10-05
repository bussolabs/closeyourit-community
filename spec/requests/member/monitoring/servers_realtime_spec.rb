# frozen_string_literal: true

require "rails_helper"

# Server monitoring realtime — read-side: la fleet rende la riga host col dom-id colpito dal replace
# + le pill (#servers_stats) e si sottoscrive allo stream servers; la show si sottoscrive allo stream
# dell'host e opta al page-refresh Turbo con morph (meta turbo-refresh-method/scroll), così l'intera
# pagina si ri-fetcha e morpha al broadcast. Il write-side è coperto da
# spec/services/servers/ingest/record_broadcast_spec.rb e spec/jobs/servers/check_stale_job_spec.rb.
RSpec.describe "Member::Monitoring::Servers realtime", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) { create(:server_host, :up, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def decoded_streams
    response.body.scan(/signed-stream-name="([^"]+)"/).flatten
            .filter_map { |name| Turbo::StreamsChannel.verified_stream_name(name) }
  end

  describe "GET index — contratto target dom-id (read-side)" do
    it "rende la riga host con id=dom_id(host) e le pill con id=servers_stats" do
      sign_in(owner)
      host
      get member_monitoring_servers_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(host)}"))
      expect(response.body).to include(%(id="servers_stats"))
    end

    it "si sottoscrive allo stream servers dell'org (nome firmato)" do
      sign_in(owner)
      get member_monitoring_servers_path

      expect(decoded_streams).to include(Realtime::Streams.servers(org))
    end

    it "NON espone lo stream servers di un'altra org" do
      sign_in(owner)
      get member_monitoring_servers_path

      other = create(:organization)
      expect(decoded_streams).not_to include(Realtime::Streams.servers(other))
    end
  end

  describe "GET show — contratto realtime (read-side)" do
    it "si sottoscrive allo stream dell'host (nome firmato)" do
      sign_in(owner)
      get member_monitoring_server_path(host)

      expect(response).to have_http_status(:ok)
      expect(decoded_streams).to include(Realtime::Streams.server_host(host))
    end

    it "opta al page-refresh Turbo con morph e scroll preservato (meta nel <head>)" do
      sign_in(owner)
      get member_monitoring_server_path(host)

      expect(response.body).to include(%(name="turbo-refresh-method" content="morph"))
      expect(response.body).to include(%(name="turbo-refresh-scroll" content="preserve"))
    end
  end
end
