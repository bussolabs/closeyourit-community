# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ChangelogComponent, type: :component do
  def release(version)
    Changelog::Release.new(
      version: version, date: "2026-07-01",
      sections: [ { label: "Added", items: [ "Voce." ] } ]
    )
  end

  it "mostra la versione corrente nel trigger in monospace" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_css("[data-test='footer-version']", text: "v0.0.52")
    expect(page).to have_css("[data-test='footer-version'] .font-mono", text: "v0.0.52")
  end

  it "does not show a caret on the trigger, since it opens a dialog rather than a menu" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_no_css("[data-test='footer-version'] svg[data-icon^='chevron']")
  end

  it "include il modale changelog (dialog nativo)" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_css("dialog[data-test='changelog-modal']")
  end

  it "opens in the standard modal shell, with Close and the full history in the header (F24)" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_css("dialog[data-test='changelog-modal'][class~='dark:bg-zinc-950']")
    expect(page).to have_css("dialog[data-test='changelog-modal'] header [data-test='changelog-close']")
    expect(page).to have_css("dialog[data-test='changelog-modal'] header [data-test='changelog-view-all']")
    expect(page).to have_css("dialog[data-test='changelog-modal'] [data-action~='ui--dialog#close']", count: 1)
  end

  it "il trigger apre il dialog via ui--dialog" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_css("[data-test='footer-version'][data-action~='ui--dialog#open']")
  end

  it "rende una voce release per ogni release passata" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52"), release("0.0.51") ]))
    expect(page).to have_css("[data-test='changelog-release']", count: 2)
  end

  it "espone il link allo storico completo" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_css("[data-test='changelog-view-all']")
  end

  it "mostra l'etichetta 'dev' quando non c'è versione" do
    render_inline(described_class.new(current: nil, releases: []))
    expect(page).to have_css("[data-test='footer-version']", text: I18n.t("shared.changelog.unknown"))
  end

  it "in the sidebar renders a phone-only link to the changelog page, without a second dialog" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ], placement: :sidebar))
    expect(page).to have_css(".md\\:hidden a[data-test='sidebar-version'][href='/member/changelog']", text: "v0.0.52")
    expect(page).to have_no_css("dialog")
  end

  it "renders the trigger as a design-system button" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_css("button[data-test='footer-version'].rounded-md.h-7")
  end

  it "signals a release the person has not opened yet, and saves it as seen on the first click" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ], unseen: true))

    expect(page).to have_css("[data-test='footer-version'] [data-test='footer-version-new']",
                             text: I18n.t("shared.changelog.new"))
    seen = page.find("[data-controller~='ui--seen-signal']")
    expect(seen["data-ui--seen-signal-key-value"]).to eq("release:v0.0.52")
    expect(seen["data-ui--seen-signal-url-value"]).to eq("/member/preferences/notices")
    expect(page).to have_css("[data-test='footer-version'][data-action~='ui--seen-signal#mark']")
  end

  it "shows no signal once the release has been seen" do
    render_inline(described_class.new(current: release("0.0.52"), releases: [ release("0.0.52") ]))
    expect(page).to have_no_css("[data-test='footer-version-new']")
  end

  it "mostra lo stato vuoto quando non ci sono release" do
    render_inline(described_class.new(current: nil, releases: []))
    expect(page).to have_css("[data-test='changelog-empty']")
  end
end
