# frozen_string_literal: true

require "rails_helper"

# Il gruppo si forma sul VALORE, non sul nome: è la sola cosa che distingue «lo stesso segreto
# ricopiato» da «due segreti diversi che si chiamano uguale».
RSpec.describe Secrets::Consolidation::Candidates do
  let(:organization) { create(:organization) }
  let(:production) { create(:environment, organization:, code: "production") }
  let(:staging) { create(:environment, organization:, code: "staging") }

  def progetto(nome, *environments)
    project = create(:project, organization:, name: nome)
    environments.each { |environment| create(:project_environment, project:, environment:) }
    project
  end

  def segreto(project, environment, name, value)
    create(:secret_variable, project:, organization:, environment:, name:, value:)
  end

  it "raggruppa lo stesso valore in due progetti, anche con nomi diversi" do
    uno = progetto("uno", production)
    due = progetto("due", production)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")
    segreto(due, production, "CHIAVE_API", "valore-condiviso-lungo")

    candidati = described_class.call(organization:).value

    expect(candidati.size).to eq(1)
    expect(candidati.first.projects_count).to eq(2)
    expect(candidati.first.names).to eq(%w[API_KEY CHIAVE_API])
    expect(candidati.first.environment).to eq(production)
  end

  it "non propone niente per un valore che vive in un progetto solo" do
    uno = progetto("uno", production)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")

    expect(described_class.call(organization:).value).to be_empty
  end

  # Due copie nello stesso progetto non sono un valore «in comune»: non c'è nessun secondo progetto
  # a cui delegarlo.
  it "non propone niente per due nomi con lo stesso valore dentro lo stesso progetto" do
    uno = progetto("uno", production)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")
    segreto(uno, production, "CHIAVE_API", "valore-condiviso-lungo")

    expect(described_class.call(organization:).value).to be_empty
  end

  it "non mescola ambienti diversi" do
    uno = progetto("uno", production, staging)
    due = progetto("due", production, staging)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")
    segreto(due, staging, "API_KEY", "valore-condiviso-lungo")

    expect(described_class.call(organization:).value).to be_empty
  end

  it "non mescola organizzazioni diverse" do
    altra = create(:organization)
    altro_env = create(:environment, organization: altra, code: "production")
    altro_progetto = create(:project, organization: altra)
    create(:project_environment, project: altro_progetto, environment: altro_env)

    uno = progetto("uno", production)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")
    create(:secret_variable, project: altro_progetto, organization: altra, environment: altro_env,
                             name: "API_KEY", value: "valore-condiviso-lungo")

    expect(described_class.call(organization:).value).to be_empty
  end

  it "ignora i valori troppo corti per avere un'impronta" do
    uno = progetto("uno", production)
    due = progetto("due", production)
    segreto(uno, production, "DEBUG", "1")
    segreto(due, production, "DEBUG", "1")

    expect(described_class.call(organization:).value).to be_empty
  end

  it "propone il nome usato dal maggior numero di progetti" do
    uno = progetto("uno", production)
    due = progetto("due", production)
    tre = progetto("tre", production)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")
    segreto(due, production, "API_KEY", "valore-condiviso-lungo")
    segreto(tre, production, "ZZZ_CHIAVE", "valore-condiviso-lungo")

    expect(described_class.call(organization:).value.first.suggested_name).to eq("API_KEY")
  end

  it "a parità di uso propone il primo nome in ordine alfabetico" do
    uno = progetto("uno", production)
    due = progetto("due", production)
    segreto(uno, production, "ZZZ_CHIAVE", "valore-condiviso-lungo")
    segreto(due, production, "API_KEY", "valore-condiviso-lungo")

    expect(described_class.call(organization:).value.first.suggested_name).to eq("API_KEY")
  end

  it "dice quando l'organizzazione tiene già quel valore" do
    condiviso = Secrets::Shared::Save.call(organization:, environment: production, name: "GIA_QUI",
                                           value: "valore-condiviso-lungo").value
    uno = progetto("uno", production)
    due = progetto("due", production)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")
    segreto(due, production, "CHIAVE_API", "valore-condiviso-lungo")

    candidato = described_class.call(organization:).value.first

    expect(candidato).to be_existing_shared
    expect(candidato.shared_value).to eq(condiviso)
  end

  it "restringe il giro all'ambiente e alle impronte richieste" do
    uno = progetto("uno", production, staging)
    due = progetto("due", production, staging)
    segreto(uno, production, "API_KEY", "valore-condiviso-lungo")
    segreto(due, production, "API_KEY", "valore-condiviso-lungo")
    segreto(uno, staging, "ALTRO", "un-altro-valore-lungo")
    segreto(due, staging, "ALTRO", "un-altro-valore-lungo")

    solo_staging = described_class.call(organization:, environment: staging).value
    expect(solo_staging.map(&:environment)).to eq([ staging ])

    impronta = Secrets::Consolidation::Fingerprint.for("valore-condiviso-lungo")
    solo_impronta = described_class.call(organization:, fingerprints: [ impronta ]).value
    expect(solo_impronta.map(&:value_fingerprint)).to eq([ impronta ])
  end
end
