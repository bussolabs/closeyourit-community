# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::ConfirmPuckAction do
  let(:organization) { create(:organization) }
  let(:account) { create(:account, telegram_chat_id: "900").tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let(:ticket) { create(:ticket, project: project) }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Triage", instructions: "Help") }
  let(:run) { Coworkers::Start.call(puck: puck, kind: "chat", input: "x", account: account) }
  let(:proposal) do
    Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: account, kind: :comment_ticket,
                                payload: { "ticket_id" => ticket.id, "body" => "On it" })
  end

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(Telegram::Send).to receive(:api_post)
  end

  def tap_button(data) = described_class.call(callback: { id: "cb1", data: data, message: { chat: { id: 900 } } })
  def text(key) = I18n.t("telegram.puck.#{key}", locale: account.effective_locale)

  it "says the action is gone when the proposal does not exist" do
    account
    expect(tap_button("cwp:c:#{SecureRandom.uuid}").value).to eq(:gone)
    expect(Telegram::Send).to have_received(:api_post).with("answerCallbackQuery", callback_query_id: "cb1", text: text("action_gone"))
  end

  it "discards the proposal from its button" do
    expect(tap_button("cwp:d:#{proposal.id}").value).to eq(:discarded)
    expect(proposal.reload).to be_status_discarded
    expect(Telegram::Send).to have_received(:api_post).with("answerCallbackQuery", callback_query_id: "cb1", text: text("discarded"))
    expect(ticket.comments.count).to eq(0)
  end

  it "answers with the reason when the confirmation fails" do
    proposal.update!(payload: { "ticket_id" => SecureRandom.uuid, "body" => "On it" })
    result = tap_button("cwp:c:#{proposal.id}")
    expect(result).to be_err
    expect(result.error.code).to eq("R404-PROPOSAL-001")
    expect(Telegram::Send).to have_received(:api_post).with("answerCallbackQuery", callback_query_id: "cb1", text: result.error.message)
    expect(proposal.reload).to be_status_failed
  end
end
