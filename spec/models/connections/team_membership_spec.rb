# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::TeamMembership, type: :model do
  let(:org) { create(:organization) }
  let(:team) { create(:team, organization: org) }
  let(:account) { create(:account) }

  it "è valida quando l'account è membro dell'org del team" do
    create(:membership, account: account, organization: org)
    expect(described_class.new(account: account, team: team)).to be_valid
  end

  it "rifiuta un account NON membro dell'org del team (integrità tenant)" do
    link = described_class.new(account: account, team: team)
    expect(link).not_to be_valid
    expect(link.errors[:account]).to be_present
  end

  it "rifiuta lo stesso account due volte sullo stesso team" do
    create(:membership, account: account, organization: org)
    described_class.create!(account: account, team: team)
    dup = described_class.new(account: account, team: team)

    expect(dup).not_to be_valid
    expect(dup.errors[:account_id]).to be_present
  end

  it "guard tenant: non solleva quando account/team sono assenti" do
    # Esercita il return del guard difensivo blank? in account_belongs_to_team_organization.
    expect { described_class.new.valid? }.not_to raise_error
  end
end
