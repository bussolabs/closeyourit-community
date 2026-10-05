# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::FormOptions do
  let(:org) { create(:organization) }
  let(:busy) { create(:project, organization: org) }
  let(:quiet) { create(:project, organization: org) }

  it "caps the open errors per project, so a busy project never hides a quiet one" do
    stub_const("#{described_class}::SIGNALS_LIMIT", 2)
    3.times { |i| create(:error_group, project: busy, last_seen_at: i.minutes.ago) }
    old = create(:error_group, project: quiet, last_seen_at: 1.day.ago)

    options = described_class.call(organization: org, projects: org.projects, signals: true)

    expect(options.error_groups.count { |group| group.project_id == busy.id }).to eq(2)
    expect(options.error_groups).to include(old)
  end
end
