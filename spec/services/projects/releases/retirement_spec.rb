# frozen_string_literal: true

require "rails_helper"

# CYRA-1161 — retiring a release stores who, when and the message; restoring clears all of it.
RSpec.describe "Projects::Releases retire and restore", type: :service do
  let(:project) { create(:project) }
  let(:release) { create(:release, project:, version: "2.4.1") }
  let(:owner) { create(:account) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def status = Projects::Releases::Status.fetch(project:, environment: release.environment, version: release.version)

  it "leaves existing releases active" do
    expect(release).not_to be_retired
  end

  it "retires with the message, the time and the author" do
    freeze_time do
      result = Projects::Releases::Retire.call(release:, message: "  Please update  ", actor: owner)

      expect(result).to be_ok
      expect(release.reload).to be_retired
      expect(release.retired_at).to eq(Time.current)
      expect(release.retirement_message).to eq("Please update")
      expect(release.retired_by).to eq(owner)
    end
  end

  it "refuses a retire without a message and keeps the release active" do
    result = Projects::Releases::Retire.call(release:, message: " ", actor: owner)

    expect(result).not_to be_ok
    expect(result.error.code).to eq("R422-RELEASE-003")
    expect(release.reload).not_to be_retired
  end

  it "restores by clearing the retirement" do
    Projects::Releases::Retire.call(release:, message: "Update", actor: owner)

    expect(Projects::Releases::Restore.call(release:, actor: owner)).to be_ok

    release.reload
    expect(release).not_to be_retired
    expect([ release.retired_at, release.retirement_message, release.retired_by_id ]).to all(be_nil)
  end

  it "writes both gestures in the project history" do
    Projects::Releases::Retire.call(release:, message: "Update", actor: owner)
    Projects::Releases::Restore.call(release:, actor: owner)

    events = project.activity_events.chronological.map { |event| event.data.slice("fields", "version") }
    expect(events).to eq([ { "fields" => [ "release_retired" ], "version" => "2.4.1" },
                           { "fields" => [ "release_restored" ], "version" => "2.4.1" } ])
  end

  it "drops the ready answer on every retire and restore" do
    expect(status).to eq(retired: false, message: nil)

    Projects::Releases::Retire.call(release:, message: "Update", actor: owner)
    expect(status).to eq(retired: true, message: "Update")

    Projects::Releases::Restore.call(release:, actor: owner)
    expect(status).to eq(retired: false, message: nil)
  end
end
