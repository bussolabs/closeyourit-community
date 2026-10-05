require "rails_helper"

RSpec.describe Secrets::Bundle do
  let(:project) { create(:project) }
  let(:production) do
    create(:environment, organization: project.organization, code: "production").tap { |e| project.environments << e }
  end
  let(:staging) do
    create(:environment, organization: project.organization, code: "staging").tap { |e| project.environments << e }
  end

  describe ".call" do
    it "ritorna la mappa decifrata name => value dell'ambiente richiesto" do
      Secrets::Variables::Set.call(project:, environment: production, name: "A", value: "1")
      Secrets::Variables::Set.call(project:, environment: production, name: "B", value: "2")

      result = described_class.call(project:, environment: production)

      expect(result).to be_ok
      expect(result.value).to eq({ "A" => "1", "B" => "2" })
    end

    it "esclude le variabili di un altro ambiente" do
      Secrets::Variables::Set.call(project:, environment: production, name: "PROD_ONLY", value: "p")
      Secrets::Variables::Set.call(project:, environment: staging, name: "STG_ONLY", value: "s")

      result = described_class.call(project:, environment: production)
      expect(result.value.keys).to eq([ "PROD_ONLY" ])
    end

    it "ritorna una mappa vuota se non ci sono variabili" do
      result = described_class.call(project:, environment: production)
      expect(result.value).to eq({})
    end
  end

  # CYRA-79 — con `account:` il bundle è quello DI QUELLA PERSONA: sopra i default si applicano i suoi
  # valori su misura. Senza account resta il bundle "della macchina", cioè i soli default.
  describe ".call con un account (valori su misura)" do
    let(:org) { project.organization }
    let(:owner) { create(:account) }
    let(:reader) { create(:account) }
    let(:altro_lettore) { create(:account) }

    # Un'organizzazione ha un solo owner: gli altri due sono membri con secrets.read concesso e il
    # progetto collegato — cioè lettori veri, gli unici a cui si può assegnare un valore su misura.
    def make_reader(account)
      create(:membership, account:, organization: org, role: :member)
      create(:project_membership, account:, project:)
      create(:account_permission, account:, organization: org, permission_key: "secrets.read", effect: :allow)
    end

    before do
      create(:membership, account: owner, organization: org, role: :owner)
      make_reader(reader)
      make_reader(altro_lettore)
      Secrets::Variables::Set.call(project:, environment: production, name: "DATABASE_URL", value: "standard")
      Secrets::Variables::Set.call(project:, environment: production, name: "API_KEY", value: "condiviso")
      Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                   name: "DATABASE_URL", value: "solo-mio", actor: owner)
    end

    it "sostituisce il default col valore su misura della persona" do
      result = described_class.call(project:, environment: production, account: reader)

      expect(result.value).to eq({ "API_KEY" => "condiviso", "DATABASE_URL" => "solo-mio" })
    end

    it "lascia il valore standard a chi non ha alcun valore su misura" do
      result = described_class.call(project:, environment: production, account: altro_lettore)

      expect(result.value).to eq({ "API_KEY" => "condiviso", "DATABASE_URL" => "standard" })
    end

    it "senza account non applica NESSUN valore su misura" do
      result = described_class.call(project:, environment: production)

      expect(result.value).to eq({ "API_KEY" => "condiviso", "DATABASE_URL" => "standard" })
    end

    it "aggiunge anche una variabile che nei default non esiste" do
      Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                   name: "SOLO_PER_ME", value: "extra", actor: owner)

      result = described_class.call(project:, environment: production, account: reader)

      expect(result.value["SOLO_PER_ME"]).to eq("extra")
      expect(described_class.call(project:, environment: production).value).not_to have_key("SOLO_PER_ME")
    end

    it "non applica il valore su misura di un altro ambiente" do
      Secrets::Variables::Set.call(project:, environment: staging, name: "DATABASE_URL", value: "standard-staging")

      result = described_class.call(project:, environment: staging, account: reader)

      expect(result.value["DATABASE_URL"]).to eq("standard-staging")
    end

    # Il valore su misura è la parola più specifica: vince anche su un valore delegato dal vault
    # condiviso dell'organizzazione.
    it "vince anche su un valore delegato dallo shared" do
      shared_value = Secrets::Shared::Save.call(organization: org, environment: production,
                                                name: "SHARED_KEY", value: "da-condiviso").value
      Secrets::Shared::Delegate.call(shared_value:, project:)
      Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                   name: "SHARED_KEY", value: "mio-al-posto-del-condiviso", actor: owner)

      result = described_class.call(project:, environment: production, account: reader)

      expect(result.value["SHARED_KEY"]).to eq("mio-al-posto-del-condiviso")
      expect(described_class.call(project:, environment: production).value["SHARED_KEY"]).to eq("da-condiviso")
    end
  end
end
