require "rails_helper"

RSpec.describe Projects::Tokens::Issue, type: :service do
  let(:project) { create(:project) }
  let(:host) { "bugs.example.com" }
  let(:environment) { create(:environment, organization: project.organization).tap { |e| project.environments << e } }

  subject(:result) { described_class.call(project:, name: "Production SDK", host:, environment:) }

  it "ritorna Result.ok con token, secret e dsn" do
    expect(result).to be_ok
    expect(result.value).to include(:token, :secret, :dsn)
    expect(result.value[:token]).to be_a(Projects::Token)
  end

  it "persiste il token sul progetto" do
    expect { result }.to change(project.tokens, :count).by(1)
  end

  it "il secret è prefissato cyi_ e non è memorizzato in chiaro" do
    secret = result.value[:secret]
    token = result.value[:token]

    expect(secret).to start_with("cyi_")
    expect(token.token_digest).to eq(Digest::SHA256.hexdigest(secret))
    expect(token).not_to respond_to(:secret)
  end

  it "il token_prefix è i primi 12 char del secret (per display)" do
    expect(result.value[:token].token_prefix).to eq(result.value[:secret][0, 12])
  end

  it "la public_key è 32 hex" do
    expect(result.value[:token].public_key).to match(/\A[0-9a-f]{32}\z/)
  end

  it "il dsn è Sentry-style con public_key, host e project_id" do
    token = result.value[:token]
    expect(result.value[:dsn]).to eq("https://#{token.public_key}@#{host}/#{project.id}")
  end

  it "default scope: ingest + read (bearer server-only a piena potenza, CYRA-37)" do
    expect(result.value[:token].scopes).to eq([ "ingest", "read" ])
  end

  it "returns a separate numeric Sentry DSN while preserving the native UUID DSN" do
    token = result.value.fetch(:token)

    expect(result.value.fetch(:sentry_dsn)).to eq("https://#{token.public_key}@#{host}/#{project.reload.sentry_project_id}")
    expect(result.value.fetch(:dsn)).to end_with("/#{project.id}")
  end

  it "accetta scopes espliciti ristretti (es. token ingest-only)" do
    res = described_class.call(project:, name: "browser SDK", host:, environment:, scopes: [ "ingest" ])
    expect(res.value[:token].scopes).to eq([ "ingest" ])
  end

  it "registra created_by quando passato" do
    account = create(:account)
    res = described_class.call(project:, name: "CI", host:, environment:, created_by: account)
    expect(res.value[:token].created_by).to eq(account)
  end

  it "ritorna Result.err R422-TOKEN-001 se la validazione fallisce (name vuoto)" do
    res = described_class.call(project:, name: nil, host:, environment:)

    expect(res).to be_err
    expect(res.error.code).to eq("R422-TOKEN-001")
  end
end
