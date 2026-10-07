# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Override do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org, code: "development").tap { |e| project.environments << e } }
  let(:account) { create(:account) }
  let(:admin) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:membership, account: admin, organization: org, role: :admin)
  end

  def build_override(**attrs)
    described_class.new({ account:, project:, organization: org, environment:,
                          name: "DATABASE_URL", value: "postgres://mio", created_by: admin }.merge(attrs))
  end

  it "salva un override valido" do
    expect(build_override).to be_valid
  end

  it "normalizza il nome in UPPER_SNAKE" do
    override = build_override(name: "  database_url ")
    override.validate
    expect(override.name).to eq("DATABASE_URL")
  end

  it "rifiuta un nome fuori formato ENV" do
    expect(build_override(name: "1_INVALID")).not_to be_valid
  end

  it "rifiuta un nome col prefisso riservato da GitHub Actions" do
    expect(build_override(name: "GITHUB_TOKEN")).not_to be_valid
  end

  it "rifiuta i nomi dei bundle derivati" do
    expect(build_override(name: "SECRETS_JSON")).not_to be_valid
  end

  it "rejects names the shell or a runtime reads before any program runs (CYRA-1046)" do
    %w[PATH LD_PRELOAD DYLD_INSERT_LIBRARIES NODE_OPTIONS].each do |name|
      expect(build_override(name:)).not_to be_valid, "#{name} must be rejected"
    end
  end

  # Il valore è cifrato at-rest come per Secrets::Variable: nil è un input assente, "" è un valore
  # esplicito legittimo (opzione disattivata).
  it "rifiuta un valore nil" do
    expect(build_override(value: nil)).not_to be_valid
  end

  it "accetta la stringa vuota come valore esplicito" do
    expect(build_override(value: "")).to be_valid
  end

  it "cifra il valore at-rest (mai in chiaro sulla colonna)" do
    override = build_override(value: "super-segreto")
    override.save!

    raw = described_class.connection.select_value(
      described_class.sanitize_sql([ "SELECT value FROM secrets_overrides WHERE id = ?", override.id ])
    )
    expect(raw).not_to include("super-segreto")
    expect(override.reload.value).to eq("super-segreto")
  end

  it "impedisce due override dello stesso nome per lo stesso destinatario e ambiente" do
    build_override.save!
    expect(build_override).not_to be_valid
  end

  it "consente lo stesso nome a due destinatari diversi" do
    build_override.save!
    other = create(:account)
    create(:membership, account: other, organization: org, role: :member)

    expect(build_override(account: other)).to be_valid
  end

  it "rifiuta un ambiente non dichiarato dal progetto" do
    foreign = create(:environment, organization: org, code: "staging")
    expect(build_override(environment: foreign)).not_to be_valid
  end

  it "rifiuta un'organizzazione diversa da quella del progetto" do
    expect(build_override(organization: create(:organization))).not_to be_valid
  end

  # Tenant guard sul DESTINATARIO: un override assegnato a chi non è dell'organizzazione del progetto
  # sarebbe una riga viva su un account estraneo.
  it "rifiuta un destinatario che non è membro dell'organizzazione del progetto" do
    expect(build_override(account: create(:account))).not_to be_valid
  end

  # L'identità della riga è [destinatario, progetto, ambiente]: si sposta cancellando e ricreando.
  it "non riassegna destinatario, progetto, ambiente e organizzazione" do
    override = build_override
    override.save!
    other = create(:account)
    create(:membership, account: other, organization: org, role: :member)

    expect { override.update(account: other) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(override.reload.account_id).to eq(account.id)
  end

  it "sopravvive alla cancellazione dell'admin che l'ha assegnato" do
    override = build_override
    override.save!

    admin.destroy!

    expect(override.reload.created_by_id).to be_nil
    expect(override.value).to eq("postgres://mio")
  end
end
