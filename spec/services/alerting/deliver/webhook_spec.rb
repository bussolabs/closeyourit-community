# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Deliver, type: :service do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project:) }
  let(:channel) { create(:alerting_channel, organization: org) }
  let(:content) do
    Alerting::Content.new(title: "Nuovo errore · Boom", body: "App::Widget#render",
                          url: "/member/monitoring/error/#{group.id}", project: project)
  end

  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  it "POST JSON con firma HMAC e header evento → ok su 2xx" do
    stub = stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 200)

    result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

    expect(result).to be_ok
    expect(stub.with { |req|
      body = JSON.parse(req.body)
      expected_sig = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "s3cret", req.body)}"
      body["event_type"] == "error_new" &&
        body["title"] == "Nuovo errore · Boom" &&
        body.dig("project", "id") == project.id &&
        body.dig("subject", "type") == "Errors::Group" &&
        req.headers["X-Closeyourit-Event"] == "error_new" &&
        req.headers["X-Closeyourit-Signature"] == expected_sig
    }).to have_been_requested
  end

  it "senza secret non firma (nessun header signature)" do
    channel.update!(webhook_secret: nil)
    stub = stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 204)

    described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

    expect(stub.with { |req| req.headers["X-Closeyourit-Signature"].nil? }).to have_been_requested
  end

  # CYRA-1227 — il lavoro in coda ritenta solo ciò che TransientFailure riconosce: l'errore deve dire
  # se il canale è caduto per un momento o ha detto di no per sempre.
  describe "guasto passeggero o rifiuto definitivo" do
    it "exposes programming errors instead of treating them as delivery failures" do
      stub_request(:post, "https://hooks.example.test/cyi").to_raise(NoMethodError)

      expect { described_class.webhook(channel:, event_type: "error_new", subject: group, content:) }
        .to raise_error(NoMethodError)
    end

    [ 500, 503, 429, 408 ].each do |status|
      it "HTTP #{status} → R502-ALERT-001, ritentabile (loggato, non solleva)" do
        stub_request(:post, "https://hooks.example.test/cyi").to_return(status:)

        result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

        expect(result).to be_err
        expect(result.error.code).to eq("R502-ALERT-001")
        expect(TransientFailure === result.error).to be(true)
      end
    end

    [ 404, 410, 403, 401, 400 ].each do |status|
      it "HTTP #{status} → R422-ALERT-004, definitivo: non si ritenta" do
        stub_request(:post, "https://hooks.example.test/cyi").to_return(status:)

        result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

        expect(result.error.code).to eq("R422-ALERT-004")
        expect(TransientFailure === result.error).to be(false)
      end
    end

    it "timeout → R502-ALERT-001 ritentabile, nessun raise" do
      stub_request(:post, "https://hooks.example.test/cyi").to_timeout

      expect do
        result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)
        expect(result.error.code).to eq("R502-ALERT-001")
        expect(TransientFailure === result.error).to be(true)
      end.not_to raise_error
    end

    it "connessione rifiutata → R502-ALERT-001 ritentabile" do
      stub_request(:post, "https://hooks.example.test/cyi").to_raise(Errno::ECONNREFUSED)

      result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

      expect(TransientFailure === result.error).to be(true)
    end

    it "host che il resolver non risolve → R502-ALERT-001 ritentabile, nessuna richiesta" do
      channel # creato mentre il DNS risponde (config-time valido)
      allow(NetworkGuard).to receive(:resolve).and_return([])

      result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

      expect(result.error.code).to eq("R502-ALERT-001")
      expect(TransientFailure === result.error).to be(true)
      expect(WebMock).not_to have_requested(:post, "https://hooks.example.test/cyi")
    end

    it "eccezione che non guarisce da sé (risposta oltre il limite) → R422-ALERT-004, nessun raise" do
      stub_request(:post, "https://hooks.example.test/cyi").to_raise(BoundedHttp::ResponseTooLarge)

      result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

      expect(result.error.code).to eq("R422-ALERT-004")
      expect(TransientFailure === result.error).to be(false)
    end
  end

  it "il payload porta l'ora dell'evento, non solo quella dell'invio (CYRA-1227)" do
    stub = stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 200)
    occurred_at = Time.zone.at(1_700_000_000)

    described_class.webhook(channel:, event_type: "error_new", subject: group, content:, occurred_at:)

    expect(stub.with { |req| JSON.parse(req.body)["occurred_at"] == occurred_at.iso8601 }).to have_been_requested
  end

  it "URL diventata interna a delivery-time → R422-ALERT-002, nessuna richiesta" do
    channel # creato mentre il DNS risolve pubblico (config-time valido)
    allow(NetworkGuard).to receive(:resolve).and_return([ "10.0.0.9" ])

    result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-ALERT-002")
    expect(WebMock).not_to have_requested(:post, "https://hooks.example.test/cyi")
  end

  it "pinna l'IP risolto sulla connessione (anti DNS-rebinding: non ri-risolve l'host al connect)" do
    stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 200)
    expect_any_instance_of(Net::HTTP).to receive(:ipaddr=).with("93.184.216.34").and_call_original

    described_class.webhook(channel:, event_type: "error_new", subject: group, content:)
  end

  # CYRA-212: eventi org-scoped (server_*/agents_*) senza progetto. Prima il payload dereferenziava sempre
  # content.project → NoMethodError catturato dal rescue = webhook MAI consegnato. Ora `project` è null.
  it "evento org-scoped (project nil): payload con project null, consegna riuscita senza raise" do
    stub = stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 200)
    org_content = Alerting::Content.new(title: "Automazione bloccata · Acme",
                                        body: "Le macchine sono attive ma nulla si conclude.",
                                        url: "/member/agents", project: nil)

    result = described_class.webhook(channel:, event_type: "agents_stalled", subject: org, content: org_content)

    expect(result).to be_ok
    expect(stub.with { |req| JSON.parse(req.body).fetch("project").nil? }).to have_been_requested
  end
end
