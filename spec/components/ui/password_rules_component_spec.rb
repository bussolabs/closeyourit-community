# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::PasswordRulesComponent, type: :component do
  it "rende le 5 regole con i target Stimulus" do
    render_inline(described_class.new)
    expect(page).to have_css("li[data-ui--password-rules-target='rule']", count: 5)
    expect(page).to have_css("li[data-rule='length']")
    expect(page).to have_css("li[data-rule='special']")
  end

  it "espone il data-test" do
    render_inline(described_class.new(test_id: "pw-rules"))
    expect(page).to have_css("ul[data-test='pw-rules']")
  end

  it "la lista è una live region (annuncia i cambi di stato agli screen reader)" do
    render_inline(described_class.new)
    expect(page).to have_css("ul[aria-live='polite']")
  end

  it "ogni regola porta uno span sr-only con lo stato testuale iniziale (da soddisfare)" do
    render_inline(described_class.new)
    expect(page).to have_css("li[data-rule='length'] span.sr-only", text: I18n.t("auth.password_rules.status.unmet"))
    expect(page.all("span.sr-only").size).to eq(5)
  end

  it "ogni regola porta le stringhe tradotte met/unmet per il controller Stimulus" do
    render_inline(described_class.new)
    li = page.find("li[data-rule='length']")
    expect(li["data-met-text"]).to eq(I18n.t("auth.password_rules.status.met"))
    expect(li["data-unmet-text"]).to eq(I18n.t("auth.password_rules.status.unmet"))
  end
end
