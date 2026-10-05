# frozen_string_literal: true

require "rails_helper"

# CYRA-77 — il registro degli accessi ai segreti di un progetto esisteva solo come coda delle ultime
# quindici righe in fondo alla matrice: chi doveva rispondere di «chi ha letto la chiave di produzione
# il mese scorso» non aveva dove guardare. Questa è la pagina che risponde, coi filtri che servono a
# restringere il campo (chi, che cosa, dove, quando).
RSpec.describe "Member::ProjectSecretEvents (CYRA-77)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:production) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }
  let(:staging) { create(:environment, organization: org, code: "staging").tap { |e| project.environments << e } }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def record(action:, name: nil, environment: nil, actor: nil, channel: nil, at: Time.current)
    Secrets::RecordEvent.call(action:, project:, environment:, actor:, name:, channel:)
    Secrets::Event.order(:created_at).last.tap { |event| event.update_column(:created_at, at) }
  end

  describe "shared secrets header" do
    it "shows the tabs, a one-line subtitle and no Vault button" do
      sign_in(owner)
      get member_project_secret_events_path(project)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-test='secrets-subnav-events'][aria-current='page']")).to be_present
      expect(document.at_css("[data-test='secret-audit-lead']")).to be_present
      expect(document.at_css("[data-test='secret-audit-vault-link']")).to be_nil
      expect(document.css("[data-test='member-project-secret-events'] h2").map(&:text)).not_to include(I18n.t("member.secret_audit.section_title"))
    end
  end

  describe "GET index" do
    it "elenca gli eventi del progetto dal più recente, col nome del secret e chi l'ha fatto" do
      record(action: "read", name: "API_KEY", environment: production, actor: owner, channel: "web",
             at: 1.hour.ago)
      record(action: "set", name: "DATABASE_URL", environment: production, actor: owner, at: 2.days.ago)
      sign_in(owner)

      get member_project_secret_events_path(project)

      expect(response).to have_http_status(:ok)
      righe = Nokogiri::HTML(response.body).css("[data-test='secret-audit-row']")
      expect(righe.size).to eq(2)
      expect(righe.first.text).to include("API_KEY").and include(owner.email)
      expect(righe.last.text).to include("DATABASE_URL")
    end

    it "non mostra gli eventi di un altro progetto" do
      altro = create(:project, organization: org)
      Secrets::RecordEvent.call(action: "read", project: altro, name: "ALTROVE", actor: owner)
      record(action: "read", name: "QUI", environment: production, actor: owner, channel: "web")
      sign_in(owner)

      get member_project_secret_events_path(project)

      expect(response.body).to include("QUI")
      expect(response.body).not_to include("ALTROVE")
    end

    it "il progetto di un'altra organizzazione → 404 (anti-BOLA)" do
      sign_in(owner)
      get member_project_secret_events_path(create(:project))
      expect(response).to have_http_status(:not_found)
    end

    # Il registro dice chi ha letto che cosa: è materiale per chi risponde dei segreti, non per chi
    # li usa e basta. Il gate è lo stesso che governa le modifiche al vault.
    it "chi vede il progetto ma non gestisce i segreti → redirect, nessun registro" do
      membro = create(:account)
      create(:membership, account: membro, organization: org, role: :member)
      create(:project_membership, account: membro, project:)
      record(action: "read", name: "API_KEY", environment: production, actor: owner, channel: "web")
      sign_in(membro)

      get member_project_secret_events_path(project)

      expect(response).to redirect_to(root_path)
      expect(response.body).not_to include("API_KEY")
    end

    it "senza eventi mostra lo stato vuoto" do
      production
      sign_in(owner)

      get member_project_secret_events_path(project)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='secret-audit-empty']")).to be_present
    end
  end

  describe "chip conteggi" do
    it "totale, letture e tentativi bloccati" do
      record(action: "read", name: "A", environment: production, actor: owner, channel: "web")
      record(action: "read", name: "B", environment: production, actor: owner, channel: "cli")
      record(action: "denied", name: "C", environment: production, actor: owner, channel: "web")
      sign_in(owner)

      get member_project_secret_events_path(project)

      chip = Nokogiri::HTML(response.body).at_css("[data-test='secret-audit-counts']").text
      expect(chip).to include("3").and include("2").and include("1")
    end
  end

  describe "filtri" do
    let(:altro_attore) { create(:account) }

    before { create(:membership, account: altro_attore, organization: org, role: :member) }

    it "per azione" do
      record(action: "read", name: "LETTO", environment: production, actor: owner, channel: "web")
      record(action: "set", name: "SCRITTO", environment: production, actor: owner)
      sign_in(owner)

      get member_project_secret_events_path(project, event_action: "read")

      expect(response.body).to include("LETTO")
      expect(response.body).not_to include("SCRITTO")
    end

    it "per ambiente" do
      record(action: "read", name: "IN_PROD", environment: production, actor: owner, channel: "web")
      record(action: "read", name: "IN_STAGING", environment: staging, actor: owner, channel: "web")
      sign_in(owner)

      get member_project_secret_events_path(project, environment_id: production.id)

      expect(response.body).to include("IN_PROD")
      expect(response.body).not_to include("IN_STAGING")
    end

    it "per attore, anche più di uno alla volta" do
      terzo = create(:account)
      create(:membership, account: terzo, organization: org, role: :member)
      record(action: "read", name: "DA_OWNER", environment: production, actor: owner, channel: "web")
      record(action: "read", name: "DA_ALTRO", environment: production, actor: altro_attore, channel: "web")
      record(action: "read", name: "DA_TERZO", environment: production, actor: terzo, channel: "web")
      sign_in(owner)

      get member_project_secret_events_path(project, actor_id: [ owner.id, altro_attore.id ])

      expect(response.body).to include("DA_OWNER").and include("DA_ALTRO")
      expect(response.body).not_to include("DA_TERZO")
    end

    it "per periodo (da / a)" do
      record(action: "read", name: "VECCHIO", environment: production, actor: owner, channel: "web",
             at: 10.days.ago)
      record(action: "read", name: "RECENTE", environment: production, actor: owner, channel: "web",
             at: 1.hour.ago)
      sign_in(owner)

      get member_project_secret_events_path(project, from: 2.days.ago.iso8601)

      expect(response.body).to include("RECENTE")
      expect(response.body).not_to include("VECCHIO")

      get member_project_secret_events_path(project, to: 5.days.ago.iso8601)

      expect(response.body).to include("VECCHIO")
      expect(response.body).not_to include("RECENTE")
    end

    it "filtri che non trovano nulla → messaggio dedicato, non lo stato vuoto" do
      record(action: "read", name: "API_KEY", environment: production, actor: owner, channel: "web")
      sign_in(owner)

      get member_project_secret_events_path(project, event_action: "deleted")

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='secret-audit-no-match']")).to be_present
      expect(doc.at_css("[data-test='secret-audit-empty']")).to be_nil
    end
  end

  # CYRA-78 — il nome di un secret di produzione è già un'informazione su produzione: chi è ristretto
  # a un ambiente non deve vedere nel registro nemmeno le righe degli ambienti che non gli spettano.
  describe "confine ambienti" do
    let(:ristretto) { create(:account) }

    before do
      create(:membership, account: ristretto, organization: org, role: :member)
      create(:project_membership, account: ristretto, project:)
      create(:account_permission, account: ristretto, organization: org,
                                  permission_key: "secrets.manage", effect: :allow)
      staging
      org.memberships.find_by!(account: ristretto).update!(secret_environment_codes: [ "staging" ])
    end

    it "le righe degli ambienti vietati non compaiono" do
      record(action: "read", name: "SOLO_PROD", environment: production, actor: owner, channel: "web")
      record(action: "read", name: "SU_STAGING", environment: staging, actor: owner, channel: "web")
      sign_in(ristretto)

      get member_project_secret_events_path(project)

      expect(response.body).to include("SU_STAGING")
      expect(response.body).not_to include("SOLO_PROD")
    end
  end

  # CYRA-924 — a register sorts on the date only, in both directions.
  describe "sorting" do
    def table_text = Nokogiri::HTML(response.body).css("tbody").text

    before do
      sign_in(owner)
      record(action: "set", name: "OLDER_KEY", at: 2.days.ago)
      record(action: "set", name: "NEWER_KEY", at: 1.hour.ago)
    end

    it "lists the oldest first when the date is sorted ascending" do
      get member_project_secret_events_path(project, sort: "occurred_at")

      expect(table_text.index("OLDER_KEY")).to be < table_text.index("NEWER_KEY")
    end

    it "lists the newest first when the date is sorted descending" do
      get member_project_secret_events_path(project, sort: "-occurred_at")

      expect(table_text.index("NEWER_KEY")).to be < table_text.index("OLDER_KEY")
    end

    it "offers the date as the only sortable column" do
      get member_project_secret_events_path(project)

      sortable = Nokogiri::HTML(response.body).css("thead a[data-test^='sort-']").map { |a| a["data-test"] }
      expect(sortable).to eq(%w[sort-occurred_at])
    end
  end

  # CYRA-924 — the counts line above the list says how many there are; the bar holds no count (C63).
  it "keeps the count out of the bar" do
    sign_in(owner)
    record(action: "set", name: "API_KEY")

    get member_project_secret_events_path(project)

    toolbar = Nokogiri::HTML(response.body).at_css("[data-test='secret-audit-toolbar']")
    expect(toolbar.text).not_to include(I18n.t("member.secret_audit.count", count: 1))
  end
end
