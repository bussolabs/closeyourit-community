# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::BreadcrumbComponent, type: :component do
  it "rende una nav semantica con aria-label e data-test" do
    render_inline(described_class.new(crumbs: [ { label: "Tickets" } ]))

    expect(page).to have_css("nav[aria-label='breadcrumb'][data-test='breadcrumb'] ol")
  end

  it "antepone sempre il crumb Dashboard come prima voce" do
    render_inline(described_class.new(crumbs: [ { label: "Tickets", href: "/x" } ]))

    first = page.all("[data-test='breadcrumb-crumb']").first
    expect(first.text).to eq(I18n.t("member.nav.home"))
  end

  it "Dashboard è un link a root_path quando ci sono crumb successivi" do
    render_inline(described_class.new(crumbs: [ { label: "Tickets" } ]))

    expect(page).to have_css("a[href='/'][data-test='breadcrumb-crumb']", text: I18n.t("member.nav.home"))
  end

  it "l'ultimo crumb è la pagina corrente: span con aria-current, senza link" do
    render_inline(described_class.new(crumbs: [ { label: "Tickets" } ]))

    expect(page).to have_css("span[aria-current='page']", text: "Tickets")
    expect(page).not_to have_css("a", text: "Tickets")
  end

  it "i crumb intermedi con href sono link" do
    render_inline(described_class.new(crumbs: [ { label: "Tickets", href: "/tickets" }, { label: "TS-1" } ]))

    expect(page).to have_css("a[href='/tickets']", text: "Tickets")
    expect(page).to have_css("span[aria-current='page']", text: "TS-1")
  end

  it "con crumbs vuoto rende solo Dashboard come corrente, senza alcun link" do
    render_inline(described_class.new(crumbs: []))

    expect(page).to have_css("span[aria-current='page']", text: I18n.t("member.nav.home"))
    expect(page).not_to have_css("a")
  end

  it "inserisce un separatore tra i crumb (n crumb totali → n-1 separatori)" do
    render_inline(described_class.new(crumbs: [ { label: "Tickets", href: "/tickets" }, { label: "TS-1" } ]))

    # Dashboard + Tickets + TS-1 = 3 crumb → 2 separatori
    expect(page.all("[data-test='breadcrumb-sep']").size).to eq(2)
  end

  it "usa root_href e root_label custom (es. area valhalla)" do
    render_inline(described_class.new(crumbs: [ { label: "Accounts" } ], root_href: "/valhalla", root_label: "Valhalla"))

    expect(page).to have_css("a[href='/valhalla'][data-test='breadcrumb-crumb']", text: "Valhalla")
  end

  it "un crumb intermedio senza href è testo, non link" do
    render_inline(described_class.new(crumbs: [ { label: "Sezione" }, { label: "Corrente" } ]))

    expect(page).to have_css("span[data-test='breadcrumb-crumb']", text: "Sezione")
    expect(page).not_to have_css("a", text: "Sezione")
  end
end
