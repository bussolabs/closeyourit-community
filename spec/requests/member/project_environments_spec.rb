# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectEnvironments", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Progetto uptime-capable con un environment DICHIARATO e uno NON dichiarato nella stessa org.
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let!(:declared_env) do
    create(:environment, organization: org, code: "production", label: "Production").tap { |e| project.environments << e }
  end
  let!(:undeclared_env) { create(:environment, organization: org, code: "staging", label: "Staging") }

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_project_environments_path(project)
      expect(response).to redirect_to(login_path)
    end

    it "manager → 200 con tabella, tri-state per l'env dichiarato e pulsanti attiva/disattiva" do
      sign_in(owner)
      get member_project_environments_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="project-environments-manage"')
      # Env dichiarato: controlli tri-state (riuso del partial) + pulsante disattiva.
      expect(response.body).to include("env-cap-#{declared_env.id}-servers")
      expect(response.body).to include("env-cap-#{declared_env.id}-uptime")
      expect(response.body).to include("env-cap-#{declared_env.id}-secrets")
      expect(response.body).to include("env-cap-#{declared_env.id}-approval") # CYRA-138: 4a capability
      expect(response.body).to include("project-environment-deactivate-#{declared_env.id}")
      # Env non dichiarato: solo pulsante attiva, niente tri-state.
      expect(response.body).to include("project-environment-activate-#{undeclared_env.id}")
      expect(response.body).not_to include("env-cap-#{undeclared_env.id}-servers")
    end

    it "keeps linked servers inside the Servers cell of the environment (CYRA-883)" do
      sign_in(owner)
      create(:server_host, organization: org, name: "apps-prod")
      get member_project_environments_path(project)

      servers_row = Nokogiri::HTML(response.body).at_css("[data-test='project-environment-cap-#{declared_env.id}-servers']")
      expect(servers_row).to be_present
      expect(servers_row.at_css("[data-test='env-cap-#{declared_env.id}-servers']")).to be_present
      expect(servers_row.at_css("[data-test='project-servers-form-#{declared_env.id}']")).to be_present
    end

    it "opens the server picker in a dialog from a button, not inline in the cell" do
      sign_in(owner)
      create(:server_host, organization: org, name: "apps-prod")
      get member_project_environments_path(project)

      cell = Nokogiri::HTML(response.body).at_css("[data-test='project-environment-cap-#{declared_env.id}-servers']")
      trigger = cell.at_css("[data-test='project-servers-open-#{declared_env.id}']")
      dialog = cell.at_css("dialog[data-test='project-servers-dialog-#{declared_env.id}']")
      expect(trigger["data-action"]).to include("ui--dialog#open")
      expect(dialog.at_css("[data-test='project-servers-form-#{declared_env.id}']")).to be_present
      expect(dialog.at_css("[data-test='project-servers-submit-#{declared_env.id}']")).to be_present
      # F24 — the standard shell: Save sits in the header panel and still submits the form.
      expect(dialog["class"]).to include("dark:bg-zinc-950")
      expect(dialog.at_css("[data-test='project-servers-form-#{declared_env.id}'] header [data-test='project-servers-submit-#{declared_env.id}']")).to be_present
    end

    it "names how many servers are linked on the button" do
      sign_in(owner)
      host = create(:server_host, organization: org, name: "apps-prod")
      project.server_links.create!(environment: declared_env, host:)
      get member_project_environments_path(project)

      trigger = Nokogiri::HTML(response.body).at_css("[data-test='project-servers-open-#{declared_env.id}']")
      expect(trigger.text.squish).to eq(I18n.t("member.projects.environments.servers_open", count: 1))
    end

    it "mostra il multiselect server per l'env dichiarato (progetto uptime-capable, manager)" do
      sign_in(owner)
      host = create(:server_host, organization: org, name: "apps-prod")
      get member_project_environments_path(project)

      expect(response.body).to include("project-servers-form-#{declared_env.id}")
      expect(response.body).to include("project-servers-select-#{declared_env.id}")
      expect(response.body).to include(ERB::Util.html_escape(host.name))
    end

    it "offre l'accesso contestuale alla creazione monitor per un env attivo senza monitor (uptime.manage)" do
      sign_in(owner)
      get member_project_environments_path(project)

      # Il link "aggiungi monitor" punta al form new di Monitoring, pre-filtrato su progetto+environment
      # (i query param nell'href sono HTML-escaped → verifico base path + singoli param, non l'URL intero).
      expect(response.body).to include("project-uptime-add-#{declared_env.id}")
      expect(response.body).to include(new_member_monitoring_monitor_path)
      expect(response.body).to include("environment_id=#{declared_env.id}")
    end

    it "mostra il link al monitor esistente invece di 'aggiungi monitor'" do
      sign_in(owner)
      monitor = create(:uptime_monitor, project:, environment: declared_env)
      get member_project_environments_path(project)

      expect(response.body).to include("project-uptime-view-#{declared_env.id}")
      expect(response.body).to include(member_monitoring_monitor_path(monitor))
      expect(response.body).not_to include("project-uptime-add-#{declared_env.id}")
    end

    it "member senza projects.edit → redirect (gate di gestione)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      get member_project_environments_path(project)

      expect(response).to redirect_to(root_path)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      get member_project_environments_path(foreign)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index — environments in columns, capabilities in rows" do
    let(:doc) { Nokogiri::HTML(response.body) }
    let(:manage) { doc.at_css("[data-test='project-environments-manage']") }

    before { sign_in(owner) }

    it "gives each declared environment a column and each capability a row" do
      get member_project_environments_path(project)

      table = manage.at_css("table[data-test='project-environments-matrix']")
      expect(table.css("thead [data-test^='project-environment-column-']").map { |th| th["data-test"] })
        .to eq([ "project-environment-column-#{declared_env.id}" ])
      expect(table.css("tbody tr").map { |tr| tr["data-test"] })
        .to eq(%w[servers uptime secrets approval].map { |cap| "project-environment-row-#{cap}" })
      expect(table.at_css("[data-test='project-environment-row-servers'] [data-test='project-environment-cap-#{declared_env.id}-servers']"))
        .to be_present
    end

    it "keeps the environment's name, tokens and Deactivate at the head of its column" do
      get member_project_environments_path(project)

      column = manage.at_css("[data-test='project-environment-column-#{declared_env.id}']")
      expect(column.at_css("[data-test='project-environment-tokens-#{declared_env.id}']")).to be_present
      expect(column.at_css("[data-test='project-environment-deactivate-#{declared_env.id}']")).to be_present
    end

    it "lets every cell save its own switch" do
      get member_project_environments_path(project)

      cell = manage.at_css("[data-test='project-environment-cap-#{declared_env.id}-secrets']")
      expect(cell["data-controller"]).to eq("environment-capability")
      expect(cell["data-environment-capability-url-value"])
        .to eq(member_project_environment_capability_path(project, declared_env.id))
    end

    it "shows the inherited value on the Inherit button" do
      declared_env.update!(servers_enabled: true, secrets_enabled: false)
      get member_project_environments_path(project)

      servers = doc.at_css("[data-test='env-cap-#{declared_env.id}-servers-inherit']").text.squish
      secrets = doc.at_css("[data-test='env-cap-#{declared_env.id}-secrets-inherit']").text.squish
      expect(servers).to eq("Inherit · On")
      expect(secrets).to eq("Inherit · Off")
    end

    it "labels the explicit states On and Off in English, not true and false" do
      get member_project_environments_path(project)

      expect(doc.at_css("[data-test='env-cap-#{declared_env.id}-uptime-on']").text.squish).to eq("On")
      expect(doc.at_css("[data-test='env-cap-#{declared_env.id}-uptime-off']").text.squish).to eq("Off")
    end

    it "explains the three states and links to the organization's environment defaults" do
      get member_project_environments_path(project)

      expect(manage.at_css("[data-test='project-environments-legend']")).to be_present
      expect(manage.at_css("a[data-test='project-environments-defaults']")["href"]).to eq(member_environments_path)
    end

    it "does not repeat the tab name as a visible section title" do
      get member_project_environments_path(project)

      heading = manage.at_css("h2")
      expect(heading["class"]).to include("sr-only")
    end

    it "says the organization has no servers instead of offering an empty picker" do
      get member_project_environments_path(project)

      note = doc.at_css("[data-test='project-servers-none-#{declared_env.id}']")
      expect(note).to be_present
      expect(note.at_css("a")["href"]).to eq(member_monitoring_servers_path)
      expect(doc.at_css("[data-test='project-servers-form-#{declared_env.id}']")).to be_nil
    end

    it "shows the active ingest tokens of each environment with a link to the tokens tab" do
      create(:project_token, project:, environment: declared_env)
      create(:project_token, :revoked, project:, environment: declared_env)
      get member_project_environments_path(project)

      tokens = doc.at_css("[data-test='project-environment-tokens-#{declared_env.id}']")
      expect(tokens.text.squish).to include("1")
      expect(tokens.at_css("a")["href"]).to eq(member_project_tokens_path(project))
    end

    it "leaves the monitor's status to Monitoring: the cell only links to the monitor" do
      create(:uptime_monitor, project:, environment: declared_env)
      get member_project_environments_path(project)

      cell = doc.at_css("[data-test='project-environment-cap-#{declared_env.id}-uptime']")
      expect(cell.at_css("[data-test='project-uptime-status-#{declared_env.id}']")).to be_nil
      expect(cell.at_css("[data-test='project-uptime-view-#{declared_env.id}']").text.squish)
        .to eq(I18n.t("member.projects.environments.uptime_view"))
    end

    it "asks for confirmation before deactivating an environment" do
      get member_project_environments_path(project)

      button = doc.at_css("[data-test='project-environment-deactivate-#{declared_env.id}']")
      expect(button["data-turbo-confirm"]).to be_present
    end

    it "gathers inactive environments at the bottom, after the table" do
      get member_project_environments_path(project)

      inactive = manage.at_css("[data-test='project-environments-inactive']")
      expect(inactive.at_css("[data-test='project-environment-activate-#{undeclared_env.id}']")).to be_present
      expect(response.body.index("project-environments-inactive"))
        .to be > response.body.index("project-environments-matrix")
    end

    it "reloads the page after a Servers or Uptime switch, not after Secrets or Approval" do
      get member_project_environments_path(project)

      reload = ->(cap) { doc.at_css("[data-test='env-cap-#{declared_env.id}-#{cap}-on']")["data-environment-capability-reload-param"] }
      expect(reload.call("servers")).to eq("true")
      expect(reload.call("uptime")).to eq("true")
      expect(reload.call("secrets")).to be_nil
      expect(reload.call("approval")).to be_nil
    end

    it "says once that servers need a web/server project" do
      plain = create(:project, organization: org)
      plain.environments << declared_env
      plain.environments << undeclared_env
      get member_project_environments_path(plain)

      expect(doc.css("[data-test='project-servers-unsupported']").size).to eq(1)
    end
  end

  describe "POST create (attiva un environment)" do
    it "dichiara l'environment e redirige alla tab" do
      sign_in(owner)

      expect { post member_project_environments_path(project), params: { environment_id: undeclared_env.id } }
        .to change { project.environments.reload.count }.by(1)
      expect(response).to redirect_to(member_project_environments_path(project))
      expect(project.environments).to include(undeclared_env)
    end

    it "scarta un environment di un'altra org (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:environment, organization: create(:organization))
      post member_project_environments_path(project), params: { environment_id: foreign.id }

      expect(project.environments.reload).not_to include(foreign)
    end

    it "è idempotente: ri-attivare un env già dichiarato non duplica" do
      sign_in(owner)

      expect { post member_project_environments_path(project), params: { environment_id: declared_env.id } }
        .not_to(change { project.environments.reload.count })
    end

    it "member senza projects.edit → redirect, nessuna dichiarazione" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      post member_project_environments_path(project), params: { environment_id: undeclared_env.id }

      expect(response).to redirect_to(root_path)
      expect(project.environments.reload).not_to include(undeclared_env)
    end
  end

  describe "DELETE destroy (disattiva un environment)" do
    it "rimuove la dichiarazione e redirige alla tab" do
      sign_in(owner)

      expect { delete member_project_environment_path(project, declared_env.id) }
        .to change { project.environments.reload.count }.by(-1)
      expect(response).to redirect_to(member_project_environments_path(project))
      expect(project.environments).not_to include(declared_env)
    end

    it "id non dichiarato → no-op (scoped al progetto), redirige senza errori" do
      sign_in(owner)
      delete member_project_environment_path(project, undeclared_env.id)

      expect(response).to redirect_to(member_project_environments_path(project))
    end

    it "member senza projects.edit → redirect, dichiarazione intatta" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      delete member_project_environment_path(project, declared_env.id)

      expect(response).to redirect_to(root_path)
      expect(project.environments.reload).to include(declared_env)
    end
  end
end
