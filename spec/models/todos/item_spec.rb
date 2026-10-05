# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Item, type: :model do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:list) { create(:todo_list, account: account, organization: organization) }

  describe "validazioni" do
    it "richiede un titolo" do
      expect(build(:todo_item, list: list, title: "  ")).not_to be_valid
    end

    it "strippa il titolo" do
      expect(create(:todo_item, list: list, title: "  Fix login  ").title).to eq("Fix login")
    end
  end

  describe "done di default" do
    it "un nuovo item non è fatto" do
      expect(create(:todo_item, list: list).done?).to be(false)
    end
  end

  describe "#mark / #toggle!" do
    it "mark(done: true) imposta done e completed_at" do
      item = create(:todo_item, list: list)
      item.mark(done: true)
      item.save!
      expect(item.done?).to be(true)
      expect(item.completed_at).to be_present
    end

    it "mark(done: false) azzera completed_at" do
      item = create(:todo_item, :done, list: list)
      item.mark(done: false)
      item.save!
      expect(item.done?).to be(false)
      expect(item.completed_at).to be_nil
    end

    it "toggle! inverte lo stato" do
      item = create(:todo_item, list: list, done: false)
      expect { item.toggle! }.to change { item.reload.done? }.from(false).to(true)
      expect { item.toggle! }.to change { item.reload.done? }.from(true).to(false)
    end
  end

  describe "link al ticket (tenant-integrity)" do
    it "ammette un ticket della stessa organizzazione della lista" do
      ticket = create(:ticket, organization: organization)
      expect(build(:todo_item, list: list, ticket: ticket)).to be_valid
    end

    it "rifiuta un ticket di un'altra organizzazione" do
      ticket = create(:ticket, organization: create(:organization))
      item = build(:todo_item, list: list, ticket: ticket)
      expect(item).not_to be_valid
      expect(item.errors[:ticket]).to be_present
    end

    it "è valido senza ticket (link opzionale)" do
      expect(build(:todo_item, list: list, ticket: nil)).to be_valid
    end
  end

  describe "cancellazione del ticket linkato" do
    it "azzera il link ma NON distrugge l'item (nullify)" do
      ticket = create(:ticket, organization: organization)
      item = create(:todo_item, list: list, ticket: ticket)
      expect { ticket.destroy }.not_to change(Todos::Item, :count)
      expect(item.reload.ticket_id).to be_nil
    end
  end

  describe ".ordered" do
    it "ordina per position" do
      c = create(:todo_item, list: list, position: 2)
      a = create(:todo_item, list: list, position: 0)
      b = create(:todo_item, list: list, position: 1)
      expect(list.items.ordered).to eq([ a, b, c ])
    end
  end
end
