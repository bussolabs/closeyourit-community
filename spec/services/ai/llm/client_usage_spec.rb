# frozen_string_literal: true

require "rails_helper"

# Token counting for the monthly cap (CYRA-914): a counting fault must never cost an answer the
# provider already gave, and a reused client must not count one answer twice.
RSpec.describe Ai::Llm::Client, "token usage" do
  subject(:client) { described_class.new(api_key: "test-key", base_url: "https://llm.test/v1", model: "test-model") }

  let(:organization) { create(:organization) }
  let(:url) { "https://llm.test/v1/chat/completions" }

  def sse(*events) = events.map { |event| "data: #{event.to_json}\n\n" }.join + "data: [DONE]\n\n"

  def chunk(text, usage: nil)
    payload = { "id" => "c1", "choices" => [ { "delta" => { "content" => text }, "finish_reason" => "stop" } ] }
    usage ? payload.merge("usage" => usage) : payload
  end

  def ask = client.generate_content(system: "s", contents: [ { role: "user", parts: [ { text: "hi" } ] } ])

  before { Current.organization = organization }
  after { Current.organization = nil }

  it "counts an answer once, even when the next answer on the same client brings no usage" do
    stub_request(:post, url).to_return(
      { status: 200, body: sse(chunk("a", usage: { "prompt_tokens" => 10, "completion_tokens" => 5 })) },
      { status: 200, body: sse(chunk("b")) }
    )
    allow(Ai::TokenBudget).to receive(:record).and_call_original

    2.times { ask }

    expect(Ai::TokenBudget.spent(organization.id)).to eq(15)
  end

  it "keeps the answer when the count cannot be saved" do
    stub_request(:post, url).to_return(status: 200,
                                       body: sse(chunk("kept", usage: { "prompt_tokens" => 1, "completion_tokens" => 1 })))
    allow(Ai::UsageMonth).to receive(:upsert).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect(ask).to eq("kept")
  end
end
