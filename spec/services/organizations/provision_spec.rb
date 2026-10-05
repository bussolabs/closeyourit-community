# frozen_string_literal: true

require "rails_helper"

RSpec.describe Organizations::Provision, type: :service do
  it "crea organizzazione + owner nuovo + membership owner + default e invia il setup" do
    result = nil
    expect {
      result = described_class.call(name: "Acme Inc", owner_email: "owner@acme.test")
    }.to have_enqueued_mail(Auth::PasswordsMailer, :reset)

    expect(result).to be_ok
    organization = result.value
    expect(organization.slug).to eq("acme-inc")
    expect(organization.owner.email).to eq("owner@acme.test")
    expect(organization.owner.memberships.first).to be_owner
    expect(organization.ticket_statuses.count).to eq(5)
    expect(Alerting::Rule.find_by(organization: organization, event_type: :uptime_down)).to be_enabled
  end

  # CYRA-249: chiusa la registrazione self-service, questa è l'unica via che crea un'organizzazione.
  # I ruoli default li installava solo il signup: un'org provisionata dal pannello nasceva senza
  # Administrator/Maintainer/Triager/Viewer, e l'owner non aveva niente da assegnare agli invitati.
  it "installa anche i ruoli di default dell'organizzazione" do
    result = described_class.call(name: "Acme Inc", owner_email: "owner@acme.test")

    expect(result.value.roles.pluck(:name))
      .to match_array(Authorization::InstallDefaultRoles::DEFAULTS.keys)
  end

  it "riusa un account esistente come owner senza inviare il setup" do
    existing = create(:account, email: "owner@acme.test")
    result = nil
    expect {
      result = described_class.call(name: "Acme", owner_email: "owner@acme.test")
    }.not_to have_enqueued_mail(Auth::PasswordsMailer, :reset)

    expect(result).to be_ok
    expect(result.value.owner).to eq(existing)
  end

  it "ritorna Err se il nome manca" do
    result = described_class.call(name: "", owner_email: "x@acme.test")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-ORG-001")
  end

  it "genera slug unico su collisione" do
    create(:organization, slug: "acme")
    result = described_class.call(name: "Acme", owner_email: "o@acme.test")
    expect(result.value.slug).to eq("acme-2")
  end
end
