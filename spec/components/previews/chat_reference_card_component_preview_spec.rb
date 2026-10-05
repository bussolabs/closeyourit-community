# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatReferenceCardComponent, type: :component do
  describe "preview" do
    ChatReferenceCardComponentPreview.examples.each do |example|
      it "renderizza l'esempio '#{example}' senza errori" do
        expect { render_preview(example) }.not_to raise_error
      end
    end

    it "l'esempio 'unavailable' mostra il placeholder non disponibile (revoca live)" do
      render_preview(:unavailable)
      expect(page).to have_css("[data-test='chat-reference-unavailable']")
    end

    it "l'esempio 'ticket' mostra la card linkata" do
      render_preview(:ticket)
      expect(page).to have_css("[data-test='chat-reference-card']")
    end
  end
end
