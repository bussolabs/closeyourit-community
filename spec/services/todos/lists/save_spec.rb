# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Lists::Save do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  def build_list(**attrs) = account.todo_lists.build(organization: organization, **attrs)

  describe "#call" do
    it "crea la lista con attributi validi" do
      result = described_class.call(list: build_list, attributes: { name: "Oggi", color: "indigo" })
      expect(result).to be_ok
      expect(result.value).to be_persisted
      expect(result.value.name).to eq("Oggi")
    end

    it "aggiorna una lista esistente" do
      list = create(:todo_list, account: account, organization: organization, name: "Vecchio")
      result = described_class.call(list: list, attributes: { name: "Nuovo" })
      expect(result).to be_ok
      expect(list.reload.name).to eq("Nuovo")
    end

    it "fallisce con nome vuoto → R422-TODOLIST-001" do
      result = described_class.call(list: build_list, attributes: { name: "  " })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TODOLIST-001")
      expect(result.error.details).to have_key(:name)
    end

    it "fallisce con nome duplicato per account+org" do
      create(:todo_list, account: account, organization: organization, name: "Oggi")
      result = described_class.call(list: build_list, attributes: { name: "Oggi" })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TODOLIST-001")
    end
  end
end
