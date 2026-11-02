# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Project, "council" do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization:) }

  it "is active when the project switch is on" do
    project = create(:project, organization:, council_enabled: true)
    expect(project.council_active?).to be(true)
  end

  it "is active when its group switch is on" do
    group.update!(council_enabled: true)
    project = create(:project, organization:, group:)
    expect(project.council_active?).to be(true)
  end

  it "is inactive when neither is on" do
    project = create(:project, organization:, group:)
    expect(project.council_active?).to be(false)
  end

  it "selects active projects through the scope" do
    group.update!(council_enabled: true)
    by_group = create(:project, organization:, group:)
    by_project = create(:project, organization:, council_enabled: true)
    create(:project, organization:)
    expect(described_class.council_active).to contain_exactly(by_group, by_project)
  end
end
