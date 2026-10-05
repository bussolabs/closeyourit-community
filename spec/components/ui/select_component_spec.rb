# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SelectComponent, type: :component do
  let(:options) { [ [ "Storefront", "1" ], [ "Payments API", "2" ] ] }

  it "rende label, marker required e opzione selezionata" do
    render_inline(described_class.new(name: "project_id", label: "Project", options: options, selected: "2", required: true))
    expect(page).to have_css("label[for='project_id']", text: "Project")
    expect(page).to have_css("label span.text-red-500", text: "*")
    expect(page).to have_css("select#project_id[name='project_id'][required]")
    expect(page).to have_css("option[value='2'][selected]", text: "Payments API")
  end

  it "single → name scalare, niente multiple" do
    render_inline(described_class.new(name: "status_id", options: options))
    expect(page).to have_css("select[name='status_id']")
    expect(page).not_to have_css("select[multiple]")
  end

  it "multiple → name array e attributo multiple" do
    render_inline(described_class.new(name: "status_id", options: options, multiple: true))
    expect(page).to have_css("select[name='status_id[]'][multiple]")
  end

  it "include_blank aggiunge l'opzione vuota col placeholder" do
    render_inline(described_class.new(name: "project_id", options: options, include_blank: true, placeholder: "Any"))
    expect(page).to have_css("option[value='']", text: "Any")
  end

  it "è arricchibile dallo Stimulus ui--select e porta il data-test sul select" do
    render_inline(described_class.new(name: "project_id", options: options, test_id: "ticket-project"))
    expect(page).to have_css("div[data-controller='ui--select']")
    expect(page).to have_css("select[data-test='ticket-project']")
  end

  it "summary di default è false (form: nessun prefisso nel trigger)" do
    render_inline(described_class.new(name: "status_id", options: options, multiple: true))
    expect(page).to have_css("div[data-controller='ui--select'][data-ui--select-summary-value='false']")
  end

  it "summary: true attiva il riepilogo prefissato nel trigger (filtri)" do
    render_inline(described_class.new(name: "status_id", options: options, multiple: true,
                                      summary: true, placeholder: "Status"))
    expect(page).to have_css("div[data-ui--select-summary-value='true'][data-ui--select-placeholder-value='Status']")
  end

  it "mostra l'errore con bordo rosso" do
    render_inline(described_class.new(name: "project_id", options: options, error: "Obbligatorio"))
    expect(page).to have_css("p.text-red-600", text: "Obbligatorio")
    expect(page).to have_css("select.border-red-400")
  end

  it "applica wrapper_class al div esterno" do
    render_inline(described_class.new(name: "project_id", options: options, wrapper_class: "md:col-span-2"))
    expect(page).to have_css("div[class*='md:col-span-2']")
  end

  it "espone un focus ring visibile ad AA (indigo-500 su focus-visible)" do
    render_inline(described_class.new(name: "project_id", options: options))
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-indigo-500")
    expect(html).not_to include("focus:ring-indigo-100")
  end

  it "variante error espone il ring rosso ad AA (focus-visible:ring-red-500)" do
    render_inline(described_class.new(name: "project_id", options: options, error: "Obbligatorio"))
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-red-500")
    expect(html).not_to include("focus:ring-red-100")
  end

  it "aria_label senza label visibile: espone aria-label sul select (a11y)" do
    render_inline(described_class.new(name: "cadence", options: options, aria_label: "Email cadence"))
    expect(page).to have_css("select[aria-label='Email cadence']")
  end

  it "aria_label con label visibile: il label vince, niente aria-label ridondante" do
    render_inline(described_class.new(name: "project_id", label: "Project", options: options, aria_label: "Ignored"))
    expect(page).not_to have_css("select[aria-label]")
  end

  it "senza aria_label: nessun attributo aria-label (nessun rumore)" do
    render_inline(described_class.new(name: "project_id", options: options))
    expect(page).not_to have_css("select[aria-label]")
  end

  # CYRA-343: descrizione per-opzione (opt-in). Il dropdown arricchito la rende sotto la voce; il
  # fallback nativo la porta come `title` (tooltip). Zero impatto senza `descriptions:`.
  describe "descriptions per-opzione" do
    it "porta data-description e title sulle opzioni che ne hanno una" do
      render_inline(described_class.new(name: "kind", options: options,
                                        descriptions: { "1" => "Il negozio", "2" => "I pagamenti" }))
      expect(page).to have_css("option[value='1'][data-description='Il negozio'][title='Il negozio']")
      expect(page).to have_css("option[value='2'][data-description='I pagamenti'][title='I pagamenti']")
    end

    it "opzione senza descrizione: nessun data-description né title" do
      render_inline(described_class.new(name: "kind", options: options, descriptions: { "1" => "Solo la prima" }))
      expect(page).to have_css("option[value='2']")
      expect(page).not_to have_css("option[value='2'][data-description]")
      expect(page).not_to have_css("option[value='2'][title]")
    end

    it "senza descriptions: nessuna opzione porta data-description (retrocompat)" do
      render_inline(described_class.new(name: "kind", options: options))
      expect(page).not_to have_css("option[data-description]")
    end
  end

  # CYRA-364 — vocabolari troppo grandi da caricare interi: le opzioni rese dal server sono solo il
  # primo blocco, il resto arriva digitando. Senza `remote:` non deve cambiare NIENTE.
  describe "opzioni dal server (remote)" do
    it "affianca ui--remote-options a ui--select e gli dice dove chiederle" do
      render_inline(described_class.new(name: "ticket_id", options: options,
                                        remote: { url: "/member/tickets/linkable", scope_field: "#team_id" }))

      expect(page).to have_css("[data-controller='ui--select ui--remote-options']")
      expect(page).to have_css("[data-ui--remote-options-url-value='/member/tickets/linkable']")
      expect(page).to have_css("[data-ui--remote-options-scope-field-value='#team_id']")
      expect(page).to have_css("select[data-ui--remote-options-target='select']")
    end

    it "il perimetro si allarga da una casella esplicita, che non entra nel submit" do
      render_inline(described_class.new(name: "ticket_id", options: options, test_id: "ticket",
                                        remote: { url: "/x", all_label: "Cerca ovunque" }))

      expect(page).to have_css("input[type='checkbox'][data-ui--remote-options-target='all']")
      expect(page).to have_text("Cerca ovunque")
      expect(page).not_to have_css("input[type='checkbox'][name]")
    end

    it "senza all_label non c'è nessuna casella da spuntare" do
      render_inline(described_class.new(name: "ticket_id", options: options, remote: { url: "/x" }))
      expect(page).not_to have_css("input[type='checkbox']")
    end

    it "senza remote resta il solo ui--select di sempre" do
      render_inline(described_class.new(name: "kind", options: options))

      expect(page).to have_css("[data-controller='ui--select']")
      expect(page).not_to have_css("[data-ui--remote-options-url-value]")
      expect(page).not_to have_css("select[data-ui--remote-options-target]")
    end
  end

  # CYRA-883 — a fixed prefix (icon + word) inside the same trigger, before the chosen value.
  describe "prefix" do
    it "passes the prefix text and icon to the enhanced trigger" do
      render_inline(described_class.new(name: "sort", options: [ [ "Name", "name" ] ], selected: "name",
                                        prefix: { text: "Sort", icon: "arrow-down-wide-short" }))

      wrapper = page.find("[data-controller='ui--select']")
      expect(wrapper["data-ui--select-prefix-value"]).to eq("Sort")
      expect(wrapper["data-ui--select-prefix-icon-value"]).to eq("arrow-down-wide-short")
    end

    it "sets no prefix values without the option" do
      render_inline(described_class.new(name: "sort", options: [ [ "Name", "name" ] ]))

      expect(page.find("[data-controller='ui--select']")["data-ui--select-prefix-value"]).to be_nil
    end
  end
end
