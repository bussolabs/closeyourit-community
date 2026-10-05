# frozen_string_literal: true

require "rails_helper"

# CYRA-540 — la scheda che dice quanto è veloce un sito. Il rischio di questa pagina non è mostrare
# poco: è mostrare due numeri diversi come se fossero lo stesso, o un trattino come se fosse uno zero.
RSpec.describe "Member::Monitoring — velocità di un sito SEO", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org) }
  let(:site) { create(:seo_site, project:, environment:) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization: org, supports_analytics: true))
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Il servizio è collegato quando l'ORGANIZZAZIONE del sito ha la sua chiave (CYRA-546): non c'è più
  # nessuna chiave di installazione da fingere con un doppio.
  def collega = create(:integration_credential, :pagespeed, organization: org)

  it "mostra laboratorio e campo per telefono e per computer, tenendoli separati" do
    create(:seo_lab_run, :completed, :with_field, site:, strategy: :mobile)
    create(:seo_lab_run, :completed, :with_field, :desktop, site:)
    collega
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    expect(response).to have_http_status(:ok)
    corpo = response.body
    expect(corpo).to include('data-test="seo-performance-field"', 'data-test="seo-performance-lab"')
    expect(corpo).to include('data-test="seo-field-mobile"', 'data-test="seo-field-desktop"')
    expect(corpo).to include('data-test="seo-lab-mobile"', 'data-test="seo-lab-desktop"')
    # Le due sezioni dichiarano a quale domanda rispondono, o il lettore le media in testa.
    expect(corpo).to include(ERB::Util.html_escape(I18n.t("seo.vitals.lab_explainer")))
    expect(corpo).to include(ERB::Util.html_escape(I18n.t("seo.vitals.field_explainer")))
  end

  # Un giro fallito non cancella i numeri buoni, ma non deve nemmeno farli passare per freschi.
  it "quando l'ultima misura è fallita lo dice, e mostra comunque i numeri di prima" do
    create(:seo_lab_run, :completed, site:, strategy: :mobile, started_at: 2.days.ago)
    site.update!(last_lab_error: "quota_exceeded")
    collega
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    expect(response.body).to include('data-test="seo-performance-stale"')
    expect(response.body).to include("quota_exceeded")
    expect(response.body).to include('data-test="seo-lab-mobile"')
  end

  # Google non ha traffico a sufficienza: è un'informazione, non un guasto nostro. Una fila di
  # trattini senza spiegazione si legge come «lo strumento è rotto».
  it "dice quando Google non ha abbastanza visite, invece di mostrare celle vuote" do
    create(:seo_lab_run, :completed, site:, strategy: :mobile)
    collega
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    expect(response.body).to include('data-test="seo-field-mobile-empty"')
    expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.monitoring.seo_sites.performance.no_field")))
  end

  # I numeri dell'origine intera presentati come «di questa pagina» sarebbero una bugia, e Google ci
  # dice esplicitamente quando è il caso.
  it "dichiara quando i numeri sono di tutto il sito e non di questa pagina" do
    create(:seo_lab_run, :completed, :with_field, :origin_fallback, site:, strategy: :mobile)
    collega
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    expect(response.body).to include('data-test="seo-field-mobile-origin"')
  end

  # Senza collegamento non arriverà nessuna misura: dirlo è l'unica alternativa a una griglia di
  # trattini, che si legge come un sito lentissimo o come uno strumento rotto.
  it "senza collegamento spiega cosa manca e dove si collega, non mostra una griglia vuota" do
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    expect(response.body).to include('data-test="seo-performance-unconfigured"')
    expect(response.body).not_to include('data-test="seo-performance-lab"')
    expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.monitoring.seo_sites.performance.unconfigured_hint")))
    expect(response.body).not_to include('data-test="seo-performance-empty"')
  end

  # Il collegamento di UN'ALTRA organizzazione non è il proprio: leggerlo come tale prometterebbe
  # misure che non arriveranno mai.
  it "il collegamento di un'altra organizzazione non vale per questo sito" do
    create(:integration_credential, :pagespeed, organization: create(:organization))
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    expect(response.body).to include('data-test="seo-performance-unconfigured"')
  end

  it "con le credenziali ma nessuna misura ancora fatta dice che arriverà" do
    collega
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    expect(response.body).to include('data-test="seo-performance-empty"')
  end

  # LA trappola dell'API: un punteggio nullo non è zero. A schermo deve restare un trattino grigio,
  # non un rosso che accusa il sito di essere messo male.
  it "un punteggio che Google non ha calcolato resta un trattino, non uno zero" do
    create(:seo_lab_run, :completed, site:, strategy: :mobile, seo_score: nil)
    collega
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(site)

    cella = Nokogiri::HTML(response.body).at_css('[data-test="seo-lab-mobile-seo"]')
    expect(cella.text).to include("—")
    expect(cella.text).to include(I18n.t("seo.vitals.ratings.unknown"))
  end

  it "un sito di un'altra organizzazione non esiste" do
    altro = create(:project)
    altro_env = create(:environment, organization: altro.organization)
    altro.environments << altro_env
    estraneo = create(:seo_site, project: altro, environment: altro_env)
    sign_in(owner)

    get performance_member_monitoring_seo_site_path(estraneo)

    expect(response).to have_http_status(:not_found)
  end
end
