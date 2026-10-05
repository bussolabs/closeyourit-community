# frozen_string_literal: true

require "rails_helper"

# An organization's own provider address is checked at call time too: a public name that resolves
# inside the internal network must never be called (SSRF, CYRA-914).
RSpec.describe "AI clients and an organization's own provider" do
  let(:organization) { create(:organization) }

  before do
    organization.create_ai_setting!(mode: "own", base_url: "https://llm.acme.test/v1", api_key: "sk-acme",
                                    chat_model: "acme-chat", embedding_model: "acme-embed")
    Ai::Configuration.reset!
    Current.organization = organization
    allow(NetworkGuard).to receive(:resolved_public_address).with("llm.acme.test").and_return(nil)
  end

  after do
    Ai::Configuration.reset!
    Current.organization = nil
  end

  it "refuses the chat call before any request leaves" do
    expect { Ai::Llm::Client.new.generate_content(system: "s", contents: [ { role: "user", parts: [ { text: "hi" } ] } ]) }
      .to raise_error(Ai::Llm::Client::Error) { |error| expect(error.code).to eq("R422-AI-008") }
    expect(a_request(:any, /llm\.acme\.test/)).not_to have_been_made
  end

  it "refuses the embedding call before any request leaves" do
    expect { Ai::Embedding::Client.new.embed(input: "hi") }
      .to raise_error(Ai::Embedding::Client::Error) { |error| expect(error.code).to eq("R422-AI-008") }
    expect(a_request(:any, /llm\.acme\.test/)).not_to have_been_made
  end

  it "fails the connection test instead of calling the address" do
    checks = Ai::TestConnection.call(config: Ai::Configuration.current).value

    expect(checks.find { |check| check.key == :chat }).to have_attributes(status: :failed)
    expect(a_request(:any, /llm\.acme\.test/)).not_to have_been_made
  end
end
