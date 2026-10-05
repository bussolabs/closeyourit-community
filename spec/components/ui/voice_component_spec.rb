# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::VoiceComponent, type: :component do
  it "renders a hidden microphone and the overlay wired to the voice endpoint (CYRA-908)" do
    render_inline(described_class.new)

    trigger = page.find("[data-test='voice-trigger']", visible: :all)
    expect(trigger[:hidden]).not_to be_nil
    expect(page).to have_css("[data-controller='ui--voice'][data-ui--voice-url-value='/member/assistant/conversations/voice']",
                             visible: :all)
    expect(page).to have_css("[data-test='voice-overlay'][hidden]", visible: :all)
  end

  it "says what to ask, with examples and a link to the assistant guide" do
    render_inline(described_class.new)

    expect(page).to have_css("[data-test='voice-examples'] li", count: 3, visible: :all)
    expect(page).to have_css("a[data-test='voice-guide'][href='/member/guides/assistant']", visible: :all)
  end

  it "renders nothing when the voice switch is off" do
    Settings::Global.instance.update!(ai_assistant_voice_enabled: false)
    render_inline(described_class.new)
    expect(page).to have_no_css("[data-controller='ui--voice']", visible: :all)
  end

  it "renders nothing when the chat switch is off" do
    Settings::Global.instance.update!(ai_assistant_chat_enabled: false)
    render_inline(described_class.new)
    expect(page).to have_no_css("[data-controller='ui--voice']", visible: :all)
  end
end
