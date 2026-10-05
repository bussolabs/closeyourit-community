# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Service::Accounts", type: :request do
  let(:org) { create(:organization, slug: "acme") }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  describe "autorizzazione" do
    it "non autenticato → redirect login" do
      get member_service_accounts_path
      expect(response).to redirect_to(login_path)
    end

    it "membro senza members.manage → redirect (forbidden)" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      sign_in(member)
      get member_service_accounts_path
      expect(response).to redirect_to(root_path)
    end
  end

  context "come owner (members.manage)" do
    before { sign_in(owner) }

    describe "GET index" do
      it "risponde 200 ed elenca i service account" do
        svc = ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value
        get member_service_accounts_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Deploy Bot")
        expect(response.body).to include(svc.handle)
      end

      # CYRA-924 — every column but the actions sorts (C9).
      it "sorts by name both ways and offers every column" do
        ::Accounts::Service::Create.call(organization: org, name: "Zeta Bot")
        ::Accounts::Service::Create.call(organization: org, name: "alpha Bot")
        get member_service_accounts_path(sort: "name")
        expect(response.body.index("alpha Bot")).to be < response.body.index("Zeta Bot")
        get member_service_accounts_path(sort: "-name")
        expect(response.body.index("Zeta Bot")).to be < response.body.index("alpha Bot")
        %w[name handle secrets tokens].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
      end

      # «Elimina» nudo su ogni riga era l'azione più in vista della tabella: sta nel menu di riga.
      it "l'eliminazione sta nel menu di riga, non come bottone nudo" do
        svc = ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value
        get member_service_accounts_path
        doc = Nokogiri::HTML(response.body)
        menu = doc.at_css(%([data-test="service-account-menu-#{svc.id}"]))
        expect(menu).to be_present
        expect(menu.parent.at_css(%([data-test="service-account-delete-#{svc.id}"]))).to be_present
      end
    end

    describe "GET new" do
      it "risponde 200" do
        get new_member_service_account_path
        expect(response).to have_http_status(:ok)
      end
    end

    describe "POST create" do
      it "crea il service account + membership e reindirizza alla show" do
        expect {
          post member_service_accounts_path, params: { confirm: "1", name: "Deploy Bot" }
        }.to change { org.accounts.service.count }.by(1)

        account = org.accounts.service.order(:created_at).last
        expect(response).to redirect_to(member_service_account_path(account))
        expect(org.memberships.find_by(account: account).role).to eq("member")
      end

      it "con grant_secrets + progetto concede visibilità e override secrets" do
        post member_service_accounts_path, params: { confirm: "1",
          name: "Deploy Bot", project_ids: [ project.id ], grant_secrets: "1"
        }

        account = org.accounts.service.order(:created_at).last
        expect(account.directly_accessible_projects).to include(project)
        expect(account.account_permissions.where(organization: org, permission_key: "secrets.manage", effect: "allow")).to exist
      end

      it "senza nome → 422 e ri-render del form" do
        post member_service_accounts_path, params: { name: "" }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    describe "GET show" do
      it "risponde 200 con nome e handle" do
        account = ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value
        get member_service_account_path(account)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Deploy Bot")
      end

      it "in italiano parla di ambienti, eccezioni e ambito, non di environment, override e scope" do
        owner.update!(locale: "it")
        account = ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value
        get member_service_account_path(account)
        text = Capybara.string(response.body).find("main").text
        expect(text).to include("Ambienti consentiti")
        expect(text).not_to match(/environment|override|\bscope\b/i)
      end
    end

    describe "PATCH update (restrizione environment)" do
      it "imposta i code consentiti sulla membership (solo quelli dell'org)" do
        create(:environment, organization: org, code: "staging")
        account = ::Accounts::Service::Create.call(organization: org, name: "Bot").value
        patch member_service_account_path(account), params: { confirm: "1", secret_environment_codes: [ "staging", "inesistente" ] }

        expect(response).to redirect_to(member_service_account_path(account))
        expect(org.memberships.find_by(account: account).secret_environment_codes).to eq([ "staging" ])
      end
    end

    describe "DELETE destroy (retire audit-safe)" do
      it "rimuove il service account dall'org ma preserva la riga account (audit)" do
        account = ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value
        expect {
          delete member_service_account_path(account), params: { confirm: "1" }
        }.to change { org.accounts.service.count }.by(-1)
        expect(response).to redirect_to(member_service_accounts_path)
        expect(Accounts::Account.exists?(account.id)).to be(true)
      end

      it "preserva l'actor dell'audit dei secret (non lo nullifica)" do
        account = ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value
        event = create(:secret_event, actor: account, organization: org, project: project, action: "read")
        delete member_service_account_path(account)
        expect(event.reload.actor).to eq(account)
      end
    end

    describe "token (reveal-once)" do
      let(:account) { ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value }

      it "POST tokens → 201 e mostra il segreto cyi_u_ UNA volta" do
        expect {
          post member_service_account_tokens_path(account), params: { confirm: "1", name: "ci-deploy" }
        }.to change { account.api_tokens.count }.by(1)

        expect(response).to have_http_status(:created)
        expect(response.body).to include("cyi_u_")
        expect(response.body).to include('data-test="service-account-token-reveal"')
      end

      # CYRA-717 — l'eccezione dichiarata dal ticket: gli account di servizio possono avere codici
      # senza scadenza, perché nessuno può rifare il login al posto loro ogni 90 giorni.
      it "il token di un account di servizio nasce SENZA scadenza" do
        post member_service_account_tokens_path(account), params: { confirm: "1", name: "ci-deploy" }

        expect(account.api_tokens.find_by!(name: "ci-deploy").expires_at).to be_nil
        expect(response.body).to include(I18n.t("member.service_accounts.tokens.no_expiry"))
      end

      it "DELETE token → revoca" do
        secret_token = ::Accounts::ApiTokens::Issue.call(account: account, organization: org, name: "old", expires_at: nil).value[:token]
        delete member_service_account_token_path(account, secret_token), params: { confirm: "1" }
        expect(response).to redirect_to(member_service_account_path(account))
        expect(secret_token.reload).to be_revoked
      end
    end

    describe "anti-BOLA" do
      it "service account di un'altra org → 404" do
        other_org = create(:organization, slug: "beta")
        foreign = ::Accounts::Service::Create.call(organization: other_org, name: "Foreign Bot").value
        get member_service_account_path(foreign)
        expect(response).to have_http_status(:not_found)
      end

      it "un account umano (non service) → 404" do
        human = create(:account)
        create(:membership, account: human, organization: org, role: :member)
        get member_service_account_path(human)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      svc = ::Accounts::Service::Create.call(organization: org, name: "Deploy Bot").value

      get member_service_accounts_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='service-account-delete-dialog-#{svc.id}']")
      expect(dialog.text).to include(I18n.t("member.service_accounts.delete_dialog.title", name: "Deploy Bot"))
      expect(dialog.at_css("form")["action"]).to eq(member_service_account_path(svc))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='service-account-delete-#{svc.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
