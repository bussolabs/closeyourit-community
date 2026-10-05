# frozen_string_literal: true

require "rails_helper"

# CYRA-433 — autocomplete dei titoli mentre si scrive un wikilink `[[…]]` nel corpo di una pagina.
# Il rischio del ticket è uno solo: suggerire il titolo di una pagina che chi scrive non può aprire.
RSpec.describe "Member::Knowledge::Pages#link_suggestions", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def suggestions(params = {})
    get link_suggestions_member_knowledge_pages_path, params: params
    JSON.parse(response.body)["data"]
  end

  it "propone i titoli delle pagine visibili con l'etichetta del tipo" do
    create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal", kind: :guide)
    sign_in(member)

    rows = suggestions(q: "deploy")

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(rows).to eq([ { "title" => "Deploy Kamal", "hint" => I18n.t("member.knowledge.kind.guide") } ])
  end

  it "senza query propone comunque qualcosa: l'elenco si apre insieme alle doppie parentesi" do
    create(:knowledge_page, organization: org, project: project, title: "Rollback")
    sign_in(member)

    expect(suggestions.map { |row| row["title"] }).to eq([ "Rollback" ])
  end

  it "ANTI-LEAK: non propone il titolo di una pagina di un progetto non visibile" do
    hidden_project = create(:project, organization: org)
    create(:knowledge_page, organization: org, project: hidden_project, title: "Riservata")
    sign_in(member)

    expect(suggestions(q: "ris")).to be_empty
    expect(response.body).not_to include("Riservata")
  end

  it "ANTI-LEAK: non propone il titolo di una pagina di un'altra organizzazione" do
    other_org = create(:organization)
    other_project = create(:project, organization: other_org)
    create(:knowledge_page, organization: other_org, project: other_project, title: "Deploy altrui")
    create(:knowledge_page, organization: org, project: project, title: "Deploy nostro")
    sign_in(member)

    expect(suggestions(q: "deploy").map { |row| row["title"] }).to eq([ "Deploy nostro" ])
  end

  it "non propone una proposta ancora in revisione" do
    create(:knowledge_page, organization: org, project: project, title: "Proposta", status: :in_review)
    sign_in(member)

    expect(suggestions(q: "prop")).to be_empty
  end

  it "esclude la pagina che si sta modificando" do
    page = create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal")
    sign_in(member)

    expect(suggestions(q: "deploy", exclude_id: page.id)).to be_empty
  end

  it "chiede l'autenticazione" do
    get link_suggestions_member_knowledge_pages_path

    expect(response).to have_http_status(:found)
  end
end
