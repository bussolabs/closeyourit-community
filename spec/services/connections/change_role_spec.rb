# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::ChangeRole do
  let(:organization) { create(:organization) }

  def membership(role)
    create(:membership, organization: organization, role: role)
  end

  it "promuove un member ad admin" do
    m = membership(:member)
    result = described_class.call(membership: m, role: "admin")
    expect(result).to be_ok
    expect(m.reload).to be_admin
  end

  it "declassa un admin a member" do
    m = membership(:admin)
    result = described_class.call(membership: m, role: "member")
    expect(result).to be_ok
    expect(m.reload).to be_member
  end

  it "rifiuta un ruolo non ammesso (owner)" do
    m = membership(:member)
    result = described_class.call(membership: m, role: "owner")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-MEMBER-001")
    expect(m.reload).to be_member
  end

  it "vieta di declassare l'ultimo owner" do
    owner = membership(:owner)
    result = described_class.call(membership: owner, role: "member")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-MEMBER-002")
    expect(owner.reload).to be_owner
  end

  it "Result.err R422-MEMBER-003 se update! solleva RecordInvalid (rete difensiva DB)" do
    m = membership(:member)
    allow(m).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(m))
    result = described_class.call(membership: m, role: "admin")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-MEMBER-003")
  end
end
