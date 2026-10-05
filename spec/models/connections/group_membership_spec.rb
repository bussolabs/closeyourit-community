# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::GroupMembership, type: :model do
  let(:org) { create(:organization) }
  let(:group) { create(:group, organization: org) }
  let(:account) { create(:account) }

  it "è valida quando l'account è membro dell'org del gruppo" do
    create(:membership, account: account, organization: org)
    expect(described_class.new(account: account, group: group)).to be_valid
  end

  it "rifiuta un account non membro dell'org del gruppo (integrità tenant)" do
    link = described_class.new(account: account, group: group)
    expect(link).not_to be_valid
    expect(link.errors[:account]).to be_present
  end

  it "rifiuta lo stesso account due volte sullo stesso gruppo" do
    create(:membership, account: account, organization: org)
    described_class.create!(account: account, group: group)
    dup = described_class.new(account: account, group: group)

    expect(dup).not_to be_valid
    expect(dup.errors[:account_id]).to be_present
  end

  it "guard tenant: non solleva quando account/group sono assenti" do
    # Esercita il return del guard difensivo blank? in account_belongs_to_group_organization.
    expect { described_class.new.valid? }.not_to raise_error
  end
end
