# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::InvitationsMailer, type: :mailer do
  let(:org) { create(:organization, name: "Acme") }
  let(:invitation) { org.invitations.create!(email: "new@example.com", role: :member) }

  it "invite compone l'email con destinatario, oggetto e link di accettazione" do
    mail = described_class.invite(invitation)

    expect(mail.to).to eq([ "new@example.com" ])
    expect(mail.subject).to include("Acme")
    expect(mail.body.encoded).to include("/invitations/")
  end

  it "il link (già assoluto) resta con un solo host, senza raddoppi" do
    html = described_class.invite(invitation).html_part.decoded
    expect(html).to include("http://example.com/invitations/")
    expect(html).not_to include("example.comhttp")
  end

  it "è multipart (html + text)" do
    mail = described_class.invite(invitation)
    expect(mail.html_part).to be_present
    expect(mail.text_part).to be_present
  end

  it "l'HTML usa il frame condiviso e mostra org + ruolo nel meta box" do
    html = described_class.invite(invitation).html_part.decoded
    expect(html).to include("CloseYourIt")                                     # wordmark
    expect(html).to include("Acme")                                            # org nel meta box
    expect(html).to include(I18n.t("connections.invitations.mailer.action"))   # CTA
    expect(html).to include("bug tracking")                                    # tagline del footer condiviso
  end
end
