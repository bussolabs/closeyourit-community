require "rails_helper"

RSpec.describe Connections::Membership, type: :model do
  describe "factory" do
    it "produce una membership valida" do
      expect(build(:membership)).to be_valid
    end
  end

  describe "associazioni" do
    it "appartiene a un account" do
      account = create(:account)
      expect(create(:membership, account: account).account).to eq(account)
    end

    it "appartiene a un'organizzazione" do
      org = create(:organization)
      expect(create(:membership, organization: org).organization).to eq(org)
    end

    it "richiede un account" do
      expect(build(:membership, account: nil)).not_to be_valid
    end

    it "richiede un'organizzazione" do
      expect(build(:membership, organization: nil)).not_to be_valid
    end
  end

  describe "ruolo (enum)" do
    it "ha default member" do
      expect(build(:membership).role).to eq("member")
    end

    it "espone i valori member/admin/owner/customer" do
      expect(described_class.roles.keys).to contain_exactly("member", "admin", "owner", "customer")
    end

    it "permette la transizione a owner" do
      membership = create(:membership)
      membership.owner!
      expect(membership.reload).to be_owner
    end

    it "solleva ArgumentError su un ruolo non valido" do
      expect { build(:membership, role: :superadmin) }.to raise_error(ArgumentError)
    end
  end

  describe "unicità account + organization" do
    it "impedisce due membership per la stessa coppia" do
      account = create(:account)
      org = create(:organization)
      create(:membership, account: account, organization: org)
      expect(build(:membership, account: account, organization: org)).not_to be_valid
    end

    it "permette lo stesso account in organizzazioni diverse" do
      account = create(:account)
      create(:membership, account: account, organization: create(:organization))
      expect(build(:membership, account: account, organization: create(:organization))).to be_valid
    end
  end

  describe "owner unico per organizzazione" do
    it "impedisce due owner nella stessa organizzazione" do
      org = create(:organization)
      create(:membership, organization: org, account: create(:account), role: :owner)
      second = build(:membership, organization: org, account: create(:account), role: :owner)
      expect(second).not_to be_valid
    end

    it "permette il ruolo owner in organizzazioni diverse" do
      account = create(:account)
      create(:membership, organization: create(:organization), account: account, role: :owner)
      other = build(:membership, organization: create(:organization), account: account, role: :owner)
      expect(other).to be_valid
    end

    it "non limita il numero di admin nella stessa organizzazione" do
      org = create(:organization)
      create(:membership, organization: org, account: create(:account), role: :admin)
      second = build(:membership, organization: org, account: create(:account), role: :admin)
      expect(second).to be_valid
    end

    it "non valida l'unicità owner senza organizzazione" do
      membership = build(:membership, organization: nil, role: :owner)
      membership.valid?
      expect(membership.errors[:role]).to be_empty
    end
  end

  describe "#secret_environment_allowed? (restrizione env dei secret)" do
    it "senza restrizione (lista vuota) consente qualsiasi environment" do
      membership = build(:membership, secret_environment_codes: [])
      expect(membership.secret_environment_allowed?("production")).to be(true)
    end

    it "con restrizione consente solo i code elencati" do
      membership = build(:membership, secret_environment_codes: [ "staging" ])
      expect(membership.secret_environment_allowed?("staging")).to be(true)
      expect(membership.secret_environment_allowed?("production")).to be(false)
    end

    it "normalizza i code (strip/downcase/uniq)" do
      membership = build(:membership, secret_environment_codes: [ " Staging ", "staging", "" ])
      expect(membership.secret_environment_codes).to eq([ "staging" ])
    end
  end
end
