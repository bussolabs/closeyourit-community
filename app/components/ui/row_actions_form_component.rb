# frozen_string_literal: true

module Ui
  # Il modulo UNICO che le azioni di riga di una lista condividono (CYRA-571).
  #
  # Ogni `button_to` costruisce un `<form>` suo, con dentro un token anti-falsificazione diverso da
  # tutti gli altri: su una lista lunga il peso cresce riga per riga e — proprio perché ogni token è
  # diverso — non si comprime. La pagina «Da sistemare» arrivava a quasi un megabyte per mostrare
  # una cinquantina di righe, e i soli moduli valevano più di un terzo del peso.
  #
  # Qui il modulo sta in pagina UNA volta e i bottoni delle righe lo puntano con `form="<id>"`,
  # scegliendo l'indirizzo con `formaction` (`Ui::ButtonComponent`, opzione `form_id:`). Restano
  # bottoni di submit veri: funzionano senza JavaScript e i lettori di schermo li annunciano per
  # quello che sono.
  #
  # Il token è quello GLOBALE — `form_authenticity_token` senza `form_options` — non quello legato
  # a una singola azione: `formaction` porta il submit a un indirizzo diverso da quello del modulo,
  # e un token per-form verrebbe rifiutato. Rails accetta il globale su qualunque azione
  # (`compare_with_global_token` in RequestForgeryProtection). Nei test la protezione è spenta,
  # quindi il campo non viene reso: la prova che il token buono è quello globale sta nel request
  # spec che la riaccende (spec/requests/member/vault/attention_spec.rb).
  # Con un blocco il modulo prende dei campi e si vede (è il caso del dialog condiviso: un motivo
  # obbligatorio scritto una volta per la pagina, non una per riga). Senza blocco è vuoto e sta
  # nascosto: servono solo i bottoni delle righe che lo puntano.
  class RowActionsFormComponent < BaseComponent
    def initialize(id: "row-actions", test_id: nil, hidden: true)
      @id = id
      @test_id = test_id
      @hidden = hidden
    end

    private

    def form_options
      opts = { id: @id, method: "post" }
      opts[:class] = "hidden" if @hidden
      opts[:data] = { test: @test_id } if @test_id
      opts
    end
  end
end
