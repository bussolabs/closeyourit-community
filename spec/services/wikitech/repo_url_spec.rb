# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::RepoUrl do
  it "normalizes a repository address to its canonical form" do
    expect(described_class.normalize("https://www.GitHub.com/GodotEngine/Godot.git/tree/master")).to eq("https://github.com/godotengine/godot")
    expect(described_class.normalize(" http://github.com/bevyengine/bevy ")).to eq("https://github.com/bevyengine/bevy")
  end

  it "returns nil for GitHub pages that are not repositories and for other hosts" do
    expect(described_class.normalize("https://github.com/topics/game-engine")).to be_nil
    expect(described_class.normalize("https://gitlab.com/a/b")).to be_nil
    expect(described_class.normalize("")).to be_nil
    expect(described_class.normalize(nil)).to be_nil
  end

  it "gives the owner/name pair" do
    expect(described_class.full_name("https://github.com/godotengine/godot")).to eq("godotengine/godot")
  end
end
