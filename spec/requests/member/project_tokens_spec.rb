# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Projects::Tokens", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }

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
      get member_project_tokens_path(project)
      expect(response).to redirect_to(login_path)
    end

    # CYRA-883 — the tokens live in Settings now; links, guides and old e-mails still land on them.
    it "admin → forwarded to the tokens section of Settings, keeping search, filter, sort and page" do
      sign_in(owner)
      get member_project_tokens_path(project), params: { q: "sdk", status: [ "revoked" ], sort: "-name", page: 2, other: "x" }

      expect(response).to redirect_to(
        member_project_settings_path(project, q: "sdk", status: [ "revoked" ], sort: "-name", page: "2", anchor: "tokens")
      )
    end

    it "membro non assegnato → 404 (non vede il progetto)" do
      sign_in(member)
      get member_project_tokens_path(project)
      expect(response).to have_http_status(:not_found)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      get member_project_tokens_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "admin crea un token e rivela il segreto UNA volta (bearer + project_id)" do
      sign_in(owner)
      env = environment
      expect do
        post member_project_tokens_path(project), params: { confirm: "1", name: "Production SDK", environment_id: env.id }
      end.to change(project.tokens, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.body).to include("token-secret")
      expect(response.body).to include("token-project-id")
      # il segreto in chiaro (cyi_) è presente nel body della creazione
      expect(response.body).to match(/cyi_[A-Za-z0-9]+/)
      token = project.tokens.last
      expect(token.environment).to eq(env)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-test='token-sentry-dsn']").text)
        .to eq(token.to_sentry_dsn(host: request.host))
    end

    it "il segreto NON è recuperabile nella index successiva (reveal-once)" do
      sign_in(owner)
      post member_project_tokens_path(project), params: { name: "SDK", environment_id: environment.id }
      get member_project_settings_path(project)
      expect(response.body).not_to match(/cyi_[A-Za-z0-9]{20,}/)
    end

    # CYRA-716 — la scadenza si sceglie alla creazione ed è facoltativa.
    it "con la data di scadenza il token nasce a termine e la pagina la mostra" do
      sign_in(owner)
      env = environment
      post member_project_tokens_path(project),
           params: { confirm: "1", name: "SDK a termine", environment_id: env.id, expires_at: 30.days.from_now.to_date.to_s }

      expect(response).to have_http_status(:created)
      expect(project.tokens.last.expires_at).to be_present
      expect(response.body).to include("token-expiry")
    end

    it "senza data di scadenza il token resta senza scadenza (nessuna imposta d'ufficio)" do
      sign_in(owner)
      post member_project_tokens_path(project), params: { confirm: "1", name: "SDK", environment_id: environment.id }

      expect(project.tokens.last.expires_at).to be_nil
    end

    it "data di scadenza nel passato → 422, nessun token" do
      sign_in(owner)
      env = environment
      expect do
        post member_project_tokens_path(project),
             params: { name: "SDK", environment_id: env.id, expires_at: 1.day.ago.to_date.to_s }
      end.not_to change(project.tokens, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "name vuoto → 422, nessun token" do
      sign_in(owner)
      env = environment
      expect do
        post member_project_tokens_path(project), params: { name: "", environment_id: env.id }
      end.not_to change(project.tokens, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    # CYRA-883 — the form sits behind a disclosure; after an error it must reopen with the message.
    it "after an error the settings page comes back with the token form open" do
      sign_in(owner)
      post member_project_tokens_path(project), params: { confirm: "1", name: "", environment_id: environment.id }

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='member-project-settings']")).to be_present
      expect(doc.at_css("details[data-test='token-form-disclosure']")["open"]).not_to be_nil
    end

    it "environment non dichiarato dal progetto → 422, nessun token" do
      sign_in(owner)
      undeclared = create(:environment, organization: org)
      expect do
        post member_project_tokens_path(project), params: { name: "SDK", environment_id: undeclared.id }
      end.not_to change(project.tokens, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "membro non assegnato → 404, niente creato" do
      sign_in(member)
      env = environment
      expect do
        post member_project_tokens_path(project), params: { name: "SDK", environment_id: env.id }
      end.not_to change(project.tokens, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "admin revoca un token attivo" do
      sign_in(owner)
      token = Projects::Tokens::Issue.call(
        project:, name: "SDK", host: "bugs.example.com", environment:
      ).value[:token]

      delete member_project_token_path(project, token), params: { confirm: "1" }

      expect(token.reload).to be_revoked
      expect(response).to redirect_to(member_project_settings_path(project, anchor: "tokens"))
    end

    it "token di un progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      foreign_env = create(:environment, organization: foreign.organization).tap { |e| foreign.environments << e }
      foreign_token = Projects::Tokens::Issue.call(
        project: foreign, name: "X", host: "x", environment: foreign_env
      ).value[:token]

      delete member_project_token_path(foreign, foreign_token)
      expect(response).to have_http_status(:not_found)
    end
  end
end
