# frozen_string_literal: true

# CYRA-1160 — a signed list of insecure versions as the public copy serves it, signed with a key made
# for the example. The app trusts it only after trust_advisory_key!, like the real constant.
module SecurityAdvisories
  def advisory_signing_key = @advisory_signing_key ||= RbNaCl::SigningKey.generate

  def trust_advisory_key!(key = advisory_signing_key)
    stub_const("App::SelfHosted::ADVISORIES_PUBLIC_KEYS", [ Base64.strict_encode64(key.verify_key.to_bytes) ])
  end

  def signed_advisories(issued_at:, advisories:, key: advisory_signing_key)
    payload = { issued_at: issued_at.utc.iso8601, advisories: }.to_json
    { payload: Base64.strict_encode64(payload), signature: Base64.strict_encode64(key.sign(payload)) }.to_json
  end

  # A verified list already stored, as the periodic check leaves it.
  def stored_advisories!(issued_at:, advisories:)
    list = Instance::Advisories.from_payload({ "issued_at" => issued_at.utc.iso8601, "advisories" => advisories.map { |item| item.transform_keys(&:to_s) } })
    Settings::Global.instance.store_security_advisories(list)
  end
end

RSpec.configure do |config|
  config.include SecurityAdvisories
end
