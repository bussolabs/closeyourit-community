# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Github::CreateBranch do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, title: "Fix login redirect") }
  let(:actor) { ticket.reporter }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization:))
  end
  let(:client) do
    instance_double(Github::Client,
                    ref: { "object" => { "sha" => "deadbeef" } },
                    create_ref: { "ref" => "refs/heads/x" })
  end

  it "crea il branch con nome prefissato dal codice ticket e registra l'evento" do
    result = described_class.call(ticket:, actor:, client:)

    expect(result).to be_ok
    branch = result.value
    expect(branch.name).to start_with(ticket.code)
    expect(branch.ticket).to eq(ticket)
    expect(ticket.events.where(action: "branch_created")).to exist
    expect(client).to have_received(:create_ref).with(
      repository.installation.installation_id, repository.full_name, "refs/heads/#{branch.name}", "deadbeef"
    )
  end

  it "senza repo agganciato → R404-GITHUB-002" do
    bare = create(:ticket, organization:, project: create(:project, organization:))

    result = described_class.call(ticket: bare, actor: bare.reporter, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-GITHUB-002")
  end

  it "se il branch del ticket esiste già → R422-GITHUB-005" do
    described_class.call(ticket:, actor:, client:)

    result = described_class.call(ticket:, actor:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-005")
  end

  it "errore API GitHub → R422-GITHUB-005" do
    allow(client).to receive(:create_ref).and_raise(Github::Client::Error.new("boom", code: "R502-GITHUB-001"))

    result = described_class.call(ticket:, actor:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-005")
  end
end
