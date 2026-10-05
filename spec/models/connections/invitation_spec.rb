# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::Invitation, type: :model do
  it "produce un invito valido" do
    expect(build(:invitation)).to be_valid
  end

  it "appartiene a organizzazione e a chi invita" do
    invitation = create(:invitation)
    expect(invitation.organization).to be_a(Organizations::Organization)
    expect(invitation.invited_by).to be_a(Accounts::Account)
  end

  it "normalizza l'email" do
    invitation = create(:invitation, email: "  Up@Example.COM ")
    expect(invitation.email).to eq("up@example.com")
  end

  it "impedisce due inviti in attesa con stessa email nella stessa organizzazione" do
    invitation = create(:invitation)
    dup = build(:invitation, organization: invitation.organization, email: invitation.email)
    expect(dup).not_to be_valid
  end

  # Il caso che bloccava il reinvito: l'invito accettato resta in tabella per sempre (RevokeOrgAccess
  # storicamente non lo toccava) e teneva occupata l'email dell'organizzazione a vita.
  it "ammette un nuovo invito quando il precedente è già stato accettato" do
    accepted = create(:invitation, accepted_at: Time.current)
    fresh = build(:invitation, organization: accepted.organization, email: accepted.email)
    expect(fresh).to be_valid
    expect { fresh.save! }.not_to raise_error
  end

  it "lascia accettare un invito quando un altro con la stessa email è in attesa" do
    first = create(:invitation)
    create(:invitation, organization: first.organization, email: first.email, accepted_at: Time.current)
    expect { first.update!(accepted_at: Time.current) }.not_to raise_error
  end

  it "ammette la stessa email in organizzazioni diverse" do
    invitation = create(:invitation)
    other = build(:invitation, email: invitation.email)
    expect(other).to be_valid
  end

  it "ritrova l'invito da un token valido" do
    invitation = create(:invitation)
    token = invitation.generate_token_for(:invitation)
    expect(Connections::Invitation.find_by_token_for(:invitation, token)).to eq(invitation)
  end

  it "ritorna nil su token scaduto" do
    invitation = create(:invitation)
    token = invitation.generate_token_for(:invitation)
    travel_to(Connections::Constants::TTL_INVITATION.from_now + 1.second) do
      expect(Connections::Invitation.find_by_token_for(:invitation, token)).to be_nil
    end
  end

  it "accepted? riflette accepted_at" do
    expect(build(:invitation, accepted_at: nil)).not_to be_accepted
    expect(build(:invitation, accepted_at: Time.current)).to be_accepted
  end
end
