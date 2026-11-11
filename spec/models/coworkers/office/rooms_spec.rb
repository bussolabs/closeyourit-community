require "spec_helper"
require_relative "../../../../app/models/coworkers/office/rooms"

RSpec.describe Coworkers::Office::Rooms do
  let(:configuration) { Data.define(:id, :preset, :watch_every_minutes) }

  it "keeps all rooms inactive without a configured Puck" do
    expect(described_class.active_for([])).to eq([])
    expect(described_class.active_for([ configuration.new(id: "one", preset: nil, watch_every_minutes: nil) ])).to eq([])
  end

  it "opens the archive from the saved research role across catalog versions" do
    %w[researcher@1 researcher@4].each do |preset|
      puck = configuration.new(id: "one", preset: preset, watch_every_minutes: nil)
      expect(described_class.active_for([ puck ])).to eq([ "archive" ])
    end
    %w[observer@4 technical@4 editor@4 unknown@4].each do |preset|
      puck = configuration.new(id: "one", preset: preset, watch_every_minutes: nil)
      expect(described_class.active_for([ puck ])).to eq([])
    end
  end

  it "opens one room per enabled capability and ignores unrelated connected IDs" do
    researcher = configuration.new(id: "one", preset: "researcher@4", watch_every_minutes: nil)
    watcher = configuration.new(id: "two", preset: nil, watch_every_minutes: 60)
    expect(described_class.active_for([ researcher, researcher, watcher ], connected_puck_ids: [ "hidden" ])).to eq(%w[archive observatory])
    expect(described_class.active_for([ researcher, watcher ], connected_puck_ids: [ "two" ])).to eq(%w[archive observatory workshop])
  end

  it "removes rooms after their configuration is disabled" do
    enabled = configuration.new(id: "one", preset: nil, watch_every_minutes: 15)
    disabled = configuration.new(id: "one", preset: nil, watch_every_minutes: nil)
    expect(described_class.active_for([ enabled ], connected_puck_ids: [ "one" ])).to eq(%w[observatory workshop])
    expect(described_class.active_for([ disabled ], connected_puck_ids: [])).to eq([])
  end
end
