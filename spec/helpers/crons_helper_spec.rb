# frozen_string_literal: true

require "rails_helper"

RSpec.describe CronsHelper, type: :helper do
  describe "#cron_status_color" do
    it "ogni stato ha un colore della palette del badge, non il grigio di ripiego" do
      Crons::Monitor.statuses.each_key do |status|
        expect(Ui::BadgeComponent::COLORS).to have_key(helper.cron_status_color(status).to_sym)
      end
      expect(helper.cron_status_color(:missed)).to eq("red")
    end
  end

  describe "#cron_interval_label" do
    around { |example| I18n.with_locale(:it) { example.run } }

    it "usa l'unità più grande che divide la cadenza" do
      expect(helper.cron_interval_label(2)).to eq("ogni 2 min")
      expect(helper.cron_interval_label(90)).to eq("ogni 90 min")
      expect(helper.cron_interval_label(60)).to eq("ogni ora")
      expect(helper.cron_interval_label(360)).to eq("ogni 6 ore")
      expect(helper.cron_interval_label(1_440)).to eq("ogni giorno")
      expect(helper.cron_interval_label(10_080)).to eq("ogni 7 giorni")
    end
  end
end
