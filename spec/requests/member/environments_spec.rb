# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Environments", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: admin, organization: org, role: :admin)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_environments_path
      expect(response).to redirect_to(login_path)
    end

    it "membro semplice senza permesso → redirect a root (gate environments.view)" do
      sign_in(member)
      create(:environment, organization: org)
      get member_environments_path
      expect(response).to redirect_to(root_path)
    end

    it "membro con environments.view → 200" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "environments.view" ], actor: owner
      )
      sign_in(member)
      create(:environment, organization: org)
      get member_environments_path
      expect(response).to have_http_status(:ok)
    end

    it "pagina: pagina 1 piena (TABLE_PER_PAGE righe) + footer, resto in pagina 2" do
      sign_in(owner)
      create_list(:environment, App::Constants::TABLE_PER_PAGE + 1, organization: org)

      get member_environments_path, params: { page: 1 }
      expect(response.body.scan('data-test="member-environment"').size).to eq(App::Constants::TABLE_PER_PAGE)
      expect(response.body).to include('data-test="environments-pagination"')

      get member_environments_path, params: { page: 2 }
      expect(response.body.scan('data-test="member-environment"').size).to eq(1)
    end
  end

  describe "GET new" do
    it "admin → 200" do
      sign_in(owner)
      get new_member_environment_path
      expect(response).to have_http_status(:ok)
    end

    it "membro semplice → redirect (forbidden)" do
      sign_in(member)
      get new_member_environment_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "admin crea (code normalizzato, created_by)" do
      sign_in(owner)
      expect do
        post member_environments_path, params: { label: "Production", code: "Production", color: "sky", active: "1" }
      end.to change(Types::Environment, :count).by(1)
      environment = Types::Environment.last
      expect(environment.code).to eq("production")
      expect(environment.created_by).to eq(owner)
      expect(response).to redirect_to(member_environments_path)
    end

    it "salva i default di capability passati" do
      sign_in(owner)
      post member_environments_path, params: {
        label: "QA", code: "qa", color: "sky", active: "1",
        servers_enabled: "1", uptime_enabled: "0", secrets_enabled: "1"
      }
      environment = Types::Environment.last
      expect([ environment.servers_enabled, environment.uptime_enabled, environment.secrets_enabled ]).to eq([ true, false, true ])
    end

    it "membro semplice → redirect, niente creato" do
      sign_in(member)
      expect do
        post member_environments_path, params: { label: "X", code: "x" }
      end.not_to change(Types::Environment, :count)
      expect(response).to redirect_to(root_path)
    end

    it "dati invalidi → 422" do
      sign_in(owner)
      post member_environments_path, params: { label: "", code: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET edit / PATCH update" do
    it "admin → 200 (render form)" do
      sign_in(owner)
      environment = create(:environment, organization: org)
      get edit_member_environment_path(environment)
      expect(response).to have_http_status(:ok)
    end

    it "admin aggiorna" do
      sign_in(owner)
      environment = create(:environment, organization: org, label: "Old")
      patch member_environment_path(environment),
            params: { label: "New", code: environment.code, color: environment.color, active: "1" }
      expect(environment.reload.label).to eq("New")
      expect(response).to redirect_to(member_environments_path)
    end

    it "aggiorna i default di capability" do
      sign_in(owner)
      environment = create(:environment, organization: org)
      patch member_environment_path(environment), params: {
        label: environment.label, code: environment.code, color: environment.color, active: "1",
        servers_enabled: "0", uptime_enabled: "1", secrets_enabled: "0"
      }
      environment.reload
      expect([ environment.servers_enabled, environment.uptime_enabled, environment.secrets_enabled ]).to eq([ false, true, false ])
    end

    it "update invalido (code vuoto) → ri-renderizza il form 422" do
      sign_in(owner)
      environment = create(:environment, organization: org, label: "Old")
      patch member_environment_path(environment), params: { code: "", label: "New" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(environment.reload.label).to eq("Old")
    end

    it "edit di una environment di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:environment, organization: create(:organization))
      get edit_member_environment_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "admin elimina una environment inutilizzata" do
      sign_in(owner)
      environment = create(:environment, organization: org)
      expect do
        delete member_environment_path(environment)
      end.to change(Types::Environment, :count).by(-1)
      expect(response).to redirect_to(member_environments_path)
    end

    it "environment in uso → non eliminata (restrict), alert" do
      sign_in(owner)
      environment = create(:environment, organization: org)
      create(:project, organization: org).environments << environment
      expect do
        delete member_environment_path(environment)
      end.not_to change(Types::Environment, :count)
      expect(response).to redirect_to(member_environments_path)
    end
  end

  describe "GET index — filtri" do
    before { sign_in(owner) }

    it "filtra per stato attivo" do
      create(:environment, organization: org, label: "ActiveOne", active: true)
      create(:environment, organization: org, label: "InactiveOne", active: false)
      get member_environments_path, params: { status: [ "true" ] }
      expect(response.body).to include("ActiveOne")
      expect(response.body).not_to include("InactiveOne")
    end

    it "filtra per stato inattivo" do
      create(:environment, organization: org, label: "ActiveOne", active: true)
      create(:environment, organization: org, label: "InactiveOne", active: false)
      get member_environments_path, params: { status: [ "false" ] }
      expect(response.body).to include("InactiveOne")
      expect(response.body).not_to include("ActiveOne")
    end

    it "search per label/code" do
      create(:environment, organization: org, label: "Searchable", code: "srch")
      create(:environment, organization: org, label: "HiddenLabel", code: "hide")
      get member_environments_path, params: { q: "Searchable" }
      expect(response.body).to include("Searchable")
      expect(response.body).not_to include("HiddenLabel")
    end

    it "search senza match → box no-match (filtro azzerabile)" do
      create(:environment, organization: org, label: "Whatever")
      get member_environments_path, params: { q: "zzzznomatch" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("environments-no-match")
    end

    it "param array con blank ignorati (filter_ids)" do
      create(:environment, organization: org, label: "KeepMe", active: true)
      get member_environments_path, params: { status: [ "" ] }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("KeepMe")
    end
  end

  # Explanations live in the guides and in the empty state, never in a box above the table (B7, B10).
  describe "the page without an intro box" do
    it "draws no intro box above the table" do
      sign_in(owner)
      create(:environment, organization: org)

      get member_environments_path

      expect(response.body).not_to include('data-test="environments-intro"')
    end

    it "explains what an environment is in the empty state" do
      sign_in(owner)

      get member_environments_path

      expect(response.body).to include('data-test="environments-empty"')
      expect(response.body).to include(CGI.escapeHTML(I18n.t("member.environments.empty_body")))
    end
  end

  # The primary "Add" sits in the page header, never in the table panel nor in the bar (C61).
  describe "the New button" do
    it "sits once, in the page header and outside the table" do
      sign_in(owner)
      create(:environment, organization: org)

      get member_environments_path

      html = Nokogiri::HTML(response.body)
      expect(html.css("[data-test='environments-new']").size).to eq(1)
      expect(html.at_css("[data-test='environments-new']")["href"]).to eq(new_member_environment_path)
      expect(html.at_css("[data-test='environments-table'] [data-test='environments-new']")).to be_nil
    end
  end

  # Delete asks in a dialog that says what disappears, never in the browser box (F3, F16, C77).
  describe "delete confirmation" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      environment = create(:environment, organization: org, label: "Staging")

      get member_environments_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='environment-delete-dialog-#{environment.id}']")
      expect(dialog.text).to include(I18n.t("member.environments.delete_dialog.title", label: "Staging"))
      expect(dialog.at_css("form")["action"]).to eq(member_environment_path(environment))
      expect(html.at_css("[data-test='environment-delete-#{environment.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end

  # Row actions are visible buttons; only Delete and Archive go in the ⋯ menu (C21).
  describe "row actions" do
    it "shows Edit as a button on the row, outside the ⋯ menu" do
      sign_in(owner)
      environment = create(:environment, organization: org)

      get member_environments_path

      html = Nokogiri::HTML(response.body)
      edit = html.at_css("[data-test='environment-edit-#{environment.id}']")
      expect(edit["href"]).to eq(edit_member_environment_path(environment))
      expect(edit.ancestors("details")).to be_empty
    end
  end
end
