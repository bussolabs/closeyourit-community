# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::CronMonitors", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "non autenticato → redirect login" do
    get member_monitoring_cron_monitors_path
    expect(response).to redirect_to(login_path)
  end

  context "owner" do
    before { sign_in(owner) }

    it "index elenca i cron dei progetti visibili" do
      mine = create(:cron_monitor, project:, name: "Nightly")
      foreign = create(:cron_monitor)

      get member_monitoring_cron_monitors_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Nightly")
      expect(response.body).not_to include(foreign.id)
    end

    it "filtra per status" do
      ok = create(:cron_monitor, project:, status: :ok, name: "OkJob")
      missed = create(:cron_monitor, project:, status: :missed, name: "MissedJob")

      get member_monitoring_cron_monitors_path, params: { status: [ "missed" ] }

      expect(response.body).to include("MissedJob")
      expect(response.body).not_to include(">OkJob<")
    end

    it "show con i check-in recenti" do
      monitor = create(:cron_monitor, project:)
      monitor.check_ins.create!(status: :ok, checked_in_at: Time.current)

      get member_monitoring_cron_monitor_path(monitor)
      expect(response).to have_http_status(:ok)
    end

    # CYRA-924 — the check-ins sort on every column (C9), without touching the outage history.
    it "show: check-ins sort by duration both ways" do
      monitor = create(:cron_monitor, project:)
      monitor.check_ins.create!(status: :ok, checked_in_at: 2.hours.ago, duration_ms: 90_000, reason: "slow-run")
      monitor.check_ins.create!(status: :ok, checked_in_at: 1.hour.ago, duration_ms: 1_000, reason: "fast-run")

      get member_monitoring_cron_monitor_path(monitor, sort: "duration")
      expect(response.body.index("fast-run")).to be < response.body.index("slow-run")
      get member_monitoring_cron_monitor_path(monitor, sort: "-duration")
      expect(response.body.index("slow-run")).to be < response.body.index("fast-run")
      %w[status duration reason at].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end

    it "show: the daily cadence reads in words" do
      monitor = create(:cron_monitor, project:, expected_interval_minutes: 1_440)

      get member_monitoring_cron_monitor_path(monitor)

      labels = Nokogiri::HTML(response.body).at_css("[data-test=cron-monitor-labels]")
      expect(labels.text).to include(I18n.t("member.crons.every_days", count: 1))
    end

    it "show di un cron non visibile → 404 (BOLA)" do
      foreign = create(:cron_monitor)
      get member_monitoring_cron_monitor_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    # CYRA-477 Scenario 1: la index dichiara la copertura degli avvisi e, se manca la regola, offre il
    # collegamento per crearla (event_type già preselezionato).
    it "senza regola cron_missed mostra il banner di copertura e il link per crearla" do
      create(:cron_monitor, project:, name: "Nightly")

      get member_monitoring_cron_monitors_path

      expect(response.body).to include('data-test="crons-coverage"')
      expect(response.body).to include('data-test="crons-coverage-link"')
      expect(response.body).to include("event_type=cron_missed")
    end

    it "con una regola cron_missed org-wide il banner segnala copertura completa (nessun link)" do
      create(:cron_monitor, project:)
      create(:alerting_rule, organization:, event_type: :cron_missed)

      get member_monitoring_cron_monitors_path

      expect(response.body).to include('data-test="crons-coverage"')
      expect(response.body).not_to include('data-test="crons-coverage-link"')
    end
  end

  # CYRA-477 Scenario 2: la spiegazione dei cron non promette più un avviso incondizionato, ma lo lega
  # all'esistenza di una regola — in entrambe le lingue.
  it "il tooltip lega l'avviso di cron mancato all'esistenza di una regola" do
    %i[it en].each do |locale|
      text = I18n.t("member.crons.help_title", locale:)
      expect(text.downcase).to match(/regola|rule/), "manca il vincolo 'regola' in #{locale}: #{text}"
    end
  end
end
