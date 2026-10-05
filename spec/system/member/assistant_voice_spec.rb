# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Assistant voice", :js, type: :system do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }

  # A 440 Hz tone stands in for the microphone: same Web Audio path as a real voice. CYRA-908
  let(:fake_mic) do
    <<~JS
      navigator.mediaDevices.getUserMedia = async () => {
        const ctx = new AudioContext()
        const tone = ctx.createOscillator()
        const out = ctx.createMediaStreamDestination()
        tone.connect(out)
        tone.start()
        return out.stream
      }
    JS
  end

  before { sign_in_as(account) }

  it "records, uploads a 16 kHz WAV and shows the transcribing bubble, then the text" do
    visit member_projects_path
    page.execute_script(fake_mic)

    find("[data-test='voice-trigger']").click
    expect(page).to have_css("[data-test='voice-overlay']:not([hidden])")
    # At least one second recorded: the timer has ticked, so the recorder holds audio.
    expect(page).to have_css("[data-ui--voice-target='title']", text: "0:01")
    find("[data-test='voice-send']").click

    expect(page).to have_css("[data-test='assistant-message'][data-status='transcribing']")
    message = Assistant::Message.role_user.sole
    header = message.audio.download.byteslice(0, 28)
    expect(header.byteslice(0, 4)).to eq("RIFF")
    expect(header.byteslice(24, 4).unpack1("V")).to eq(16_000)

    client = instance_double(Ai::Llm::Client, transcribe: "Apri un ticket su CYFL")
    allow(Ai::Llm::Client).to receive(:new).and_return(client)
    perform_enqueued_jobs(only: Assistant::TranscribeJob)

    expect(page).to have_css("[data-test='assistant-message'][data-status='complete']", text: "Apri un ticket su CYFL",
                                                                                        wait: 10)
    expect(page).to have_css("[data-test='assistant-correct']")
  end

  it "shows what to ask while listening and opens the assistant guide from there" do
    visit member_projects_path
    page.execute_script(fake_mic)

    find("[data-test='voice-trigger']").click
    expect(page).to have_css("[data-test='voice-examples'] li", count: 3)
    page.save_screenshot(Rails.root.join("tmp/voice_examples.png")) if ENV["SHOT"]
    find("[data-test='voice-guide']").click

    expect(page).to have_css("[data-test='member-guide-assistant']")
    expect(page).to have_css("[data-test='guide-assistant-section']", count: 4)
    page.save_screenshot(Rails.root.join("tmp/assistant_guide.png")) if ENV["SHOT"]
    expect(Assistant::Message.count).to eq(0)
  end

  it "cancels with Esc and sends nothing" do
    visit member_projects_path
    page.execute_script(fake_mic)

    find("[data-test='voice-trigger']").click
    expect(page).to have_css("[data-test='voice-overlay']:not([hidden])")
    find("body").send_keys(:escape)

    expect(page).to have_css("[data-test='voice-overlay'][hidden]", visible: :all)
    expect(Assistant::Message.count).to eq(0)
  end

  # A device the OS keeps muted still resolves getUserMedia, it just delivers zeros.
  it "warns after a few seconds when the microphone delivers only silence" do
    visit member_projects_path
    page.execute_script(<<~JS)
      navigator.mediaDevices.getUserMedia = async () => new AudioContext().createMediaStreamDestination().stream
    JS

    find("[data-test='voice-trigger']").click
    hint = I18n.t("member.assistant.voice.silent_hint", locale: account.effective_locale)
    expect(page).to have_no_css("[data-ui--voice-target='hint']", text: hint)
    expect(page).to have_css("[data-ui--voice-target='hint'][data-silent]", text: hint, wait: 6)
  end

  it "lets the user switch microphone from the overlay and remembers the choice" do
    visit member_projects_path
    page.execute_script(<<~JS)
      window.requestedDevices = []
      navigator.mediaDevices.enumerateDevices = async () => [
        { kind: "audioinput", deviceId: "mic-1", label: "Built-in Microphone" },
        { kind: "audioinput", deviceId: "mic-2", label: "USB Headset" },
        { kind: "audiooutput", deviceId: "spk-1", label: "Speakers" }
      ]
      navigator.mediaDevices.getUserMedia = async (constraints) => {
        const id = constraints.audio.deviceId?.exact || "mic-1"
        window.requestedDevices.push(id)
        const ctx = new AudioContext()
        const tone = ctx.createOscillator()
        const out = ctx.createMediaStreamDestination()
        tone.connect(out)
        tone.start()
        out.stream.getAudioTracks()[0].getSettings = () => ({ deviceId: id })
        return out.stream
      }
    JS

    find("[data-test='voice-trigger']").click
    devices = find("[data-test='voice-devices']")
    devices.find("button[aria-haspopup='listbox']").click
    expect(devices).to have_no_css("[role='option']", text: "Speakers")
    devices.find("[role='option']", text: "USB Headset").click

    expect(page).to have_css("[data-test='voice-devices'] button[aria-haspopup='listbox']", text: "USB Headset")
    expect(page.evaluate_script("window.requestedDevices")).to eq(%w[mic-1 mic-2])

    find("body").send_keys(:escape)
    find("[data-test='voice-trigger']").click
    expect(page).to have_css("[data-test='voice-devices'] button[aria-haspopup='listbox']", text: "USB Headset")
    expect(page.evaluate_script("window.requestedDevices.at(-1)")).to eq("mic-2")
  end

  describe "from the panel's composer" do
    before do
      visit member_projects_path
      page.execute_script(fake_mic)
      find("[data-test='assistant-trigger']").click
      expect(page).to have_css("[data-test='assistant-input']")
    end

    it "swaps the text field for the waves and sends to the conversation on screen" do
      find("[data-test='assistant-mic']").click

      expect(page).to have_css("[data-test='assistant-waves']")
      expect(page).to have_no_css("[data-test='assistant-input']")
      expect(page).to have_css("[data-test='assistant-waves']", text: "0:01")
      # The waves span the strip up to the timer (left 8px + right 76px), not a canvas' default 300px.
      strip, waves = page.evaluate_script(<<~JS)
        [document.querySelector("[data-test='assistant-waves']").clientWidth,
         document.querySelector("[data-test='assistant-waves'] canvas").clientWidth]
      JS
      expect(waves).to be_within(4).of(strip - 84)
      timer_left = page.evaluate_script("document.querySelector(\"[data-ui--voice-inline-target='status']\").getBoundingClientRect().left")
      canvas_right = page.evaluate_script("document.querySelector(\"[data-test='assistant-waves'] canvas\").getBoundingClientRect().right")
      expect(canvas_right).to be <= timer_left
      find("[data-test='assistant-send']").click

      expect(page).to have_css("[data-test='assistant-message'][data-status='transcribing']")
      expect(Assistant::Message.role_user.sole).to be_status_transcribing
    end

    it "cancels and gives the text field back" do
      find("[data-test='assistant-mic']").click
      expect(page).to have_css("[data-test='assistant-waves']")
      find("[data-test='assistant-mic-cancel']").click

      expect(page).to have_css("[data-test='assistant-input']")
      expect(page).to have_no_css("[data-test='assistant-waves']")
      expect(Assistant::Message.count).to eq(0)
    end
  end

  it "records from the conversation page into that conversation" do
    conversation = Assistant::Conversation.create!(account: account, organization: org)
    visit member_assistant_conversation_path(conversation)
    page.execute_script(fake_mic)

    find("[data-test='assistant-mic']").click
    expect(page).to have_css("[data-test='assistant-waves']", text: "0:01")
    find("[data-test='assistant-send']").click

    expect(page).to have_css("[data-test='assistant-message'][data-status='transcribing']")
    expect(page).to have_css("[data-test='assistant-input']")
    expect(conversation.messages.sole).to be_status_transcribing
  end

  it "explains how to allow the microphone when permission is denied" do
    visit member_projects_path
    page.execute_script(<<~JS)
      navigator.mediaDevices.getUserMedia = async () => { throw new DOMException("denied", "NotAllowedError") }
    JS

    find("[data-test='voice-trigger']").click

    expect(page).to have_text(I18n.t("member.assistant.voice.denied_title", locale: account.effective_locale))
    find("[data-test='voice-close']").click
    expect(page).to have_css("[data-test='voice-overlay'][hidden]", visible: :all)
  end
end
