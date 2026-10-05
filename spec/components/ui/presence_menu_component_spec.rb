# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::PresenceMenuComponent, type: :component do
  def render_menu(count, viewer: nil)
    accounts = Array.new(count) { |index| build_stubbed(:account, name: "Online User #{index + 1}") }
    render_inline(described_class.new(accounts: accounts, viewer: viewer))
  end

  # CYRA-898 — the trigger is as wide as its content: no fixed width, no empty avatar slots.
  it "sizes the trigger to its content instead of reserving four slots" do
    render_menu(1)

    summary_class = page.find("summary")[:class]
    expect(summary_class).to include("md:w-[34px]", "md:@min-[810px]:w-auto", "border-0")
    expect(summary_class).not_to include("lg:w-[154px]", "xl:w-[220px]")
    expect(page).to have_css("[data-test~='presence-preview-slot']", count: 1, visible: :all)
  end

  it "shows the connection as a dot, with a label that the controller reveals only on trouble" do
    render_menu(1)

    expect(page).to have_css("span[data-connection-status-target='icon'].rounded-full.bg-green-500")
    expect(page).to have_css("span[data-connection-status-target='text'].sr-only", visible: :all)
  end

  # The trigger is 34px at md and the count needs room, so it only comes back on the widest topbar (CYRA-634).
  it "shows the count only on the widest topbar" do
    render_menu(2)

    label = page.find("summary [data-test='presence-count']", visible: :all)
    expect(label[:class]).to include("md:@min-[980px]:block")
    expect(label[:class]).not_to include("md:@min-[810px]:block")
  end

  it "says only you when the viewer is the only one online" do
    viewer = build_stubbed(:account, name: "Ada Lovelace")
    render_inline(described_class.new(accounts: [ viewer ], viewer: viewer))

    expect(page).to have_css("summary [data-test='presence-only-you']", text: I18n.t("member.presence.only_you"), visible: :all)
    expect(page).to have_no_css("summary [data-test='presence-count']", visible: :all)
    expect(page).to have_no_css("summary [data-test^='presence-avatar-']", visible: :all)
  end

  it "goes back to initials and count as soon as someone else is online" do
    viewer = build_stubbed(:account, name: "Ada Lovelace")
    other = build_stubbed(:account, name: "Grace Hopper")
    render_inline(described_class.new(accounts: [ viewer, other ], viewer: viewer))

    expect(page).to have_no_css("[data-test='presence-only-you']", visible: :all)
    expect(page).to have_css("summary [data-test^='presence-avatar-']", count: 2, visible: :all)
  end

  it "with four online shows four avatars and no overflow" do
    render_menu(4)

    expect(page).to have_css("summary [data-test^='presence-avatar-']", count: 4)
    expect(page).to have_no_css("[data-test='presence-overflow']")
  end

  it "beyond four online shows three avatars and the rest in the fourth slot" do
    render_menu(7)

    expect(page).to have_css("summary [data-test^='presence-avatar-']", count: 3)
    expect(page).to have_css("summary [data-test~='presence-overflow']", text: "+4")
    expect(page).to have_css("[data-test='presence-menu-row']", count: 7, visible: :all)
  end

  it "renders an accessible empty state when nobody is visible" do
    render_menu(0)

    expect(page).to have_css("[data-test='presence-empty']", text: I18n.t("member.presence.empty"), visible: :all)
  end
end
