require "rails_helper"

RSpec.describe Text::ItalianOrthography do
  describe ".correct" do
    context "forme con apostrofo al posto dell'accento" do
      it "corregge «e'» in «è»" do
        expect(described_class.correct("Il ticket e' chiuso")).to eq("Il ticket è chiuso")
      end

      it "corregge «piu'» in «più»" do
        expect(described_class.correct("non serve piu'")).to eq("non serve più")
      end

      it "corregge «gia'» in «già»" do
        expect(described_class.correct("era gia' presente")).to eq("era già presente")
      end

      it "corregge «li'» in «lì»" do
        expect(described_class.correct("da li' non se ne vanno")).to eq("da lì non se ne vanno")
      end

      it "corregge «perche'» in «perché»" do
        expect(described_class.correct("spiega perche' fallisce")).to eq("spiega perché fallisce")
      end

      it "accetta anche l'apostrofo tipografico" do
        expect(described_class.correct("il conto e’ finito")).to eq("il conto è finito")
      end
    end

    context "parole senza accento del dizionario chiuso" do
      it "corregge «gia» in «già»" do
        expect(described_class.correct("nasce gia in stato saltata")).to eq("nasce già in stato saltata")
      end

      it "corregge «perche» in «perché»" do
        expect(described_class.correct("non dice perche")).to eq("non dice perché")
      end

      it "corregge «piu» in «più»" do
        expect(described_class.correct("uno o piu scenari")).to eq("uno o più scenari")
      end

      it "corregge «ereditarieta» in «ereditarietà»" do
        expect(described_class.correct("la ereditarieta dei permessi")).to eq("la ereditarietà dei permessi")
      end

      it "corregge «attivita» in «attività»" do
        expect(described_class.correct("la attivita recente")).to eq("la attività recente")
      end
    end

    context "forme ambigue" do
      it "non tocca la congiunzione «e»" do
        expect(described_class.correct("bug e story")).to eq("bug e story")
      end

      it "non tocca il pronome «li»" do
        expect(described_class.correct("li ho visti tutti")).to eq("li ho visti tutti")
      end

      it "non tocca l'articolo «la»" do
        expect(described_class.correct("la notifica e' rimandata")).to eq("la notifica è rimandata")
      end

      it "non tocca «meta» senza apostrofo" do
        expect(described_class.correct("la meta del progetto")).to eq("la meta del progetto")
      end

      it "corregge «meta'» con apostrofo" do
        expect(described_class.correct("meta' dei ticket")).to eq("metà dei ticket")
      end

      it "non tocca «sara» senza apostrofo, che è anche un nome" do
        expect(described_class.correct("Sara ha aperto il ticket")).to eq("Sara ha aperto il ticket")
      end

      it "corregge «sara'» con apostrofo" do
        expect(described_class.correct("il job sara' ripreso")).to eq("il job sarà ripreso")
      end
    end

    context "apostrofi che sono già corretti" do
      it "non tocca l'elisione" do
        expect(described_class.correct("l'utente dell'app un'ora")).to eq("l'utente dell'app un'ora")
      end

      it "non tocca «po'»" do
        expect(described_class.correct("un po' di tempo")).to eq("un po' di tempo")
      end

      it "non tocca gli imperativi tronchi" do
        expect(described_class.correct("da' il via, fa' il resto, va' avanti"))
          .to eq("da' il via, fa' il resto, va' avanti")
      end
    end

    context "maiuscole" do
      it "conserva l'iniziale maiuscola" do
        expect(described_class.correct("Perche fallisce?")).to eq("Perché fallisce?")
      end

      it "corregge «E'» a inizio frase" do
        expect(described_class.correct("E' definitivo")).to eq("È definitivo")
      end

      it "conserva il tutto maiuscolo" do
        expect(described_class.correct("PIU' VELOCE")).to eq("PIÙ VELOCE")
      end
    end

    context "zone protette" do
      it "non tocca il testo dentro un blocco di codice recintato" do
        text = "e' rotto\n```\nparams[:gia] e' qui\n```\ne' finito"
        expect(described_class.correct(text)).to eq("è rotto\n```\nparams[:gia] e' qui\n```\nè finito")
      end

      it "non tocca il testo dentro il codice inline" do
        expect(described_class.correct("il campo `gia_visto` e' nullo")).to eq("il campo `gia_visto` è nullo")
      end

      it "non tocca gli URL" do
        expect(described_class.correct("apri https://esempio.it/gia/perche ora"))
          .to eq("apri https://esempio.it/gia/perche ora")
      end

      it "non tocca gli indirizzi email" do
        expect(described_class.correct("scrivi a gia.perche@esempio.it subito"))
          .to eq("scrivi a gia.perche@esempio.it subito")
      end
    end

    context "input non correggibili" do
      it "lascia invariato un testo già corretto" do
        expect(described_class.correct("è più che già corretto")).to eq("è più che già corretto")
      end

      it "è idempotente" do
        once = described_class.correct("e' gia piu' lento")
        expect(described_class.correct(once)).to eq(once)
      end

      it "ritorna stringa vuota per nil" do
        expect(described_class.correct(nil)).to eq("")
      end

      it "non tocca il testo inglese" do
        expect(described_class.correct("the queue is empty")).to eq("the queue is empty")
      end

      it "non tocca una parola che contiene una voce del dizionario" do
        expect(described_class.correct("giacca perchezza")).to eq("giacca perchezza")
      end
    end
  end

  describe ".correct_deep" do
    it "corregge le stringhe di un array" do
      expect(described_class.correct_deep([ "e' rotto", "gia visto" ])).to eq([ "è rotto", "già visto" ])
    end

    it "corregge i valori di un hash annidato" do
      expect(described_class.correct_deep({ "given" => "e' aperto", "when" => [ "piu' click" ] }))
        .to eq({ "given" => "è aperto", "when" => [ "più click" ] })
    end

    it "lascia intatto ciò che non è testo" do
      expect(described_class.correct_deep([ 1, nil, true ])).to eq([ 1, nil, true ])
    end

    it "non tocca le chiavi" do
      expect(described_class.correct_deep({ "gia" => "gia" })).to eq({ "gia" => "già" })
    end
  end

  describe "PROMPT_RULE" do
    it "nomina gli accenti" do
      expect(described_class::PROMPT_RULE).to include("accent")
    end

    it "è essa stessa scritta con gli accenti giusti" do
      expect(described_class.correct(described_class::PROMPT_RULE)).to eq(described_class::PROMPT_RULE)
    end
  end

  describe "dizionario" do
    it "non contiene correzioni identiche alla forma sbagliata" do
      expect(described_class::CORRECTIONS.select { |wrong, right| wrong == right }).to be_empty
    end

    it "marca come ambigue solo forme presenti nel dizionario" do
      expect(described_class::APOSTROPHE_ONLY.to_a - described_class::CORRECTIONS.keys).to be_empty
    end
  end
end
