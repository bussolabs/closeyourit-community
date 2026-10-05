# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::PersonalSecrets", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before { create(:membership, account:, organization: org, role: :member) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def owned
    Secrets::Personal::Variable.for(account:, organization: org)
  end

  def owned_events
    Secrets::Personal::Event.for(account:, organization: org)
  end

  describe "autenticazione" do
    it "non autenticato → redirect login" do
      get member_personal_secrets_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET index" do
    it "mostra solo i miei secret dell'org (con chip conteggi)" do
      sign_in(account)
      create(:personal_secret_variable, account:, organization: org, name: "MY_KEY")
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)
      create(:personal_secret_variable, account: other, organization: org, name: "OTHER_KEY")

      get member_personal_secrets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("MY_KEY")
      expect(response.body).not_to include("OTHER_KEY")
      expect(response.body).to include('data-test="personal-secrets-counts"')
    end
  end

  # La paginazione delle variabili stava dentro il blocco delle attività: senza attività spariva, e
  # le variabili oltre la prima pagina non si raggiungevano più.
  # N4 — a placeholder disappears while typing and is not a name: each field of the add row has one.
  it "names the three fields of the add row for screen readers" do
    sign_in(account)
    get member_personal_secrets_path

    row = Capybara.string(response.body).find("[data-test='personal-secret-new-row']")
    %w[name value description].each do |field|
      expect(row.find("input[name='#{field}']")["aria-label"]).to be_present
    end
  end

  it "pagina le variabili anche quando non c'è nessuna attività" do
    sign_in(account)
    (Pagination::DEFAULT_PER + 1).times do |i|
      create(:personal_secret_variable, account:, organization: org, name: "KEY_#{i}")
    end
    owned_events.delete_all

    get member_personal_secrets_path

    table = Nokogiri::HTML(response.body).at_css("[data-test='personal-secrets-table']")
    expect(table.at_css("[data-test='personal-secrets-pagination']")).to be_present
  end

  # CYRA-204 — il valore in chiaro NON deve mai finire nel corpo HTML della pagina: il mascheramento
  # non può essere solo client-side (chi apre il sorgente lo leggerebbe senza mostrare né lasciare
  # traccia). Il valore si recupera solo via endpoint dedicato (GET reveal), che registra l'accesso.
  describe "GET index — nessun valore di secret nel corpo (CYRA-204)" do
    it "il valore in chiaro non compare da nessuna parte nella risposta" do
      sign_in(account)
      create(:personal_secret_variable, account:, organization: org, name: "API_KEY", value: "PLAINTEXT-CANARY-42")

      get member_personal_secrets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("API_KEY")
      expect(response.body).not_to include("PLAINTEXT-CANARY-42")
    end
  end

  describe "GET reveal (CYRA-204)" do
    it "owner → restituisce il valore in chiaro in JSON e registra l'accesso (audit read, source web)" do
      sign_in(account)
      secret = create(:personal_secret_variable, account:, organization: org, name: "API_KEY", value: "s3cr3t-plain")

      expect do
        get reveal_member_personal_secret_path(secret)
      end.to change { owned_events.where(action: "read").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("s3cr3t-plain")
      # Il valore in chiaro non deve persistere nella cache HTTP del browser.
      expect(response.headers["Cache-Control"]).to include("no-store")

      event = owned_events.where(action: "read").last
      expect(event.name).to eq("API_KEY")
      expect(event.metadata["source"]).to eq("web")
    end

    it "l'evento web compare nell'attività accanto alle letture da terminale (bundle)" do
      sign_in(account)
      secret = create(:personal_secret_variable, account:, organization: org, name: "API_KEY", value: "v")
      # Lettura da terminale (bundle CLI): registra un evento read source-less.
      Secrets::Personal::RecordEvent.call(action: "read", account:, organization: org, metadata: { count: 3 })

      get reveal_member_personal_secret_path(secret)
      get member_personal_secrets_path

      expect(response.body).to include('data-test="personal-secrets-activity"')
      expect(owned_events.where(action: "read").count).to eq(2)
    end

    it "non autenticato → redirect login, nessun valore esposto" do
      secret = create(:personal_secret_variable, account:, organization: org, value: "s3cr3t-plain")

      get reveal_member_personal_secret_path(secret)

      expect(response).to redirect_to(login_path)
      expect(response.body).not_to include("s3cr3t-plain")
    end

    # Anti-BOLA: il find fallisce PRIMA di leggere/registrare il valore → 404 e nessun evento (il valore
    # in chiaro non viene mai raggiunto). Non si asserisce sul body: la debug-page di test mostra il
    # sorgente del test stesso; in produzione la 404 è statica.
    it "secret di un altro account nella stessa org → 404 (anti-BOLA)" do
      sign_in(account)
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)
      foreign = create(:personal_secret_variable, account: other, organization: org, value: "plain")

      expect do
        get reveal_member_personal_secret_path(foreign)
      end.not_to(change { Secrets::Personal::Event.where(action: "read").count })

      expect(response).to have_http_status(:not_found)
    end

    it "secret di un'altra org → 404 (anti-BOLA)" do
      sign_in(account)
      other_org = create(:organization)
      create(:membership, account:, organization: other_org, role: :member)
      foreign = create(:personal_secret_variable, account:, organization: other_org, value: "plain")

      expect do
        get reveal_member_personal_secret_path(foreign)
      end.not_to(change { Secrets::Personal::Event.where(action: "read").count })

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create (upsert)" do
    it "crea la variabile → redirect" do
      sign_in(account)

      expect { post member_personal_secrets_path, params: { name: "api_key", value: "v1" } }
        .to change { owned.count }.by(1)

      expect(response).to redirect_to(member_personal_secrets_path)
      expect(owned.find_by(name: "API_KEY").value).to eq("v1")
    end

    it "fa upsert sullo stesso nome senza duplicare" do
      sign_in(account)
      create(:personal_secret_variable, account:, organization: org, name: "API_KEY", value: "old")

      post member_personal_secrets_path, params: { name: "API_KEY", value: "new" }

      expect(owned.where(name: "API_KEY").count).to eq(1)
      expect(owned.find_by(name: "API_KEY").value).to eq("new")
    end

    it "nome invalido → 422 e mostra l'errore" do
      sign_in(account)

      post member_personal_secrets_path, params: { name: "1BAD", value: "x" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(owned.count).to eq(0)
    end
  end

  describe "DELETE destroy" do
    it "elimina il mio secret → redirect" do
      sign_in(account)
      secret = create(:personal_secret_variable, account:, organization: org)

      delete member_personal_secret_path(secret)

      expect(response).to redirect_to(member_personal_secrets_path)
      expect(Secrets::Personal::Variable.exists?(secret.id)).to be(false)
    end

    it "secret di un altro account nella stessa org → 404 (anti-BOLA)" do
      sign_in(account)
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)
      foreign = create(:personal_secret_variable, account: other, organization: org)

      delete member_personal_secret_path(foreign)

      expect(response).to have_http_status(:not_found)
      expect(Secrets::Personal::Variable.exists?(foreign.id)).to be(true)
    end

    it "secret di un'altra org → 404 (anti-BOLA)" do
      sign_in(account)
      other_org = create(:organization)
      create(:membership, account:, organization: other_org, role: :member)
      foreign = create(:personal_secret_variable, account:, organization: other_org)

      delete member_personal_secret_path(foreign)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "versioni + rollback" do
    def secret_with_history
      Secrets::Personal::Variables::Set.call(account:, organization: org, name: "API_KEY", value: "old")
      Secrets::Personal::Variables::Set.call(account:, organization: org, name: "API_KEY", value: "new").value
    end

    it "GET index versioni → 200" do
      sign_in(account)
      secret = secret_with_history
      get member_personal_secret_versions_path(secret)
      expect(response).to have_http_status(:ok)
    end

    it "POST rollback ripristina il valore → redirect" do
      sign_in(account)
      secret = secret_with_history
      first = secret.versions.find_by(number: 1)

      post rollback_member_personal_secret_version_path(secret, first)

      expect(response).to redirect_to(member_personal_secret_versions_path(secret))
      expect(secret.reload.value).to eq("old")
    end

    it "versioni di un secret altrui → 404 (anti-BOLA)" do
      sign_in(account)
      foreign = create(:personal_secret_variable)
      get member_personal_secret_versions_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    # CYRA-204 — anche lo storico personale è una lettura dal sito: nessun valore storico nel sorgente
    # (aggirerebbe il reveal della lista) e ogni lettura on-demand lascia traccia.
    it "GET index versioni → nessun valore nel corpo" do
      sign_in(account)
      Secrets::Personal::Variables::Set.call(account:, organization: org, name: "API_KEY", value: "VER-CANARY-OLD")
      secret = Secrets::Personal::Variables::Set.call(account:, organization: org, name: "API_KEY", value: "VER-CANARY-NEW").value

      get member_personal_secret_versions_path(secret)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("VER-CANARY-OLD")
      expect(response.body).not_to include("VER-CANARY-NEW")
    end

    it "GET reveal versione → valore in JSON, audit read (source web) e no-store" do
      sign_in(account)
      secret = secret_with_history
      version = secret.versions.ordered.last # numero 1, valore "old"

      expect do
        get reveal_member_personal_secret_version_path(secret, version)
      end.to change { owned_events.where(action: "read").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("old")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(owned_events.where(action: "read").last.metadata["source"]).to eq("web")
    end

    it "GET reveal versione di un secret altrui → 404 (anti-BOLA)" do
      sign_in(account)
      foreign = create(:personal_secret_variable)
      Secrets::Personal::Variables::Set.call(account: foreign.account, organization: foreign.organization,
                                             name: foreign.name, value: "leaked")
      foreign_version = foreign.versions.ordered.first

      expect do
        get reveal_member_personal_secret_version_path(foreign, foreign_version)
      end.not_to(change { Secrets::Personal::Event.where(action: "read").count })

      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-422 — la protezione dei secret personali sta nel corpo, non più nel suggerimento del titolo.
  describe "GET index — protezione nel corpo (CYRA-422)" do
    it "mostra cifratura, visibilità solo tua, tracciamento e retention nel corpo, fuori dal tooltip" do
      sign_in(account)
      get member_personal_secrets_path

      expect(response.body).to include('data-test="secret-protection"')
      expect(response.body).to include('data-test="secret-protection-audit"')
      expect(response.body).to include('data-test="secret-protection-retention"')
      expect(response.body).to include(I18n.t("member.secret_protection.encryption.personal"))
      expect(response.body).not_to include(I18n.t("member.personal_secrets.help_title"))
    end
  end
end
