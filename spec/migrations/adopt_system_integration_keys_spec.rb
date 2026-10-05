# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260817090000_adopt_system_integration_keys")

# CYRA-549 — il giorno del passaggio. La migrazione che sposta le chiavi dall'ambiente
# all'organizzazione di chi gestisce l'installazione, una volta sola e senza copiarle altrove.
RSpec.describe AdoptSystemIntegrationKeys do
  def esegui = ActiveRecord::Migration.suppress_messages { described_class.new.up }

  def organizzazione_dell_operatore
    create(:organization).tap { |org| create(:membership, organization: org, account: create(:account, god: true), role: :owner) }
  end

  around do |example|
    originale = ENV["GOOGLE_PAGESPEED_API_KEY"]
    ENV["GOOGLE_PAGESPEED_API_KEY"] = "AIza-di-sistema"
    example.run
    ENV["GOOGLE_PAGESPEED_API_KEY"] = originale
  end

  it "la chiave di sistema finisce sull'organizzazione di chi gestisce l'installazione" do
    operatore = organizzazione_dell_operatore

    esegui

    expect(Integrations::Credential.find_by(organization: operatore, provider: "pagespeed").api_key)
      .to eq("AIza-di-sistema")
  end

  # Il cuore del ticket: le altre organizzazioni partono NON collegate. Copiare la chiave ovunque
  # vorrebbe dire lasciare il consumo di tutti a carico di una persona sola.
  it "nessun'altra organizzazione riceve una copia della chiave" do
    organizzazione_dell_operatore
    altra = create(:organization)

    esegui

    expect(Integrations::Credential.where(organization: altra)).to be_empty
  end

  it "senza un'organizzazione riconoscibile non scrive niente da nessuna parte" do
    create(:organization)

    esegui

    expect(Integrations::Credential.count).to eq(0)
  end

  it "è rieseguibile senza duplicare né sovrascrivere" do
    operatore = organizzazione_dell_operatore
    esegui

    expect { esegui }.not_to change(Integrations::Credential, :count)
    expect(Integrations::Credential.where(organization: operatore).count).to eq(1)
  end
end
