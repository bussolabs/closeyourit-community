# frozen_string_literal: true

module Ui
  class MarkdownComponentPreview < ViewComponent::Preview
    RICH = <<~MD
      ## Passi

      1. toccare `app/models/foo.rb`
      2. aggiornare la spec

      | file | cosa |
      |---|---|
      | `foo.rb` | la query |

      > Attenzione al tetto di revisione.

      - [x] analisi
      - [ ] rilascio
    MD

    def blocco = render(Ui::MarkdownComponent.new(text: RICH, class: "text-[13px] text-zinc-700 leading-relaxed"))

    # Il testo scritto senza markdown non cambia: gli a capo singoli restano a capo.
    def testo_semplice = render(Ui::MarkdownComponent.new(text: "prima riga\nseconda riga", class: "text-[13px] text-zinc-700"))

    # Variante inline: niente <p>, colore e corpo li eredita dalla riga che lo ospita.
    def inline
      render(Ui::MarkdownComponent.new(text: "un piano con `codice` e una parola in **grassetto**",
                                       inline: true, class: "text-[12.5px] text-gray-500"))
    end

    # Inline con più blocchi: il contenitore diventa un div, o un <ul> dentro uno <span> spezzerebbe
    # il paragrafo che lo ospita.
    def inline_con_elenco
      render(Ui::MarkdownComponent.new(text: "Serve una scelta:\n\n- prima opzione\n- seconda opzione",
                                       inline: true, class: "text-[12.5px] text-zinc-700"))
    end

    # L'HTML scritto da chi ha compilato il campo resta testo visibile, mai markup.
    def html_di_chi_scrive
      render(Ui::MarkdownComponent.new(text: "usa <div> per il layout <script>alert(1)</script>",
                                       class: "text-[13px] text-zinc-700"))
    end

    # Le immagini remote non partono dal browser di chi legge: restano l'indirizzo, in chiaro.
    def immagine_remota_neutralizzata
      render(Ui::MarkdownComponent.new(text: "![diagramma](https://tracker.example/pixel.png)",
                                       class: "text-[13px] text-zinc-700"))
    end
  end
end
