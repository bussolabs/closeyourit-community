# frozen_string_literal: true

require "rails_helper"

# Cron monitor realtime — read-side: la lista rende la riga monitor col dom-id colpito dal replace
# + le pill (#crons_stats) e si sottoscrive allo stream crons; la show rende il container di prepend
# dei check-in (#cron_monitor_check_ins_<id>, presente ANCHE a lista vuota) + l'header di stato
# (#cron_monitor_labels_<id>) e si sottoscrive allo stream del monitor. Il write-side è coperto da
# spec/services/crons/record_check_in_broadcast_spec.rb e spec/jobs/crons/evaluate_job_spec.rb.
RSpec.describe "Member::Monitoring::CronMonitors realtime", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:monitor) { create(:cron_monitor, project:) }

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
    it "rende la riga monitor con id=dom_id(monitor) e le pill con id=crons_stats" do
      sign_in(owner)
      monitor
      get member_monitoring_cron_monitors_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(monitor)}"))
      expect(response.body).to include(%(id="crons_stats"))
    end

    it "le pill (#crons_stats) usano display:contents — un solo mt-2.5 dall'header, niente flex annidato (mt-5, CYRA-70)" do
      sign_in(owner)
      get member_monitoring_cron_monitors_path

      stats = Nokogiri::HTML(response.body).at_css("#crons_stats")
      expect(stats["class"]).to eq("contents")
      expect(stats["data-test"]).to eq("crons-stats")
    end

    it "si sottoscrive allo stream crons dell'org (nome firmato)" do
      sign_in(owner)
      get member_monitoring_cron_monitors_path

      expect(decoded_streams).to include(Realtime::Streams.crons(org))
    end

    it "NON espone lo stream crons di un'altra org" do
      sign_in(owner)
      get member_monitoring_cron_monitors_path

      other = create(:organization)
      expect(decoded_streams).not_to include(Realtime::Streams.crons(other))
    end
  end

  describe "GET show — contratto target dom-id (read-side)" do
    it "rende il container check-in ANCHE a lista vuota (target di prepend) + l'header di stato" do
      sign_in(owner)
      get member_monitoring_cron_monitor_path(monitor)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="cron_monitor_check_ins_#{monitor.id}"))
      expect(response.body).to include(%(id="cron_monitor_labels_#{monitor.id}"))
    end

    it "si sottoscrive allo stream del monitor (nome firmato)" do
      sign_in(owner)
      get member_monitoring_cron_monitor_path(monitor)

      expect(decoded_streams).to include(Realtime::Streams.cron_monitor(monitor))
    end
  end
end
