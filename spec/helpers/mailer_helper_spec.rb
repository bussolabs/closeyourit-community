# frozen_string_literal: true

require "rails_helper"

RSpec.describe MailerHelper, type: :helper do
  describe "#mail_accent_key_for" do
    it "error_new / uptime_down → :red" do
      expect(helper.mail_accent_key_for("error_new")).to eq(:red)
      expect(helper.mail_accent_key_for("uptime_down")).to eq(:red)
    end

    it "error_regression → :amber" do
      expect(helper.mail_accent_key_for("error_regression")).to eq(:amber)
    end

    it "uptime_up → :green" do
      expect(helper.mail_accent_key_for("uptime_up")).to eq(:green)
    end

    it "tipo sconosciuto o nil → :indigo (default)" do
      expect(helper.mail_accent_key_for("ticket_created")).to eq(:indigo)
      expect(helper.mail_accent_key_for(nil)).to eq(:indigo)
    end
  end

  describe "#mail_accent_for / #mail_accent_soft_for" do
    it "mappano la chiave sul colore accent e sulla tinta soft" do
      expect(helper.mail_accent_for("error_new")).to eq(MailerHelper::ACCENTS[:red])
      expect(helper.mail_accent_soft_for("error_new")).to eq(MailerHelper::ACCENTS_SOFT[:red])
      expect(helper.mail_accent_for("qualsiasi")).to eq(MailerHelper::ACCENTS[:indigo])
    end
  end

  describe "#mail_absolute_url" do
    it "url nil o vuoto → stringa vuota (nessun link nudo all'host, la view testuale non ha guardia)" do
      expect(helper.mail_absolute_url(nil)).to eq("")
      expect(helper.mail_absolute_url("")).to eq("")
    end

    it "url già assoluto → invariato (idempotente, un solo host)" do
      expect(helper.mail_absolute_url("https://www.closeyour.it/member/tickets/1")).to eq("https://www.closeyour.it/member/tickets/1")
    end
  end

  describe "stili inline (stringhe CSS)" do
    it "ogni helper di stile ritorna una stringa CSS non vuota" do
      expect(helper.mail_overline_style).to include("font-family").and include("text-transform:uppercase")
      expect(helper.mail_h1_style).to include("font-size:21px")
      expect(helper.mail_h1_style(size: 30)).to include("font-size:30px")
      expect(helper.mail_p_style).to include("line-height:1.6")
      expect(helper.mail_note_style).to include("margin:24px 0 0 0")
      expect(helper.mail_footnote_style).to include("font-size:11.5px")
      expect(helper.mail_mono_style).to include(MailerHelper::MAIL_TEXT)
      expect(helper.mail_mono_style(color: "#000000")).to include("#000000")
    end
  end
end
