# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Knowledge::Versions", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  # La pagina è la LIVE/HEAD: il suo contenuto = quello dell'ultima versione (v2).
  let(:page) { create(:knowledge_page, organization: org, project: project, created_by: member, title: "Attuale", body: "Corpo due") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # v1 (storica) + v2 (rispecchia la live).
  def build_history!
    create(:knowledge_version, page: page, organization: org, created_by: member, number: 1, title: "Prima", body: "Corpo uno")
    create(:knowledge_version, page: page, organization: org, created_by: member, number: 2, title: "Attuale", body: "Corpo due")
  end

  describe "GET /member/knowledge/pages/:page_id/versions" do
    it "elenca le versioni con chip conteggio e badge LIVE sull'ultima" do
      build_history!
      sign_in(member)

      get member_knowledge_page_versions_path(page)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="knowledge-versions-counts"')
      expect(response.body).to include("v1")
      expect(response.body).to include("v2")
      expect(response.body).to include(I18n.t("member.knowledge.versions.live"))
    end

    it "mostra il pulsante Ripristina all'autore sulle versioni non-live" do
      build_history!
      sign_in(member)

      get member_knowledge_page_versions_path(page)
      expect(response.body).to include('data-test="knowledge-version-restore"')
    end

    it "pagina di progetto non visibile → 404 (anti-BOLA)" do
      hidden = create(:knowledge_page, organization: org, project: create(:project, organization: org))
      create(:knowledge_version, page: hidden, organization: org, number: 1)
      sign_in(member)

      get member_knowledge_page_versions_path(hidden)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /member/knowledge/pages/:page_id/versions/:id" do
    it "renderizza lo snapshot storico read-only e lo marca come storico" do
      build_history!
      sign_in(member)

      get member_knowledge_page_version_path(page, 1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Corpo uno")
      expect(response.body).to include('data-test="knowledge-version-historical"')
    end

    it "marca la versione più recente come live" do
      build_history!
      sign_in(member)

      get member_knowledge_page_version_path(page, 2)
      expect(response.body).to include(I18n.t("member.knowledge.versions.live"))
    end

    it "numero versione inesistente → 404" do
      build_history!
      sign_in(member)

      get member_knowledge_page_version_path(page, 99)
      expect(response).to have_http_status(:not_found)
    end

    it "il corpo markdown dello snapshot ha una measure leggibile (max-w-[70ch]), non max-w-none" do
      build_history!
      sign_in(member)

      get member_knowledge_page_version_path(page, 1)
      body_wrap = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-version-body"] .prose')
      expect(body_wrap["class"]).to include("max-w-[70ch]")
      expect(body_wrap["class"]).not_to include("max-w-none")
    end
  end

  describe "POST /member/knowledge/pages/:page_id/versions/:id/restore" do
    it "l'autore ripristina una versione: nuova versione + pagina aggiornata" do
      build_history!
      sign_in(member)

      expect do
        post restore_member_knowledge_page_version_path(page, 1)
      end.to change { page.versions.count }.by(1)

      expect(response).to redirect_to(member_knowledge_page_path(page))
      expect(page.reload.title).to eq("Prima")
      expect(page.body).to eq("Corpo uno")
      expect(page.versions.maximum(:number)).to eq(3)
    end

    it "ripristinare la versione già live è idempotente (nessuna nuova versione)" do
      build_history!
      sign_in(member)

      expect do
        post restore_member_knowledge_page_version_path(page, 2)
      end.not_to change { page.versions.count }
      expect(page.reload.title).to eq("Attuale")
    end

    it "un member senza knowledge.edit NON ripristina la pagina altrui (redirect)" do
      foreign = create(:knowledge_page, organization: org, project: project, title: "Altro", body: "X")
      create(:knowledge_version, page: foreign, organization: org, number: 1, title: "Old", body: "Old body")
      sign_in(member)

      post restore_member_knowledge_page_version_path(foreign, 1)
      expect(response).to redirect_to(root_path)
      expect(foreign.reload.title).to eq("Altro")
    end

    it "l'owner ripristina la pagina altrui" do
      foreign = create(:knowledge_page, organization: org, project: project, title: "Altro", body: "X")
      create(:knowledge_version, page: foreign, organization: org, number: 1, title: "Old", body: "Old body")
      sign_in(owner)

      post restore_member_knowledge_page_version_path(foreign, 1)
      expect(foreign.reload.title).to eq("Old")
    end
  end

  it "non autenticato → redirect al login" do
    build_history!
    get member_knowledge_page_versions_path(page)
    expect(response).to redirect_to(login_path)
  end

  # CYRA-924 — every column but restore sorts (C9).
  it "sorts the versions by author both ways and offers every column" do
    create(:knowledge_version, page: page, organization: org, created_by: member, number: 1, author_name: "Zoe Writer")
    create(:knowledge_version, page: page, organization: org, created_by: member, number: 2, author_name: "abel Editor")
    sign_in(owner)

    get member_knowledge_page_versions_path(page), params: { sort: "author" }
    expect(response.body.index("abel Editor")).to be < response.body.index("Zoe Writer")
    get member_knowledge_page_versions_path(page), params: { sort: "-author" }
    expect(response.body.index("Zoe Writer")).to be < response.body.index("abel Editor")
    %w[number author date status].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
  end

  # CYRA-924 — restoring asks in a dialog that names the version, never in the browser box (F16, P2).
  describe "restore confirmation (dialog)" do
    it "opens a dialog that sends the restore" do
      build_history!
      sign_in(member)
      version = page.versions.find_by!(number: 1)

      get member_knowledge_page_versions_path(page)

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='knowledge-version-restore-dialog-#{version.id}']")
      expect(dialog.text).to include(I18n.t("member.knowledge.versions.restore_dialog.title", number: 1))
      expect(dialog.at_css("form")["action"]).to eq(restore_member_knowledge_page_version_path(page, version))
      expect(dialog.at_css("form input[name='_method']")).to be_nil
      expect(dialog.ancestors.first.at_css("[data-test='knowledge-version-restore']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
