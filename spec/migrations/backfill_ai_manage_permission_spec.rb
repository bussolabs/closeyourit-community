# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261005121000_backfill_ai_manage_permission")

# CYRA-914 phase 2 — ai.manage is a new key: the Administrator roles of existing organizations get
# :all only when they are created, so without this they could not open the organization AI page.
RSpec.describe BackfillAiManagePermission do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  def keys_of(organization, role)
    organization.roles.find_by!(name: role).role_permissions.pluck(:permission_key)
  end

  let(:organization) { create(:organization) }

  before do
    Authorization::InstallDefaultRoles.call(organization:)
    Authorization::RolePermission.where(permission_key: "ai.manage").delete_all
  end

  it "gives ai.manage to the Administrator role only" do
    run_backfill

    expect(keys_of(organization, "Administrator")).to include("ai.manage")
    expect(keys_of(organization, "Maintainer")).not_to include("ai.manage")
  end

  it "can run twice" do
    run_backfill

    expect { run_backfill }.not_to raise_error
  end
end
