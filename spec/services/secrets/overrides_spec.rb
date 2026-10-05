# frozen_string_literal: true

require "rails_helper"

# CYRA-79 — i valori su misura: chi gestisce il vault assegna a UNA persona un valore diverso dal
# default, e quella persona se lo ritrova senza fare nulla.
RSpec.describe "Secrets::Overrides" do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:reader) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:production) do
    create(:environment, organization: org, code: "production").tap { |e| project.environments << e }
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    # Il destinatario dev'essere una persona che quei secret li può già leggere: membro dell'org,
    # collegato al progetto, con secrets.read concesso (stessa gerarchia di Secrets::Readers).
    create(:membership, account: reader, organization: org, role: :member)
    create(:project_membership, account: reader, project:)
    create(:account_permission, account: reader, organization: org, permission_key: "secrets.read", effect: :allow)
  end

  describe Secrets::Overrides::Set do
    it "assegna il valore alla persona indicata, con l'admin come autore" do
      result = described_class.call(project:, environment: production, account: reader,
                                    name: "database_url", value: "postgres://mio", actor: owner)

      expect(result).to be_ok
      override = result.value
      expect(override.name).to eq("DATABASE_URL")
      expect(override.value).to eq("postgres://mio")
      expect(override.account).to eq(reader)
      expect(override.created_by).to eq(owner)
      expect(override.organization).to eq(org)
    end

    it "aggiorna il valore se la persona ha già quell'override, senza crearne un secondo" do
      described_class.call(project:, environment: production, account: reader, name: "API_KEY", value: "uno", actor: owner)
      described_class.call(project:, environment: production, account: reader, name: "API_KEY", value: "due", actor: owner)

      expect(Secrets::Override.where(project:, environment: production, account: reader, name: "API_KEY").count).to eq(1)
      expect(Secrets::Override.find_by(project:, account: reader, name: "API_KEY").value).to eq("due")
    end

    it "registra nel registro chi ha assegnato e a chi" do
      described_class.call(project:, environment: production, account: reader, name: "API_KEY", value: "v", actor: owner)

      event = project.secret_events.find_by(action: "override_set")
      expect(event.actor).to eq(owner)
      expect(event.name).to eq("API_KEY")
      expect(event.metadata["target_account_id"]).to eq(reader.id)
    end

    # Un override non deve MAI far partire una scrittura verso GitHub: il push porta i default.
    it "non enfila alcuna sincronizzazione verso GitHub" do
      expect(Secrets::Github::SyncJob).not_to receive(:perform_later)

      described_class.call(project:, environment: production, account: reader, name: "API_KEY", value: "v", actor: owner)
    end

    it "rifiuta un destinatario che non può leggere i secret del progetto" do
      estraneo = create(:account)
      create(:membership, account: estraneo, organization: org, role: :member)
      create(:project_membership, account: estraneo, project:)

      result = described_class.call(project:, environment: production, account: estraneo,
                                    name: "API_KEY", value: "v", actor: owner)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-006")
      expect(Secrets::Override.count).to be_zero
    end

    it "rifiuta un destinatario assente" do
      result = described_class.call(project:, environment: production, account: nil,
                                    name: "API_KEY", value: "v", actor: owner)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-006")
    end

    it "rifiuta un nome fuori formato" do
      result = described_class.call(project:, environment: production, account: reader,
                                    name: "non valido", value: "v", actor: owner)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-005")
    end

    it "conserva la stringa vuota come valore esplicito" do
      result = described_class.call(project:, environment: production, account: reader,
                                    name: "OPTIONAL_FLAG", value: "", actor: owner)

      expect(result).to be_ok
      expect(result.value.value).to eq("")
    end
  end

  describe Secrets::Overrides::Delete do
    it "toglie l'override e lo registra con il destinatario" do
      override = Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                              name: "API_KEY", value: "v", actor: owner).value

      result = described_class.call(override:, actor: owner)

      expect(result).to be_ok
      expect(Secrets::Override.count).to be_zero
      event = project.secret_events.find_by(action: "override_deleted")
      expect(event.actor).to eq(owner)
      expect(event.name).to eq("API_KEY")
      expect(event.metadata["target_account_id"]).to eq(reader.id)
    end

    it "non enfila alcuna sincronizzazione verso GitHub" do
      override = Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                              name: "API_KEY", value: "v", actor: owner).value
      expect(Secrets::Github::SyncJob).not_to receive(:perform_later)

      described_class.call(override:, actor: owner)
    end
  end
end
