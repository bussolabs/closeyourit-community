# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Items::Save do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:list) { create(:todo_list, account: account, organization: organization) }

  describe "#call" do
    it "crea la voce con titolo valido" do
      result = described_class.call(item: list.items.build, attributes: { title: "Fix login" })
      expect(result).to be_ok
      expect(result.value).to be_persisted
      expect(result.value.title).to eq("Fix login")
    end

    it "fallisce con titolo vuoto → R422-TODOITEM-001" do
      result = described_class.call(item: list.items.build, attributes: { title: "  " })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TODOITEM-001")
      expect(result.error.details).to have_key(:title)
    end

    it "ammette il link a un ticket della stessa org" do
      ticket = create(:ticket, organization: organization)
      result = described_class.call(item: list.items.build, attributes: { title: "T", ticket_id: ticket.id })
      expect(result).to be_ok
      expect(result.value.ticket_id).to eq(ticket.id)
    end

    it "rifiuta un ticket di un'altra org → R422-TODOITEM-001" do
      ticket = create(:ticket, organization: create(:organization))
      result = described_class.call(item: list.items.build, attributes: { title: "T", ticket_id: ticket.id })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TODOITEM-001")
      expect(result.error.details).to have_key(:ticket)
    end
  end
end
