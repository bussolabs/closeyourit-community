# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::InviteMember do
  let(:organization) { create(:organization) }
  let(:inviter) { create(:account) }

  it "crea l'invito e accoda l'email" do
    result = nil
    expect do
      result = described_class.call(organization: organization, email: "New@Example.com", role: "admin", invited_by: inviter)
    end.to have_enqueued_mail(Connections::InvitationsMailer, :invite)

    expect(result).to be_ok
    expect(result.value.email).to eq("new@example.com")
    expect(result.value.role).to eq("admin")
  end

  it "rifiuta il ruolo owner" do
    result = described_class.call(organization: organization, email: "x@example.com", role: "owner", invited_by: inviter)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-INVITE-003")
    expect(organization.invitations).to be_empty
  end

  it "rifiuta chi è già membro" do
    existing = create(:account, email: "member@example.com")
    create(:membership, account: existing, organization: organization, role: :member)

    result = described_class.call(organization: organization, email: "member@example.com", role: "member", invited_by: inviter)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-INVITE-004")
  end

  # Il caso reale: persona invitata, entrata, poi rimossa dall'organizzazione. L'invito accettato
  # restava e rendeva impossibile reinvitarla.
  it "riesce a reinvitare chi era già entrato ed è stato rimosso" do
    account = create(:account, email: "back@example.com")
    membership = create(:membership, account: account, organization: organization, role: :member)
    create(:invitation, organization: organization, email: account.email, accepted_at: Time.current)
    Connections::RemoveMember.call(membership: membership)

    result = described_class.call(organization: organization, email: "back@example.com", role: "member", invited_by: inviter)
    expect(result).to be_ok
    expect(result.value).not_to be_accepted
  end

  it "rifiuta un invito duplicato per la stessa email/org, dicendo che è in attesa" do
    described_class.call(organization: organization, email: "dup@example.com", role: "member", invited_by: inviter)
    result = described_class.call(organization: organization, email: "dup@example.com", role: "member", invited_by: inviter)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-INVITE-005")
    expect(result.error.message).to eq(I18n.t("member.errors.pending_invitation"))
  end
end
