# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectSerializer do
  it "espone l'icona Font Awesome e icon_image_url nil senza immagine" do
    project = create(:project, icon: "rocket")
    json = JSON.parse(described_class.new(project).serialize)

    expect(json["icon"]).to eq("rocket")
    expect(json["icon_image_url"]).to be_nil
  end

  it "espone icon_image_url quando c'è un'immagine caricata" do
    project = create(:project)
    project.icon_image.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
      filename: "icon.png", content_type: "image/png"
    )
    json = JSON.parse(described_class.new(project).serialize)

    expect(json["icon_image_url"]).to be_present
  end
end
