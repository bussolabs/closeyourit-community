# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::AssignTicket do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  def member
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end

  it "assegna un membro (Result.ok)" do
    assignee = member
    result = described_class.call(organization: org, ticket: ticket, assignee_id: assignee.id)
    expect(result).to be_ok
    expect(ticket.reload.assignee).to eq(assignee)
  end

  it "id vuoto → disassegna" do
    ticket.update!(assignee: member)
    described_class.call(organization: org, ticket: ticket, assignee_id: "")
    expect(ticket.reload.assignee).to be_nil
  end

  it "account non membro → resta non assegnato (anti-BOLA)" do
    outsider = create(:account)
    described_class.call(organization: org, ticket: ticket, assignee_id: outsider.id)
    expect(ticket.reload.assignee).to be_nil
  end

  describe "cronologia" do
    let(:actor) { ticket.reporter }

    it "registra `assigned` con il nome del nuovo assegnatario" do
      assignee = member
      expect do
        described_class.call(organization: org, ticket: ticket, assignee_id: assignee.id, actor: actor)
      end.to change(Ticketing::Event, :count).by(1)

      event = Ticketing::Event.last
      expect(event.action).to eq("assigned")
      expect(event.actor).to eq(actor)
      expect(event.data).to eq("assignee" => { "from" => nil, "to" => assignee.name })
    end

    it "registra `unassigned` quando si disassegna" do
      previous = member
      ticket.update!(assignee: previous)
      described_class.call(organization: org, ticket: ticket, assignee_id: "", actor: actor)

      event = Ticketing::Event.last
      expect(event.action).to eq("unassigned")
      expect(event.data).to eq("assignee" => { "from" => previous.name, "to" => nil })
    end

    it "no-op (stesso assegnatario) → nessun evento" do
      assignee = member
      ticket.update!(assignee: assignee)
      expect do
        described_class.call(organization: org, ticket: ticket, assignee_id: assignee.id, actor: actor)
      end.not_to change(Ticketing::Event, :count)
    end

    it "no-op (disassegna un già non assegnato) → nessun evento" do
      expect do
        described_class.call(organization: org, ticket: ticket, assignee_id: "", actor: actor)
      end.not_to change(Ticketing::Event, :count)
    end

    it "registra true_actor in impersonation" do
      god = create(:account)
      described_class.call(organization: org, ticket: ticket, assignee_id: member.id, actor: actor, true_actor: god)
      expect(Ticketing::Event.last.true_actor).to eq(god)
    end
  end

  # Realtime: replace del display assignee nella sidebar della show, dopo il commit della transazione.
  describe "broadcast realtime dell'assegnatario" do
    it "fa il replace del display assignee sullo stream del ticket (target+partial del contratto)" do
      assignee = member
      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
        Realtime::Streams.ticket(ticket),
        target: "#{ActionView::RecordIdentifier.dom_id(ticket)}_assignee",
        partial: "member/tickets/assignee", locals: anything
      )
      described_class.call(organization: org, ticket: ticket, assignee_id: assignee.id, actor: ticket.reporter)
    end

    it "no-op (stesso assegnatario) → nessun broadcast" do
      assignee = member
      ticket.update!(assignee: assignee)
      expect(Turbo::StreamsChannel).not_to receive(:broadcast_replace_to)
      described_class.call(organization: org, ticket: ticket, assignee_id: assignee.id, actor: ticket.reporter)
    end
  end
end
