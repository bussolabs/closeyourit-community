# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::PromoteToTicket, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:idea) { create(:idea, organization:, project:, title: "Dark mode") }

  before { Types::InstallDefaults.call(organization:) }

  it "crea il ticket, congela l'idea e salva il backlink" do
    result = described_class.call(idea:, reporter: owner,
                                  params: { title: "Dark mode per la dashboard", description: "Sintesi AI" })

    expect(result).to be_ok
    ticket = result.value
    expect(ticket.title).to eq("Dark mode per la dashboard")
    expect(ticket.description).to eq("Sintesi AI")
    expect(ticket.reporter).to eq(owner)

    idea.reload
    expect(idea).to be_status_converted
    expect(idea.ticket).to eq(ticket)
    expect(idea.converted_at).to be_present
    expect(ticket.idea).to eq(idea)
  end

  it "default: kind story, status open, priority medium" do
    ticket = described_class.call(idea:, reporter: owner, params: { description: "testo" }).value

    expect(ticket).to be_kind_story
    expect(ticket.status.code).to eq("open")
    expect(ticket.priority.code).to eq("medium")
    expect(ticket.title).to eq("Dark mode")
  end

  it "kind esplicito: vince sul default story" do
    ticket = described_class.call(idea:, reporter: owner, params: { kind: "bug", description: "testo" }).value

    expect(ticket).to be_kind_bug
  end

  it "idea già convertita → R422-IDEA-003, nessun secondo ticket (idempotenza)" do
    described_class.call(idea:, reporter: owner, params: { description: "prima" })

    expect do
      result = described_class.call(idea: idea.reload, reporter: owner, params: { description: "seconda" })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-IDEA-003")
    end.not_to change(Ticketing::Ticket, :count)
  end

  it "idea archiviata → R422-IDEA-002, nessun ticket" do
    archived = create(:idea, :archived, organization:, project:)

    expect do
      result = described_class.call(idea: archived, reporter: owner, params: { description: "x" })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-IDEA-002")
    end.not_to change(Ticketing::Ticket, :count)
  end

  it "reporter senza accesso al progetto → propaga R404-TICKET-001 (CreateTicket scoping)" do
    member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }

    result = described_class.call(idea:, reporter: member, params: { description: "x" })

    expect(result).to be_err
    expect(result.error.code).to eq("R404-TICKET-001")
    expect(idea.reload).to be_status_open
  end

  it "description vuota → propaga la validazione ticket, idea resta aperta" do
    result = described_class.call(idea:, reporter: owner, params: { description: "" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-001")
    expect(idea.reload).to be_status_open
  end
end
