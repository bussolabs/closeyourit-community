# frozen_string_literal: true

require "rails_helper"

# The New Puck dialog shows every mascot at once instead of a dropdown. Hovering one plays its animation,
# and the mascots the account's Puckies already use (remembered in this browser) carry a mark.
RSpec.describe "Coworkers — the mascot grid in New Puck", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account, locale: "it") }
  let!(:researcher) { Coworkers::Puck.create!(account: owner, organization: org, name: "Researcher", instructions: "Cite sources") }
  let!(:editor) { Coworkers::Puck.create!(account: owner, organization: org, name: "Editor", instructions: "Write drafts") }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    create(:membership, account: owner, organization: org, role: :owner)
    sign_in_as(owner)
  end

  def open_new_puck(stored = {})
    visit member_coworkers_path
    stored.each do |puck, mascot|
      page.execute_script("localStorage.setItem(arguments[0], arguments[1])", "coworkers:mascot:#{org.id}:#{owner.id}:#{puck.id}", mascot)
    end
    visit member_coworkers_path(new: 1)
    expect_test "coworkers-mascot-grid"
  end

  it "shows all twenty mascots without opening anything, and picks one with a click" do
    open_new_puck

    expect(page).to have_css("[data-test='coworkers-mascot-grid'] [data-test^='coworkers-mascot-option-']", count: 20, visible: true)
    click_on_test "coworkers-mascot-option-07"

    expect(find("[data-test='coworkers-mascot-option-07']")["aria-pressed"]).to eq("true")
    expect(find("[data-test='coworkers-mascot-option-01']")["aria-pressed"]).to eq("false")
  end

  it "plays the mascot's animation while the pointer is on it" do
    open_new_puck

    find("[data-test='coworkers-mascot-option-03']").hover

    sprite = find("[data-test='coworkers-mascot-option-03'] [data-test='coworkers-mascot-sprite']", visible: :all)
    expect(sprite[:src]).to end_with("/coworkers/mascots/animations/03.webp")
  end

  it "marks the mascots the account's Puckies already use, with their names" do
    open_new_puck(researcher => "05")

    used = find("[data-test='coworkers-mascot-option-05'] [data-test='coworkers-mascot-used']")
    expect(used).to be_visible
    expect(find("[data-test='coworkers-mascot-option-05']")[:title]).to include("Researcher")
    # A Puck with no choice in this browser shows the default mascot, so it uses that one.
    expect(find("[data-test='coworkers-mascot-option-01']")[:title]).to include("Editor")
    expect(page).to have_no_css("[data-test='coworkers-mascot-option-09'] [data-test='coworkers-mascot-used']", visible: true)
  end
end
