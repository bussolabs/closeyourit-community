# frozen_string_literal: true

module Ticketing
  # I consigli scritti sotto `**Consigli:**` in un testo lungo del ticket (CYRA-264): una riga per
  # consiglio, ognuna destinata a diventare il titolo di un ticket nuovo.
  #
  # PORO puro e senza scritture, come Ticketing::CommentShape: sbagliare qui non produce un errore
  # visibile ma il titolo sbagliato su un ticket vero, oppure fa sparire in silenzio un consiglio che
  # qualcuno aveva scritto. Deve essere testabile da solo, senza vista e senza controller.
  #
  # Il contratto è quello di knowledge-base/global/closeyourit-writing.md, ricontrollato da
  # skills/shared/scripts/text-check.mjs nel repo delle skill: se cambia lì, cambia qui.
  class AdviceLines < ApplicationService
    LABEL = "Consigli"

    # `**Consigli:**` a inizio riga. Il grassetto è parte del contratto, non decorazione: distingue
    # l'etichetta da una riga che parla di consigli.
    SECTION = /\A\*\*#{LABEL}:\*\*\s*\z/
    # Una qualsiasi altra etichetta chiude la sezione.
    ANY_LABEL = /\A\*\*[^*:]+:\*\*/
    BULLET = /\A\s*[-*]\s+(?<text>\S.*)\z/

    # Oltre questo numero la sezione non è più un elenco di consigli ma un dump, e mostrarla come
    # cento link non aiuterebbe nessuno.
    MAX_LINES = 20
    # Il titolo di un ticket si ferma a 255 (Ticketing::Ticket length_budget :title): una riga più
    # lunga arriva troncata, invece di far fallire la creazione a form già compilato.
    MAX_LINE_CHARS = 255

    def initialize(text:)
      @text = text.to_s
    end

    def call
      lines = @text.lines.map(&:chomp)
      start = lines.index { |line| line.match?(SECTION) }
      return [] if start.nil?

      collect(lines, start)
    end

    private

    # La sezione finisce alla prima riga vuota o alla prossima etichetta — stessa lettura dello
    # script che avvisa chi scrive. Una riga che non è un elemento d'elenco viene saltata, non
    # indovinata: spezzare un paragrafo a caso produrrebbe titoli senza senso.
    def collect(lines, start)
      found = []
      lines[(start + 1)..].to_a.each do |line|
        break if line.strip.empty? || line.match?(ANY_LABEL)

        match = line.match(BULLET)
        next if match.nil?

        found << match[:text].strip.truncate(MAX_LINE_CHARS)
        break if found.length >= MAX_LINES
      end
      found
    end
  end
end
