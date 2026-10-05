require "rails_helper"

RSpec.describe Accounts::ApiTokens::Issue, type: :service do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  describe "#call" do
    it "emette un token con segreto cyi_u_ e digest corrispondente" do
      result = described_class.call(account:, organization:, name: "MacBook")

      expect(result).to be_ok
      token = result.value[:token]
      secret = result.value[:secret]
      expect(secret).to start_with("cyi_u_")
      expect(token.token_digest).to eq(Digest::SHA256.hexdigest(secret))
      expect(token.token_prefix).to eq(secret[0, 14])
      expect(token.account).to eq(account)
      expect(token.organization).to eq(organization)
    end

    it "non persiste il segreto in chiaro" do
      result = described_class.call(account:, organization:, name: "MacBook")
      token = result.value[:token].reload
      expect(token.attributes.values.map(&:to_s)).not_to include(result.value[:secret])
    end

    it "accetta una scadenza esplicita" do
      result = described_class.call(account:, organization:, name: "CI", expires_at: 1.day.from_now)
      expect(result.value[:token].expires_at).to be_present
    end

    # CYRA-717 — un token personale non deve valere per sempre: chi non chiede niente ha 90 giorni.
    describe "scadenza di default" do
      it "senza expires_at scade dopo la durata di default" do
        freeze_time do
          result = described_class.call(account:, organization:, name: "MacBook")

          expect(result.value[:token].expires_at)
            .to be_within(1.second).of(described_class::DEFAULT_LIFETIME.from_now)
        end
      end

      it "la durata di default è di novanta giorni" do
        expect(described_class::DEFAULT_LIFETIME).to eq(90.days)
      end
    end

    describe "token senza scadenza (expires_at: nil esplicito)" do
      it "un account di SERVIZIO può averlo" do
        service = create(:account, :service)
        create(:membership, account: service, organization:)

        result = described_class.call(account: service, organization:, name: "ci-deploy", expires_at: nil)

        expect(result).to be_ok
        expect(result.value[:token].expires_at).to be_nil
      end

      it "un account UMANO no: R422-CLIAUTH-002 e nessun token creato" do
        expect {
          @result = described_class.call(account:, organization:, name: "eterno", expires_at: nil)
        }.not_to change(Accounts::ApiToken, :count)

        expect(@result).to be_err
        expect(@result.error.code).to eq("R422-CLIAUTH-002")
      end
    end

    it "fallisce con R422-CLIAUTH-001 se il nome è vuoto" do
      result = described_class.call(account:, organization:, name: "")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-CLIAUTH-001")
    end

    it "fallisce se l'account NON è membro dell'organizzazione" do
      other_org = create(:organization)
      result = described_class.call(account:, organization: other_org, name: "MacBook")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-CLIAUTH-001")
    end
  end
end
