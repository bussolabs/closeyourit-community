# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ButtonComponent, type: :component do
  it "rende un button con la variante primary di default" do
    render_inline(described_class.new(label: "OK"))
    expect(page).to have_css("button.bg-indigo-600", text: "OK")
  end

  it "rende un link quando passato href" do
    render_inline(described_class.new(label: "Vai", href: "/x"))
    expect(page).to have_css("a[href='/x']", text: "Vai")
  end

  it "applica la size sm" do
    render_inline(described_class.new(label: "S", size: :sm))
    expect(page).to have_css("button.h-7")
  end

  it "renders the Lucide icon" do
    render_inline(described_class.new(label: "Add", icon: "plus"))
    expect(page).to have_css("button svg[data-icon='plus']")
  end

  it "espone il data-test" do
    render_inline(described_class.new(label: "T", test_id: "btn-x"))
    expect(page).to have_css("button[data-test='btn-x']")
  end

  it "rende lo stato disabled" do
    render_inline(described_class.new(label: "D", disabled: true))
    expect(page).to have_css("button[disabled]")
  end

  it "solleva ArgumentError su variante sconosciuta" do
    expect { described_class.new(label: "X", variant: :nope) }.to raise_error(ArgumentError)
  end

  it "solleva ArgumentError su size sconosciuta" do
    expect { described_class.new(label: "X", size: :huge) }.to raise_error(ArgumentError)
  end

  # A leftover Font Awesome name must fail at construction, not render a missing icon (CYRA-926).
  it "raises ArgumentError when the icon is a Font Awesome name" do
    expect { described_class.new(label: "X", icon: "fa-rotate") }
      .to raise_error(ArgumentError, /Lucide name/)
  end

  it "inoltra l'attributo form per submit fuori dal <form>" do
    render_inline(described_class.new(label: "Salva", type: "submit", form: "x-form"))
    expect(page).to have_css("button[form='x-form'][type='submit']")
  end

  it "espone un focus ring visibile ad AA (indigo-500 su focus-visible)" do
    render_inline(described_class.new(label: "Ok"))
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-indigo-500")
    expect(html).not_to include("focus:ring-indigo-100")
  end

  it "rende un button_to (form + _method) quando passato href + method" do
    render_inline(described_class.new(label: "Elimina", href: "/x", method: :delete))
    expect(page).to have_css("form[action='/x'] button", text: "Elimina")
    expect(page).to have_css("form input[name='_method'][value='delete']", visible: :all)
  end

  it "propaga confirm come data-turbo-confirm sul button_to" do
    render_inline(described_class.new(label: "Elimina", href: "/x", method: :delete, confirm: "Sicuro?"))
    expect(page).to have_css("button[data-turbo-confirm='Sicuro?']")
  end

  it "applica form_class al <form> wrapper del button_to" do
    render_inline(described_class.new(label: "Watch", href: "/w", method: :put, form_class: "pointer-events-auto"))
    expect(page).to have_css("form.pointer-events-auto button", text: "Watch")
  end

  it "rende le varianti header (secondary_muted / danger_outline / success_outline)" do
    render_inline(described_class.new(label: "Edit", variant: :secondary_muted))
    expect(page).to have_css("button.text-gray-500.bg-white")

    render_inline(described_class.new(label: "Del", variant: :danger_outline))
    expect(page).to have_css("button.text-red-600.bg-white")

    render_inline(described_class.new(label: "Approve", variant: :success_outline))
    expect(page).to have_css("button.text-emerald-700.bg-white")
  end

  it "rende la variante success come verde pieno, gemella di danger" do
    render_inline(described_class.new(label: "Approva", variant: :success))
    expect(page).to have_css("button.bg-emerald-600.text-white")
  end

  it "rende il variant tinted_outline (indigo con bordo, per lo stato attivo del watch)" do
    render_inline(described_class.new(label: "Seguendo", variant: :tinted_outline))
    # Indigo soft come :tinted, ma bordato → shape coerente col :secondary_muted dello stato inattivo.
    expect(page).to have_css("button.text-indigo-600.bg-indigo-50.border.border-indigo-200")
  end

  it "rende lo slot trailing dopo la label (badge conteggio)" do
    render_inline(described_class.new(label: "Watch", href: "/w", method: :put)) do |b|
      b.with_trailing { "<span data-test='cnt'>3</span>".html_safe }
    end
    expect(page).to have_css("button", text: "Watch")
    expect(page).to have_css("button [data-test='cnt']", text: "3")
  end

  it "dimensiona l'icona in base alla size (sm → 11px)" do
    render_inline(described_class.new(label: "Add", icon: "plus", size: :sm))
    expect(page).to have_css("button svg[data-icon='plus'].text-\\[11px\\]")
  end

  describe "icon_only" do
    it "rende un quadrato con la sola icona, senza il testo della label" do
      render_inline(described_class.new(label: "Approva", icon: "check", icon_only: true, size: :sm))
      expect(page).to have_css("button.h-7.w-7 svg[data-icon='check']")
      expect(page).to have_no_text("Approva")
    end

    it "conserva la label come aria-label e title (l'unica etichetta accessibile)" do
      render_inline(described_class.new(label: "Approva", icon: "check", icon_only: true))
      expect(page).to have_css("button[aria-label='Approva'][title='Approva']")
    end

    it "lascia vincere un aria-label esplicito del caller" do
      render_inline(described_class.new(label: "Approva", icon: "check", icon_only: true, aria: { label: "Approva la review" }))
      expect(page).to have_css("button[aria-label='Approva la review']")
    end

    it "non rende lo slot trailing" do
      render_inline(described_class.new(label: "Approva", icon: "check", icon_only: true)) do |b|
        b.with_trailing { "<span data-test='cnt'>3</span>".html_safe }
      end
      expect(page).to have_no_css("[data-test='cnt']")
    end

    it "solleva ArgumentError senza icon" do
      expect { described_class.new(label: "X", icon_only: true) }.to raise_error(ArgumentError, /icon/)
    end

    it "solleva ArgumentError senza label" do
      expect { described_class.new(icon: "check", icon_only: true) }.to raise_error(ArgumentError, /label/)
    end
  end

  # CYRA-571 — un'azione di riga NON porta più il suo `<form>`: submette quello unico della pagina
  # (Ui::RowActionsFormComponent) puntandolo con `formaction`. Ogni form wrappato porta con sé un
  # token CSRF diverso, quindi su una lista lunga il peso cresce riga per riga e non è comprimibile.
  describe "form_id (azione mutante sul modulo condiviso della pagina)" do
    it "submette il modulo condiviso invece di costruirne uno proprio" do
      render_inline(described_class.new(label: "Approva", href: "/x/approve", method: :post, form_id: "row-actions"))
      expect(page).to have_no_css("form")
      expect(page).to have_css("button[type='submit'][form='row-actions'][formaction='/x/approve']", text: "Approva")
    end

    it "porta il metodo diverso da POST nel campo del submitter" do
      render_inline(described_class.new(label: "Rimetti", href: "/x", method: :delete, form_id: "row-actions"))
      expect(page).to have_css("button[name='_method'][value='delete']")
    end

    it "non aggiunge _method quando il metodo è già quello del modulo condiviso" do
      render_inline(described_class.new(label: "Approva", href: "/x", method: :post, form_id: "row-actions"))
      expect(page).to have_no_css("button[name='_method']")
    end

    it "propaga confirm come data-turbo-confirm sul submitter" do
      render_inline(described_class.new(label: "Rifiuta", href: "/x", method: :post, form_id: "row-actions",
                                        confirm: "Sicuro?"))
      expect(page).to have_css("button[data-turbo-confirm='Sicuro?']")
    end

    it "solleva ArgumentError senza href o senza method (senza non è un'azione)" do
      expect { described_class.new(label: "X", href: "/x", form_id: "row-actions") }
        .to raise_error(ArgumentError, /method/)
      expect { described_class.new(label: "X", method: :post, form_id: "row-actions") }
        .to raise_error(ArgumentError, /href/)
    end
  end

  describe "grouped" do
    it "rinuncia al proprio raggio, che nel gruppo lo dà il wrapper" do
      render_inline(described_class.new(label: "Ok", grouped: true))
      expect(page).to have_no_css("button.rounded-md")
    end

    it "tiene il raggio quando è fuori da un gruppo" do
      render_inline(described_class.new(label: "Ok"))
      expect(page).to have_css("button.rounded-md")
    end

    # Il wrapper del gruppo ha overflow-hidden per clippare i raggi dei figli: un ring esterno con
    # offset verrebbe clippato anche lui e il focus da tastiera sparirebbe. Dentro, il ring va inset.
    it "porta il focus ring all'interno, così overflow-hidden non lo cancella" do
      render_inline(described_class.new(label: "Ok", grouped: true))
      html = page.native.to_html
      expect(html).to include("focus-visible:ring-inset")
      expect(html).not_to include("focus-visible:ring-offset-1")
      expect(html).to include("focus-visible:ring-indigo-500")
    end
  end
end
