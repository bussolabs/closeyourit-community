# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::OtpRecoveryCode, type: :model do
  let(:account) { create(:account) }

  it "appartiene a un account" do
    code = account.otp_recovery_codes.create!(code_digest: "a" * 64)
    expect(code.account).to eq(account)
  end

  it "scope .unused esclude i codici già consumati" do
    unused = account.otp_recovery_codes.create!(code_digest: "a" * 64)
    account.otp_recovery_codes.create!(code_digest: "b" * 64, used_at: Time.current)
    expect(Accounts::OtpRecoveryCode.unused).to contain_exactly(unused)
  end

  it "#used? riflette used_at" do
    expect(account.otp_recovery_codes.create!(code_digest: "c" * 64)).not_to be_used
    expect(account.otp_recovery_codes.create!(code_digest: "d" * 64, used_at: Time.current)).to be_used
  end

  it "cade con l'account (dependent: :destroy / FK on_delete: cascade)" do
    account.otp_recovery_codes.create!(code_digest: "e" * 64)
    expect { account.destroy }.to change(Accounts::OtpRecoveryCode, :count).by(-1)
  end
end
