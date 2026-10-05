# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Event, type: :model do
  describe "factory" do
    it "produce un evento valido" do
      expect(build(:ticket_event)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede action" do
      expect(build(:ticket_event, action: nil)).not_to be_valid
    end

    it "rifiuta una action fuori dalla allow-list" do
      expect(build(:ticket_event, action: "teleported")).not_to be_valid
    end

    it "accetta ogni action della allow-list" do
      Ticketing::Event::ACTIONS.each do |action|
        expect(build(:ticket_event, action: action)).to be_valid, "#{action} dovrebbe essere valida"
      end
    end

    it "richiede ticket" do
      expect(build(:ticket_event, ticket: nil)).not_to be_valid
    end

    it "richiede organization" do
      expect(build(:ticket_event, organization: nil)).not_to be_valid
    end

    it "ha actor opzionale" do
      expect(build(:ticket_event, actor: nil, actor_name: "Sistema")).to be_valid
    end

    it "ha true_actor opzionale" do
      expect(build(:ticket_event, true_actor: nil)).to be_valid
    end

    it "rifiuta organization diversa da quella del ticket (invariante tenant)" do
      ticket = create(:ticket)
      event = build(:ticket_event, ticket: ticket, organization: create(:organization))
      expect(event).not_to be_valid
      expect(event.errors[:organization]).to be_present
    end

    it "accetta organization coerente col ticket" do
      ticket = create(:ticket)
      event = build(:ticket_event, ticket: ticket, organization: ticket.project.organization)
      expect(event).to be_valid
    end
  end

  describe "#impersonated?" do
    let(:event) { build(:ticket_event) }

    it "è falso quando true_actor è assente" do
      event.true_actor = nil
      expect(event.impersonated?).to be(false)
    end

    it "è falso quando true_actor coincide con actor" do
      event.true_actor = event.actor
      expect(event.impersonated?).to be(false)
    end

    it "è vero quando true_actor differisce da actor" do
      event.true_actor = create(:account)
      expect(event.impersonated?).to be(true)
    end
  end

  describe ".chronological" do
    it "ordina per created_at crescente" do
      ticket = create(:ticket)
      older = create(:ticket_event, ticket: ticket, created_at: 2.hours.ago)
      newer = create(:ticket_event, ticket: ticket, created_at: 1.hour.ago)

      expect(Ticketing::Event.chronological.to_a).to eq([ older, newer ])
    end

    it "a parità di created_at usa il tie-break su :id (ordine totale deterministico)" do
      ticket = create(:ticket)
      instant = 1.hour.ago
      a = create(:ticket_event, ticket: ticket, created_at: instant)
      b = create(:ticket_event, ticket: ticket, created_at: instant)

      expect(Ticketing::Event.chronological.to_a).to eq([ a, b ].sort_by(&:id))
    end
  end

  describe "cancellazione dell'attore (FK on_delete: :nullify)" do
    it "alla destroy dell'account l'evento sopravvive con actor nil e actor_name preservato" do
      ticket = create(:ticket)
      actor = create(:account)
      event = create(:ticket_event,
                     ticket: ticket, organization: ticket.project.organization,
                     actor: actor, actor_name: "Mario Storico")

      expect { actor.destroy! }.to change { event.reload.actor_id }.from(actor.id).to(nil)
      expect(event.actor_name).to eq("Mario Storico")
    end

    it "nullifica anche true_actor alla destroy del god impersonante" do
      ticket = create(:ticket)
      god = create(:account)
      event = create(:ticket_event,
                     ticket: ticket, organization: ticket.project.organization, true_actor: god)

      expect { god.destroy! }.to change { event.reload.true_actor_id }.from(god.id).to(nil)
    end
  end

  describe "data jsonb" do
    it "fa round-trip dell'hash con chiavi stringa" do
      event = create(:ticket_event, data: { "status" => { "from" => "A", "to" => "B" } })
      expect(event.reload.data).to eq("status" => { "from" => "A", "to" => "B" })
    end
  end
end
