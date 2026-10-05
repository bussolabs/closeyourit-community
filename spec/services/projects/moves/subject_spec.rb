# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::Subject do
  let(:org) { create(:organization) }
  let(:group) { create(:group, organization: org) }
  let!(:inside) { create(:project, organization: org, group:) }
  let!(:outside) { create(:project, organization: org) }

  it "carries every project of a group" do
    expect(described_class.new(group).project_ids).to contain_exactly(inside.id)
    expect(described_class.new(group).group_ids).to eq([ group.id ])
  end

  it "carries a single project without its group" do
    subject = described_class.new(outside)
    expect(subject.project_ids).to eq([ outside.id ])
    expect(subject.group_ids).to be_empty
    expect(subject.label).to eq(outside.key)
  end
end
