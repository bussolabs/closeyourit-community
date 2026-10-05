# frozen_string_literal: true

require "rails_helper"

# CYRA-519 — una regola di avviso valeva per tutta la flotta: se su una macchina produceva falsi
# allarmi, l'unica scelta era spegnerla ovunque e perdere il segnale anche dove serviva. È il caso
# reale di «Contenitore caduto» sui due runner di CI, dove i container nascono e muoiono a ogni giro.
RSpec.describe "Member — regole di avviso silenziate su una macchina", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:host) { create(:server_host, organization:, name: "runner-1") }
  let(:altra) { create(:server_host, organization:, name: "apps") }
  let(:rule) { create(:alerting_rule, organization:, event_type: :server_container_down, name: "Contenitore caduto") }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    create(:membership, account: member, organization:, role: :member)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  it "chi gestisce gli avvisi la silenzia su questa macchina" do
    sign_in(owner)

    post member_monitoring_server_alert_exclusions_path(host), params: { rule_id: rule.id }

    expect(response).to redirect_to(member_monitoring_server_path(host, tab: "alerts"))
    expect(Alerting::RuleHostExclusion.where(rule:, host:)).to exist
  end

  it "silenziarla due volte non è un errore" do
    sign_in(owner)
    Alerting::RuleHostExclusion.create!(rule:, host:)

    post member_monitoring_server_alert_exclusions_path(host), params: { rule_id: rule.id }

    expect(response).to redirect_to(member_monitoring_server_path(host, tab: "alerts"))
    expect(Alerting::RuleHostExclusion.where(rule:, host:).count).to eq(1)
  end

  it "si riattiva da dove la si era silenziata" do
    sign_in(owner)
    Alerting::RuleHostExclusion.create!(rule:, host:)

    delete member_monitoring_server_alert_exclusion_path(host, rule_id: rule.id)

    expect(Alerting::RuleHostExclusion.where(rule:, host:)).not_to exist
  end

  it "chi non gestisce gli avvisi non può silenziare niente" do
    sign_in(member)

    post member_monitoring_server_alert_exclusions_path(host), params: { rule_id: rule.id }

    expect(response).not_to have_http_status(:ok)
    expect(Alerting::RuleHostExclusion.where(rule:, host:)).not_to exist
  end

  # Anti-BOLA: la regola di un'altra organizzazione non esiste, non è "vietata".
  it "una regola di un'altra organizzazione dà 404" do
    sign_in(owner)
    estranea = create(:alerting_rule, organization: create(:organization), event_type: :server_container_down)

    post member_monitoring_server_alert_exclusions_path(host), params: { rule_id: estranea.id }

    expect(response).to have_http_status(:not_found)
  end

  # Un silenzio che non si vede è un silenzio dimenticato: la regola resta in elenco, marcata.
  it "sulla scheda della macchina il silenzio si vede e si toglie" do
    sign_in(owner)
    Alerting::RuleHostExclusion.create!(rule:, host:)

    get member_monitoring_server_path(host, tab: "alerts")

    expect(response.body).to include(%(data-test="server-alert-muted-#{rule.id}"))
    expect(response.body).to include(%(data-test="server-alert-unmute-#{rule.id}"))
  end

  it "sull'altra macchina la stessa regola non risulta silenziata" do
    sign_in(owner)
    Alerting::RuleHostExclusion.create!(rule:, host:)

    get member_monitoring_server_path(altra, tab: "alerts")

    expect(response.body).not_to include(%(data-test="server-alert-muted-#{rule.id}"))
    expect(response.body).to include(%(data-test="server-alert-mute-#{rule.id}"))
  end
end
