# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Items::Reorder do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:list) { create(:todo_list, account: account, organization: organization) }

  describe "#call" do
    it "assegna la posizione delle voci secondo l'ordine degli id" do
      a = create(:todo_item, list: list, position: 0)
      b = create(:todo_item, list: list, position: 0)
      c = create(:todo_item, list: list, position: 0)

      described_class.call(list: list, ordered_ids: [ c.id, a.id, b.id ])

      expect(c.reload.position).to eq(0)
      expect(a.reload.position).to eq(1)
      expect(b.reload.position).to eq(2)
    end

    it "ignora voci di un'altra lista (anti cross-lista)" do
      mine = create(:todo_item, list: list, position: 7)
      other_list = create(:todo_list, account: account, organization: organization)
      alien = create(:todo_item, list: other_list, position: 7)

      described_class.call(list: list, ordered_ids: [ alien.id, mine.id ])

      expect(alien.reload.position).to eq(7)
      expect(mine.reload.position).to eq(1)
    end
  end
end
