# frozen_string_literal: true

module Knowledge
  module Review
    # Le regole del revisore, lette da un file versionato: app/prompts/knowledge/review.md è la copia
    # per la macchina di knowledge-base/global/knowledge-formats.md, e le due devono coincidere (la
    # spec lo verifica quando il repo della knowledge base è sul disco).
    module Rules
      PATH = Rails.root.join("app/prompts/knowledge/review.md")
      OUTPUT_RULES = <<~TEXT
        Rispondi SOLO con il JSON richiesto. `format` è il formato riconosciuto, `unknown` se la pagina non
        rientra in nessuno. `verdict` è `reject` se il formato è `unknown` o se hai trovato almeno una
        violazione; altrimenti `accept`. Ogni violazione porta il `code` della regola (K03, T01, …) e un
        `message` in italiano, una frase, che dica cosa manca o cosa togliere. `quote` è il passaggio
        della pagina che motiva la violazione, ricopiato ESATTAMENTE dal testo e lungo al massimo una
        riga: stringa vuota quando la regola riguarda qualcosa che manca, e mai una frase tua. Una
        citazione che nel testo non c'è viene buttata via. `suggested_title` è il titolo nella forma
        «<Area> — <oggetto>»; `suggested_kind` il kind del formato riconosciuto.
        `split_suggestion` elenca i titoli delle pagine in cui spezzare, solo se la pagina tratta più
        argomenti. `duplicate_of` è il titolo della pagina vicina che copre già lo stesso fatto, o null.
      TEXT

      module_function

      def text = @text ||= PATH.read

      def system_prompt = "#{text}\n\n## Come rispondere\n\n#{OUTPUT_RULES}\n#{Text::ItalianOrthography::PROMPT_RULE}"

      # I formati che il file descrive (una sezione `## <chiave>` ciascuno): la spec pretende che
      # coincidano con Knowledge::Constants::REVIEW_FORMATS, così enum e prompt non divergono.
      def formats_in_text = text.scan(/^## Formato:\s*(\S+)/).flatten
    end
  end
end
