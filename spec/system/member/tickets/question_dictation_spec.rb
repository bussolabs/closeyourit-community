# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dictation in the question field of a ticket", :js, type: :system do
  let(:org) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }
  let(:ticket) { create(:ticket, organization: org, project: create(:project, organization: org)) }

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
      .and_return(instance_double(Ai::Llm::Client, transcribe: "Which browser shows it?"))
    sign_in_as(account)
    visit member_ticket_path(ticket, tab: "questions")
    page.execute_script(fake_mic)
  end

  it "keeps Ask inside the field, with the microphone beside it" do
    inside = page.evaluate_script(<<~JS)
      (() => { const f = document.getElementById('ticket-question-body').getBoundingClientRect();
               const a = document.querySelector("[data-test='ticket-question-submit']").getBoundingClientRect();
               const m = document.querySelector("[data-test='dictation-mic']").getBoundingClientRect();
               return [a.top - f.top, f.right - a.right, a.left - m.right, m.top - f.top] })()
    JS
    expect(inside).to eq([ 3, 3, 3, 3 ])
  end

  it "writes what was said into the question, ready to ask" do
    find("[data-test='dictation-mic']").click
    expect(page).to have_css("[data-test='dictation-waves']", text: "0:01")
    find("[data-test='dictation-done']").click

    expect(page).to have_field("ticket-question-body", with: "Which browser shows it?")
    click_on_test "ticket-question-submit"

    expect(page).to have_css("[data-test='flash-notice']")
    expect(ticket.questions.reload.last.body).to eq("Which browser shows it?")
  end
end
