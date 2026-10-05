# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Comment field on a ticket", :js, type: :system do
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

  def top_of(test_id)
    page.evaluate_script("document.querySelector(\"[data-test='#{test_id}']\").getBoundingClientRect().top")
  end

  before do
    allow(Ai::Llm::Client).to receive(:new)
      .and_return(instance_double(Ai::Llm::Client, transcribe: "It also happens on staging."))
    sign_in_as(account)
    visit member_ticket_path(ticket, tab: "discussion")
    page.execute_script(fake_mic)
  end

  it "shows Comment only once the field is in use, under the field" do
    expect(page).to have_css("[data-test='member-ticket-comment-submit']", visible: :hidden)

    find("[data-test='member-ticket-comment-body']").click

    expect(page).to have_css("[data-test='member-ticket-comment-submit']", visible: :visible)
    expect(top_of("member-ticket-comment-submit")).to be > top_of("member-ticket-comment-body") + 90
  end

  it "centres the microphone in the resting field" do
    gaps = page.evaluate_script(<<~JS)
      (() => { const f = document.getElementById('ticket-comment-body').getBoundingClientRect();
               const m = document.querySelector("[data-test='dictation-mic']").getBoundingClientRect();
               return [m.top - f.top, f.bottom - m.bottom, f.right - m.right] })()
    JS
    expect(gaps).to eq([ 3, 3, 3 ])
  end

  it "starts dictating from the field at rest, and cancelling gives the resting field back" do
    find("[data-test='dictation-mic']").click

    expect(page).to have_css("[data-test='dictation-waves']", text: "0:01")
    expect(page.evaluate_script("document.getElementById('ticket-comment-body').offsetHeight")).to be > 90
    find("[data-test='dictation-cancel']").click

    expect(page).to have_no_css("[data-test='dictation-waves']")
    expect(page).to have_css("[data-test='member-ticket-comment-extras']", visible: :hidden)
    expect(page.evaluate_script("document.getElementById('ticket-comment-body').offsetHeight")).to eq(34)
  end

  it "adds what was said to the comment, after what was already written" do
    find("[data-test='member-ticket-comment-body']").fill_in(with: "Confirmed.")
    find("[data-test='dictation-mic']").click
    expect(page).to have_css("[data-test='dictation-waves']", text: "0:01")
    find("[data-test='dictation-done']").click

    expect(page).to have_field("ticket-comment-body", with: "Confirmed. It also happens on staging.")
    click_on_test "member-ticket-comment-submit"

    expect(page).to have_css("[data-test='flash-notice']")
    expect(ticket.comments.reload.last.body).to eq("Confirmed. It also happens on staging.")
  end
end
