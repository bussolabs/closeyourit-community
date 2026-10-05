# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — monthly token caps: platform cap from Valhalla (empty = none, as today), a
# variation may only lower it, an own provider pays for itself and answers to its own cap only.
RSpec.describe Ai::TokenBudget do
  let(:organization) { create(:organization) }

  after do
    Ai::Configuration.reset!
    Current.organization = nil
  end

  def cap_for(org)
    Ai::Configuration.reset!
    Ai::Configuration.for(org).monthly_token_cap
  end

  it "has no cap when nobody set one, so closeyour.it keeps working as today" do
    described_class.record(organization.id, 10_000_000)

    expect(cap_for(organization)).to be_nil
    expect { described_class.check!(organization.id) }.not_to raise_error
  end

  it "stops the organization once the platform cap is spent" do
    Settings::Global.instance.update!(ai_org_monthly_token_cap: 100)
    described_class.record(organization.id, 100)

    expect { described_class.check!(organization.id) }
      .to raise_error(Ai::Llm::Client::Error) { |error| expect(error.code).to eq(Ai::TokenBudget::EXHAUSTED_CODE) }
  end

  it "counts each organization and each month apart" do
    Settings::Global.instance.update!(ai_org_monthly_token_cap: 100)
    other = create(:organization)
    travel_to(1.month.ago) { described_class.record(organization.id, 100) }
    described_class.record(other.id, 100)

    expect { described_class.check!(organization.id) }.not_to raise_error
    expect(described_class.spent(organization.id)).to eq(0)
  end

  it "lets a variation lower the platform cap, never raise it" do
    Settings::Global.instance.update!(ai_org_monthly_token_cap: 1_000)
    organization.create_ai_setting!(mode: "variation", monthly_token_cap: 50)
    expect(cap_for(organization)).to eq(50)

    organization.ai_setting.update!(monthly_token_cap: 5_000)
    expect(cap_for(organization)).to eq(1_000)
  end

  it "applies only the organization's own cap to an own provider" do
    Settings::Global.instance.update!(ai_org_monthly_token_cap: 10)
    organization.create_ai_setting!(mode: "own", base_url: "https://llm.acme.test/v1", api_key: "sk", chat_model: "m")

    expect(cap_for(organization)).to be_nil
  end

  it "ignores work done outside an organization" do
    expect { described_class.record(nil, 100) }.not_to change(Ai::UsageMonth, :count)
    expect { described_class.check!(nil) }.not_to raise_error
  end

  describe "in the chat client" do
    let(:url) { "https://llm.test/v1/chat/completions" }
    let(:body) do
      payload = { "id" => "c1", "choices" => [ { "delta" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                  "usage" => { "prompt_tokens" => 7, "completion_tokens" => 5 } }
      "data: #{payload.to_json}\n\ndata: [DONE]\n\n"
    end

    before { Current.organization = organization }

    it "adds the tokens of each answer to the organization's month" do
      stub_request(:post, url).to_return(status: 200, body:)

      Ai::Llm::Client.new.generate_content(system: "s", contents: [])

      expect(described_class.spent(organization.id)).to eq(12)
    end

    it "does not call the provider once the cap is spent" do
      Settings::Global.instance.update!(ai_org_monthly_token_cap: 10)
      described_class.record(organization.id, 10)
      request = stub_request(:post, url)

      expect { Ai::Llm::Client.new.generate_content(system: "s", contents: []) }
        .to raise_error(Ai::Llm::Client::Error)
      expect(request).not_to have_been_requested
    end
  end
end
