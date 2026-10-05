# frozen_string_literal: true

require "rails_helper"

# Il callback di installazione della GitHub App può arrivare più volte per la stessa organizzazione
# (reinstallazione, cambio account). Deve restare UNA installazione per organizzazione: due righe
# vorrebbero dire due token possibili per le stesse chiamate, e nessuno saprebbe quale vale.
RSpec.describe Github::Installations::Connect do
  let(:organization) { create(:organization) }

  before do
    allow(Github::Installations::Verify).to receive(:call) do |**args|
      if args[:installation_id].nil?
        Result.err(AppError.new("Missing installation", code: "R422-GITHUB-001", details: { installation_id: [ "missing" ] }))
      else
        Result.ok({ "account" => { "login" => args[:installation_id] == 999 ? "other-account" : "bussolabs" } })
      end
    end
  end

  it "does not persist an installation without verified authority" do
    allow(Github::Installations::Verify).to receive(:call).and_return(
      Result.err(AppError.new("Not verified", code: "R403-GITHUB-001", status: :forbidden))
    )
    result = described_class.call(organization:, installation_id: 555, code: "test-code", redirect_uri: "https://example.com/callback")
    expect(result).to be_err
    expect(organization.reload.github_installation).to be_nil
  end

  it "registra l'installazione dell'organizzazione" do
    result = described_class.call(organization:, installation_id: 12_345, code: "test-code", redirect_uri: "https://example.com/callback")

    expect(result).to be_ok
    installation = result.value
    expect(installation).to be_persisted
    expect(installation.organization).to eq(organization)
    expect(installation.installation_id).to eq(12_345)
    expect(installation.account_login).to eq("bussolabs")
  end

  it "una seconda installazione aggiorna quella che c'è invece di affiancarla" do
    described_class.call(organization:, installation_id: 12_345, code: "test-code", redirect_uri: "https://example.com/callback")

    expect do
      result = described_class.call(organization:, installation_id: 999, code: "test-code", redirect_uri: "https://example.com/callback")
      expect(result).to be_ok
    end.not_to change(Github::Installation, :count)

    expect(organization.reload.github_installation)
      .to have_attributes(installation_id: 999, account_login: "other-account")
  end

  it "ogni organizzazione ha la sua" do
    described_class.call(organization:, installation_id: 1, code: "test-code", redirect_uri: "https://example.com/callback")
    described_class.call(organization: create(:organization), installation_id: 2, code: "test-code", redirect_uri: "https://example.com/callback")

    expect(Github::Installation.count).to eq(2)
    expect(organization.reload.github_installation.installation_id).to eq(1)
  end

  it "un callback senza numero di installazione è un errore di dominio, non un'eccezione" do
    result = described_class.call(organization:, installation_id: nil, code: "test-code", redirect_uri: "https://example.com/callback")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-001")
    expect(result.error.details).to have_key(:installation_id)
    expect(organization.reload.github_installation).to be_nil
  end
end
