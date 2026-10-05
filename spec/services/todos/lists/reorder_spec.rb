# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Lists::Reorder do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  describe "#call" do
    it "assegna la posizione secondo l'ordine degli id" do
      a = create(:todo_list, account: account, organization: organization, position: 0)
      b = create(:todo_list, account: account, organization: organization, position: 0)
      c = create(:todo_list, account: account, organization: organization, position: 0)

      described_class.call(account: account, organization: organization, ordered_ids: [ c.id, a.id, b.id ])

      expect(c.reload.position).to eq(0)
      expect(a.reload.position).to eq(1)
      expect(b.reload.position).to eq(2)
    end

    it "ignora id non posseduti (anti-BOLA)" do
      mine = create(:todo_list, account: account, organization: organization, position: 5)
      other = create(:todo_list, account: create(:account), organization: organization, position: 5)

      described_class.call(account: account, organization: organization, ordered_ids: [ other.id, mine.id ])

      expect(other.reload.position).to eq(5) # invariato: non è mio
      expect(mine.reload.position).to eq(1)
    end

    it "ritorna Result.ok" do
      expect(described_class.call(account: account, organization: organization, ordered_ids: [])).to be_ok
    end
  end
end
