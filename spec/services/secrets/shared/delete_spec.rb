# frozen_string_literal: true

require "rails_helper"

# Cancellare un valore condiviso lo toglie a TUTTI i progetti che lo ricevono, in tutti gli ambienti
# in una volta sola: è irreversibile e a raggio largo. Per questo la conferma non è una sola, ma una
# per ogni cella — se nel frattempo ne è comparsa un'altra, la conferma non torna e la cancellazione
# si ferma invece di portarsi via anche quella.
RSpec.describe Secrets::Shared::Delete do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:production) { create(:environment, organization:, code: "production") }
  let(:staging) { create(:environment, organization:, code: "staging") }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }

  before { [ production, staging ].each { |env| create(:project_environment, project:, environment: env) } }

  def salva(environment, value: "secret")
    Secrets::Shared::Save.call(organization:, environment:, name: "api_key", value:).value
  end

  def digests(variable)
    variable.values.map do |value|
      Secrets::Shared::Impact.call(shared_value: value, effect: :delete).value["digest"]
    end
  end

  let(:variable) { salva(production).shared_variable }

  it "cancella la variabile e tutti i suoi valori, e lo scrive nel registro" do
    variable

    result = described_class.call(shared_variable: variable, actor:,
                                  confirmation_digests: digests(variable))

    expect(result).to be_ok
    expect(Secrets::Shared::Variable.where(id: variable.id)).not_to exist
    expect(Secrets::Shared::Value.count).to eq(0)

    event = Secrets::Shared::Event.where(action: "deleted").last
    expect(event).to have_attributes(organization:, actor:, name: "API_KEY")
  end

  it "vuole la conferma di OGNI ambiente, non di uno solo" do
    salva(production)
    salva(staging)

    parziale = described_class.call(shared_variable: variable.reload, actor:,
                                    confirmation_digests: [ digests(variable).first ])

    expect(parziale).to be_err
    expect(parziale.error.code).to eq("R409-SHARED-001")
    expect(Secrets::Shared::Variable.where(id: variable.id)).to exist
  end

  it "l'ordine delle conferme non conta" do
    salva(production)
    salva(staging)

    expect(described_class.call(shared_variable: variable.reload, actor:,
                                confirmation_digests: digests(variable).reverse)).to be_ok
  end

  it "una conferma vecchia rifiuta e restituisce l'impatto aggiornato" do
    variable
    Secrets::Shared::Delegate.call(shared_value: variable.values.first, project:)

    result = described_class.call(shared_variable: variable.reload, actor:,
                                  confirmation_digests: [ "vecchio" ])

    expect(result).to be_err
    expect(result.error.code).to eq("R409-SHARED-001")
    expect(result.error.details.first["projects"].map { |row| row["id"] }).to eq([ project.id ])
    expect(Secrets::Shared::Variable.where(id: variable.id)).to exist
  end

  it "senza conferme non cancella niente" do
    variable

    expect(described_class.call(shared_variable: variable, actor:, confirmation_digests: nil)).to be_err
    expect(Secrets::Shared::Variable.where(id: variable.id)).to exist
  end

  it "i progetti che lo ricevevano vengono riallineati su GitHub" do
    variable
    repository = create(:github_repository, project:, sync_secrets: true)
    Secrets::Shared::Delegate.call(shared_value: variable.values.first, project:)
    clear_enqueued_jobs

    described_class.call(shared_variable: variable.reload, actor:,
                         confirmation_digests: digests(variable))

    expect(Secrets::Github::SyncJob).to have_been_enqueued.once
      .with(github_repository_id: repository.id)
  end

  it "cancellando spariscono anche le deleghe: nessun progetto resta agganciato al vuoto" do
    variable
    Secrets::Shared::Delegate.call(shared_value: variable.values.first, project:)

    described_class.call(shared_variable: variable.reload, actor:,
                         confirmation_digests: digests(variable))

    expect(Secrets::Shared::Delegation.count).to eq(0)
    expect(Secrets::Bundle.call(project:, environment: production).value).to eq({})
  end
end
