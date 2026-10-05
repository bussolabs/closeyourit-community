# frozen_string_literal: true

require "rails_helper"

# CYRA-318 — «Avvisi» esisteva in due punti e portava a due pagine diverse: la campanella in alto apriva
# le notifiche ricevute (/member/alerting/notifications), la voce nel menu laterale apriva le regole
# (/member/alerting/rules). Stessa parola, due destinazioni: una trappola di navigazione. La voce del
# menu che porta alle regole ora si chiama «Regole di avviso», così due voci con destinazioni diverse
# non condividono più lo stesso nome.
RSpec.describe "Member — nomi di navigazione (CYRA-318)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "il menu laterale chiama la voce come la pagina delle regole" do
    sign_in(owner)
    get member_alerting_rules_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("member.nav.alert_rules"))
    expect(response.body).to include(%(href="#{member_alerting_rules_path}"))
  end

  it "la voce del menu e la campanella sono nomi diversi per pagine diverse" do
    # Il glossario deve tenere separati i due nomi: se tornassero uguali, la trappola si riaprirebbe.
    # CYRA-333: ora ogni nome è quello della pagina che apre — «Avvisi» le regole, «Notifiche» la
    # campanella — e restano due nomi distinti per due posti distinti.
    expect(I18n.t("member.nav.alert_rules", locale: :it)).to eq(I18n.t("member.alerting.rules.title", locale: :it))
    expect(I18n.t("member.nav.alert_rules", locale: :it)).not_to eq(I18n.t("member.nav.alerts", locale: :it))

    sign_in(owner)
    get member_alerting_rules_path

    # La campanella (avvisi ricevuti) si chiama «Notifiche» e punta alle notifiche, non alle regole.
    expect(response.body).to include(%(aria-label="#{I18n.t('member.nav.alerts')}"))
    expect(response.body).to include(%(href="#{member_alerting_notifications_path}"))
  end

  # CYRA-486 — la Definition of Done fissa il nome della voce: non più «Avvisi», parola che indicava
  # anche gli avvisi ricevuti, ma «Regole di avviso», che dice esattamente cosa apre.
  it "il menu laterale chiama le regole «Regole di avviso»" do
    expect(I18n.t("member.nav.alert_rules", locale: :it)).to eq("Regole di avviso")
    expect(I18n.t("member.nav.alert_rules", locale: :en)).to eq("Alert rules")
  end
end
