# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("script/certification/bootstrap_support")

RSpec.describe Certification::BootstrapSupport do
  it "satisfies the real account password policy even when random output lacks character classes" do
    allow(SecureRandom).to receive(:base64).with(48).and_return("a" * 64)
    account = Accounts::Account.new(password: described_class.password)
    account.send(:password_complexity)
    expect(account.errors.details).to be_empty
    expect(account.password.bytesize).to be <= 72
  end

  it "returns only static validation field names without messages or values" do
    account = Accounts::Account.new
    account.errors.add(:password, "synthetic private message")
    account.errors.add(:email, "synthetic private value")
    account.errors.add(:unrecognized_field, "synthetic private field")
    error = ActiveRecord::RecordInvalid.new(account)
    payload = described_class.failure(error, "create_installation_sessions")
    expect(payload).to eq(error: { code: "bootstrap_failed", stage: "create_installation_sessions",
      exception_class: "ActiveRecord::RecordInvalid", validation_attributes: %w[password email] })
    expect(JSON.generate(payload)).not_to include("synthetic", "unrecognized_field")
  end

  it "replaces unknown exception classes and non-scalar actions with static fallbacks" do
    error = Class.new(StandardError).new("synthetic private message")
    expect(described_class.failure(error, { "action" => "synthetic" })).to eq(error: {
      code: "bootstrap_failed", stage: "unknown", exception_class: "StandardError", validation_attributes: [] })
  end

  it "handles validation exceptions without a record" do
    expect(described_class.failure(ActiveRecord::RecordInvalid.new, "create")).to eq(error: {
      code: "bootstrap_failed", stage: "create", exception_class: "ActiveRecord::RecordInvalid", validation_attributes: [] })
  end
end
