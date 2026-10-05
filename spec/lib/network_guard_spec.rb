# frozen_string_literal: true

require "rails_helper"

RSpec.describe NetworkGuard do
  describe ".safe_url?" do
    it "vera per https pubblica" do
      allow(described_class).to receive(:resolve).and_return([ "93.184.216.34" ])
      expect(described_class.safe_url?("https://example.test/hook")).to be(true)
    end

    it "falsa per schema non http(s)" do
      expect(described_class.safe_url?("ftp://example.test/x")).to be(false)
    end

    it "falsa per host interno" do
      allow(described_class).to receive(:resolve).and_return([ "10.0.0.5" ])
      expect(described_class.safe_url?("https://interno.test/x")).to be(false)
    end

    it "falsa per URL malformata" do
      expect(described_class.safe_url?("http://[bad")).to be(false)
    end
  end

  describe ".resolved_public_address" do
    it "ritorna il primo IP per un host pubblico" do
      allow(described_class).to receive(:resolve).and_return([ "93.184.216.34" ])
      expect(described_class.resolved_public_address("example.test")).to eq("93.184.216.34")
    end

    it "nil se l'host risolve a un indirizzo interno" do
      allow(described_class).to receive(:resolve).and_return([ "10.0.0.10" ])
      expect(described_class.resolved_public_address("interno.test")).to be_nil
    end

    it "nil se UNO degli indirizzi è interno (record misti pubblico+interno → sospetto)" do
      allow(described_class).to receive(:resolve).and_return([ "93.184.216.34", "127.0.0.1" ])
      expect(described_class.resolved_public_address("misto.test")).to be_nil
    end

    it "nil per il metadata cloud 169.254.169.254" do
      expect(described_class.resolved_public_address("169.254.169.254")).to be_nil
    end

    it "nil per host blank (nil e stringa vuota)" do
      expect(described_class.resolved_public_address(nil)).to be_nil
      expect(described_class.resolved_public_address("")).to be_nil
    end

    it "nil se il DNS non risolve (lista vuota)" do
      allow(described_class).to receive(:resolve).and_return([])
      expect(described_class.resolved_public_address("nope.invalid")).to be_nil
    end

    it "nil se un indirizzo risolto non è un IP valido" do
      allow(described_class).to receive(:resolve).and_return([ "not-an-ip" ])
      expect(described_class.resolved_public_address("weird.test")).to be_nil
    end

    it "IP letterale pubblico → ritornato senza interrogare il DNS" do
      expect(described_class).not_to receive(:resolve)
      expect(described_class.resolved_public_address("93.184.216.34")).to eq("93.184.216.34")
    end

    it "IP letterale interno → nil senza interrogare il DNS" do
      expect(described_class).not_to receive(:resolve)
      expect(described_class.resolved_public_address("192.168.1.1")).to be_nil
    end

    it "blocca IPv6 loopback ::1" do
      expect(described_class.resolved_public_address("::1")).to be_nil
    end
  end

  describe ".resolve — timeout DNS (CYRA-273)" do
    it "risolve con un tempo limite esplicito invece del resolver di sistema senza timeout" do
      resolver = instance_double(Resolv::DNS)
      expect(Resolv::DNS).to receive(:new).and_return(resolver)
      expect(resolver).to receive(:timeouts=).with(NetworkGuard::DNS_TIMEOUTS)
      allow(resolver).to receive(:getaddresses).and_return([ Resolv::IPv4.create("93.184.216.34") ])
      allow(resolver).to receive(:close)

      expect(described_class.resolve("example.test")).to eq([ "93.184.216.34" ])
    end

    it "ritorna [] (host irrisolvibile) se il resolver solleva per timeout scaduto" do
      resolver = instance_double(Resolv::DNS)
      allow(Resolv::DNS).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:timeouts=)
      allow(resolver).to receive(:getaddresses).and_raise(Resolv::ResolvError)
      allow(resolver).to receive(:close)

      expect(described_class.resolve("dead-ns.test")).to eq([])
    end
  end
end
