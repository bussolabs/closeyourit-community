# frozen_string_literal: true

require "rails_helper"

# I secret con la rotazione in scadenza o scaduta (CYRA-138, Fase 4 pezzo A1; copertura + età
# CYRA-407). Da CYRA-428 non hanno più una pagina propria: quelli da cambiare sono righe della lista
# unica di «Da sistemare», la copertura e i secret senza regola stanno nel contesto sotto quella
# lista. Questo indirizzo resta e ci porta. Gate invariato: secrets_audit.view sulla destinazione.
RSpec.describe "Member::Vault::Rotation", type: :request do
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

  def secret_with_rotation(name:, days:, rotated_at:, target_project: project, target_environment: environment)
    variable = Secrets::Variables::Set.call(project: target_project, environment: target_environment,
                                             name:, value: "v").value
    variable.update!(rotation_interval_days: days, rotated_at:)
    variable
  end

  # Segreto SENZA regola di rotazione: rotated_at (età del valore) valorizzato da Set, policy assente.
  def secret_without_rotation(name:, value_age_days: 0, target_project: project, target_environment: environment)
    variable = Secrets::Variables::Set.call(project: target_project, environment: target_environment,
                                             name:, value: "v").value
    variable.update!(rotated_at: Time.current - value_age_days.days)
    variable
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_vault_rotation_path
      expect(response).to redirect_to(login_path)
    end

    it "porta alla lista «Da sistemare»" do
      sign_in(owner)
      get member_vault_rotation_path

      expect(response).to redirect_to(member_vault_attention_path)
    end

    it "senza il permesso secrets_audit.view la destinazione resta chiusa" do
      sign_in(member)
      get member_vault_rotation_path
      follow_redirect!

      expect(response).to redirect_to(root_path)
    end
  end

  # Gli stessi scenari di CYRA-407, verificati dove la rotazione vive adesso.
  describe "la rotazione dentro «Da sistemare»" do
    it "owner senza alcun segreto → stato neutro 'nessun segreto', non un via libera" do
      sign_in(owner)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="vault-attention-rotation-empty"')
      expect(response.body).not_to include('data-test="vault-attention-rotation-onboarding"')
    end

    it "segreti presenti ma NESSUNA regola → onboarding 'non attiva', non 'niente da ruotare'" do
      sign_in(owner)
      secret_without_rotation(name: "OLD_SECRET", value_age_days: 120)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="vault-attention-rotation-onboarding"')
      # html_escape: il testo EN contiene virgolette, che nel body sono entità HTML.
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.vault_rotation.onboarding_body")))
      # il segreto senza regola è comunque visibile con la sua età, non nascosto dietro un falso verde
      expect(response.body).to include("OLD_SECRET")
      expect(response.body).to include('data-test="vault-attention-uncovered"')
    end

    it "dice quanti segreti una regola li copre davvero" do
      sign_in(owner)
      secret_without_rotation(name: "BARE", value_age_days: 10)

      get member_vault_attention_path

      expect(response.body).to include('data-test="vault-attention-rotation-coverage"')
    end

    # B3 — the coverage also sits among the page counts and jumps to its panel.
    it "repeats the coverage among the page counts, as a link to the rotation panel" do
      sign_in(owner)
      secret_without_rotation(name: "BARE", value_age_days: 10)

      get member_vault_attention_path

      count = Capybara.string(response.body).find("[data-test='vault-attention-counts'] [data-test='vault-attention-stat-rotation-coverage']")
      expect(count.text).to include("0 / 1")
      expect(count[:href]).to eq("#vault-attention-rotation")
    end

    it "copertura parziale → separa i segreti da cambiare da quelli senza regola" do
      sign_in(owner)
      secret_with_rotation(name: "OVERDUE", days: 1, rotated_at: Time.current - 2.days)
      secret_without_rotation(name: "NO_RULE", value_age_days: 200)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      lista = response.body[/data-test="vault-attention-list".*?<\/section>/m]
      expect(lista).to include("OVERDUE")                                       # da cambiare adesso
      expect(lista).not_to include("NO_RULE")
      expect(response.body).to include('data-test="vault-attention-uncovered"') # senza regola
      expect(response.body).to include("NO_RULE")
    end

    it "elenca un secret in scadenza e uno scaduto, lo scaduto per primo" do
      sign_in(owner)
      secret_with_rotation(name: "DUE_SOON", days: 14, rotated_at: Time.current)
      secret_with_rotation(name: "OVERDUE", days: 1, rotated_at: Time.current - 2.days)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("DUE_SOON", "OVERDUE")
      expect(response.body.index("OVERDUE")).to be < response.body.index("DUE_SOON")
    end

    it "anti-BOLA: i secret di un progetto non visibile all'utente non compaiono" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "secrets_audit.view" ], actor: owner
      )
      visible_project = create(:project, organization: org, name: "Progetto Visibile")
      create(:project_membership, account: member, project: visible_project)

      hidden_project = create(:project, organization: org, name: "Progetto Nascosto")
      hidden_env = create(:environment, organization: org, code: "hidden_env").tap { |e| hidden_project.environments << e }
      secret_with_rotation(name: "HIDDEN_OVERDUE", days: 1, rotated_at: Time.current - 2.days,
                            target_project: hidden_project, target_environment: hidden_env)
      sign_in(member)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Progetto Nascosto")
      expect(response.body).not_to include("HIDDEN_OVERDUE")
      # il member non vede alcun segreto: stato neutro, mai il falso verde
      expect(response.body).to include('data-test="vault-attention-rotation-empty"')
    end
  end
end
