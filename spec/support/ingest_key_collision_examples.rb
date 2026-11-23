# frozen_string_literal: true

RSpec.shared_context "an error with colliding field names" do
  let(:colliding_error) do
    event.merge(
      "extra" => { "nested#{0.chr}" => [ { "k#{0.chr}" => "repaired", "k" => "original", "k_2" => "reserved" } ],
                   "token" => "secret", "tok#{0.chr}en" => "other" },
      "user" => { "username" => "private", "user#{0.chr}name" => "private-copy", "ip_address" => "192.0.2.1", "ip_#{0.chr}address" => "192.0.2.2" },
      "us#{0.chr}er" => { "username" => "private-section" },
      "request" => { "headers" => { "x-forwarded-for" => "192.0.2.1", "x-forwarded-#{0.chr}for" => "192.0.2.2" },
                     "env" => { "value" => "private" }, "en#{0.chr}v" => { "value" => "private-copy" },
                     "url" => "https://example.test/one?token=secret", "ur#{0.chr}l" => "https://example.test/two?token=other",
                     "query_string" => "token=secret", "query_#{0.chr}string" => "token=other" }
    )
  end

  def expect_safe_collision_payload(payload)
    expect(payload.dig("extra", "nested")).to eq([ { "k" => "original", "k_2" => "reserved", "k_3" => "repaired" } ])
    expect(payload["extra"]).to include("token" => "[FILTERED]", "token_2" => "[FILTERED]")
    expect(payload.dig("user", "username_2")).to eq("[FILTERED]")
    expect(payload.dig("user", "ip_address_2")).to eq("[FILTERED]")
    expect(payload.dig("user_2", "username")).to eq("[FILTERED]")
    expect(payload.dig("request", "headers").values).to all(eq("[FILTERED]"))
    expect(payload["request"]).to include("env_2" => "[FILTERED]", "url_2" => "https://example.test/two",
                                         "query_string_2" => "token=[FILTERED]")
    expect(payload.to_json).not_to include("private", "192.0.2.", "secret", "other", "\\u0000")
  end
end
