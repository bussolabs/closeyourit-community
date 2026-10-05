# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::EntityMarkComponent, type: :component do
  it "draws the uploaded image when there is one, before anything else" do
    project = create(:project, color: "indigo", icon: "rocket")
    project.icon_image.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
      filename: "icon.png", content_type: "image/png"
    )

    render_inline(described_class.new(record: project))

    expect(page).to have_css("img")
    expect(page).to have_no_css("svg[data-icon]", visible: :all)
  end

  it "draws the icon on the color tint when there is an icon and no image" do
    project = build(:project, color: "indigo", icon: "rocket")

    render_inline(described_class.new(record: project))

    expect(page).to have_css("span.bg-indigo-50.text-indigo-600 svg[data-icon='rocket']", visible: :all)
    expect(page).to have_no_css("img")
  end

  it "falls back to the color swatch without icon or image" do
    group = build(:group, color: "emerald", icon: nil)

    render_inline(described_class.new(record: group))

    expect(page).to have_css("span.bg-emerald-500")
    expect(page).to have_no_css("svg[data-icon]", visible: :all)
    expect(page).to have_no_css("img")
  end

  it "size non riconosciuta → fallback a DEFAULT_SIZE (sm: w-6 h-6)" do
    group = build(:group, color: "indigo", icon: "rocket")

    render_inline(described_class.new(record: group, size: :xl))

    expect(page).to have_css("span.w-6.h-6")
  end
end
