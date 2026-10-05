# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ButtonGroupComponent, type: :component do
  def decision_group(**options)
    render_inline(described_class.new(**options)) do |group|
      group.with_button(variant: :success, size: :sm, icon: "check", icon_only: true, label: "Approva", test_id: "approve")
      group.with_button(variant: :danger, size: :sm, icon: "x", icon_only: true, label: "Rifiuta", test_id: "reject")
    end
  end

  it "rende i bottoni nell'ordine dichiarato dentro un wrapper che clippa i raggi" do
    decision_group
    expect(page).to have_css("div.inline-flex.rounded-md.overflow-hidden")
    expect(page).to have_css("div button", count: 2)
    expect(page).to have_css("button[data-test='approve'] svg[data-icon='check']")
    expect(page).to have_css("button[data-test='reject'] svg[data-icon='x']")
  end

  it "spegne il raggio dei figli senza che il caller debba chiederlo" do
    decision_group
    expect(page).to have_no_css("button.rounded-md")
  end

  it "non impone bordo né divisori: li passa il caller" do
    decision_group
    expect(page).to have_no_css("div.border")

    decision_group(class: "border border-stone-200 divide-x divide-stone-200")
    expect(page).to have_css("div.border.border-stone-200.divide-x")
  end

  it "espone il data-test sul wrapper" do
    decision_group(test_id: "home-decision")
    expect(page).to have_css("div[data-test='home-decision']")
  end

  it "accetta un figlio button_to con form display:contents (il button resta item della flex)" do
    render_inline(described_class.new) do |group|
      group.with_button(variant: :success, size: :sm, icon: "check", icon_only: true, label: "Approva",
                        href: "/approva", method: :post, form_class: "contents")
    end
    expect(page).to have_css("div.inline-flex > form.contents > button")
    expect(page).to have_css("form[action='/approva']")
  end
end
