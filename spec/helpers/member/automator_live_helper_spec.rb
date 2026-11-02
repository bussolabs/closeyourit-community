# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::AutomatorLiveHelper, type: :helper do
  it "numbers a change like a review" do
    hunk = Agents::LiveEvents::Session::Hunk.new(old_start: 3, old_lines: 2, new_start: 3, new_lines: 3,
                                                 lines: [ " keep", "-old", "+new", "+more" ])

    expect(helper.automator_live_lines(hunk).map { [ it.kind, it.old_number, it.new_number, it.text ] }).to eq(
      [ [ :context, 3, 3, "keep" ], [ :removed, 4, nil, "old" ], [ :added, nil, 4, "new" ], [ :added, nil, 5, "more" ] ]
    )
  end

  it "groups files under their folders, folders and files in path order" do
    entries = %w[app/models/user.rb README.md app/models/ticket.rb config/routes.rb].map { Struct.new(:path).new(it) }

    tree = helper.automator_live_tree(entries)

    expect(tree.map { |folder, files| [ folder, files.map(&:path) ] }).to eq(
      [ [ "", %w[README.md] ], [ "app/models", %w[app/models/ticket.rb app/models/user.rb] ], [ "config", %w[config/routes.rb] ] ]
    )
  end

  it "calls fresh only what arrived in the last few seconds" do
    travel_to Time.utc(2026, 11, 2, 15) do
      expect(helper.automator_live_fresh?(5.seconds.ago)).to be(true)
      expect(helper.automator_live_fresh?(1.minute.ago)).to be(false)
      expect(helper.automator_live_fresh?(nil)).to be(false)
    end
  end

  it "names the engine and shortens the ticket to its number" do
    expect(helper.automator_live_engine("codex")).to eq("Codex")
    expect(helper.automator_live_number(Struct.new(:code).new("CYRA-1139"))).to eq("1139")
  end

  it "writes the time at work as m:ss, and h:mm:ss past an hour" do
    travel_to Time.utc(2026, 11, 2, 15) do
      expect(helper.automator_live_elapsed(3.minutes.ago - 42.seconds)).to eq("3:42")
      expect(helper.automator_live_elapsed(1.hour.ago - 5.minutes)).to eq("1:05:00")
      expect(helper.automator_live_elapsed(1.minute.from_now)).to eq("0:00")
    end
  end
end
