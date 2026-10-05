require "rails_helper"

RSpec.describe Accounts::Devices::Start, type: :service do
  describe "#call" do
    it "crea una concessione pending e ritorna il device_code (digest in DB)" do
      result = described_class.call(client_name: "closeyourit-cli/1.0")

      expect(result).to be_ok
      grant = result.value[:grant]
      device_code = result.value[:device_code]
      expect(grant).to be_pending
      expect(grant.device_code_digest).to eq(Digest::SHA256.hexdigest(device_code))
      expect(grant.client_name).to eq("closeyourit-cli/1.0")
    end

    it "genera un user_code nel formato XXXX-XXXX dall'alfabeto sicuro" do
      grant = described_class.call.value[:grant]
      expect(grant.user_code).to match(/\A[BCDFGHJKLMNPQRSTVWXZ23456789]{4}-[BCDFGHJKLMNPQRSTVWXZ23456789]{4}\z/)
    end

    it "imposta interval e scadenza dai constants" do
      freeze_time do
        grant = described_class.call.value[:grant]
        expect(grant.interval).to eq(Accounts::Constants::DEVICE_POLL_INTERVAL)
        expect(grant.expires_at).to be_within(1.second).of(Accounts::Constants::TTL_DEVICE_GRANT.from_now)
      end
    end

    it "genera user_code univoci su più chiamate" do
      codes = Array.new(5) { described_class.call.value[:grant].user_code }
      expect(codes.uniq.size).to eq(5)
    end

    it "user_code in collisione → ritenta finché ne trova uno libero (loop)" do
      # Prima verifica: collisione (else del `unless exists?`); seconda: libero → return.
      allow(Accounts::DeviceGrant).to receive(:exists?).and_return(true, false)

      expect(described_class.call).to be_ok
    end
  end
end
