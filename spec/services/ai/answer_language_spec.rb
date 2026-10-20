# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::AnswerLanguage do
  let(:organization) { create(:organization) }

  after { Current.organization = nil }

  it "uses the organization's language when it chose one" do
    Organizations::AiSetting.find_or_create_by!(organization:).update!(answer_language: "en")
    Current.organization = organization.reload

    I18n.with_locale(:it) { expect(described_class.instruction).to include("in English") }
  end

  it "follows the interface language of whoever asks when the organization chose none" do
    Current.organization = organization

    I18n.with_locale(:it) { expect(described_class.instruction).to include("in Italian") }
    I18n.with_locale(:en) { expect(described_class.instruction).to include("in English") }
  end

  it "works outside an organization, on the interface language" do
    I18n.with_locale(:en) { expect(described_class.instruction).to include("in English") }
  end
end
