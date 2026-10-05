# frozen_string_literal: true

require "rails_helper"

# CYRA-416: revocare una delega è irreversibile per chi la subisce (il progetto smette di leggere il
# segreto), quindi passa da una conferma legata allo stato mostrato a schermo. Il digest è la prova
# che l'elenco dei progetti impattati non è cambiato fra la lettura e il clic.
RSpec.describe Secrets::Shared::Unlink do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:, code: "production") }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }

  # Valore condiviso già delegato al progetto: è lo stato da cui parte una revoca.
  let(:shared_value) do
    create(:project_environment, project:, environment:)
    value = Secrets::Shared::Save.call(organization:, environment:, name: "api_key", value: "secret").value
    Secrets::Shared::Delegate.call(shared_value: value, project:)
    value.reload
  end

  let(:delegation) { shared_value.delegations.first }
  let(:valid_digest) { Secrets::Shared::Impact.call(shared_value:, effect: :unlink).value["digest"] }

  it "con la conferma giusta toglie la delega e registra chi l'ha fatto" do
    result = described_class.call(delegation:, actor:, confirmation_digest: valid_digest)

    expect(result).to be_ok
    expect(result.value).to eq(project)
    expect(Secrets::Shared::Delegation.where(id: delegation.id)).not_to exist

    event = Secrets::Shared::Event.order(:created_at).last
    expect(event.action).to eq("unlinked")
    expect(event.actor).to eq(actor)
    expect(event.project).to eq(project)
  end

  it "con una conferma obsoleta rifiuta e lascia la delega dov'è" do
    result = described_class.call(delegation:, actor:, confirmation_digest: "vecchio-digest")

    expect(result).to be_err
    expect(result.error.code).to eq("R409-SHARED-001")
    expect(Secrets::Shared::Delegation.where(id: delegation.id)).to exist
  end

  it "senza conferma rifiuta invece di revocare in silenzio" do
    result = described_class.call(delegation:, actor:, confirmation_digest: nil)

    expect(result).to be_err
    expect(Secrets::Shared::Delegation.where(id: delegation.id)).to exist
  end
end
