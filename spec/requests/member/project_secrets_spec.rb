# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectSecrets", type: :request do
  let(:org) { create(:organization) }
  # Gli attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune li faceva pagare tutti a tutti.
  let(:owner) { account_with_membership(:owner) }
  let(:member) { account_with_membership(:member) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }
  let(:staging) { create(:environment, organization: org, code: "staging").tap { |e| project.environments << e } }

  def account_with_membership(role)
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: role) }
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "unisce una delega e una variabile locale omonima distinguendo le origini senza falsi buchi" do
      shared = Secrets::Shared::Save.call(organization: org, environment:, name: "ORG_ENDPOINT",
                                          value: "valore-condiviso-di-prova", enqueue_sync: false).value
      shared.delegations.create!(project:, local_name: "APP_ENDPOINT")
      create(:secret_variable, project:, organization: org, environment: staging, name: "APP_ENDPOINT")
      sign_in(owner)

      get member_project_secrets_path(project)

      document = Nokogiri::HTML(response.body)
      expect(response).to have_http_status(:ok)
      expect(document.css("#secret-app_endpoint").size).to eq(1)
      expect(document.css("#secret-app_endpoint [data-test='secret-cell-shared-production']").size).to eq(1)
      expect(document.css("#secret-app_endpoint [data-test='secret-cell-local']").size).to eq(1)
      expect(document.css("#secret-app_endpoint textarea[name='values[#{environment.id}]']")).to be_empty
      expect(document.css("#secret-app_endpoint [data-test='secret-cell-drift']")).to be_empty
      expect(response.body).not_to include("valore-condiviso-di-prova")
    end

    it "filtra per nome effettivo e origine senza esporre valori" do
      shared = Secrets::Shared::Save.call(organization: org, environment:, name: "ORG_ENDPOINT",
                                          value: "valore-condiviso-di-prova", enqueue_sync: false).value
      shared.delegations.create!(project:, local_name: "APP_ENDPOINT")
      create(:secret_variable, project:, organization: org, environment:, name: "LOCAL_ONLY")
      sign_in(owner)

      get member_project_secrets_path(project, q: "app_", origin: "shared")

      document = Nokogiri::HTML(response.body)
      expect(response).to have_http_status(:ok)
      expect(document.css("#secret-app_endpoint").size).to eq(1)
      expect(document.css("#secret-local_only")).to be_empty
      expect(document.css("#secret-app_endpoint [data-test^='secret-edit-']")).to be_empty
      expect(response.body).not_to include("valore-condiviso-di-prova")

      get member_project_secrets_path(project, origin: "local")
      expect(Nokogiri::HTML(response.body).css("#secret-app_endpoint")).to be_empty
      expect(Nokogiri::HTML(response.body).css("#secret-local_only").size).to eq(1)
    end

    it "non autenticato → redirect login" do
      get member_project_secrets_path(project)
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200" do
      sign_in(owner)
      get member_project_secrets_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "membro che vede il progetto ma senza secrets.read → redirect (forbidden)" do
      create(:project_membership, account: member, project:)
      sign_in(member)
      get member_project_secrets_path(project)
      expect(response).to redirect_to(root_path)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project)
      sign_in(owner)
      get member_project_secrets_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-777 — «questo valore ce l'hanno anche altri progetti». Il banner e il segnalino sulla cella
  # li vede solo chi può accettare la proposta: agli altri sarebbe un avviso senza rimedio, e per
  # giunta racconterebbe qualcosa dei segreti di progetti che quella persona magari non vede.
  describe "banner «valore in comune»" do
    let(:altro) { create(:project, organization: org).tap { |p| p.environments << environment } }

    def proposta
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "valore-condiviso-lungo")
      Secrets::Variables::Set.call(project: altro, environment:, name: "CHIAVE_API", value: "valore-condiviso-lungo")
      Secrets::Consolidation::Refresh.call(organization: org)
      Secrets::Consolidation::Suggestion.last
    end

    it "compare per chi tiene i secret dell'organizzazione, con il segnalino sulla cella" do
      suggestion = proposta
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include("secrets-consolidation-banner")
      expect(response.body).to include("secret-cell-consolidation")
      expect(response.body).to include(member_vault_consolidation_path(suggestion))
    end

    it "segnala una proposta che perderebbe alias anche quando i nomi multipli sono in un altro progetto" do
      proposta
      create(:secret_variable, project: altro, organization: org, environment:, name: "SECOND_API_KEY", value: "valore-condiviso-lungo")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="secrets-consolidation-alias-conflict"')
      expect(response.body).to include(I18n.t("member.secrets.origins.alias_conflict_body"))
    end

    it "non nomina mai gli altri progetti né il valore" do
      proposta
      altro.update!(name: "progetto-gemello")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include("progetto-gemello", "valore-condiviso-lungo")
    end

    it "non compare a chi non può accettare la proposta" do
      proposta
      create(:project_membership, account: member, project:)
      Authorization::SetAccountPermissions.call(organization: org, account: member,
                                                allow_keys: [ "secrets.read" ], actor: owner)
      sign_in(member)

      get member_project_secrets_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("secrets-consolidation-banner")
      expect(response.body).not_to include("secret-cell-consolidation")
    end
  end

  # CYRA-424 — arrivando dalla ricerca variabili (/member/vault/variables) la riga cercata va
  # evidenziata: ?highlight=NOME segna la riga (id-ancora #secret-<slug> per lo scroll), mai un valore.
  describe "GET index — evidenzia la variabile in arrivo dalla ricerca (CYRA-424)" do
    it "evidenzia la riga della variabile passata in ?highlight=" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      sign_in(owner)

      get member_project_secrets_path(project, highlight: "API_KEY")

      expect(response).to have_http_status(:ok)
      row = Nokogiri::HTML(response.body).at_css('[data-test="secret-row-highlighted"]')
      expect(row).to be_present
      expect(row["id"]).to eq("secret-api_key")
    end

    it "confronto case-insensitive: ?highlight=api_key evidenzia comunque API_KEY" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      sign_in(owner)

      get member_project_secrets_path(project, highlight: "api_key")

      expect(Nokogiri::HTML(response.body).at_css('[data-test="secret-row-highlighted"]')).to be_present
    end

    it "senza highlight nessuna riga è evidenziata" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(Nokogiri::HTML(response.body).at_css('[data-test="secret-row-highlighted"]')).to be_nil
    end
  end

  # CYRA-202 — il valore in chiaro NON deve mai finire nel corpo HTML della pagina: il mascheramento
  # non può essere solo client-side (chi apre il sorgente lo leggerebbe senza sbloccare né lasciare
  # traccia). Il valore si recupera solo via endpoint dedicato (GET reveal), che registra l'accesso.
  describe "GET index — nessun valore di secret nel corpo (CYRA-202)" do
    it "il valore in chiaro non compare da nessuna parte nella risposta" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "PLAINTEXT-CANARY-42")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("PLAINTEXT-CANARY-42")
    end

    it "il textarea di editing è reso vuoto (popolato solo allo sblocco, via endpoint)" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "another-secret").value
      sign_in(owner)

      get member_project_secrets_path(project)

      textarea = Nokogiri::HTML(response.body).at_css(%(textarea[data-test="secret-input-#{variable.id}"]))
      expect(textarea).to be_present
      expect(textarea.text).to eq("")
    end
  end

  describe "GET reveal (CYRA-202)" do
    it "owner → restituisce il valore in chiaro in JSON e registra l'accesso (audit read)" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "s3cr3t-plain").value
      sign_in(owner)

      expect do
        get reveal_member_project_secret_path(project, variable)
      end.to change {
        project.secret_events.where(action: "read", environment:, name: "API_KEY").count
      }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("s3cr3t-plain")
      # Il valore in chiaro non deve persistere nella cache HTTP del browser.
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "membro che vede il progetto ma senza secrets.read → redirect (forbidden), nessun valore esposto" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "s3cr3t-plain").value
      create(:project_membership, account: member, project:)
      sign_in(member)

      get reveal_member_project_secret_path(project, variable)

      expect(response).to redirect_to(root_path)
      expect(response.body).not_to include("s3cr3t-plain")
    end

    it "secret di un altro progetto → 404 (anti-BOLA)" do
      other_project = create(:project, organization: org)
      other_env = create(:environment, organization: org, code: "other").tap { |e| other_project.environments << e }
      foreign = Secrets::Variables::Set.call(project: other_project, environment: other_env, name: "API_KEY", value: "leak").value
      sign_in(owner)

      get reveal_member_project_secret_path(project, foreign)

      expect(response).to have_http_status(:not_found)
    end

    it "progetto non visibile (altra org) → 404 (anti-BOLA)" do
      sign_in(owner)
      get reveal_member_project_secret_path(create(:project), SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index — drift cross-ambiente (CYRA-137)" do
    it "variabile presente in un solo ambiente su due → evidenzia la cella mancante e mostra la chip" do
      staging
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include('data-test="secret-cell-drift"')
      expect(response.body).to include('data-test="secrets-drift-count"')
    end

    it "variabile completa su tutti gli ambienti attivi → nessuna evidenziazione né chip" do
      Secrets::Variables::Set.call(project:, environment:, name: "COMPLETE", value: "p")
      Secrets::Variables::Set.call(project:, environment: staging, name: "COMPLETE", value: "s")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include('data-test="secret-cell-drift"')
      expect(response.body).not_to include('data-test="secrets-drift-count"')
    end

    it "nessun secret locale in matrice → nessuna evidenziazione né chip" do
      staging
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include('data-test="secret-cell-drift"')
      expect(response.body).not_to include('data-test="secrets-drift-count"')
    end

    it "un secret delegato dallo shared non genera drift (resta fuori dal diff)" do
      staging
      shared = Secrets::Shared::Save.call(organization: org, environment:, name: "DELEGATED", value: "v").value
      Secrets::Shared::Delegate.call(shared_value: shared, project:)
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include('data-test="secret-cell-drift"')
      expect(response.body).not_to include('data-test="secrets-drift-count"')
    end

    it "cella con capability secrets disabilitata ma con buco resta evidenziata" do
      off_environment = create(:environment, organization: org, code: "preview", secrets_enabled: false)
        .tap { |e| project.environments << e }
      Secrets::Variables::Set.call(project:, environment:, name: "ONLY_PROD", value: "v")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include('data-test="secret-cell-drift"')
      expect(off_environment.secrets_enabled?).to be(false)
    end
  end

  describe "GET index — voce di menu «Copia in un ambiente» (CYRA-137)" do
    it "progetto con un solo ambiente attivo → la voce di copia non compare (non c'è un altro ambiente)" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include("secret-promote-#{variable.id}")
    end

    it "almeno due ambienti attivi → la voce compare e il valore resta mascherato nel dialog (mai in chiaro)" do
      staging
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "s3cr3t-plain").value
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include("secret-promote-#{variable.id}")
      # CYRA-202: il valore in chiaro non vive più da nessuna parte nel sorgente (né cella né dialog).
      expect(response.body).not_to include("s3cr3t-plain")
      dialog = Nokogiri::HTML(response.body).at_css(%(dialog[data-test="secret-promote-modal-#{variable.id}"]))
      expect(dialog).to be_present
      expect(dialog.to_html).not_to include("s3cr3t-plain")
      expect(dialog.text).to include(I18n.t("member.secrets.masked"))
    end
  end

  describe "POST create (riga della matrice: name + values per ambiente)" do
    it "owner → crea una cella per ogni ambiente valorizzato e reindirizza" do
      sign_in(owner)
      # N celle = N secret distinti, ognuno col proprio snapshot di versione (MAX(number) per
      # secret_variable_id diverso): query per-record indipendenti, non un N+1 di caricamento associazione.
      expect do
        allow_n_plus_one do
          post member_project_secrets_path(project),
               params: { confirm: "1", name: "DATABASE_URL", values: { environment.id.to_s => "postgres://p", staging.id.to_s => "postgres://s" } }
        end
      end.to change { project.secret_variables.count }.by(2)
      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(project.secret_variables.find_by(environment:, name: "DATABASE_URL").value).to eq("postgres://p")
      expect(project.secret_variables.find_by(environment: staging, name: "DATABASE_URL").value).to eq("postgres://s")
    end

    it "owner → fa upsert delle celle esistenti senza duplicarle" do
      Secrets::Variables::Set.call(project:, environment:, name: "TOKEN", value: "old")
      sign_in(owner)
      expect do
        post member_project_secrets_path(project), params: { confirm: "1", name: "TOKEN", values: { environment.id.to_s => "new" } }
      end.not_to change { project.secret_variables.count }
      expect(project.secret_variables.find_by(environment:, name: "TOKEN").value).to eq("new")
    end

    it "owner → salta le celle vuote (svuotare non cancella)" do
      staging
      sign_in(owner)
      expect do
        post member_project_secrets_path(project),
             params: { confirm: "1", name: "API_KEY", values: { environment.id.to_s => "only-prod", staging.id.to_s => "" } }
      end.to change { project.secret_variables.count }.by(1)
      expect(project.secret_variables.exists?(environment: staging, name: "API_KEY")).to be(false)
    end

    it "owner → ignora un env_id estraneo nei params (sicurezza subset)" do
      foreign = create(:environment, organization: org, code: "foreign") # NON dichiarato dal progetto
      sign_in(owner)
      expect do
        post member_project_secrets_path(project),
             params: { confirm: "1", name: "SCOPED", values: { environment.id.to_s => "ok", foreign.id.to_s => "leak" } }
      end.to change { project.secret_variables.count }.by(1)
      expect(Secrets::Variable.exists?(environment: foreign, name: "SCOPED")).to be(false)
    end

    it "owner con nome invalido (prefisso GITHUB_) → 422 e non crea nulla" do
      sign_in(owner)
      post member_project_secrets_path(project), params: { name: "GITHUB_TOKEN", values: { environment.id.to_s => "v" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.secret_variables.count).to eq(0)
    end

    it "owner con nome VUOTO → 422 e la riga-crea resta visibile con l'errore (non ri-nascosta)" do
      sign_in(owner)
      post member_project_secrets_path(project), params: { confirm: "1", name: "", values: { environment.id.to_s => "v" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.secret_variables.count).to eq(0)
      # @open_row è vuoto: l'errore va comunque attribuito alla riga-crea, che deve mostrarlo
      # (data-test reso solo con errors presente) invece di tornare hidden.
      expect(response.body).to include("secret-new-error")
      # CYRA-924 — C65: the new-secret dialog reopens on its own with the error.
      dialog_holder = Nokogiri::HTML(response.body).at_css("[data-test='secret-new-dialog']").parent
      expect(dialog_holder["data-ui--dialog-open-value"]).to eq("true")
    end

    # CYRA-924 — C64: a failed save of an existing row reopens that row's dialog with the error.
    it "reopens the row's dialog with the error when saving an existing row fails" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      allow(Secrets::Rows::Save).to receive(:call)
        .and_return(Result.err(AppError.new("Broken value", code: "R422-TEST-001")))
      sign_in(owner)
      post member_project_secrets_path(project), params: { confirm: "1", name: "API_KEY", values: { environment.id.to_s => "x" } }
      expect(response).to have_http_status(:unprocessable_content)
      row = Nokogiri::HTML(response.body).at_css("#secret-api_key")
      expect(row["data-secret-row-open-value"]).to eq("true")
      expect(row.at_css("[data-test='secret-dialog-api_key'] [data-test='secret-row-error-api_key']").text).to include("Broken value")
    end

    it "membro senza secrets.manage → redirect (forbidden)" do
      create(:project_membership, account: member, project:)
      sign_in(member)
      post member_project_secrets_path(project), params: { name: "X", values: { environment.id.to_s => "v" } }
      expect(response).to redirect_to(root_path)
      expect(project.secret_variables.count).to eq(0)
    end
  end

  describe "POST create — riga con un ambiente protetto dall'approvazione a due (CYRA-138 C1b)" do
    before do
      staging # forza la creazione della riga join (declared) prima di proteggerla
      project.update!(secret_approval_enabled: true)
      project.project_environments.find_by!(environment: staging).update!(approval_required: true)
    end

    it "owner → la cella libera è salvata subito, la cella protetta diventa una change request pending; il notice riflette entrambe" do
      sign_in(owner)

      # 2 celle = 2 query indipendenti Secrets::Approval.required? (una per environment_id), stessa
      # categoria già tollerata sopra per "crea una cella per ogni ambiente" (query per-record, non un
      # N+1 di caricamento associazione).
      expect do
        allow_n_plus_one do
          post member_project_secrets_path(project),
               params: { confirm: "1", name: "MIXED", values: { environment.id.to_s => "free-value", staging.id.to_s => "protected-value" } }
        end
      end.to change { project.secret_variables.count }.by(1).and change(Secrets::ChangeRequest, :count).by(1)

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(project.secret_variables.find_by(environment:, name: "MIXED").value).to eq("free-value")
      expect(project.secret_variables.exists?(environment: staging, name: "MIXED")).to be(false)
      expect(flash[:notice]).to eq(I18n.t("member.secrets.saved_with_pending", applied: 1, pending: 1))
    end

    it "owner → riga interamente sull'ambiente protetto: nessuna variabile scritta, notice 0 salvate / 1 in attesa" do
      sign_in(owner)

      expect do
        post member_project_secrets_path(project), params: { confirm: "1", name: "ONLY_PROTECTED", values: { staging.id.to_s => "v" } }
      end.to change(Secrets::ChangeRequest, :count).by(1)

      expect(project.secret_variables.exists?(name: "ONLY_PROTECTED")).to be(false)
      expect(flash[:notice]).to eq(I18n.t("member.secrets.saved_with_pending", applied: 0, pending: 1))
    end
  end

  describe "DELETE destroy" do
    it "owner → elimina e reindirizza" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      sign_in(owner)
      delete member_project_secret_path(project, variable), params: { confirm: "1" }
      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(Secrets::Variable.exists?(variable.id)).to be(false)
    end
  end

  describe "DELETE destroy — ambiente protetto dall'approvazione a due (CYRA-138 C1b)" do
    before do
      environment # forza la creazione della riga join (declared) prima di proteggerla
      project.update!(secret_approval_enabled: true)
      project.project_environments.find_by!(environment:).update!(approval_required: true)
    end

    it "owner → NON elimina, crea una change request pending e mostra il notice di attesa" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      sign_in(owner)

      expect do
        delete member_project_secret_path(project, variable), params: { confirm: "1" }
      end.to change(Secrets::ChangeRequest, :count).by(1)

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(Secrets::Variable.exists?(variable.id)).to be(true)
      expect(flash[:notice]).to eq(I18n.t("member.secrets.pending_approval", name: "API_KEY"))

      change_request = Secrets::ChangeRequest.last
      expect(change_request).to be_remove
      expect(change_request.environment).to eq(environment)
    end
  end

  describe "POST promote (copia di un secret in un altro ambiente, CYRA-137)" do
    def secret_in(env, value: "prod-value")
      Secrets::Variables::Set.call(project:, environment: env, name: "API_KEY", value: value).value
    end

    it "owner → copia il valore sorgente creando la variabile nell'ambiente target" do
      variable = secret_in(environment)
      sign_in(owner)

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: staging.id }
      end.to change { project.secret_variables.count }.by(1)

      expect(response).to redirect_to(member_project_secrets_path(project))
      copied = project.secret_variables.find_by(environment: staging, name: "API_KEY")
      expect(copied.value).to eq("prod-value")
    end

    it "target con valore già esistente → viene sovrascritto (nessuna riga nuova)" do
      variable = secret_in(environment)
      secret_in(staging, value: "old-staging-value")
      sign_in(owner)

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: staging.id }
      end.not_to change { project.secret_variables.count }

      expect(project.secret_variables.find_by(environment: staging, name: "API_KEY").value).to eq("prod-value")
    end

    it "registra l'evento audit 'set' per la copia" do
      variable = secret_in(environment)
      sign_in(owner)

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: staging.id }
      end.to change {
        project.secret_events.where(action: "set", environment: staging, name: "API_KEY").count
      }.by(1)
    end

    it "membro senza secrets.manage → redirect (forbidden), nulla viene copiato" do
      variable = secret_in(environment)
      create(:project_membership, account: member, project:)
      sign_in(member)

      expect do
        post promote_member_project_secret_path(project, variable), params: { target_environment_id: staging.id }
      end.not_to change { project.secret_variables.count }

      expect(response).to redirect_to(root_path)
      expect(project.secret_variables.exists?(environment: staging, name: "API_KEY")).to be(false)
    end

    it "progetto non visibile (altra org) → 404 (anti-BOLA)" do
      other_project = create(:project)
      sign_in(owner)

      post promote_member_project_secret_path(other_project, SecureRandom.uuid),
           params: { target_environment_id: SecureRandom.uuid }

      expect(response).to have_http_status(:not_found)
    end

    it "ambiente target non dichiarato dal progetto → rifiutato (non 500), nulla viene copiato" do
      variable = secret_in(environment)
      foreign = create(:environment, organization: org, code: "foreign") # NON dichiarato dal progetto
      sign_in(owner)

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: foreign.id }
      end.not_to change { project.secret_variables.count }

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(Secrets::Variable.exists?(environment: foreign, name: "API_KEY")).to be(false)
    end

    it "ambiente target disattivato → rifiutato (non 500), nulla viene copiato" do
      variable = secret_in(environment)
      inactive = create(:environment, organization: org, code: "inactive", active: false)
        .tap { |e| project.environments << e }
      sign_in(owner)

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: inactive.id }
      end.not_to change { project.secret_variables.count }

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(Secrets::Variable.exists?(environment: inactive, name: "API_KEY")).to be(false)
    end

    it "ambiente target con capability secrets disabilitata (creazione nuova) → errore gestito (non 500)" do
      variable = secret_in(environment)
      disabled = create(:environment, :secrets_off, organization: org, code: "no_secrets")
        .tap { |e| project.environments << e }
      sign_in(owner)

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: disabled.id }
      end.not_to change { project.secret_variables.count }

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(Secrets::Variable.exists?(environment: disabled, name: "API_KEY")).to be(false)
    end

    it "ambiente target uguale al sorgente → rifiutato con errore chiaro, nessuna copia inutile" do
      variable = secret_in(environment)
      sign_in(owner)

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: environment.id }
      end.not_to change { project.secret_variables.count }

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(variable.reload.value).to eq("prod-value")
    end

    describe "ambiente target protetto dall'approvazione a due (CYRA-138 C1b)" do
      before do
        staging # forza la creazione della riga join (declared) prima di proteggerla
        project.update!(secret_approval_enabled: true)
        project.project_environments.find_by!(environment: staging).update!(approval_required: true)
      end

      it "owner → NON copia, crea una change request pending e mostra il notice di attesa" do
        variable = secret_in(environment)
        sign_in(owner)

        expect do
          post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: staging.id }
        end.to change(Secrets::ChangeRequest, :count).by(1)

        expect(response).to redirect_to(member_project_secrets_path(project))
        expect(project.secret_variables.exists?(environment: staging, name: "API_KEY")).to be(false)
        expect(flash[:notice]).to eq(I18n.t("member.secrets.pending_approval", name: "API_KEY"))

        change_request = Secrets::ChangeRequest.last
        expect(change_request).to be_set
        expect(change_request.value).to eq("prod-value")
        expect(change_request.environment).to eq(staging)
      end
    end
  end

  describe "POST rotation (imposta/rimuove la policy di rotazione, CYRA-138)" do
    def secret_with_policy(days: 30)
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      variable.update!(rotation_interval_days: days, rotated_at: Time.current)
      variable
    end

    it "owner → imposta la policy di rotazione" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      sign_in(owner)

      post rotation_member_project_secret_path(project, variable), params: { confirm: "1", rotation_interval_days: "30" }

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(variable.reload.rotation_interval_days).to eq(30)
    end

    it "owner → valore VUOTO rimuove la policy" do
      variable = secret_with_policy
      sign_in(owner)

      post rotation_member_project_secret_path(project, variable), params: { confirm: "1", rotation_interval_days: "" }

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(variable.reload.rotation_interval_days).to be_nil
    end

    it "owner → 0 rimuove la policy" do
      variable = secret_with_policy
      sign_in(owner)

      post rotation_member_project_secret_path(project, variable), params: { confirm: "1", rotation_interval_days: "0" }

      expect(variable.reload.rotation_interval_days).to be_nil
    end

    it "owner con valore negativo → rifiutato (alert, non 500), la policy resta invariata" do
      variable = secret_with_policy(days: 30)
      sign_in(owner)

      post rotation_member_project_secret_path(project, variable), params: { confirm: "1", rotation_interval_days: "-5" }

      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(flash[:alert]).to be_present
      expect(variable.reload.rotation_interval_days).to eq(30)
    end

    it "membro senza secrets.manage → redirect (forbidden), la policy resta invariata" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      create(:project_membership, account: member, project:)
      sign_in(member)

      post rotation_member_project_secret_path(project, variable), params: { rotation_interval_days: "30" }

      expect(response).to redirect_to(root_path)
      expect(variable.reload.rotation_interval_days).to be_nil
    end

    it "progetto non visibile (altra org) → 404 (anti-BOLA)" do
      other_project = create(:project)
      sign_in(owner)

      post rotation_member_project_secret_path(other_project, SecureRandom.uuid),
           params: { rotation_interval_days: "30" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index — badge di rotazione (CYRA-137/CYRA-138)" do
    it "secret in scadenza (due_soon) → mostra il badge nella cella" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      variable.update!(rotation_interval_days: 14, rotated_at: Time.current)
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include("secret-cell-rotation-#{variable.id}")
    end

    it "secret scaduto (overdue) → mostra il badge nella cella" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      variable.update!(rotation_interval_days: 1, rotated_at: Time.current - 2.days)
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include("secret-cell-rotation-#{variable.id}")
    end

    it "secret senza alcuna policy di rotazione → nessun badge" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include("secret-cell-rotation-#{variable.id}")
    end

    it "secret con policy ma ancora :ok (ben oltre la soglia) → nessun badge" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
      variable.update!(rotation_interval_days: 90, rotated_at: Time.current)
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include("secret-cell-rotation-#{variable.id}")
    end
  end

  describe "GET index — badge di richiesta di modifica in attesa (CYRA-138 C2b)" do
    it "una CR pending sulla stessa cella [ambiente, nome] → mostra il badge" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      create(:secret_change_request, project:, environment:, requested_by: create(:account),
             name: "API_KEY", value: "nuovo-valore")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include('data-test="secret-cell-change-pending"')
    end

    it "nessuna CR pending → nessun badge" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include('data-test="secret-cell-change-pending"')
    end

    it "una CR già decisa (applied/rejected/cancelled) non mostra più il badge" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      change_request = create(:secret_change_request, project:, environment:, requested_by: create(:account),
                              name: "API_KEY", value: "nuovo-valore")
      change_request.update!(status: :applied, decided_at: Time.current)
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include('data-test="secret-cell-change-pending"')
    end

    it "una CR pending su un nome presente in un ALTRO ambiente (riga esistente via drift) evidenzia la cella vuota" do
      staging
      Secrets::Variables::Set.call(project:, environment:, name: "DRIFT_NAME", value: "prod-value")
      # Nessuna variabile DRIFT_NAME su staging: la richiesta propone di crearla lì — la riga esiste
      # comunque in matrice perché il nome ha già un valore su production.
      create(:secret_change_request, project:, environment: staging, requested_by: create(:account),
             name: "DRIFT_NAME", value: "staging-value")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).to include('data-test="secret-cell-change-pending"')
    end

    it "una CR pending di un ALTRO progetto non genera badge in questa matrice" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v")
      other_project = create(:project, organization: org)
      other_environment = create(:environment, organization: org).tap { |e| other_project.environments << e }
      create(:secret_change_request, project: other_project, environment: other_environment,
             requested_by: create(:account), name: "API_KEY", value: "other")
      sign_in(owner)

      get member_project_secrets_path(project)

      expect(response.body).not_to include('data-test="secret-cell-change-pending"')
    end
  end

  # CYRA-138, Fase 4 pezzo C1b — GRANDE SPEC DI SICUREZZA: con l'opt-in dell'approvazione OFF (default
  # di ogni progetto), l'intero flusso web di scrittura dei secret deve restare BYTE-PER-BYTE identico a
  # prima dell'intercettazione — nessuna ChangeRequest viene mai creata, i notice sono quelli di sempre.
  describe "Regressione — opt-in approvazione OFF (default): il flusso resta identico a prima di CYRA-138 C1b" do
    it "create/promote/destroy non creano mai una ChangeRequest e mostrano i notice originali" do
      sign_in(owner)

      expect do
        post member_project_secrets_path(project),
             params: { confirm: "1", name: "REG_KEY", values: { environment.id.to_s => "v1" } }
      end.not_to change(Secrets::ChangeRequest, :count)
      expect(response).to redirect_to(member_project_secrets_path(project))
      expect(flash[:notice]).to eq(I18n.t("member.secrets.saved"))

      variable = project.secret_variables.find_by(environment:, name: "REG_KEY")

      expect do
        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: staging.id }
      end.not_to change(Secrets::ChangeRequest, :count)
      expect(flash[:notice]).to eq(I18n.t("member.secrets.promoted", name: "REG_KEY", environment: staging.label))

      expect do
        delete member_project_secret_path(project, variable), params: { confirm: "1" }
      end.not_to change(Secrets::ChangeRequest, :count)
      expect(flash[:notice]).to eq(I18n.t("member.secrets.deleted"))
      expect(Secrets::Variable.exists?(variable.id)).to be(false)
    end
  end

  # CYRA-422 — la protezione è nel corpo (non nei tooltip) e la pagina dice CHI può leggere i secret,
  # con nomi e ruoli reali, filtrando i nomi sui permessi di chi guarda.
  describe "GET index — protezione e chi può vedere (CYRA-422)" do
    it "mostra la riga permanente di protezione: cifratura, tracciamento e retention" do
      sign_in(owner)
      get member_project_secrets_path(project)

      expect(response.body).to include('data-test="secret-protection"')
      expect(response.body).to include('data-test="secret-protection-encryption"')
      expect(response.body).to include('data-test="secret-protection-audit"')
      expect(response.body).to include('data-test="secret-protection-retention"')
      expect(response.body).to include(I18n.t("member.secret_protection.retention"))
    end

    it "a chi gestisce i segreti (owner) mostra i nomi di chi può leggere, con ruolo" do
      sign_in(owner)
      get member_project_secrets_path(project)

      expect(response.body).to include('data-test="secret-readers-list"')
      # Il nome va cercato ESCAPED: i nomi generati contengono un apostrofo circa una volta su
      # quaranta (`Abram D'Amore`), che nell'HTML diventa `&#39;` e non combacia più con la stringa
      # grezza. Un rosso raro, che sembra inspiegabile perché dipende dal nome sorteggiato.
      expect(response.body).to include(ERB::Util.html_escape(owner.name))
      expect(response.body).to include(I18n.t("member.roles.owner"))
    end

    it "a chi può solo leggere mostra il conteggio senza i nomi (no fuga sull'organizzazione)" do
      create(:project_membership, account: member, project:)
      create(:account_permission, account: member, organization: org, permission_key: "secrets.read", effect: :allow)
      sign_in(member)
      get member_project_secrets_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="secret-readers-count"')
      expect(response.body).to include('data-test="secret-readers-hidden"')
      expect(response.body).not_to include('data-test="secret-readers-list"')
      expect(response.body).not_to include(ERB::Util.html_escape(owner.name))
    end
  end

  # CYRA-78 — il confine ambienti (finora solo CLI, e solo per i service account) vale anche per gli
  # utenti umani sul web: la matrice nasconde le colonne vietate e ogni ramo che tocca una cella di un
  # ambiente fuori confine risponde 403 lasciando un evento "denied" nell'audit.
  describe "confine ambienti per-utente (CYRA-78)" do
    let(:restricted_membership) { org.memberships.find_by!(account: member) }

    def denied_events(environment_scope)
      project.secret_events.where(action: "denied", channel: "web", environment: environment_scope)
    end

    before do
      environment.update!(label: "Produzione")
      staging.update!(label: "Ambiente di prova")
      create(:project_membership, account: member, project:)
      # CYRA-721 — leggere i valori e gestirli sono due permessi distinti (manage NON implica più read):
      # questo blocco esercita entrambe le strade (reveal e scrittura), quindi l'attore li ha entrambi.
      # Il confine ambienti è ortogonale ai permessi: dice DOVE, non COSA.
      create(:account_permission, account: member, organization: org, permission_key: "secrets.manage", effect: :allow)
      create(:account_permission, account: member, organization: org, permission_key: "secrets.read", effect: :allow)
      restricted_membership.update!(secret_environment_codes: [ "staging" ])
    end

    describe "GET index" do
      it "esclude dai risultati e dai conteggi le deleghe di un ambiente vietato" do
        shared = Secrets::Shared::Save.call(organization: org, environment:, name: "PRIVATE_PRODUCTION_NAME",
                                            value: "valore-di-prova", enqueue_sync: false).value
        shared.delegations.create!(project:)
        sign_in(member)

        get member_project_secrets_path(project, origin: "shared")

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("PRIVATE_PRODUCTION_NAME")
        expect(Nokogiri::HTML(response.body).at_css('[data-test="secrets-count-shared"]').text).to include("0")
        expect(response.body).not_to include('data-test="secret-shared-source"')
      end

      it "mostra solo le colonne consentite" do
        sign_in(member)
        get member_project_secrets_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-test="secret-column-staging"')
        expect(response.body).not_to include('data-test="secret-column-production"')
      end

      it "chi non ha restrizioni vede tutte le colonne" do
        sign_in(owner)
        get member_project_secrets_path(project)

        expect(response.body).to include('data-test="secret-column-staging"')
        expect(response.body).to include('data-test="secret-column-production"')
      end
    end

    describe "GET reveal" do
      it "ambiente vietato → 403, nessun valore, evento denied" do
        variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "s3cr3t-plain").value
        sign_in(member)

        expect do
          get reveal_member_project_secret_path(project, variable)
        end.to change { denied_events(environment).where(name: "API_KEY").count }.by(1)

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include("s3cr3t-plain")
      end

      it "ambiente consentito → 200 e nessun evento denied" do
        variable = Secrets::Variables::Set.call(project:, environment: staging, name: "API_KEY", value: "ok-plain").value
        sign_in(member)

        expect do
          get reveal_member_project_secret_path(project, variable)
        end.not_to change { project.secret_events.where(action: "denied").count }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["value"]).to eq("ok-plain")
      end
    end

    describe "POST create" do
      it "cella su un ambiente vietato → 403 e niente scritto" do
        sign_in(member)

        expect do
          post member_project_secrets_path(project),
               params: { confirm: "1", name: "DATABASE_URL", values: { environment.id.to_s => "postgres://p" } }
        end.to change { denied_events(environment).count }.by(1)

        expect(response).to have_http_status(:forbidden)
        expect(project.secret_variables.count).to eq(0)
      end

      it "cella su un ambiente consentito → salvata" do
        sign_in(member)

        post member_project_secrets_path(project),
             params: { confirm: "1", name: "DATABASE_URL", values: { staging.id.to_s => "postgres://s" } }

        expect(response).to redirect_to(member_project_secrets_path(project))
        expect(project.secret_variables.find_by(environment: staging, name: "DATABASE_URL").value).to eq("postgres://s")
      end
    end

    describe "DELETE destroy" do
      it "cella su un ambiente vietato → 403 e il secret resta" do
        variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
        sign_in(member)

        expect do
          delete member_project_secret_path(project, variable), params: { confirm: "1" }
        end.to change { denied_events(environment).count }.by(1)

        expect(response).to have_http_status(:forbidden)
        expect(project.secret_variables.exists?(variable.id)).to be(true)
      end
    end

    describe "POST promote" do
      it "ambiente di destinazione vietato → 403 e nessuna copia" do
        variable = Secrets::Variables::Set.call(project:, environment: staging, name: "API_KEY", value: "v").value
        sign_in(member)

        expect do
          post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: environment.id }
        end.to change { denied_events(environment).count }.by(1)

        expect(response).to have_http_status(:forbidden)
        expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
      end

      it "ambiente di origine vietato → 403 (il valore di production non esce da lì)" do
        variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
        sign_in(member)

        post promote_member_project_secret_path(project, variable), params: { confirm: "1", target_environment_id: staging.id }

        expect(response).to have_http_status(:forbidden)
        expect(project.secret_variables.exists?(environment: staging, name: "API_KEY")).to be(false)
      end
    end

    describe "POST rotation" do
      it "cella su un ambiente vietato → 403 e policy invariata" do
        variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
        sign_in(member)

        post rotation_member_project_secret_path(project, variable), params: { confirm: "1", rotation_interval_days: "30" }

        expect(response).to have_http_status(:forbidden)
        expect(variable.reload.rotation_interval_days).to be_nil
      end
    end

    describe "override per-progetto" do
      let(:other_project) { create(:project, organization: org) }

      before do
        other_project.environments << environment
        other_project.environments << staging
        create(:project_membership, account: member, project: other_project)
      end

      it "allarga a production solo sul progetto scelto" do
        create(:account_secret_access, account: member, project:, organization: org,
                                       environment_codes: %w[staging production])
        variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "ok-plain").value
        elsewhere = Secrets::Variables::Set.call(project: other_project, environment:, name: "API_KEY", value: "nope").value
        sign_in(member)

        get reveal_member_project_secret_path(project, variable)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["value"]).to eq("ok-plain")

        get reveal_member_project_secret_path(other_project, elsewhere)
        expect(response).to have_http_status(:forbidden)
      end

      it "restringe anche quando l'organizzazione non pone limiti" do
        restricted_membership.update!(secret_environment_codes: [])
        create(:account_secret_access, account: member, project:, organization: org, environment_codes: %w[staging])
        variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v").value
        sign_in(member)

        get reveal_member_project_secret_path(project, variable)

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # CYRA-721 — leggere i valori e gestirli sono due permessi distinti: `secrets.read` apre il valore in
  # chiaro, `secrets.manage` permette di cambiarlo. Prima manage implicava read (chi poteva solo gestire
  # vedeva tutto) e read da solo non aveva nessun comando per mostrare il valore. Le quattro combinazioni
  # sono qui, sulla stessa pagina: la matrice resta aperta a entrambi (i NOMI non sono un valore), ma la
  # strada verso il valore in chiaro esiste solo per chi ha read.
  describe "GET index e reveal — lettura e gestione sono permessi distinti (CYRA-721)" do
    let!(:secret) { Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "s3cr3t-plain").value }

    def grant(key)
      create(:account_permission, account: member, organization: org, permission_key: key, effect: :allow)
    end

    before { create(:project_membership, account: member, project:) }

    context "solo secrets.read (può leggere, non può gestire)" do
      before { grant("secrets.read") }

      it "la matrice offre il comando per mostrare i valori, non quelli per cambiarli" do
        sign_in(member)
        get member_project_secrets_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-test="secret-reveal-api_key"')
        expect(response.body).to include(%(data-test="secret-copy-#{secret.id}"))
        expect(response.body).not_to include('data-test="secret-edit-api_key"')
        expect(response.body).not_to include('data-test="secret-add"')
      end

      it "il valore in chiaro arriva davvero" do
        sign_in(member)
        get reveal_member_project_secret_path(project, secret)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["value"]).to eq("s3cr3t-plain")
      end
    end

    context "solo secrets.manage (può gestire, non può leggere)" do
      before { grant("secrets.manage") }

      it "la matrice resta gestibile: i nomi si vedono e la riga si sblocca" do
        sign_in(member)
        get member_project_secrets_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("API_KEY")
        expect(response.body).to include('data-test="secret-edit-api_key"')
      end

      it "nessuna strada verso il valore in chiaro: niente comando mostra, niente copia, niente indirizzo" do
        sign_in(member)
        get member_project_secrets_path(project)

        expect(response.body).not_to include('data-test="secret-reveal-api_key"')
        expect(response.body).not_to include(%(data-test="secret-copy-#{secret.id}"))
        expect(response.body).not_to include(reveal_member_project_secret_path(project, secret))
        expect(response.body).not_to include("s3cr3t-plain")
      end

      it "il reveal chiamato a mano è respinto e non registra nessuna lettura" do
        sign_in(member)

        expect do
          get reveal_member_project_secret_path(project, secret)
        end.not_to change { project.secret_events.where(action: "read").count }

        expect(response).to redirect_to(root_path)
        expect(response.body).not_to include("s3cr3t-plain")
      end
    end

    context "secrets.read + secrets.manage" do
      before do
        grant("secrets.read")
        grant("secrets.manage")
      end

      it "ha entrambi i comandi e legge il valore" do
        sign_in(member)
        get member_project_secrets_path(project)
        expect(response.body).to include('data-test="secret-reveal-api_key"')
        expect(response.body).to include('data-test="secret-edit-api_key"')

        get reveal_member_project_secret_path(project, secret)
        expect(response.parsed_body["value"]).to eq("s3cr3t-plain")
      end
    end

    context "nessuno dei due permessi" do
      it "la matrice non si apre nemmeno" do
        sign_in(member)
        get member_project_secrets_path(project)

        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "page layout" do
    def doc = Nokogiri::HTML(response.body)

    before { staging }

    it "shows the origins as count chips instead of a separate box" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      sign_in(owner)
      get member_project_secrets_path(project)
      counts = doc.at_css("[data-test='secrets-counts']")
      expect(counts).to be_present
      %w[secrets-count-local secrets-count-shared secrets-count-environments secrets-drift-count].each do |id|
        expect(counts.at_css("[data-test='#{id}']")).to be_present, "missing #{id}"
      end
      expect(doc.at_css("[data-test='secrets-origin-summary']")).to be_nil
    end

    it "drops the section and table titles and keeps a one-line subtitle" do
      sign_in(owner)
      get member_project_secrets_path(project)
      titles = doc.css("[data-test='member-project-secrets'] h2, [data-test='member-project-secrets'] h3").map { |h| h.text.strip }
      expect(titles).not_to include(I18n.t("member.secrets.section_title"), I18n.t("member.secrets.table_title"))
      expect(doc.at_css("[data-test='secrets-lead']").text.strip).to eq(I18n.t("member.secrets.lead"))
    end

    # CYRA-924 — C63: the result count sits in the panel's counts line, not in the toolbar.
    it "uses the standard toolbar and says the count in the panel's counts line" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      Secrets::Variables::Set.call(project:, environment:, name: "OTHER", value: "x")
      sign_in(owner)
      get member_project_secrets_path(project, q: "part")
      toolbar = doc.at_css("[data-test='secrets-toolbar']")
      expect(toolbar.at_css("[data-test='secrets-search']")).to be_present
      expect(doc.at_css("[data-test='secrets-filter-reset']")).to be_nil
      expect(doc.at_css("[data-test='secrets-count-shown']").text.squish)
        .to include(I18n.t("member.secrets.counts.of_total", total: 2))
    end

    # CYRA-924 — T1, T12: one panel holds tabs, counts as text, actions, search, table and footer.
    it "keeps tabs, counts, actions, search, table and footer in one panel" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      sign_in(owner)
      get member_project_secrets_path(project)
      panel = doc.at_css("[data-test='secrets-panel']")
      %w[secrets-subnav secrets-counts secret-add secrets-toolbar secrets-table secrets-legend].each do |id|
        expect(panel.at_css("[data-test='#{id}']")).to be_present, "missing #{id} in the panel"
      end
      expect(panel.at_css("[data-test='secrets-count-shown']").text.squish).to include("1")
    end

    it "turns each row into a card on the phone and keeps the name column in place" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      sign_in(owner)
      get member_project_secrets_path(project)
      table = doc.at_css("[data-test='secrets-table'] table")
      expect(table["class"]).to include("ui-table--stacked", "ui-table--sticky-first")
      expect(table["aria-label"]).to eq(I18n.t("member.secrets.matrix_label"))
      expect(doc.at_css("#secret-partial th.ui-table-cell--title[scope='row']")).to be_present
      expect(doc.at_css("#secret-partial td[data-label='#{environment.label}']")).to be_present
    end

    it "says no row matches inside the table, with a way to reset the filters" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      sign_in(owner)
      get member_project_secrets_path(project, q: "nothing-like-this")
      state = doc.at_css("tr.ui-table-state [data-test='secrets-empty']")
      expect(state["data-table-state"]).to eq("no_results")
      expect(state.at_css("a[href='#{member_project_secrets_path(project)}']").text.squish).to eq(I18n.t("member.secrets.origins.reset"))
      expect(doc.at_css("[data-test='secrets-toolbar']")).to be_present
    end

    it "says the matrix is empty when the project has no variables" do
      sign_in(owner)
      get member_project_secrets_path(project)
      expect(doc.at_css("[data-test='secrets-empty']")["data-table-state"]).to eq("empty")
    end

    it "turns files, tailored values and the access log into tabs" do
      sign_in(owner)
      get member_project_secrets_path(project)
      nav = doc.at_css("[data-test='secrets-subnav']")
      expect(nav.at_css("[data-test='secrets-subnav-variables'][aria-current='page']")).to be_present
      expect(nav.at_css("a[href='#{member_project_secret_assets_path(project)}']")).to be_present
      expect(nav.at_css("a[href='#{member_project_secret_overrides_path(project)}']")).to be_present
      expect(nav.at_css("a[href='#{member_project_secret_events_path(project)}']")).to be_present
      expect(doc.at_css("[data-test='secret-overrides-open']")).to be_nil
      expect(doc.at_css("[data-test='secrets-activity-all']")).to be_nil
    end

    it "shows only the tabs a read-only member can open" do
      create(:project_membership, account: member, project:)
      create(:account_permission, account: member, organization: org, permission_key: "secrets.read", effect: :allow)
      sign_in(member)
      get member_project_secrets_path(project)
      nav = doc.at_css("[data-test='secrets-subnav']")
      expect(nav.at_css("a[href='#{member_project_secret_overrides_path(project)}']")).to be_nil
      expect(nav.at_css("a[href='#{member_project_secret_events_path(project)}']")).to be_nil
    end

    it "writes Missing in amber for a hole and a dash for an ordinary empty cell" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      shared = Secrets::Shared::Save.call(organization: org, environment:, name: "ORG_ONLY", value: "v", enqueue_sync: false).value
      Secrets::Shared::Delegate.call(shared_value: shared, project:)
      sign_in(owner)
      get member_project_secrets_path(project)
      expect(doc.at_css("#secret-partial [data-test='secret-cell-drift']").text.strip).to eq(I18n.t("member.secrets.origins.missing"))
      expect(doc.at_css("#secret-org_only [data-test='secret-cell-empty']").text.strip).to eq("—")
    end

    it "filters the rows with holes from the Anomalies chip" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      Secrets::Variables::Set.call(project:, environment:, name: "COMPLETE", value: "p")
      Secrets::Variables::Set.call(project:, environment: staging, name: "COMPLETE", value: "s")
      sign_in(owner)
      get member_project_secrets_path(project)
      expect(doc.at_css("a[data-test='secrets-drift-count']")["href"]).to include("drift=1")

      get member_project_secrets_path(project, drift: "1")
      expect(doc.css("[data-test='secret-row'] th").map { |th| th.text.strip }).to eq([ "PARTIAL" ])
      expect(doc.at_css("[data-test='secrets-drift-count'][aria-current='true']")).to be_present
    end

    it "says how many variables each environment has" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      Secrets::Variables::Set.call(project:, environment:, name: "OTHER", value: "x")
      sign_in(owner)
      get member_project_secrets_path(project)
      expect(doc.at_css("[data-test='secret-column-production']").text).to include("2/2")
      expect(doc.at_css("[data-test='secret-column-staging']").text).to include("0/2")
    end

    it "folds identical reads in a row into one activity line" do
      Secrets::Variables::Set.call(project:, environment:, name: "PARTIAL", value: "only-prod")
      3.times { create(:secret_event, project:, environment:, actor: owner, action: "read", metadata: { "count" => 1 }) }
      sign_in(owner)
      get member_project_secrets_path(project)
      lines = doc.css("[data-test='secret-event']")
      expect(lines.first.text).to include(I18n.t("member.secrets.activity_read_times", count: 3))
      expect(lines.size).to eq(2) # the folded reads and the earlier set
    end

    it "gives who can see and how we protect a panel each" do
      sign_in(owner)
      get member_project_secrets_path(project)
      readers = doc.at_css("[data-test='secret-readers']")
      protection = doc.at_css("[data-test='secret-protection']")
      expect(doc.at_css("[data-test='secrets-access']")).to be_nil
      expect(readers["class"]).to include("border")
      expect(protection["class"]).to include("rounded-lg")
      expect(readers.at_css("[data-test='secret-protection']")).to be_nil
    end

    it "keeps Use this secret folded until opened" do
      sign_in(owner)
      get member_project_secrets_path(project)
      usage = doc.at_css("details[data-test='secret-usage']")
      expect(usage).to be_present
      expect(usage["open"]).to be_nil
    end
  end

  # CYRA-924 — C68, C70: the matrix pages like every list; a searched row opens on its page.
  describe "GET index — pagination" do
    def doc = Nokogiri::HTML(response.body)

    # The setup writes one secret per call; Prosopite would flag the loop, not the page under test.
    def create_names(count)
      Prosopite.pause do
        (1..count).each { |i| Secrets::Variables::Set.call(project:, environment:, name: format("VAR_%02d", i), value: "v") }
      end
    end

    it "shows 12 names per page and counts every name in the column headers" do
      create_names(14)
      sign_in(owner)
      get member_project_secrets_path(project)
      expect(doc.css("[data-test='secret-row'] th").size).to eq(12)
      expect(doc.at_css("[data-test='secret-column-count-#{environment.code}']").text.strip).to eq("14/14")
      expect(doc.at_css("[data-test='secrets-pagination']")).to be_present

      get member_project_secrets_path(project, page: 2)
      expect(doc.css("[data-test='secret-row'] th").map { |th| th.text.strip }).to eq(%w[VAR_13 VAR_14])
    end

    it "opens a searched row on the page that holds it" do
      create_names(14)
      sign_in(owner)
      get member_project_secrets_path(project, highlight: "var_14")
      expect(doc.at_css("[data-test='secret-row-highlighted']")["id"]).to eq("secret-var_14")
    end

    it "keeps the page the person asked for, even with a highlight" do
      create_names(14)
      sign_in(owner)
      get member_project_secrets_path(project, highlight: "VAR_14", page: 1)
      expect(doc.at_css("[data-test='secret-row-highlighted']")).to be_nil
    end
  end

  # CYRA-924 — C64, C65: the matrix shows values; adding and editing happen in dialogs.
  describe "GET index — dialogs instead of inline fields" do
    def doc = Nokogiri::HTML(response.body)

    it "keeps every field out of the cells and puts them in the row's dialog" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v", description: "Main key").value
      sign_in(owner)
      get member_project_secrets_path(project)
      row = doc.at_css("#secret-api_key")
      expect(row.css("td textarea, td input[type='text']").reject { |field| field.ancestors("dialog").any? }).to be_empty
      dialog = row.at_css("dialog[data-test='secret-dialog-api_key']")
      expect(dialog.at_css("textarea[name='values[#{environment.id}]']").text).to eq("")
      expect(dialog.at_css("input[name='description']")["value"]).to eq("Main key")
      expect(row.at_css("th [data-test='secret-description-api_key']").text).to eq("Main key")
      expect(dialog.at_css("input[type='hidden'][name='name']")["value"]).to eq("API_KEY")
      expect(row.at_css("[data-test='secret-value-#{variable.id}'][hidden]")).to be_present
    end

    it "saves one description for every environment of the name" do
      staging
      sign_in(owner)
      # Secrets::Rows::Save writes one cell per environment on purpose (see its header): a linear cost.
      Prosopite.pause do
        post member_project_secrets_path(project), params: { confirm: "1", name: "NEW_KEY", description: "Signs the cookies",
                                                             values: { environment.id.to_s => "p", staging.id.to_s => "s" } }
      end
      expect(project.secret_variables.where(name: "NEW_KEY").pluck(:description)).to eq([ "Signs the cookies" ] * 2)
    end

    it "opens a dialog to add a secret, with one field per environment" do
      environment
      sign_in(owner)
      get member_project_secrets_path(project)
      dialog = doc.at_css("dialog[data-test='secret-new-dialog']")
      expect(dialog.at_css("input[name='name']")).to be_present
      expect(dialog.at_css("input[name='description']")).to be_present
      expect(dialog.at_css("[data-test='secret-new-field-#{environment.code}']")).to be_present
      expect(doc.at_css("[data-test='secret-new-row']")).to be_nil
    end

    # F24 — every dialog of the page opens in the standard shell, its actions in the header panel.
    it "opens the row, add, copy and rotation dialogs in the standard modal shell" do
      staging
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "s3cr3t-plain").value
      sign_in(owner)
      get member_project_secrets_path(project)
      { "secret-dialog-api_key" => "secret-save-api_key", "secret-new-dialog" => "secret-add-row",
        "secret-promote-modal-#{variable.id}" => "secret-promote-submit-#{variable.id}",
        "secret-rotation-modal-#{variable.id}" => "secret-rotation-submit-#{variable.id}" }.each do |dialog_id, submit_id|
        dialog = doc.at_css("dialog[data-test='#{dialog_id}']")
        expect(dialog["class"]).to include("bg-stone-100", "dark:bg-zinc-950", "rounded-xl")
        submit = dialog.at_css("header [data-test='#{submit_id}']")
        expect(submit).to be_present
        expect(submit.ancestors("form")).to be_present
      end
      expect(doc.at_css("[data-test='secret-new-dialog'] header [data-test='secret-cancel-new']")).to be_present
      expect(response.body).not_to include("s3cr3t-plain")
    end

    it "says a shared value is changed from the organization, with no field for it" do
      shared = Secrets::Shared::Save.call(organization: org, environment:, name: "ORG_ONLY", value: "v", enqueue_sync: false).value
      Secrets::Shared::Delegate.call(shared_value: shared, project:)
      staging
      Secrets::Variables::Set.call(project:, environment: staging, name: "ORG_ONLY", value: "s")
      sign_in(owner)
      get member_project_secrets_path(project)
      field = doc.at_css("[data-test='secret-dialog-org_only'] [data-test='secret-dialog-field-#{environment.code}']")
      expect(field.text).to include(I18n.t("member.secrets.shared_readonly"))
      expect(field.at_css("textarea")).to be_nil
    end
  end
end
