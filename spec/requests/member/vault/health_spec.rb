# frozen_string_literal: true

require "rails_helper"

# Le anomalie dei secret (CYRA-137 → riscritta in CYRA-409): quale variabile manca, in quale ambiente,
# da quando, e la possibilità di marcarne una come «assenza voluta». Da CYRA-428 l'ELENCO vive dentro
# la lista unica di «Da sistemare» (Member::Vault::AttentionController) e questo indirizzo ci porta;
# qui restano le AZIONI, con lo stesso gate org-level secrets_audit.view e lo stesso anti-BOLA.
RSpec.describe "Member::Vault::Health", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Il label è ciò che l'utente vede (la pagina mostra environment.label, non il code): lo derivo dal
  # code così i test possono cercarlo nell'HTML. Il factory di default ha un label fisso "Environment".
  def declare_environment(target_project, code:)
    environment = create(:environment, organization: target_project.organization, code: code, label: code.titleize)
    create(:project_environment, project: target_project, environment: environment)
    target_project.environments.reset
    environment
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_vault_health_path
      expect(response).to redirect_to(login_path)
    end

    # L'indirizzo resta valido per chi ce l'ha nei segnalibri: porta alla lista che ora contiene le
    # anomalie. Il redirect non ha gate — il permesso lo applica la destinazione.
    it "porta alla lista «Da sistemare»" do
      sign_in(owner)
      get member_vault_health_path

      expect(response).to redirect_to(member_vault_attention_path)
    end
  end

  # Il contenuto delle anomalie si legge ora nella lista unica: sono gli stessi scenari di CYRA-409,
  # verificati dove le righe vivono adesso.
  describe "le anomalie nella lista «Da sistemare»" do
    it "owner senza anomalie → 200 con lo stato 'tutto in ordine'" do
      sign_in(owner)
      production = declare_environment(project, code: "production")
      create(:secret_variable, project: project, environment: production, name: "OK")

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.vault_attention.empty"))
    end

    # Scenario 1 + DoD: la riga mostra il nome della variabile e in quale ambiente manca, senza aprire
    # il progetto. E DoD 4: da quando l'anomalia esiste.
    it "mostra il nome della variabile, l'ambiente in cui manca e da quando (buco drift)" do
      sign_in(owner)
      production = declare_environment(project, code: "production")
      declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "PARTIAL_VAR")
      # PARTIAL_VAR è in production, manca in staging.

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PARTIAL_VAR")
      expect(response.body).to include("Staging") # il label dell'ambiente in cui manca
      # "da quando esiste" (DoD 4), nella locale della richiesta.
      expect(response.body).to include(I18n.t("member.vault_attention.since", time: "").strip)
    end

    # Scenario 3: l'ordine segue il rischio — la produzione prima, non l'ordine alfabetico.
    it "ordina per rischio: l'anomalia in produzione compare prima di quella in staging" do
      sign_in(owner)

      # "Zeta": buco in PRODUCTION (variabile presente in staging, assente in production).
      zeta = create(:project, organization: org, name: "Zeta")
      declare_environment(zeta, code: "production")
      zeta_staging = declare_environment(zeta, code: "zeta_staging")
      create(:secret_variable, project: zeta, environment: zeta_staging, name: "ZVAR")

      # "Alfa": buco in un ambiente non di produzione. Alfabeticamente verrebbe prima di "Zeta".
      alfa = create(:project, organization: org, name: "Alfa")
      declare_environment(alfa, code: "alfa_staging")
      alfa_preprod = declare_environment(alfa, code: "alfa_preprod")
      create(:secret_variable, project: alfa, environment: alfa_preprod, name: "AVAR")

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      rows = Nokogiri::HTML(response.body).css("[data-test='vault-attention-row']").map(&:text)
      expect(rows.index { |text| text.include?("Zeta") }).to be < rows.index { |text| text.include?("Alfa") }
    end

    it "anti-BOLA: le anomalie di un progetto non visibile all'utente non compaiono" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "secrets_audit.view" ], actor: owner
      )
      visible_project = create(:project, organization: org, name: "Progetto Visibile")
      create(:project_membership, account: member, project: visible_project)

      hidden_project = create(:project, organization: org, name: "Progetto Nascosto")
      hidden_env = declare_environment(hidden_project, code: "hidden_production")
      declare_environment(hidden_project, code: "hidden_staging")
      create(:secret_variable, project: hidden_project, environment: hidden_env, name: "HIDDEN_PARTIAL")
      sign_in(member)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Progetto Nascosto")
      expect(response.body).not_to include("HIDDEN_PARTIAL")
      expect(response.body).to include(I18n.t("member.vault_attention.empty"))
    end
  end

  # Scenario 2: marco un'assenza come voluta → sparisce dalle anomalie e resta una nota consultabile,
  # con CHI l'ha decisa e QUANDO (vale per l'organizzazione — risposta del cliente su CYRA-409).
  describe "POST acknowledge" do
    def prepare_anomaly
      production = declare_environment(project, code: "production")
      declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "PARTIAL_VAR")
      sign_in(owner)
      get member_vault_attention_path # osserva e persiste l'anomalia
      Secrets::HealthAnomaly.find_by!(secret_name: "PARTIAL_VAR")
    end

    it "marca l'assenza come voluta: esce dai conteggi e resta nella sezione delle volute con la nota" do
      anomaly = prepare_anomaly

      post member_acknowledge_vault_health_anomaly_path(anomaly), params: { reason: "In staging non serve." }

      expect(response).to redirect_to(member_vault_attention_path)
      anomaly.reload
      expect(anomaly.status).to eq("acknowledged")
      expect(anomaly.acknowledgement_reason).to eq("In staging non serve.")
      expect(anomaly.acknowledged_by).to eq(owner)
      expect(anomaly.acknowledged_at).to be_present

      follow_redirect!
      expect(response.body).to include(I18n.t("member.vault_health.acknowledged_section.title"))
      expect(response.body).to include("In staging non serve.")
    end

    it "senza una nota non marca nulla e avvisa" do
      anomaly = prepare_anomaly

      post member_acknowledge_vault_health_anomaly_path(anomaly), params: { reason: "  " }

      expect(anomaly.reload.status).to eq("open")
      expect(flash[:alert]).to eq(I18n.t("member.vault_health.acknowledge_needs_reason"))
    end

    it "senza il permesso secrets_audit.view non si marca nulla" do
      anomaly = prepare_anomaly
      sign_in(member)

      post member_acknowledge_vault_health_anomaly_path(anomaly), params: { reason: "x" }

      expect(anomaly.reload.status).to eq("open")
    end

    it "anti-BOLA: non si può marcare un'anomalia di un progetto non visibile (altra org) → 404" do
      other_org = create(:organization)
      other_project = create(:project, organization: other_org)
      other_env = create(:environment, organization: other_org).tap { |e| other_project.environments << e }
      foreign = create(:secret_health_anomaly, project: other_project, environment: other_env, secret_name: "FOREIGN")
      sign_in(owner)

      post member_acknowledge_vault_health_anomaly_path(foreign), params: { reason: "x" }

      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.status).to eq("open")
    end
  end

  describe "DELETE restore" do
    it "rimette un'assenza voluta fra le cose da guardare" do
      production = declare_environment(project, code: "production")
      staging = declare_environment(project, code: "staging")
      anomaly = create(:secret_health_anomaly, :acknowledged, project: project, environment: staging,
                       secret_name: "PARTIAL_VAR")
      create(:secret_variable, project: project, environment: production, name: "PARTIAL_VAR")
      sign_in(owner)

      delete member_restore_vault_health_anomaly_path(anomaly)

      expect(response).to redirect_to(member_vault_attention_path)
      anomaly.reload
      expect(anomaly.status).to eq("open")
      expect(anomaly.acknowledged_by).to be_nil
      expect(anomaly.acknowledgement_reason).to be_nil
    end
  end
end
