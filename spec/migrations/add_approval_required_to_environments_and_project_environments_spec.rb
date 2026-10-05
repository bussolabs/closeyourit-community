# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260717080036_add_approval_required_to_environments_and_project_environments")

RSpec.describe AddApprovalRequiredToEnvironmentsAndProjectEnvironments do
  it "il backfill imposta approval_required=true SOLO per l'ambiente production, gli altri restano al default false" do
    org = create(:organization)
    # Stato post-add_column, pre-backfill: tutti gli ambienti nascono al default DB (false).
    prod = create(:environment, organization: org, code: "production", approval_required: false)
    stg  = create(:environment, organization: org, code: "staging", approval_required: false)
    dev  = create(:environment, organization: org, code: "development", approval_required: false)

    ActiveRecord::Migration.suppress_messages { described_class.new.backfill_production_approval_required }

    expect(prod.reload.approval_required).to be(true)
    expect(stg.reload.approval_required).to be(false)
    expect(dev.reload.approval_required).to be(false)
  end
end
