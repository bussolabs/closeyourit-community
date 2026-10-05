require "rails_helper"

RSpec.describe Secrets::Github::Encryptor do
  describe ".call" do
    it "cifra il valore in un sealed box apribile con la private key corrispondente" do
      key = RbNaCl::PrivateKey.generate
      public_key_base64 = Base64.strict_encode64(key.public_key.to_bytes)

      result = described_class.call(public_key_base64:, value: "super-secret")

      expect(result).to be_ok
      ciphertext = Base64.decode64(result.value)
      opened = RbNaCl::Boxes::Sealed.from_private_key(key).open(ciphertext)
      expect(opened).to eq("super-secret")
    end

    it "produce ciphertext diversi per lo stesso valore (sealed box randomizzato)" do
      key = RbNaCl::PrivateKey.generate
      public_key_base64 = Base64.strict_encode64(key.public_key.to_bytes)

      a = described_class.call(public_key_base64:, value: "v").value
      b = described_class.call(public_key_base64:, value: "v").value
      expect(a).not_to eq(b)
    end
  end
end
