require "rails_helper"

RSpec.describe Accounts::DeviceGrant, type: :model do
  describe "factory" do
    it "produce una concessione valida (pending)" do
      expect(build(:device_grant)).to be_valid
    end

    it "produce una concessione approvata valida" do
      expect(build(:device_grant, :approved)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede device_code_digest" do
      expect(build(:device_grant, device_code_digest: nil)).not_to be_valid
    end

    it "device_code_digest è unico" do
      existing = create(:device_grant)
      expect(build(:device_grant, device_code_digest: existing.device_code_digest)).not_to be_valid
    end

    it "richiede user_code" do
      expect(build(:device_grant, user_code: nil)).not_to be_valid
    end

    it "user_code è unico" do
      existing = create(:device_grant)
      expect(build(:device_grant, user_code: existing.user_code)).not_to be_valid
    end

    it "richiede expires_at" do
      expect(build(:device_grant, expires_at: nil)).not_to be_valid
    end
  end

  describe "status" do
    it "default è pending" do
      expect(build(:device_grant).status).to eq("pending")
    end

    it "espone gli stati del ciclo device-flow" do
      expect(described_class.statuses.keys)
        .to match_array(%w[pending approved denied fulfilled expired])
    end
  end

  describe "#approvable?" do
    it "true se pending e non scaduta" do
      expect(build(:device_grant, expires_at: 10.minutes.from_now).approvable?).to be(true)
    end

    it "false se già approvata" do
      expect(build(:device_grant, :approved).approvable?).to be(false)
    end

    it "false se negata" do
      expect(build(:device_grant, :denied).approvable?).to be(false)
    end

    it "false se scaduta" do
      expect(build(:device_grant, expires_at: 1.minute.ago).approvable?).to be(false)
    end

    it "al confine: approvabile 1s prima, non più 1s dopo la scadenza" do
      freeze_time do
        grant = create(:device_grant, expires_at: 1.second.from_now)
        expect(grant.approvable?).to be(true)

        travel 2.seconds
        expect(grant.approvable?).to be(false)
      end
    end
  end

  describe ".live" do
    it "include solo le concessioni pending non scadute" do
      live = create(:device_grant, expires_at: 10.minutes.from_now)
      approved = create(:device_grant, :approved)
      stale = create(:device_grant, expires_at: 1.minute.ago)

      expect(described_class.live).to include(live)
      expect(described_class.live).not_to include(approved, stale)
    end
  end
end
