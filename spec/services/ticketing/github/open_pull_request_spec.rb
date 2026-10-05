# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Github::OpenPullRequest do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, title: "Fix login redirect") }
  let(:actor) { ticket.reporter }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization:))
  end
  let(:client) do
    instance_double(Github::Client,
                    create_pull: {
                      "number" => 7, "html_url" => "https://github.com/bussolabs/app/pull/7",
                      "id" => 555, "user" => { "login" => "alice" }
                    })
  end

  it "apre la PR usando il branch del ticket e registra l'evento" do
    branch = create(:github_branch, repository:, ticket:, name: "#{ticket.code}-fix")

    result = described_class.call(ticket:, actor:, client:)

    expect(result).to be_ok
    pull = result.value
    expect(pull.number).to eq(7)
    expect(pull.ticket).to eq(ticket)
    expect(pull.head_ref).to eq(branch.name)
    expect(ticket.events.where(action: "pull_request_opened")).to exist
    expect(client).to have_received(:create_pull).with(
      repository.installation.installation_id, repository.full_name,
      hash_including(title: "#{ticket.code} #{ticket.title}", base: "main")
    )
  end

  it "senza branch del ticket → R422-GITHUB-005" do
    result = described_class.call(ticket:, actor:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-005")
  end

  it "senza repo agganciato → R404-GITHUB-002" do
    bare = create(:ticket, organization:, project: create(:project, organization:))

    result = described_class.call(ticket: bare, actor: bare.reporter, client:)

    expect(result.error.code).to eq("R404-GITHUB-002")
  end

  it "errore API GitHub (es. PR senza diff) → R422-GITHUB-005" do
    create(:github_branch, repository:, ticket:, name: "#{ticket.code}-fix")
    allow(client).to receive(:create_pull).and_raise(Github::Client::Error.new("no commits", code: "R502-GITHUB-001"))

    result = described_class.call(ticket:, actor:, client:)

    expect(result.error.code).to eq("R422-GITHUB-005")
  end
end
