# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::List, type: :model do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  describe "validazioni" do
    it "richiede un nome" do
      expect(build(:todo_list, account: account, organization: organization, name: "  ")).not_to be_valid
    end

    it "nome unico per (account, organizzazione)" do
      create(:todo_list, account: account, organization: organization, name: "Oggi")
      expect(build(:todo_list, account: account, organization: organization, name: "Oggi")).not_to be_valid
    end

    it "lo stesso nome è ammesso per account diversi (isolamento)" do
      create(:todo_list, account: account, organization: organization, name: "Oggi")
      expect(build(:todo_list, account: create(:account), organization: organization, name: "Oggi")).to be_valid
    end

    it "lo stesso nome è ammesso in organizzazioni diverse (isolamento)" do
      create(:todo_list, account: account, organization: organization, name: "Oggi")
      expect(build(:todo_list, account: account, organization: create(:organization), name: "Oggi")).to be_valid
    end
  end

  describe "normalizzazione" do
    it "strippa il nome" do
      expect(create(:todo_list, account: account, organization: organization, name: "  Oggi  ").name).to eq("Oggi")
    end

    it "riporta il colore vuoto a nil" do
      expect(create(:todo_list, account: account, organization: organization, color: "  ").color).to be_nil
    end
  end

  describe ".for" do
    it "ritorna solo le liste dell'account nell'org" do
      mine = create(:todo_list, account: account, organization: organization)
      create(:todo_list, account: create(:account), organization: organization)
      create(:todo_list, account: account, organization: create(:organization))
      expect(described_class.for(account: account, organization: organization)).to contain_exactly(mine)
    end
  end

  describe ".ordered" do
    it "ordina per position poi per name" do
      b = create(:todo_list, account: account, organization: organization, name: "B", position: 0)
      a = create(:todo_list, account: account, organization: organization, name: "A", position: 0)
      z = create(:todo_list, account: account, organization: organization, name: "Z", position: -1)
      expect(described_class.for(account: account, organization: organization).ordered).to eq([ z, a, b ])
    end
  end

  describe ".shared_with" do
    it "ritorna le liste condivise CON l'account (non quelle possedute)" do
      recipient = create(:account)
      create(:membership, account: recipient, organization: organization, role: :member)
      shared = create(:todo_list, account: account, organization: organization)
      create(:todo_share, list: shared, account: recipient)
      create(:todo_list, account: account, organization: organization) # non condivisa

      expect(described_class.shared_with(recipient)).to contain_exactly(shared)
    end
  end

  describe "#items_count / #done_count" do
    it "conta 0 item su lista vuota" do
      list = create(:todo_list, account: account, organization: organization)
      expect(list.items_count).to eq(0)
      expect(list.done_count).to eq(0)
    end

    it "conta gli item e quelli fatti (N)" do
      list = create(:todo_list, account: account, organization: organization)
      create(:todo_item, list: list, done: true)
      create(:todo_item, list: list, done: true)
      create(:todo_item, list: list, done: false)
      expect(list.reload.items_count).to eq(3)
      expect(list.done_count).to eq(2)
    end
  end

  describe "distruzione a cascata" do
    it "distrugge gli item della lista" do
      list = create(:todo_list, account: account, organization: organization)
      create(:todo_item, list: list)
      expect { list.destroy }.to change(Todos::Item, :count).by(-1)
    end

    it "distrugge le condivisioni della lista" do
      recipient = create(:account)
      create(:membership, account: recipient, organization: organization, role: :member)
      list = create(:todo_list, account: account, organization: organization)
      create(:todo_share, list: list, account: recipient)
      expect { list.destroy }.to change(Todos::Share, :count).by(-1)
    end

    it "cade con l'account proprietario" do
      owner = create(:account)
      create(:todo_list, account: owner, organization: organization)
      expect { owner.destroy }.to change(Todos::List, :count).by(-1)
    end

    it "cade con l'organizzazione" do
      org = create(:organization)
      create(:todo_list, account: account, organization: org)
      expect { org.destroy }.to change(Todos::List, :count).by(-1)
    end
  end
end
