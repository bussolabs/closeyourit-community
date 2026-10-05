# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::DeleteComment, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }

  it "elimina il commento di un'idea aperta e aggiorna il contatore" do
    comment = create(:idea_comment, idea:, organization:)

    result = described_class.call(comment:)

    expect(result).to be_ok
    expect(Ideas::Comment.exists?(comment.id)).to be(false)
    expect(idea.reload.comments_count).to eq(0)
  end

  it "idea congelata → R422-IDEA-002, il commento resta (fonte della sintesi AI)" do
    comment = create(:idea_comment, idea:, organization:)
    idea.update!(status: :archived)

    result = described_class.call(comment:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
    expect(Ideas::Comment.exists?(comment.id)).to be(true)
  end
end
