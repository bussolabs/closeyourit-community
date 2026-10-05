# frozen_string_literal: true

require "rails_helper"

RSpec.describe CommentSerializer do
  it "espone il nome dell'autore" do
    comment = create(:ticket_comment)
    json = JSON.parse(described_class.new(comment).serialize)

    expect(json["id"]).to eq(comment.id)
    expect(json["ticket_id"]).to eq(comment.ticket_id)
    expect(json["author"]).to eq(comment.author.name)
  end

  it "autore rimosso (author nil) → author = nil (nil-safe)" do
    comment = create(:ticket_comment)
    allow(comment).to receive(:author).and_return(nil)

    json = JSON.parse(described_class.new(comment).serialize)

    expect(json["author"]).to be_nil
  end
end
