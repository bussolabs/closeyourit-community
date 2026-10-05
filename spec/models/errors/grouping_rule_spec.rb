# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::GroupingRule, type: :model do
  describe "factory" do
    it "produce una regola valida" do
      expect(build(:error_grouping_rule)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede value" do
      expect(build(:error_grouping_rule, value: nil)).not_to be_valid
    end

    it "richiede fingerprint_key" do
      expect(build(:error_grouping_rule, fingerprint_key: nil)).not_to be_valid
    end
  end

  describe "#matches?" do
    def rule(**attrs) = build(:error_grouping_rule, **attrs)

    it "contains è case-insensitive" do
      r = rule(field: :exception_type, operator: :contains, value: "timeout")
      expect(r.matches?(exception_type: "ConnectionTimeoutError")).to be(true)
      expect(r.matches?(exception_type: "RuntimeError")).to be(false)
    end

    it "equals confronta l'intero valore (case-insensitive)" do
      r = rule(field: :exception_type, operator: :equals, value: "PaymentError")
      expect(r.matches?(exception_type: "paymenterror")).to be(true)
      expect(r.matches?(exception_type: "PaymentErrors")).to be(false)
    end

    it "starts_with guarda l'inizio" do
      r = rule(field: :culprit, operator: :starts_with, value: "App::Payments")
      expect(r.matches?(culprit: "App::Payments::Charge#call")).to be(true)
      expect(r.matches?(culprit: "App::Users#show")).to be(false)
    end

    it "è falso se il campo osservato è assente" do
      r = rule(field: :message, operator: :contains, value: "x")
      expect(r.matches?(message: nil)).to be(false)
    end
  end

  describe "#target_fingerprint" do
    it "è deterministico e uguale a parità di fingerprint_key" do
      a = build(:error_grouping_rule, fingerprint_key: "same")
      b = build(:error_grouping_rule, fingerprint_key: "same")
      expect(a.target_fingerprint).to eq(b.target_fingerprint)
    end

    it "differisce per fingerprint_key diversi" do
      a = build(:error_grouping_rule, fingerprint_key: "one")
      b = build(:error_grouping_rule, fingerprint_key: "two")
      expect(a.target_fingerprint).not_to eq(b.target_fingerprint)
    end
  end
end
