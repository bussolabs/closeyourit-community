# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::ConverseHistory do
  let(:conversation) { create(:assistant_conversation) }
  let(:org) { conversation.organization }

  def message(role, content, at:)
    conversation.messages.create!(organization: org, role: role, status: :complete, content: content, created_at: at)
  end

  def history_before(question) = described_class.call(conversation: conversation, question: question)

  it "keeps plain turns as text" do
    message(:user, "hi", at: 3.minutes.ago)
    message(:assistant, "hello", at: 2.minutes.ago)
    question = message(:user, "next", at: 1.minute.ago)

    expect(history_before(question)).to eq([ { role: "user", parts: [ { text: "hi" } ] },
                                             { role: "model", parts: [ { text: "hello" } ] } ])
  end

  # Without the call, the model read "I prepared the card" as plain text and imitated it without
  # calling the tool: the card never existed (seen live on 2026-10-01). CYRA-908
  it "replays a reply with cards as the tool call, its answer and then the text" do
    message(:user, "open a ticket", at: 3.minutes.ago)
    reply = message(:assistant, "Card ready, confirm it.", at: 2.minutes.ago)
    proposal = create(:assistant_proposal, message: reply, kind: :create_ticket,
                                           payload: { "project_id" => "p1", "project_key" => "STR", "title" => "Cart",
                                                      "description" => "Broken", "similar" => [] })
    question = message(:user, "and another one", at: 1.minute.ago)

    turns = history_before(question)

    call = turns[1][:parts].sole[:functionCall]
    expect(call).to eq(id: "proposal-#{proposal.id}", name: "propose_ticket",
                       args: { "project_key" => "STR", "title" => "Cart", "description" => "Broken" })
    expect(turns[2]).to eq(role: "user", parts: [ { functionResponse: {
                             id: "proposal-#{proposal.id}", name: "propose_ticket",
                             response: { proposal_id: proposal.id, status: "awaiting_confirmation" }
                           } } ])
    expect(turns[3]).to eq(role: "model", parts: [ { text: "Card ready, confirm it." } ])
  end

  it "tells the model how an earlier card ended" do
    message(:user, "open a ticket", at: 3.minutes.ago)
    reply = message(:assistant, "Card ready.", at: 2.minutes.ago)
    create(:assistant_proposal, message: reply, status: :confirmed)
    question = message(:user, "next", at: 1.minute.ago)

    response = history_before(question)[2][:parts].sole[:functionResponse][:response]
    expect(response[:status]).to eq("confirmed")
  end

  it "builds a wire the gateway accepts: tool calls, one tool message each, then the text" do
    message(:user, "open two", at: 3.minutes.ago)
    reply = message(:assistant, "Two cards.", at: 2.minutes.ago)
    create_list(:assistant_proposal, 2, message: reply)
    question = message(:user, "next", at: 1.minute.ago)

    wire = Ai::Llm::Messages.build(system: "s", contents: history_before(question))

    expect(wire.map { |m| m[:role] }).to eq(%w[system user assistant tool tool assistant])
    expect(wire[2][:tool_calls].map { |c| c[:id] }).to eq(wire[3..4].map { |m| m[:tool_call_id] })
  end

  it "maps every proposal kind to a declared write tool" do
    names = Assistant::Tools::Registry::WRITE_TOOLS.map(&:tool_name)
    assistant_kinds = Assistant::Proposal.kinds.keys - Assistant::Proposal::PUCK_ONLY_KINDS
    expect(assistant_kinds.map { |kind| described_class::KIND_TOOLS.fetch(kind) }).to all(be_in(names))
  end
end
