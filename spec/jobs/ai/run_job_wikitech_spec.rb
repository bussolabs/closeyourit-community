# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::RunJob, "wikitech_ask" do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:request_record) { Ai::Request.create!(account: account, organization: org, kind: "wikitech_ask", args: { question: "games?" }) }

  before { create(:membership, account: account, organization: org, role: :member) }

  it "answers in the shape the page draws, with links to the cards" do
    entry = create(:wikitech_entry, organization: org, name: "Godot", categories: [ "game dev" ])
    allow(Wikitech::Ask).to receive(:call).and_return(
      Result.ok(Wikitech::Ask::Answer.new(answer: "Godot.", entries: [ entry ], insufficient: false))
    )

    described_class.perform_now(request_record)

    expect(Wikitech::Ask).to have_received(:call).with(scope: org.wikitech_entries, question: "games?")
    result = request_record.reload.payload
    expect(result).to include("answer" => "Godot.", "insufficient" => false, "scope_reduced" => false)
    expect(result["pages"]).to eq([ { "id" => entry.id, "title" => "Godot", "kind_label" => "game dev",
                                      "url" => "/member/wikitech/entries/#{entry.id}" } ])
  end
end
