# frozen_string_literal: true

require "rails_helper"

# CYRA-4 — le scrollbar vanno nascoste in TUTTA l'interfaccia mantenendo lo scroll.
# Prima del fix la regola viveva solo dentro `@utility scrollbar-none`, applicata a
# mano su 5 container: la maggior parte dell'UI mostrava ancora la scrollbar.
# Questi spec verificano che il foglio di stile nasconda le scrollbar in modo
# GLOBALE (selettore universale), non solo per i container che optano esplicitamente.
RSpec.describe "application.css — scrollbar nascoste globalmente" do
  let(:css) { Rails.root.join("app/assets/tailwind/application.css").read }

  it "nasconde la scrollbar WebKit/Chromium su ogni elemento (selettore universale)" do
    # `*::-webkit-scrollbar` è universale; l'utility usa invece `&::-webkit-scrollbar`.
    expect(css).to match(/\*::-webkit-scrollbar\s*\{[^}]*display:\s*none/m)
  end

  it "azzera scrollbar-width su Firefox globalmente (selettore universale)" do
    # Regola `* { scrollbar-width: none }` fuori dal blocco @utility.
    expect(css).to match(/(?:\A|[^&\w])\*\s*\{[^}]*scrollbar-width:\s*none/m)
  end

  it "mantiene l'utility scrollbar-none per i container che la referenziano" do
    expect(css).to include("@utility scrollbar-none")
  end

  it "blurs the page behind every dialog, with one global rule" do
    expect(css).to match(/dialog::backdrop\s*\{[^}]*backdrop-filter:\s*blur\(/m)
  end
end
