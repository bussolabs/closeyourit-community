# frozen_string_literal: true

require "rails_helper"

# Il giro mirato che segue un salvataggio. Gli argomenti sono id e non record proprio perché il job
# può girare molto dopo: quello che non c'è più non è un errore da ritentare all'infinito.
RSpec.describe Secrets::Consolidation::RefreshJob do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:, code: "production") }

  def valore_ripetuto(valore = "valore-condiviso-lungo")
    2.times do |i|
      project = create(:project, organization:)
      create(:project_environment, project:, environment:)
      create(:secret_variable, project:, organization:, environment:, name: "SECRET_#{i}", value: valore)
    end
    Secrets::Consolidation::Fingerprint.for(valore)
  end

  it "apre la proposta per la sola impronta richiesta" do
    impronta = valore_ripetuto

    expect do
      described_class.perform_now(organization_id: organization.id, environment_id: environment.id,
                                  fingerprints: [ impronta ])
    end.to change { Secrets::Consolidation::Suggestion.count }.by(1)
  end

  it "non fa niente se l'organizzazione non c'è più" do
    valore_ripetuto

    expect do
      described_class.perform_now(organization_id: SecureRandom.uuid)
    end.not_to change { Secrets::Consolidation::Suggestion.count }
  end

  it "non fa niente se l'ambiente non c'è più" do
    impronta = valore_ripetuto

    expect do
      described_class.perform_now(organization_id: organization.id, environment_id: SecureRandom.uuid,
                                  fingerprints: [ impronta ])
    end.not_to change { Secrets::Consolidation::Suggestion.count }
  end
end
