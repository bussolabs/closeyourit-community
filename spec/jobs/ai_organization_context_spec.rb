# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — background work runs as the organization that owns the record, so it uses that
# organization's AI settings and never another one's.
RSpec.describe "AI settings in background jobs" do # rubocop:disable RSpec/DescribeClass
  after do
    Ai::Configuration.reset!
    Current.organization = nil
  end

  def customize(organization)
    organization.create_ai_setting!(mode: "variation", embedding_model: "embed-acme", chat_model: "chat-acme")
    Ai::Configuration.reset!
  end

  def org_version(organization) = Ai::Configuration.for(organization).embedding_version

  EMBEDDED = {
    "tickets" => [ :ticket, Ticketing::EmbedTicketJob, :ticket_id, ->(r) { r.project.organization } ],
    "error groups" => [ :error_group, Errors::EmbedGroupJob, :group_id, ->(r) { r.project.organization } ],
    "knowledge pages" => [ :knowledge_page, Knowledge::EmbedPageJob, :page_id, lambda(&:organization) ],
    "ideas" => [ :idea, Ideas::EmbedIdeaJob, :idea_id, ->(r) { r.project.organization } ],
    "helpdesk requests" => [ :helpdesk_request, Helpdesk::EmbedRequestJob, :request_id, ->(r) { r.project.organization } ]
  }.freeze

  EMBEDDED.each do |name, (factory, job, argument, owner)|
    it "embeds #{name} with the model of their organization and stamps its version" do
      record = create(factory)
      organization = owner.call(record)
      customize(organization)
      used = nil
      allow(Embeddings::EmbedText).to receive(:call) do
        used = Ai::Configuration.current.embedding_model
        Result.ok(basis_vector(3))
      end

      job.perform_now(argument => record.id)

      expect(used).to eq("embed-acme")
      expect(record.reload.embedding_version).to eq(org_version(organization))
    end
  end

  it "does not queue again a ticket already embedded with its organization's model" do
    ticket = create(:ticket)
    customize(ticket.project.organization)
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(basis_vector(3)))
    Ticketing::EmbedTicketJob.perform_now(ticket_id: ticket.id)
    Ai::Configuration.reset!
    Current.organization = nil

    expect { Ticketing::BackfillEmbeddingsJob.perform_now }
      .not_to have_enqueued_job(Ticketing::EmbedTicketJob)
  end

  it "counts rows embedded with their organization's model as current, not stale" do
    ticket = create(:ticket)
    organization = ticket.project.organization
    customize(organization)
    ticket.update_columns(embedding: basis_vector(3), embedding_version: org_version(organization))
    Ai::Configuration.reset!

    table = Embeddings::VersionDrift.call.tables.find { |t| t.key == :tickets }

    expect(table.stale).to eq(0)
  end

  it "answers an AI request with the chat model of the request's organization" do
    group = create(:error_group)
    organization = group.project.organization
    customize(organization)
    request = create(:ai_request, organization:, kind: "error_triage", args: { "group_id" => group.id })
    used = nil
    allow(Errors::TriageWithAi).to receive(:call) do
      used = Ai::Configuration.current.chat_model
      Result.ok({})
    end

    Ai::RunJob.perform_now(request)

    expect(used).to eq("chat-acme")
  end
end
