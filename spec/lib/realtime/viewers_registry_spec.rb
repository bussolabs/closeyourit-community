# frozen_string_literal: true

require "rails_helper"

# Registro TTL dei viewer per-risorsa (Task D2). Conta ACCOUNT distinti (due token/tab dello stesso
# account = 1 persona) e ripulisce i viewer scaduti via TTL. Store iniettato (MemoryStore) perché in
# test il cache_store dell'app è :null_store (no-op).
RSpec.describe Realtime::ViewersRegistry do
  let(:stream) { "org:1:viewers:abc" }

  around do |example|
    previous = described_class.store
    described_class.store = ActiveSupport::Cache::MemoryStore.new
    example.run
    described_class.store = previous
  end

  describe ".register / .count" do
    it "un viewer → conteggio 1" do
      expect(described_class.register(stream, token: "t1", account_id: "acc-a")).to eq(1)
      expect(described_class.count(stream)).to eq(1)
    end

    it "due account distinti → conteggio 2" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      expect(described_class.register(stream, token: "t2", account_id: "acc-b")).to eq(2)
    end

    it "due token dello STESSO account (due tab) → conteggio 1 (per-persona)" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      expect(described_class.register(stream, token: "t2", account_id: "acc-a")).to eq(1)
    end

    it "lo stesso token re-registrato non duplica" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      expect(described_class.register(stream, token: "t1", account_id: "acc-a")).to eq(1)
    end

    it "stream senza viewer → 0" do
      expect(described_class.count(stream)).to eq(0)
    end

    it "isola gli stream tra loro (no leak cross-risorsa)" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      expect(described_class.count("org:1:viewers:other")).to eq(0)
    end
  end

  describe ".unregister" do
    it "rimuove il token e decrementa" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      described_class.register(stream, token: "t2", account_id: "acc-b")
      expect(described_class.unregister(stream, token: "t2")).to eq(1)
      expect(described_class.count(stream)).to eq(1)
    end

    it "chiudere uno dei due tab dello stesso account NON azzera (l'altro resta)" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      described_class.register(stream, token: "t2", account_id: "acc-a")
      expect(described_class.unregister(stream, token: "t2")).to eq(1)
    end

    it "rimuovere l'ultimo viewer → 0" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      expect(described_class.unregister(stream, token: "t1")).to eq(0)
      expect(described_class.count(stream)).to eq(0)
    end

    it "token inesistente è no-op (conteggio invariato)" do
      described_class.register(stream, token: "t1", account_id: "acc-a")
      expect(described_class.unregister(stream, token: "ghost")).to eq(1)
    end
  end

  describe "TTL — viewer scaduti (confine ±1s)" do
    it "un viewer non rinfrescato scade subito DOPO il TTL" do
      described_class.register(stream, token: "t1", account_id: "acc-a", ttl: 30)
      travel(31.seconds) { expect(described_class.count(stream)).to eq(0) }
    end

    it "il viewer resta vivo subito PRIMA del TTL" do
      described_class.register(stream, token: "t1", account_id: "acc-a", ttl: 30)
      travel(29.seconds) { expect(described_class.count(stream)).to eq(1) }
    end

    it "register rinfresca la scadenza (heartbeat): il viewer sopravvive oltre il TTL iniziale" do
      described_class.register(stream, token: "t1", account_id: "acc-a", ttl: 30)
      travel(20.seconds) { described_class.register(stream, token: "t1", account_id: "acc-a", ttl: 30) }
      travel(45.seconds) { expect(described_class.count(stream)).to eq(1) }
    end

    it "un account con un viewer scaduto e uno vivo conta comunque 1" do
      described_class.register(stream, token: "t-old", account_id: "acc-a", ttl: 10)
      described_class.register(stream, token: "t-new", account_id: "acc-a", ttl: 60)
      travel(20.seconds) { expect(described_class.count(stream)).to eq(1) }
    end
  end
end
