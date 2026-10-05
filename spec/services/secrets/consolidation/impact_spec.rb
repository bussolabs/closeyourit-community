# frozen_string_literal: true

require "rails_helper"

# Il digest è ciò che rende la conferma una conferma: dice «sto decidendo su QUESTO». Il confine è
# preciso — copre lo stato del mondo, non le scelte di chi conferma — e sbagliarlo si paga in due
# modi opposti: troppo largo, e cambiare una lettera nel nome fa rispondere «conferma obsoleta» a una
# richiesta valida; troppo stretto, e si scrive su un mondo diverso da quello letto.
RSpec.describe Secrets::Consolidation::Impact do
  let(:organization) { create(:organization) }
  let(:production) { create(:environment, organization:, code: "production") }

  def progetto(nome)
    create(:project, organization:, name: nome).tap { |p| create(:project_environment, project: p, environment: production) }
  end

  let(:uno) { progetto("uno") }
  let(:due) { progetto("due") }

  def suggestion(valore: "valore-condiviso-lungo")
    create(:secret_variable, project: uno, organization:, environment: production, name: "API_KEY", value: valore)
    create(:secret_variable, project: due, organization:, environment: production, name: "CHIAVE_API", value: valore)
    Secrets::Consolidation::Refresh.call(organization:)
    Secrets::Consolidation::Suggestion.last
  end

  it "elenca ogni progetto col nome che perde e il repository che riceverà il valore" do
    create(:github_repository, project: uno, sync_secrets: true, full_name: "bussolabs/uno")

    payload = described_class.call(suggestion: suggestion).value

    expect(payload["projects"].map { |r| r["project"] }).to eq(%w[due uno])
    expect(payload["projects"].map { |r| r["name"] }).to eq(%w[CHIAVE_API API_KEY])
    expect(payload["projects"].last["repository"]).to eq("bussolabs/uno")
  end

  it "non porta mai il valore" do
    payload = described_class.call(suggestion: suggestion).value

    expect(payload.to_json).not_to include("valore-condiviso-lungo")
  end

  it "dà lo stesso digest a mondo invariato" do
    proposta = suggestion

    expect(described_class.call(suggestion: proposta).value["digest"])
      .to eq(described_class.call(suggestion: proposta).value["digest"])
  end

  it "cambia digest quando un terzo progetto prende lo stesso valore" do
    proposta = suggestion
    prima = described_class.call(suggestion: proposta).value["digest"]

    create(:secret_variable, project: progetto("tre"), organization:, environment: production,
                             name: "API_KEY", value: "valore-condiviso-lungo")

    expect(described_class.call(suggestion: proposta).value["digest"]).not_to eq(prima)
  end

  it "cambia digest quando uno dei progetti rinomina la sua variabile" do
    proposta = suggestion
    prima = described_class.call(suggestion: proposta).value["digest"]

    Secrets::Variable.find_by(project: due).update!(name: "ALTRO_NOME")

    expect(described_class.call(suggestion: proposta).value["digest"]).not_to eq(prima)
  end

  it "cambia digest quando l'organizzazione comincia a tenere quel valore" do
    proposta = suggestion
    prima = described_class.call(suggestion: proposta).value["digest"]

    Secrets::Shared::Save.call(organization:, environment: production, name: "GIA_QUI",
                               value: "valore-condiviso-lungo")

    expect(described_class.call(suggestion: proposta).value["digest"]).not_to eq(prima)
  end

  it "dice che non c'è niente da spostare quando il valore non è più ripetuto" do
    proposta = suggestion
    Secrets::Variable.find_by(project: due).update!(value: "un-altro-valore-lungo")

    expect(described_class.call(suggestion: proposta).value["projects"]).to be_empty
  end
end
