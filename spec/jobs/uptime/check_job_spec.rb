# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::CheckJob, type: :job do
  it "monitor attivo: pinga e registra un check" do
    monitor = create(:uptime_monitor, url: "https://up.test/health")
    allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
    stub_request(:get, "https://up.test/health").to_return(status: 200)
    expect { described_class.perform_now(monitor.id) }.to change(monitor.checks, :count).by(1)
    expect(monitor.reload).to be_status_up
  end

  # CYRA-1239: il ping verso un IPv6 non deve più far fallire il job senza scrivere il check.
  describe "ping verso un indirizzo IPv6" do
    let(:monitor) { create(:uptime_monitor, :ping, host: "ipv6.example.com") }

    before { allow(NetworkGuard).to receive(:resolve).and_return([ "2606:2800:220:1:248:1893:25c8:1946" ]) }

    it "host che risponde → check up registrato" do
      allow_any_instance_of(Uptime::Ping).to receive(:icmp_reachable?).and_return(true)
      expect { described_class.perform_now(monitor.id) }.to change(monitor.checks, :count).by(1)
      expect(monitor.reload).to be_status_up
    end

    it "primo minuto con il solo socket finto: apre ICMPv6 e registra l'esito" do
      socket = instance_double(Socket, connect: 0, send: 1, close: nil)
      expect(Socket).to receive(:new).with(Socket::AF_INET6, Socket::SOCK_DGRAM, Socket::IPPROTO_ICMPV6).and_return(socket)
      allow(socket).to receive(:wait_readable).and_return(socket)
      allow(socket).to receive(:recvfrom).and_return([ [ 129, 0 ].pack("C2"), nil ])
      expect { described_class.perform_now(monitor.id) }.to change(monitor.checks, :count).by(1)
      expect(monitor.reload).to be_status_up
    end

    it "host che non risponde → check down registrato" do
      allow_any_instance_of(Uptime::Ping).to receive(:icmp_reachable?).and_return(false)
      expect { described_class.perform_now(monitor.id) }.to change(monitor.checks, :count).by(1)
      expect(monitor.checks.sole.error).to eq("unreachable")
    end

    it "server senza rete IPv6 → check down con motivo ipv6_unavailable, il job non fallisce" do
      allow(Socket).to receive(:new).and_raise(Errno::EAFNOSUPPORT)
      expect { described_class.perform_now(monitor.id) }.to change(monitor.checks, :count).by(1)
      check = monitor.checks.sole
      expect(check).not_to be_up
      expect(check.error).to eq("ipv6_unavailable")
      expect(monitor.reload.last_checked_at).to be_present
    end

    it "errore di rete qualsiasi → check down registrato" do
      allow_any_instance_of(Uptime::Ping).to receive(:icmp_reachable?).and_raise(Errno::EHOSTUNREACH)
      expect { described_class.perform_now(monitor.id) }.to change(monitor.checks, :count).by(1)
      expect(monitor.checks.sole.error).to eq("ehostunreach")
    end
  end

  it "monitor inesistente → no-op" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end

  it "monitor in pausa → no-op (non attivo)" do
    monitor = create(:uptime_monitor, :paused)
    expect { described_class.perform_now(monitor.id) }.not_to change(Uptime::Check, :count)
  end
end
