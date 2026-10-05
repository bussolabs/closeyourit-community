# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::AcceptInvitation, type: :service do
  let(:invitation) { create(:invitation, email: "new@example.com", role: :admin) }

  def accept(overrides = {})
    described_class.call(
      **{ invitation: invitation, name: "Bob", password: "Secret123!", password_confirmation: "Secret123!" }.merge(overrides)
    )
  end

  it "crea account + membership col ruolo e marca l'invito accettato (nuovo account)" do
    result = accept
    expect(result).to be_ok
    expect(result.value.new_account).to be(true)

    account = result.value.account
    expect(account.email).to eq("new@example.com")
    membership = account.memberships.first
    expect(membership.organization).to eq(invitation.organization)
    expect(membership).to be_admin
    expect(invitation.reload).to be_accepted
  end

  it "ritorna Err se la password è debole (nuovo account)" do
    result = accept(password: "debole", password_confirmation: "debole")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-INVITE-001")
  end

  it "ritorna Err se l'invito è già accettato" do
    invitation.update!(accepted_at: Time.current)
    result = accept
    expect(result).to be_err
    expect(result.error.code).to eq("R422-INVITE-002")
  end

  it "collega la membership a un account già esistente invece di crearne uno nuovo (CYRA-164)" do
    existing = create(:account, email: "new@example.com", name: "Original")
    invitation # forza la creazione dell'invito (e del suo invited_by) fuori dal blocco di misura
    result = nil
    expect { result = accept }.not_to change(Accounts::Account, :count)

    expect(result).to be_ok
    expect(result.value.new_account).to be(false)
    expect(result.value.account).to eq(existing)
    expect(existing.reload.name).to eq("Original") # i dati dell'invito non sovrascrivono l'account esistente
    membership = existing.memberships.find_by(organization: invitation.organization)
    expect(membership).to be_present
    expect(membership).to be_admin
    expect(invitation.reload).to be_accepted
  end

  it "è idempotente se l'account esistente è già membro dell'org (ruolo esistente preservato)" do
    existing = create(:account, email: "new@example.com")
    create(:membership, account: existing, organization: invitation.organization, role: :member)
    result = accept
    expect(result).to be_ok
    memberships = existing.memberships.where(organization: invitation.organization)
    expect(memberships.count).to eq(1)
    expect(memberships.first).to be_member
  end

  it "non crea account se la transazione fallisce (rollback su password invalida)" do
    invitation # forza la creazione (e del suo invited_by) fuori dal blocco di misura
    expect { accept(password: "debole", password_confirmation: "debole") }.not_to change(Accounts::Account, :count)
  end
end
