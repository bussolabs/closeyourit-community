# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Conversation, type: :model do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  describe "validazioni" do
    it "richiede un account" do
      expect(build(:assistant_conversation, account: nil, organization: organization)).not_to be_valid
    end

    it "richiede un'organizzazione" do
      expect(build(:assistant_conversation, account: account, organization: nil)).not_to be_valid
    end
  end

  describe "normalizzazione" do
    it "riporta un titolo vuoto a nil" do
      expect(create(:assistant_conversation, account: account, organization: organization, title: "   ").title).to be_nil
    end

    it "strippa il titolo" do
      expect(create(:assistant_conversation, account: account, organization: organization, title: "  Bug  ").title).to eq("Bug")
    end
  end

  describe ".for" do
    it "ritorna solo le conversazioni dell'account nell'org (anti-BOLA)" do
      mine = create(:assistant_conversation, account: account, organization: organization)
      create(:assistant_conversation, account: create(:account), organization: organization)
      create(:assistant_conversation, account: account, organization: create(:organization))

      expect(described_class.for(account: account, organization: organization)).to contain_exactly(mine)
    end

    # I due assistenti hanno regole opposte — quello del sito indica le pagine, quello con gli
    # attrezzi legge i dati — e condividono la tabella. Il kind è parte del confine: senza, un
    # canale leggerebbe (e cancellerebbe) i thread dell'altro, e la storia di uno finirebbe nel
    # prompt dell'altro.
    it "separa le conversazioni dei due assistenti quando il kind è dichiarato" do
      sito = create(:assistant_conversation, account: account, organization: organization, kind: :help)
      app  = create(:assistant_conversation, account: account, organization: organization, kind: :tools)

      expect(described_class.for(account: account, organization: organization, kind: :tools)).to contain_exactly(app)
      expect(described_class.for(account: account, organization: organization, kind: :help)).to contain_exactly(sito)
    end

    it "senza kind le ritorna tutte, com'era prima" do
      sito = create(:assistant_conversation, account: account, organization: organization, kind: :help)
      app  = create(:assistant_conversation, account: account, organization: organization, kind: :tools)

      expect(described_class.for(account: account, organization: organization)).to contain_exactly(sito, app)
    end
  end

  describe "kind" do
    # Il canale web non lo passa: le conversazioni che nascono lì devono restare quelle di aiuto.
    it "nasce come conversazione di aiuto se nessuno dice altro" do
      expect(create(:assistant_conversation, account: account, organization: organization)).to be_kind_help
    end
  end

  describe ".ordered" do
    it "mette prima l'attività più recente e in coda le conversazioni senza messaggi" do
      vecchia = create(:assistant_conversation, account: account, organization: organization, last_message_at: 2.hours.ago)
      recente = create(:assistant_conversation, account: account, organization: organization, last_message_at: 1.minute.ago)
      vuota   = create(:assistant_conversation, account: account, organization: organization, last_message_at: nil)

      expect(described_class.for(account: account, organization: organization).ordered).to eq([ recente, vecchia, vuota ])
    end
  end

  describe "distruzione" do
    it "elimina i messaggi collegati (dependent: :destroy)" do
      conversation = create(:assistant_conversation, account: account, organization: organization)
      create(:assistant_message, conversation: conversation)

      expect { conversation.destroy }.to change(Assistant::Message, :count).by(-1)
    end
  end
end
