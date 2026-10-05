# frozen_string_literal: true

# CYRA-855 — il contorno che le factory riusano invece di coniarlo a ogni record.
#
# Un ticket finto tirava dentro organizzazione, progetto, stato, priorità e autore nuovi ogni volta,
# e tredici factory annidate (commenti, domande, resoconti, dipendenze, flussi) ne creavano uno
# completo a testa: su un campione di file la preparazione era metà del tempo di ogni prova.
module FactoryReuse
  module_function

  # L'organizzazione già in scena. La prova che ne vuole una seconda la passa esplicitamente, e
  # quella è anche l'unica forma che dichiara l'isolamento fra tenant invece di ereditarlo.
  def organization
    Organizations::Organization.order(:created_at, :id).first || FactoryBot.create(:organization)
  end
end
