# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring SEO sites", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization: org, supports_analytics: true))
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "elenca i siti sotto controllo" do
      create(:seo_site, project:, environment:, base_url: "https://acme.test")
      sign_in(owner)

      get member_monitoring_seo_sites_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("https://acme.test")
      expect(response.body).to include("seo-counts")
    end

    it "senza siti invita a dichiararne uno" do
      sign_in(owner)

      get member_monitoring_seo_sites_path

      expect(response.body).to include("seo-sites-empty")
    end

    it "non mostra i siti di un'altra organizzazione" do
      other = create(:project)
      other_env = create(:environment, organization: other.organization)
      other.environments << other_env
      create(:seo_site, project: other, environment: other_env, base_url: "https://altrove.test")
      sign_in(owner)

      get member_monitoring_seo_sites_path

      expect(response.body).not_to include("https://altrove.test")
    end
  end

  describe "POST create" do
    it "does not schedule a check when the site is disabled" do
      sign_in(owner)
      expect do
        post member_monitoring_seo_sites_path, params: {
          project_id: project.id, environment_id: environment.id,
          base_url: "https://disabled.test", frequency: "weekly", max_pages: "50", enabled: "0"
        }
      end.to change(Seo::Site, :count).by(1)
      expect(Seo::AuditSiteJob).not_to have_been_enqueued
    end

    it "crea il sito e fa partire subito il primo controllo" do
      sign_in(owner)

      expect do
        post member_monitoring_seo_sites_path, params: {
          project_id: project.id, environment_id: environment.id,
          base_url: "https://acme.test/", frequency: "weekly", max_pages: "50",
          follow_sitemap: "1", enabled: "1"
        }
      end.to change(Seo::Site, :count).by(1)

      site = Seo::Site.last
      expect(site.base_url).to eq("https://acme.test")
      expect(site).to be_every_weekly
      expect(site.max_pages).to eq(50)
      expect(site.created_by).to eq(owner)
      expect(Seo::AuditSiteJob).to have_been_enqueued.with(site.id)
    end

    it "rifiuta un indirizzo interno e lo dice nel form" do
      sign_in(owner)

      post member_monitoring_seo_sites_path, params: {
        project_id: project.id, environment_id: environment.id, base_url: "http://127.0.0.1:3000"
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Seo::Site.count).to be_zero
    end

    it "chi non ha seo.manage non può creare" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, project:, account: member)
      sign_in(member)

      post member_monitoring_seo_sites_path, params: {
        project_id: project.id, environment_id: environment.id, base_url: "https://acme.test"
      }

      expect(response).not_to have_http_status(:ok)
      expect(Seo::Site.count).to be_zero
    end
  end

  describe "PATCH update" do
    it "cambia frequenza e tetto delle pagine" do
      site = create(:seo_site, project:, environment:)
      sign_in(owner)

      patch member_monitoring_seo_site_path(site), params: {
        base_url: site.base_url, frequency: "weekly", max_pages: "20", follow_sitemap: "0", enabled: "0"
      }

      site.reload
      expect(site).to be_every_weekly
      expect(site.max_pages).to eq(20)
      expect(site.follow_sitemap).to be(false)
      expect(site).not_to be_enabled
    end

    it "un sito di un'altra organizzazione non esiste" do
      other = create(:project)
      other_env = create(:environment, organization: other.organization)
      other.environments << other_env
      site = create(:seo_site, project: other, environment: other_env)
      sign_in(owner)

      patch member_monitoring_seo_site_path(site), params: { base_url: "https://cambiato.test" }

      expect(response).to have_http_status(:not_found)
      expect(site.reload.base_url).not_to eq("https://cambiato.test")
    end
  end

  # CYRA-808 — l'elenco dei siti dice quante pagine ha visto l'ultimo giro: da solo quel numero fa
  # sembrare controllato anche ciò che non si è riusciti a leggere.
  it "nell'elenco la riga di un sito dice quante pagine il giro non ha letto" do
    site = create(:seo_site, project:, environment:, last_audited_at: 1.hour.ago)
    create(:seo_audit, site:, status: :completed, pages_count: 12, pages_unverified_count: 4)
    sign_in(owner)

    get member_monitoring_seo_sites_path

    expect(response.body).to include('data-test="seo-site-row-unverified"')
  end

  it "nell'elenco non parla di pagine non lette quando il giro le ha lette tutte" do
    site = create(:seo_site, project:, environment:, last_audited_at: 1.hour.ago)
    create(:seo_audit, site:, status: :completed, pages_count: 12)
    sign_in(owner)

    get member_monitoring_seo_sites_path

    expect(response.body).not_to include('data-test="seo-site-row-unverified"')
  end

  # CYRA-818 — la riga dell'elenco metteva accanto alla data dell'ultimo controllo il numero di
  # pagine di un controllo PRECEDENTE: due fatti che si leggono come uno solo, e che il dettaglio
  # smentiva. Data e numero devono venire dallo stesso giro.
  describe "l'ultimo controllo nell'elenco" do
    it "abbina alla data il numero di pagine di quel controllo, non di uno vecchio" do
      site = create(:seo_site, project:, environment:, last_audited_at: 1.hour.ago)
      create(:seo_audit, :completed, site:, started_at: 3.days.ago, pages_count: 23)
      create(:seo_audit, :completed, site:, started_at: 1.hour.ago, pages_count: 79)
      sign_in(owner)

      get member_monitoring_seo_sites_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="seo-site-row"]').text
      expect(riga).to include("79")
      expect(riga).not_to include("23")
    end

    it "con un solo controllo mostra il numero di quel controllo" do
      site = create(:seo_site, project:, environment:, last_audited_at: 1.hour.ago)
      create(:seo_audit, :completed, site:, started_at: 1.hour.ago, pages_count: 41)
      sign_in(owner)

      get member_monitoring_seo_sites_path

      expect(Nokogiri::HTML(response.body).at_css('[data-test="seo-site-row"]').text).to include("41")
    end

    it "senza nessun controllo dice che il sito non è mai stato controllato" do
      create(:seo_site, project:, environment:, base_url: "https://acme.test")
      sign_in(owner)

      get member_monitoring_seo_sites_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="seo-site-row"]').text
      expect(riga).to include(I18n.t("member.monitoring.seo_sites.never_audited"))
    end

    it "un controllo ancora in corso non azzera i numeri dell'ultimo concluso" do
      site = create(:seo_site, project:, environment:, last_audited_at: 2.hours.ago)
      create(:seo_audit, :completed, site:, started_at: 2.hours.ago, pages_count: 79)
      create(:seo_audit, site:, status: :running, started_at: 1.minute.ago, pages_count: 0)
      sign_in(owner)

      get member_monitoring_seo_sites_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="seo-site-row"]').text
      expect(riga).to include("79")
    end

    it "il numero dell'elenco è quello che la cronologia del dettaglio mette in cima" do
      site = create(:seo_site, project:, environment:, last_audited_at: 1.hour.ago)
      create(:seo_audit, :completed, site:, started_at: 3.days.ago, pages_count: 23)
      create(:seo_audit, :completed, site:, started_at: 1.hour.ago, pages_count: 79)
      sign_in(owner)

      get member_monitoring_seo_sites_path
      elenco = Nokogiri::HTML(response.body).at_css('[data-test="seo-site-row"]').text

      get member_monitoring_seo_site_path(site)
      ultimo_giro = Nokogiri::HTML(response.body).css('[data-test="seo-site-audit"]').first.text

      expect(elenco).to include("79")
      expect(ultimo_giro).to include("79")
    end

    it "una pagina sola si legge al singolare e la data dice quanto tempo fa" do
      site = create(:seo_site, project:, environment:, last_audited_at: 1.hour.ago)
      create(:seo_audit, :completed, site:, started_at: 1.hour.ago, pages_count: 1)
      sign_in(owner)

      get member_monitoring_seo_sites_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="seo-site-row"]').text.squish
      expect(riga).to include("about 1 hour ago · 1 page")
      expect(riga).not_to include("1 pages")
    end
  end

  # CYRA-536 — nell'elenco la riga portava FUORI dall'applicazione, sul sito stesso: l'unica cosa che
  # si poteva già aprire da soli. Tutto ciò che il sistema sa di quel sito si leggeva solo in elenchi
  # globali, filtrati a mano.
  describe "GET show" do
    it "raccoglie i rilievi aperti, le pagine e lo storico dei giri di quel sito" do
      site = create(:seo_site, project:, environment:, base_url: "https://acme.test")
      pagina = create(:seo_page, site:, url: "https://acme.test/prezzi", path: "/prezzi")
      create(:seo_issue, site:, page: pagina, severity: :critical, check_key: "missing_title")
      create(:seo_issue, site:, page: pagina, severity: :low, check_key: "title_too_long")
      create(:seo_issue, site:, page: pagina, severity: :high, check_key: "missing_h1", status: :resolved)
      create(:seo_audit, site:, status: :completed, pages_count: 12)
      sign_in(owner)

      get member_monitoring_seo_site_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("https://acme.test")
      expect(response.body).to include("/prezzi")
      expect(response.body).to include('data-test="seo-site-audits"')
      # Le chip contano i rilievi di QUESTO sito: due aperti su tre, uno risolto.
      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css('[data-test="seo-site-stat-open"]').text).to include("2")
      expect(pagina.at_css('[data-test="seo-site-stat-critical"]').text).to include("1")
    end

    # Un giro fallito che somigliasse a un giro riuscito è la cosa peggiore che questa pagina possa
    # fare: è la stessa regola già scritta sulla riga dell'elenco.
    it "distingue un giro fallito da uno riuscito, col suo motivo" do
      site = create(:seo_site, project:, environment:)
      create(:seo_audit, site:, status: :failed, error: "robots.txt irraggiungibile")
      sign_in(owner)

      get member_monitoring_seo_site_path(site)

      expect(response.body).to include("robots.txt irraggiungibile")
      expect(response.body).to include('data-test="seo-site-audit-failed"')
    end

    # CYRA-808 — un giro che non è riuscito a leggere metà delle pagine somiglia in tutto a un giro
    # riuscito, e il numero dei rilievi che non scende sembra un guasto. Il conteggio lo dice.
    it "dice quante pagine un giro non è riuscito a leggere" do
      site = create(:seo_site, project:, environment:)
      create(:seo_audit, site:, status: :completed, pages_count: 12, pages_unverified_count: 4)
      sign_in(owner)

      get member_monitoring_seo_site_path(site)

      expect(response.body).to include('data-test="seo-site-audit-unverified"')
    end

    it "non parla di pagine non lette quando il giro le ha lette tutte" do
      site = create(:seo_site, project:, environment:)
      create(:seo_audit, site:, status: :completed, pages_count: 12)
      sign_in(owner)

      get member_monitoring_seo_site_path(site)

      expect(response.body).not_to include('data-test="seo-site-audit-unverified"')
    end

    it "mostra le visite solo dove il progetto le raccoglie" do
      site = create(:seo_site, project:, environment:)
      sign_in(owner)

      get member_monitoring_seo_site_path(site)
      expect(response.body).not_to include('data-test="seo-site-visits"')

      project.update!(analytics_enabled: true)
      get member_monitoring_seo_site_path(site)
      expect(response.body).to include('data-test="seo-site-visits"')
    end

    it "un sito di un'altra organizzazione non esiste" do
      other = create(:project)
      other_env = create(:environment, organization: other.organization)
      other.environments << other_env
      site = create(:seo_site, project: other, environment: other_env)
      sign_in(owner)

      get member_monitoring_seo_site_path(site)

      expect(response).to have_http_status(:not_found)
    end

    it "le pagine e i rilievi del sito hanno una scheda propria, paginata" do
      site = create(:seo_site, project:, environment:)
      pagina = create(:seo_page, site:, url: "https://acme.test/blog", path: "/blog")
      create(:seo_issue, site:, page: pagina, check_key: "thin_content")
      sign_in(owner)

      get pages_member_monitoring_seo_site_path(site)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/blog")

      get issues_member_monitoring_seo_site_path(site)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("thin_content").or include(Seo::Check.new("thin_content").label)
    end
  end

  describe "DELETE destroy" do
    it "rimuove il sito con tutto quello che ne dipende" do
      site = create(:seo_site, project:, environment:)
      create(:seo_issue, site:, page: nil, check_key: "duplicate_title")
      sign_in(owner)

      expect { delete member_monitoring_seo_site_path(site) }.to change(Seo::Site, :count).by(-1)
      expect(Seo::Issue.count).to be_zero
    end
  end
end
