# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Share, type: :model do
  let(:owner) { create(:account) }
  let(:organization) { create(:organization) }
  let(:list) { create(:todo_list, account: owner, organization: organization) }
  let(:member) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end

  describe "destinatario membro dell'org" do
    it "ammette un membro dell'org della lista" do
      expect(build(:todo_share, list: list, account: member)).to be_valid
    end

    it "rifiuta un account non membro dell'org (anti-leak cross-tenant)" do
      outsider = create(:account)
      share = build(:todo_share, list: list, account: outsider)
      expect(share).not_to be_valid
      expect(share.errors[:account]).to be_present
    end

    it "rifiuta un membro di un'ALTRA org" do
      other = create(:account)
      create(:membership, account: other, organization: create(:organization), role: :member)
      expect(build(:todo_share, list: list, account: other)).not_to be_valid
    end
  end

  describe "non condividere con sé stessi" do
    it "rifiuta il proprietario come destinatario" do
      share = build(:todo_share, list: list, account: owner)
      expect(share).not_to be_valid
      expect(share.errors[:account]).to be_present
    end
  end

  describe "unicità" do
    it "non ammette due condivisioni con lo stesso membro sulla stessa lista" do
      create(:todo_share, list: list, account: member)
      expect(build(:todo_share, list: list, account: member)).not_to be_valid
    end

    it "ammette lo stesso membro su liste diverse" do
      create(:todo_share, list: list, account: member)
      other_list = create(:todo_list, account: owner, organization: organization)
      expect(build(:todo_share, list: other_list, account: member)).to be_valid
    end
  end

  describe "cancellazione a cascata" do
    it "cade con l'account destinatario" do
      create(:todo_share, list: list, account: member)
      expect { member.destroy }.to change(Todos::Share, :count).by(-1)
    end
  end

  describe "validatori nil-safe (nessun crash sui bordi)" do
    it "account assente → recipient_is_org_member esce presto senza eccezioni" do
      share = described_class.new(list: list, account: nil)
      expect { share.valid? }.not_to raise_error
    end

    it "lista assente → entrambi i validatori escono presto senza eccezioni" do
      share = described_class.new(list: nil, account: member)
      expect { share.valid? }.not_to raise_error
    end
  end
end
