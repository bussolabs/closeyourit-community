# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::AssistantComponent, type: :component do
  subject(:render) { render_inline(described_class.new) }

  let(:panel_path) { Rails.application.routes.url_helpers.member_assistant_panel_path }

  it "renders a permanent column that survives Turbo visits" do
    render
    expect(page).to have_css("aside#assistant-dock[data-turbo-permanent][data-controller='ui--assistant']", visible: :all)
  end

  it "renders the panel hidden, as a page column on desktop and full screen on mobile" do
    render
    panel = page.find("[data-ui--assistant-target='panel'][hidden]", visible: :all)
    expect(panel[:class]).to include("md:w-[392px]", "md:shrink-0", "max-md:fixed", "max-md:inset-0")
  end

  it "has no floating button of its own" do
    render
    expect(page).to have_no_css("button[data-test='assistant-fab']", visible: :all)
  end

  # CYRA-558 — a lazy frame inside a hidden container never "appears", so it never loaded. The
  # controller sets `src` on the first opening instead.
  it "leaves the frame without src and without lazy loading" do
    render
    frame = page.find("turbo-frame#assistant_panel", visible: :all)
    expect(frame[:src]).to be_blank
    expect(frame[:loading]).to be_blank
  end

  it "carries the panel url on the controller that loads it on opening" do
    render
    expect(page).to have_css("[data-controller='ui--assistant'][data-ui--assistant-url-value='#{panel_path}']", visible: :all)
  end

  it "prepares the load failure message with a retry button" do
    render
    expect(page).to have_css("[data-ui--assistant-target='error'][data-test='assistant-panel-error'][hidden]",
                             visible: :all, text: I18n.t("member.assistant.panel.failed.load"))
    expect(page).to have_css("[data-test='assistant-panel-retry'][data-action='ui--assistant#retry']",
                             visible: :all, text: I18n.t("member.assistant.panel.failed.retry"))
  end
end
