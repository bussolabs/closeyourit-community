# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Searches", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "GET /member/search" do
    it "rende il turbo frame con i risultati visibili e i link alle risorse" do
      project = create(:project, organization: organization, name: "Apollo")
      ticket = create(:ticket, :plain_bug, organization: organization, project: project,
                                           title: "Deploy Apollo bloccato")
      error_group = create(:error_group, project: project, title: "Apollo::Timeout")
      page = create(:knowledge_page, project: project, organization: organization,
                                     title: "Runbook Apollo")

      get member_search_path, params: { q: "Apollo" }

      expect(response).to have_http_status(:ok)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("turbo-frame#member-global-search-results")).to be_present
      expect(html.at_css("[data-test='global-search-result-project-#{project.id}']")["href"])
        .to eq(member_project_path(project))
      expect(html.at_css("[data-test='global-search-result-ticket-#{ticket.id}']")["href"])
        .to eq(member_ticket_path(ticket))
      expect(html.at_css("[data-test='global-search-result-error-group-#{error_group.id}']")["href"])
        .to eq(member_monitoring_error_group_path(error_group))
      expect(html.at_css("[data-test='global-search-result-page-#{page.id}']")["href"])
        .to eq(member_knowledge_page_path(page))
    end

    it "non espone risultati appartenenti a un'altra organizzazione" do
      visible = create(:project, organization: organization, name: "Apollo visibile")
      foreign = create(:project, name: "Apollo riservato")

      get member_search_path, params: { q: "Apollo" }

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-test='global-search-result-project-#{visible.id}']")).to be_present
      expect(html.at_css("[data-test='global-search-result-project-#{foreign.id}']")).to be_nil
    end

    it "rispetta la visibilità per progetto di un membro" do
      member = create(:account)
      create(:membership, account: member, organization: organization, role: :member)
      visible = create(:project, organization: organization, name: "Apollo assegnato")
      hidden = create(:project, organization: organization, name: "Apollo nascosto")
      create(:project_membership, account: member, project: visible)

      delete logout_path
      post login_path, params: { email: member.email, password: "Secret123!" }
      get member_search_path, params: { q: "Apollo" }

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-test='global-search-result-project-#{visible.id}']")).to be_present
      expect(html.at_css("[data-test='global-search-result-project-#{hidden.id}']")).to be_nil
    end

    it "mostra lo stato iniziale senza eseguire una ricerca" do
      get member_search_path, params: { q: "" }

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css("[data-test='global-search-prompt']")).to be_present
    end

    it "aperta come pagina ha intestazione e un campo con la ricerca fatta" do
      create(:project, organization: organization, name: "Apollo")

      get member_search_path, params: { q: "Apollo" }

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-test='search-page'] h1").text).to include(I18n.t("member.search.title"))
      expect(html.at_css("[data-test='search-page-input']")["value"]).to eq("Apollo")
    end

    it "dentro il pannello rende solo i risultati, senza intestazione" do
      get member_search_path, params: { q: "Apollo" },
                              headers: { "Turbo-Frame" => "member-global-search-results" }

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("turbo-frame#member-global-search-results")).to be_present
      expect(html.at_css("[data-test='search-page']")).to be_nil
    end

    it "mostra uno stato vuoto quando la query non trova risultati" do
      get member_search_path, params: { q: "nessuna-corrispondenza" }

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css("[data-test='global-search-empty']")).to be_present
    end
  end

  describe "results panel (CYRA-900)" do
    let(:html) { Nokogiri::HTML(response.body) }

    def search(query, **params)
      get member_search_path, params: { q: query, **params }, headers: { "Turbo-Frame" => "member-global-search-results" }
    end

    it "finds menu pages the viewer can open" do
      search("Ticket")

      entry = html.at_css("[data-test='global-search-group-nav'] a[href='#{member_tickets_path}']")
      expect(entry).to be_present
    end

    it "highlights the matched words in the title" do
      create(:project, organization: organization, name: "Apollo Control")

      search("apollo")

      expect(html.at_css("[data-test='global-search-group-projects'] mark").text).to eq("Apollo")
    end

    it "offers one filter per kind with results and keeps the query in each filter link" do
      create(:project, organization: organization, name: "Apollo")

      search("Apollo")

      chip = html.at_css("[data-test='global-search-filter-projects']")
      expect(chip["href"]).to eq(member_search_path(q: "Apollo", type: "projects"))
      expect(chip["data-turbo-frame"]).to eq("_self")
      expect(html.at_css("[data-test='global-search-filter-all']")).to be_present
    end

    it "links to the full list when a group has more than it shows" do
      create_list(:project, 7, organization: organization, name: "Apollo")

      search("Apollo")

      see_all = html.at_css("[data-test='global-search-see-all-projects']")
      expect(see_all["href"]).to eq(member_projects_path(q: "Apollo"))
      expect(see_all.text).to include("7")
    end

    it "opens a direct chat with a person" do
      person = create(:account, name: "Ada Apollo")
      create(:membership, account: person, organization: organization, role: :member)

      search("Ada Apollo")

      result = html.at_css("[data-test='global-search-result-person-#{person.id}']")
      expect(result["href"]).to eq(member_chat_conversations_path(kind: "direct", account_id: person.id))
      expect(result["data-turbo-method"]).to eq("post")
    end

    it "sends a secret name to the vault's variable search, without its value" do
      project = create(:project, organization: organization)
      create(:secret_variable, project: project, name: "APOLLO_TOKEN", value: "never-shown")

      search("APOLLO_TOK")

      result = html.at_css("[data-test='global-search-result-secret-APOLLO_TOKEN']")
      expect(result["href"]).to eq(member_vault_variables_path(q: "APOLLO_TOKEN"))
      expect(response.body).not_to include("never-shown")
    end
  end
end
