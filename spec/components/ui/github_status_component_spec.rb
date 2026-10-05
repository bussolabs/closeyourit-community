# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::GithubStatusComponent, type: :component do
  it "mostra lo stato collegato con icona attiva e check" do
    render_inline(described_class.new(connected: true, test_id: "github-status"))

    expect(page).to have_css("[data-test='github-status'][aria-label='GitHub connected'].text-zinc-900")
    expect(page).to have_css("svg[data-icon='github']")
    expect(page).to have_css("svg[data-icon='circle-check'].text-emerald-600")
  end

  it "mostra lo stato assente in grigio e con il simbolo meno" do
    render_inline(described_class.new(connected: false, test_id: "github-status"))

    expect(page).to have_css("[data-test='github-status'][aria-label='GitHub not connected'].text-gray-300")
    expect(page).to have_css("svg[data-icon='github']")
    expect(page).to have_css("svg[data-icon='circle-minus'].text-gray-400")
  end

  it "supporta le due dimensioni previste" do
    render_inline(described_class.new(connected: true, size: :lg))

    expect(page).to have_css("svg[data-icon='github'][class~='text-[16px]']")
    expect(page).to have_css("svg[data-icon='circle-check'][class~='text-[8px]']")
  end

  it "rifiuta dimensioni sconosciute" do
    expect { described_class.new(connected: true, size: :xl) }
      .to raise_error(ArgumentError, "size sconosciuta: xl")
  end
end
