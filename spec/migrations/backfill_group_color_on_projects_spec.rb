# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261003230000_backfill_group_color_on_projects")

RSpec.describe BackfillGroupColorOnProjects do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  let(:organization) { create(:organization) }

  # Projects created before the rule kept their own color inside a colored group: `legacy!` writes
  # that state past the model.
  def legacy!(project, color)
    project.update_column(:color, color)
    project
  end

  it "gives the group's color to the projects that had another one" do
    group = create(:group, organization:, color: "emerald")
    project = legacy!(create(:project, organization:, group:), "violet")

    run_backfill

    expect(project.reload.color).to eq("emerald")
  end

  it "leaves projects without a group, or in a group without a color, as they are" do
    alone = create(:project, organization:, color: "violet")
    plain = create(:project, organization:, group: create(:group, organization:, color: nil), color: "rose")

    run_backfill

    expect([ alone.reload.color, plain.reload.color ]).to eq(%w[violet rose])
  end

  it "can run twice" do
    group = create(:group, organization:, color: "emerald")
    project = legacy!(create(:project, organization:, group:), "violet")

    2.times { run_backfill }

    expect(project.reload.color).to eq("emerald")
  end
end
