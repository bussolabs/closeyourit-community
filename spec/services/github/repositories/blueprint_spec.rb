# frozen_string_literal: true

require "rails_helper"

# CYRA-1071 — the Map tab reads blueprint.json from the project's repository and never writes it.
RSpec.describe Github::Repositories::Blueprint do
  let(:project) { create(:project) }
  let(:client) { instance_double(Github::Client) }
  let(:map) do
    JSON.generate("name" => "App", "nodes" => [ { "id" => "app", "name" => "App", "level" => 0, "parent" => nil,
                                                  "kind" => "system", "summary" => "The app.", "files" => [] } ])
  end

  def read = described_class.call(project:, client:)

  it "says so when the project has no repository" do
    expect(read.state).to eq(:no_repository)
  end

  context "with a linked repository" do
    let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/shop", default_branch: "trunk") }

    it "reads the map from the default branch" do
      allow(client).to receive(:repository_file)
        .with(repository.github_installation_id, "bussolabs/shop", "blueprint.json", ref: "trunk").and_return(map)

      reading = read

      expect(reading.state).to eq(:ready)
      expect(reading.document.nodes.first["name"]).to eq("App")
      expect(reading.source_url).to eq("https://github.com/bussolabs/shop/blob/trunk/blueprint.json")
    end

    it "says the map is missing when the file does not exist" do
      allow(client).to receive(:repository_file).and_return(nil)

      expect(read.state).to eq(:missing)
    end

    it "says the map is broken, with the reason, when the file is not a valid map" do
      allow(client).to receive(:repository_file).and_return("{ nope")

      reading = read

      expect(reading.state).to eq(:invalid)
      expect(reading.problem).to include("not valid JSON")
    end

    it "says GitHub did not answer when the call fails" do
      allow(client).to receive(:repository_file).and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001"))

      expect(read.state).to eq(:unreachable)
    end
  end
end
