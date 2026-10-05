# frozen_string_literal: true

require "rails_helper"

# CYRA-419 — «Il segno resta finché una persona non cambia la pagina davvero: correggere una virgola
# non la rende sua». Questa spec è la definizione scritta della soglia.
RSpec.describe Knowledge::SubstantiveEdit do
  # Testo di riferimento: 60 parole, come una pagina corta vera.
  let(:testo) do
    (1..60).map { |number| "parola#{number}" }.join(" ")
  end

  it "correggere la punteggiatura non è una riscrittura" do
    expect(described_class.call(before: testo, after: "#{testo}.")).to be(false)
  end

  it "sistemare due parole su sessanta non è una riscrittura" do
    corretto = testo.sub("parola3 parola4", "termine3 termine4")

    expect(described_class.call(before: testo, after: corretto)).to be(false)
  end

  it "riscrivere metà del testo è una riscrittura" do
    riscritto = testo.split.each_with_index.map { |parola, indice| indice.even? ? "nuova#{indice}" : parola }.join(" ")

    expect(described_class.call(before: testo, after: riscritto)).to be(true)
  end

  it "aggiungere un paragrafo intero è una riscrittura anche su una pagina lunga" do
    lunga = (1..600).map { |number| "parola#{number}" }.join(" ")
    paragrafo = (1..45).map { |number| "aggiunta#{number}" }.join(" ")

    expect(described_class.call(before: lunga, after: "#{lunga} #{paragrafo}")).to be(true)
  end

  it "cambiare una sola parola in una pagina cortissima resta una correzione" do
    expect(described_class.call(before: "una nota breve", after: "una nota corta")).to be(false)
  end

  it "riscrivere per intero una pagina cortissima è una riscrittura" do
    expect(described_class.call(before: "una nota breve scritta male", after: "il vault sta sul server di produzione")).to be(true)
  end

  it "cambiare solo maiuscole e spazi non conta" do
    expect(described_class.call(before: "Il  vault sta sul server", after: "il vault sta   sul SERVER")).to be(false)
  end

  it "testo identico non conta" do
    expect(described_class.call(before: testo, after: testo)).to be(false)
  end

  it "un testo che arriva vuoto non conta come riscrittura" do
    expect(described_class.call(before: nil, after: nil)).to be(false)
  end
end
