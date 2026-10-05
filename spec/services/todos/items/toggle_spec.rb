# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Items::Toggle do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:list) { create(:todo_list, account: account, organization: organization) }

  describe "#call" do
    it "inverte non-fatto → fatto e imposta completed_at" do
      item = create(:todo_item, list: list, done: false)
      result = described_class.call(item: item)
      expect(result).to be_ok
      expect(item.reload.done?).to be(true)
      expect(item.completed_at).to be_present
    end

    it "inverte fatto → non-fatto e azzera completed_at" do
      item = create(:todo_item, :done, list: list)
      described_class.call(item: item)
      expect(item.reload.done?).to be(false)
      expect(item.completed_at).to be_nil
    end

    it "done: true esplicito completa la voce" do
      item = create(:todo_item, list: list, done: false)
      described_class.call(item: item, done: true)
      expect(item.reload.done?).to be(true)
    end

    it "done: false esplicito riapre la voce" do
      item = create(:todo_item, :done, list: list)
      described_class.call(item: item, done: false)
      expect(item.reload.done?).to be(false)
    end

    it "salvataggio fallito → Result.err R422-TODOITEM-001" do
      item = create(:todo_item, list: list, done: false)
      allow(item).to receive(:save).and_return(false)

      result = described_class.call(item: item)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TODOITEM-001")
    end
  end
end
