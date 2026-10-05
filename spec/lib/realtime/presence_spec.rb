# frozen_string_literal: true

require "rails_helper"

# Store di presenza (Realtime::Presence). Confini coperti: relazione 0/1/N online, multi-tab
# (contatore add/remove), TTL ai bordi (±1s con travel_to), heartbeat che estende la vita,
# isolamento tenant (chiave org-prefissata + ri-scoping sui membri reali). Usa un MemoryStore
# reale perché in test Rails.cache è :null_store.
RSpec.describe Realtime::Presence do
  include_context "realtime presence cache"

  let(:organization) { create(:organization) }
  let(:account) { create(:account, name: "Bob") }
  let!(:membership) { create(:membership, account: account, organization: organization) }

  def online_ids(org = organization) = described_class.online(org).map(&:id)

  describe ".add / .online" do
    it "nessuno online di default (relazione 0)" do
      expect(described_class.online(organization)).to be_empty
    end

    it "dopo add l'account è online (relazione 1)" do
      described_class.add(organization, account)
      expect(online_ids).to contain_exactly(account.id)
    end

    it "online con N account, ordinati per nome" do
      ann = create(:account, name: "Ann")
      create(:membership, account: ann, organization: organization)
      described_class.add(organization, account) # Bob
      described_class.add(organization, ann)     # Ann

      expect(described_class.online(organization).to_a).to eq([ ann, account ])
    end
  end

  describe ".remove — multi-tab (contatore)" do
    it "due tab aperte: una remove NON porta offline, la seconda sì" do
      described_class.add(organization, account) # tab 1
      described_class.add(organization, account) # tab 2

      described_class.remove(organization, account)
      expect(online_ids).to contain_exactly(account.id)

      described_class.remove(organization, account)
      expect(online_ids).to be_empty
    end

    it "remove di un account mai aggiunto è no-op (nessun errore)" do
      expect { described_class.remove(organization, account) }.not_to raise_error
      expect(online_ids).to be_empty
    end
  end

  describe "TTL ai confini" do
    it "resta online appena PRIMA della scadenza e sparisce DOPO" do
      freeze_time
      described_class.add(organization, account)

      travel(described_class::TTL - 1.second)
      expect(online_ids).to contain_exactly(account.id)

      travel(2.seconds) # ora oltre il TTL
      expect(online_ids).to be_empty
    end

    it "touch (heartbeat) entro la finestra estende la vita oltre il TTL originale" do
      freeze_time
      described_class.add(organization, account)

      travel(described_class::TTL - 5.seconds)
      described_class.touch(organization, account) # rinfresca la scadenza

      travel(10.seconds) # oltre il TTL dall'add, ma entro il TTL dal touch
      expect(online_ids).to contain_exactly(account.id)
    end

    it "touch ri-aggancia un account assente (upsert resiliente alle race)" do
      described_class.touch(organization, account)
      expect(online_ids).to contain_exactly(account.id)
    end

    it "touch riaggancia un'entry col contatore azzerato (tabs < 1) → tab riportata a 1" do
      # Stato di race: un'entry persistita con tabs 0 (normalmente impossibile via API). touch la sana.
      described_class.send(:mutate, organization) do |roster|
        roster[account.id] = { "tabs" => 0, "expires_at" => (Time.current + 60).to_f }
      end

      described_class.touch(organization, account)

      expect(online_ids).to contain_exactly(account.id)
    end
  end

  describe ".org_id (accetta oggetto org o id grezzo)" do
    it "da un oggetto organization ritorna il suo id" do
      expect(described_class.send(:org_id, organization)).to eq(organization.id)
    end

    it "da un id grezzo (non risponde a :id) lo ritorna tale e quale" do
      expect(described_class.send(:org_id, "raw-org-id")).to eq("raw-org-id")
    end
  end

  describe "isolamento tenant" do
    it "la presenza in un'org NON appare in un'altra org" do
      other = create(:organization)
      described_class.add(organization, account)

      expect(described_class.online(other)).to be_empty
    end

    it "online esclude un id presente nel roster ma NON membro dell'org (doppia difesa)" do
      stranger = create(:account, name: "Zoe") # nessuna membership in `organization`
      described_class.add(organization, stranger)
      described_class.add(organization, account)

      expect(online_ids).to contain_exactly(account.id)
    end
  end

  describe "fingerprint (per-viewer)" do
    it "store/last roundtrip per viewer" do
      described_class.store_fingerprint(organization, account, "a,b")
      expect(described_class.last_fingerprint(organization, account)).to eq("a,b")
    end

    it "è isolato per viewer (un altro account non lo vede)" do
      other_viewer = create(:account, name: "Ann")
      described_class.store_fingerprint(organization, account, "a,b")
      expect(described_class.last_fingerprint(organization, other_viewer)).to be_nil
    end

    it "è isolato per organizzazione" do
      other = create(:organization)
      described_class.store_fingerprint(organization, account, "a,b")
      expect(described_class.last_fingerprint(other, account)).to be_nil
    end
  end
end
