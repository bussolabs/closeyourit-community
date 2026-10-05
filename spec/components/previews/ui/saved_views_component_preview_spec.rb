# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SavedViewsComponent, type: :component do
  describe "preview" do
    Ui::SavedViewsComponentPreview.examples.each do |example|
      it "renderizza l'esempio '#{example}' senza errori" do
        expect { render_preview(example) }.not_to raise_error
      end
    end

    it "l'esempio 'with_views' elenca le viste salvate" do
      render_preview(:with_views)
      expect(page).to have_css("[data-ui--saved-views-target='option']", count: 2)
    end

    it "l'esempio 'empty' mostra lo stato senza viste salvate" do
      render_preview(:empty)
      expect(page).to have_css("[data-test='saved-views-empty']")
    end
  end
end
