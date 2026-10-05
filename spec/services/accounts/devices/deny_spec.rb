require "rails_helper"

RSpec.describe Accounts::Devices::Deny, type: :service do
  describe "#call" do
    it "marca la concessione come denied" do
      grant = create(:device_grant)
      result = described_class.call(grant:)

      expect(result).to be_ok
      expect(grant.reload).to be_denied
    end

    it "è no-op se la concessione non è più pending" do
      grant = create(:device_grant, :approved)
      described_class.call(grant:)
      expect(grant.reload).to be_approved
    end

    # CYRA-806 — anche qui la guardia legge uno snapshot: una concessione già consumata non torna
    # indietro a "negata" solo perché chi chiama l'aveva letta quando era ancora in attesa.
    it "è no-op anche se la concessione è stata consumata dopo la lettura" do
      grant = create(:device_grant)
      snapshot = Accounts::DeviceGrant.find(grant.id)
      Accounts::DeviceGrant.find(grant.id).update!(status: :fulfilled)

      result = described_class.call(grant: snapshot)

      expect(result).to be_ok
      expect(grant.reload).to be_fulfilled
    end
  end
end
