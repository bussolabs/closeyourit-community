# frozen_string_literal: true

require "rails_helper"

# Pagina Audit del Vault (CYRA-135): elenco navigabile e filtrabile degli eventi sui secret org-scoped,
# gated dal permesso org-level secrets_audit.view. Sostituisce la lettura "Recent activity" cap 15 inline.
RSpec.describe "Member::Vault::Audit", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_vault_audit_path
      expect(response).to redirect_to(login_path)
    end

    it "senza il permesso secrets_audit.view → redirect (forbidden)" do
      sign_in(member)
      get member_vault_audit_path
      expect(response).to redirect_to(root_path)
    end

    it "owner → 200 e vede un evento di audit" do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "set", name: "API_KEY")

      get member_vault_audit_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("API_KEY")
    end

    # A read in production is not a read in staging: every row names its environment.
    it "names the environment of each event" do
      sign_in(owner)
      production = create(:environment, organization: org, label: "Production")
      project.environments << production
      create(:secret_event, project: project, organization: org, environment: production, action: "set", name: "API_KEY")

      get member_vault_audit_path

      cell = Capybara.string(response.body).find("[data-test='vault-audit-row'] [data-test='vault-audit-environment']")
      expect(cell.text.strip).to eq("Production")
    end

    # F173 — the row says the detail the event carries: where it came from and which version.
    it "says where an event came from and which version it left" do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "set", name: "API_KEY",
                            channel: "cli", metadata: { version: 5 })
      create(:secret_event, project: project, organization: org, action: "set", name: "PLAIN", channel: nil, metadata: {})

      get member_vault_audit_path

      details = Capybara.string(response.body).all("[data-test='vault-audit-detail']").map { |detail| detail.text.strip }
      expect(details).to eq([ "from the command line · version 5" ])
    end

    # La lettura di un ambiente intero da riga di comando non ha un nome: la cella diceva solo «—».
    it "una lettura senza nome dice quanti secret sono usciti invece del trattino" do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "read", name: nil,
                            metadata: { count: 12 })

      get member_vault_audit_path

      expect(response.body).to include("Whole environment (12)")
    end

    it "filtra per azione" do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "set", name: "SETVAR")
      create(:secret_event, project: project, organization: org, action: "read", name: "READVAR")

      get member_vault_audit_path(event_action: "set")

      expect(response.body).to include("SETVAR")
      expect(response.body).not_to include("READVAR")
    end

    # CYRA-78 — i tentativi fermati dal confine ambienti entrano nel registro come gli altri eventi,
    # con un verbo proprio (mai il nome inglese dell'azione) e filtrabili.
    it "mostra e filtra i tentativi bloccati" do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "denied", name: "NEGATA", channel: "web")
      create(:secret_event, project: project, organization: org, action: "set", name: "SETVAR")

      get member_vault_audit_path(event_action: "denied")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("NEGATA")
      expect(response.body).to include(I18n.t("member.secrets.actions.denied"))
      expect(response.body).not_to include("SETVAR")
    end

    it "owner senza eventi → 200 con stato vuoto" do
      sign_in(owner)

      get member_vault_audit_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.vault_audit.empty"))
    end

    it "una pagina oltre il limite resta valida (torna all'ultima)" do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "set", name: "SOLO")

      get member_vault_audit_path(page: 999)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("SOLO")
    end
  end

  describe "vista salvata (secret_events)" do
    it "salva una vista dell'audit e reindirizza alla pagina Attivita (INDEX_HELPERS mappato)" do
      sign_in(owner)

      post member_saved_views_path, params: {
        resource_type: "secret_events", name: "Solo modifiche", event_action: "set"
      }

      expect(response).to redirect_to(member_vault_audit_path(event_action: "set"))
    end
  end

  # CYRA-924 — a register sorts on the date only, in both directions.
  describe "sorting" do
    def table_text = Nokogiri::HTML(response.body).css("tbody").text

    before do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "set", name: "OLDER_KEY", created_at: 2.days.ago)
      create(:secret_event, project: project, organization: org, action: "set", name: "NEWER_KEY", created_at: 1.hour.ago)
    end

    it "lists the oldest first when the date is sorted ascending" do
      get member_vault_audit_path(sort: "occurred_at")

      expect(table_text.index("OLDER_KEY")).to be < table_text.index("NEWER_KEY")
    end

    it "offers the date as the only sortable column" do
      get member_vault_audit_path

      sortable = Nokogiri::HTML(response.body).css("thead a[data-test^='sort-']").map { |a| a["data-test"] }
      expect(sortable).to eq(%w[sort-occurred_at])
    end
  end
end
