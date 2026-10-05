# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Provision, type: :model do
  subject(:provision) { build(:secret_provision) }

  it "è valida con gli attributi richiesti e non persiste alcun plaintext" do
    expect(provision).to be_valid
    expect(described_class.column_names).not_to include("secret", "value", "ciphertext")
  end

  it "rende idempotency_key unica nell'organizzazione" do
    existing = create(:secret_provision)
    duplicate = build(:secret_provision, organization: existing.organization,
                                         idempotency_key: existing.idempotency_key)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:idempotency_key]).to be_present
  end

  it "permette la stessa idempotency_key in organizzazioni diverse" do
    existing = create(:secret_provision)
    other = build(:secret_provision, idempotency_key: existing.idempotency_key)

    expect(other).to be_valid
  end

  it "espone soltanto gli stati tecnici previsti" do
    expect(described_class.statuses.keys).to contain_exactly("pending_sync", "ready", "failed")
  end
end
