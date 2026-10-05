# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::InputComponent, type: :component do
  it "keeps custom identifiers consistent across field, label and error" do
    render_inline(described_class.new(name: "input", id: "task-input", type: "textarea", label: "Task", error: "Required"))
    expect(page).to have_css("textarea#task-input[aria-describedby='task-input_error']")
    expect(page).to have_css("label[for='task-input']")
    expect(page).to have_css("#task-input_error", text: "Required")
  end
  it "renders escaped multiline content with its label and required constraint" do
    render_inline(described_class.new(name: "memory", type: "textarea", label: "Memory", value: "<script>test</script>\nSecond line", required: true, rows: 8))
    expect(page).to have_css("label[for='memory']", text: "Memory")
    expect(page).to have_css("textarea#memory[required][rows='8']", text: "<script>test</script>")
    expect(page).not_to have_css("script")
  end
  it "rende label, input e marker required" do
    render_inline(described_class.new(name: "email", label: "Email", required: true))
    expect(page).to have_css("label[for='email']", text: "Email")
    expect(page).to have_css("label span.text-red-500", text: "*")
    expect(page).to have_css("input#email[name='email'][required]")
  end

  it "non mostra l'asterisco quando non required" do
    render_inline(described_class.new(name: "nome", label: "Nome"))
    expect(page).not_to have_css("span.text-red-500")
  end

  it "mostra l'errore con bordo rosso" do
    render_inline(described_class.new(name: "email", error: "non valida"))
    expect(page).to have_css("p.text-red-600", text: "non valida")
    expect(page).to have_css("input.border-red-400")
  end

  it "mostra l'hint quando non c'è errore" do
    render_inline(described_class.new(name: "email", hint: "ti serve per accedere"))
    expect(page).to have_css("p.text-gray-500", text: "ti serve per accedere")
  end

  it "applica wrapper_class al div esterno" do
    render_inline(described_class.new(name: "x", wrapper_class: "md:col-span-2"))
    expect(page).to have_css("div[class*='md:col-span-2']")
  end

  it "senza wrapper_class non aggiunge classi col-span al wrapper" do
    render_inline(described_class.new(name: "x"))
    expect(page).not_to have_css("div[class*='col-span']")
  end

  it "espone un focus ring visibile ad AA (indigo-500 su focus-visible)" do
    render_inline(described_class.new(name: "email"))
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-indigo-500")
    expect(html).not_to include("focus:ring-indigo-100")
  end

  it "variante error espone il ring rosso ad AA (focus-visible:ring-red-500)" do
    render_inline(described_class.new(name: "email", error: "x"))
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-red-500")
    expect(html).not_to include("focus:ring-red-100")
  end

  it "errore → associa input e messaggio via aria-invalid + aria-describedby" do
    render_inline(described_class.new(name: "email", error: "no"))
    html = page.native.to_html
    expect(html).to include('aria-invalid="true"').and include('aria-describedby="email_error"').and include('id="email_error"')
  end

  it "hint senza errore → associa input e hint via aria-describedby (niente aria-invalid)" do
    render_inline(described_class.new(name: "email", hint: "ti serve per accedere"))
    html = page.native.to_html
    expect(html).to include('aria-describedby="email_hint"').and include('id="email_hint"')
    expect(html).not_to include("aria-invalid")
  end

  it "senza errore né hint → nessun aria-describedby/aria-invalid" do
    render_inline(described_class.new(name: "email"))
    html = page.native.to_html
    expect(html).not_to include("aria-describedby")
    expect(html).not_to include("aria-invalid")
  end
end
