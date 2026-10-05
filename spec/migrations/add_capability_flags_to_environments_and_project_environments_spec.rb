# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260709142924_add_capability_flags_to_environments_and_project_environments")

RSpec.describe AddCapabilityFlagsToEnvironmentsAndProjectEnvironments do
  it "il backfill porta gli ambienti canonici ESISTENTI dal default DB (tutto ON) alla matrice differenziata" do
    org = create(:organization)
    # Stato post-add_column, pre-backfill: i canonici già installati hanno tutte le capability al default DB (true).
    prod = create(:environment, organization: org, code: "production", servers_enabled: true, uptime_enabled: true, secrets_enabled: true)
    stg  = create(:environment, organization: org, code: "staging", servers_enabled: true, uptime_enabled: true, secrets_enabled: true)
    dev  = create(:environment, organization: org, code: "development", servers_enabled: true, uptime_enabled: true, secrets_enabled: true)

    ActiveRecord::Migration.suppress_messages { described_class.new.backfill_canonical_capabilities }

    expect([ prod.reload.servers_enabled, prod.uptime_enabled, prod.secrets_enabled ]).to eq([ true, true, true ])
    expect([ stg.reload.servers_enabled, stg.uptime_enabled, stg.secrets_enabled ]).to eq([ true, false, true ])
    expect([ dev.reload.servers_enabled, dev.uptime_enabled, dev.secrets_enabled ]).to eq([ false, false, true ])
  end
end
