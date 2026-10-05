# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::DeleteCase, type: :service do
  let(:idea) { create(:idea) }
  let!(:case_record) { create(:idea_case, idea:) }

  it "elimina il case da un'idea aperta" do
    expect { described_class.call(case_record:) }.to change(Ideas::Case, :count).by(-1)
  end

  it "idea congelata → R422-IDEA-002, il case resta" do
    idea.update!(status: :archived)

    result = described_class.call(case_record:)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
    expect(Ideas::Case.exists?(case_record.id)).to be(true)
  end
end
