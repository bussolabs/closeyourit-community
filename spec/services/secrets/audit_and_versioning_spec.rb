require "rails_helper"

# Emissione degli eventi audit (Secrets::Event) + snapshot delle versioni dai service di mutazione.
RSpec.describe "Secrets audit + versioning" do
  let(:project) { create(:project) }
  let(:environment) do
    create(:environment, organization: project.organization).tap { |env| project.environments << env }
  end
  let(:actor) { create(:account) }

  def set(name, value, **opts)
    Secrets::Variables::Set.call(project:, environment:, name:, value:, actor:, **opts)
  end

  describe "Secrets::Variables::Set" do
    it "registra un evento 'set' e crea la versione 1" do
      expect { set("A", "1") }.to change { project.secret_events.where(action: "set").count }.by(1)

      variable = project.secret_variables.find_by(name: "A")
      expect(variable.versions.count).to eq(1)
      expect(variable.versions.first.value).to eq("1")
    end

    it "NON crea una nuova versione se il plaintext non cambia" do
      set("A", "1")
      variable = project.secret_variables.find_by(name: "A")
      expect { set("A", "1") }.not_to change { variable.versions.count }
    end

    it "crea una nuova versione se il plaintext cambia" do
      set("A", "1")
      variable = project.secret_variables.find_by(name: "A")
      expect { set("A", "2") }.to change { variable.versions.count }.by(1)
    end
  end

  describe "Secrets::Variables::Delete" do
    it "registra un evento 'deleted' col nome del secret" do
      variable = set("A", "1", audit: false).value
      expect { Secrets::Variables::Delete.call(variable:, actor:) }
        .to change { project.secret_events.where(action: "deleted", name: "A").count }.by(1)
    end
  end

  describe "Secrets::Variables::Import" do
    let(:entries) { [ { name: "A", value: "1" }, { name: "B", value: "2" } ] }

    it "registra UN solo evento 'imported' (mai uno 'set' per voce)" do
      expect { Secrets::Variables::Import.call(project:, environment:, entries:, actor:) }
        .to change { project.secret_events.where(action: "imported").count }.by(1)

      expect(project.secret_events.where(action: "set").count).to eq(0)
      expect(project.secret_events.find_by(action: "imported").metadata["count"]).to eq(2)
    end

    it "crea una versione per ciascun secret importato" do
      Secrets::Variables::Import.call(project:, environment:, entries:, actor:)
      expect(Secrets::Version.where(secret_variable: project.secret_variables).count).to eq(2)
    end
  end
end
