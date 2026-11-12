# frozen_string_literal: true

require "rails_helper"

# CYRA-1291 — the server reads which files a pull request changed, instead of taking the agent's word for it.
RSpec.describe Github::Client, "#pull_request_files" do
  let(:rsa) { OpenSSL::PKey::RSA.new(2048) }
  let(:installation_id) { 999 }

  subject(:client) do
    described_class.new(app_id: "42", private_key: rsa.to_pem, base_url: "https://api.github.test")
  end

  before do
    Rails.cache.clear
    stub_request(:post, "https://api.github.test/app/installations/#{installation_id}/access_tokens")
      .to_return(status: 201, body: { token: "ghs_installtoken" }.to_json)
  end

  def files_url(page) = "https://api.github.test/repos/acme/api/pulls/7/files?per_page=100&page=#{page}"

  def page_of(count, prefix: "app/file")
    Array.new(count) { |index| { filename: "#{prefix}_#{index}.rb", status: "modified" } }.to_json
  end

  it "returns the changed paths of a small pull request" do
    stub_request(:get, files_url(1)).to_return(status: 200, body: [
      { filename: "app/models/user.rb", status: "modified" },
      { filename: "db/migrate/20261112090000_add_notes.rb", status: "added" }
    ].to_json)

    expect(client.pull_request_files(installation_id, "acme/api", 7))
      .to include(paths: %w[app/models/user.rb db/migrate/20261112090000_add_notes.rb], truncated: false)
  end

  it "keeps status and line counts of each file" do
    stub_request(:get, files_url(1)).to_return(status: 200, body: [
      { filename: "spec/models/user_spec.rb", status: "removed", additions: 0, deletions: 40 }
    ].to_json)

    expect(client.pull_request_files(installation_id, "acme/api", 7)[:files])
      .to eq([ { path: "spec/models/user_spec.rb", status: "removed", additions: 0, deletions: 40 } ])
  end

  it "counts both names of a renamed file" do
    stub_request(:get, files_url(1)).to_return(status: 200, body: [
      { filename: "app/services/login.rb", previous_filename: "app/auth/login.rb", status: "renamed" }
    ].to_json)

    expect(client.pull_request_files(installation_id, "acme/api", 7)[:paths])
      .to eq(%w[app/services/login.rb app/auth/login.rb])
  end

  it "follows the pages until a short one" do
    stub_request(:get, files_url(1)).to_return(status: 200, body: page_of(100, prefix: "a"))
    stub_request(:get, files_url(2)).to_return(status: 200, body: page_of(3, prefix: "b"))

    result = client.pull_request_files(installation_id, "acme/api", 7)

    expect(result[:paths].size).to eq(103)
    expect(result[:truncated]).to be(false)
  end

  it "says the list is incomplete when the page cap is reached" do
    (1..described_class::FILES_MAX_PAGES).each do |page|
      stub_request(:get, files_url(page)).to_return(status: 200, body: page_of(100, prefix: "p#{page}"))
    end

    result = client.pull_request_files(installation_id, "acme/api", 7)

    expect(result[:truncated]).to be(true)
    expect(result[:paths].size).to eq(described_class::FILES_MAX_PAGES * 100)
  end

  it "raises an authoritative not found for a missing pull request" do
    stub_request(:get, files_url(1)).to_return(status: 404, body: "{}")

    expect { client.pull_request_files(installation_id, "acme/api", 7) }
      .to raise_error(Github::Client::Error) { |error| expect(error.status).to eq(:not_found) }
  end
end
