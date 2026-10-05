# frozen_string_literal: true

require "rails_helper"

# CYRA-428, Scenario 1 — chi cerca una chiave non sa se sia stata salvata come testo o come file, e
# non deve sceglierlo da una voce di menu prima ancora di cercare. Variabili e file dello stesso
# livello vivono nella stessa voce, in due schede; e i segreti di progetto si leggono per progetto o
# per variabile, che sono due viste sugli stessi dati.
RSpec.describe "Member — schede del Vault (CYRA-428)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Una scheda è attiva quando è la pagina che stai guardando: `aria-current="page"` è ciò che lo
  # dice a chi naviga con un lettore di schermo, non il solo colore.
  def active_tab(body, test_id)
    body[/<a[^>]*data-test="#{test_id}"[^>]*>/]
  end

  describe "segreti personali" do
    before { sign_in(owner) }

    it "dalle variabili si passa ai file senza cambiare voce di menu" do
      get member_personal_secrets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="personal-tabs"')
      expect(response.body).to include(%(href="#{member_personal_secret_assets_path}"))
      expect(active_tab(response.body, "personal-tab-variables")).to include('aria-current="page"')
    end

    it "sui file è accesa la scheda dei file" do
      get member_personal_secret_assets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="#{member_personal_secrets_path}"))
      expect(active_tab(response.body, "personal-tab-files")).to include('aria-current="page"')
    end
  end

  describe "segreti dell'organizzazione" do
    before { sign_in(owner) }

    it "dalle variabili si passa ai file senza cambiare voce di menu" do
      get member_shared_secrets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="organization-tabs"')
      expect(response.body).to include(%(href="#{member_shared_secret_assets_path}"))
      expect(active_tab(response.body, "organization-tab-variables")).to include('aria-current="page"')
    end

    it "sui file è accesa la scheda dei file" do
      get member_shared_secret_assets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="#{member_shared_secrets_path}"))
      expect(active_tab(response.body, "organization-tab-files")).to include('aria-current="page"')
    end

    # I due permessi sono distinti: chi ha solo i file non deve vedere una scheda che non può aprire.
    it "chi non gestisce le variabili condivise non vede quella scheda" do
      solo_file = create(:account)
      create(:membership, account: solo_file, organization: org, role: :member)
      Authorization::SetAccountPermissions.call(organization: org, account: solo_file,
                                                allow_keys: [ "shared_secret_files.manage" ], actor: owner)

      sign_in(solo_file)
      get member_shared_secret_assets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-test="organization-tab-variables"')
    end
  end

  describe "segreti di progetto" do
    # La lettura per variabile cerca fra i progetti visibili: senza nemmeno un progetto non ci sarebbe
    # nulla da cercare e la scheda non comparirebbe (gate vault_variable_search_nav_visible?).
    before do
      create(:project, organization: org)
      sign_in(owner)
    end

    it "l'elenco per progetto porta alla lettura per variabile" do
      get member_vault_projects_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="vault-projects-tabs"')
      expect(response.body).to include(%(href="#{member_vault_variables_path}"))
      expect(active_tab(response.body, "vault-projects-tab-by-project")).to include('aria-current="page"')
    end

    it "la lettura per variabile è la seconda scheda della stessa voce" do
      get member_vault_variables_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="#{member_vault_projects_path}"))
      expect(active_tab(response.body, "vault-projects-tab-by-variable")).to include('aria-current="page"')
    end
  end
end
