# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261003220000_backfill_helpdesk_manage_permission")

RSpec.describe BackfillHelpdeskManagePermission do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  # The default roles of the organizations that already exist were created before `helpdesk.manage`
  # entered the catalog: `legacy!` reproduces that state, and the backfill has to repair it.
  let(:org) { create(:organization) }

  def legacy!(organization)
    Authorization::InstallDefaultRoles.call(organization: organization)
    Authorization::RolePermission.where(role_id: organization.roles.select(:id), permission_key: "helpdesk.manage").delete_all
  end

  def role(organization, name) = organization.roles.find_by!(name: name)

  it "grants helpdesk.manage to the Administrator and Maintainer roles that lack it" do
    legacy!(org)
    expect(role(org, "Maintainer").permission_keys).not_to include("helpdesk.manage")

    run_backfill

    %w[Administrator Maintainer].each do |name|
      expect(role(org, name).permission_keys).to include("helpdesk.manage")
    end
  end

  it "is idempotent" do
    legacy!(org)

    2.times { run_backfill }

    expect(Authorization::RolePermission.where(role_id: role(org, "Maintainer").id, permission_key: "helpdesk.manage").count).to eq(1)
  end

  # A request carries a visitor's address: the roles that never had the key must not receive it.
  it "leaves the other default roles untouched" do
    legacy!(org)

    run_backfill

    %w[Viewer Triager].each do |name|
      expect(role(org, name).permission_keys).not_to include("helpdesk.manage")
    end
  end

  it "covers every existing organization" do
    other = create(:organization)
    [ org, other ].each { |organization| legacy!(organization) }

    run_backfill

    [ org, other ].each do |organization|
      expect(role(organization, "Maintainer").permission_keys).to include("helpdesk.manage")
    end
  end

  it "revokes on the way down only where it could have granted" do
    legacy!(org)
    custom = org.roles.create!(name: "Support desk")
    Authorization::RolePermission.create!(role_id: custom.id, permission_key: "helpdesk.manage")
    run_backfill

    ActiveRecord::Migration.suppress_messages { described_class.new.down }

    expect(role(org, "Maintainer").permission_keys).not_to include("helpdesk.manage")
    expect(custom.reload.permission_keys).to include("helpdesk.manage")
  end
end
