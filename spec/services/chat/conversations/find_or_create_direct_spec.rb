# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Conversations::FindOrCreateDirect do
  let(:org) { create(:organization) }
  let(:shared_project) { create(:project, organization: org) }

  def member_with_shared_project
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    create(:project_membership, account: account, project: shared_project)
    account
  end

  describe "gating" do
    it "rifiuta la chat con sé stessi (R422-CHAT-001)" do
      account = member_with_shared_project
      result = described_class.call(organization: org, account_a: account, account_b: account)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHAT-001")
    end

    it "rifiuta se un account non è membro dell'org (R422-CHAT-002)" do
      a = member_with_shared_project
      b = create(:account) # non membro
      result = described_class.call(organization: org, account_a: a, account_b: b)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHAT-002")
    end

    it "rifiuta senza progetto in comune (R403-CHAT-003)" do
      a = member_with_shared_project
      b = create(:account)
      create(:membership, account: b, organization: org, role: :member)
      create(:project_membership, account: b, project: create(:project, organization: org)) # progetto diverso
      result = described_class.call(organization: org, account_a: a, account_b: b)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHAT-003")
      expect(result.error.status).to eq(:forbidden)
    end
  end

  describe "creazione" do
    it "crea il DM con le due righe partecipante" do
      a = member_with_shared_project
      b = member_with_shared_project
      result = described_class.call(organization: org, account_a: a, account_b: b)

      expect(result).to be_ok
      conversation = result.value
      expect(conversation.kind_direct?).to be(true)
      expect(conversation.direct_key).to be_present
      expect(conversation.accounts).to contain_exactly(a, b)
    end

    it "è idempotente: seconda chiamata → stessa conversazione, niente doppioni" do
      a = member_with_shared_project
      b = member_with_shared_project
      first = described_class.call(organization: org, account_a: a, account_b: b).value
      second = described_class.call(organization: org, account_a: a, account_b: b).value

      expect(second.id).to eq(first.id)
      expect(Chat::Conversation.where(organization: org).kind_direct.count).to eq(1)
      expect(first.participants.count).to eq(2)
    end

    it "è canonica: l'ordine dei due account non cambia la conversazione" do
      a = member_with_shared_project
      b = member_with_shared_project
      ab = described_class.call(organization: org, account_a: a, account_b: b).value
      ba = described_class.call(organization: org, account_a: b, account_b: a).value
      expect(ba.id).to eq(ab.id)
    end

    it "usa l'actor esplicito come created_by (default = account_a)" do
      a = member_with_shared_project
      b = member_with_shared_project
      result = described_class.call(organization: org, account_a: a, account_b: b, actor: b)
      expect(result.value.created_by).to eq(b)
    end

    it "riapre il DM esistente anche se la coppia non condivide più progetti (gate solo alla creazione)" do
      a = member_with_shared_project
      b = member_with_shared_project
      existing = described_class.call(organization: org, account_a: a, account_b: b).value
      Connections::ProjectMembership.where(account_id: [ a.id, b.id ], project_id: shared_project.id).destroy_all

      result = described_class.call(organization: org, account_a: a, account_b: b)
      expect(result).to be_ok
      expect(result.value.id).to eq(existing.id)
    end

    it "sopravvive alla race sull'INSERT concorrente (RecordNotUnique → rilegge)" do
      a = member_with_shared_project
      b = member_with_shared_project
      key = Chat::Conversation.direct_key_for(a, b)
      winner = Chat::Conversation.create!(organization: org, kind: :direct, direct_key: key)

      # Simula il perdente della race: find_or_create_by esplode come se un'altra richiesta avesse
      # appena inserito la stessa direct_key (il find_by iniziale del service viene bypassato).
      allow(Chat::Conversation).to receive(:find_by).and_return(nil, winner)
      allow(Chat::Conversation).to receive(:find_or_create_by)
        .and_raise(ActiveRecord::RecordNotUnique)

      result = described_class.call(organization: org, account_a: a, account_b: b)
      expect(result).to be_ok
      expect(result.value.id).to eq(winner.id)
    end
  end

  describe "conversazione non persistita (path difensivo)" do
    let(:a) { member_with_shared_project }
    let(:b) { member_with_shared_project }

    it "ritorna err con i dettagli di validazione (R422-CHAT-004)" do
      allow(Chat::Conversation).to receive(:find_or_create_by).and_return(Chat::Conversation.new)
      result = described_class.call(organization: org, account_a: a, account_b: b)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHAT-004")
    end

    it "ritorna err anche se il find_or_create è nil (race)" do
      allow(Chat::Conversation).to receive(:find_or_create_by).and_return(nil)
      result = described_class.call(organization: org, account_a: a, account_b: b)
      expect(result).to be_err
    end
  end
end
