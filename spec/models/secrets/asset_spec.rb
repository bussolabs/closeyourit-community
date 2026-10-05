# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Asset, type: :model do
  it "accetta un asset per-progetto con environment opzionale" do
    project = create(:project)
    asset = described_class.new(organization: project.organization, project:, name: "Upload key", asset_type: "p8")
    expect(asset).to be_valid
  end

  it "accetta un asset condiviso ma vieta project ed environment incoerenti" do
    org = create(:organization)
    expect(described_class.new(organization: org, name: "Distribution", asset_type: "p12")).to be_valid

    foreign_project = create(:project)
    invalid = described_class.new(organization: org, project: foreign_project, name: "Bad", asset_type: "p12")
    expect(invalid).not_to be_valid
  end

  it "limita i tipi agli asset CI mobili" do
    project = create(:project)
    asset = described_class.new(organization: project.organization, project:, name: "Shell", asset_type: "sh")
    expect(asset).not_to be_valid
  end
end
