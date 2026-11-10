# frozen_string_literal: true

require "rails_helper"

# CYRA-233: the sender of ALL emails (alerts, digests, invitations, password resets) sat on a domain with no
# sending setup at all. Nobody noticed because the failure leaves no trace where people look.
RSpec.describe Ops::MailSenderCheck, type: :service do
  let(:ses) { Aws::SESV2::Client.new(stub_responses: true) }

  # The real vault credentials must not pick the expected branch: known values for every example, the
  # original ones restored afterwards.
  around do |example|
    original = %w[AWS_SES_ACCESS_KEY_ID AWS_SES_SECRET_ACCESS_KEY].index_with { |key| ENV[key] }
    ENV["AWS_SES_ACCESS_KEY_ID"] = "AKIATESTKEY"
    ENV["AWS_SES_SECRET_ACCESS_KEY"] = "ses_test_secret"
    example.run
    original.each { |key, value| ENV[key] = value }
  end

  before { allow(Aws::SESV2::Client).to receive(:new).and_return(ses) }

  def stub_identity(verification_status: "SUCCESS", sending: true)
    ses.stub_responses(:get_email_identity,
                       { verification_status:, verified_for_sending_status: sending })
  end

  def requested_identities = ses.api_requests.map { |request| request[:params][:email_identity] }

  describe "deliverable sender" do
    it "is verified when the sender's domain is a verified identity enabled for sending" do
      stub_identity

      result = described_class.call(from: "CloseYourIt <noreply@notifications.example.test>")

      expect(result.status).to eq(:verified)
      expect(result.deliverable?).to be(true)
      expect(result.domain).to eq("notifications.example.test")
      expect(requested_identities).to eq([ "notifications.example.test" ])
    end

    it "asks SES in eu-central-1 with the AWS_SES_* credentials" do
      stub_identity

      described_class.call(from: "noreply@notifications.example.test")

      expect(Aws::SESV2::Client).to have_received(:new)
        .with(region: "eu-central-1",
              credentials: having_attributes(access_key_id: "AKIATESTKEY", secret_access_key: "ses_test_secret"))
    end

    # The staging sender carries an RFC comment in parentheses: if address parsing broke there, the check
    # would answer :invalid_sender on a perfectly valid setup.
    it "reads the domain from a sender with a comment in parentheses (staging)" do
      stub_identity

      result = described_class.call(from: "CloseYourIt (staging) <noreply@notifications.example.test>")

      expect(result.status).to eq(:verified)
      expect(result.domain).to eq("notifications.example.test")
    end

    it "accepts a sender without a display name" do
      stub_identity

      expect(described_class.call(from: "noreply@notifications.example.test").status).to eq(:verified)
    end
  end

  describe "undeliverable sender" do
    # The CYRA-233 failure in one line: the sender's domain is not an identity at all.
    it "is unknown_domain when the sender's domain is not an SES identity" do
      ses.stub_responses(:get_email_identity, "NotFoundException")

      result = described_class.call(from: "CloseYourIt <noreply@notifications.example.test>")

      expect(result.status).to eq(:unknown_domain)
      expect(result.deliverable?).to be(false)
      expect(result.detail).to include("notifications.example.test")
      # SES answered here: the sender does NOT send. It is not an "I don't know" (CYRA-771).
      expect(result.unverifiable?).to be(false)
    end

    # An identity whose DNS records have not propagated yet does not send: it counts as a failure.
    it "is unverified when the identity exists but is not verified" do
      stub_identity(verification_status: "PENDING", sending: false)

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.status).to eq(:unverified)
      expect(result.deliverable?).to be(false)
      expect(result.detail).to include("PENDING")
    end

    it "is unverified when the identity is verified but not enabled for sending" do
      stub_identity(sending: false)

      expect(described_class.call(from: "noreply@notifications.example.test").status).to eq(:unverified)
    end
  end

  describe "missing or malformed configuration" do
    # Without credentials production turns delivery off (config/environments/production.rb): not one mail
    # leaves, even with perfect DNS. It is a failure as much as a dead domain, and it must be said.
    %w[AWS_SES_ACCESS_KEY_ID AWS_SES_SECRET_ACCESS_KEY].each do |key|
      it "is unconfigured without #{key}, without calling SES" do
        ENV.delete(key)

        result = described_class.call(from: "noreply@notifications.example.test")

        expect(result.status).to eq(:unconfigured)
        expect(result.deliverable?).to be(false)
        expect(Aws::SESV2::Client).not_to have_received(:new)
      end
    end

    it "is invalid_sender when the configured sender is not an address" do
      result = described_class.call(from: "CloseYourIt")

      expect(result.status).to eq(:invalid_sender)
      expect(Aws::SESV2::Client).not_to have_received(:new)
    end

    it "is invalid_sender when the sender is blank" do
      expect(described_class.call(from: "  ").status).to eq(:invalid_sender)
    end
  end

  # CYRA-771: credentials allowed to send but not to read identities must not paint mail as down.
  describe "credentials not allowed to read identities" do
    before { ses.stub_responses(:get_email_identity, "AccessDeniedException") }

    it "is restricted_key, not error, when SES refuses the identity read" do
      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.status).to eq(:restricted_key)
      expect(result.detail).to include("not allowed to read")
    end

    # "I cannot check" is NOT "it does not send": whoever reads the result must tell the two apart without
    # parsing the detail text.
    it "is not deliverable but declared unverifiable" do
      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.deliverable?).to be(false)
      expect(result.unverifiable?).to be(true)
    end

    it "does not raise and does not leak the credentials" do
      result = nil
      expect { result = described_class.call(from: "noreply@notifications.example.test") }.not_to raise_error
      expect(result.to_h.values.join).not_to include("AKIATESTKEY", "ses_test_secret")
    end
  end

  describe "provider unreachable" do
    # The check observes, it does not break: an API failure must not raise (the caller is a recurring job,
    # and a raise would make it retry for nothing).
    it "is error without raising when SES rejects the credentials" do
      ses.stub_responses(:get_email_identity, "UnrecognizedClientException")

      result = nil
      expect { result = described_class.call(from: "noreply@notifications.example.test") }.not_to raise_error
      expect(result.status).to eq(:error)
      expect(result.deliverable?).to be(false)
      # NOT an "I cannot check" (CYRA-771): revoked credentials land in :error, and they are the ones that
      # send, so mail is really down and the red stays.
      expect(result.unverifiable?).to be(false)
    end

    it "is error without raising when SES does not answer at all" do
      ses.stub_responses(:get_email_identity,
                         Seahorse::Client::NetworkingError.new(Timeout::Error.new("execution expired")))

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.status).to eq(:error)
      expect(result.detail).to be_present
      # The detail lands in logs and on the health page: the credentials must never show up there.
      expect(result.to_h.values.join).not_to include("AKIATESTKEY", "ses_test_secret")
    end
  end

  describe "default sender" do
    # No argument = the sender the emails will really use. If the two diverged, the check would look elsewhere.
    it "checks ApplicationMailer's sender when called without arguments" do
      stub_identity

      expect(described_class.call.status).to eq(:verified)
      expect(requested_identities).to eq([ Mail::Address.new(ApplicationMailer.default[:from]).domain ])
    end
  end
end
