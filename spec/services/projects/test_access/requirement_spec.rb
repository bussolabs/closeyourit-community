# frozen_string_literal: true

require "rails_helper"

# CYRA-1304 — no automatic work on a project with a staging environment until its test account is filled in.
RSpec.describe Projects::TestAccess::Requirement do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:actor) { create(:account) }

  before do
    versioni_uscite("v1.0.0")
    project.update!(production_hold_hours: 0)
  end

  def declare_staging
    create(:environment, organization:, code: "staging", label: "Staging").tap { |environment| project.environments << environment }
  end

  def fill_test_access
    project.update!(test_access_url: "https://staging.example.com/login", test_access_username: "tester@example.com")
    Projects::TestAccess::SavePassword.call(project:, password: "S3cret-pass", actor:)
  end

  def waiting_ticket
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, "closer_production")
    create(:agent_attempt, workflow: ticket.agent_workflow, organization:, phase: "closer_staging", status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.0.0-beta.1", "commit" => "a" * 40 })
    ticket
  end

  def host
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}",
                                                     project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  def queue_head = Agents::TicketQueues::Candidates.new(project:, host:).head_id

  it "leaves alone a project with no staging environment" do
    ticket = waiting_ticket

    expect(described_class.missing?(project)).to be(false)
    expect(queue_head).to eq(ticket.id)
  end

  it "hands out nothing on a project with staging and no test account" do
    declare_staging
    waiting_ticket

    expect(described_class.missing?(project)).to be(true)
    expect(queue_head).to be_nil
  end

  it "still hands out nothing while one of the three pieces is missing" do
    declare_staging
    waiting_ticket
    project.update!(test_access_url: "https://staging.example.com/login", test_access_username: "tester@example.com")
    expect(queue_head).to be_nil

    Projects::TestAccess::SavePassword.call(project:, password: "S3cret-pass", actor:)
    project.update!(test_access_username: nil)
    expect(queue_head).to be_nil
  end

  it "hands out work again once link, user and password are all there" do
    declare_staging
    ticket = waiting_ticket
    fill_test_access

    expect(described_class.missing?(project.reload)).to be(false)
    expect(queue_head).to eq(ticket.id)
  end

  it "hands out work on a project with staging that declares it has nothing to sign in to" do
    declare_staging
    ticket = waiting_ticket
    project.update!(test_access_not_needed: "1")

    expect(described_class.missing?(project)).to be(false)
    expect(queue_head).to eq(ticket.id)
  end

  it "asks for the account again once that declaration is withdrawn" do
    declare_staging
    waiting_ticket
    project.update!(test_access_not_needed: "1")
    project.update!(test_access_not_needed: "0")

    expect(described_class.missing?(project)).to be(true)
    expect(queue_head).to be_nil
  end
end
