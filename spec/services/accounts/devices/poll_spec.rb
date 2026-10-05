require "rails_helper"

RSpec.describe Accounts::Devices::Poll, type: :service do
  def digest(code) = Digest::SHA256.hexdigest(code)

  describe "#call" do
    it "device_code sconosciuto → invalid_grant (R401)" do
      result = described_class.call(device_code: "inesistente")

      expect(result).to be_err
      expect(result.error.code).to eq("R401-CLIAUTH-001")
      expect(result.error.status).to eq(:unauthorized)
      expect(result.error.details[:oauth_error]).to eq("invalid_grant")
    end

    it "pending → authorization_pending (R400-CLIAUTH-002)" do
      create(:device_grant, device_code_digest: digest("dc-pending"))

      result = described_class.call(device_code: "dc-pending")

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-002")
      expect(result.error.details[:oauth_error]).to eq("authorization_pending")
    end

    it "poll troppo frequente → slow_down (R400-CLIAUTH-003) e alza l'interval" do
      grant = create(:device_grant, device_code_digest: digest("dc-fast"),
                                    last_polled_at: Time.current, interval: 5)

      result = described_class.call(device_code: "dc-fast")

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-003")
      expect(result.error.details[:oauth_error]).to eq("slow_down")
      expect(grant.reload.interval).to eq(10)
    end

    it "negato → access_denied (R400-CLIAUTH-005)" do
      create(:device_grant, :denied, device_code_digest: digest("dc-denied"))

      result = described_class.call(device_code: "dc-denied")

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-005")
      expect(result.error.details[:oauth_error]).to eq("access_denied")
    end

    it "scaduto → expired_token e marca la concessione expired" do
      grant = create(:device_grant, device_code_digest: digest("dc-exp"), expires_at: 1.minute.ago)

      result = described_class.call(device_code: "dc-exp")

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-005")
      expect(result.error.details[:oauth_error]).to eq("expired_token")
      expect(grant.reload).to be_expired
    end

    it "approvato → conia il token, consegna il segreto una volta, marca fulfilled" do
      grant = create(:device_grant, :approved, device_code_digest: digest("dc-ok"))

      result = described_class.call(device_code: "dc-ok")

      expect(result).to be_ok
      access_token = result.value[:access_token]
      token = result.value[:token]
      expect(access_token).to start_with("cyi_u_")
      expect(token.token_digest).to eq(Digest::SHA256.hexdigest(access_token))
      expect(token.account).to eq(grant.account)
      expect(token.organization).to eq(grant.organization)

      grant.reload
      expect(grant).to be_fulfilled
      expect(grant.api_token).to eq(token)
    end

    it "già consumato (fulfilled) → access_denied (single-use)" do
      create(:device_grant, :approved, status: :fulfilled,
                                       device_code_digest: digest("dc-used"), last_polled_at: 1.hour.ago)

      result = described_class.call(device_code: "dc-used")

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-005")
      expect(result.error.details[:oauth_error]).to eq("access_denied")
    end

    it "approvato ma l'emissione del token fallisce → propaga l'errore (mint)" do
      create(:device_grant, :approved, device_code_digest: digest("dc-mint"), last_polled_at: 1.hour.ago)
      allow(Accounts::ApiTokens::Issue).to receive(:call).and_return(
        Result.err(AppError.new("emissione fallita", code: "R422-APITOKEN-001", status: :unprocessable_content))
      )

      result = described_class.call(device_code: "dc-mint")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-APITOKEN-001")
    end

    # CYRA-806 — consumo ed emissione sono un atto solo. Qui la concessione viene consumata da
    # un'altra richiesta un istante prima che questa apra la propria transazione: il token viene
    # coniato, ma la conferma non trova più nulla da consumare e se lo porta via col rollback.
    it "concessione consumata mentre si conia → access_denied e NESSUNA seconda credenziale" do
      grant = create(:device_grant, :approved, device_code_digest: digest("dc-corsa"),
                                               last_polled_at: 1.hour.ago)
      allow_any_instance_of(described_class).to receive(:mint).and_wrap_original do |original, snapshot|
        Accounts::DeviceGrant.find(grant.id).update!(status: :fulfilled)
        original.call(snapshot)
      end

      result = described_class.call(device_code: "dc-corsa")

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-005")
      expect(result.error.details[:oauth_error]).to eq("access_denied")
      expect(Accounts::ApiToken.count).to eq(0)
      expect(grant.reload.api_token).to be_nil
    end

    it "conferma della concessione fallita dopo l'emissione → il token non sopravvive" do
      create(:device_grant, :approved, device_code_digest: digest("dc-boom"), last_polled_at: 1.hour.ago)
      allow_any_instance_of(described_class).to receive(:consume)
        .and_raise(ActiveRecord::StatementInvalid, "conferma fallita")

      expect { described_class.call(device_code: "dc-boom") }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect(Accounts::ApiToken.count).to eq(0)
    end

    it "grant già in stato expired → expired_token senza ri-transizione (guard unless expired?)" do
      create(:device_grant, :expired, device_code_digest: digest("dc-exp"))

      result = described_class.call(device_code: "dc-exp")

      expect(result).to be_err
      expect(result.error.details[:oauth_error]).to eq("expired_token")
    end
  end
end
