# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::TicketLink, type: :model do
  describe "validazioni" do
    it "è valida con ticket, related e created_by" do
      expect(build(:ticket_link)).to be_valid
    end

    it "impedisce il doppione sulla stessa coppia [ticket, related]" do
      link = create(:ticket_link)
      dup = build(:ticket_link, ticket: link.ticket, related: link.related, created_by: link.created_by)
      expect(dup).not_to be_valid
      expect(dup.errors[:related_id]).to be_present
    end

    it "impedisce il self-link" do
      ticket = create(:ticket)
      link = build(:ticket_link, ticket: ticket, related: ticket, created_by: ticket.reporter)
      expect(link).not_to be_valid
      expect(link.errors[:related]).to be_present
    end

    it "impedisce il link tra ticket di organizzazioni diverse" do
      ticket = create(:ticket)
      other_org_ticket = create(:ticket, organization: create(:organization))
      link = build(:ticket_link, ticket: ticket, related: other_org_ticket, created_by: ticket.reporter)
      expect(link).not_to be_valid
      expect(link.errors[:related]).to be_present
    end
  end

  describe "kind" do
    it "espone duplicate e related con default duplicate" do
      expect(described_class.new.kind).to eq("duplicate")
      expect(build(:ticket_link, kind: :related)).to be_valid
    end
  end

  describe ".involving" do
    it "trova il link da entrambe le direzioni e non da un terzo ticket" do
      link = create(:ticket_link)
      stranger = create(:ticket, organization: link.ticket.project.organization)

      expect(described_class.involving(link.ticket)).to include(link)
      expect(described_class.involving(link.related)).to include(link)
      expect(described_class.involving(stranger)).to be_empty
    end
  end

  describe "#other_ticket" do
    it "ritorna il capo opposto della relazione" do
      link = create(:ticket_link)
      expect(link.other_ticket(link.ticket)).to eq(link.related)
      expect(link.other_ticket(link.related)).to eq(link.ticket)
    end
  end

  describe "cascade" do
    it "cade con il ticket (da entrambe le direzioni)" do
      link = create(:ticket_link)
      expect { link.ticket.destroy! }.to change(described_class, :count).by(-1)

      other = create(:ticket_link)
      expect { other.related.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
