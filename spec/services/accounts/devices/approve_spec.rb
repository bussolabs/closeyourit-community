require "rails_helper"

RSpec.describe Accounts::Devices::Approve, type: :service do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  describe "#call" do
    it "approva la concessione registrando account e org scelta" do
      grant = create(:device_grant)

      result = described_class.call(grant:, account:, organization:)

      expect(result).to be_ok
      grant.reload
      expect(grant).to be_approved
      expect(grant.account).to eq(account)
      expect(grant.organization).to eq(organization)
      expect(grant.approved_at).to be_present
    end

    it "NON conia il token in approvazione (il segreto passa solo dal poll)" do
      grant = create(:device_grant)
      described_class.call(grant:, account:, organization:)
      expect(grant.reload.api_token).to be_nil
    end

    it "fallisce con R404 se l'account NON è membro dell'org scelta" do
      grant = create(:device_grant)
      other_org = create(:organization)

      result = described_class.call(grant:, account:, organization: other_org)

      expect(result).to be_err
      expect(result.error.code).to eq("R404-SYSTEM-001")
      expect(grant.reload).to be_pending
    end

    it "fallisce con R400-CLIAUTH-005 se la concessione è scaduta" do
      grant = create(:device_grant, expires_at: 1.minute.ago)

      result = described_class.call(grant:, account:, organization:)

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-005")
    end

    # CYRA-806 — la guardia legge uno snapshot: fra la lettura e la scrittura la concessione può
    # essere stata negata da un'altra richiesta, e un'approvazione cieca trasformerebbe il rifiuto
    # dell'umano in una credenziale.
    it "NON approva una concessione negata dopo la lettura della guardia" do
      grant = create(:device_grant)
      snapshot = Accounts::DeviceGrant.find(grant.id)
      Accounts::Devices::Deny.call(grant: Accounts::DeviceGrant.find(grant.id))

      result = described_class.call(grant: snapshot, account:, organization:)

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-005")
      expect(grant.reload).to be_denied
      expect(grant.account).to be_nil
    end

    it "fallisce con R400-CLIAUTH-005 se la concessione è già stata negata" do
      grant = create(:device_grant, :denied)

      result = described_class.call(grant:, account:, organization:)

      expect(result).to be_err
      expect(result.error.code).to eq("R400-CLIAUTH-005")
    end
  end
end
