# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring SEO", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def site_in(target_project)
    environment = create(:environment, organization: target_project.organization)
    target_project.environments << environment
    create(:seo_site, project: target_project, environment:)
  end

  def issue_in(target_project, check_key: "missing_h1", **attrs)
    site = site_in(target_project)
    page = create(:seo_page, site:, url: "#{site.base_url}/chi-siamo")
    create(:seo_issue, site:, page:, check_key:, **attrs)
  end

  describe "GET index" do
    it "elenca i rilievi dei progetti visibili con le chip dei conteggi" do
      issue_in(project)
      sign_in(owner)

      get member_monitoring_seo_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("seo-counts")
      expect(response.body).to include("/chi-siamo")
    end

    it "l'ultimo controllo di un rilievo dice quanto tempo fa" do
      issue_in(project, last_seen_at: 2.days.ago)
      sign_in(owner)

      get member_monitoring_seo_index_path

      expect(Nokogiri::HTML(response.body).at_css('[data-test="seo-row"]').text.squish).to include("2 days ago")
    end

    it "NON mostra i rilievi di un'altra organizzazione" do
      issue_in(create(:project))
      sign_in(owner)

      get member_monitoring_seo_index_path

      expect(response.body).not_to include("/chi-siamo")
    end

    it "filtra per gravità" do
      issue_in(project, check_key: "noindex", severity: :critical)
      sign_in(owner)

      get member_monitoring_seo_index_path, params: { severity: [ "low" ] }

      expect(response.body).to include("seo-no-match")
    end

    it "filtra per ambito del controllo" do
      issue_in(project, check_key: "missing_h1") # struttura
      sign_in(owner)

      get member_monitoring_seo_index_path, params: { area: [ "performance" ] }

      expect(response.body).to include("seo-no-match")
    end

    it "senza nemmeno un rilievo mostra l'invito a dichiarare un sito" do
      sign_in(owner)

      get member_monitoring_seo_index_path

      expect(response.body).to include("seo-empty")
    end
  end

  describe "GET pages" do
    it "elenca le pagine viste" do
      site = site_in(project)
      create(:seo_page, site:, url: "#{site.base_url}/prezzi")
      sign_in(owner)

      get pages_member_monitoring_seo_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/prezzi")
    end

    it "fra siti diversi la pagina si riconosce dal dominio e la data dice quanto tempo fa" do
      site = site_in(project)
      create(:seo_page, site:, url: "https://www.acme.test/", last_seen_at: 2.days.ago)
      sign_in(owner)

      get pages_member_monitoring_seo_index_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="seo-page-row"]').text.squish
      expect(riga).to include("www.acme.test/")
      expect(riga).to include("2 days ago")
    end
  end

  describe "GET show" do
    it "mostra la prova del rilievo" do
      issue = issue_in(project)
      sign_in(owner)

      get member_monitoring_seo_path(issue)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("seo-evidence")
    end

    it "nel percorso c'è il nome del rilievo, non la sua chiave, e le date dicono quanto tempo fa" do
      issue = issue_in(project, check_key: "noindex", first_seen_at: 3.days.ago, last_seen_at: 3.days.ago)
      sign_in(owner)

      get member_monitoring_seo_path(issue)

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('nav[aria-label="breadcrumb"]').text).to include(issue.label)
      expect(html.at_css('nav[aria-label="breadcrumb"]').text).not_to include("noindex")
      expect(html.at_css('[data-test="seo-issue-details"]').text.squish).to include("3 days ago")
    end

    # CYRA-552 — la scheda si apriva solo per le gravità che colorano la chip: media e bassa
    # arrivavano alla pagina di errore.
    %i[medium low].each do |severity|
      it "si apre anche per un rilievo di gravità #{severity}" do
        issue = issue_in(project, severity:)
        sign_in(owner)

        get member_monitoring_seo_path(issue)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("seo-stat-issue-severity")
      end
    end

    it "un rilievo di un'altra organizzazione non esiste, non è vietato" do
      issue = issue_in(create(:project))
      sign_in(owner)

      get member_monitoring_seo_path(issue)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "triage" do
    it "ignorare richiede seo.triage" do
      issue = issue_in(project)
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, project:, account: member)
      sign_in(member)

      patch ignore_member_monitoring_seo_path(issue)

      expect(response).not_to have_http_status(:ok)
      expect(issue.reload).to be_status_open
    end

    it "chi ha il permesso può ignorare e poi riaprire" do
      issue = issue_in(project)
      sign_in(owner)

      patch ignore_member_monitoring_seo_path(issue), params: { triage_note: "pagina di servizio" }
      expect(issue.reload).to be_status_ignored
      expect(issue.triage_note).to eq("pagina di servizio")

      patch reopen_member_monitoring_seo_path(issue)
      expect(issue.reload).to be_status_open
    end

    it "promuove il rilievo a ticket, portandosi dietro la prova" do
      create(:ticket_status, organization: org, code: "open", position: 0)
      create(:ticket_priority, organization: org, code: "high", position: 0)
      issue = issue_in(project)
      sign_in(owner)

      expect { post promote_member_monitoring_seo_path(issue) }
        .to change(Ticketing::Ticket, :count).by(1)

      expect(issue.reload).to be_promoted
      expect(issue.ticket.technical_analysis).to include("missing_h1")
    end
  end

  describe "POST rescan" do
    it "accoda una visita per il sito indicato" do
      site = site_in(project)
      sign_in(owner)

      expect { post rescan_member_monitoring_seo_index_path, params: { site_id: site.id } }
        .to have_enqueued_job(Seo::AuditSiteJob).with(site.id)
    end

    it "un sito che non vedi non fa partire niente" do
      site = site_in(create(:project))
      sign_in(owner)

      expect { post rescan_member_monitoring_seo_index_path, params: { site_id: site.id } }
        .not_to have_enqueued_job(Seo::AuditSiteJob)
    end
  end
end
