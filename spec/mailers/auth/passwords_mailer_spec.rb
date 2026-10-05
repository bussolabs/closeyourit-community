# frozen_string_literal: true

require "rails_helper"

RSpec.describe Auth::PasswordsMailer, type: :mailer do
  let(:account) { create(:account, email: "ada@example.com", name: "Ada") }

  it "reset compone l'email con destinatario, oggetto e link" do
    mail = described_class.reset(account)

    expect(mail.to).to eq([ "ada@example.com" ])
    expect(mail.subject).to be_present
    expect(mail.body.encoded).to include("/passwords/")
  end

  it "il link (già assoluto) resta con un solo host, senza raddoppi" do
    html = described_class.reset(account).html_part.decoded
    expect(html).to include("http://example.com/passwords/")
    expect(html).not_to include("example.comhttp")
  end

  it "è multipart (html + text)" do
    mail = described_class.reset(account)
    expect(mail.html_part).to be_present
    expect(mail.text_part).to be_present
  end

  it "l'HTML usa il frame condiviso (wordmark + CTA + footer)" do
    html = described_class.reset(account).html_part.decoded
    expect(html).to include("CloseYourIt")                          # wordmark header
    expect(html).to include(I18n.t("auth.passwords.mailer.action")) # CTA label
    expect(html).to include("bug tracking")                         # tagline del footer condiviso
  end

  describe "localizzazione nella lingua del destinatario (ApplicationMailer#mail)" do
    let(:subject_key) { "auth.passwords.mailer.subject" }

    it "le traduzioni it/en del soggetto differiscono (il test ha mordente)" do
      expect(I18n.t(subject_key, locale: :it)).not_to eq(I18n.t(subject_key, locale: :en))
    end

    it "rende il soggetto in italiano quando l'account ha locale 'it'" do
      account.update!(locale: "it")
      expect(described_class.reset(account).subject).to eq(I18n.t(subject_key, locale: :it))
    end

    it "rende il soggetto in inglese (default) quando l'account non ha preferenza" do
      account.update!(locale: nil)
      expect(described_class.reset(account).subject).to eq(I18n.t(subject_key, locale: :en))
    end

    it "il render nella lingua del destinatario non altera I18n.locale del processo" do
      account.update!(locale: "it")
      expect { described_class.reset(account).subject }.not_to change(I18n, :locale)
    end
  end
end
