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

  it "HTTP non-2xx → Result.err R502-ALERT-001 (loggato, non solleva)" do
    stub_request(:post, "https://hooks.example.test/cyi").to_return(status: 500)

    result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-ALERT-001")
  end

  it "timeout/eccezione → Result.err, nessun raise" do
    stub_request(:post, "https://hooks.example.test/cyi").to_timeout

    expect do
      result = described_class.webhook(channel:, event_type: "error_new", subject: group, content:)
      expect(result).to be_err
    end.not_to raise_error
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
