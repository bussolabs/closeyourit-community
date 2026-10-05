# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::SetReviewer do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  # reviewer di default = reporter (factory): lo azzeriamo nei test che partono da "senza revisore".
  let(:ticket) { create(:ticket, organization: org, project: project) }

  def member
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end

  it "imposta un revisore membro (Result.ok)" do
    reviewer = member
    result = described_class.call(organization: org, ticket: ticket, reviewer_id: reviewer.id)
    expect(result).to be_ok
    expect(ticket.reload.reviewer).to eq(reviewer)
  end

  it "id vuoto → rimuove il revisore" do
    ticket.update!(reviewer: member)
    described_class.call(organization: org, ticket: ticket, reviewer_id: "")
    expect(ticket.reload.reviewer).to be_nil
  end

  it "account non membro → revisore invariato (anti-BOLA)" do
    ticket.update!(reviewer: nil)
    outsider = create(:account)
    described_class.call(organization: org, ticket: ticket, reviewer_id: outsider.id)
    expect(ticket.reload.reviewer).to be_nil
  end

  it "NON accoda NotifyJob (il cambio revisore non notifica)" do
    reviewer = member
    expect do
      described_class.call(organization: org, ticket: ticket, reviewer_id: reviewer.id, actor: ticket.reporter)
    end.not_to have_enqueued_job(Ticketing::NotifyJob)
  end

  describe "cronologia" do
    let(:actor) { ticket.reporter }

    it "registra `reviewer_changed` col nome del nuovo revisore" do
      ticket.update!(reviewer: nil)
      reviewer = member
      expect do
        described_class.call(organization: org, ticket: ticket, reviewer_id: reviewer.id, actor: actor)
      end.to change(Ticketing::Event, :count).by(1)

      event = Ticketing::Event.last
      expect(event.action).to eq("reviewer_changed")
      expect(event.actor).to eq(actor)
      expect(event.data).to eq("reviewer" => { "from" => nil, "to" => reviewer.name })
    end

    it "registra la rimozione (to nil)" do
      previous = member
      ticket.update!(reviewer: previous)
      described_class.call(organization: org, ticket: ticket, reviewer_id: "", actor: actor)

      event = Ticketing::Event.last
      expect(event.action).to eq("reviewer_changed")
      expect(event.data).to eq("reviewer" => { "from" => previous.name, "to" => nil })
    end

    it "no-op (stesso revisore) → nessun evento" do
      reviewer = member
      ticket.update!(reviewer: reviewer)
      expect do
        described_class.call(organization: org, ticket: ticket, reviewer_id: reviewer.id, actor: actor)
      end.not_to change(Ticketing::Event, :count)
    end
  end

  # Realtime: replace del display revisore nella sidebar della show, dopo il commit della transazione.
  describe "broadcast realtime del revisore" do
    it "fa il replace del display reviewer sullo stream del ticket (target+partial del contratto)" do
      ticket.update!(reviewer: nil)
      reviewer = member
      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
        Realtime::Streams.ticket(ticket),
        target: "#{ActionView::RecordIdentifier.dom_id(ticket)}_reviewer",
        partial: "member/tickets/reviewer", locals: anything
      )
      described_class.call(organization: org, ticket: ticket, reviewer_id: reviewer.id, actor: ticket.reporter)
    end

    it "no-op (stesso revisore) → nessun broadcast" do
      reviewer = member
      ticket.update!(reviewer: reviewer)
      expect(Turbo::StreamsChannel).not_to receive(:broadcast_replace_to)
      described_class.call(organization: org, ticket: ticket, reviewer_id: reviewer.id, actor: ticket.reporter)
    end
  end
end
