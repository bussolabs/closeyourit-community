# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261119234500_switch_the_supporter_on_by_default")

RSpec.describe SwitchTheSupporterOnByDefault do
  let(:organization) { create(:organization) }

  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.switch_existing_projects_on }
  end

  it "switches the supporter on for the projects that were born off" do
    project = create(:project, organization:, supporter_enabled: false)

    run_backfill

    expect(project.reload.supporter_enabled).to be(true)
  end

  it "can run twice" do
    project = create(:project, organization:, supporter_enabled: false)

    2.times { run_backfill }

    expect(project.reload.supporter_enabled).to be(true)
  end
end
