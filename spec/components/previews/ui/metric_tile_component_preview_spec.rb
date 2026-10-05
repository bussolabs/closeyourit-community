# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::MetricTileComponent, type: :component do
  describe "preview" do
    Ui::MetricTileComponentPreview.examples.each do |example|
      it "renderizza l'esempio '#{example}' senza errori" do
        expect { render_preview(example) }.not_to raise_error
      end
    end

    it "l'esempio 'clickable' rende un link cliccabile con aria-label" do
      render_preview(:clickable)
      expect(page).to have_css("a[data-test='kpi-errors'][aria-label]")
    end

    it "l'esempio 'with_tooltip' rende un contenitore statico col title nativo" do
      render_preview(:with_tooltip)
      expect(page).not_to have_css("a")
      expect(page).to have_css("div[title]")
    end
  end
end
