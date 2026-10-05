# frozen_string_literal: true

require "rails_helper"

RSpec.describe Todos::Shares::SetShares do
  let(:owner) { create(:account) }
  let(:organization) { create(:organization) }
  let(:list) { create(:todo_list, account: owner, organization: organization) }

  def member!
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end

  describe "#call" do
    it "condivide con i membri indicati" do
      m1 = member!
      m2 = member!
      result = described_class.call(list: list, account_ids: [ m1.id, m2.id ])
      expect(result).to be_ok
      expect(list.shared_accounts).to contain_exactly(m1, m2)
    end

    it "rimuove i destinatari non più presenti (diff)" do
      m1 = member!
      m2 = member!
      create(:todo_share, list: list, account: m1)
      create(:todo_share, list: list, account: m2)

      described_class.call(list: list, account_ids: [ m1.id ])
      expect(list.reload.shared_accounts).to contain_exactly(m1)
    end

    it "con insieme vuoto rimuove tutte le condivisioni" do
      create(:todo_share, list: list, account: member!)
      result = described_class.call(list: list, account_ids: [])
      expect(result).to be_ok
      expect(list.reload.shares).to be_empty
    end

    it "è idempotente (nessun doppione)" do
      m1 = member!
      described_class.call(list: list, account_ids: [ m1.id ])
      expect { described_class.call(list: list, account_ids: [ m1.id ]) }.not_to change(Todos::Share, :count)
    end

    it "rifiuta un destinatario non membro → R422-TODOSHARE-001 e non muta nulla" do
      outsider = create(:account)
      existing = member!
      create(:todo_share, list: list, account: existing)

      result = described_class.call(list: list, account_ids: [ existing.id, outsider.id ])
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TODOSHARE-001")
      # atomico: la condivisione preesistente resta intatta, l'outsider non è aggiunto
      expect(list.reload.shared_accounts).to contain_exactly(existing)
    end

    it "rifiuta il proprietario come destinatario" do
      result = described_class.call(list: list, account_ids: [ owner.id ])
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TODOSHARE-001")
    end
  end
end
