# frozen_string_literal: true

require "rails_helper"

# Il giro giornaliero è l'unico posto che si accorge quando una proposta smette di essere vera senza
# che nessuno abbia salvato niente in quel progetto.
RSpec.describe Secrets::Consolidation::ScanJob do
  def organizzazione_con_valore_ripetuto(valore)
    organization = create(:organization)
    environment = create(:environment, organization:, code: "production")
    2.times do |i|
      project = create(:project, organization:)
      create(:project_environment, project:, environment:)
      create(:secret_variable, project:, organization:, environment:, name: "SECRET_#{i}", value: valore)
    end
    organization
  end

  it "apre le proposte di ogni organizzazione, senza mescolarle" do
    una = organizzazione_con_valore_ripetuto("valore-condiviso-lungo")
    altra = organizzazione_con_valore_ripetuto("valore-condiviso-lungo")

    described_class.perform_now

    expect(Secrets::Consolidation::Suggestion.where(organization: una).count).to eq(1)
    expect(Secrets::Consolidation::Suggestion.where(organization: altra).count).to eq(1)
  end

  it "chiude la proposta quando il valore non è più ripetuto" do
    organization = organizzazione_con_valore_ripetuto("valore-condiviso-lungo")
    described_class.perform_now

    Secrets::Variable.where(organization:).last.update!(value: "un-altro-valore-lungo")

    expect { described_class.perform_now }.to change { Secrets::Consolidation::Suggestion.count }.to(0)
  end
end
