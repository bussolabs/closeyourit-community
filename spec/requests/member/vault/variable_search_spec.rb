# frozen_string_literal: true

require "rails_helper"

# Ricerca cross-progetto delle variabili segrete per NOME (CYRA-137, poi CYRA-424): risponde a
# "dove è (e dove MANCA) VAR_X" tra i progetti VISIBILI dell'utente. Gate = sola visibilità progetti
# (visible.projects, anti-BOLA) — NESSUN permesso secrets.read: non si espone alcun valore,
# solo la presenza del nome in [progetto, ambiente]. Ogni risultato è una MATRICE progetto × ambiente
# (presenze + assenze), porta DIRITTO alla variabile nella tabella dei segreti, ed è filtrabile,
# ordinabile e paginato.
RSpec.describe "Member::Vault::VariableSearch", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project_a) { create(:project, organization: org, name: "Progetto Alfa") }
  let(:project_b) { create(:project, organization: org, name: "Progetto Beta") }
  let(:production) { create(:environment, organization: org, code: "production", label: "Produzione", position: 0) }
  let(:staging) { create(:environment, organization: org, code: "staging", label: "Staging", position: 1) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "trova una delega con l'alias senza esporre valori o progetti non assegnati" do
      project_a.environments << production
      project_b.environments << production
      create(:project_membership, account: member, project: project_a)
      shared = Secrets::Shared::Save.call(organization: org, environment: production,
                                          name: "ORG_ENDPOINT", value: "valore-riservato-di-prova",
                                          enqueue_sync: false).value
      shared.delegations.create!(project: project_a, local_name: "APP_ENDPOINT")
      shared.delegations.create!(project: project_b, local_name: "APP_ENDPOINT")
      sign_in(member)

      get member_vault_variables_path(q: "app_endpoint")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("APP_ENDPOINT", "Progetto Alfa")
      expect(response.body).not_to include("ORG_ENDPOINT", "Progetto Beta", "valore-riservato-di-prova")
    end

    it "non autenticato → redirect login" do
      get member_vault_variables_path(q: "DATABASE")

      expect(response).to redirect_to(login_path)
    end

    it "owner → cerca DATABASE e trova le variabili il cui nome la contiene (case-insensitive), con progetto e ambiente" do
      project_a.environments << production
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "database_url")
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "OTHER_VAR")
      sign_in(owner)

      get member_vault_variables_path(q: "database")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("DATABASE_URL")
      expect(response.body).to include("Progetto Alfa")
      expect(response.body).to include("Produzione")
      expect(response.body).not_to include("OTHER_VAR")
    end

    it "anti-BOLA: un membro assegnato solo al progetto A non trova una variabile omonima nel progetto B non assegnato" do
      project_a.environments << production
      project_b.environments << staging
      create(:project_membership, account: member, project: project_a)
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "SHARED_NAME")
      create(:secret_variable, project: project_b, environment: staging, organization: org, name: "SHARED_NAME")
      sign_in(member)

      get member_vault_variables_path(q: "SHARED_NAME")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Progetto Alfa")
      expect(response.body).not_to include("Progetto Beta")
    end

    it "non mostra mai il valore del secret nel body" do
      project_a.environments << production
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "LEAKY_VAR", value: "s3cr3t-LEAK")
      sign_in(owner)

      get member_vault_variables_path(q: "LEAKY")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("s3cr3t-LEAK")
    end

    it "query vuota → 200 con lo stato vuoto 'cerca una variabile'" do
      project_a.environments << production
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "SOMEVAR")
      sign_in(owner)

      get member_vault_variables_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.vault_variables.empty_query"))
      expect(response.body).not_to include(I18n.t("member.vault_variables.no_match"))
    end

    it "query senza match → 200 con lo stato vuoto 'nessuna variabile trovata'" do
      project_a.environments << production
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "SOMEVAR")
      sign_in(owner)

      get member_vault_variables_path(q: "NOPE_NOTHING_HERE")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.vault_variables.no_match"))
    end
  end

  # Scenario 1 — dal risultato si arriva DIRITTO alla variabile nella tabella dei segreti del progetto,
  # non più alla scheda generale del progetto.
  describe "GET index — il risultato porta alla variabile (Scenario 1)" do
    it "il link punta ai segreti del progetto con la variabile da evidenziare" do
      project_a.environments << production
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE")

      link = Nokogiri::HTML(response.body).at_css('[data-test="vault-variables-open"]')
      expect(link).to be_present
      expect(link["href"]).to start_with(member_project_secrets_path(project_a))
      expect(link["href"]).to include("highlight=DATABASE_URL")
    end

    it "non punta più alla scheda generale del progetto" do
      project_a.environments << production
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE")

      link = Nokogiri::HTML(response.body).at_css('[data-test="vault-variables-open"]')
      expect(link["href"]).not_to eq(member_project_path(project_a))
    end
  end

  # Scenario 2 — la riga mostra tutti gli ambienti attivi del progetto, con le assenze segnate.
  describe "GET index — mostra dove manca (Scenario 2)" do
    it "segna assente l'ambiente in cui la variabile non è definita" do
      project_a.environments << production
      project_a.environments << staging
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE")

      doc = Nokogiri::HTML(response.body)
      present = doc.css('[data-test="vault-variables-cell"][data-state="present"]').map(&:text).join
      absent = doc.css('[data-test="vault-variables-cell"][data-state="absent"]').map(&:text).join
      expect(present).to include("Produzione")
      expect(absent).to include("Staging")
    end

    it "conta le assenze nell'header" do
      project_a.environments << production
      project_a.environments << staging
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE")

      expect(response.body).to include('data-test="vault-variables-stat-absences"')
    end
  end

  describe "GET index — filtri" do
    it "filtro progetto: mostra solo i risultati del progetto scelto" do
      project_a.environments << production
      project_b.environments << production
      # Fixture bulk: la validazione capability del model interroga l'ambiente per-record — non è un
      # N+1 di produzione (la richiesta sotto test è coperta dallo scan Prosopite fuori da questo blocco).
      allow_n_plus_one do
        create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
        create(:secret_variable, project: project_b, environment: production, organization: org, name: "DATABASE_URL")
      end
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE", project: project_a.id)

      # Sui BLOCCHI risultato (data-project), non sull'intero body: "Progetto Beta" resta come opzione
      # della tendina filtro progetto, ma non deve comparire tra i risultati.
      results = Nokogiri::HTML(response.body).css('[data-test="vault-variables-row"]').map { |r| r["data-project"] }
      expect(results).to eq([ project_a.id ])
    end

    it "filtro ambiente: esclude i progetti che non hanno quell'ambiente attivo" do
      project_a.environments << production
      project_b.environments << staging
      allow_n_plus_one do # fixture bulk: validazione capability per-record, non N+1 di produzione
        create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
        create(:secret_variable, project: project_b, environment: staging, organization: org, name: "DATABASE_URL")
      end
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE", environment: "production")

      results = Nokogiri::HTML(response.body).css('[data-test="vault-variables-row"]').map { |r| r["data-project"] }
      expect(results).to eq([ project_a.id ])
    end
  end

  describe "GET index — ordinamento per occorrenze" do
    it "mette prima il progetto con più presenze, anche contro l'ordine alfabetico" do
      project_a.environments << production
      project_b.environments << production
      project_b.environments << staging
      allow_n_plus_one do # fixture bulk: validazione capability per-record, non N+1 di produzione
        create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
        create(:secret_variable, project: project_b, environment: production, organization: org, name: "DATABASE_URL")
        create(:secret_variable, project: project_b, environment: staging, organization: org, name: "DATABASE_URL")
      end
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE", sort: "occurrences")

      # Ordine dei BLOCCHI risultato (data-project): Beta (2 presenze) prima di Alfa (1), contro l'alfabetico.
      results = Nokogiri::HTML(response.body).css('[data-test="vault-variables-row"]').map { |r| r["data-project"] }
      expect(results.index(project_b.id)).to be < results.index(project_a.id)
    end
  end

  describe "GET index — paginazione" do
    it "impagina i risultati e mostra il controllo di paginazione" do
      project_a.environments << production
      allow_n_plus_one { 12.times { |i| create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_VAR_#{i}") } } # fixture bulk: validazione capability per-record, non N+1 di produzione
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE", per: 10, page: 1)

      doc = Nokogiri::HTML(response.body)
      expect(doc.css('[data-test="vault-variables-row"]').size).to eq(10)
      expect(doc.at_css('[data-test="vault-variables-pagination"]')).to be_present
    end

    it "pagina 2 mostra le righe restanti" do
      project_a.environments << production
      allow_n_plus_one { 12.times { |i| create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_VAR_#{i}") } } # fixture bulk: validazione capability per-record, non N+1 di produzione
      sign_in(owner)

      get member_vault_variables_path(q: "DATABASE", per: 10, page: 2)

      expect(Nokogiri::HTML(response.body).css('[data-test="vault-variables-row"]').size).to eq(2)
    end
  end

  # CYRA-422 — «mostra dove esiste, mai il valore» ora è nel corpo, non più solo nel tooltip del titolo.
  describe "GET index — testo nel corpo (CYRA-422)" do
    it "porta la spiegazione nel corpo della pagina" do
      sign_in(owner)
      get member_vault_variables_path

      expect(response.body).to include('data-test="vault-variables-help"')
      expect(response.body).to include(I18n.t("member.vault_variables.help_title"))
    end
  end
end
