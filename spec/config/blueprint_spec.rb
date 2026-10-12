# frozen_string_literal: true

require "rails_helper"

# CYRA-1071 — blueprint.json is the map of this app that the Map tab shows. A map that points to
# files that no longer exist lies, so every glob must still match something.
RSpec.describe "blueprint.json", type: :model do
  let(:document) { Blueprint::Document.parse(Rails.root.join("blueprint.json").read) }

  it "is a valid map" do
    expect { document }.not_to raise_error
  end

  it "points only to files that exist" do
    missing = document.files.uniq.select { |glob| Dir.glob(Rails.root.join(glob).to_s).empty? }

    expect(missing).to be_empty, "Globs in blueprint.json that match nothing:\n#{missing.join("\n")}"
  end
end
