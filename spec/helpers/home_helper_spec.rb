# frozen_string_literal: true

require "rails_helper"

RSpec.describe HomeHelper, type: :helper do
  # CYRA-324 — «4 days fa» non era né italiano né inglese, e a qualche giorno di distanza la forma
  # relativa costringe comunque a fare il conto.
  describe "#card_time" do
    it "sotto la soglia resta relativo, e in italiano" do
      I18n.with_locale(:it) do
        expect(helper.card_time(3.hours.ago)).to eq("circa 3 ore fa")
        expect(helper.card_time(2.days.ago)).to eq("2 giorni fa")
      end
    end

    it "oltre la soglia passa alla data breve col giorno della settimana" do
      time = Time.zone.local(2026, 8, 6, 9, 30)

      I18n.with_locale(:it) do
        expect(helper.card_time(time, now: Time.zone.local(2026, 8, 11, 9, 30))).to eq("gio 6 ago")
      end
    end

    it "non stampa niente senza una data" do
      expect(helper.card_time(nil)).to be_nil
    end

    it "in inglese resta inglese" do
      I18n.with_locale(:en) do
        expect(helper.card_time(3.hours.ago)).to eq("about 3 hours ago")
        expect(helper.card_time(Time.zone.local(2026, 8, 6), now: Time.zone.local(2026, 8, 11))).to eq("Thu 6 Aug")
      end
    end
  end

  # CYRA-326 — la frase che apre la Home: le tre forme che può prendere, comprese quelle limite.

  # CYRA-884 — same labels as the approvals filters, at most three states, the rest summed.
  describe "#queue_breakdown" do
    it "keeps chip order, shows at most three states and sums the rest" do
      totals = { "review" => 18, "awaiting_approval" => 3, "clarification" => 3, "secret_change" => 1, "waiting" => 2 }

      shown, rest = helper.queue_breakdown(totals)

      expect(shown.map(&:first)).to eq([ I18n.t("member.approvals.filters.awaiting_approval"),
                                         I18n.t("member.approvals.filters.review"),
                                         I18n.t("member.approvals.filters.clarification") ])
      expect(shown.map(&:last)).to eq([ 3, 18, 3 ])
      expect(rest).to eq(3)
    end

    it "skips states with no decisions" do
      shown, rest = helper.queue_breakdown({ "review" => 2 })

      expect(shown).to eq([ [ I18n.t("member.approvals.filters.review"), 2 ] ])
      expect(rest).to eq(0)
    end
  end
end
