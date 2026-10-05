# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::AppJwt do
  let(:rsa) { OpenSSL::PKey::RSA.new(2048) }
  let(:now) { Time.utc(2026, 7, 7, 12, 0, 0) }

  subject(:jwt) { described_class.new(app_id: "12345", private_key: rsa.to_pem, now: now).to_s }

  def b64decode(str)
    Base64.urlsafe_decode64(str + ("=" * ((4 - (str.length % 4)) % 4)))
  end

  it "produce un JWT in tre parti" do
    expect(jwt.split(".").size).to eq(3)
  end

  it "imposta iss = app_id, iat con clock-skew e exp entro 10 minuti" do
    _header, payload_b64, _sig = jwt.split(".")
    claims = JSON.parse(b64decode(payload_b64))

    expect(claims["iss"]).to eq("12345")
    expect(claims["iat"]).to eq((now - 60).to_i)
    expect(claims["exp"] - claims["iat"]).to be <= 10 * 60
  end

  it "è firmato RS256 e verificabile con la public key" do
    header_b64, payload_b64, sig_b64 = jwt.split(".")
    signing_input = "#{header_b64}.#{payload_b64}"

    expect(JSON.parse(b64decode(header_b64))["alg"]).to eq("RS256")
    expect(
      rsa.public_key.verify(OpenSSL::Digest.new("SHA256"), b64decode(sig_b64), signing_input)
    ).to be(true)
  end

  it "firma anche con private key coi newline escapati in \\n (vault→CI→container)" do
    escaped = rsa.to_pem.gsub("\n", '\n') # newline reali → `\n` letterale come nell'env del container
    expect(escaped).to include('\n') # sanity: nessun a-capo reale
    expect(escaped).not_to include("\n")

    header_b64, payload_b64, sig_b64 = described_class.new(app_id: "12345", private_key: escaped, now:).to_s.split(".")
    expect(
      rsa.public_key.verify(OpenSSL::Digest.new("SHA256"), b64decode(sig_b64), "#{header_b64}.#{payload_b64}")
    ).to be(true)
  end
end
