# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectSecretVersions", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def secret_with_history
    secret = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "old").value
    Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "new")
    secret.reload
  end

  describe "project header" do
    it "shows the project header and the secrets tabs above the versions" do
      secret = secret_with_history
      sign_in(owner)
      get member_project_secret_versions_path(project, secret)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-test='project-tabs']")).to be_present
      expect(document.at_css("[data-test='secrets-subnav-variables'][aria-current='page']")).to be_present
      expect(document.at_css("[data-test='versions-environment']").text).to include(environment.label)
    end
  end

  describe "GET index" do
    it "owner → 200 con le versioni" do
      secret = secret_with_history
      sign_in(owner)
      get member_project_secret_versions_path(project, secret)
      expect(response).to have_http_status(:ok)
    end

    it "membro che vede il progetto ma senza secrets.read → redirect" do
      create(:project_membership, account: member, project:)
      secret = secret_with_history
      sign_in(member)
      get member_project_secret_versions_path(project, secret)
      expect(response).to redirect_to(root_path)
    end

    it "secret di un altro progetto → 404 (anti-BOLA)" do
      other = create(:secret_variable)
      sign_in(owner)
      get member_project_secret_versions_path(project, other)
      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-204 — anche lo storico è una lettura dal sito: nessun valore storico deve finire nel sorgente
  # (chi lo apre leggerebbe TUTTE le versioni, corrente compresa, aggirando il reveal della matrice) e
  # ogni lettura on-demand deve lasciare traccia, come per la matrice (CYRA-202).
  describe "GET index — nessun valore di versione nel corpo (CYRA-204)" do
    it "i valori storici non compaiono nella risposta" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "VERSION-CANARY-OLD")
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "VERSION-CANARY-NEW")
      secret = project.secret_variables.find_by!(name: "API_KEY")
      sign_in(owner)

      get member_project_secret_versions_path(project, secret)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("VERSION-CANARY-OLD")
      expect(response.body).not_to include("VERSION-CANARY-NEW")
    end
  end

  describe "GET reveal versione (CYRA-204)" do
    it "owner → valore della versione in JSON e registra l'accesso (audit read, source web)" do
      secret = secret_with_history
      version = secret.versions.ordered.last # numero 1, valore "old"
      sign_in(owner)

      expect do
        get reveal_member_project_secret_version_path(project, secret, version)
      end.to change { project.secret_events.where(action: "read", environment:, name: "API_KEY").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("old")
      expect(response.headers["Cache-Control"]).to include("no-store")

      event = project.secret_events.where(action: "read", name: "API_KEY").order(:created_at).last
      expect(event.metadata["source"]).to eq("web")
    end

    it "membro senza secrets.read → redirect, nessun valore esposto" do
      create(:project_membership, account: member, project:)
      secret = secret_with_history
      version = secret.versions.ordered.last
      sign_in(member)

      get reveal_member_project_secret_version_path(project, secret, version)

      expect(response).to redirect_to(root_path)
    end

    it "secret di un altro progetto → 404 (anti-BOLA)" do
      # Il 404 scatta su set_secret (il secret non è nel progetto), prima ancora di cercare la versione.
      other = create(:secret_variable)
      sign_in(owner)

      get reveal_member_project_secret_version_path(project, other, SecureRandom.uuid)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST rollback" do
    it "owner → ripristina il valore e reindirizza" do
      secret = secret_with_history
      v1 = secret.versions.ordered.last # numero 1, valore "old"
      sign_in(owner)
      post rollback_member_project_secret_version_path(project, secret, v1), params: { confirm: "1" }
      expect(response).to redirect_to(member_project_secret_versions_path(project, secret))
      expect(secret.reload.value).to eq("old")
    end

    it "membro senza secrets.manage → redirect, valore invariato" do
      create(:project_membership, account: member, project:)
      secret = secret_with_history
      v1 = secret.versions.ordered.last
      sign_in(member)
      post rollback_member_project_secret_version_path(project, secret, v1)
      expect(response).to redirect_to(root_path)
      expect(secret.reload.value).to eq("new")
    end
  end

  describe "POST rollback — ambiente protetto dall'approvazione a due (CYRA-138 C1b)" do
    before do
      environment # forza la creazione della riga join (declared) prima di proteggerla
      project.update!(secret_approval_enabled: true)
      project.project_environments.find_by!(environment:).update!(approval_required: true)
    end

    it "owner → NON ripristina, crea una change request pending e mostra il notice di attesa" do
      secret = secret_with_history
      v1 = secret.versions.ordered.last # numero 1, valore "old"
      sign_in(owner)

      expect do
        post rollback_member_project_secret_version_path(project, secret, v1), params: { confirm: "1" }
      end.to change(Secrets::ChangeRequest, :count).by(1)

      expect(response).to redirect_to(member_project_secret_versions_path(project, secret))
      expect(secret.reload.value).to eq("new") # invariato: il rollback NON è stato applicato
      expect(flash[:notice]).to eq(I18n.t("member.secrets.pending_approval", name: "API_KEY"))

      change_request = Secrets::ChangeRequest.last
      expect(change_request).to be_set
      expect(change_request.value).to eq("old")
      expect(change_request.source_version).to eq(v1)
    end
  end

  # CYRA-138, Fase 4 pezzo C1b — grande spec di sicurezza: con l'opt-in OFF (default), il rollback resta
  # identico a prima dell'intercettazione.
  describe "Regressione — opt-in approvazione OFF (default): il rollback resta identico a prima di CYRA-138 C1b" do
    it "ripristina il valore, nessuna ChangeRequest, notice originale" do
      secret = secret_with_history
      v1 = secret.versions.ordered.last
      sign_in(owner)

      expect do
        post rollback_member_project_secret_version_path(project, secret, v1), params: { confirm: "1" }
      end.not_to change(Secrets::ChangeRequest, :count)

      expect(response).to redirect_to(member_project_secret_versions_path(project, secret))
      expect(secret.reload.value).to eq("old")
      expect(flash[:notice]).to eq(I18n.t("member.secrets.rolled_back"))
    end
  end

  # CYRA-666 — il confine ambienti (CYRA-78) vale anche qui. Lo storico e' l'altra strada verso il
  # valore in chiaro: senza questo gate, un account confinato a staging legge dalla versione il valore
  # di produzione che la matrice gli nega, restando sullo stesso canale e sullo stesso permesso.
  describe "confine ambienti per-utente (CYRA-666)" do
    let(:staging) { create(:environment, organization: org, code: "staging").tap { |e| project.environments << e } }
    let(:restricted_membership) { org.memberships.find_by!(account: member) }

    def denied_events(environment_scope)
      project.secret_events.where(action: "denied", channel: "web", environment: environment_scope)
    end

    before do
      staging
      create(:project_membership, account: member, project:)
      create(:account_permission, account: member, organization: org, permission_key: "secrets.read", effect: :allow)
      restricted_membership.update!(secret_environment_codes: [ "staging" ])
    end

    describe "GET reveal" do
      it "ambiente vietato -> 403, nessun valore in chiaro, evento denied" do
        secret = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "s3cr3t-plain").value
        version = secret.versions.first
        sign_in(member)

        expect do
          get reveal_member_project_secret_version_path(project, secret, version)
        end.to change { denied_events(environment).where(name: "API_KEY").count }.by(1)

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include("s3cr3t-plain")
      end

      it "ambiente consentito -> 200 col valore e nessun evento denied" do
        secret = Secrets::Variables::Set.call(project:, environment: staging, name: "API_KEY", value: "ok-plain").value
        version = secret.versions.first
        sign_in(member)

        expect do
          get reveal_member_project_secret_version_path(project, secret, version)
        end.not_to change { project.secret_events.where(action: "denied").count }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["value"]).to eq("ok-plain")
      end
    end

    describe "GET index" do
      it "storico di un ambiente vietato -> rimbalzo, nessuna versione resa" do
        secret = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "old").value
        sign_in(member)

        get member_project_secret_versions_path(project, secret)

        expect(response).to redirect_to(root_path)
      end

      it "storico di un ambiente consentito -> 200" do
        secret = Secrets::Variables::Set.call(project:, environment: staging, name: "API_KEY", value: "old").value
        sign_in(member)

        get member_project_secret_versions_path(project, secret)

        expect(response).to have_http_status(:ok)
      end
    end

    describe "POST rollback" do
      it "ripristino su un ambiente vietato -> rimbalzo e valore invariato" do
        create(:account_permission, account: member, organization: org, permission_key: "secrets.manage", effect: :allow)
        secret = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "old").value
        Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "new")
        old_version = secret.reload.versions.order(:number).first
        sign_in(member)

        post rollback_member_project_secret_version_path(project, secret, old_version), params: { confirm: "1" }

        expect(response).to redirect_to(root_path)
        expect(secret.reload.value).to eq("new")
      end
    end
  end

  # CYRA-721 — sullo storico vale la stessa separazione della matrice: la LISTA (numero, autore, data)
  # è un metadato e serve a chi gestisce per poter ripristinare; il VALORE di una versione è in chiaro,
  # quindi esce solo con `secrets.read`. Senza questa distinzione lo storico sarebbe la porta di servizio
  # verso il valore che la matrice nega.
  describe "lettura e gestione sono permessi distinti (CYRA-721)" do
    def grant(key)
      create(:account_permission, account: member, organization: org, permission_key: key, effect: :allow)
    end

    before { create(:project_membership, account: member, project:) }

    context "solo secrets.manage" do
      before { grant("secrets.manage") }

      it "vede la lista delle versioni (gli serve per ripristinare)" do
        secret = secret_with_history
        sign_in(member)

        get member_project_secret_versions_path(project, secret)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-test="versions-list"')
      end

      it "la pagina non offre nessun comando per mostrare un valore storico" do
        secret = secret_with_history
        sign_in(member)

        get member_project_secret_versions_path(project, secret)

        expect(response.body).not_to include('data-test="version-reveal-')
      end

      it "il reveal di una versione è respinto e il valore non esce" do
        secret = secret_with_history
        version = secret.versions.order(:number).first
        sign_in(member)

        expect do
          get reveal_member_project_secret_version_path(project, secret, version)
        end.not_to change { project.secret_events.where(action: "read").count }

        expect(response).to redirect_to(root_path)
        expect(response.body).not_to include("old")
      end
    end

    context "solo secrets.read" do
      before { grant("secrets.read") }

      it "vede la lista con il comando per mostrare e ottiene il valore storico" do
        secret = secret_with_history
        version = secret.versions.order(:number).first
        sign_in(member)

        get member_project_secret_versions_path(project, secret)
        expect(response.body).to include(%(data-test="version-reveal-#{version.id}"))

        get reveal_member_project_secret_version_path(project, secret, version)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["value"]).to eq("old")
      end

      it "non può ripristinare (il rollback resta di chi gestisce)" do
        secret = secret_with_history
        version = secret.versions.order(:number).first
        sign_in(member)

        post rollback_member_project_secret_version_path(project, secret, version)

        expect(response).to redirect_to(root_path)
        expect(secret.reload.value).to eq("new")
      end
    end
  end
end
