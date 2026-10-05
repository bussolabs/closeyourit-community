# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Ping, type: :service do
  let(:monitor) { build(:uptime_monitor, url: "https://up.test/health", expected_status: 200, timeout_seconds: 5) }

  # I test host non risolvono via DNS reale in CI → stub Resolv su un IP pubblico (anti falso-blocco SSRF).
  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  it "status atteso → up con status_code e response_time" do
    stub_request(:get, "https://up.test/health").to_return(status: 200, body: "ok")
    r = described_class.call(monitor: monitor)
    expect(r.up).to be(true)
    expect(r.status_code).to eq(200)
    expect(r.response_time_ms).to be_a(Integer).and be >= 0
    expect(r.error).to be_nil
  end

  it "status diverso dall'atteso → down con error" do
    stub_request(:get, "https://up.test/health").to_return(status: 503)
    r = described_class.call(monitor: monitor)
    expect(r.up).to be(false)
    expect(r.status_code).to eq(503)
    expect(r.error).to include("unexpected_status")
  end

  it "timeout → down, error timeout, niente status/response" do
    stub_request(:get, "https://up.test/health").to_timeout
    r = described_class.call(monitor: monitor)
    expect(r.up).to be(false)
    expect(r.status_code).to be_nil
    expect(r.error).to eq("timeout")
  end

  it "errore di connessione → down" do
    stub_request(:get, "https://up.test/health").to_raise(Errno::ECONNREFUSED)
    r = described_class.call(monitor: monitor)
    expect(r.up).to be(false)
    expect(r.error).to be_present
  end

  it "rispetta il metodo HTTP del monitor (POST)" do
    monitor.http_method = "POST"
    stub = stub_request(:post, "https://up.test/health").to_return(status: 200)
    described_class.call(monitor: monitor)
    expect(stub).to have_been_requested
  end

  describe "keyword attesa nel body" do
    it "keyword presente → up" do
      monitor.expected_body_keyword = "healthy"
      stub_request(:get, "https://up.test/health").to_return(status: 200, body: "all healthy here")
      expect(described_class.call(monitor: monitor).up).to be(true)
    end

    it "keyword assente → down con error keyword_missing (anche con status atteso)" do
      monitor.expected_body_keyword = "healthy"
      stub_request(:get, "https://up.test/health").to_return(status: 200, body: "maintenance page")
      r = described_class.call(monitor: monitor)
      expect(r.up).to be(false)
      expect(r.status_code).to eq(200)
      expect(r.error).to eq("keyword_missing")
    end

    it "status inatteso ha precedenza: la keyword non maschera l'errore" do
      monitor.expected_body_keyword = "healthy"
      stub_request(:get, "https://up.test/health").to_return(status: 503, body: "healthy")
      r = described_class.call(monitor: monitor)
      expect(r.up).to be(false)
      expect(r.error).to include("unexpected_status")
    end

    it "con HEAD la keyword viene ignorata (nessun body)" do
      monitor.http_method = "HEAD"
      monitor.expected_body_keyword = "healthy"
      stub_request(:head, "https://up.test/health").to_return(status: 200, body: "")
      expect(described_class.call(monitor: monitor).up).to be(true)
    end
  end

  describe "scadenza certificato (ssl_expires_at)" do
    it "https con certificato → not_after nel Result" do
      not_after = 30.days.from_now
      cert = instance_double(OpenSSL::X509::Certificate, not_after: not_after)
      allow_any_instance_of(Net::HTTP).to receive(:peer_cert).and_return(cert)
      stub_request(:get, "https://up.test/health").to_return(status: 200)

      expect(described_class.call(monitor: monitor).ssl_expires_at).to eq(not_after)
    end

    it "senza certificato osservabile → nil (WebMock non fa TLS reale)" do
      stub_request(:get, "https://up.test/health").to_return(status: 200)
      expect(described_class.call(monitor: monitor).ssl_expires_at).to be_nil
    end

    it "http (non tls) → nil, peer_cert mai interrogato" do
      plain = build(:uptime_monitor, url: "http://up.test/health", expected_status: 200, timeout_seconds: 5)
      stub_request(:get, "http://up.test/health").to_return(status: 200)
      expect(described_class.call(monitor: plain).ssl_expires_at).to be_nil
    end
  end

  describe "SSRF guard" do
    it "blocca localhost (risolve a loopback) senza fare la richiesta" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "127.0.0.1" ])
      m = build(:uptime_monitor, url: "http://localhost/admin")
      r = described_class.call(monitor: m)
      expect(r.up).to be(false)
      expect(r.error).to eq("blocked_address")
    end

    it "blocca un IP privato esplicito (rete interna)" do
      m = build(:uptime_monitor, url: "http://10.0.0.10:5432/")
      r = described_class.call(monitor: m)
      expect(r.error).to eq("blocked_address")
    end

    it "blocca l'endpoint metadata cloud 169.254.169.254" do
      m = build(:uptime_monitor, url: "http://169.254.169.254/latest/meta-data/")
      r = described_class.call(monitor: m)
      expect(r.error).to eq("blocked_address")
    end

    it "blocca host che non risolve (DNS vuoto)" do
      allow(NetworkGuard).to receive(:resolve).and_return([])
      r = described_class.call(monitor: build(:uptime_monitor, url: "https://nope.invalid/"))
      expect(r.error).to eq("blocked_address")
    end

    it "blocca uno schema non http/https (ftp) senza fare la richiesta" do
      r = described_class.call(monitor: build(:uptime_monitor, url: "ftp://example.com/file"))
      expect(r.up).to be(false)
      expect(r.error).to eq("blocked_address")
    end

    it "blocca una URL senza host" do
      r = described_class.call(monitor: build(:uptime_monitor, url: "https:///only-path"))
      expect(r.error).to eq("blocked_address")
    end

    it "blocca se un indirizzo risolto non è un IP valido (rescue IPAddr::Error)" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "not-an-ip" ])
      r = described_class.call(monitor: build(:uptime_monitor, url: "https://weird.test/"))
      expect(r.up).to be(false)
      expect(r.error).to eq("blocked_address")
    end

    it "pinna l'IP risolto sulla connessione (anti DNS-rebinding: non ri-risolve l'host al connect)" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      stub_request(:get, "https://up.test/health").to_return(status: 200)
      expect_any_instance_of(Net::HTTP).to receive(:ipaddr=).with("93.184.216.34").and_call_original

      described_class.call(monitor: monitor)
    end
  end

  # CYRA-151: check non-web. Il bersaglio è host(+port); status_code/ssl restano nil.
  describe "check TCP (porta)" do
    let(:tcp) { build(:uptime_monitor, :tcp, host: "db.test", port: 5432, timeout_seconds: 5) }

    it "connessione riuscita → up con response_time e senza status_code" do
      allow(Socket).to receive(:tcp).and_yield(instance_double(Socket, close: nil))
      r = described_class.call(monitor: tcp)
      expect(r.up).to be(true)
      expect(r.status_code).to be_nil
      expect(r.response_time_ms).to be_a(Integer).and be >= 0
      expect(r.error).to be_nil
    end

    it "connessione rifiutata → down" do
      allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
      r = described_class.call(monitor: tcp)
      expect(r.up).to be(false)
      expect(r.error).to be_present
    end

    it "timeout di connessione → down con error timeout" do
      allow(Socket).to receive(:tcp).and_raise(Errno::ETIMEDOUT)
      r = described_class.call(monitor: tcp)
      expect(r.up).to be(false)
      expect(r.error).to eq("timeout")
    end

    it "connette all'IP pubblico risolto, non ri-risolve l'host (SSRF-safe)" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      expect(Socket).to receive(:tcp).with("93.184.216.34", 5432, hash_including(:connect_timeout)).and_yield(instance_double(Socket, close: nil))
      described_class.call(monitor: tcp)
    end

    it "blocca un host che risolve a un indirizzo interno (SSRF) senza connettersi" do
      expect(Socket).not_to receive(:tcp)
      r = described_class.call(monitor: build(:uptime_monitor, :tcp, host: "10.0.0.10", port: 5432))
      expect(r.up).to be(false)
      expect(r.error).to eq("blocked_address")
    end
  end

  describe "check DNS" do
    it "l'host risolve → up" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
      r = described_class.call(monitor: build(:uptime_monitor, :dns, host: "example.com"))
      expect(r.up).to be(true)
      expect(r.response_time_ms).to be_a(Integer)
    end

    it "l'host non risolve → down con error dns_no_record" do
      allow(NetworkGuard).to receive(:resolve).and_return([])
      r = described_class.call(monitor: build(:uptime_monitor, :dns, host: "nope.invalid"))
      expect(r.up).to be(false)
      expect(r.error).to eq("dns_no_record")
    end
  end

  describe "check ping (ICMP)" do
    let(:ping) { build(:uptime_monitor, :ping, host: "example.com", timeout_seconds: 5) }

    before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

    it "host raggiungibile → up con response_time" do
      allow_any_instance_of(described_class).to receive(:icmp_reachable?).and_return(true)
      r = described_class.call(monitor: ping)
      expect(r.up).to be(true)
      expect(r.response_time_ms).to be_a(Integer)
      expect(r.status_code).to be_nil
    end

    it "host non raggiungibile → down con error unreachable" do
      allow_any_instance_of(described_class).to receive(:icmp_reachable?).and_return(false)
      r = described_class.call(monitor: ping)
      expect(r.up).to be(false)
      expect(r.error).to eq("unreachable")
    end

    it "ICMP non permesso nell'ambiente → down con error icmp_unavailable (degrado esplicito)" do
      allow_any_instance_of(described_class).to receive(:icmp_reachable?).and_raise(Errno::EACCES)
      r = described_class.call(monitor: ping)
      expect(r.up).to be(false)
      expect(r.error).to eq("icmp_unavailable")
    end

    it "blocca un host interno (SSRF) senza pingare" do
      expect_any_instance_of(described_class).not_to receive(:icmp_reachable?)
      r = described_class.call(monitor: build(:uptime_monitor, :ping, host: "10.0.0.10"))
      expect(r.error).to eq("blocked_address")
    end

    # Portabilità header IP: Linux (dgram) consegna il solo messaggio ICMP; Darwin/raw lo precede
    # dell'header IPv4, che va saltato prima di leggere il type (altrimenti si legge la versione IP).
    describe "#icmp_echo_reply? (riconoscimento del reply)" do
      let(:svc) { described_class.new(monitor: build(:uptime_monitor, :ping)) }

      it "Linux: messaggio senza header IP, type 0 → reply" do
        expect(svc.send(:icmp_echo_reply?, [ 0, 0 ].pack("C2") + "payload")).to be(true)
      end

      it "Darwin/raw: messaggio con header IPv4 (IHL 5 → 20 byte) e type 0 → reply" do
        ip_header = ([ 0x45 ] + Array.new(19, 0)).pack("C*")
        expect(svc.send(:icmp_echo_reply?, ip_header + [ 0, 0 ].pack("C2"))).to be(true)
      end

      it "type diverso da echo reply (8 = request) → non reply" do
        expect(svc.send(:icmp_echo_reply?, [ 8, 0 ].pack("C2"))).to be(false)
      end

      it "dati vuoti → non reply" do
        expect(svc.send(:icmp_echo_reply?, "")).to be(false)
      end
    end
  end
end
