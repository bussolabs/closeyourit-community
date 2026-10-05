# frozen_string_literal: true

require "rails_helper"

# Errori realtime (TASK C4). Read-side: index/show rendono i target dom-id che i broadcast colpiscono e
# si sottoscrivono agli stream (errors d'org / error_group). Write-side: la triage (PATCH resolve) dal
# canale Member ri-broadcasta riga + stats sullo stream errors dell'org.
RSpec.describe "Member::Monitoring::ErrorGroups realtime", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    # owner = vede tutti i progetti dell'org e può triage (errors.triage) → niente project_membership.
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def subscribed_streams(body)
    body.scan(/signed-stream-name="([^"]+)"/).flatten
        .filter_map { |name| Turbo::StreamsChannel.verified_stream_name(name) }
  end

  describe "GET index — contratto target dom-id + sottoscrizione (read-side)" do
    it "rende riga gruppo (dom_id) e stats (errors_stats)" do
      sign_in(owner)
      group = create(:error_group, project:, title: "RuntimeError: boom")
      get member_monitoring_error_groups_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="errors_group_#{group.id}"))
      expect(response.body).to include(%(id="errors_stats"))
    end

    it "le pill (#errors_stats) usano display:contents — un solo mt-2.5 dall'header, niente flex annidato (mt-5, CYRA-70)" do
      sign_in(owner)
      get member_monitoring_error_groups_path

      stats = Nokogiri::HTML(response.body).at_css("#errors_stats")
      expect(stats["class"]).to eq("contents")
      expect(stats["data-test"]).to eq("errors-stats")
    end

    it "si sottoscrive allo stream errors dell'org (nome firmato che decodifica a Streams.errors)" do
      sign_in(owner)
      get member_monitoring_error_groups_path

      expect(subscribed_streams(response.body)).to include(Realtime::Streams.errors(org))
    end

    it "opta per il page-refresh Turbo morph (realtime throttlato d'ingest, CYRA-41)" do
      sign_in(owner)
      get member_monitoring_error_groups_path

      expect(response.body).to include('name="turbo-refresh-method"', 'content="morph"')
    end
  end

  describe "GET show — contratto target occorrenze + sottoscrizione (read-side)" do
    it "rende il container occorrenze (error_group_events_<id>)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:)
      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="error_group_events_#{group.id}"))
    end

    it "si sottoscrive allo stream del gruppo (decodifica a Streams.error_group)" do
      sign_in(owner)
      group = create(:error_group, project:)
      get member_monitoring_error_group_path(group)

      expect(subscribed_streams(response.body)).to include(Realtime::Streams.error_group(group))
    end

    it "opta per il page-refresh Turbo morph (realtime throttlato d'ingest, CYRA-41)" do
      sign_in(owner)
      group = create(:error_group, project:)
      get member_monitoring_error_group_path(group)

      expect(response.body).to include('name="turbo-refresh-method"', 'content="morph"')
    end
  end

  describe "PATCH resolve — broadcast (write-side)" do
    it "broadcasta la riga sullo stream errors PER-PROGETTO, non org-wide (CYRA-271)" do
      sign_in(owner)
      group = create(:error_group, project:, status: :unresolved)

      expect { patch resolve_member_monitoring_error_group_path(group) }
        .to have_broadcasted_to(Realtime::Streams.project_errors(project))
        .with(a_string_including("errors_group_#{group.id}"))
    end

    # Sullo stream org-wide viaggia SOLO il page-refresh: né le pill (conteggi org-wide, CYRA-257) né
    # la riga renderizzata (l'HTML dell'errore arriverebbe a chi il progetto non lo vede, CYRA-271).
    it "sullo stream org-wide manda solo un refresh, mai le pill né la riga renderizzate" do
      sign_in(owner)
      group = create(:error_group, project:, status: :unresolved)

      seen = []
      expect { patch reopen_member_monitoring_error_group_path(group) }
        .to have_broadcasted_to(Realtime::Streams.errors(org)).with { |html| seen << html }

      expect(seen).to include(a_string_including(%(action="refresh")))
      expect(seen.join).not_to include("errors_stats")
      expect(seen.join).not_to include("errors_group_#{group.id}")
    end

    it "non broadcasta sullo stream errors di un'ALTRA organizzazione (isolamento tenant)" do
      sign_in(owner)
      group = create(:error_group, project:, status: :unresolved)
      other = Realtime::Streams.errors(create(:organization))

      expect { patch resolve_member_monitoring_error_group_path(group) }
        .not_to have_broadcasted_to(other)
    end
  end
end
