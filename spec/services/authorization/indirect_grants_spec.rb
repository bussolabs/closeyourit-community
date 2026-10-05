# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Indirect permission grants" do
  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }
  let!(:membership) { create(:membership, organization:, account: actor, role: :member) }
  let(:role) { create(:role, organization:) }
  let(:team) { create(:team, organization:) }

  it "does not restore a denied inherited permission through self-editing" do
    create(:role_permission, role:, permission_key: "organization.manage")
    create(:account_role, organization:, account: actor, role:)
    denial = create(:account_permission, organization:, account: actor, permission_key: "organization.manage", effect: :deny)

    result = Authorization::SetAccountPermissions.call(organization:, account: actor, actor:, allow_keys: [], deny_keys: [])

    expect(result.error.code).to eq("R403-ACCESS-001")
    expect(denial.reload.effect).to eq("deny")
    expect(Authorization::Resolver.new(account: actor, organization:).can?("organization.manage")).to be(false)
  end

  it "lets an owner remove a denial" do
    membership.update!(role: :owner)
    target = create(:account)
    create(:membership, organization:, account: target)
    create(:account_permission, organization:, account: target, permission_key: "organization.manage", effect: :deny)

    expect(Authorization::SetAccountPermissions.call(organization:, account: target, actor:)).to be_ok
    expect(target.account_permissions.reload).to be_empty
  end

  it "rejects adding oneself to a privileged team" do
    create(:role_permission, role:, permission_key: "organization.manage")
    create(:team_role, team:, role:)

    result = Teams::SetTeamMembers.call(team:, account_ids: [ actor.id ], actor:)

    expect(result.error.code).to eq("R403-ACCESS-001")
    expect(team.team_memberships.reload).to be_empty
  end

  it "rejects adding a member to a team with hidden projects even without roles" do
    project = create(:project, organization:)
    create(:team_project_access, team:, project:)

    result = Teams::SetTeamMembers.call(team:, account_ids: [ actor.id ], actor:)

    expect(result.error.code).to eq("R403-ACCESS-001")
    expect(team.team_memberships.reload).to be_empty
  end

  it "allows removing membership from a privileged team" do
    create(:role_permission, role:, permission_key: "organization.manage")
    create(:team_role, team:, role:)
    create(:team_membership, team:, account: actor)

    expect(Teams::SetTeamMembers.call(team:, account_ids: [], actor:)).to be_ok
    expect(team.team_memberships.reload).to be_empty
  end

  it "allows adding a member when the team grants neither roles nor hidden scope" do
    expect(Teams::SetTeamMembers.call(team:, account_ids: [ actor.id ], actor:)).to be_ok
    expect(team.team_memberships.pluck(:account_id)).to eq([ actor.id ])
  end
end
