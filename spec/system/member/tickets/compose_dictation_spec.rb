# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dictation in Write it for me", :js, type: :system do
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
    create(:project, organization: org)
    allow(Ai::Llm::Client).to receive(:new)
      .and_return(instance_double(Ai::Llm::Client, transcribe: "The checkout times out on mobile."))
    sign_in_as(account)
    visit new_member_ticket_path
    page.execute_script(fake_mic)
    find("[data-test='ticket-compose-open']").click
  end

  it "adds what was said to the field, after what was already written" do
    find("[data-test='ticket-compose-prompt']").fill_in(with: "Urgent.")
    find("[data-test='dictation-mic']").click

    # The field stays in view while the strip with the waves listens under it.
    expect(page).to have_css("[data-test='dictation-waves']", text: "0:01")
    expect(page).to have_css("[data-test='ticket-compose-prompt']")
    find("[data-test='dictation-done']").click

    expect(page).to have_field("ai-buddy-prompt", with: "Urgent. The checkout times out on mobile.")
    expect(page).to have_no_css("[data-test='dictation-waves']")
    expect(Assistant::Message.count).to eq(0)
  end

  it "cancels and leaves the field as it was" do
    find("[data-test='ticket-compose-prompt']").fill_in(with: "Urgent.")
    find("[data-test='dictation-mic']").click
    expect(page).to have_css("[data-test='dictation-waves']")
    find("[data-test='dictation-cancel']").click

    expect(page).to have_no_css("[data-test='dictation-waves']")
    expect(page).to have_field("ai-buddy-prompt", with: "Urgent.")
  end

  it "drops a text that arrives after Cancel" do
    # The answer is held back until the test releases it: a condition, never a fixed time.
    release = Queue.new
    answered = false
    slow = instance_double(Ai::Llm::Client)
    allow(slow).to receive(:transcribe) do
      release.pop
      answered = true
      "Too late."
    end
    allow(Ai::Llm::Client).to receive(:new).and_return(slow)
    find("[data-test='ticket-compose-prompt']").fill_in(with: "Urgent.")
    find("[data-test='dictation-mic']").click
    expect(page).to have_css("[data-test='dictation-waves']", text: "0:01")
    find("[data-test='dictation-done']").click
    find("body").send_keys(:escape)

    expect(page).to have_no_css("[data-test='dictation-waves']")
    release << :go
    wait_until("the slow answer comes back") { answered }
    expect(page).to have_field("ai-buddy-prompt", with: "Urgent.")
  end
end
