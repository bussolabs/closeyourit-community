# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authorization::VisibleScope do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  def visible_group_ids = described_class.new(account: account, organization: org).groups.pluck(:id)

  describe "#groups" do
    context "owner (unscoped)" do
      before { create(:membership, account: account, organization: org, role: :owner) }

      it "vede tutti i gruppi dell'org" do
        g1 = create(:group, organization: org)
        g2 = create(:group, organization: org)
        expect(visible_group_ids).to contain_exactly(g1.id, g2.id)
      end
    end

    context "member (scoped)" do
      before { create(:membership, account: account, organization: org, role: :member) }

      it "zero link → nessun gruppo (strict)" do
        create(:group, organization: org)
        expect(visible_group_ids).to be_empty
      end

      it "link personale → solo il gruppo assegnato" do
        g1 = create(:group, organization: org)
        create(:group, organization: org)
        create(:group_membership, account: account, group: g1)
        expect(visible_group_ids).to contain_exactly(g1.id)
      end

      it "link via team → il gruppo del team" do
        g1 = create(:group, organization: org)
        team = create(:team, organization: org)
        create(:team_membership, account: account, team: team)
        create(:team_group_access, team: team, group: g1)
        expect(visible_group_ids).to contain_exactly(g1.id)
      end
    end
  end
end
