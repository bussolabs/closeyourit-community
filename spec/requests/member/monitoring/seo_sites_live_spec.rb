# frozen_string_literal: true

require "rails_helper"

# CYRA-824 — il controllo di un sito gira in background e dura minuti: chi tiene la scheda aperta
# restava con l'esito di prima finché non ricaricava a mano. Qui si prova il confine: un riquadro
# per lo stato e i risultati, che si ri-chiede da solo quando il giro finisce, con la sessione di
# chi guarda — quindi con i suoi progetti e i suoi permessi, anche dopo una riconnessione.
RSpec.describe "Member::Monitoring — la scheda di un sito si aggiorna da sola (CYRA-824)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org) }
  let(:site) { create(:seo_site, project:, environment:, base_url: "https://acme.test") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization: org, supports_analytics: true))
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def frame(name = "seo-site-live") = { "Turbo-Frame" => name }

  # Vede il progetto (quindi il sito) ma NON può far ripartire un controllo: è il caso su cui si
  # prova che il riquadro ricaricato non è una porta di servizio che salta i permessi.
  def solo_lettura
    account = create(:account)
    create(:membership, account:, organization: org, role: :member)
    create(:project_membership, account:, project:)
    account
  end

  describe "la pagina intera" do
    before { sign_in(owner) }

    it "dichiara il riquadro, l'aggancio agli aggiornamenti e come ricaricarlo" do
      get member_monitoring_seo_site_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="seo-site-live"')
      expect(response.body).to include("turbo-cable-stream-source")
      expect(response.body).to include('data-controller="live-frame"')
      expect(response.body).to include(%(data-live-frame-url-value="#{member_monitoring_seo_site_path(site)}"))
    end

    it "la scheda velocità si aggancia agli stessi aggiornamenti, col proprio indirizzo" do
      get performance_member_monitoring_seo_site_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="seo-site-live"')
      expect(response.body).to include("turbo-cable-stream-source")
      expect(response.body).to include(%(data-live-frame-url-value="#{performance_member_monitoring_seo_site_path(site)}"))
    end

    it "rende tutto come prima: nessun buco da riempire con una seconda richiesta" do
      create(:seo_issue, site:, check_key: "missing_h1")
      create(:seo_audit, :completed, site:)

      get member_monitoring_seo_site_path(site)

      expect(response.body).to include('data-test="seo-site-counts"')
      expect(response.body).to include('data-test="seo-site-issues"')
      expect(response.body).to include('data-test="seo-site-pages"')
      expect(response.body).to include('data-test="seo-site-audits"')
      expect(response.body).to include('data-test="seo-site-configuration"')
    end
  end

  describe "il riquadro ricaricato da solo" do
    before { sign_in(owner) }

    it "porta stato e risultati, senza rifare la pagina intorno" do
      create(:seo_audit, :completed, site:)

      get member_monitoring_seo_site_path(site), headers: frame

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="seo-site-live"')
      expect(response.body).to include('data-test="seo-site-counts"')
      expect(response.body).to include('data-test="seo-site-audits"')
      # Nessun layout: barra laterale, intestazione del sito e il resto restano dove sono.
      expect(response.body).not_to include("<html")
      expect(response.body).not_to include('data-test="skip-link"')
    end

    it "sulla scheda velocità porta le misure, e nient'altro" do
      create(:seo_lab_run, :completed, site:, strategy: :mobile)
      create(:integration_credential, :pagespeed, organization: org)

      get performance_member_monitoring_seo_site_path(site), headers: frame

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="seo-site-live"')
      expect(response.body).to include('data-test="seo-performance-lab"')
      expect(response.body).not_to include("<html")
    end

    # Il segnale è uno solo per tutti: il riquadro deve arrivare filtrato dalla sessione di chi lo
    # chiede, non da chi lo ha fatto partire.
    it "a chi non può far ripartire il controllo non offre i bottoni per farlo" do
      sign_in(solo_lettura)

      get member_monitoring_seo_site_path(site), headers: frame

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-test="seo-site-rescan"')
      expect(response.body).not_to include('data-test="seo-site-edit"')
    end

    it "il sito di un'altra organizzazione resta un 404" do
      altrui = create(:seo_site)

      get member_monitoring_seo_site_path(altrui), headers: frame

      expect(response).to have_http_status(:not_found)
    end

    # Scenario 1: il giro finisce e i conteggi cambiano da soli.
    it "dopo un giro finito porta i conteggi nuovi" do
      create(:seo_issue, site:, check_key: "missing_h1", severity: :critical)

      get member_monitoring_seo_site_path(site), headers: frame

      expect(response.body).to include('data-test="seo-site-stat-critical"')
      expect(response.body).to include('data-test="seo-site-audits"')
    end

    # Scenario 2: il giro fallisce. Non un silenzio, non un finto avanzamento: il motivo scritto.
    it "dopo un giro fallito dice cosa non ha funzionato" do
      site.update!(last_audited_at: Time.current, last_error: "timeout")
      create(:seo_audit, :failed, site:, error: "timeout")

      get member_monitoring_seo_site_path(site), headers: frame

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="seo-site-audit-failed"')
      expect(response.body).to include("timeout")
    end

    # Un tentativo andato male non cancella l'unica cosa che sappiamo del sito.
    it "un giro fallito non porta via i numeri buoni di prima" do
      create(:seo_lab_run, :completed, site:, strategy: :mobile, started_at: 2.days.ago)
      site.update!(last_lab_error: "quota_exceeded")
      create(:integration_credential, :pagespeed, organization: org)

      get performance_member_monitoring_seo_site_path(site), headers: frame

      expect(response.body).to include('data-test="seo-performance-stale"')
      expect(response.body).to include("quota_exceeded")
      expect(response.body).to include('data-test="seo-lab-mobile"')
    end

    # Consultare non è misurare: il riquadro si ri-chiede da solo, e se ogni richiesta accodasse un
    # giro il sito verrebbe visitato ogni volta che qualcuno guarda la sua scheda.
    it "non fa partire nessun controllo nuovo" do
      expect { get member_monitoring_seo_site_path(site), headers: frame }
        .not_to have_enqueued_job(Seo::AuditSiteJob)
      expect { get performance_member_monitoring_seo_site_path(site), headers: frame }
        .not_to have_enqueued_job(Seo::LabRunJob)
    end
  end
end
