# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::CommonScope do
  let(:org) { create(:organization) }

  # Rende `account` un membro che vede esattamente i progetti passati (via ProjectMembership).
  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  it "restituisce i progetti visti da TUTTI (intersezione)" do
    p1 = create(:project, organization: org)
    p2 = create(:project, organization: org)
    p3 = create(:project, organization: org)
    a = member_seeing(p1, p2)
    b = member_seeing(p2, p3)

    ids = described_class.new(accounts: [ a, b ], organization: org).project_ids
    expect(ids).to contain_exactly(p2.id)
  end

  it "un owner vede tutto → l'intersezione coincide con ciò che vede l'altro" do
    p1 = create(:project, organization: org)
    _p2 = create(:project, organization: org)
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    member = member_seeing(p1)

    ids = described_class.new(accounts: [ owner, member ], organization: org).project_ids
    expect(ids).to contain_exactly(p1.id)
  end

  it "è vuota senza progetti in comune" do
    a = member_seeing(create(:project, organization: org))
    b = member_seeing(create(:project, organization: org))

    scope = described_class.new(accounts: [ a, b ], organization: org)
    expect(scope.any?).to be(false)
    expect(scope.project_ids).to be_empty
  end
end
