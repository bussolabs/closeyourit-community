# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarkdownHelper, type: :helper do
  describe "#render_markdown" do
    it "rende grassetto ed elenchi invece dei simboli in chiaro" do
      html = helper.render_markdown("Testo **grassetto**\n\n- primo\n- secondo")

      expect(html).to include("<strong>grassetto</strong>")
      expect(html).to include("<ul>")
      expect(html).to include("<li>primo</li>")
    end

    it "escapa l'HTML grezzo nel sorgente (modalità safe)" do
      html = helper.render_markdown("<script>alert(1)</script>")

      expect(html).not_to include("<script>")
      expect(html).to include("&lt;script&gt;")
    end

    it "neutralizza le immagini remote con remote_images: false" do
      html = helper.render_markdown("![logo](https://tracker.example/pixel.png)", remote_images: false)

      expect(html).not_to include("<img")
      expect(html).to include("tracker.example/pixel.png")
    end
  end

  describe "#render_markdown_inline" do
    it "toglie il paragrafo quando il testo è un blocco solo" do
      html = helper.render_markdown_inline("il **piano** è pronto")

      expect(html).to eq("il <strong>piano</strong> è pronto")
    end

    it "tiene i blocchi quando il testo ne ha più di uno" do
      html = helper.render_markdown_inline("prima riga\n\n- elenco")

      expect(html).to include("<p>prima riga</p>")
      expect(html).to include("<li>elenco</li>")
    end

    it "escapa l'HTML grezzo come la variante a blocchi" do
      html = helper.render_markdown_inline("<img src=x onerror=alert(1)>")

      expect(html).not_to include("<img")
      expect(html).to include("&lt;img")
    end

    it "restituisce vuoto per testo assente" do
      expect(helper.render_markdown_inline(nil)).to eq("")
      expect(helper.render_markdown_inline("")).to eq("")
    end

    it "è marcato html_safe" do
      expect(helper.render_markdown_inline("ciao")).to be_html_safe
    end
  end

  # CYRA-431 — una riga di comando più larga della colonna finiva tagliata al bordo: senza barra,
  # senza segno che continuasse, e chi la copiava a mano portava via mezzo comando.
  describe "blocchi di codice" do
    let(:comando) { "kamal app exec --reuse 'bin/rails runner Metriche::Ricalcola.tutte'" }
    let(:html) { helper.render_markdown("Prova\n\n```\n#{comando}\n```\n") }
    let(:doc) { Nokogiri::HTML5.fragment(html) }

    it "il blocco scorre in orizzontale e dichiara che il testo continua" do
      pre = doc.at_css("pre")

      expect(pre["class"]).to include("overflow-x-auto")
      expect(pre["data-controller"]).to eq("ui--scroll-hint")
    end

    it "il bottone di copia prende la riga sorgente, non quella visibile" do
      blocco = doc.at_css("[data-test='code-block']")

      expect(blocco["data-controller"]).to eq("clipboard")
      expect(blocco.at_css("[data-test='code-block-copy']")).to be_present
      expect(blocco.at_css("[data-clipboard-target='source']").text).to include(comando)
    end

    it "il bottone resta fuori dal testo che viene copiato" do
      sorgente = doc.at_css("[data-clipboard-target='source']").text

      expect(sorgente).not_to include(I18n.t("shared.code_block.copy"))
    end

    it "il codice in linea resta com'è" do
      inline = helper.render_markdown("usa `bin/dev` per partire")

      expect(inline).to include("<code>bin/dev</code>")
      expect(inline).not_to include("code-block")
    end

    it "un testo senza codice non paga nessuna riscrittura" do
      expect(helper.render_markdown("solo parole")).to eq("<p>solo parole</p>\n")
    end
  end

  # CYRA-405 — nelle analisi i percorsi dei file vivono in mezzo alla prosa: senza un segno, chi non
  # è del mestiere non distingue la spiegazione dal riferimento tecnico.
  describe "riferimenti a file dentro la prosa" do
    it "li segna come codice" do
      html = helper.render_markdown("La logica sta in app/services/foo.rb:33 e in config/routes.rb.")

      expect(html).to include("<code>app/services/foo.rb:33</code>")
      expect(html).to include("<code>config/routes.rb</code>")
    end

    it "non tocca quelli già scritti come codice" do
      html = helper.render_markdown("Vedi `app/models/x.rb` per il resto.")

      expect(html.scan("<code>").size).to eq(1)
    end

    it "non tocca il testo dentro un blocco di codice" do
      html = helper.render_markdown("```\ncat app/models/x.rb\n```\n")

      expect(html).not_to include("<code><code>")
    end

    it "non tocca il testo di un collegamento" do
      html = helper.render_markdown("[apri app/models/x.rb](https://example.com)")

      expect(html).not_to include("<code>")
    end

    it "un testo senza percorsi non paga nessuna riscrittura" do
      expect(helper.render_markdown("solo parole")).to eq("<p>solo parole</p>\n")
    end

    # Il testo di un nodo torna GREZZO: se lo si rimettesse così com'è, il markup che il renderer
    # aveva reso innocuo tornerebbe vivo. Vale solo per le righe che contengono anche un percorso,
    # cioè quelle che passano dalla marcatura.
    it "marcando i percorsi non fa rivivere il markup che il renderer aveva neutralizzato" do
      html = helper.render_markdown("Prova <script>alert(1)</script> in app/x.rb")

      expect(html).to include("&lt;script&gt;")
      expect(html).not_to include("<script>")
    end
  end
end
