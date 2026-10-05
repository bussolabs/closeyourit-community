# frozen_string_literal: true

require "rails_helper"

# «Valore in comune» (CYRA-777): la pagina che elenca cosa sta per succedere e il gesto che lo fa
# succedere. Le due cose da provare qui sono il confine (chi non tiene i secret dell'organizzazione
# non entra, e non vede nemmeno le proposte di un'altra organizzazione) e la conferma, che deve
# reggere anche quando il mondo cambia sotto la pagina.
RSpec.describe "Member::Vault::Consolidations", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:production) { create(:environment, organization: org, code: "production", label: "Production") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def progetto(nome)
    create(:project, organization: org, name: nome).tap { |project| project.environments << production }
  end

  let(:uno) { progetto("uno") }
  let(:due) { progetto("due") }

  def proposta(valore: "valore-condiviso-lungo")
    Secrets::Variables::Set.call(project: uno, environment: production, name: "API_KEY", value: valore)
    Secrets::Variables::Set.call(project: due, environment: production, name: "CHIAVE_API", value: valore)
    Secrets::Consolidation::Refresh.call(organization: org)
    Secrets::Consolidation::Suggestion.last
  end

  def digest_of(suggestion) = Secrets::Consolidation::Impact.call(suggestion:).value["digest"]

  describe "GET show" do
    it "non autenticato → redirect login" do
      get member_vault_consolidation_path(proposta)

      expect(response).to redirect_to(login_path)
    end

    it "senza il permesso sui secret dell'organizzazione non si entra" do
      suggestion = proposta
      sign_in(member)

      get member_vault_consolidation_path(suggestion)

      expect(response).to have_http_status(:found)
    end

    it "mostra cosa sparisce da ogni progetto e con che nome lo leggerà" do
      suggestion = proposta
      sign_in(owner)

      get member_vault_consolidation_path(suggestion)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("uno", "due", "API_KEY", "CHIAVE_API")
      expect(response.body).to include("vault-consolidation-promote")
    end

    it "non rende mai il valore" do
      suggestion = proposta
      sign_in(owner)

      get member_vault_consolidation_path(suggestion)

      expect(response.body).not_to include("valore-condiviso-lungo")
    end

    # Anti-BOLA: una proposta di un'altra organizzazione non esiste, non è vietata.
    #
    # All'owner NON si dà una membership nell'altra organizzazione, e non è una svista:
    # `set_current_organization` (app/controllers/concerns/organization_context.rb:29-33) ripiega su
    # `memberships.first`, che senza un ordinamento esplicito segue l'ordine del database. Con due
    # membership, quale delle due organizzazioni risulti attiva cambia da una macchina all'altra: in
    # locale usciva 404, in CI 200 — e il 200 era corretto, perché lì la proposta era davvero di casa.
    it "una proposta di un'altra organizzazione è un 404" do
      altra = create(:organization)
      estranea = Secrets::Consolidation::Suggestion.create!(
        organization: altra, environment: create(:environment, organization: altra),
        value_fingerprint: "x" * 64, suggested_name: "API_KEY", projects_count: 2,
        first_seen_at: Time.current, last_seen_at: Time.current
      )
      sign_in(owner)

      get member_vault_consolidation_path(estranea)

      expect(response).to have_http_status(:not_found)
    end

    it "dice che non c'è più niente da spostare quando il valore non è più ripetuto" do
      suggestion = proposta
      Secrets::Variable.find_by(project: due).update!(value: "un-altro-valore-lungo")
      sign_in(owner)

      get member_vault_consolidation_path(suggestion)

      expect(response.body).to include("vault-consolidation-gone")
      expect(response.body).not_to include("vault-consolidation-promote")
    end
  end

  describe "POST promote" do
    it "sposta il valore e riporta alla lista" do
      suggestion = proposta
      sign_in(owner)

      # Le query ripetute qui sono N SCRITTURE, non N letture per una lista: ogni delega creata
      # verifica di non collidere col nome effettivo di un'altra: è la stessa query che qualunque
      # `validates :uniqueness` fa una volta per record. Il gesto è manuale e tocca i pochi progetti
      # elencati nella pagina di conferma.
      allow_n_plus_one do
        post promote_member_vault_consolidation_path(suggestion),
             params: { confirm: 1, confirmation_digest: digest_of(suggestion), name: "API_KEY" }
      end

      expect(response).to redirect_to(member_vault_attention_path)
      expect(suggestion.reload).to be_status_promoted
      expect(Secrets::Bundle.call(project: due, environment: production).value)
        .to eq("CHIAVE_API" => "valore-condiviso-lungo")
    end

    # CYRA-728: la chiave shared_secrets.manage è pericolosa, quindi la scrittura pretende il gesto
    # di conferma anche quando il digest c'è.
    it "senza il parametro di conferma non scrive" do
      suggestion = proposta
      sign_in(owner)

      post promote_member_vault_consolidation_path(suggestion),
           params: { confirmation_digest: digest_of(suggestion) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(suggestion.reload).to be_status_open
    end

    it "con la conferma obsoleta torna sulla pagina senza spostare niente" do
      suggestion = proposta
      sign_in(owner)

      post promote_member_vault_consolidation_path(suggestion),
           params: { confirm: 1, confirmation_digest: "vecchio" }

      expect(response).to redirect_to(member_vault_consolidation_path(suggestion))
      expect(suggestion.reload).to be_status_open
      expect(Secrets::Variable.where(project: [ uno, due ]).count).to eq(2)
    end

    it "senza il permesso non scrive" do
      suggestion = proposta
      digest = digest_of(suggestion)
      sign_in(member)

      post promote_member_vault_consolidation_path(suggestion),
           params: { confirm: 1, confirmation_digest: digest }

      expect(suggestion.reload).to be_status_open
    end
  end

  describe "POST dismiss" do
    it "archivia la proposta, che non torna al giro dopo" do
      suggestion = proposta
      sign_in(owner)

      post dismiss_member_vault_consolidation_path(suggestion), params: { confirm: 1 }

      expect(response).to redirect_to(member_vault_attention_path)
      expect(suggestion.reload).to be_status_dismissed
      expect(suggestion.dismissed_by).to eq(owner)

      Secrets::Consolidation::Refresh.call(organization: org)
      expect(suggestion.reload).to be_status_dismissed
    end
  end

  describe "la riga in «Da sistemare»" do
    it "compare per chi tiene i secret dell'organizzazione" do
      proposta
      sign_in(owner)

      get member_vault_attention_path

      expect(response.body).to include("vault-attention-stat-consolidation")
      expect(response.body).to include(member_vault_consolidation_path(Secrets::Consolidation::Suggestion.last))
    end

    it "non compare per chi non può accettarla" do
      proposta
      sign_in(member)

      get member_vault_attention_path

      expect(response.body).not_to include("vault-attention-stat-consolidation")
    end
  end
end
