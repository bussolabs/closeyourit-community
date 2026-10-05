# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::RecordActivity do
  let(:org) { create(:organization) }
  let(:ticket) { create(:ticket, organization: org) }
  let(:actor) { ticket.reporter }

  it "crea un Ticketing::Event con organization_id derivato dal ticket" do
    expect do
      described_class.call(ticket: ticket, action: "status_changed", actor: actor)
    end.to change(Ticketing::Event, :count).by(1)

    event = Ticketing::Event.last
    expect(event.ticket).to eq(ticket)
    expect(event.organization_id).to eq(ticket.project.organization_id)
    expect(event.action).to eq("status_changed")
  end

  it "snapshotta il nome dell'attore" do
    event = described_class.call(ticket: ticket, action: "status_changed", actor: actor)
    expect(event.actor).to eq(actor)
    expect(event.actor_name).to eq(actor.name)
  end

  it "registra true_actor quando presente (impersonation)" do
    god = create(:account)
    event = described_class.call(ticket: ticket, action: "status_changed", actor: actor, true_actor: god)
    expect(event.true_actor).to eq(god)
    expect(event).to be_impersonated
  end

  it "ammette actor e true_actor nil (evento di sistema)" do
    event = described_class.call(ticket: ticket, action: "status_changed")
    expect(event.actor).to be_nil
    expect(event.actor_name).to be_nil
  end

  it "stringifica le chiavi del data (symbol → string)" do
    event = described_class.call(
      ticket: ticket, action: "status_changed",
      data: { status: { from: "A", to: "B" } }
    )
    expect(event.reload.data).to eq("status" => { "from" => "A", "to" => "B" })
  end

  it "ritorna l'Event creato (non un Result)" do
    result = described_class.call(ticket: ticket, action: "status_changed", actor: actor)
    expect(result).to be_a(Ticketing::Event)
  end

  it "solleva su action invalida (la transazione del chiamante farà rollback)" do
    expect do
      described_class.call(ticket: ticket, action: "bogus", actor: actor)
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  # Choke point realtime: RecordActivity è chiamato da OGNI service di mutazione, quindi appende qui
  # fa apparire live in timeline ogni azione. Il broadcast DEVE partire dopo il commit (il service gira
  # dentro la transazione del chiamante) → incapsulato in ActiveRecord.after_all_transactions_commit.
  describe "broadcast realtime in timeline" do
    it "registra l'append come after-commit (mai prima del commit della transazione)" do
      # Se after_all_transactions_commit NON esegue il blocco, NESSUN broadcast parte: prova che
      # l'append è deferito al commit, non emesso inline dentro la transazione del chiamante.
      allow(ActiveRecord).to receive(:after_all_transactions_commit) # blocco non eseguito
      expect(Turbo::StreamsChannel).not_to receive(:broadcast_append_to)
      described_class.call(ticket: ticket, action: "status_changed", actor: actor)
    end

    it "appende l'evento alla timeline del ticket (stream tenant-scoped, target+partial del contratto)" do
      allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield
      expect(Turbo::StreamsChannel).to receive(:broadcast_append_to).with(
        Realtime::Streams.ticket(ticket),
        target: "ticket_timeline_#{ticket.id}", partial: "member/tickets/event", locals: anything
      )
      described_class.call(ticket: ticket, action: "status_changed", actor: actor)
    end

    it "consegna realtime sullo stream del ticket (wiring ActionCable + render end-to-end)" do
      allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield
      expect do
        described_class.call(ticket: ticket, action: "status_changed", actor: actor,
                             data: { status: { from: "Open", to: "Closed" } })
      end.to have_broadcasted_to(Realtime::Streams.ticket(ticket))
    end
  end
end
