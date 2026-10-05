# frozen_string_literal: true

require "rails_helper"

# CYRA-418 — chi apre l'area dei segreti vuole sapere se c'è qualcosa che non va, e trovava un numero
# senza contesto, righe di attività col trattino al posto dell'oggetto e una griglia di scorciatoie
# che copriva meno della metà delle voci — comprese proprio quelle dove le anomalie sono raccolte.
RSpec.describe "Member::Vault — la panoramica (CYRA-418)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org, name: "Storefront") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  # CYRA-930 — what is wrong is a column of the projects table, linked to the attention page.
  describe "what is wrong" do
    def anomalies_cell
      Nokogiri::HTML(response.body).at_css("[data-test='vault-row-#{project.id}'] [data-test='vault-cell-anomalies']")
    end

    it "counts the open anomalies of the project and links to the attention page" do
      create(:secret_health_anomaly, organization: org, project: project, resolved_at: nil, acknowledged_at: nil)

      get member_vault_path

      expect(anomalies_cell.at_css("[data-test='vault-cell-value']").text.strip).to eq("1")
      expect(anomalies_cell["href"]).to eq(member_vault_attention_path(kind: [ "anomaly" ], project_id: [ project.id ]))
    end

    # F146 — C14: the cell names the kinds it counts.
    it "says what kind of anomalies the project has" do
      # Rows are created in bulk: the N+1 belongs to the factory, not to the request under test.
      allow_n_plus_one do
        create_list(:secret_health_anomaly, 2, organization: org, project: project, kind: :empty_environment,
                                               resolved_at: nil, acknowledged_at: nil)
      end

      get member_vault_path

      expect(anomalies_cell.text).to include("2 environments with no secrets")
    end

    it "does not count an accepted anomaly again" do
      create(:secret_health_anomaly, organization: org, project: project, resolved_at: nil,
                                     acknowledged_at: 1.hour.ago)

      get member_vault_path

      expect(anomalies_cell.at_css("[data-test='vault-cell-value']").text.strip).to eq("0")
    end
  end

  # CYRA-430, Scenario 2 — «leggo quali collegamenti sono attivi e su quanti progetti».
  describe "i collegamenti automatici" do
    it "dice su quanti progetti la sincronizzazione con GitHub è accesa" do
      repository = create(:github_repository, project: project)
      repository.update_column(:synced_secret_names, { "production" => %w[DATABASE_URL] })

      get member_vault_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='vault-integration-github']")
      expect(riga).to be_present
      expect(riga.at_css("[data-test='vault-integration-status-github']").text).to include("1")
    end

    it "dice su quanti progetti i segreti si leggono da riga di comando" do
      create(:secret_event, organization: org, project: project, action: "read", metadata: { count: 2 })

      get member_vault_path

      stato = Nokogiri::HTML(response.body).at_css("[data-test='vault-integration-status-cli']")
      expect(stato.text).to include("1")
    end

    # Il rischio dichiarato dal ticket: meglio nessun dato che un dato falso.
    it "per direnv non mostra un numero, perché il sistema non può conoscerlo" do
      get member_vault_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='vault-integration-direnv']")
      expect(riga).to be_present
      expect(riga.text).not_to match(/\d/)
    end

    it "da ogni collegamento si arriva a come si attiva" do
      get member_vault_path

      doc = Nokogiri::HTML(response.body)
      %w[github cli direnv].each do |chiave|
        collegamento = doc.at_css("[data-test='vault-integration-how-#{chiave}']")
        expect(collegamento).to be_present, "il collegamento #{chiave} non dice come si attiva"
        expect(collegamento["href"]).to start_with(member_vault_capabilities_path)
      end
    end
  end
  # F148 — the Vault landing has no project in context: choosing one fills the commands.
  describe "the command block" do
    it "shows placeholders until a project is chosen, then the real project and environment" do
      staging = create(:environment, organization: org, code: "staging")
      project.environments << staging

      get member_vault_path
      expect(response.body).to include('data-test="secret-usage-picker"')
      expect(response.body).to include("cyi run -p &lt;project&gt; -e &lt;environment&gt;")

      get member_vault_path, params: { usage_project: project.key }
      expect(response.body).to include("cyi run -p #{project.key} -e staging")
    end
  end
end
