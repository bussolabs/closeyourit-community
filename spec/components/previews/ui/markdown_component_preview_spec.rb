# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::MarkdownComponent, type: :component do
  describe "preview" do
    Ui::MarkdownComponentPreview.examples.each do |example|
      it "renderizza l'esempio '#{example}' senza errori" do
        expect { render_preview(example) }.not_to raise_error
      end
    end
  end
end
