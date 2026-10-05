# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260903155915_drop_gemini_credentials")

# CYRA-765 — le chiavi Gemini collegate dalle organizzazioni non hanno più un consumatore: l'AI la
# offre il sistema. Tenerle in tabella vorrebbe dire custodire il segreto di qualcun altro senza
# usarlo mai, e nessuna schermata potrebbe più mostrarle per farle togliere.
#
# La riga si scrive in SQL: il modello rifiuta un fornitore fuori registro, e la prova deve partire
# dallo stato in cui il database si trova davvero il giorno del rilascio.
RSpec.describe DropGeminiCredentials do
  let(:organization) { create(:organization) }

  def esegui = ActiveRecord::Migration.suppress_messages { described_class.new.up }

  def scrivi_credenziale_gemini
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO integrations_credentials (id, organization_id, provider, api_key, created_at, updated_at)
      VALUES (gen_random_uuid(), '#{organization.id}', 'gemini', 'cifrato-finto', NOW(), NOW())
    SQL
  end

  it "cancella le chiavi del fornitore ritirato" do
    scrivi_credenziale_gemini

    esegui

    expect(Integrations::Credential.where(provider: "gemini")).to be_empty
  end

  it "non tocca le chiavi dei servizi ancora collegabili" do
    scrivi_credenziale_gemini
    rimasta = create(:integration_credential, organization:, provider: "pagespeed")

    esegui

    expect(rimasta.reload).to be_present
  end

  it "senza niente da cancellare non fa danni" do
    expect { esegui }.not_to raise_error
  end
end
