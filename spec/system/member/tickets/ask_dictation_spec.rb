# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dictation in the Ask the tickets question", :js, type: :system do
  let(:org) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }

  # A 440 Hz tone stands in for the microphone: same Web Audio path as a real voice.
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

  before do
    allow(Ai::Llm::Client).to receive(:new)
      .and_return(instance_double(Ai::Llm::Client, transcribe: "Did checkout break on Safari before?"))
    sign_in_as(account)
    visit ask_member_tickets_path
    page.execute_script(fake_mic)
  end

  it "writes what was said into the question" do
    find("[data-test='dictation-mic']").click
    expect(page).to have_css("[data-test='dictation-waves']", text: "0:01")
    page.save_screenshot(Rails.root.join("tmp/ask_dictation.png").to_s) if ENV["ASK_SHOT"]
    find("[data-test='dictation-done']").click

    expect(page).to have_field("ask-question", with: "Did checkout break on Safari before?")
  end
end
