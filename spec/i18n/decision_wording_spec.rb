# frozen_string_literal: true

require "rails_helper"

# CYRA-630 — la stessa decisione, chiamata allo stesso modo dovunque la si prenda.
#
# La decisione si prende dalla scheda della lavorazione, e i pulsanti della scheda Automazione del
# ticket restano dove sono per scelta esplicita (decisione cliente del 2026-08-17). Restando, però,
# devono dire le stesse parole: «Richiedi modifiche» e «Respingi» erano lo stesso identico service
# (`RequestPlanChanges`) chiamato in due modi a un clic di distanza, e chi leggeva non poteva sapere
# che erano la stessa cosa.
#
# Non è una prova sui testi, è una prova sul VOCABOLARIO: il pulsante e la sua controparte devono
# essere la stessa stringa, in tutte e due le lingue. Cambiarne uno solo fa rosso qui.
RSpec.describe "le due superfici chiamano la stessa decisione con le stesse parole" do
  # pulsante della scheda Automazione del ticket → la voce della scheda della lavorazione che porta
  # allo stesso service.
  coppie = {
    %w[tickets automation plan approve] => %w[approvals actions approve awaiting_approval],
    %w[tickets automation plan request_changes] => %w[approvals actions reject awaiting_approval],
    %w[tickets automation blocked retry] => %w[approvals actions approve review_blocked],
    %w[tickets automation cancel] => %w[approvals actions reject review_blocked]
  }.freeze

  # CYRA-675 — «Rivaluta» non ha una coppia da tenere allineata: le due superfici leggono la STESSA
  # chiave (`member.approvals.actions.reassess`), che è il modo più forte di dire la stessa cosa —
  # non si può divergere. La prova qui è che quella chiave, e il suo effetto dichiarato, esistano in
  # tutte e due le lingue: senza, una delle due pagine mostrerebbe l'identificatore interno.
  chiavi_condivise = %w[approvals.actions.reassess approvals.reassess_hint].freeze

  %w[it en].each do |lingua|
    chiavi_condivise.each do |chiave|
      it "#{lingua}: member.#{chiave} c'è, ed è la stessa in home e sulla scheda" do
        expect(I18n.t("member.#{chiave}", locale: lingua, default: nil)).to be_present
      end
    end

    coppie.each do |sul_ticket, sulla_scheda|
      it "#{lingua}: member.#{sul_ticket.join('.')} dice come member.#{sulla_scheda.join('.')}" do
        parole = ->(chiave) { I18n.t("member.#{chiave.join('.')}", locale: lingua, default: nil) }

        expect(parole.call(sul_ticket)).to be_present, "manca la voce sul ticket"
        expect(parole.call(sulla_scheda)).to be_present, "manca la voce sulla scheda"
        expect(parole.call(sul_ticket)).to eq(parole.call(sulla_scheda))
      end
    end
  end
end
