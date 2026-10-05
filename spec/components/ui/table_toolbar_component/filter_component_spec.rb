# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableToolbarComponent::FilterComponent, type: :component do
  it "wrappa il contenuto in un chip con X di rimozione" do
    render_inline(described_class.new(key: "status", label: "Status")) { "<span data-test='inner'>F</span>".html_safe }

    # Senza params il chip è [hidden] → visible: :all per ispezionarne il contenuto.
    expect(page).to have_css("[data-test='filter-chip-status'][data-filter-key='status']", visible: :all)
    expect(page).to have_css("[data-test='inner']", visible: :all)
    # X: type=button (dentro un form GET non deve submittare) + aria-label i18n.
    expect(page).to have_css("button[type='button'][data-test='filter-chip-status-remove'][aria-label='Remove Status filter']", visible: :all)
  end

  # The period filter opens from a <summary>: it too gives up its right corners next to the X.
  it "squares the right corners of a period trigger joined to the X" do
    render_inline(described_class.new(key: "range", label: "Period")) { "<details><summary>24h</summary></details>".html_safe }

    expect(page.find("[data-test='filter-chip-range']", visible: :all)[:class]).to include("[&>:first-child>summary]:rounded-r-none")
  end

  it "è hidden senza param attivo" do
    render_inline(described_class.new(key: "status", label: "Status")) { "F" }
    expect(page).to have_css("[data-test='filter-chip-status'][hidden]", visible: :all)
  end

  it "è visibile con param array" do
    with_request_url "/login?status[]=open" do
      render_inline(described_class.new(key: "status", label: "Status")) { "F" }
    end

    expect(page).to have_css("[data-test='filter-chip-status']:not([hidden])")
  end

  it "è visibile con param scalare" do
    with_request_url "/login?status=open" do
      render_inline(described_class.new(key: "status", label: "Status")) { "F" }
    end

    expect(page).to have_css("[data-test='filter-chip-status']:not([hidden])")
  end

  it "resta hidden con param blank" do
    with_request_url "/login?status[]=" do
      render_inline(described_class.new(key: "status", label: "Status")) { "F" }
    end

    expect(page).to have_css("[data-test='filter-chip-status'][hidden]", visible: :all)
  end

  it "accetta un chip_test_id personalizzato" do
    render_inline(described_class.new(key: "status", label: "Status", chip_test_id: "custom-chip")) { "F" }

    expect(page).to have_css("[data-test='custom-chip']", visible: :all)
    expect(page).to have_css("[data-test='custom-chip-remove']", visible: :all)
  end
end
