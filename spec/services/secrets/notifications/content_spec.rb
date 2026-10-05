# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::Content do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization, key: "STR") }
  let(:environment) { create(:environment, organization: organization, label: "Production").tap { |e| project.environments << e } }

  def variable_due_soon(days: 5)
    create(:secret_variable, project: project, environment: environment, name: "API_KEY",
                             rotation_interval_days: 14, rotated_at: Time.current - (14 - days).days)
  end

  def variable_overdue(days_ago: 3)
    create(:secret_variable, project: project, environment: environment, name: "API_KEY",
                             rotation_interval_days: 1, rotated_at: Time.current - (1 + days_ago).days)
  end

  describe ".for" do
    it "titolo con nome variabile, progetto e ambiente" do
      content = described_class.for(variable: variable_due_soon)
      expect(content.title).to include("API_KEY").and include(project.name).and include("Production")
    end

    it "MAI il valore del secret nel titolo" do
      variable = variable_due_soon
      expect(described_class.for(variable: variable).title).not_to include(variable.value)
    end

    it "due_soon → corpo con i giorni alla scadenza (stessa formula della pagina Cosa ruotare)" do
      variable = variable_due_soon(days: 5)
      content = described_class.for(variable: variable)
      expect(content.body).to eq(I18n.t("member.secrets.rotation_due_soon", days: variable.rotation_days_until_due))
    end

    it "overdue → corpo con i giorni di ritardo (stessa formula della pagina Cosa ruotare)" do
      variable = variable_overdue(days_ago: 3)
      content = described_class.for(variable: variable)
      expect(content.body).to eq(I18n.t("member.secrets.rotation_overdue", days: variable.rotation_days_until_due.abs))
    end

    it "MAI il valore del secret nel corpo" do
      variable = variable_overdue
      expect(described_class.for(variable: variable).body).not_to include(variable.value)
    end

    it "url punta alla pagina org-wide Cosa ruotare" do
      content = described_class.for(variable: variable_due_soon)
      expect(content.url).to eq(Rails.application.routes.url_helpers.member_vault_attention_path)
    end
  end

  describe ".for_deletion" do
    let(:actor) { create(:account, name: "Mario Rossi") }

    def content(actor: self.actor, name: "API_KEY", environment_label: "Production")
      described_class.for_deletion(project: project, name: name, environment_label: environment_label, actor: actor)
    end

    it "titolo con nome variabile, progetto, ambiente e attore" do
      expect(content.title).to include("API_KEY").and include(project.name)
                                                     .and include("Production").and include("Mario Rossi")
    end

    it "senza attore usa un'etichetta generica (mai un errore, mai nil interpolato)" do
      expect(content(actor: nil).title).to be_present
    end

    it "MAI il valore del secret nel titolo o nel corpo (la variabile è già distrutta: non arriva nemmeno come dato)" do
      c = content
      expect(c.title).not_to include("s3cr3t")
      expect(c.body).not_to include("s3cr3t")
    end

    it "il corpo non ripete il nome dell'attore (già nel titolo) ma resta presente" do
      expect(content.body).to be_present
    end

    it "url punta alla tab Secrets del progetto (dove viveva la variabile cancellata)" do
      expect(content.url).to eq(Rails.application.routes.url_helpers.member_project_secrets_path(project))
    end
  end

  describe ".for_sync_failure" do
    def content(reason: nil)
      described_class.for_sync_failure(project: project, reason: reason)
    end

    it "titolo con il nome del progetto" do
      expect(content.title).to include(project.name)
    end

    it "senza motivo: corpo generico presente" do
      expect(content.body).to be_present
    end

    it "con motivo: il corpo lo riporta (codice sintetico, mai un valore)" do
      expect(content(reason: "R502-GITHUB-001").body).to include("R502-GITHUB-001")
    end

    it "url punta alla tab GitHub del progetto" do
      expect(content.url).to eq(Rails.application.routes.url_helpers.member_project_github_path(project))
    end
  end
end
