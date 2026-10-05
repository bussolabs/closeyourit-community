# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Assets::Crypto do
  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  it "cifra e decifra autenticando contenuto e metadati" do
    encrypted = described_class.encrypt(StringIO.new("private-key"), aad: "asset:v1")

    expect(encrypted.ciphertext).not_to include("private-key")
    expect(described_class.decrypt(encrypted, aad: "asset:v1")).to eq("private-key")
    expect { described_class.decrypt(encrypted, aad: "asset:v2") }
      .to raise_error(Secrets::Assets::Crypto::IntegrityError)
  end

  it "rifiuta una master key assente o non lunga 32 byte" do
    previous = ENV.delete("SECRET_ASSETS_MASTER_KEY")
    begin
      expect { described_class.encrypt(StringIO.new("x"), aad: "a") }
        .to raise_error(Secrets::Assets::Crypto::ConfigurationError)
    ensure
      ENV["SECRET_ASSETS_MASTER_KEY"] = previous
    end
  end

  it "rifiuta ciphertext manomesso" do
    encrypted = described_class.encrypt(StringIO.new("private-key"), aad: "asset:v1")
    tampered = encrypted.with(ciphertext: encrypted.ciphertext.dup.tap { |bytes| bytes.setbyte(0, bytes.getbyte(0) ^ 1) })
    expect { described_class.decrypt(tampered, aad: "asset:v1") }
      .to raise_error(Secrets::Assets::Crypto::IntegrityError)
  end
end
