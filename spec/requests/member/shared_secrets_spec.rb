# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member shared secrets", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:env_prod) { create(:environment, organization:, code: "production") }
  let(:env_stg) { create(:environment, organization:, code: "staging") }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    create(:membership, account: member, organization:, role: :member)
  end

  def sign_in(account) = post(login_path, params: { email: account.email, password: "Secret123!" })

  def shared_variable(name = "API_KEY") = organization.shared_secret_variables.find_by(name:)

  it "mostra la matrice all'owner e la nega a chi non ha il permesso" do
    sign_in(owner)
    get member_shared_secrets_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("shared-secrets-header")
    expect(response.body).to include("shared-secret-new-row")

    sign_in(member)
    get member_shared_secrets_path
    expect(response).to redirect_to(root_path)
  end

  it "crea una variabile su più ambienti (riga) senza riportare i valori nella risposta" do
    sign_in(owner)
    post member_shared_secrets_path, params: { confirm: "1",
      name: "api_key", values: { env_prod.id => "prod-secret", env_stg.id => "" }
    }

    expect(response).to redirect_to(member_shared_secrets_path)
    expect(response.body).not_to include("prod-secret")
    expect(shared_variable.values.map(&:environment_id)).to contain_exactly(env_prod.id)
    expect(shared_variable.values.first.value).to eq("prod-secret")
  end

  it "shows a validation error when all environment values are blank" do
    sign_in(owner)
    post member_shared_secrets_path, params: { confirm: "1", name: "api_key", values: { env_prod.id => "", env_stg.id => "  " } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t("member.review_fixes.secret_value_required"))
    expect(Secrets::Shared::Variable.where(organization:)).to be_empty
  end

  it "con nome vuoto e un valore → 422 e la riga-crea mostra l'errore (non ri-nascosta)" do
    sign_in(owner)
    post member_shared_secrets_path, params: { confirm: "1", name: "", values: { env_prod.id => "v" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(Secrets::Shared::Variable.where(organization:)).to be_empty
    # @open_row è vuoto: l'errore va comunque attribuito alla riga-crea, che deve mostrarlo
    # (data-test reso solo con errors presente) invece di tornare hidden.
    expect(response.body).to include("shared-secret-new-error")
  end

  it "ignora un ambiente di un'altra organizzazione nei parametri (anti-BOLA)" do
    foreign_environment = create(:environment)
    sign_in(owner)

    post member_shared_secrets_path, params: { confirm: "1",
      name: "api_key", values: { env_prod.id => "prod-secret", foreign_environment.id => "leak" }
    }

    expect(response).to redirect_to(member_shared_secrets_path)
    expect(shared_variable.values.map(&:environment_id)).to contain_exactly(env_prod.id)
  end

  it "chiede conferma d'impatto quando si ruota un valore delegato, poi applica col digest" do
    project = create(:project, organization:)
    create(:project_environment, project:, environment: env_prod)
    shared = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "api_key", value: "one").value
    Secrets::Shared::Delegate.call(shared_value: shared, project:)
    sign_in(owner)

    post member_shared_secrets_path, params: { confirm: "1", name: "api_key", values: { env_prod.id => "two" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("shared-secret-impact")
    expect(shared.reload.value).to eq("one")

    digest = Secrets::Shared::RowImpact.call(shared_values: [ shared ]).value["digest"]
    post member_shared_secrets_path, params: { confirm: "1", name: "api_key", values: { env_prod.id => "two" }, confirmation_digest: digest }
    expect(response).to redirect_to(member_shared_secrets_path)
    expect(shared.reload.value).to eq("two")
  end

  it "impedisce BOLA nell'anteprima d'impatto" do
    foreign = create(:organization)
    foreign_environment = create(:environment, organization: foreign)
    foreign_value = Secrets::Shared::Save.call(organization: foreign, environment: foreign_environment,
                                                name: "TOKEN", value: "secret").value
    sign_in(owner)
    post impact_member_shared_secret_path(foreign_value.shared_variable), params: { confirm: "1", value_id: foreign_value.id, effect: "rotate" }
    expect(response).to have_http_status(:not_found)
  end

  # CYRA-202 — il valore in chiaro NON deve mai finire nel corpo HTML della matrice: il mascheramento
  # non può essere solo client-side. Il valore si recupera solo via endpoint dedicato (GET reveal), che
  # registra l'accesso.
  it "la matrice non contiene il valore in chiaro nel corpo (CYRA-202)" do
    Secrets::Shared::Save.call(organization:, environment: env_prod, name: "api_key", value: "SHARED-CANARY-99")
    sign_in(owner)

    get member_shared_secrets_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("SHARED-CANARY-99")
  end

  describe "GET reveal (CYRA-202)" do
    it "owner → restituisce il valore in chiaro in JSON e registra l'accesso (audit revealed)" do
      shared = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "api_key", value: "shared-plain").value
      sign_in(owner)

      expect do
        get reveal_member_shared_secret_path(shared.shared_variable, value_id: shared.id)
      end.to change { organization.shared_secret_events.where(action: "revealed", name: "API_KEY").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("shared-plain")
      # Il valore in chiaro non deve persistere nella cache HTTP del browser.
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "membro senza shared_secrets.manage → redirect (forbidden), nessun valore esposto" do
      shared = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "api_key", value: "shared-plain").value
      sign_in(member)

      get reveal_member_shared_secret_path(shared.shared_variable, value_id: shared.id)

      expect(response).to redirect_to(root_path)
      expect(response.body).not_to include("shared-plain")
    end

    it "value di un'altra organizzazione → 404 (anti-BOLA)" do
      foreign = create(:organization)
      foreign_environment = create(:environment, organization: foreign)
      foreign_value = Secrets::Shared::Save.call(organization: foreign, environment: foreign_environment,
                                                 name: "TOKEN", value: "secret").value
      sign_in(owner)

      get reveal_member_shared_secret_path(foreign_value.shared_variable, value_id: foreign_value.id)

      expect(response).to have_http_status(:not_found)
    end

    it "value_id non appartenente alla variabile richiesta → 404 (anti-BOLA)" do
      Secrets::Shared::Save.call(organization:, environment: env_prod, name: "api_key", value: "one")
      other = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "other_key", value: "two").value
      sign_in(owner)

      get reveal_member_shared_secret_path(shared_variable("API_KEY"), value_id: other.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  it "ripristina una versione di un valore delegato con il digest di rollback" do
    project = create(:project, organization:)
    create(:project_environment, project:, environment: env_prod)
    shared = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "API_KEY", value: "one").value
    Secrets::Shared::Delegate.call(shared_value: shared, project:)
    rotation_digest = Secrets::Shared::Impact.call(shared_value: shared, effect: :rotate).value["digest"]
    Secrets::Shared::Save.call(organization:, shared_variable: shared.shared_variable, environment: env_prod,
                               name: shared.name, value: "two", confirmation_digest: rotation_digest)
    previous = shared.versions.find_by!(number: 1)
    rollback_digest = Secrets::Shared::Impact.call(shared_value: shared, effect: :rollback).value["digest"]
    sign_in(owner)

    patch member_shared_secret_version_path(shared.shared_variable, previous),
          params: { confirm: "1", confirmation_digest: rollback_digest }

    expect(response).to redirect_to(member_shared_secrets_path)
    expect(shared.reload.value).to eq("one")
    expect(Secrets::Shared::Event.where(action: "rolled_back", shared_variable: shared.shared_variable)).to exist
  end

  # CYRA-416: la matrice deve spiegare la delega nel corpo e confermare la revoca nominando
  # progetto, segreto ed effetto immediato; la revoca (reversibile) non deve avere lo stile
  # distruttivo riservato all'eliminazione della variabile.
  describe "CYRA-416: chiarezza delega e conferma revoca" do
    def delegated_value
      project = create(:project, organization:)
      create(:project_environment, project:, environment: env_prod)
      shared = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "API_KEY", value: "one").value
      Secrets::Shared::Delegate.call(shared_value: shared, project:)
      [ shared, project ]
    end

    it "spiega cosa significa delegare in una riga sempre visibile del corpo" do
      sign_in(owner)
      get member_shared_secrets_path

      help = Nokogiri::HTML(response.body).at_css("[data-test='shared-secrets-delegation-help']")
      expect(help).to be_present
      expect(help.text).to include(I18n.t("member.shared_secrets.delegation_help"))
    end

    it "revoking a delegation asks in a dialog that names the project, the secret and the immediate effect" do
      _shared, project = delegated_value
      sign_in(owner)
      get member_shared_secrets_path

      button = Nokogiri::HTML(response.body).at_css("[data-test^='shared-secret-unlink-']")
      expect(button["data-action"]).to eq("ui--dialog#open")
      dialog = button.ancestors("[data-controller='ui--dialog']").first.at_css("dialog")
      expect(dialog.at_css("form input[name='confirmation_digest']")).to be_present
      confirm = dialog.text
      expect(confirm).to include(project.name)
      expect(confirm).to include("API_KEY")
      expect(confirm).to include(I18n.t("member.shared_secrets.unlink_effect"))
    end

    it "la revoca della delega non usa lo stile distruttivo, l'eliminazione della variabile sì" do
      delegated_value
      sign_in(owner)
      get member_shared_secrets_path

      doc = Nokogiri::HTML(response.body)
      unlink = doc.at_css("[data-test^='shared-secret-unlink-']")
      delete = doc.at_css("[data-test='shared-secret-delete-api_key']")
      expect(unlink["class"]).not_to include("red-600")
      expect(delete["class"]).to include("red-600")
    end
  end

  # CYRA-426 — la lista delle attività scriveva il verbo così com'è registrato («Created», «Rotated»):
  # metà frase in inglese proprio dove la persona deve verificare cosa è successo ai propri secret.
  describe "le attività si leggono in italiano" do
    before do
      owner.update!(locale: "it")
      Secrets::Shared::Event.create!(
        organization:, action: "created", name: "API_KEY", actor: owner, created_at: 3.hours.ago
      )
    end

    it "scrive il verbo in italiano e mette data e ora esatte nel tooltip del tempo" do
      sign_in(owner)
      get member_shared_secrets_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='shared-secret-event']")
      expect(riga.text).to include("Creato").and include("ore fa")
      expect(riga.text).not_to include("Created")
      expect(riga.at_css("span[title]")["title"]).to match(%r{\d{2}/\d{2}/\d{4}})
    end
  end

  # CYRA-422 — protezione nel corpo e chi può gestire/leggere i segreti dell'organizzazione, con nomi e ruoli.
  describe "GET index — protezione e chi può vederli (CYRA-422)" do
    it "mostra la protezione e chi può gestire i segreti dell'organizzazione, con nomi e ruoli" do
      sign_in(owner)
      get member_shared_secrets_path

      expect(response.body).to include('data-test="secret-protection"')
      expect(response.body).to include(I18n.t("member.secret_protection.retention"))
      expect(response.body).to include('data-test="secret-readers-list"')
      expect(response.body).to include(ERB::Util.html_escape(owner.name))
      expect(response.body).to include(I18n.t("member.roles.owner"))
    end
  end

  # CYRA-924 — every older version restores through its own dialog, kept outside the ⋯ menu (F16, C77).
  describe "restore confirmation (dialog)" do
    it "gives each older version a dialog outside the menu, opened from the menu item" do
      Secrets::Shared::Save.call(organization:, environment: env_prod, name: "API_KEY", value: "one")
      shared = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "API_KEY", value: "two").value
      old = shared.versions.min_by(&:number)
      sign_in(owner)

      get member_shared_secrets_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog#shared-secret-rollback-dialog-#{old.id}")
      expect(dialog.ancestors("details")).to be_empty
      expect(dialog.text).to include(I18n.t("member.shared_secrets.rollback_dialog.title", number: old.number, name: "API_KEY", environment: env_prod.label))
      form = dialog.at_css("form")
      expect(form["action"]).to eq(member_shared_secret_version_path(shared.shared_variable, old))
      expect(form.at_css("input[name='_method']")["value"]).to eq("patch")
      expect(form.at_css("input[name='confirmation_digest']")).to be_present
      trigger = html.at_css("[data-test='shared-secret-rollback-#{old.id}']")
      expect(trigger["data-ui--dialog-dialog-param"]).to eq("shared-secret-rollback-dialog-#{old.id}")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
