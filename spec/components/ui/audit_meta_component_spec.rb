# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::AuditMetaComponent, type: :component do
  let(:created) { Time.zone.local(2026, 3, 12, 14, 32) }
  let(:updated) { Time.zone.local(2026, 3, 20, 9, 50) }

  it "rende la data e l'autore di creazione" do
    render_inline(described_class.new(created_at: created, created_by: "Marco Rossi"))

    within("[data-test='audit-created']") do
      expect(page).to have_text("12/03/2026")
      expect(page).to have_text("Marco Rossi")
    end
  end

  it "rende la data e l'autore dell'ultimo aggiornamento" do
    render_inline(described_class.new(created_at: created, created_by: "Marco Rossi",
                                      updated_at: updated, updated_by: "Olivia Lane"))

    within("[data-test='audit-updated']") do
      expect(page).to have_text("20/03/2026")
      expect(page).to have_text("Olivia Lane")
    end
  end

  it "rende le iniziali dell'autore nell'avatar" do
    render_inline(described_class.new(created_at: created, created_by: "Marco Rossi",
                                      updated_at: updated, updated_by: "Olivia Lane"))

    expect(page).to have_css("[data-test='audit-created']", text: "MR")
    expect(page).to have_css("[data-test='audit-updated']", text: "OL")
  end

  it "omette l'autore quando created_by è nil (entità di sistema)" do
    render_inline(described_class.new(created_at: created))

    expect(page).to have_css("[data-test='audit-created']", text: "12/03/2026")
    expect(page).not_to have_css("[data-test='audit-created'] [data-test='audit-author']")
  end

  it "omette il blocco Updated quando updated_at è nil" do
    render_inline(described_class.new(created_at: created, created_by: "Marco Rossi"))

    expect(page).to have_css("[data-test='audit-created']")
    expect(page).not_to have_css("[data-test='audit-updated']")
  end

  it "formatta la data in stile europeo con ora (gg/mm/aaaa · HH:MM)" do
    render_inline(described_class.new(created_at: created))

    expect(page).to have_text("12/03/2026 · 14:32")
  end

  it "is one strip: every piece on the same 20px line, the action at the far end" do
    render_inline(described_class.new(created_at: created, created_by: "Marco Rossi", updated_at: updated, test_id: "audit")) do |c|
      c.with_action { "History" }
    end

    expect(page).to have_css("[data-test='audit'].flex.flex-wrap.items-center[aria-label='Audit']")
    expect(page).to have_no_css("[data-test='audit'] > p")
    %w[audit-label audit-date audit-author].each do |piece|
      expect(page).to have_css("[data-test='audit-created'] [data-test='#{piece}'].h-5.leading-none")
    end
    expect(page).to have_css("[data-test='audit-action'].ml-auto", text: "History")
  end

  it "applica il test_id e le classi del caller sul nodo radice" do
    render_inline(described_class.new(created_at: created, test_id: "ticket-audit", class: "pt-3 border-t"))

    expect(page).to have_css("div.pt-3.border-t[data-test='ticket-audit']")
  end

  it "rende lo slot action (es. link cronologia) quando fornito" do
    render_inline(described_class.new(created_at: created)) do |c|
      c.with_action { "<a href='/x' data-test='audit-history'>View activity history</a>".html_safe }
    end

    expect(page).to have_css("[data-test='audit-history']", text: "View activity history")
  end

  it "non rende l'area action quando lo slot non è fornito" do
    render_inline(described_class.new(created_at: created))

    expect(page).not_to have_css("[data-test='audit-action']")
  end
  # CYRA-406 — un'automazione non si mostra con le iniziali dentro un cerchio, che è il segno delle
  # persone: stesso posto, icona diversa.
  it "l'autore macchina porta l'icona, non le iniziali" do
    render_inline(described_class.new(created_at: Time.current, created_by: "GitHub", created_by_machine: true))

    expect(page).to have_css('[data-test="audit-author-machine"] svg[data-icon="bot"]')
    expect(page.find('[data-test="audit-author"]').text).to include("GitHub")
    expect(page.find('[data-test="audit-author"]').text).not_to include("GI")
  end

  it "l'autore persona resta con le iniziali" do
    render_inline(described_class.new(created_at: Time.current, created_by: "Alessio Bussolari"))

    expect(page).not_to have_css('[data-test="audit-author-machine"]')
    expect(page.find('[data-test="audit-author"]').text).to include("AB")
  end

  # The mono face draws its digits 0.7px above the sans name in the same box (measured 2026-10-05).
  it "nudges the mono date down so it lines up with the author's name" do
    render_inline(described_class.new(created_at: Time.zone.local(2026, 10, 5, 10, 41), created_by: "Ada Byron"))

    expect(page.find('[data-test="audit-date"]')[:class]).to include("translate-y-[0.5px]")
  end
end
