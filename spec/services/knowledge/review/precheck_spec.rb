# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Review::Precheck do
  let(:good_body) { "Formato: troubleshooting\n\n## Sintomo\n`boom`\n## Causa\nx\n## Correzione\ny\n## Verifica\nz" }

  def violations(title: "Rails — la cache non tiene niente in prova", body: good_body, tech_spec: "", kind: "note",
                 tags: %w[rails test], known_titles: [])
    described_class.call(title:, body:, tech_spec:, kind:, tags:, known_titles:)
  end

  def codes(**args) = violations(**args).map(&:code)

  it "una pagina in regola non ha violazioni" do
    expect(violations).to be_empty
  end

  describe "K01 — formato dichiarato" do
    it "manca la prima riga" do
      expect(codes(body: "## Sintomo\n`x`")).to include("K01")
    end

    it "accetta la chiave o l'etichetta italiana, senza badare alle maiuscole" do
      expect(described_class.format_of("formato: Accessi di test\n…")).to eq("test_access")
      expect(described_class.format_of("Formato: procedure")).to eq("procedure")
      expect(described_class.format_of("Formato: poesia")).to be_nil
    end
  end

  describe "legacy — il giro sul parco scritto prima delle regole" do
    it "ignora K01 e K11, e il titolo fuori schema è solo un avviso" do
      found = violations(title: "senza area", body: "## Sintomo\n`x`", tags: [], known_titles: [])
      expect(found.map(&:code)).to eq(%w[K01 K02 K11])

      legacy = described_class.call(title: "senza area", body: "## Sintomo\n`x`", tech_spec: "", kind: "note", tags: [], legacy: true)
      expect(legacy.map { |v| [ v.code, v.blocking ] }).to eq([ [ "K02", false ] ])
    end

    it "le regole di sostanza restano: segreti e titoli «N trappole»" do
      legacy = described_class.call(title: "CI — tre trappole", body: "postgres://u:p@h/db", tech_spec: "", kind: "note", tags: [], legacy: true)
      expect(legacy.map(&:code)).to contain_exactly("K02_bundle", "K08_url")
    end
  end

  describe "K02 — titolo" do
    it "vuole il trattino lungo fra spazi" do
      expect(codes(title: "Rails - la cache")).to eq([ "K02_dash" ])
      expect(codes(title: "Rails – la cache")).to eq([ "K02_dash" ])
      expect(codes(title: "La cache non tiene")).to eq([ "K02" ])
    end

    it "boccia i titoli «N trappole»" do
      expect(codes(title: "CI — tre trappole del runner Mac")).to eq([ "K02_bundle" ])
      expect(codes(title: "CI — 4 cose che il provisioning non copre")).to eq([ "K02_bundle" ])
    end
  end

  it "K07 — indirizzi scritti a parole" do
    expect(codes(body: "#{good_body}\nvai su clubbel punto staging punto bussolarialessio punto me")).to include("K07")
    expect(codes(body: "#{good_body}\nscrivi a god chiocciola clubbel.com")).to include("K07")
  end

  describe "K08 — segreti" do
    it "boccia sempre un URL con credenziali" do
      expect(codes(body: "#{good_body}\n`postgres://user:pass@localhost/db`")).to include("K08_url")
    end

    it "boccia chiavi note e coppie nome=valore fuori dagli accessi di test" do
      expect(codes(tech_spec: "token: ghp_abcdefghijklmnop")).to include("K08_key")
      expect(codes(tech_spec: "PASSWORD = supersegreta1")).to include("K08_key")
      expect(codes(tech_spec: "-----BEGIN RSA PRIVATE KEY-----")).to include("K08_key")
    end

    it "guarda anche titolo e tag, non solo il corpo" do
      expect(codes(title: "Rails — token: ghp_abcdefghijklmnop")).to include("K08_key")
      expect(codes(tags: [ "rails", "postgres://u:p@h/db" ])).to include("K08_url")
    end

    it "non scatta su nomi di variabile senza valore né su valori corti" do
      expect(codes(tech_spec: "la chiave sta in `AI_API_KEY` (vault CYRA/staging)")).not_to include("K08_key")
      expect(codes(tech_spec: "password: 1,7%")).not_to include("K08_key")
    end

    it "negli accessi di test le password ci stanno, ma non quelle di produzione" do
      staging = "Formato: accessi di test\nAmbiente: staging\n| Email | Password |\n| a@e2e.test | password: Segreta123! |"
      expect(codes(body: staging, kind: "guide", tags: %w[clubbel accessi-test])).to be_empty
      expect(codes(body: staging.sub("staging", "production"), kind: "guide")).to include("A01")
      expect(codes(body: staging.sub("Ambiente: staging\n", ""), kind: "guide")).to include("A01_missing")
    end
  end

  it "K10 — kind coerente col formato" do
    expect(codes(kind: "guide")).to eq([ "K10" ])
    expect(codes(body: "Formato: procedura\n1. a\n2. b\n3. c", kind: "guide")).to be_empty
  end

  it "K11 — almeno due tag, contati DOPO la normalizzazione (strip/downcase/uniq)" do
    expect(codes(tags: [ "rails" ])).to eq([ "K11" ])
    expect(codes(tags: [])).to eq([ "K11" ])
    expect(codes(tags: [ "Rails", " rails ", "" ])).to eq([ "K11" ])
    expect(codes(tags: [ "Rails", "Cache" ])).to be_empty
  end

  describe "K12 — lunghezze" do
    it "corpo e parte tecnica oltre il tetto" do
      expect(codes(body: "#{good_body}\n#{'x' * 4_000}")).to include("K12_body")
      expect(codes(tech_spec: "x" * 1_501)).to include("K12_tech")
    end

    it "parte tecnica compressa al limite" do
      expect(codes(tech_spec: "x" * 1_460)).to eq([ "K12_squeezed" ])
      expect(codes(tech_spec: "x" * 1_400)).to be_empty
    end
  end

  describe "P05 — guida in parti" do
    let(:proc_body) { "Formato: procedura\n1. a\n2. b\n3. c" }

    def part(title, known: [])
      violations(title:, body: proc_body, kind: "guide", tags: %w[nuxt deploy], known_titles: known)
    end

    it "numeri impossibili" do
      expect(part("Nuxt — deploy su sites (parte 3/2)").map(&:code)).to eq([ "P05_numbers" ])
      expect(part("Nuxt — deploy su sites (parte 0/2)").map(&:code)).to eq([ "P05_numbers" ])
      expect(part("Nuxt — deploy su sites (parte 1/1)").map(&:code)).to eq([ "P05_numbers" ])
    end

    it "la parte mancante è un avviso che non blocca" do
      found = part("Nuxt — deploy su sites (parte 1/3)")
      expect(found.map(&:code)).to eq([ "P05_missing" ])
      expect(found.first).not_to be_blocking
      expect(found.first.message).to include("2, 3")
    end

    it "con tutte le parti presenti non avvisa" do
      known = [ "Nuxt — deploy su sites (parte 1/3)", "Nuxt — deploy su sites (parte 2/3)" ]
      expect(part("Nuxt — deploy su sites (parte 3/3)", known:)).to be_empty
    end

    it "un totale diverso dalle altre parti blocca" do
      known = [ "Nuxt — deploy su sites (parte 1/2)" ]
      expect(part("Nuxt — deploy su sites (parte 2/3)", known:).map(&:code)).to eq([ "P05_total" ])
    end
  end

  describe "K14 — wikilink" do
    it "blocca un collegamento a una pagina che non esiste" do
      found = violations(body: "#{good_body}\nVedi [[Rails — altra cosa]]", known_titles: [ "Rails — una cosa" ])
      expect(found.map(&:code)).to eq([ "K14" ])
      expect(found.first).to be_blocking
    end

    it "passa se la pagina esiste, senza badare alle maiuscole" do
      expect(violations(body: "#{good_body}\nVedi [[rails — una cosa]]", known_titles: [ "Rails — una cosa" ])).to be_empty
    end

    it "la parte successiva della stessa serie è solo un avviso" do
      found = violations(title: "Nuxt — deploy (parte 1/2)", body: "Formato: procedura\n1. a\n2. b\n3. c\nContinua in [[Nuxt — deploy (parte 2/2)]]",
                         kind: "guide", tags: %w[nuxt deploy])
      expect(found.map { |v| [ v.code, v.blocking ] }).to contain_exactly([ "K14", false ], [ "P05_missing", false ])
    end
  end
end
