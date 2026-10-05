# frozen_string_literal: true

require "rails_helper"

# Performance/metriche realtime (TASK C5) — read-side: la lista rende la riga gruppo col dom-id colpito
# dal replace e si sottoscrive allo stream metrics; la show rende il container di prepend dei campioni
# (#metric_group_samples_<id>) e si sottoscrive allo stream del gruppo. Il write-side (broadcast
# all'ingest) è coperto da spec/services/metrics/ingest/record_broadcast_spec.rb.
RSpec.describe "Member::Monitoring::MetricGroups realtime", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

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
    it "rende la riga gruppo con id=dom_id(group)" do
      sign_in(owner)
      group = create(:metric_group, project:, title: "SELECT * FROM widgets")
      get member_monitoring_metric_groups_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(group)}"))
    end

    it "rende le pill header con id=metrics_stats (target di replace)" do
      sign_in(owner)
      get member_monitoring_metric_groups_path

      expect(response.body).to include(%(id="metrics_stats"))
    end

    it "le pill (#metrics_stats) usano display:contents — un solo mt-2.5 dall'header, niente flex annidato (mt-5, CYRA-70)" do
      sign_in(owner)
      get member_monitoring_metric_groups_path

      stats = Nokogiri::HTML(response.body).at_css("#metrics_stats")
      expect(stats["class"]).to eq("contents")
      expect(stats["data-test"]).to eq("metrics-stats")
    end

    it "si sottoscrive allo stream metrics dell'org (nome firmato)" do
      sign_in(owner)
      get member_monitoring_metric_groups_path

      expect(decoded_streams).to include(Realtime::Streams.metrics(org))
    end

    it "NON espone lo stream metrics di un'altra org" do
      sign_in(owner)
      get member_monitoring_metric_groups_path

      other = create(:organization)
      expect(decoded_streams).not_to include(Realtime::Streams.metrics(other))
    end

    it "opta per il page-refresh Turbo morph (realtime throttlato d'ingest, CYRA-41)" do
      sign_in(owner)
      get member_monitoring_metric_groups_path

      expect(response.body).to include('name="turbo-refresh-method"', 'content="morph"')
    end
  end

  describe "GET show — contratto target dom-id (read-side)" do
    it "rende il container campioni con id=metric_group_samples_<id> (target di prepend)" do
      sign_in(owner)
      group = create(:metric_group, project:)
      create(:metric_sample, group:, project:, occurred_at: 1.minute.ago)
      get member_monitoring_metric_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="metric_group_samples_#{group.id}"))
    end

    it "il container campioni esiste anche a lista vuota (prepend dal vuoto)" do
      sign_in(owner)
      group = create(:metric_group, project:)
      get member_monitoring_metric_group_path(group)

      expect(response.body).to include(%(id="metric_group_samples_#{group.id}"))
      expect(response.body).to include('data-test="occurrences-empty"')
    end

    it "le righe campione vivono dentro il container di prepend" do
      sign_in(owner)
      group = create(:metric_group, project:)
      sample = create(:metric_sample, group:, project:, occurred_at: 1.minute.ago)
      get member_monitoring_metric_group_path(group)

      expect(response.body).to match(
        %r{id="metric_group_samples_#{group.id}".*id="#{ActionView::RecordIdentifier.dom_id(sample)}"}m
      )
    end

    it "si sottoscrive allo stream del gruppo-metrica (nome firmato)" do
      sign_in(owner)
      group = create(:metric_group, project:)
      get member_monitoring_metric_group_path(group)

      expect(decoded_streams).to include(Realtime::Streams.metric_group(group))
    end

    it "opta per il page-refresh Turbo morph (realtime throttlato d'ingest, CYRA-41)" do
      sign_in(owner)
      group = create(:metric_group, project:)
      get member_monitoring_metric_group_path(group)

      expect(response.body).to include('name="turbo-refresh-method"', 'content="morph"')
    end
  end
end
